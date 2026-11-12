import AppKit
import Combine
import Foundation
import WebKit

private enum IntegrationTestError: Error {
    case navigationFailed(String)
    case invalidJavaScriptResult
}

private struct ScriptResult: Decodable, Sendable {
    let ok: Bool
    let reason: String?
}

private struct NotificationFixtureOutcome: Decodable, Sendable {
    let supported: Bool
    let bridgeInstalled: Bool
    let initial: String?
    let requested: String?
    let constructed: Bool
    let showEventDelivered: Bool
    let errorEventDelivered: Bool
    let serviceWorkerPatched: Bool
    let failure: String?
}

private struct LocationFixtureOutcome: Decodable, Sendable {
    let supported: Bool
    let bridgeInstalled: Bool
    let permission: String?
    let latitude: Double?
    let longitude: Double?
    let accuracy: Double?
    let errorCode: Int?
    let failure: String?
}

@MainActor
private final class RecordingNotificationPresenter: UserNotificationPresenting {
    struct Shown {
        let request: NotificationShowRequest
        let service: ChatService
    }

    private(set) var cachedPermission: NotificationPermission
    private let permissionAfterRequest: NotificationPermission
    private(set) var shown: [Shown] = []

    init(initial: NotificationPermission, afterRequest: NotificationPermission) {
        cachedPermission = initial
        permissionAfterRequest = afterRequest
    }

    func currentPermission() async -> NotificationPermission {
        cachedPermission
    }

    func requestPermission() async -> NotificationPermission {
        cachedPermission = permissionAfterRequest
        return cachedPermission
    }

    func show(_ request: NotificationShowRequest, from service: ChatService) {
        shown.append(Shown(request: request, service: service))
    }

    private(set) var completions: [ChatService] = []

    func notifyResponseCompletion(for service: ChatService) {
        completions.append(service)
    }
}

@MainActor
private final class RecordingLocationProvider: LocationProviding {
    var permissionState: LocationPermissionState
    private let result: Result<BrowserLocation, LocationProviderError>
    private(set) var highAccuracyRequests: [Bool] = []

    init(
        permissionState: LocationPermissionState,
        result: Result<BrowserLocation, LocationProviderError>
    ) {
        self.permissionState = permissionState
        self.result = result
    }

    func currentPosition(enableHighAccuracy: Bool) async throws -> BrowserLocation {
        highAccuracyRequests.append(enableHighAccuracy)
        return try result.get()
    }
}

@MainActor
private final class RecordingPrintPresenter: WebPagePrintPresenting {
    private(set) var requestedWebViews: [WKWebView] = []

    func presentPrintPanel(for webView: WKWebView) {
        requestedWebViews.append(webView)
    }
}

@MainActor
private final class FixtureLoader: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?

    func load(_ url: URL, in webView: WKWebView) async throws {
        webView.navigationDelegate = self
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
    }

    /// Loads fixture markup under a real origin so origin-gated user scripts run.
    func loadHTML(_ html: String, baseURL: URL, in webView: WKWebView) async throws {
        webView.navigationDelegate = self
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            webView.loadHTMLString(html, baseURL: baseURL)
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            self.continuation?.resume()
            self.continuation = nil
        }
    }

    nonisolated func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        finishWithError(error.localizedDescription)
    }

    nonisolated func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        finishWithError(error.localizedDescription)
    }

    nonisolated private func finishWithError(_ message: String) {
        Task { @MainActor in
            self.continuation?.resume(throwing: IntegrationTestError.navigationFailed(message))
            self.continuation = nil
        }
    }
}

@main
struct HostLifecycleTests {
    @MainActor
    static func main() async {
        _ = NSApplication.shared
        var failures: [String] = []

        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() { failures.append(message) }
        }

        let firstHost = BrowserHostView(frame: .init(x: 0, y: 0, width: 400, height: 400))
        let secondHost = BrowserHostView(frame: .init(x: 0, y: 0, width: 400, height: 400))
        let transferredWebView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())

        firstHost.install(transferredWebView)
        secondHost.install(transferredWebView)
        firstHost.clear()
        expect(
            transferredWebView.superview === secondHost,
            "Old host removed a WKWebView after it moved to the split-pane host"
        )

        expect(
            ChatService.chatGPT.acceptsBridgeMessage(
                isMainFrame: true,
                protocol: "https",
                host: "chatgpt.com"
            ),
            "A provider main-frame origin should reach its notification bridge"
        )
        expect(
            !ChatService.chatGPT.acceptsBridgeMessage(
                isMainFrame: false,
                protocol: "https",
                host: "chatgpt.com"
            ),
            "A provider subframe must not reach the notification bridge"
        )
        expect(
            !ChatService.chatGPT.acceptsBridgeMessage(
                isMainFrame: true,
                protocol: "https",
                host: "chatgpt.com.evil.example"
            ),
            "A spoofed provider suffix must not reach the notification bridge"
        )
        expect(
            !ChatService.chatGPT.acceptsBridgeMessage(
                isMainFrame: true,
                protocol: "http",
                host: "chatgpt.com"
            ),
            "A non-HTTPS provider origin must not reach the notification bridge"
        )

        let revealRouter = NotificationRevealRouter()
        var routedServices: [ChatService] = []
        revealRouter.route(.claude)
        expect(routedServices.isEmpty, "A cold-start notification route should wait for the workspace")
        revealRouter.register { routedServices.append($0) }
        expect(
            routedServices == [.claude],
            "A cold-start notification route should resume when the workspace becomes available"
        )
        revealRouter.route(.chatGPT)
        expect(
            routedServices == [.claude, .chatGPT],
            "Notification routes should be delivered immediately after workspace registration"
        )

        let attachedWindow = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 400, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let attachedHost = BrowserHostView(frame: attachedWindow.contentView?.bounds ?? .zero)
        let detachedHost = BrowserHostView(frame: attachedHost.bounds)
        let protectedWebView = WKWebView(frame: attachedHost.bounds, configuration: WKWebViewConfiguration())
        attachedWindow.contentView = attachedHost
        attachedHost.install(protectedWebView)
        detachedHost.synchronizeHostedWebView(protectedWebView)
        expect(
            protectedWebView.superview === attachedHost,
            "A detached transient host must not steal a web view from the visible host"
        )

        let drawerWindow = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 400, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let drawerWebView = ProviderWebView(frame: drawerWindow.contentView?.bounds ?? .zero, configuration: WKWebViewConfiguration())
        drawerWindow.contentView?.addSubview(drawerWebView)
        var reservesDrawerFocus = true
        drawerWebView.reservesFocusForPrompt = { reservesDrawerFocus }
        drawerWindow.makeFirstResponder(drawerWebView)
        expect(
            drawerWindow.firstResponder !== drawerWebView,
            "An open prompt drawer must keep pages from taking keyboard focus"
        )
        reservesDrawerFocus = false
        drawerWindow.makeFirstResponder(drawerWebView)
        expect(
            drawerWindow.firstResponder === drawerWebView,
            "Pages must take keyboard focus normally while the prompt drawer is closed"
        )

        weak var releasedWebView: WKWebView?
        autoreleasepool {
            let releaseHost = BrowserHostView(frame: .init(x: 0, y: 0, width: 400, height: 400))
            let releaseBrowser = BrowserController(service: .chatGPT)
            let webView = releaseBrowser.prepare()
            releasedWebView = webView
            releaseHost.install(webView)
            releaseBrowser.release()
        }
        expect(
            releasedWebView == nil,
            "A cached browser host must not retain a web view after its controller releases it"
        )

        let staleHostBrowser = BrowserController(service: .chatGPT)
        _ = staleHostBrowser.prepare()
        staleHostBrowser.release()
        staleHostBrowser.activateWhenHosted()
        expect(
            staleHostBrowser.webView == nil,
            "A stale host callback must not recreate a released provider web view"
        )

        let mountWindow = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 400, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let mountHost = BrowserHostView(frame: mountWindow.contentView?.bounds ?? .zero)
        var mountNotificationCount = 0
        mountHost.onWindowAttachment = { mountNotificationCount += 1 }
        mountWindow.orderFront(nil)
        DuetWindowRegistry.register(mountWindow)
        mountWindow.contentView = mountHost
        mountHost.scheduleWindowAttachment()
        mountHost.scheduleWindowAttachment()
        expect(
            mountNotificationCount == 0,
            "Browser host mount callbacks must not run during the current SwiftUI update"
        )
        try? await Task.sleep(for: .milliseconds(20))
        expect(
            mountNotificationCount == 1,
            "Repeated browser host updates should coalesce into one mount callback"
        )
        mountHost.scheduleWindowAttachment()
        mountHost.clear()
        try? await Task.sleep(for: .milliseconds(20))
        expect(
            mountNotificationCount == 1,
            "A dismantled browser host must cancel its pending mount callback"
        )
        mountWindow.orderOut(nil)
        DuetWindowRegistry.unregister(mountWindow)

        let restoredWindow = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 400, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let restoredHost = BrowserHostView(frame: restoredWindow.contentView?.bounds ?? .zero)
        let restoredBrowser = BrowserController(service: .chatGPT)
        let restoredWebView = restoredBrowser.prepare()
        restoredHost.onWindowAttachment = {
            restoredHost.synchronizeHostedWebView(restoredBrowser.webView)
        }
        restoredWindow.contentView = restoredHost
        try? await Task.sleep(for: .milliseconds(20))
        expect(
            restoredWebView.superview == nil,
            "A provider view must not mount into a workspace before that window becomes active"
        )
        restoredWindow.orderFront(nil)
        DuetWindowRegistry.register(restoredWindow)
        try? await Task.sleep(for: .milliseconds(100))
        expect(
            restoredWebView.superview === restoredHost,
            "A restored workspace must mount its provider view after becoming the active workspace"
        )

        let staleWorkspaceWindow = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 400, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let staleWorkspaceHost = BrowserHostView(frame: staleWorkspaceWindow.contentView?.bounds ?? .zero)
        staleWorkspaceWindow.contentView = staleWorkspaceHost
        staleWorkspaceWindow.orderOut(nil)
        staleWorkspaceHost.synchronizeHostedWebView(restoredWebView)
        expect(
            restoredWebView.superview === restoredHost,
            "A stale workspace host must not steal a provider view from the registered workspace"
        )
        restoredWindow.orderOut(nil)
        DuetWindowRegistry.unregister(restoredWindow)

        // A window reopened on another Space registers before it is visible.
        let offscreenWindow = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 400, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let offscreenHost = BrowserHostView(frame: offscreenWindow.contentView?.bounds ?? .zero)
        let offscreenBrowser = BrowserController(service: .claude)
        let offscreenWebView = offscreenBrowser.prepare()
        offscreenHost.onWindowAttachment = {
            offscreenHost.synchronizeHostedWebView(offscreenBrowser.webView)
        }
        offscreenWindow.contentView = offscreenHost
        DuetWindowRegistry.register(offscreenWindow)
        try? await Task.sleep(for: .milliseconds(20))
        expect(
            !offscreenWindow.isVisible && offscreenWebView.superview === offscreenHost,
            "A registered workspace must mount its provider view before it becomes visible"
        )
        let takeoverWindow = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 400, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        takeoverWindow.orderFront(nil)
        DuetWindowRegistry.register(takeoverWindow)
        offscreenHost.clear()
        offscreenHost.synchronizeHostedWebView(offscreenWebView)
        expect(
            offscreenWebView.superview == nil,
            "A replaced workspace window must not claim a provider view"
        )
        takeoverWindow.orderOut(nil)
        DuetWindowRegistry.unregister(takeoverWindow)

        let focusWindow = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 400, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let focusHost = BrowserHostView(frame: focusWindow.contentView?.bounds ?? .zero)
        let focusedWebView = WKWebView(frame: focusHost.bounds, configuration: WKWebViewConfiguration())
        focusWindow.contentView = focusHost
        focusHost.install(focusedWebView)
        let acceptedWebViewFocus = focusWindow.makeFirstResponder(focusedWebView)
        expect(acceptedWebViewFocus, "Retained-pane focus test could not focus its web view")
        focusHost.setAcceptsKeyboardInput(false)
        expect(
            focusWindow.firstResponder !== focusedWebView,
            "An inactive retained pane should resign keyboard focus"
        )

        let detachedFocusHost = BrowserHostView(frame: focusWindow.contentView?.bounds ?? .zero)
        let detachedFocusedWebView = WKWebView(frame: detachedFocusHost.bounds, configuration: WKWebViewConfiguration())
        focusWindow.contentView = detachedFocusHost
        detachedFocusHost.install(detachedFocusedWebView)
        let acceptedDetachedWebViewFocus = focusWindow.makeFirstResponder(detachedFocusedWebView)
        expect(acceptedDetachedWebViewFocus, "Host-detachment focus test could not focus its web view")
        detachedFocusHost.clear()
        expect(
            focusWindow.firstResponder !== detachedFocusedWebView,
            "A browser host must resign its web view before detaching it from the window"
        )
        // A quick single-to-split-and-back switch: SwiftUI keeps the split
        // host alive while the single-pane host takes the view.
        let survivingSplitHost = BrowserHostView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let outgoingSingleHost = BrowserHostView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let reclaimedWebView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        survivingSplitHost.install(reclaimedWebView)
        outgoingSingleHost.install(reclaimedWebView)
        survivingSplitHost.install(reclaimedWebView)
        expect(
            reclaimedWebView.superview === survivingSplitHost,
            "A host must take back a web view that another host moved away"
        )
        outgoingSingleHost.clear()
        expect(
            reclaimedWebView.superview === survivingSplitHost,
            "Tearing down the outgoing host must not remove the reclaimed web view"
        )

        let identifiedWorkspaceWindow = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 400, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        identifiedWorkspaceWindow.contentView = WorkspaceWindowMarkerView(frame: .zero)
        expect(
            identifiedWorkspaceWindow.identifier == DuetWindowIdentifier.workspace,
            "The workspace marker should assign the stable workspace window identifier"
        )
        expect(
            DuetWindowRegistry.workspaceWindow === identifiedWorkspaceWindow,
            "The workspace marker should register the exact workspace window for later restoration"
        )
        identifiedWorkspaceWindow.identifier = NSUserInterfaceItemIdentifier("workspace-AppWindow-1")
        expect(
            identifiedWorkspaceWindow.identifier == DuetWindowIdentifier.workspace,
            "The workspace marker should restore its identifier when SwiftUI replaces it"
        )

        let windowSizeDefaultsName = "com.siolon.duet.tests.window-size.\(UUID().uuidString)"
        if let windowSizeDefaults = UserDefaults(suiteName: windowSizeDefaultsName) {
            defer { windowSizeDefaults.removePersistentDomain(forName: windowSizeDefaultsName) }
            identifiedWorkspaceWindow.setFrame(
                NSRect(x: 0, y: 0, width: 760, height: 540),
                display: false
            )
            DuetWindowSizePersistence.save(identifiedWorkspaceWindow, userDefaults: windowSizeDefaults)

            let sizeRestoreWindow = NSWindow(
                contentRect: .init(x: 0, y: 0, width: 400, height: 400),
                styleMask: [.titled, .resizable],
                backing: .buffered,
                defer: false
            )
            DuetWindowSizePersistence.restore(
                sizeRestoreWindow,
                centerInVisibleScreen: true,
                userDefaults: windowSizeDefaults
            )
            expect(
                abs(sizeRestoreWindow.frame.width - 760) < 0.5
                    && abs(sizeRestoreWindow.frame.height - 540) < 0.5,
                "The workspace should restore its persisted window size"
            )
            if let visibleFrame = sizeRestoreWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame {
                expect(
                    abs(sizeRestoreWindow.frame.midX - visibleFrame.midX) < 0.5
                        && abs(sizeRestoreWindow.frame.midY - visibleFrame.midY) < 0.5,
                    "The workspace should center its restored window on the visible screen"
                )
            }
        } else {
            failures.append("Window-size persistence test could not create isolated defaults")
        }

        identifiedWorkspaceWindow.orderOut(nil)
        let existingVisibleWindow = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 400, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        existingVisibleWindow.orderFront(nil)
        let replacementWorkspaceWindow = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 400, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        replacementWorkspaceWindow.orderFront(nil)
        expect(
            DuetWindowRegistry.visibleWorkspaceWindow(
                in: [identifiedWorkspaceWindow, existingVisibleWindow, replacementWorkspaceWindow]
            ) == nil,
            "A closed registered workspace should not be treated as a restorable visible window"
        )
        expect(
            DuetWindowRegistry.visibleWorkspaceWindow(
                in: [existingVisibleWindow, replacementWorkspaceWindow]
            ) == nil,
            "A newly visible unidentified window must not become the workspace"
        )
        DuetWindowRegistry.register(replacementWorkspaceWindow)
        expect(
            replacementWorkspaceWindow.identifier == DuetWindowIdentifier.workspace,
            "A replacement workspace should receive the stable workspace identifier immediately"
        )
        expect(
            DuetWindowRegistry.visibleWorkspaceWindow(
                in: [identifiedWorkspaceWindow, existingVisibleWindow, replacementWorkspaceWindow]
            ) === replacementWorkspaceWindow,
            "Workspace restoration should replace the stale registry entry with the exact reopened window"
        )
        expect(
            identifiedWorkspaceWindow.isExcludedFromWindowsMenu,
            "A replaced workspace should be removed from the Window menu"
        )
        expect(
            identifiedWorkspaceWindow.identifier != DuetWindowIdentifier.workspace,
            "A replaced workspace must lose the identifier that permits provider hosting"
        )
        replacementWorkspaceWindow.orderOut(nil)
        let restorableWindows = [identifiedWorkspaceWindow, existingVisibleWindow, replacementWorkspaceWindow]
        expect(
            DuetWindowRegistry.restorableWorkspaceWindow(in: restorableWindows, appIsHidden: true)
                === replacementWorkspaceWindow,
            "Revealing a hidden Duet should bring back its registered workspace, not open another"
        )
        expect(
            DuetWindowRegistry.restorableWorkspaceWindow(in: restorableWindows, appIsHidden: false) == nil,
            "An off-screen workspace outside a hidden app should not be treated as restorable"
        )
        expect(
            DuetWindowRegistry.restorableWorkspaceWindow(
                in: [identifiedWorkspaceWindow, existingVisibleWindow],
                appIsHidden: true
            ) == nil,
            "A workspace window that no longer exists should not be restored"
        )
        existingVisibleWindow.orderOut(nil)
        DuetWindowRegistry.unregister(replacementWorkspaceWindow)

        let filePickerSelector = NSSelectorFromString(
            "webView:runOpenPanelWithParameters:initiatedByFrame:completionHandler:"
        )
        let mediaCaptureSelector = NSSelectorFromString(
            "webView:requestMediaCapturePermissionForOrigin:initiatedByFrame:type:decisionHandler:"
        )
        let responsePolicySelector = NSSelectorFromString(
            "webView:decidePolicyForNavigationResponse:decisionHandler:"
        )
        let actionDownloadSelector = NSSelectorFromString(
            "webView:navigationAction:didBecomeDownload:"
        )
        let responseDownloadSelector = NSSelectorFromString(
            "webView:navigationResponse:didBecomeDownload:"
        )
        let downloadDestinationSelector = NSSelectorFromString(
            "download:decideDestinationUsingResponse:suggestedFilename:completionHandler:"
        )
        let browserController = BrowserController(service: .chatGPT)
        let preparedWebView = browserController.prepare()
        expect(
            (preparedWebView.value(forKey: "drawsBackground") as? Bool) == false,
            "Provider web views should expose the native host canvas while loading"
        )
        expect(
            preparedWebView.underPageBackgroundColor.alphaComponent == 0,
            "Provider web views should use the supported transparent background property"
        )
        let darkCanvasHost = BrowserHostView(frame: .init(x: 0, y: 0, width: 400, height: 400))
        darkCanvasHost.appearance = NSAppearance(named: .darkAqua)
        darkCanvasHost.viewDidChangeEffectiveAppearance()
        let darkCanvasColor = darkCanvasHost.layer?.backgroundColor
        expect(
            darkCanvasHost.wantsLayer && darkCanvasColor?.alpha == 1,
            "Browser hosts should provide an opaque canvas behind transparent provider web views"
        )
        expect(
            (darkCanvasColor?.components?.prefix(3).max() ?? 1) < 0.2,
            "Browser hosts should use a dark loading canvas in dark appearance"
        )
        darkCanvasHost.appearance = NSAppearance(named: .aqua)
        darkCanvasHost.viewDidChangeEffectiveAppearance()
        let lightCanvasColor = darkCanvasHost.layer?.backgroundColor
        expect(
            lightCanvasColor?.alpha == 1
                && (lightCanvasColor?.components?.prefix(3).min() ?? 0) > 0.9,
            "Browser hosts should preserve a light loading canvas in light appearance"
        )
        expect(
            browserController.responds(to: filePickerSelector),
            "Browser controller should handle WebKit file-upload panels"
        )
        expect(
            browserController.responds(to: mediaCaptureSelector),
            "Browser controller should persist trusted provider microphone access"
        )
        expect(
            BrowserController.mediaCapturePermissionDecision(
                service: .chatGPT,
                originProtocol: "https",
                originHost: "www.chatgpt.com",
                frameURL: URL(string: "https://www.chatgpt.com/c/123"),
                currentPageURL: URL(string: "https://www.chatgpt.com/c/123"),
                type: .microphone
            ) == .grant,
            "Trusted provider microphone requests should not prompt again"
        )
        expect(
            BrowserController.mediaCapturePermissionDecision(
                service: .chatGPT,
                originProtocol: "https",
                originHost: "www.chatgpt.com",
                frameURL: URL(string: "https://www.chatgpt.com/c/123"),
                currentPageURL: URL(string: "https://www.chatgpt.com/c/123"),
                type: .camera
            ) == .prompt,
            "Camera requests should preserve WebKit's user prompt"
        )
        expect(
            BrowserController.mediaCapturePermissionDecision(
                service: .chatGPT,
                originProtocol: "https",
                originHost: "example.com",
                frameURL: URL(string: "https://www.chatgpt.com/c/123"),
                currentPageURL: URL(string: "https://www.chatgpt.com/c/123"),
                type: .microphone
            ) == .deny,
            "Foreign origins must not receive microphone access"
        )
        expect(
            BrowserController.mediaCapturePermissionDecision(
                service: .chatGPT,
                originProtocol: "https",
                originHost: "www.chatgpt.com",
                frameURL: URL(string: "https://accounts.google.com/signin"),
                currentPageURL: URL(string: "https://www.chatgpt.com/c/123"),
                type: .microphone
            ) == .deny,
            "Authentication frames must not receive microphone access"
        )
        expect(
            BrowserController.mediaCapturePermissionDecision(
                service: .chatGPT,
                originProtocol: "https",
                originHost: "www.chatgpt.com",
                frameURL: URL(string: "https://www.chatgpt.com/login"),
                currentPageURL: URL(string: "https://www.chatgpt.com/login"),
                type: .microphone
            ) == .deny,
            "Provider login pages must not receive microphone access"
        )
        expect(
            BrowserController.mediaCapturePermissionDecision(
                service: .claude,
                originProtocol: "https",
                originHost: "claude.ai",
                frameURL: URL(string: "https://claude.ai/new"),
                currentPageURL: URL(string: "https://claude.ai/login"),
                type: .microphone
            ) == .deny,
            "A trusted frame must not override an authentication main page"
        )
        expect(
            browserController.responds(to: responsePolicySelector),
            "Browser controller should classify downloadable navigation responses"
        )
        expect(
            browserController.responds(to: actionDownloadSelector),
            "Browser controller should adopt action-initiated WebKit downloads"
        )
        expect(
            browserController.responds(to: responseDownloadSelector),
            "Browser controller should adopt response-initiated WebKit downloads"
        )
        expect(
            browserController.responds(to: downloadDestinationSelector),
            "Browser controller should choose destinations for WebKit downloads"
        )
        expect(
            BrowserController.shouldDownloadNavigationResponse(
                canShowMIMEType: true,
                contentDisposition: "attachment; filename=report.pdf"
            ),
            "Attachment responses should become downloads"
        )
        expect(
            !BrowserController.shouldDownloadNavigationResponse(
                canShowMIMEType: true,
                contentDisposition: "inline; filename=attachment-guide.pdf"
            ),
            "Inline responses must not become downloads because of filename text"
        )
        expect(
            BrowserController.shouldDownloadNavigationResponse(
                canShowMIMEType: true,
                contentDisposition: "  AtTaChMeNt ; filename=report.pdf"
            ),
            "Attachment disposition matching should ignore case and surrounding whitespace"
        )
        expect(
            BrowserController.shouldDownloadNavigationResponse(
                canShowMIMEType: false,
                contentDisposition: "inline"
            ),
            "Responses with unsupported MIME types should become downloads"
        )
        do {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("DuetDownloadTests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let destination = directory.appendingPathComponent("saved.txt")
            try "original".write(to: destination, atomically: true, encoding: .utf8)

            let staging = DownloadFileReplacement.stagingURL(for: destination)
            expect(!FileManager.default.fileExists(atPath: staging.path), "A staged download path must start empty")
            try "replacement".write(to: staging, atomically: true, encoding: .utf8)
            let inProgressContent = try String(contentsOf: destination, encoding: .utf8)
            expect(inProgressContent == "original", "An in-progress download must preserve the original")
            try DownloadFileReplacement.commit(staging, to: destination)
            let completedContent = try String(contentsOf: destination, encoding: .utf8)
            expect(completedContent == "replacement", "A completed download should replace the original")

            for reason in ["failure", "cancellation"] {
                let partial = DownloadFileReplacement.stagingURL(for: destination)
                try "partial".write(to: partial, atomically: true, encoding: .utf8)
                DownloadFileReplacement.discard(partial)
                let retainedContent = try String(contentsOf: destination, encoding: .utf8)
                expect(retainedContent == "replacement", "Download \(reason) must preserve the existing file")
                expect(!FileManager.default.fileExists(atPath: partial.path), "Download \(reason) must remove the partial file")
            }

            let existingDirectory = directory.appendingPathComponent("existing-folder")
            try FileManager.default.createDirectory(at: existingDirectory, withIntermediateDirectories: true)
            let failedStaging = DownloadFileReplacement.stagingURL(for: existingDirectory)
            try "replacement".write(to: failedStaging, atomically: true, encoding: .utf8)
            do {
                try DownloadFileReplacement.commit(failedStaging, to: existingDirectory)
                failures.append("A failed final replacement should report an error")
            } catch {
                expect(FileManager.default.fileExists(atPath: existingDirectory.path), "A failed replacement must preserve its destination")
                DownloadFileReplacement.discard(failedStaging)
            }
        } catch {
            failures.append("Download replacement test failed: \(error)")
        }
        let downloadPhaseBrowser = BrowserController(service: .chatGPT)
        downloadPhaseBrowser.beginProvisionalNavigation()
        downloadPhaseBrowser.restorePhaseForMainFrameDownload()
        downloadPhaseBrowser.handleNavigationFailure(
            NSError(domain: "WebKitErrorDomain", code: 102)
        )
        expect(
            downloadPhaseBrowser.phase == .unloaded,
            "A successful download conversion must not leave the provider in a failed or loading phase"
        )
        let failedNavigationBrowser = BrowserController(service: .chatGPT)
        failedNavigationBrowser.beginProvisionalNavigation()
        failedNavigationBrowser.restorePhaseForMainFrameDownload()
        failedNavigationBrowser.handleNavigationFailure(
            NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost)
        )
        if case .failed = failedNavigationBrowser.phase {
            // Expected: only known download interruptions are suppressed.
        } else {
            failures.append("A real navigation failure must remain visible after download classification")
        }
        let supersededBrowser = BrowserController(service: .chatGPT)
        supersededBrowser.beginProvisionalNavigation()
        supersededBrowser.handleNavigationFailure(URLError(.cancelled))
        expect(
            supersededBrowser.phase == .loading,
            "A navigation cancelled because another one replaced it must not show a failure"
        )
        let challengeURL = URL(string: "https://claude.ai/new")!
        let challengeBrowser = BrowserController(service: .claude)
        challengeBrowser.beginProvisionalNavigation()
        challengeBrowser.noteMainFrameResponse(HTTPURLResponse(
            url: challengeURL, statusCode: 403, httpVersion: "HTTP/1.1",
            headerFields: ["cf-mitigated": "challenge"]
        )!)
        challengeBrowser.finishNavigation()
        expect(
            challengeBrowser.phase == .verificationRequired,
            "A Cloudflare challenge response should show the verification state without a page check"
        )
        challengeBrowser.beginProvisionalNavigation()
        challengeBrowser.noteMainFrameResponse(HTTPURLResponse(
            url: challengeURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:]
        )!)
        challengeBrowser.finishNavigation()
        expect(
            challengeBrowser.phase == .ready,
            "The page the challenge hands over to should be ready again"
        )
        let cachedPageBrowser = BrowserController(service: .claude)
        cachedPageBrowser.beginProvisionalNavigation()
        cachedPageBrowser.noteMainFrameResponse(HTTPURLResponse(
            url: challengeURL, statusCode: 403, httpVersion: "HTTP/1.1",
            headerFields: ["cf-mitigated": "challenge"]
        )!)
        cachedPageBrowser.finishNavigation()
        // A back/forward restore can finish without a new response.
        cachedPageBrowser.beginProvisionalNavigation()
        cachedPageBrowser.finishNavigation()
        expect(
            cachedPageBrowser.phase == .ready,
            "A navigation with no response of its own must not inherit an earlier challenge"
        )
        let timedOutBrowser = BrowserController(service: .claude)
        timedOutBrowser.handleNavigationFailure(URLError(.timedOut))
        expect(
            timedOutBrowser.phase.failureMessage == "The page took too long to respond.",
            "A Claude timeout should show a readable explanation"
        )
        let observableBrowser = BrowserController(service: .chatGPT)
        var browserChangeCount = 0
        let browserChangeObserver = observableBrowser.objectWillChange.sink {
            browserChangeCount += 1
        }
        _ = observableBrowser.prepare()
        expect(
            browserChangeCount > 0,
            "Preparing a recreated provider view should notify an existing SwiftUI browser host"
        )
        withExtendedLifetime(browserChangeObserver) {}

        let startupDefaultsSuite = "Duet.HostLifecycleTests.\(UUID().uuidString)"
        guard let startupDefaults = UserDefaults(suiteName: startupDefaultsSuite) else {
            fputs("FAIL: Could not create isolated startup defaults\n", stderr)
            exit(1)
        }
        startupDefaults.removePersistentDomain(forName: startupDefaultsSuite)
        defer { startupDefaults.removePersistentDomain(forName: startupDefaultsSuite) }

        let claudeStartupState = AppState(startupDestination: .claude, userDefaults: startupDefaults)
        expect(!claudeStartupState.isLaunchChooserVisible, "Claude startup should skip the tool chooser")
        expect(claudeStartupState.selectedService == .claude, "Claude startup should select Claude")
        expect(!claudeStartupState.isSplitView, "Claude startup should use one pane")
        expect(!claudeStartupState.isPromptDrawerOpen, "Single-provider startup should keep the prompt drawer collapsed")
        expect(
            claudeStartupState.browser(for: .claude).webView != nil
                && claudeStartupState.browser(for: .chatGPT).webView == nil,
            "Claude startup should prepare only Claude"
        )

        let bothStartupState = AppState(startupDestination: .both, userDefaults: startupDefaults)
        expect(!bothStartupState.isLaunchChooserVisible, "Both startup should skip the tool chooser")
        expect(bothStartupState.isSplitView, "Both startup should use split view")
        expect(bothStartupState.isPromptDrawerOpen, "Both startup should immediately open the prompt drawer")
        expect(
            ChatService.allCases.allSatisfy { bothStartupState.browser(for: $0).webView != nil },
            "Both startup should prepare both providers"
        )

        startupDefaults.set(StartupDestination.claude.rawValue, forKey: AppPreferenceKey.lastWorkspaceDestination)
        let lastUsedStartupState = AppState(startupDestination: .lastUsed, userDefaults: startupDefaults)
        expect(!lastUsedStartupState.isLaunchChooserVisible, "Last Used should skip the chooser when a destination exists")
        expect(lastUsedStartupState.selectedService == .claude, "Last Used should restore the saved provider")
        startupDefaults.removeObject(forKey: AppPreferenceKey.lastWorkspaceDestination)
        let emptyLastUsedStartupState = AppState(startupDestination: .lastUsed, userDefaults: startupDefaults)
        expect(emptyLastUsedStartupState.isLaunchChooserVisible, "Last Used should show the chooser without a saved destination")

        let splitPreparationState = AppState()
        var providersWerePreparedBeforeSplitPublished = false
        let splitStateObserver = splitPreparationState.$isSplitView.dropFirst().sink { isSplitView in
            if isSplitView {
                providersWerePreparedBeforeSplitPublished = ChatService.allCases.allSatisfy {
                    splitPreparationState.browser(for: $0).webView != nil
                }
            }
        }
        splitPreparationState.setSplitView(true)
        expect(
            providersWerePreparedBeforeSplitPublished,
            "Both provider views must exist before split state is published to SwiftUI"
        )
        expect(splitPreparationState.isPromptDrawerOpen, "Entering split view should open the prompt drawer")
        splitPreparationState.isPromptDrawerOpen = false
        splitPreparationState.setSplitView(true)
        expect(!splitPreparationState.isPromptDrawerOpen, "Remaining in split view should preserve a collapsed drawer")
        splitPreparationState.setSplitView(false)
        splitPreparationState.setSplitView(true)
        expect(splitPreparationState.isPromptDrawerOpen, "Reentering split view should reopen the prompt drawer")
        withExtendedLifetime(splitStateObserver) {}

        let workspaceState = AppState(userDefaults: startupDefaults)
        expect(workspaceState.isLaunchChooserVisible, "Workspace should begin at the tool chooser")
        expect(!workspaceState.canStartNewConversation, "New Conversation needs a provider workspace")
        expect(
            ![PromptTarget.service(.chatGPT), .service(.claude), .both].contains(where: workspaceState.isShowingWorkspace),
            "The tool chooser should not mark any workspace as shown"
        )
        workspaceState.openWorkspace(for: .service(.claude))
        expect(workspaceState.canStartNewConversation, "New Conversation should be available in a provider workspace")
        expect(
            workspaceState.isShowingWorkspace(for: .service(.claude))
                && !workspaceState.isShowingWorkspace(for: .service(.chatGPT))
                && !workspaceState.isShowingWorkspace(for: .both),
            "Only the Claude workspace should be marked as shown"
        )
        expect(!workspaceState.isLaunchChooserVisible, "A provider destination should leave the tool chooser")
        expect(workspaceState.selectedService == .claude, "Claude destination should select Claude")
        expect(!workspaceState.isSplitView, "A single-provider destination should use one pane")
        expect(
            startupDefaults.string(forKey: AppPreferenceKey.lastWorkspaceDestination) == StartupDestination.claude.rawValue,
            "Opening Claude should remember it as the last workspace destination"
        )
        let releasableClaudeView = workspaceState.browser(for: .claude).webView
        workspaceState.openWorkspace(for: .service(.chatGPT))
        try? await Task.sleep(for: .milliseconds(350))
        expect(
            releasableClaudeView != nil && workspaceState.browser(for: .claude).webView == nil,
            "The default single-pane mode should release its inactive web view after the UI transition"
        )
        workspaceState.setKeepsProvidersLoaded(true)
        workspaceState.openWorkspace(for: .service(.claude))
        let retainedClaudeView = workspaceState.browser(for: .claude).webView
        workspaceState.openWorkspace(for: .service(.chatGPT))
        workspaceState.browserDidMount(.chatGPT)
        expect(
            retainedClaudeView != nil && workspaceState.browser(for: .claude).webView === retainedClaudeView,
            "The faster-switching setting should keep the inactive web view alive"
        )
        workspaceState.openWorkspace(for: .both)
        expect(workspaceState.isSplitView, "Both destination should use split view")
        expect(
            workspaceState.isShowingWorkspace(for: .both) && !workspaceState.isShowingWorkspace(for: .service(.chatGPT)),
            "Only the Both workspace should be marked as shown in split view"
        )
        expect(workspaceState.isPromptDrawerOpen, "Choosing Both should immediately open the prompt drawer")
        expect(
            startupDefaults.string(forKey: AppPreferenceKey.lastWorkspaceDestination) == StartupDestination.both.rawValue,
            "Opening Both should remember split view as the last workspace destination"
        )
        workspaceState.browserDidMount(.chatGPT)
        workspaceState.browserDidMount(.claude)
        let splitWorkspaceMounted = await workspaceState.waitForWorkspaceMount(
            for: .both,
            timeout: 0.01
        )
        expect(splitWorkspaceMounted, "Both split-pane browser hosts should mount before quick-prompt dispatch")
        workspaceState.openWorkspace(for: .service(.claude))
        expect(workspaceState.selectedService == .claude, "Later Claude destination should select Claude")
        expect(!workspaceState.isSplitView, "Later single-provider destination should leave split view")
        expect(
            workspaceState.browser(for: .chatGPT).webView != nil,
            "Leaving split view should retain the inactive provider when faster switching is enabled"
        )
        workspaceState.setKeepsProvidersLoaded(false)
        try? await Task.sleep(for: .milliseconds(350))
        expect(
            workspaceState.browser(for: .chatGPT).webView == nil,
            "Turning faster switching off should release the inactive provider after the UI transition"
        )

        let promptDrawerState = AppState()
        promptDrawerState.isPromptDrawerOpen = true
        promptDrawerState.prompt = "First prompt"
        let submittedDraft = promptDrawerState.capturePromptDraft()
        promptDrawerState.prompt = "Second unsent draft"
        promptDrawerState.clearPrompt(ifUnchanged: submittedDraft)
        expect(promptDrawerState.prompt == "Second unsent draft", "A successful earlier send must preserve a newer draft")
        expect(promptDrawerState.isPromptDrawerOpen, "An earlier send must leave a newer draft visible")
        promptDrawerState.prompt = "First prompt"
        promptDrawerState.clearPrompt(ifUnchanged: submittedDraft)
        expect(promptDrawerState.prompt == "First prompt", "Returning to identical text must still count as a newer edit")
        promptDrawerState.clearPrompt(ifUnchanged: promptDrawerState.capturePromptDraft())
        expect(promptDrawerState.prompt.isEmpty, "An unchanged submitted draft should clear after success")
        expect(!promptDrawerState.isPromptDrawerOpen, "An unchanged submitted draft should collapse the drawer after success")
        promptDrawerState.openWorkspace(for: .service(.chatGPT))
        promptDrawerState.browserDidMount(.chatGPT)
        var promptDrawerPreparationCompleted = false
        let promptDrawerPreparation = Task {
            let prepared = await promptDrawerState.preparePromptDrawerWorkspace(
                for: .both,
                timeout: 0.5
            )
            promptDrawerPreparationCompleted = true
            return prepared
        }
        for _ in 0..<20 {
            if promptDrawerState.isSplitView { break }
            await Task.yield()
        }
        expect(promptDrawerState.isSplitView, "Sending the prompt drawer to Both should open split view")
        expect(
            ChatService.allCases.allSatisfy { promptDrawerState.browser(for: $0).webView != nil },
            "Prompt drawer Both should prepare both provider views"
        )
        promptDrawerState.browserDidMount(.claude)
        try? await Task.sleep(for: .milliseconds(75))
        expect(
            !promptDrawerPreparationCompleted,
            "A stale single-pane mount must not satisfy prompt drawer split readiness"
        )
        promptDrawerState.browserDidMount(.chatGPT)
        let promptDrawerPrepared = await promptDrawerPreparation.value
        expect(
            promptDrawerPrepared,
            "Prompt drawer Both should wait for both split-pane browser hosts"
        )

        let splitView = NSSplitView(frame: NSRect(x: 0, y: 0, width: 1_000, height: 600))
        splitView.isVertical = true
        splitView.addSubview(NSView(frame: .zero))
        splitView.addSubview(NSView(frame: .zero))
        let splitWindow = NSWindow(
            contentRect: splitView.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        splitWindow.contentView = splitView
        splitWindow.orderFront(nil)
        splitView.adjustSubviews()
        var savedRatio = 0.7
        for _ in 0..<3 {
            splitView.setPosition(500, ofDividerAt: 0)
            let marker = SplitRatioMarkerView(ratio: savedRatio, minimumPaneWidth: 280)
            splitView.subviews[0].addSubview(marker)
            try? await Task.sleep(for: .milliseconds(100))
            savedRatio = splitView.subviews[0].frame.width / splitView.bounds.width
            expect(abs(savedRatio - 0.7) < 0.001, "Restoring split view repeatedly must not drift from the saved ratio")
            marker.removeFromSuperview()
        }
        splitWindow.orderOut(nil)

        workspaceState.openQuickPromptWorkspace(for: .both)
        expect(workspaceState.isSplitView, "Quick Prompt Both destination should use a fresh split workspace")
        workspaceState.browserDidMount(.chatGPT)
        workspaceState.browserDidMount(.claude)
        workspaceState.openQuickPromptWorkspace(for: .both)
        let staleSplitWorkspaceMounted = await workspaceState.waitForWorkspaceMount(
            for: .both,
            timeout: 0.01
        )
        expect(
            !staleSplitWorkspaceMounted,
            "Recreated split-pane browsers must not inherit stale mount state"
        )
        workspaceState.browserDidMount(.chatGPT)
        workspaceState.browserDidMount(.claude)
        let recreatedSplitWorkspaceMounted = await workspaceState.waitForWorkspaceMount(
            for: .both,
            timeout: 0.01
        )
        expect(recreatedSplitWorkspaceMounted, "Recreated split-pane browser hosts should report their new mounts")

        let singleQuickPromptState = AppState()
        singleQuickPromptState.openQuickPromptWorkspace(for: .service(.claude))
        singleQuickPromptState.browserDidMount(.chatGPT)
        let wrongSingleWorkspaceMounted = await singleQuickPromptState.waitForWorkspaceMount(
            for: .service(.claude),
            timeout: 0.01
        )
        expect(
            !wrongSingleWorkspaceMounted,
            "An unrelated browser mount must not start a single-provider Quick Prompt dispatch"
        )
        singleQuickPromptState.browserDidMount(.claude)
        let singleWorkspaceMounted = await singleQuickPromptState.waitForWorkspaceMount(
            for: .service(.claude),
            timeout: 0.01
        )
        expect(singleWorkspaceMounted, "Claude must mount before a single-provider Quick Prompt dispatch")

        let quickPromptDrawerState = AppState()
        quickPromptDrawerState.openQuickPromptWorkspace(for: .both)
        expect(quickPromptDrawerState.isSplitView, "Quick Prompt Both should enter split view")
        expect(!quickPromptDrawerState.isPromptDrawerOpen, "Quick Prompt Both must not open the shared drawer")

        quickPromptDrawerState.isPromptDrawerOpen = true
        quickPromptDrawerState.openQuickPromptWorkspace(for: .both)
        expect(!quickPromptDrawerState.isPromptDrawerOpen, "Quick Prompt Both should collapse an empty drawer in split view")

        quickPromptDrawerState.isPromptDrawerOpen = true
        quickPromptDrawerState.openQuickPromptWorkspace(for: .service(.claude))
        expect(!quickPromptDrawerState.isPromptDrawerOpen, "Single-provider Quick Prompt should collapse an empty drawer")

        quickPromptDrawerState.isPromptDrawerOpen = true
        quickPromptDrawerState.prompt = "  \n"
        quickPromptDrawerState.openQuickPromptWorkspace(for: .service(.chatGPT))
        expect(!quickPromptDrawerState.isPromptDrawerOpen, "Quick Prompt should collapse a whitespace-only drawer")

        quickPromptDrawerState.isPromptDrawerOpen = true
        quickPromptDrawerState.prompt = "Existing shared draft"
        quickPromptDrawerState.openQuickPromptWorkspace(for: .both)
        expect(quickPromptDrawerState.isPromptDrawerOpen, "Quick Prompt must leave an existing shared draft visible")
        expect(quickPromptDrawerState.prompt == "Existing shared draft", "Quick Prompt must preserve an existing shared draft")

        quickPromptDrawerState.isPromptDrawerOpen = false
        quickPromptDrawerState.openQuickPromptWorkspace(for: .service(.claude))
        quickPromptDrawerState.openQuickPromptWorkspace(for: .both)
        expect(!quickPromptDrawerState.isPromptDrawerOpen, "Quick Prompt must not reveal a collapsed shared draft")
        expect(quickPromptDrawerState.prompt == "Existing shared draft", "Quick Prompt must keep a collapsed shared draft")

        quickPromptDrawerState.setSplitView(false)
        quickPromptDrawerState.setSplitView(true)
        expect(quickPromptDrawerState.isPromptDrawerOpen, "Entering split view by hand should still open the drawer after a Quick Prompt")

        singleQuickPromptState.reportWorkspaceUnavailable(for: .service(.claude))
        expect(
            singleQuickPromptState.dispatchNotice?.results == [
                PromptDispatchResult(service: .claude, outcome: .unavailable)
            ],
            "A failed Quick Prompt mount should surface the affected provider without dispatching"
        )

        do {
            try await testComposerFixture(
                named: "contenteditable.html",
                service: .chatGPT,
                failures: &failures
            )
            try await testComposerFixture(
                named: "contenteditable.html",
                service: .claude,
                failures: &failures
            )
            try await testComposerFixture(
                named: "chatgpt-composer.html",
                service: .chatGPT,
                failures: &failures
            )
            for service in ChatService.allCases {
                try await testComposerFixture(
                    named: "hidden-composer.html",
                    service: service,
                    failures: &failures
                )
            }
            // Return that adds a new line instead of sending.
            try await testComposerFixture(
                named: "send-no-op.html",
                service: .chatGPT,
                expectsConfirmation: false,
                failures: &failures
            )
            try await testStandInComposer(named: "claude-static-composer.html", service: .claude, failures: &failures)
            try await testStandInComposer(named: "chatgpt-pending-composer.html", service: .chatGPT, failures: &failures)
            try await testReturnKeyPastPromptDrawer(failures: &failures)
            try await testSendToBothPastPromptDrawer(failures: &failures)
            try await testClaudeSubmissionTiming(failures: &failures)
            try await testRepeatedPromptConfirmation(failures: &failures)
            try await testExistingDraftProtection(failures: &failures)
            try await testSignedOutFixture(failures: &failures)
            try await testClaudePageChecks(failures: &failures)
            try await testClaudeFileDropCompatibility(failures: &failures)
            try await testPrintingBridgeFixture(failures: &failures)
            try await testLocationBridgeFixture(failures: &failures)
            try await testNotificationBridgeFixture(failures: &failures)
            try await testResponseWatcherFixture(failures: &failures)
        } catch {
            failures.append("Fixture integration test threw: \(error)")
        }

        await testInactiveReleaseWaitsForHost(failures: &failures)
        await testHostHandOffRechecksWorkspace(failures: &failures)
        await testRapidProviderReversals(failures: &failures)
        await testRapidSplitReversals(failures: &failures)
        await testRetentionChangesDuringPendingCleanup(failures: &failures)
        await testRepeatedTransitionSoak(failures: &failures)
        await testDrawerPromptFocus(failures: &failures)

        if failures.isEmpty {
            print("Browser host and fixture integration tests passed.")
        } else {
            failures.forEach { fputs("FAIL: \($0)\n", stderr) }
            exit(1)
        }
    }

    /// Mounts a provider's current web view in a pane host, as SwiftUI does.
    @MainActor
    private static func mountedHost(for service: ChatService, in state: AppState) -> BrowserHostView {
        let host = BrowserHostView(frame: .init(x: 0, y: 0, width: 400, height: 400))
        if let webView = state.browser(for: service).webView {
            host.install(webView)
        }
        return host
    }

    /// Lets a host's hand-off reach AppState, which hears about it a turn later.
    @MainActor
    private static func settle() async {
        try? await Task.sleep(for: .milliseconds(20))
    }

    /// The drawer must end up with keyboard focus even when SwiftUI drops
    /// its first request and a provider page keeps first responder.
    @MainActor
    private static func testDrawerPromptFocus(failures: inout [String]) async {
        let state = AppState()
        let window = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 400, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let field = NSTextView(frame: .init(x: 0, y: 0, width: 400, height: 100))
        window.contentView?.addSubview(field)
        if let webView = state.browser(for: .chatGPT).webView {
            webView.frame = .init(x: 0, y: 100, width: 400, height: 300)
            window.contentView?.addSubview(webView)
            window.makeFirstResponder(webView)
        }
        expect(
            state.providerPageHoldsKeyboardFocus,
            "A provider page that is first responder should count as holding keyboard focus",
            failures: &failures
        )

        // The first request is dropped, as SwiftUI sometimes does when the
        // drawer appears. Later ones go through.
        var requests: [Bool] = []
        let focused = await PromptFocus.take(
            checkDelay: .milliseconds(1),
            setFocused: { isFocused in
                requests.append(isFocused)
                if isFocused, requests.count > 1 { window.makeFirstResponder(field) }
            },
            isFocused: { !state.providerPageHoldsKeyboardFocus }
        )
        expect(focused, "The drawer should take focus after its first request is dropped", failures: &failures)
        expect(
            window.firstResponder === field,
            "A dropped drawer focus request must not leave the provider page with keyboard focus",
            failures: &failures
        )
        expect(
            requests == [true, false, true],
            "A repeated drawer focus request should clear the focus state before setting it again",
            failures: &failures
        )
        expect(
            !state.providerPageHoldsKeyboardFocus,
            "A provider page should not count as holding focus once the drawer field has it",
            failures: &failures
        )

        var immediateRequests = 0
        let immediatelyFocused = await PromptFocus.take(
            checkDelay: .milliseconds(1),
            setFocused: { if $0 { immediateRequests += 1 } },
            isFocused: { true }
        )
        expect(
            immediatelyFocused && immediateRequests == 1,
            "A drawer focus request that takes should not be repeated",
            failures: &failures
        )

        var refusedRequests = 0
        let refusedFocus = await PromptFocus.take(
            attempts: 3,
            checkDelay: .milliseconds(1),
            setFocused: { if $0 { refusedRequests += 1 } },
            isFocused: { false }
        )
        expect(
            !refusedFocus && refusedRequests == 3,
            "A drawer focus request should give up after its attempts rather than keep taking focus",
            failures: &failures
        )

        // The user clicks into a page or presses Tab while the drawer is
        // still checking its first request. That move is deliberate, so the
        // drawer must not take focus back.
        var userMovedFocus = false
        var interruptedRequests = 0
        let interruptedFocus = await PromptFocus.take(
            checkDelay: .milliseconds(1),
            setFocused: { isFocused in
                guard isFocused else { return }
                interruptedRequests += 1
                userMovedFocus = true
            },
            isFocused: { false },
            userMovedFocus: { userMovedFocus }
        )
        expect(
            !interruptedFocus && interruptedRequests == 1,
            "A click or Tab from the user must stop the drawer from taking focus back",
            failures: &failures
        )

        window.makeKeyAndOrderFront(nil)
        let userFocusEvents = UserFocusEventMonitor()
        func keyDown(_ keyCode: UInt16, _ characters: String) -> NSEvent? {
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: false,
                keyCode: keyCode
            )
        }
        if let letter = keyDown(7, "x") { NSApp.sendEvent(letter) }
        expect(
            !userFocusEvents.sawUserFocusEvent,
            "Typing a letter should not count as the user moving focus",
            failures: &failures
        )
        if let tab = keyDown(48, "\t") { NSApp.sendEvent(tab) }
        expect(
            userFocusEvents.sawUserFocusEvent,
            "Pressing Tab should count as the user moving focus",
            failures: &failures
        )
        userFocusEvents.stop()

        var cancelledRequests = 0
        let cancelledFocus = Task { @MainActor in
            await PromptFocus.take(
                checkDelay: .seconds(10),
                setFocused: { if $0 { cancelledRequests += 1 } },
                isFocused: { false }
            )
        }
        await Task.yield()
        cancelledFocus.cancel()
        let cancelledResult = await cancelledFocus.value
        expect(
            !cancelledResult && cancelledRequests <= 1,
            "Closing the drawer should stop its pending focus requests",
            failures: &failures
        )
        window.orderOut(nil)
    }

    @MainActor
    private static func testInactiveReleaseWaitsForHost(failures: inout [String]) async {
        let state = AppState()
        let chatGPTHost = mountedHost(for: .chatGPT, in: state)
        state.select(.claude)
        let claudeHost = mountedHost(for: .claude, in: state)
        await settle()
        expect(
            state.browser(for: .chatGPT).webView != nil,
            "The outgoing provider must stay loaded while its pane still holds it",
            failures: &failures
        )

        chatGPTHost.clear()
        await settle()
        expect(
            state.browser(for: .chatGPT).webView == nil,
            "The outgoing provider should be released once its pane lets go of it",
            failures: &failures
        )
        expect(
            state.browser(for: .claude).webView?.superview === claudeHost,
            "Releasing the outgoing provider must leave the visible pane alone",
            failures: &failures
        )

        let unhostedState = AppState()
        unhostedState.select(.claude)
        expect(
            unhostedState.browser(for: .chatGPT).webView == nil,
            "An inactive provider no pane holds should be released right away",
            failures: &failures
        )
    }

    @MainActor
    private static func testHostHandOffRechecksWorkspace(failures: inout [String]) async {
        let reselectedState = AppState()
        let reselectedHost = mountedHost(for: .chatGPT, in: reselectedState)
        let reselectedView = reselectedState.browser(for: .chatGPT).webView
        reselectedState.select(.claude)
        reselectedState.select(.chatGPT)
        reselectedHost.clear()
        await settle()
        expect(
            reselectedState.browser(for: .chatGPT).webView === reselectedView,
            "A hand-off must not release a provider that was selected again",
            failures: &failures
        )

        let splitState = AppState()
        let splitHost = mountedHost(for: .chatGPT, in: splitState)
        splitState.select(.claude)
        splitState.setSplitView(true)
        splitHost.clear()
        await settle()
        expect(
            ChatService.allCases.allSatisfy { splitState.browser(for: $0).webView != nil },
            "A hand-off must not release a provider while split view shows it",
            failures: &failures
        )

        let movedState = AppState()
        movedState.setSplitView(true)
        let chatGPTSplitHost = mountedHost(for: .chatGPT, in: movedState)
        let claudeSplitHost = mountedHost(for: .claude, in: movedState)
        let chatGPTView = movedState.browser(for: .chatGPT).webView
        movedState.setSplitView(false)
        let singleHost = mountedHost(for: .chatGPT, in: movedState)
        await settle()
        expect(
            movedState.browser(for: .claude).webView?.superview === claudeSplitHost,
            "Leaving split view must keep the inactive pane's view until its pane goes away",
            failures: &failures
        )
        chatGPTSplitHost.clear()
        claudeSplitHost.clear()
        await settle()
        expect(
            movedState.browser(for: .claude).webView == nil,
            "Leaving split view should release the inactive provider once its pane goes away",
            failures: &failures
        )
        expect(
            movedState.browser(for: .chatGPT).webView === chatGPTView && chatGPTView?.superview === singleHost,
            "Leaving split view must keep the selected provider in its single pane",
            failures: &failures
        )
    }

    @MainActor
    private static func testRapidProviderReversals(failures: inout [String]) async {
        let state = AppState()
        let chatGPTHost = mountedHost(for: .chatGPT, in: state)
        let originalChatGPTView = state.browser(for: .chatGPT).webView

        for _ in 0..<10 {
            state.select(.claude)
            state.select(.chatGPT)
        }
        await settle()
        expect(
            state.selectedService == .chatGPT && state.browser(for: .chatGPT).webView === originalChatGPTView,
            "Rapid Claude-to-ChatGPT reversals must not release or replace the final selected provider",
            failures: &failures
        )
        expect(
            state.browser(for: .claude).webView == nil,
            "Rapid Claude-to-ChatGPT reversals should release inactive Claude",
            failures: &failures
        )

        state.select(.claude)
        let claudeHost = mountedHost(for: .claude, in: state)
        chatGPTHost.clear()
        await settle()
        let originalClaudeView = state.browser(for: .claude).webView
        for _ in 0..<10 {
            state.select(.chatGPT)
            state.select(.claude)
        }
        await settle()
        expect(
            state.selectedService == .claude
                && originalClaudeView != nil
                && state.browser(for: .claude).webView === originalClaudeView
                && originalClaudeView?.superview === claudeHost,
            "Rapid ChatGPT-to-Claude reversals must not release or replace the final selected provider",
            failures: &failures
        )
        expect(
            state.browser(for: .chatGPT).webView == nil,
            "Rapid ChatGPT-to-Claude reversals should release inactive ChatGPT",
            failures: &failures
        )
    }

    @MainActor
    private static func testRapidSplitReversals(failures: inout [String]) async {
        for selectedService in ChatService.allCases {
            let releasingState = AppState()
            releasingState.select(selectedService)

            releasingState.setSplitView(true)
            releasingState.setSplitView(false)
            releasingState.setSplitView(true)
            await settle()
            expect(releasingState.isSplitView, "Rapid split reversal should stop in split view", failures: &failures)
            expect(
                ChatService.allCases.allSatisfy { releasingState.browser(for: $0).webView != nil },
                "Rapid split reversal should leave exactly one prepared view per provider",
                failures: &failures
            )

            releasingState.setSplitView(false)
            releasingState.setSplitView(true)
            releasingState.setSplitView(false)
            await settle()
            expect(!releasingState.isSplitView, "Rapid split reversal should stop in single-pane view", failures: &failures)
            expect(
                releasingState.browser(for: selectedService).webView != nil,
                "Rapid split reversal must preserve the selected provider in single-pane view",
                failures: &failures
            )
            expect(
                ChatService.allCases
                    .filter { $0 != selectedService }
                    .allSatisfy { releasingState.browser(for: $0).webView == nil },
                "Rapid split reversal should release the inactive provider in single-pane view",
                failures: &failures
            )

            let retainingState = AppState()
            retainingState.select(selectedService)
            retainingState.setKeepsProvidersLoaded(true)
            let retainedViews = Dictionary(
                uniqueKeysWithValues: ChatService.allCases.map { ($0, retainingState.browser(for: $0).webView) }
            )
            for _ in 0..<10 {
                retainingState.setSplitView(true)
                retainingState.setSplitView(false)
                retainingState.setSplitView(true)
            }
            await settle()
            expect(retainingState.isSplitView, "Retained rapid split reversal should stop in split view", failures: &failures)
            expect(
                ChatService.allCases.allSatisfy {
                    retainingState.browser(for: $0).webView === retainedViews[$0]!
                },
                "Retention should reuse the same two provider views through rapid split reversals",
                failures: &failures
            )
        }
    }

    @MainActor
    private static func testRetentionChangesDuringPendingCleanup(failures: inout [String]) async {
        let state = AppState()
        let chatGPTHost = mountedHost(for: .chatGPT, in: state)
        let pendingChatGPTView = state.browser(for: .chatGPT).webView
        state.select(.claude)
        state.setKeepsProvidersLoaded(true)
        chatGPTHost.clear()
        await settle()
        expect(
            state.browser(for: .chatGPT).webView === pendingChatGPTView
                && state.browser(for: .claude).webView != nil,
            "Enabling retention must cancel obsolete inactive-provider cleanup",
            failures: &failures
        )

        state.setKeepsProvidersLoaded(false)
        await settle()
        expect(
            state.browser(for: .claude).webView != nil && state.browser(for: .chatGPT).webView == nil,
            "Disabling retention in single-pane mode should release only the inactive provider",
            failures: &failures
        )

        state.setKeepsProvidersLoaded(true)
        state.setSplitView(true)
        let splitViews = Dictionary(
            uniqueKeysWithValues: ChatService.allCases.map { ($0, state.browser(for: $0).webView) }
        )
        state.setKeepsProvidersLoaded(false)
        await settle()
        expect(
            ChatService.allCases.allSatisfy { state.browser(for: $0).webView === splitViews[$0]! },
            "Disabling retention must not release either provider while split view is active",
            failures: &failures
        )

        state.setSplitView(false)
        await settle()
        expect(
            state.browser(for: .claude).webView != nil && state.browser(for: .chatGPT).webView == nil,
            "Leaving split view should resume cleanup after retention was disabled",
            failures: &failures
        )
    }

    @MainActor
    private static func testRepeatedTransitionSoak(failures: inout [String]) async {
        let releasingState = AppState()
        var selectedHost = mountedHost(for: .chatGPT, in: releasingState)
        for _ in 0..<25 {
            for service in [ChatService.claude, .chatGPT] {
                releasingState.select(service)
                let nextHost = mountedHost(for: service, in: releasingState)
                selectedHost.clear()
                selectedHost = nextHost
                await Task.yield()
            }
            releasingState.setSplitView(true)
            releasingState.setSplitView(false)
            await Task.yield()
        }
        await settle()
        expect(
            releasingState.selectedService == .chatGPT
                && releasingState.browser(for: .chatGPT).webView?.superview === selectedHost
                && releasingState.browser(for: .claude).webView == nil,
            "Retention-off transition soak should settle with only the selected provider prepared",
            failures: &failures
        )

        let retainingState = AppState()
        retainingState.setKeepsProvidersLoaded(true)
        let retainedViews = Dictionary(
            uniqueKeysWithValues: ChatService.allCases.map { ($0, retainingState.browser(for: $0).webView) }
        )
        for _ in 0..<50 {
            retainingState.select(.claude)
            retainingState.select(.chatGPT)
            retainingState.setSplitView(true)
            retainingState.setSplitView(false)
        }
        await settle()
        expect(
            ChatService.allCases.allSatisfy { retainingState.browser(for: $0).webView === retainedViews[$0]! },
            "Retention-on transition soak should keep the same two provider views",
            failures: &failures
        )
    }

    @MainActor
    private static func testComposerFixture(
        named name: String,
        service: ChatService,
        expectsConfirmation: Bool = true,
        failures: inout [String]
    ) async throws {
        let (webView, loader) = makeFixtureWebView()
        defer {
            webView.navigationDelegate = nil
            webView.stopLoading()
        }
        try await loader.load(fixtureURL(name), in: webView)

        let adapter = ProviderAdapter.adapter(for: service)
        let prompt = "A quote: \" and a newline\nnext line"
        let ready: Bool = try await evaluate(adapter.readinessScript(), in: webView)
        expect(ready, "\(name) composer was not detected", failures: &failures)

        let fill: ScriptResult = try await evaluate(adapter.fillScript(prompt: prompt), in: webView)
        expect(fill.ok, "\(name) composer was not filled", failures: &failures)

        let beforeReturn: Bool = try await evaluate(
            adapter.submissionConfirmationScript(),
            in: webView
        )
        expect(!beforeReturn, "\(name) reported submission before Return", failures: &failures)

        let target: ScriptResult = try await evaluate(adapter.returnKeyTargetScript(prompt: prompt), in: webView)
        expect(target.ok, "\(name) composer wasn't ready for Return: \(target.reason ?? "")", failures: &failures)
        webView.pressReturnKey()

        let confirmed = try await waitForSubmissionConfirmation(adapter: adapter, in: webView)
        expect(
            confirmed == expectsConfirmation,
            "\(name) returned the wrong submission confirmation",
            failures: &failures
        )
        let holdsPrompt: Bool = try await evaluate(adapter.composerHoldsPromptScript(prompt: prompt), in: webView)
        expect(
            holdsPrompt == !expectsConfirmation,
            "\(name) must report a composer that Return didn't send",
            failures: &failures
        )

        if name == "chatgpt-composer.html" {
            _ = try await evaluate(
                "(() => { document.querySelector('#prompt-textarea').remove(); return true; })()",
                in: webView
            ) as Bool
            let missingComposer: Bool = try await evaluate(
                adapter.submissionConfirmationScript(),
                in: webView
            )
            expect(!missingComposer, "A missing composer must not confirm during navigation", failures: &failures)

            _ = try await evaluate(
                """
                (() => {
                  const composer = document.createElement('div');
                  composer.id = 'prompt-textarea';
                  composer.contentEditable = 'true';
                  composer.textContent = 'Ask anything';
                  composer.setAttribute('aria-hidden', 'true');
                  document.body.appendChild(composer);
                  return true;
                })()
                """,
                in: webView
            ) as Bool
            let hiddenComposer: Bool = try await evaluate(
                adapter.submissionConfirmationScript(),
                in: webView
            )
            expect(!hiddenComposer, "A hidden composer must not confirm submission", failures: &failures)

            _ = try await evaluate(
                "(() => { document.querySelector('#prompt-textarea').removeAttribute('aria-hidden'); return true; })()",
                in: webView
            ) as Bool
            let replacementComposer: Bool = try await evaluate(
                adapter.submissionConfirmationScript(),
                in: webView
            )
            expect(!replacementComposer, "A visible replacement composer containing text must not confirm", failures: &failures)
        }
    }

    /// With the prompt drawer holding keyboard focus, Duet's Return keypress
    /// must still send, and must be the only thing allowed to move focus into
    /// the page.
    @MainActor
    private static func testReturnKeyPastPromptDrawer(failures: inout [String]) async throws {
        let window = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 800, height: 640),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let container = NSView(frame: window.contentView?.bounds ?? .zero)
        window.contentView = container
        let drawerField = NSTextField(frame: .init(x: 0, y: 600, width: 400, height: 24))
        let (webView, loader) = makeFixtureWebView()
        container.addSubview(webView)
        container.addSubview(drawerField)
        defer {
            webView.navigationDelegate = nil
            webView.stopLoading()
            webView.removeFromSuperview()
        }
        try await loader.load(fixtureURL("contenteditable.html"), in: webView)

        webView.reservesFocusForPrompt = { true }
        window.makeFirstResponder(drawerField)
        window.makeFirstResponder(webView)
        expect(
            window.firstResponder !== webView,
            "The drawer test page must not take focus on its own",
            failures: &failures
        )

        let adapter = ProviderAdapter.adapter(for: .claude)
        let prompt = "Sent past the drawer"
        let fill: ScriptResult = try await evaluate(adapter.fillScript(prompt: prompt), in: webView)
        expect(fill.ok, "The drawer test composer was not filled", failures: &failures)
        let target: ScriptResult = try await evaluate(adapter.returnKeyTargetScript(prompt: prompt), in: webView)
        expect(target.ok, "The drawer test composer wasn't ready for Return", failures: &failures)
        webView.pressReturnKey()
        expect(
            window.firstResponder === webView,
            "Return must take focus for the page even while the drawer reserves it",
            failures: &failures
        )
        let confirmed = try await waitForSubmissionConfirmation(adapter: adapter, in: webView)
        expect(confirmed, "Return must send while the prompt drawer holds focus", failures: &failures)

        window.makeFirstResponder(drawerField)
        window.makeFirstResponder(webView)
        expect(
            window.firstResponder !== webView,
            "After Return, the page must again be kept from taking focus",
            failures: &failures
        )
    }

    /// Send to Both through the controllers, with the prompt drawer holding
    /// focus in the same window: each fill must go through WebKit's own
    /// editing (a trusted input event, not the fallback), each Return must
    /// send, and focus must go back to the drawer once, after both.
    @MainActor
    private static func testSendToBothPastPromptDrawer(failures: inout [String]) async throws {
        let fixtureHTML = try String(contentsOf: fixtureURL("contenteditable.html"), encoding: .utf8)
        let window = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 1000, height: 640),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let container = NSView(frame: window.contentView?.bounds ?? .zero)
        window.contentView = container
        let drawerField = NSTextField(frame: .init(x: 0, y: 600, width: 400, height: 24))
        container.addSubview(drawerField)

        var restores = 0
        var browsers: [BrowserController] = []
        for (index, service) in ChatService.allCases.enumerated() {
            let browser = BrowserController(service: service)
            let webView = browser.prepare()
            webView.frame = NSRect(x: CGFloat(index) * 500, y: 0, width: 500, height: 590)
            container.addSubview(webView)
            webView.configuration.userContentController.removeAllUserScripts()
            browser.reservesFocusForPrompt = true
            browser.restorePromptFocus = {
                restores += 1
                window.makeFirstResponder(drawerField)
            }
            webView.loadHTMLString(fixtureHTML, baseURL: service.startURL)
            browsers.append(browser)
        }
        defer { browsers.forEach { $0.release() } }
        let loadDeadline = Date().addingTimeInterval(5)
        while browsers.contains(where: { $0.phase != .ready }), Date() < loadDeadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        guard browsers.allSatisfy({ $0.phase == .ready }) else {
            failures.append("Send to Both drawer fixtures did not load")
            return
        }
        for browser in browsers {
            guard let webView = browser.webView else { continue }
            _ = try await evaluate(
                """
                (() => {
                  window.trustedInputs = 0;
                  document.addEventListener('input', event => { if (event.isTrusted) window.trustedInputs++; }, true);
                  return true;
                })()
                """,
                in: webView
            ) as Bool
        }

        for round in 1...2 {
            restores = 0
            window.makeFirstResponder(drawerField)
            let prompt = "Send to Both round \(round)"
            let firstBrowser = browsers[0]
            let secondBrowser = browsers[1]
            async let first = firstBrowser.dispatch(prompt: prompt)
            async let second = secondBrowser.dispatch(prompt: prompt)
            let outcomes = await [first, second]
            expect(
                outcomes == [.sent, .sent],
                "Send to Both past the drawer, round \(round), returned \(outcomes)",
                failures: &failures
            )
            for browser in browsers {
                guard let webView = browser.webView else { continue }
                let trustedInputs: Int = try await evaluate("window.trustedInputs", in: webView)
                expect(
                    trustedInputs == round,
                    "\(browser.service.title) fill in round \(round) must use WebKit editing, saw \(trustedInputs) trusted inputs",
                    failures: &failures
                )
            }
            expect(restores == 1, "Round \(round) must give focus back to the drawer once, did \(restores) times", failures: &failures)
            expect(window.firstResponder !== browsers[0].webView && window.firstResponder !== browsers[1].webView,
                   "Round \(round) must leave focus with the drawer", failures: &failures)
        }
    }

    /// A cold load shows a stand-in textarea that swallows Return before the
    /// provider's real editor mounts (Claude's `#static-composer-input`,
    /// ChatGPT's `#pending-home-input`). Duet must wait for the editor and
    /// press Return there, once.
    @MainActor
    private static func testStandInComposer(
        named name: String,
        service: ChatService,
        failures: inout [String]
    ) async throws {
        let fixtureHTML = try String(contentsOf: fixtureURL(name), encoding: .utf8)
        let browser = BrowserController(service: service)
        let webView = browser.prepare()
        defer { browser.release() }
        webView.configuration.userContentController.removeAllUserScripts()
        webView.loadHTMLString(fixtureHTML, baseURL: service.startURL)
        let loadDeadline = Date().addingTimeInterval(5)
        while browser.phase != .ready, Date() < loadDeadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        guard browser.phase == .ready else {
            failures.append("\(service.title) stand-in composer fixture did not load")
            return
        }
        let outcome = await browser.dispatch(prompt: "Past the stand-in")
        expect(outcome == .sent, "\(service.title)'s stand-in composer must not take the send, got \(outcome)", failures: &failures)
        let staticPresses: Int = try await evaluate("window.staticReturnPresses", in: webView)
        let editorPresses: Int = try await evaluate("window.editorReturnPresses", in: webView)
        expect(staticPresses == 0, "Return must not go to \(service.title)'s stand-in composer", failures: &failures)
        expect(editorPresses == 1, "Return must go to \(service.title)'s real editor once, got \(editorPresses)", failures: &failures)
    }

    /// Key events reach the page asynchronously, so poll for the composer to
    /// clear. A page that never confirms comes back `false`.
    @MainActor
    private static func waitForSubmissionConfirmation(
        adapter: ProviderAdapter,
        in webView: WKWebView,
        timeout: TimeInterval = 1
    ) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let confirmed: Bool = try await evaluate(adapter.submissionConfirmationScript(), in: webView)
            if confirmed { return true }
            try await Task.sleep(for: .milliseconds(25))
        } while Date() < deadline
        return false
    }

    @MainActor
    private static func testClaudeSubmissionTiming(failures: inout [String]) async throws {
        let fixtureScript = try String(contentsOf: fixtureURL("delayed-confirmation.js"), encoding: .utf8)
        let fixtureHTML = try String(contentsOf: fixtureURL("delayed-confirmation.html"), encoding: .utf8)
            .replacingOccurrences(
                of: "<script src=\"delayed-confirmation.js\"></script>",
                with: "<script>\(fixtureScript)</script>"
            )
        for (configuration, expectedOutcome) in [
            ("'clear', 5500", PromptDispatchOutcome.sent),
            ("'navigate', 300", .sent),
            ("'replace', 0", .failed("Couldn't confirm it sent, check the chat")),
            ("'ignore', 0", .failed("Typed but not sent, Return didn't send it")),
            ("'newline', 0", .failed("Typed but not sent, Return didn't send it"))
        ] {
            let state = AppState(startupDestination: .claude)
            let browser = state.browser(for: .claude)
            let webView = browser.prepare()
            defer { browser.release() }
            webView.configuration.userContentController.removeAllUserScripts()
            webView.loadHTMLString(fixtureHTML, baseURL: ChatService.claude.startURL)
            let loadDeadline = Date().addingTimeInterval(5)
            while browser.phase != .ready, Date() < loadDeadline {
                try await Task.sleep(for: .milliseconds(25))
            }
            guard browser.phase == .ready else {
                failures.append("Claude timing fixture did not load")
                continue
            }
            _ = try await evaluate("(window.configureSubmission(\(configuration)), true)", in: webView) as Bool
            state.prompt = "Delayed Claude submission"
            state.isPromptDrawerOpen = true
            let results = await state.send(draft: state.capturePromptDraft(), to: .service(.claude))
            expect(
                results == [PromptDispatchResult(service: .claude, outcome: expectedOutcome)],
                "Claude timing fixture (\(configuration)) returned \(results)",
                failures: &failures
            )
            let presses: Int = try await evaluate("window.returnPresses", in: webView)
            expect(
                presses == 1,
                "Claude timing fixture (\(configuration)) must get exactly one trusted Return, got \(presses)",
                failures: &failures
            )
            expect(
                state.prompt.isEmpty == expectedOutcome.wasSent,
                "Only confirmed Claude submissions should clear the drawer draft",
                failures: &failures
            )
            expect(
                state.isPromptDrawerOpen != expectedOutcome.wasSent,
                "Only confirmed Claude submissions should collapse the drawer",
                failures: &failures
            )
        }
    }

    @MainActor
    private static func testRepeatedPromptConfirmation(failures: inout [String]) async throws {
        let (webView, loader) = makeFixtureWebView()
        defer {
            webView.navigationDelegate = nil
            webView.stopLoading()
        }
        try await loader.load(fixtureURL("contenteditable.html"), in: webView)

        let adapter = ProviderAdapter.adapter(for: .chatGPT)
        let prompt = "Repeated prompt"
        _ = try await evaluate(
            """
            (() => {
              window.returnPresses = 0;
              document.querySelector('[contenteditable]').addEventListener('keydown', event => {
                if (event.key === 'Enter' && event.isTrusted) window.returnPresses++;
              });
              return true;
            })()
            """,
            in: webView
        ) as Bool
        _ = try await evaluate(adapter.fillScript(prompt: prompt), in: webView) as ScriptResult
        _ = try await evaluate(
            "(() => { document.querySelector('[contenteditable]').textContent = ''; return true; })()",
            in: webView
        ) as Bool

        let refused: ScriptResult = try await evaluate(adapter.returnKeyTargetScript(prompt: prompt), in: webView)
        expect(!refused.ok, "A composer cleared before Duet's Return must block submission", failures: &failures)
        expect(refused.reason == "composer-missing-prompt", "A cleared composer should report the missing prompt", failures: &failures)

        _ = try await evaluate(adapter.fillScript(prompt: prompt), in: webView) as ScriptResult
        _ = try await evaluate(
            "(() => { document.querySelector('[contenteditable]').textContent += ' edited'; return true; })()",
            in: webView
        ) as Bool
        let editedSubmission: ScriptResult = try await evaluate(adapter.returnKeyTargetScript(prompt: prompt), in: webView)
        expect(!editedSubmission.ok, "An edited composer must not submit a changed prompt", failures: &failures)
        _ = try await evaluate(
            "(() => { document.querySelector('[contenteditable]').textContent = 'Different draft'; return true; })()",
            in: webView
        ) as Bool
        let editedConfirmation: Bool = try await evaluate(adapter.submissionConfirmationScript(), in: webView)
        expect(!editedConfirmation, "A different composer draft must not confirm submission", failures: &failures)
        _ = try await evaluate(
            "(() => { document.querySelector('[contenteditable]').textContent = ''; return true; })()",
            in: webView
        ) as Bool
        _ = try await evaluate(adapter.fillScript(prompt: prompt), in: webView) as ScriptResult
        let beforeClick: Bool = try await evaluate(
            adapter.submissionConfirmationScript(),
            in: webView
        )
        expect(!beforeClick, "Refilling a repeated prompt must not confirm before Return", failures: &failures)
        let submit: ScriptResult = try await evaluate(adapter.returnKeyTargetScript(prompt: prompt), in: webView)
        expect(submit.ok, "Repeated prompt composer wasn't ready for Return", failures: &failures)
        webView.pressReturnKey()
        let confirmed = try await waitForSubmissionConfirmation(adapter: adapter, in: webView)
        expect(confirmed, "A filled repeated prompt should confirm after Return", failures: &failures)
        let presses: Int = try await evaluate("window.returnPresses", in: webView)
        expect(presses == 1, "A filled prompt should get one Return", failures: &failures)
    }

    @MainActor
    private static func testExistingDraftProtection(failures: inout [String]) async throws {
        let (webView, loader) = makeFixtureWebView()
        defer {
            webView.navigationDelegate = nil
            webView.stopLoading()
        }
        try await loader.load(fixtureURL("contenteditable.html"), in: webView)

        _ = try await evaluate(
            """
            (() => {
              document.querySelector('[contenteditable]').textContent = "Existing provider draft";
              return true;
            })()
            """,
            in: webView
        ) as Bool
        let adapter = ProviderAdapter.adapter(for: .chatGPT)
        let fill: ScriptResult = try await evaluate(adapter.fillScript(prompt: "Replacement prompt"), in: webView)
        expect(!fill.ok, "A provider draft should block native prompt replacement", failures: &failures)
        expect(fill.reason == "composer-not-empty", "Draft protection should return its specific reason", failures: &failures)

        let preservedDraft: String = try await evaluate(
            "document.querySelector('[contenteditable]').textContent",
            in: webView
        )
        expect(preservedDraft == "Existing provider draft", "A blocked native prompt must preserve the provider draft", failures: &failures)
    }

    @MainActor
    private static func testSignedOutFixture(failures: inout [String]) async throws {
        let (webView, loader) = makeFixtureWebView()
        defer {
            webView.navigationDelegate = nil
            webView.stopLoading()
        }
        try await loader.load(fixtureURL("signed-out.html"), in: webView)

        let adapter = ProviderAdapter.adapter(for: .chatGPT)
        let loginRequired: Bool = try await evaluate(adapter.loginRequiredScript(), in: webView)
        expect(loginRequired, "Signed-out fixture was not recognized", failures: &failures)

        let (discussionWebView, discussionLoader) = makeFixtureWebView()
        defer {
            discussionWebView.navigationDelegate = nil
            discussionWebView.stopLoading()
        }
        try await discussionLoader.load(fixtureURL("login-discussion.html"), in: discussionWebView)
        let discussionRequiresLogin: Bool = try await evaluate(adapter.loginRequiredScript(), in: discussionWebView)
        expect(!discussionRequiresLogin, "Conversation text should not be mistaken for a sign-in screen", failures: &failures)
    }

    @MainActor
    private static func testClaudePageChecks(failures: inout [String]) async throws {
        let adapter = ProviderAdapter.adapter(for: .claude)
        guard let challengeScript = adapter.verificationChallengeScript(),
              let blankScript = adapter.blankPageScript() else {
            failures.append("Claude page checks were not configured")
            return
        }
        let pages: [(name: String, html: String, isChallenge: Bool, isBlank: Bool)] = [
            ("app", "<html><head><title>Claude</title></head><body><main><textarea></textarea></main></body></html>", false, false),
            ("interstitial title", "<html><head><title>Just a moment...</title></head><body><p>Checking your browser</p></body></html>", true, false),
            ("challenge markup", "<html><body><div id=\"challenge-error-text\"></div></body></html>", true, true),
            ("cookie notice", "<html><body><p>Enable JavaScript and cookies to continue</p></body></html>", true, false),
            ("blank", "<html><head></head><body></body></html>", false, true)
        ]
        for page in pages {
            let (webView, loader) = makeFixtureWebView()
            defer {
                webView.navigationDelegate = nil
                webView.stopLoading()
            }
            try await loader.loadHTML(page.html, baseURL: ChatService.claude.startURL, in: webView)
            let isChallenge: Bool = try await evaluate(challengeScript, in: webView)
            let isBlank: Bool = try await evaluate(blankScript, in: webView)
            expect(isChallenge == page.isChallenge, "Claude \(page.name) page challenge check returned \(isChallenge)", failures: &failures)
            expect(isBlank == page.isBlank, "Claude \(page.name) page blank check returned \(isBlank)", failures: &failures)
        }
    }

    @MainActor
    private static func testClaudeFileDropCompatibility(failures: inout [String]) async throws {
        let configuration = WKWebViewConfiguration()
        guard let source = ProviderAdapter.adapter(for: .claude).fileDropCompatibilityScript() else {
            failures.append("Claude file-drop compatibility script was not configured")
            return
        }
        configuration.userContentController.addUserScript(WKUserScript(
            source: source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        let webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600),
            configuration: configuration
        )
        let loader = FixtureLoader()
        defer {
            webView.navigationDelegate = nil
            webView.stopLoading()
        }
        let fixtureHTML = """
        <html><body>
          <input type="file" data-testid="file-upload" multiple>
          <script>
            window.__duetFileChangeCount = 0;
            window.__duetDropOverlayVisible = true;
            document.querySelector('[data-testid="file-upload"]').addEventListener('change', () => {
              window.__duetFileChangeCount += 1;
            });
            document.body.addEventListener('dragleave', event => {
              if (event.dataTransfer?.types.includes('Files') && event.relatedTarget === null) {
                window.__duetDropOverlayVisible = false;
              }
            });
          </script>
        </body></html>
        """
        try await loader.loadHTML(
            fixtureHTML,
            baseURL: URL(string: "https://claude.ai")!,
            in: webView
        )

        let handled: Bool = try await evaluate(
            """
            (() => {
              const transfer = new DataTransfer();
              transfer.items.add(new File(['Duet'], 'duet-drop.txt', { type: 'text/plain' }));
              const event = new Event('drop', { bubbles: true, cancelable: true });
              Object.defineProperty(event, 'dataTransfer', { value: transfer });
              document.body.dispatchEvent(event);
              const input = document.querySelector('[data-testid="file-upload"]');
              return event.defaultPrevented &&
                input.files?.length === 1 &&
                input.files[0].name === 'duet-drop.txt' &&
                window.__duetFileChangeCount === 1 &&
                window.__duetDropOverlayVisible === false;
            })()
            """,
            in: webView
        )
        expect(handled, "A Claude file drop should reach its working upload input", failures: &failures)

        try await loader.loadHTML(
            fixtureHTML,
            baseURL: URL(string: "https://example.com")!,
            in: webView
        )
        let foreignPageWasUntouched: Bool = try await evaluate(
            """
            (() => {
              const transfer = new DataTransfer();
              transfer.items.add(new File(['Duet'], 'foreign.txt', { type: 'text/plain' }));
              const event = new Event('drop', { bubbles: true, cancelable: true });
              Object.defineProperty(event, 'dataTransfer', { value: transfer });
              document.body.dispatchEvent(event);
              const input = document.querySelector('[data-testid="file-upload"]');
              return !event.defaultPrevented && input.files.length === 0 &&
                window.__duetFileChangeCount === 0;
            })()
            """,
            in: webView
        )
        expect(
            foreignPageWasUntouched,
            "Claude file-drop compatibility must not run on foreign pages",
            failures: &failures
        )
    }

    @MainActor
    private static func testPrintingBridgeFixture(failures: inout [String]) async throws {
        let presenter = RecordingPrintPresenter()
        let configuration = WKWebViewConfiguration()
        let bridge = PrintingBridge(service: .claude, presenter: presenter)
        bridge.install(in: configuration)
        let webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600),
            configuration: configuration
        )
        let loader = FixtureLoader()
        defer {
            webView.navigationDelegate = nil
            webView.stopLoading()
        }

        try await loader.loadHTML(
            """
            <html><body>
              <article id="recipe">
                <button id="mainPrint" onclick="window.print()">Print</button>
                <h2>Ingredients</h2><p>Noodles</p>
                <h2>Steps</h2><p>Cook</p>
              </article>
              <iframe id="card" srcdoc='<section><button id="cardPrint">Print recipe</button></section>'></iframe>
            </body></html>
            """,
            baseURL: URL(string: "https://claude.ai")!,
            in: webView
        )
        let bridgeInstalled: Bool = try await evaluate(
            "Boolean(window.__duetPrintingBridgeInstalled)",
            in: webView
        )
        expect(bridgeInstalled, "Provider pages must receive Duet's printing bridge", failures: &failures)

        _ = try await evaluate("(document.getElementById('mainPrint').click(), true)", in: webView) as Bool
        try await Task.sleep(for: .milliseconds(100))
        expect(
            presenter.requestedWebViews.count == 1 && presenter.requestedWebViews.first === webView,
            "A provider window.print() call must request native printing for its WKWebView",
            failures: &failures
        )
        let markedRecipe: Bool = try await evaluate(
            "document.getElementById('recipe').hasAttribute('data-duet-print-root')",
            in: webView
        )
        expect(markedRecipe, "The clicked recipe card must become the printable region", failures: &failures)

        _ = try await evaluate(
            "(document.getElementById('card').contentDocument.getElementById('cardPrint').click(), true)",
            in: webView
        ) as Bool
        try await Task.sleep(for: .milliseconds(900))
        expect(
            presenter.requestedWebViews.count == 2 && presenter.requestedWebViews.last === webView,
            "A provider child frame window.print() call must request native printing for its WKWebView",
            failures: &failures
        )

        try await loader.loadHTML(
            "<html><body>Foreign</body></html>",
            baseURL: URL(string: "https://example.com")!,
            in: webView
        )
        let foreignBridgeInstalled: Bool = try await evaluate(
            "Boolean(window.__duetPrintingBridgeInstalled)",
            in: webView
        )
        expect(!foreignBridgeInstalled, "Foreign pages must not receive Duet's printing shim", failures: &failures)

        let handlerWasVisible: Bool = try await evaluate(
            """
            (() => {
              const handler = window.webkit?.messageHandlers?.duetPrint;
              if (!handler) return false;
              handler.postMessage(null).catch(() => {});
              return true;
            })()
            """,
            in: webView
        )
        try await Task.sleep(for: .milliseconds(100))
        expect(handlerWasVisible, "The foreign print test must exercise the native handler", failures: &failures)
        expect(
            presenter.requestedWebViews.count == 2,
            "A foreign origin must not reach Duet's native print presenter",
            failures: &failures
        )
    }

    @MainActor
    private static func testNotificationBridgeFixture(failures: inout [String]) async throws {
        let fixtureHTML = try String(contentsOf: fixtureURL("notifications.html"), encoding: .utf8)
        let claudeOrigin = URL(string: "https://claude.ai")!

        // A page whose permission request is granted must reach the presenter.
        let grantedPresenter = RecordingNotificationPresenter(initial: .undetermined, afterRequest: .granted)
        let granted = try await runNotificationFixture(
            fixtureHTML,
            baseURL: claudeOrigin,
            presenter: grantedPresenter
        )
        expect(granted.supported, "Provider page did not receive the Notification API", failures: &failures)
        expect(granted.bridgeInstalled, "Provider page did not receive the Duet notification bridge", failures: &failures)
        expect(granted.initial == "default", "Initial permission must seed from the native cache", failures: &failures)
        expect(granted.requested == "granted", "Granted native permission was not reported to the page", failures: &failures)
        expect(granted.failure == nil, "Notification fixture failed: \(granted.failure ?? "")", failures: &failures)
        expect(granted.showEventDelivered, "A granted notification must deliver its show event", failures: &failures)
        expect(granted.serviceWorkerPatched, "Service worker notifications were not routed to the bridge", failures: &failures)
        expect(
            grantedPresenter.shown.count == 1
                && grantedPresenter.shown.first?.request == NotificationShowRequest(
                    title: "Duet Test",
                    body: "Body text",
                    tag: "fixture-tag"
                )
                && grantedPresenter.shown.first?.service == .claude,
            "The page notification did not reach the native presenter intact",
            failures: &failures
        )

        // A denied permission must resolve honestly and never post natively.
        let deniedPresenter = RecordingNotificationPresenter(initial: .denied, afterRequest: .denied)
        let denied = try await runNotificationFixture(
            fixtureHTML,
            baseURL: claudeOrigin,
            presenter: deniedPresenter
        )
        expect(denied.requested == "denied", "Denied native permission was not reported to the page", failures: &failures)
        expect(denied.errorEventDelivered, "A denied notification must deliver its error event", failures: &failures)
        expect(deniedPresenter.shown.isEmpty, "A denied page must not reach the native presenter", failures: &failures)

        // The shim must stay inert outside provider origins.
        let foreignPresenter = RecordingNotificationPresenter(initial: .granted, afterRequest: .granted)
        let foreign = try await runNotificationFixture(
            fixtureHTML,
            baseURL: URL(string: "https://example.com")!,
            presenter: foreignPresenter
        )
        expect(!foreign.bridgeInstalled, "Non-provider origins must not receive the Duet notification bridge", failures: &failures)
        expect(foreignPresenter.shown.isEmpty, "Non-provider origins must not reach the native presenter", failures: &failures)
        try await testDirectForeignBridgeAttempt(failures: &failures)
    }

    @MainActor
    private static func testLocationBridgeFixture(failures: inout [String]) async throws {
        let fixtureHTML = try String(contentsOf: fixtureURL("location.html"), encoding: .utf8)
        let expectedPosition = BrowserLocation(
            latitude: 24.669,
            longitude: -81.353,
            accuracy: 12,
            timestampMilliseconds: 1_722_700_000_000
        )
        let grantedProvider = RecordingLocationProvider(
            permissionState: .granted,
            result: .success(expectedPosition)
        )
        let granted = try await runLocationFixture(
            fixtureHTML,
            baseURL: URL(string: "https://www.chatgpt.com")!,
            provider: grantedProvider
        )
        expect(granted.supported, "Provider page did not receive the Geolocation API", failures: &failures)
        expect(granted.bridgeInstalled, "Provider page did not receive the Duet location bridge", failures: &failures)
        expect(granted.permission == "granted", "Native location permission was not reported to the page", failures: &failures)
        expect(granted.latitude == expectedPosition.latitude, "Location latitude changed in the page bridge", failures: &failures)
        expect(granted.longitude == expectedPosition.longitude, "Location longitude changed in the page bridge", failures: &failures)
        expect(granted.accuracy == expectedPosition.accuracy, "Location accuracy changed in the page bridge", failures: &failures)
        expect(granted.errorCode == nil, "Granted location unexpectedly reported an error", failures: &failures)
        expect(granted.failure == nil, "Location fixture failed: \(granted.failure ?? "")", failures: &failures)
        expect(
            grantedProvider.highAccuracyRequests == [true],
            "Precise location requests must reach Core Location as high-accuracy requests",
            failures: &failures
        )

        let deniedProvider = RecordingLocationProvider(
            permissionState: .denied,
            result: .failure(.permissionDenied)
        )
        let denied = try await runLocationFixture(
            fixtureHTML,
            baseURL: URL(string: "https://claude.ai")!,
            provider: deniedProvider,
            service: .claude
        )
        expect(denied.permission == "denied", "Denied native permission was not reported to Claude", failures: &failures)
        expect(denied.errorCode == 1, "Denied location must use the browser permission-denied code", failures: &failures)

        let foreignProvider = RecordingLocationProvider(
            permissionState: .granted,
            result: .success(expectedPosition)
        )
        let foreign = try await runLocationFixture(
            fixtureHTML,
            baseURL: URL(string: "https://example.com")!,
            provider: foreignProvider
        )
        expect(!foreign.bridgeInstalled, "Non-provider origins must not receive the Duet location bridge", failures: &failures)
        expect(foreignProvider.highAccuracyRequests.isEmpty, "Non-provider pages must not request native location", failures: &failures)
        try await testDirectForeignLocationAttempt(
            provider: foreignProvider,
            service: .chatGPT,
            baseURL: URL(string: "https://example.com")!,
            failures: &failures
        )

        for (service, url) in [
            (ChatService.chatGPT, URL(string: "https://www.chatgpt.com/login")!),
            (.claude, URL(string: "https://claude.ai/login")!)
        ] {
            let loginProvider = RecordingLocationProvider(permissionState: .granted, result: .success(expectedPosition))
            let login = try await runLocationFixture(fixtureHTML, baseURL: url, provider: loginProvider, service: service)
            expect(!login.bridgeInstalled, "Provider login pages must not receive the Duet location bridge", failures: &failures)
            try await testDirectForeignLocationAttempt(
                provider: loginProvider,
                service: service,
                baseURL: url,
                failures: &failures
            )
        }
    }

    @MainActor
    private static func testDirectForeignLocationAttempt(
        provider: RecordingLocationProvider,
        service: ChatService,
        baseURL: URL,
        failures: inout [String]
    ) async throws {
        let configuration = WKWebViewConfiguration()
        let bridge = LocationBridge(service: service, provider: provider)
        bridge.install(in: configuration)
        let webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600),
            configuration: configuration
        )
        let loader = FixtureLoader()
        defer {
            webView.navigationDelegate = nil
            webView.stopLoading()
        }
        try await loader.loadHTML(
            "<html><body>Foreign</body></html>",
            baseURL: baseURL,
            in: webView
        )
        let handlerWasVisible: Bool = try await evaluate(
            """
            (() => {
              const handler = window.webkit?.messageHandlers?.duetLocation;
              if (!handler) return false;
              handler.postMessage({ type: 'currentPosition', enableHighAccuracy: true }).catch(() => {});
              return true;
            })()
            """,
            in: webView
        )
        try await Task.sleep(for: .milliseconds(100))
        expect(handlerWasVisible, "The foreign location test must exercise the native handler", failures: &failures)
        expect(
            provider.highAccuracyRequests.isEmpty,
            "A disallowed page must be rejected even when it calls the location handler directly",
            failures: &failures
        )
    }

    @MainActor
    private static func testDirectForeignBridgeAttempt(failures: inout [String]) async throws {
        let presenter = RecordingNotificationPresenter(initial: .granted, afterRequest: .granted)
        let configuration = WKWebViewConfiguration()
        let bridge = NotificationBridge(service: .claude, presenter: presenter)
        bridge.install(in: configuration)
        let webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600),
            configuration: configuration
        )
        let loader = FixtureLoader()
        defer {
            webView.navigationDelegate = nil
            webView.stopLoading()
        }
        try await loader.loadHTML("<html><body>Foreign</body></html>", baseURL: URL(string: "https://example.com")!, in: webView)

        let handlerWasVisible: Bool = try await evaluate(
            """
            (() => {
              const handler = window.webkit?.messageHandlers?.duetNotifications;
              if (!handler) return false;
              handler.postMessage({ type: "show", title: "Spoofed" }).catch(() => {});
              return true;
            })()
            """,
            in: webView
        )
        try await Task.sleep(for: .milliseconds(100))
        expect(handlerWasVisible, "The foreign-origin test must exercise the registered native handler", failures: &failures)
        expect(
            presenter.shown.isEmpty,
            "A foreign origin must be rejected even when it calls the native handler directly",
            failures: &failures
        )
    }

    @MainActor
    private static func testResponseWatcherFixture(failures: inout [String]) async throws {
        for service in ChatService.allCases {
            try await testResponseWatcherFixture(for: service, failures: &failures)
        }
    }

    @MainActor
    private static func testResponseWatcherFixture(for service: ChatService, failures: inout [String]) async throws {
        let fixtureScript = try String(contentsOf: fixtureURL("streaming-response.js"), encoding: .utf8)
        let fixtureHTML = try String(contentsOf: fixtureURL("streaming-response.html"), encoding: .utf8)
            .replacingOccurrences(
                // Each provider's live composer sits in this element: ChatGPT's
                // in a <form>, Claude's in a <fieldset>.
                of: "__COMPOSER_SCOPE__",
                with: service == .chatGPT ? "form" : "fieldset"
            )
            .replacingOccurrences(
                of: "<script src=\"streaming-response.js\"></script>",
                with: "<script>\(fixtureScript)</script>"
            )
        let presenter = RecordingNotificationPresenter(initial: .granted, afterRequest: .granted)

        let configuration = WKWebViewConfiguration()
        configuration.preferences.inactiveSchedulingPolicy = .none
        let bridge = NotificationBridge(service: service, presenter: presenter)
        let watcher = WKUserScript(
            source: NotificationScript.responseWatcherSource(
                adapter: ProviderAdapter.adapter(for: service),
                allowedHosts: service.providerPageHosts,
                pollIntervalMilliseconds: 50,
                minimumGenerationMilliseconds: 200
            ),
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        configuration.userContentController.addUserScript(watcher)
        configuration.userContentController.addScriptMessageHandler(
            bridge,
            contentWorld: .page,
            name: NotificationScript.handlerName
        )
        let webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600),
            configuration: configuration
        )
        let loader = FixtureLoader()
        defer {
            webView.navigationDelegate = nil
            webView.stopLoading()
        }
        try await loader.loadHTML(fixtureHTML, baseURL: service.startURL, in: webView)

        _ = try await evaluate("(window.setUnrelatedStop(true), true)", in: webView) as Bool
        try await Task.sleep(for: .milliseconds(300))
        _ = try await evaluate("(window.setUnrelatedStop(false), true)", in: webView) as Bool
        try await Task.sleep(for: .milliseconds(100))
        expect(
            presenter.completions.isEmpty,
            "\(service.title): an unrelated Stop button must not report generation",
            failures: &failures
        )

        _ = try await evaluate("(window.setUnrelatedStop(true), true)", in: webView) as Bool
        let labels = ["Stop", "Stop streaming", "Stop generating", "Stop response", "sToP response generation"]
        for (index, label) in labels.enumerated() {
            _ = try await evaluate("(window.startStreaming('\(label)'), true)", in: webView) as Bool
            try await Task.sleep(for: .milliseconds(300))
            _ = try await evaluate("(window.finishStreaming(), true)", in: webView) as Bool
            let deadline = Date().addingTimeInterval(1)
            while Date() < deadline, presenter.completions.count < index + 1 {
                try await Task.sleep(for: .milliseconds(25))
            }
            expect(
                presenter.completions == Array(repeating: service, count: index + 1),
                "\(service.title): \(label) must report one completion despite an unrelated Stop button",
                failures: &failures
            )
        }

        let expectedCompletionCount = presenter.completions.count
        _ = try await evaluate("(window.startStreaming('Stop generating'), true)", in: webView) as Bool
        try await Task.sleep(for: .milliseconds(60))
        _ = try await evaluate("(window.finishStreaming(), true)", in: webView) as Bool
        try await Task.sleep(for: .milliseconds(100))
        expect(
            presenter.completions.count == expectedCompletionCount,
            "\(service.title): a brief streaming flicker must not produce a completion notification",
            failures: &failures
        )

        // ChatGPT's Stop button has no test ID, so only Claude's is checked.
        if service == .claude {
            _ = try await evaluate("(window.startStreaming(null, false, 'chat-input-stop'), true)", in: webView) as Bool
            try await Task.sleep(for: .milliseconds(300))
            _ = try await evaluate("(window.finishStreaming(), true)", in: webView) as Bool
            try await Task.sleep(for: .milliseconds(100))
            expect(
                presenter.completions.count == expectedCompletionCount + 1,
                "Claude: the chat-input-stop test ID must still report completion without a label",
                failures: &failures
            )

            _ = try await evaluate("(window.startStreaming(null, true), true)", in: webView) as Bool
            try await Task.sleep(for: .milliseconds(300))
            _ = try await evaluate("(window.finishStreaming(), true)", in: webView) as Bool
            try await Task.sleep(for: .milliseconds(100))
            expect(
                presenter.completions.count == expectedCompletionCount + 2,
                "Claude: the streaming status must report completion without a stop button",
                failures: &failures
            )
        }
    }

    @MainActor
    private static func runNotificationFixture(
        _ fixtureHTML: String,
        baseURL: URL,
        presenter: RecordingNotificationPresenter
    ) async throws -> NotificationFixtureOutcome {
        let configuration = WKWebViewConfiguration()
        let bridge = NotificationBridge(service: .claude, presenter: presenter)
        bridge.install(in: configuration)
        let webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600),
            configuration: configuration
        )
        let loader = FixtureLoader()
        defer {
            webView.navigationDelegate = nil
            webView.stopLoading()
        }
        try await loader.loadHTML(fixtureHTML, baseURL: baseURL, in: webView)

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let finished: Bool = try await evaluate("Boolean(window.__duetNotificationTest)", in: webView)
            if finished { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        return try await evaluate("(window.__duetNotificationTest)", in: webView)
    }

    @MainActor
    private static func runLocationFixture(
        _ fixtureHTML: String,
        baseURL: URL,
        provider: RecordingLocationProvider,
        service: ChatService = .chatGPT
    ) async throws -> LocationFixtureOutcome {
        let configuration = WKWebViewConfiguration()
        let bridge = LocationBridge(service: service, provider: provider)
        bridge.install(in: configuration)
        let webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600),
            configuration: configuration
        )
        let loader = FixtureLoader()
        defer {
            webView.navigationDelegate = nil
            webView.stopLoading()
        }
        try await loader.loadHTML(fixtureHTML, baseURL: baseURL, in: webView)

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let finished: Bool = try await evaluate("Boolean(window.__duetLocationTest)", in: webView)
            if finished { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        return try await evaluate("(window.__duetLocationTest)", in: webView)
    }

    @MainActor
    private static func makeFixtureWebView() -> (ProviderWebView, FixtureLoader) {
        let webView = ProviderWebView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600),
            configuration: WKWebViewConfiguration()
        )
        return (webView, FixtureLoader())
    }

    private static func fixtureURL(_ name: String) -> URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Tests/Fixtures")
            .appendingPathComponent(name)
    }

    @MainActor
    private static func evaluate<Value: Decodable & Sendable>(
        _ script: String,
        in webView: WKWebView
    ) async throws -> Value {
        let wrapped = "JSON.stringify((\(script)))"
        let json: String = try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(wrapped) { value, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let json = value as? String {
                    continuation.resume(returning: json)
                } else {
                    continuation.resume(throwing: IntegrationTestError.invalidJavaScriptResult)
                }
            }
        }
        return try JSONDecoder().decode(Value.self, from: Data(json.utf8))
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String,
        failures: inout [String]
    ) {
        if !condition() { failures.append(message) }
    }
}
