import CoreLocation
import Foundation
import WebKit

enum LocationPermissionState: String, Sendable {
    case prompt
    case granted
    case denied
}

enum LocationProviderError: Error, Equatable {
    case permissionDenied
    case unavailable
    case timedOut

    var webCode: Int {
        switch self {
        case .permissionDenied: 1
        case .unavailable: 2
        case .timedOut: 3
        }
    }

    var message: String {
        switch self {
        case .permissionDenied: "Location permission was denied."
        case .unavailable: "Your location is currently unavailable."
        case .timedOut: "The location request timed out."
        }
    }
}

struct BrowserLocation: Equatable, Sendable {
    let latitude: Double
    let longitude: Double
    let accuracy: Double
    let altitude: Double?
    let altitudeAccuracy: Double?
    let heading: Double?
    let speed: Double?
    let timestampMilliseconds: Double

    init(location: CLLocation) {
        latitude = location.coordinate.latitude
        longitude = location.coordinate.longitude
        accuracy = location.horizontalAccuracy
        altitude = location.verticalAccuracy >= 0 ? location.altitude : nil
        altitudeAccuracy = location.verticalAccuracy >= 0 ? location.verticalAccuracy : nil
        heading = location.course >= 0 ? location.course : nil
        speed = location.speed >= 0 ? location.speed : nil
        timestampMilliseconds = location.timestamp.timeIntervalSince1970 * 1_000
    }

    init(
        latitude: Double,
        longitude: Double,
        accuracy: Double,
        altitude: Double? = nil,
        altitudeAccuracy: Double? = nil,
        heading: Double? = nil,
        speed: Double? = nil,
        timestampMilliseconds: Double
    ) {
        self.latitude = latitude
        self.longitude = longitude
        self.accuracy = accuracy
        self.altitude = altitude
        self.altitudeAccuracy = altitudeAccuracy
        self.heading = heading
        self.speed = speed
        self.timestampMilliseconds = timestampMilliseconds
    }

    var webPayload: [String: Any] {
        func webValue(_ value: Double?) -> Any {
            if let value { return value }
            return NSNull()
        }
        return [
            "ok": true,
            "coords": [
                "latitude": latitude,
                "longitude": longitude,
                "accuracy": accuracy,
                "altitude": webValue(altitude),
                "altitudeAccuracy": webValue(altitudeAccuracy),
                "heading": webValue(heading),
                "speed": webValue(speed)
            ],
            "timestamp": timestampMilliseconds
        ]
    }
}

@MainActor
protocol LocationProviding: AnyObject {
    var permissionState: LocationPermissionState { get }
    func currentPosition(enableHighAccuracy: Bool) async throws -> BrowserLocation
}

@MainActor
final class CoreLocationProvider: NSObject, LocationProviding, @preconcurrency CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<BrowserLocation, Error>?
    private var timeoutTask: Task<Void, Never>?

    override init() {
        super.init()
        manager.delegate = self
    }

    var permissionState: LocationPermissionState {
        switch manager.authorizationStatus {
        case .notDetermined: .prompt
        case .authorizedAlways, .authorizedWhenInUse: .granted
        case .denied, .restricted: .denied
        @unknown default: .denied
        }
    }

    func currentPosition(enableHighAccuracy: Bool) async throws -> BrowserLocation {
        guard continuation == nil else { throw LocationProviderError.unavailable }
        manager.desiredAccuracy = enableHighAccuracy ? kCLLocationAccuracyBest : kCLLocationAccuracyHundredMeters

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(15))
                self?.finish(.failure(LocationProviderError.timedOut))
            }
            continueAfterAuthorizationChange()
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard continuation != nil else { return }
        continueAfterAuthorizationChange()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else {
            finish(.failure(LocationProviderError.unavailable))
            return
        }
        finish(.success(BrowserLocation(location: location)))
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if let coreLocationError = error as? CLError, coreLocationError.code == .denied {
            finish(.failure(LocationProviderError.permissionDenied))
        } else {
            finish(.failure(LocationProviderError.unavailable))
        }
    }

    private func continueAfterAuthorizationChange() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            manager.requestLocation()
        case .denied, .restricted:
            finish(.failure(LocationProviderError.permissionDenied))
        @unknown default:
            finish(.failure(LocationProviderError.unavailable))
        }
    }

    private func finish(_ result: Result<BrowserLocation, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        continuation.resume(with: result)
    }
}

enum LocationScript {
    static let handlerName = "duetLocation"

    static func source(allowedHosts: [String]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: allowedHosts)
        let allowedHostsJSON = String(data: data, encoding: .utf8)!
        return """
        (() => {
          const allowedHosts = \(allowedHostsJSON);
          const host = (location.hostname || '').toLowerCase();
          const allowed = allowedHosts.some(domain => host === domain || host.endsWith(`.${domain}`));
          const firstPath = location.pathname.split('/').filter(Boolean)[0]?.toLowerCase();
          if (!allowed || ['auth', 'login', 'signin', 'sign-in'].includes(firstPath) || window.__duetLocationBridgeInstalled) return;

          const bridge = window.webkit?.messageHandlers?.\(handlerName);
          if (!bridge?.postMessage) return;

          let permissionState = 'prompt';
          const permissionStatus = new EventTarget();
          Object.defineProperty(permissionStatus, 'state', { get: () => permissionState });
          permissionStatus.onchange = null;

          const setPermissionState = state => {
            if (!['prompt', 'granted', 'denied'].includes(state) || state === permissionState) return;
            permissionState = state;
            permissionStatus.dispatchEvent(new Event('change'));
            if (typeof permissionStatus.onchange === 'function') permissionStatus.onchange();
          };

          const makeError = (code, message) => ({
            code,
            message,
            PERMISSION_DENIED: 1,
            POSITION_UNAVAILABLE: 2,
            TIMEOUT: 3
          });

          const requestPosition = (successCallback, errorCallback, options) => {
            if (typeof successCallback !== 'function') throw new TypeError('A success callback is required.');
            Promise.resolve(bridge.postMessage({
              type: 'currentPosition',
              enableHighAccuracy: Boolean(options?.enableHighAccuracy)
            })).then(result => {
              if (!result?.ok) {
                const error = makeError(Number(result?.code) || 2, result?.message || 'Location unavailable.');
                if (error.code === 1) setPermissionState('denied');
                if (typeof errorCallback === 'function') errorCallback(error);
                return;
              }
              setPermissionState('granted');
              const coords = Object.freeze({
                latitude: Number(result.coords.latitude),
                longitude: Number(result.coords.longitude),
                accuracy: Number(result.coords.accuracy),
                altitude: result.coords.altitude == null ? null : Number(result.coords.altitude),
                altitudeAccuracy: result.coords.altitudeAccuracy == null ? null : Number(result.coords.altitudeAccuracy),
                heading: result.coords.heading == null ? null : Number(result.coords.heading),
                speed: result.coords.speed == null ? null : Number(result.coords.speed)
              });
              successCallback(Object.freeze({ coords, timestamp: Number(result.timestamp) }));
            }).catch(() => {
              if (typeof errorCallback === 'function') errorCallback(makeError(2, 'Location unavailable.'));
            });
          };

          let nextWatchIdentifier = 1;
          const activeWatches = new Set();
          const geolocation = Object.freeze({
            getCurrentPosition(successCallback, errorCallback, options) {
              requestPosition(successCallback, errorCallback, options);
            },
            watchPosition(successCallback, errorCallback, options) {
              const identifier = nextWatchIdentifier++;
              activeWatches.add(identifier);
              requestPosition(
                position => { if (activeWatches.has(identifier)) successCallback(position); },
                error => { if (activeWatches.has(identifier) && typeof errorCallback === 'function') errorCallback(error); },
                options
              );
              return identifier;
            },
            clearWatch(identifier) {
              activeWatches.delete(Number(identifier));
            }
          });

          try {
            Object.defineProperty(navigator, 'geolocation', {
              configurable: true,
              enumerable: true,
              value: geolocation
            });
          } catch (_) {
            Object.defineProperty(Navigator.prototype, 'geolocation', {
              configurable: true,
              enumerable: true,
              get: () => geolocation
            });
          }

          const permissions = navigator.permissions;
          if (permissions?.query) {
            const originalQuery = permissions.query.bind(permissions);
            const query = descriptor => {
              if (descriptor?.name !== 'geolocation') return originalQuery(descriptor);
              return Promise.resolve(bridge.postMessage({ type: 'permission' }))
                .then(result => {
                  setPermissionState(result?.state || 'prompt');
                  return permissionStatus;
                }, () => permissionStatus);
            };
            try {
              Object.defineProperty(permissions, 'query', { configurable: true, value: query });
            } catch (_) {
              Object.defineProperty(Object.getPrototypeOf(permissions), 'query', { configurable: true, value: query });
            }
          }

          window.__duetLocationBridgeInstalled = true;
        })();
        """
    }
}

@MainActor
final class LocationBridge: NSObject {
    private let service: ChatService
    private let provider: any LocationProviding

    init(service: ChatService, provider: (any LocationProviding)? = nil) {
        self.service = service
        self.provider = provider ?? CoreLocationProvider()
        super.init()
    }

    func install(in configuration: WKWebViewConfiguration) {
        let userContentController = configuration.userContentController
        userContentController.addUserScript(WKUserScript(
            source: LocationScript.source(allowedHosts: service.webNotificationHosts),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        userContentController.addScriptMessageHandler(
            self,
            contentWorld: .page,
            name: LocationScript.handlerName
        )
    }
}

extension LocationBridge: WKScriptMessageHandlerWithReply {
    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) async -> (Any?, String?) {
        let origin = message.frameInfo.securityOrigin
        guard NotificationMessageOriginPolicy.allows(
            isMainFrame: message.frameInfo.isMainFrame,
            scheme: origin.protocol,
            host: origin.host,
            allowedHosts: service.webNotificationHosts
        ), service.allowsNativePermission(at: message.frameInfo.request.url),
           service.allowsNativePermission(at: message.webView?.url) else { return (nil, nil) }
        let requestingPageURL = message.webView?.url
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else {
            return (nil, nil)
        }

        if type == "permission" {
            return (["state": provider.permissionState.rawValue], nil)
        }
        guard type == "currentPosition" else { return (nil, nil) }

        do {
            let position = try await provider.currentPosition(
                enableHighAccuracy: body["enableHighAccuracy"] as? Bool ?? false
            )
            guard message.webView?.url == requestingPageURL,
                  service.allowsNativePermission(at: message.webView?.url) else {
                return (["ok": false, "code": 1, "message": "Location permission was denied."], nil)
            }
            return (position.webPayload, nil)
        } catch let error as LocationProviderError {
            return (["ok": false, "code": error.webCode, "message": error.message], nil)
        } catch {
            return ([
                "ok": false,
                "code": LocationProviderError.unavailable.webCode,
                "message": LocationProviderError.unavailable.message
            ], nil)
        }
    }
}
