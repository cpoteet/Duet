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

        identifiedWorkspaceWindow.orderOut(nil)
        let existingVisibleWindow = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 400, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        existingVisibleWindow.orderFront(nil)
        let workspaceWindowSnapshot = WorkspaceWindowSnapshot(
            windows: [identifiedWorkspaceWindow, existingVisibleWindow]
        )
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
            workspaceWindowSnapshot.reopenedWorkspaceWindow(
                in: [existingVisibleWindow, replacementWorkspaceWindow]
            ) === replacementWorkspaceWindow,
            "Workspace restoration should select the newly shown replacement, not an existing visible window"
        )
        if let reopenedWorkspaceWindow = workspaceWindowSnapshot.reopenedWorkspaceWindow(
            in: [existingVisibleWindow, replacementWorkspaceWindow]
        ) {
            DuetWindowRegistry.register(reopenedWorkspaceWindow)
        }
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
        existingVisibleWindow.orderOut(nil)
        DuetWindowRegistry.unregister(replacementWorkspaceWindow)

        let filePickerSelector = NSSelectorFromString(
            "webView:runOpenPanelWithParameters:initiatedByFrame:completionHandler:"
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
        expect(
            browserController.prepare().underPageBackgroundColor.alphaComponent == 0,
            "Provider web views should use the supported transparent background property"
        )
        expect(
            browserController.responds(to: filePickerSelector),
            "Browser controller should handle WebKit file-upload panels"
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
        withExtendedLifetime(splitStateObserver) {}

        let workspaceState = AppState()
        expect(workspaceState.isLaunchChooserVisible, "Workspace should begin at the tool chooser")
        workspaceState.openWorkspace(for: .service(.claude))
        expect(!workspaceState.isLaunchChooserVisible, "A provider destination should leave the tool chooser")
        expect(workspaceState.selectedService == .claude, "Claude destination should select Claude")
        expect(!workspaceState.isSplitView, "A single-provider destination should use one pane")
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
        workspaceState.browserDidMount(.chatGPT)
        workspaceState.browserDidMount(.claude)
        let splitWorkspaceMounted = await workspaceState.waitForSplitWorkspaceMount(timeout: 0.01)
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
        workspaceState.openQuickPromptWorkspace(for: .both)
        expect(workspaceState.isSplitView, "Quick Prompt Both destination should use a fresh split workspace")
        workspaceState.browserDidMount(.chatGPT)
        workspaceState.browserDidMount(.claude)
        workspaceState.openQuickPromptWorkspace(for: .both)
        let staleSplitWorkspaceMounted = await workspaceState.waitForSplitWorkspaceMount(timeout: 0.01)
        expect(
            !staleSplitWorkspaceMounted,
            "Recreated split-pane browsers must not inherit stale mount state"
        )
        workspaceState.browserDidMount(.chatGPT)
        workspaceState.browserDidMount(.claude)
        let recreatedSplitWorkspaceMounted = await workspaceState.waitForSplitWorkspaceMount(timeout: 0.01)
        expect(recreatedSplitWorkspaceMounted, "Recreated split-pane browser hosts should report their new mounts")

        do {
            try await testComposerFixture(
                named: "textarea.html",
                service: .chatGPT,
                failures: &failures
            )
            try await testComposerFixture(
                named: "contenteditable.html",
                service: .claude,
                failures: &failures
            )
            try await testDelayedSend(failures: &failures)
            try await testRepeatedPromptConfirmation(failures: &failures)
            try await testExistingDraftProtection(failures: &failures)
            try await testSignedOutFixture(failures: &failures)
            try await testNotificationBridgeFixture(failures: &failures)
            try await testResponseWatcherFixture(failures: &failures)
        } catch {
            failures.append("Fixture integration test threw: \(error)")
        }

        await testRapidProviderReversals(failures: &failures)
        await testRapidSplitReversals(failures: &failures)
        await testRetentionChangesDuringPendingCleanup(failures: &failures)
        await testRepeatedTransitionSoak(failures: &failures)

        if failures.isEmpty {
            print("Browser host and fixture integration tests passed.")
        } else {
            failures.forEach { fputs("FAIL: \($0)\n", stderr) }
            exit(1)
        }
    }

    @MainActor
    private static func testRapidProviderReversals(failures: inout [String]) async {
        let state = AppState(inactiveBrowserReleaseDelay: .milliseconds(10))
        let originalChatGPTView = state.browser(for: .chatGPT).webView

        for _ in 0..<10 {
            state.select(.claude)
            state.select(.chatGPT)
        }
        try? await Task.sleep(for: .milliseconds(30))
        expect(
            state.selectedService == .chatGPT && state.browser(for: .chatGPT).webView === originalChatGPTView,
            "Rapid Claude-to-ChatGPT reversals must not release or replace the final selected provider",
            failures: &failures
        )
        expect(
            state.browser(for: .claude).webView == nil,
            "Rapid Claude-to-ChatGPT reversals should eventually release inactive Claude",
            failures: &failures
        )

        state.select(.claude)
        try? await Task.sleep(for: .milliseconds(30))
        let originalClaudeView = state.browser(for: .claude).webView
        for _ in 0..<10 {
            state.select(.chatGPT)
            state.select(.claude)
        }
        try? await Task.sleep(for: .milliseconds(30))
        expect(
            state.selectedService == .claude && state.browser(for: .claude).webView === originalClaudeView,
            "Rapid ChatGPT-to-Claude reversals must not release or replace the final selected provider",
            failures: &failures
        )
        expect(
            state.browser(for: .chatGPT).webView == nil,
            "Rapid ChatGPT-to-Claude reversals should eventually release inactive ChatGPT",
            failures: &failures
        )
    }

    @MainActor
    private static func testRapidSplitReversals(failures: inout [String]) async {
        for selectedService in ChatService.allCases {
            let releasingState = AppState(inactiveBrowserReleaseDelay: .milliseconds(10))
            releasingState.select(selectedService)
            try? await Task.sleep(for: .milliseconds(30))

            releasingState.setSplitView(true)
            releasingState.setSplitView(false)
            releasingState.setSplitView(true)
            try? await Task.sleep(for: .milliseconds(30))
            expect(releasingState.isSplitView, "Rapid split reversal should stop in split view", failures: &failures)
            expect(
                ChatService.allCases.allSatisfy { releasingState.browser(for: $0).webView != nil },
                "Rapid split reversal should leave exactly one prepared view per provider",
                failures: &failures
            )

            releasingState.setSplitView(false)
            releasingState.setSplitView(true)
            releasingState.setSplitView(false)
            try? await Task.sleep(for: .milliseconds(30))
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

            let retainingState = AppState(inactiveBrowserReleaseDelay: .milliseconds(10))
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
            try? await Task.sleep(for: .milliseconds(30))
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
        let state = AppState(inactiveBrowserReleaseDelay: .milliseconds(20))
        state.select(.claude)
        let pendingChatGPTView = state.browser(for: .chatGPT).webView
        state.setKeepsProvidersLoaded(true)
        try? await Task.sleep(for: .milliseconds(40))
        expect(
            state.browser(for: .chatGPT).webView === pendingChatGPTView
                && state.browser(for: .claude).webView != nil,
            "Enabling retention must cancel obsolete inactive-provider cleanup",
            failures: &failures
        )

        state.setKeepsProvidersLoaded(false)
        try? await Task.sleep(for: .milliseconds(40))
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
        try? await Task.sleep(for: .milliseconds(40))
        expect(
            ChatService.allCases.allSatisfy { state.browser(for: $0).webView === splitViews[$0]! },
            "Disabling retention must not release either provider while split view is active",
            failures: &failures
        )

        state.setSplitView(false)
        try? await Task.sleep(for: .milliseconds(40))
        expect(
            state.browser(for: .claude).webView != nil && state.browser(for: .chatGPT).webView == nil,
            "Leaving split view should resume cleanup after retention was disabled",
            failures: &failures
        )
    }

    @MainActor
    private static func testRepeatedTransitionSoak(failures: inout [String]) async {
        let releasingState = AppState(inactiveBrowserReleaseDelay: .milliseconds(5))
        for _ in 0..<25 {
            releasingState.select(.claude)
            try? await Task.sleep(for: .milliseconds(10))
            releasingState.select(.chatGPT)
            try? await Task.sleep(for: .milliseconds(10))
            releasingState.setSplitView(true)
            releasingState.setSplitView(false)
            try? await Task.sleep(for: .milliseconds(10))
        }
        expect(
            releasingState.selectedService == .chatGPT
                && releasingState.browser(for: .chatGPT).webView != nil
                && releasingState.browser(for: .claude).webView == nil,
            "Retention-off transition soak should settle with only the selected provider prepared",
            failures: &failures
        )

        let retainingState = AppState(inactiveBrowserReleaseDelay: .milliseconds(5))
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
        try? await Task.sleep(for: .milliseconds(20))
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

        let baselineMessageCount: Int = try await evaluate(adapter.submissionBaselineScript(), in: webView)

        let fill: ScriptResult = try await evaluate(adapter.fillScript(prompt: prompt), in: webView)
        expect(fill.ok, "\(name) composer was not filled", failures: &failures)

        let beforeClick: Bool = try await evaluate(
            adapter.submissionConfirmationScript(
                prompt: prompt,
                baselineMessageCount: baselineMessageCount
            ),
            in: webView
        )
        expect(!beforeClick, "\(name) reported submission before click", failures: &failures)

        let submit: ScriptResult = try await evaluate(adapter.submissionScript(), in: webView)
        expect(submit.ok, "\(name) send control was not clicked", failures: &failures)

        let confirmed: Bool = try await evaluate(
            adapter.submissionConfirmationScript(
                prompt: prompt,
                baselineMessageCount: baselineMessageCount
            ),
            in: webView
        )
        expect(confirmed, "\(name) submission was not confirmed", failures: &failures)
    }

    @MainActor
    private static func testDelayedSend(failures: inout [String]) async throws {
        let (webView, loader) = makeFixtureWebView()
        defer {
            webView.navigationDelegate = nil
            webView.stopLoading()
        }
        try await loader.load(fixtureURL("delayed-send.html"), in: webView)

        let adapter = ProviderAdapter.adapter(for: .claude)
        let prompt = "Delayed prompt"
        let baselineMessageCount: Int = try await evaluate(adapter.submissionBaselineScript(), in: webView)
        _ = try await evaluate(adapter.fillScript(prompt: prompt), in: webView) as ScriptResult

        let early: ScriptResult = try await evaluate(adapter.submissionScript(), in: webView)
        expect(!early.ok, "Delayed send control was available too early", failures: &failures)
        try await Task.sleep(for: .milliseconds(350))

        let submit: ScriptResult = try await evaluate(adapter.submissionScript(), in: webView)
        expect(submit.ok, "Delayed send control never became ready", failures: &failures)
        let confirmed: Bool = try await evaluate(
            adapter.submissionConfirmationScript(
                prompt: prompt,
                baselineMessageCount: baselineMessageCount
            ),
            in: webView
        )
        expect(confirmed, "Delayed submission was not confirmed", failures: &failures)
    }

    @MainActor
    private static func testRepeatedPromptConfirmation(failures: inout [String]) async throws {
        let (webView, loader) = makeFixtureWebView()
        defer {
            webView.navigationDelegate = nil
            webView.stopLoading()
        }
        try await loader.load(fixtureURL("textarea.html"), in: webView)

        let adapter = ProviderAdapter.adapter(for: .chatGPT)
        let prompt = "Repeated prompt"
        _ = try await evaluate(
            """
            (() => {
              const message = document.createElement('div');
              message.dataset.messageAuthorRole = 'user';
              message.textContent = "Repeated prompt";
              document.body.appendChild(message);
              return true;
            })()
            """,
            in: webView
        ) as Bool
        let baselineMessageCount: Int = try await evaluate(adapter.submissionBaselineScript(), in: webView)
        _ = try await evaluate(adapter.fillScript(prompt: prompt), in: webView) as ScriptResult

        let oldMessageConfirmed: Bool = try await evaluate(
            adapter.submissionConfirmationScript(
                prompt: prompt,
                baselineMessageCount: baselineMessageCount
            ),
            in: webView
        )
        expect(!oldMessageConfirmed, "An older repeated prompt must not confirm a new submission", failures: &failures)

        _ = try await evaluate(
            """
            (() => {
              document.querySelector('textarea').value = '';
              return true;
            })()
            """,
            in: webView
        ) as Bool
        let clearedComposerConfirmed: Bool = try await evaluate(
            adapter.submissionConfirmationScript(
                prompt: prompt,
                baselineMessageCount: baselineMessageCount
            ),
            in: webView
        )
        expect(!clearedComposerConfirmed, "An empty composer alone must not confirm submission", failures: &failures)

        _ = try await evaluate(adapter.fillScript(prompt: prompt), in: webView) as ScriptResult
        let submit: ScriptResult = try await evaluate(adapter.submissionScript(), in: webView)
        expect(submit.ok, "Repeated prompt send control was not clicked", failures: &failures)
        let newMessageConfirmed: Bool = try await evaluate(
            adapter.submissionConfirmationScript(
                prompt: prompt,
                baselineMessageCount: baselineMessageCount
            ),
            in: webView
        )
        expect(newMessageConfirmed, "A newly added repeated prompt should confirm submission", failures: &failures)
    }

    @MainActor
    private static func testExistingDraftProtection(failures: inout [String]) async throws {
        let (webView, loader) = makeFixtureWebView()
        defer {
            webView.navigationDelegate = nil
            webView.stopLoading()
        }
        try await loader.load(fixtureURL("textarea.html"), in: webView)

        _ = try await evaluate(
            """
            (() => {
              document.querySelector('textarea').value = "Existing provider draft";
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
            "document.querySelector('textarea').value",
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
    }

    @MainActor
    private static func testResponseWatcherFixture(failures: inout [String]) async throws {
        let fixtureHTML = try String(contentsOf: fixtureURL("streaming-response.html"), encoding: .utf8)
        let presenter = RecordingNotificationPresenter(initial: .granted, afterRequest: .granted)

        let configuration = WKWebViewConfiguration()
        let bridge = NotificationBridge(service: .claude, presenter: presenter)
        let watcher = WKUserScript(
            source: NotificationScript.responseWatcherSource(
                indicatorSelectors: ProviderAdapter.adapter(for: .claude).generationIndicatorSelectors,
                allowedHosts: ChatService.claude.webNotificationHosts,
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
        try await loader.loadHTML(fixtureHTML, baseURL: URL(string: "https://claude.ai")!, in: webView)

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, presenter.completions.isEmpty {
            try await Task.sleep(for: .milliseconds(50))
        }
        expect(
            presenter.completions == [.claude],
            "A finished streaming response must report exactly one completion",
            failures: &failures
        )

        // A short flicker of the streaming indicator must not notify.
        _ = try await evaluate("(window.flickerStreaming(60), true)", in: webView) as Bool
        try await Task.sleep(for: .milliseconds(600))
        expect(
            presenter.completions == [.claude],
            "A brief streaming flicker must not produce a completion notification",
            failures: &failures
        )
    }

    @MainActor
    private static func runNotificationFixture(
        _ fixtureHTML: String,
        baseURL: URL,
        presenter: RecordingNotificationPresenter
    ) async throws -> NotificationFixtureOutcome {
        let configuration = WKWebViewConfiguration()
        let bridge = NotificationBridge(service: .claude, presenter: presenter)
        bridge.install(in: configuration.userContentController)
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
    private static func makeFixtureWebView() -> (WKWebView, FixtureLoader) {
        let webView = WKWebView(
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
