import AppKit
import UserNotifications
import WebKit

/// Native notification behavior the bridge depends on. Production uses
/// `DuetNotificationManager`; tests substitute a recorder because
/// `UNUserNotificationCenter` is unavailable outside a real app bundle.
@MainActor
protocol UserNotificationPresenting: AnyObject {
    var cachedPermission: NotificationPermission { get }
    func currentPermission() async -> NotificationPermission
    func requestPermission() async -> NotificationPermission
    func show(_ request: NotificationShowRequest, from service: ChatService)
    func notifyResponseCompletion(for service: ChatService)
}

/// Connects one provider web view's injected Notification shim to native
/// macOS notifications.
@MainActor
final class NotificationBridge: NSObject {
    private let service: ChatService
    private let presenter: UserNotificationPresenting

    init(service: ChatService, presenter: UserNotificationPresenting) {
        self.service = service
        self.presenter = presenter
        super.init()
    }

    func install(in configuration: WKWebViewConfiguration) {
        // Hidden or minimized web views must keep running their timers, or the
        // response watcher would stop exactly when its notifications matter.
        configuration.preferences.inactiveSchedulingPolicy = .none
        let userContentController = configuration.userContentController
        let script = WKUserScript(
            source: NotificationScript.source(
                initialPermission: presenter.cachedPermission,
                allowedHosts: service.webNotificationHosts
            ),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        userContentController.addUserScript(script)
        let responseWatcher = WKUserScript(
            source: NotificationScript.responseWatcherSource(
                indicatorSelectors: ProviderAdapter.adapter(for: service).generationIndicatorSelectors,
                allowedHosts: service.webNotificationHosts
            ),
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        userContentController.addUserScript(responseWatcher)
        userContentController.addScriptMessageHandler(
            self,
            contentWorld: .page,
            name: NotificationScript.handlerName
        )
    }
}

extension NotificationBridge: WKScriptMessageHandlerWithReply {
    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) async -> (Any?, String?) {
        guard let parsed = NotificationBridgeMessage(body: message.body) else { return (nil, nil) }
        switch parsed {
        case .permission:
            return (await presenter.currentPermission().domValue, nil)
        case .requestPermission:
            return (await presenter.requestPermission().domValue, nil)
        case .show(let request):
            presenter.show(request, from: service)
            return (nil, nil)
        case .responseComplete:
            presenter.notifyResponseCompletion(for: service)
            return (nil, nil)
        }
    }
}

/// Owns Duet's relationship with `UNUserNotificationCenter`: permission state,
/// posting provider notifications, and routing notification clicks back to the
/// originating provider pane. The notification center is only touched from
/// method bodies so test executables that construct browsers never reach it.
@MainActor
final class DuetNotificationManager: NSObject, UserNotificationPresenting {
    static let shared = DuetNotificationManager()

    private static let permissionDefaultsKey = "webNotificationPermission"
    private nonisolated static let serviceUserInfoKey = "duet.service"

    private(set) var cachedPermission: NotificationPermission
    private var revealWorkspace: ((ChatService) -> Void)?
    private var lastSiteNotificationDates: [ChatService: Date] = [:]

    private override init() {
        let stored = UserDefaults.standard.string(forKey: Self.permissionDefaultsKey)
        cachedPermission = stored.flatMap(NotificationPermission.init(rawValue:)) ?? .undetermined
        super.init()
    }

    /// Called once from the app scene. Registers for click handling and
    /// refreshes the cached permission used to seed injected shims.
    func configure(revealWorkspace: @escaping (ChatService) -> Void) {
        guard self.revealWorkspace == nil else { return }
        self.revealWorkspace = revealWorkspace
        UNUserNotificationCenter.current().delegate = self
        Task { _ = await currentPermission() }
    }

    func currentPermission() async -> NotificationPermission {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return updateCachedPermission(from: settings.authorizationStatus)
    }

    func requestPermission() async -> NotificationPermission {
        let current = await currentPermission()
        guard current == .undetermined else { return current }
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])
        return await currentPermission()
    }

    /// Fires when Duet's response watcher sees a provider finish generating.
    /// Skips situations the user is already watching, and defers to a site
    /// notification that just covered the same completion.
    func notifyResponseCompletion(for service: ChatService) {
        let workspaceWindow = DuetWindowRegistry.visibleWorkspaceWindow()
        let shouldNotify = ResponseCompletionPolicy.shouldNotify(
            isEnabled: responseCompletionNotificationsEnabled,
            isAppActive: NSApp.isActive,
            isWorkspaceVisible: workspaceWindow.map { $0.isVisible && !$0.isMiniaturized } ?? false,
            secondsSinceSiteNotification: lastSiteNotificationDates[service]
                .map { Date().timeIntervalSince($0) }
        )
        guard shouldNotify else { return }
        show(
            NotificationShowRequest(
                title: service.title,
                body: "Finished responding",
                tag: "duet-response-complete"
            ),
            from: service
        )
    }

    private var responseCompletionNotificationsEnabled: Bool {
        UserDefaults.standard.object(forKey: AppPreferenceKey.responseCompletionNotifications)
            as? Bool ?? true
    }

    func show(_ request: NotificationShowRequest, from service: ChatService) {
        lastSiteNotificationDates[service] = Date()
        Task { @MainActor in
            var permission = await self.currentPermission()
            if permission == .undetermined {
                permission = await self.requestPermission()
            }
            guard permission == .granted else { return }

            let content = UNMutableNotificationContent()
            content.title = request.title.isEmpty ? service.title : request.title
            content.body = request.body
            content.threadIdentifier = service.rawValue
            content.userInfo = [Self.serviceUserInfoKey: service.rawValue]

            // Reuse the page-provided tag as the identifier so a re-notified
            // tag replaces its predecessor, matching Notification API behavior.
            let identifier = request.tag.isEmpty
                ? UUID().uuidString
                : "\(service.rawValue)-\(request.tag)"
            let notificationRequest = UNNotificationRequest(
                identifier: identifier,
                content: content,
                trigger: nil
            )
            try? await UNUserNotificationCenter.current().add(notificationRequest)
        }
    }

    private func updateCachedPermission(from status: UNAuthorizationStatus) -> NotificationPermission {
        let permission: NotificationPermission = switch status {
        case .authorized, .provisional: .granted
        case .denied: .denied
        default: .undetermined
        }
        if permission != cachedPermission {
            cachedPermission = permission
            UserDefaults.standard.set(permission.rawValue, forKey: Self.permissionDefaultsKey)
        }
        return permission
    }
}

extension DuetNotificationManager: UNUserNotificationCenterDelegate {
    /// Providers decide when a notification is warranted (typically only while
    /// their page is hidden), so banners stay visible even when Duet is active.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let rawService = response.notification.request.content
            .userInfo[Self.serviceUserInfoKey] as? String
        guard let rawService, let service = ChatService(rawValue: rawService) else { return }
        await MainActor.run {
            self.revealWorkspace?(service)
        }
    }
}
