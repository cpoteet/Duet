import Foundation

/// The DOM notification permission states as exposed to provider pages.
enum NotificationPermission: String, Sendable {
    case undetermined = "default"
    case granted
    case denied

    var domValue: String { rawValue }
}

/// A provider page's request to display one notification.
struct NotificationShowRequest: Equatable, Sendable {
    let title: String
    let body: String
    let tag: String
}

/// A validated message from the injected notification shim.
enum NotificationBridgeMessage: Equatable {
    case permission
    case requestPermission
    case show(NotificationShowRequest)
    case responseComplete

    init?(body: Any) {
        guard let dictionary = body as? [String: Any],
              let type = dictionary["type"] as? String else { return nil }
        switch type {
        case "permission":
            self = .permission
        case "requestPermission":
            self = .requestPermission
        case "responseComplete":
            self = .responseComplete
        case "show":
            guard let title = dictionary["title"] as? String else { return nil }
            self = .show(NotificationShowRequest(
                title: title,
                body: dictionary["body"] as? String ?? "",
                tag: dictionary["tag"] as? String ?? ""
            ))
        default:
            return nil
        }
    }
}

/// Decides whether a detected response completion should produce a native
/// notification. Kept free of AppKit so the rules stay unit-testable.
enum ResponseCompletionPolicy {
    /// A site notification that just arrived for the same provider already
    /// covers the completion; suppress the duplicate inside this window.
    static let siteNotificationSuppressionWindow: TimeInterval = 10

    static func shouldNotify(
        isEnabled: Bool,
        isAppActive: Bool,
        isWorkspaceVisible: Bool,
        secondsSinceSiteNotification: TimeInterval?
    ) -> Bool {
        guard isEnabled else { return false }
        if let secondsSinceSiteNotification,
           secondsSinceSiteNotification < siteNotificationSuppressionWindow {
            return false
        }
        return !isAppActive || !isWorkspaceVisible
    }
}

/// Generates the Notification API shim injected into provider pages. WebKit
/// exposes no public website-notification support to third-party `WKWebView`
/// clients, so Duet supplies the standards-shaped in-page API itself and
/// bridges it to native macOS notifications while the provider page is loaded.
enum NotificationScript {
    static let handlerName = "duetNotifications"

    static func source(initialPermission: NotificationPermission, allowedHosts: [String]) -> String {
        """
        (() => {
          if (window.__duetNotificationBridgeInstalled) return;
          const bridge = window.webkit?.messageHandlers?.\(handlerName);
          if (!bridge) return;
          const allowedHosts = \(jsonArray(allowedHosts));
          const host = (location.hostname || "").toLowerCase();
          if (!allowedHosts.some(domain => host === domain || host.endsWith("." + domain))) return;
          window.__duetNotificationBridgeInstalled = true;

          let permission = \(jsonString(initialPermission.domValue));
          const acceptPermission = value => {
            if (value === "granted" || value === "denied" || value === "default") permission = value;
            return permission;
          };

          class DuetNotification extends EventTarget {
            constructor(title, options) {
              super();
              const settings = options || {};
              this.title = title === undefined ? "" : String(title);
              this.body = settings.body === undefined ? "" : String(settings.body);
              this.tag = settings.tag === undefined ? "" : String(settings.tag);
              this.icon = settings.icon === undefined ? "" : String(settings.icon);
              this.data = settings.data === undefined ? null : settings.data;
              this.dir = "auto";
              this.lang = "";
              this.silent = settings.silent === true;
              this.onclick = null;
              this.onclose = null;
              this.onerror = null;
              this.onshow = null;
              const deliverEvent = name => setTimeout(() => {
                const event = new Event(name);
                const handler = this["on" + name];
                if (typeof handler === "function") { try { handler.call(this, event); } catch (_) {} }
                this.dispatchEvent(event);
              }, 0);
              if (permission !== "granted") {
                deliverEvent("error");
                return;
              }
              bridge.postMessage({ type: "show", title: this.title, body: this.body, tag: this.tag }).catch(() => {});
              deliverEvent("show");
            }

            close() {}

            static get permission() { return permission; }

            static get maxActions() { return 0; }

            static requestPermission(callback) {
              return bridge.postMessage({ type: "requestPermission" })
                .then(acceptPermission, () => permission)
                .then(value => {
                  if (typeof callback === "function") { try { callback(value); } catch (_) {} }
                  return value;
                });
            }
          }

          Object.defineProperty(window, "Notification", {
            value: DuetNotification,
            writable: true,
            configurable: true
          });

          if (window.ServiceWorkerRegistration) {
            ServiceWorkerRegistration.prototype.showNotification = function (title, options) {
              new DuetNotification(title, options);
              return Promise.resolve();
            };
            ServiceWorkerRegistration.prototype.getNotifications = function () {
              return Promise.resolve([]);
            };
          }

          bridge.postMessage({ type: "permission" }).then(acceptPermission, () => {});
        })();
        """
    }

    /// Generates the watcher that detects a provider response finishing and
    /// reports it over the bridge. Providers whose sites refuse to use the
    /// in-page Notification API (they require an unobtainable Web Push
    /// subscription) still get native completion notifications this way.
    static func responseWatcherSource(
        indicatorSelectors: [String],
        allowedHosts: [String],
        pollIntervalMilliseconds: Int = 600,
        minimumGenerationMilliseconds: Int = 1500
    ) -> String {
        """
        (() => {
          if (window.__duetResponseWatcherInstalled) return;
          const bridge = window.webkit?.messageHandlers?.\(handlerName);
          if (!bridge) return;
          const allowedHosts = \(jsonArray(allowedHosts));
          const host = (location.hostname || "").toLowerCase();
          if (!allowedHosts.some(domain => host === domain || host.endsWith("." + domain))) return;
          window.__duetResponseWatcherInstalled = true;

          const indicatorSelectors = \(jsonArray(indicatorSelectors));
          let wasGenerating = false;
          let generatingSince = 0;
          setInterval(() => {
            let generating = false;
            try {
              generating = indicatorSelectors.some(selector => document.querySelector(selector));
            } catch (_) {}
            const now = Date.now();
            if (generating) {
              if (!wasGenerating) generatingSince = now;
              wasGenerating = true;
              return;
            }
            if (!wasGenerating) return;
            wasGenerating = false;
            if (now - generatingSince >= \(minimumGenerationMilliseconds)) {
              bridge.postMessage({ type: "responseComplete" }).catch(() => {});
            }
          }, \(pollIntervalMilliseconds));
        })();
        """
    }

    private static func jsonArray(_ values: [String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: values) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func jsonString(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]) else { return "\"\"" }
        let array = String(decoding: data, as: UTF8.self)
        return String(array.dropFirst().dropLast())
    }
}
