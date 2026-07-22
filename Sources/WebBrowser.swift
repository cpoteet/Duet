import AppKit
import Combine
import SwiftUI
import WebKit

@MainActor
final class BrowserController: NSObject, ObservableObject {
    let service: ChatService
    private let adapter: ProviderAdapter

    @Published private(set) var phase: BrowserPhase = .unloaded
    @Published private(set) var webView: WKWebView?
    private lazy var notificationBridge = NotificationBridge(
        service: service,
        presenter: DuetNotificationManager.shared
    )
    private var hasRetriedBlankInitialClaudeLoad = false
    // WebKit ends a main-frame navigation with error 102 after converting it
    // into a WKDownload. Preserve the page's prior phase for that exact path.
    private var phaseBeforeProvisionalNavigation: BrowserPhase?
    private var phaseRestoredForMainFrameDownload: BrowserPhase?
    private weak var mainFrameDownload: WKDownload?

    init(service: ChatService) {
        self.service = service
        self.adapter = ProviderAdapter.adapter(for: service)
        super.init()
    }

    /// Creates the view without starting navigation. SwiftUI calls this while it
    /// is constructing a host, then `activateWhenHosted()` starts the first
    /// navigation only after the view belongs to a real window.
    func prepare() -> WKWebView {
        if let webView { return webView }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.preferences.isElementFullscreenEnabled = true
        notificationBridge.install(in: configuration)

        let newWebView = WKWebView(frame: .zero, configuration: configuration)
        newWebView.allowsBackForwardNavigationGestures = true
        newWebView.navigationDelegate = self
        newWebView.uiDelegate = self
        newWebView.underPageBackgroundColor = .clear
        webView = newWebView
        hasRetriedBlankInitialClaudeLoad = false
        return newWebView
    }

    /// Starts a load immediately for actions that operate without a visible pane,
    /// such as sending a prompt to the inactive provider.
    func acquire() -> WKWebView {
        let webView = prepare()
        startInitialNavigationIfNeeded(in: webView)
        return webView
    }

    func activateWhenHosted() {
        guard let webView else { return }
        guard webView.superview?.window != nil else { return }
        startInitialNavigationIfNeeded(in: webView)
    }

    func release() {
        guard let webView else { return }
        webView.stopLoading()
        webView.removeFromSuperview()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        // WKWebView has no public close API. Duet is a personal, non-App Store
        // app, so use WebKit's guarded close selector to destroy the discarded
        // page proxy. Persistent website data is stored separately and survives
        // the view teardown.
        let closeSelector = NSSelectorFromString("_close")
        if webView.responds(to: closeSelector) {
            webView.perform(closeSelector)
        }
        self.webView = nil
        clearNavigationPhaseTracking()
        phase = .unloaded
    }

    func reload() {
        if let webView {
            beginProgrammaticNavigation()
            webView.reload()
        } else {
            _ = acquire()
        }
    }

    func openInDefaultBrowser() {
        NSWorkspace.shared.open(service.startURL)
    }

    func dispatch(
        prompt: String,
        startsNewConversation: Bool = false,
        timeout: TimeInterval = 12
    ) async -> PromptDispatchOutcome {
        if startsNewConversation {
            openNewConversation()
        } else {
            _ = acquire()
        }
        switch await waitForComposer(timeout: timeout) {
        case .ready:
            break
        case .loginRequired:
            return .loginRequired
        case .unavailable:
            return .unavailable
        }

        do {
            guard service.allowsPromptInjection(at: webView?.url) else {
                return .failed("Provider page is not active")
            }
            let baselineMessageCount = try await evaluate(adapter.submissionBaselineScript(), as: Int.self)
            let result = try await evaluate(adapter.fillScript(prompt: prompt), as: ScriptResult.self)
            guard result.ok else {
                if result.reason == "composer-not-found" {
                    return .unavailable
                }
                if result.reason == "composer-not-empty" {
                    return .composerHasDraft
                }
                return .failed("Unexpected page response")
            }
            return await waitForSubmission(
                prompt: prompt,
                baselineMessageCount: baselineMessageCount,
                timeout: 4
            )
        } catch {
            return .failed("Could not talk to page")
        }
    }

    private func openNewConversation() {
        let webView = prepare()
        webView.stopLoading()
        beginProgrammaticNavigation()
        webView.load(URLRequest(url: service.newConversationURL))
    }

    func clearWebsiteData() async {
        let dataStore = WKWebsiteDataStore.default()
        let recordTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        let records: [WKWebsiteDataRecord] = await withCheckedContinuation { continuation in
            dataStore.fetchDataRecords(ofTypes: recordTypes) { continuation.resume(returning: $0) }
        }
        let matches = records.filter { record in
            let name = record.displayName.lowercased()
            return service.websiteDataTokens.contains { name.contains($0) }
        }
        guard !matches.isEmpty else {
            release()
            _ = prepare()
            return
        }
        await withCheckedContinuation { continuation in
            dataStore.removeData(ofTypes: recordTypes, for: matches) { continuation.resume() }
        }
        release()
        _ = prepare()
    }

    private func waitForComposer(timeout: TimeInterval) async -> ComposerReadiness {
        let deadline = Date().addingTimeInterval(timeout)
        var nextLoginCheck = Date.distantPast
        while Date() < deadline {
            if Task.isCancelled { return .unavailable }
            if await hasComposer() { return .ready }
            if Date() >= nextLoginCheck {
                if await isLoginRequired() { return .loginRequired }
                nextLoginCheck = Date().addingTimeInterval(0.9)
            }
            do {
                try await Task.sleep(for: .milliseconds(300))
            } catch {
                return .unavailable
            }
        }
        return await isLoginRequired() ? .loginRequired : .unavailable
    }

    private func startInitialNavigationIfNeeded(in webView: WKWebView) {
        guard phase == .unloaded else { return }
        beginProgrammaticNavigation()
        webView.load(URLRequest(url: service.startURL))
    }

    private func hasComposer() async -> Bool {
        guard service.allowsPromptInjection(at: webView?.url) else { return false }
        return (try? await evaluate(adapter.readinessScript(), as: Bool.self)) ?? false
    }

    private func isLoginRequired() async -> Bool {
        guard let url = webView?.url else { return false }
        if service.isAuthenticationPage(url) { return true }
        guard service.allowsPromptInjection(at: url) else { return false }
        return (try? await evaluate(adapter.loginRequiredScript(), as: Bool.self)) ?? false
    }

    /// Cloudflare can complete a navigation while showing no usable app UI in an
    /// embedded renderer. Surface that separately from a normal page failure.
    private func detectVerificationChallenge(in loadedWebView: WKWebView) async {
        guard service == .claude, webView === loadedWebView else { return }
        let script = """
        (() => ({
          title: document.title || '',
          text: (document.body?.innerText || '').slice(0, 1500),
          hasChallenge: Boolean(document.querySelector('#challenge-error-text, [data-cf-beacon], iframe[src*="challenges.cloudflare.com"]'))
        }))()
        """
        guard let details = try? await evaluate(script, as: VerificationDetails.self) else { return }
        guard webView === loadedWebView else { return }
        let title = details.title.lowercased()
        let text = details.text.lowercased()
        let hasChallenge = details.hasChallenge
        if hasChallenge || title.contains("just a moment") || text.contains("enable javascript and cookies") {
            phase = .verificationRequired
        }
    }

    /// Claude can occasionally finish its first embedded navigation with an
    /// empty root document. Retrying that one unusable result avoids requiring
    /// the user to switch away and back, while leaving normal navigation alone.
    private func retryBlankInitialClaudeLoadIfNeeded(in loadedWebView: WKWebView) async {
        guard service == .claude, !hasRetriedBlankInitialClaudeLoad, webView === loadedWebView else { return }

        try? await Task.sleep(for: .milliseconds(800))
        guard webView === loadedWebView else { return }

        let script = """
        (() => {
          const body = document.body;
          const hasAppContent = Boolean(body?.innerText?.trim()) || Boolean(
            document.querySelector('main, [role="main"], textarea, [contenteditable="true"], button, a')
          );
          return !hasAppContent;
        })()
        """
        guard (try? await evaluate(script, as: Bool.self)) == true else { return }

        hasRetriedBlankInitialClaudeLoad = true
        beginProgrammaticNavigation()
        loadedWebView.reload()
    }

    private func beginProgrammaticNavigation() {
        phaseBeforeProvisionalNavigation = phase
        phaseRestoredForMainFrameDownload = nil
        mainFrameDownload = nil
        phase = .loading
    }

    func beginProvisionalNavigation() {
        if phaseRestoredForMainFrameDownload == nil, phase != .loading {
            phaseBeforeProvisionalNavigation = phase
        }
        phase = .loading
    }

    func restorePhaseForMainFrameDownload() {
        let restoredPhase = phaseBeforeProvisionalNavigation
            ?? (phase == .loading ? .ready : phase)
        phaseRestoredForMainFrameDownload = restoredPhase
        phase = restoredPhase
    }

    func handleNavigationFailure(_ error: Error) {
        if let restoredPhase = phaseRestoredForMainFrameDownload,
           Self.isDownloadNavigationInterruption(error) {
            phase = restoredPhase
        } else {
            phase = .failed(error.localizedDescription)
        }
        clearNavigationPhaseTracking()
    }

    private func completeNavigation() {
        clearNavigationPhaseTracking()
        phase = .ready
    }

    private func completeMainFrameDownload(_ download: WKDownload) {
        guard mainFrameDownload === download else { return }
        if let restoredPhase = phaseRestoredForMainFrameDownload {
            phase = restoredPhase
        }
        clearNavigationPhaseTracking()
    }

    private func clearNavigationPhaseTracking() {
        phaseBeforeProvisionalNavigation = nil
        phaseRestoredForMainFrameDownload = nil
        mainFrameDownload = nil
    }

    static func shouldDownloadNavigationResponse(
        canShowMIMEType: Bool,
        contentDisposition: String?
    ) -> Bool {
        !canShowMIMEType || isAttachmentContentDisposition(contentDisposition)
    }

    private static func isAttachmentContentDisposition(_ value: String?) -> Bool {
        guard let dispositionType = value?
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) else {
            return false
        }
        return dispositionType.caseInsensitiveCompare("attachment") == .orderedSame
    }

    private static func isDownloadNavigationInterruption(_ error: Error) -> Bool {
        let nsError = error as NSError
        return (nsError.domain == "WebKitErrorDomain" && nsError.code == 102)
            || (nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled)
    }

    private func waitForSubmission(
        prompt: String,
        baselineMessageCount: Int,
        timeout: TimeInterval
    ) async -> PromptDispatchOutcome {
        let deadline = Date().addingTimeInterval(timeout)
        var didClickSend = false
        while Date() < deadline {
            if Task.isCancelled { return .failed("Send cancelled") }
            do {
                guard service.allowsPromptInjection(at: webView?.url) else {
                    return .failed("Provider page changed before sending")
                }
                if didClickSend {
                    if try await evaluate(
                        adapter.submissionConfirmationScript(
                            prompt: prompt,
                            baselineMessageCount: baselineMessageCount
                        ),
                        as: Bool.self
                    ) {
                        return .sent
                    }
                } else {
                    let result = try await evaluate(adapter.submissionScript(), as: ScriptResult.self)
                    didClickSend = result.ok
                }
            } catch {
                return .failed("Could not execute prompt")
            }
            do {
                try await Task.sleep(for: .milliseconds(180))
            } catch {
                return .failed("Send cancelled")
            }
        }
        if await isLoginRequired() { return .loginRequired }
        return didClickSend
            ? .failed("Could not confirm prompt was sent")
            : .failed("Send button did not become ready")
    }

    private func evaluate<Value: Decodable & Sendable>(_ script: String, as type: Value.Type) async throws -> Value {
        let json = try await evaluateJSON(script)
        return try JSONDecoder().decode(Value.self, from: Data(json.utf8))
    }

    private func evaluateJSON(_ script: String) async throws -> String {
        guard let webView else { throw BrowserError.webViewUnavailable }
        let wrappedScript = "JSON.stringify((\(script)))"
        return try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(wrappedScript) { value, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let json = value as? String {
                    continuation.resume(returning: json)
                } else {
                    continuation.resume(throwing: BrowserError.invalidJavaScriptResult)
                }
            }
        }
    }

}

private enum BrowserError: Error {
    case webViewUnavailable
    case invalidJavaScriptResult
}

private enum ComposerReadiness {
    case ready
    case loginRequired
    case unavailable
}

private struct ScriptResult: Decodable, Sendable {
    let ok: Bool
    let reason: String?
}

private struct VerificationDetails: Decodable, Sendable {
    let title: String
    let text: String
    let hasChallenge: Bool
}

extension BrowserController: WKNavigationDelegate {
    nonisolated func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        MainActor.assumeIsolated {
            // Provider-generated files commonly use blob: URLs, which are not
            // valid page destinations. Honor WebKit's explicit download signal
            // before applying the normal provider-navigation allowlist.
            if navigationAction.shouldPerformDownload {
                decisionHandler(.download)
                return
            }
            if navigationAction.targetFrame?.isMainFrame == false {
                decisionHandler(.allow)
                return
            }
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }
            if self.service.allowsNavigation(to: url) {
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
                self.openExternalURLIfSafe(url)
            }
        }
    }

    nonisolated func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void
    ) {
        MainActor.assumeIsolated {
            let contentDisposition = (navigationResponse.response as? HTTPURLResponse)?
                .value(forHTTPHeaderField: "Content-Disposition")
            if Self.shouldDownloadNavigationResponse(
                canShowMIMEType: navigationResponse.canShowMIMEType,
                contentDisposition: contentDisposition
            ) {
                decisionHandler(.download)
            } else {
                decisionHandler(.allow)
            }
        }
    }

    nonisolated func webView(
        _ webView: WKWebView,
        navigationAction: WKNavigationAction,
        didBecome download: WKDownload
    ) {
        MainActor.assumeIsolated {
            download.delegate = self
            if navigationAction.targetFrame?.isMainFrame == true {
                self.mainFrameDownload = download
                self.restorePhaseForMainFrameDownload()
            }
        }
    }

    nonisolated func webView(
        _ webView: WKWebView,
        navigationResponse: WKNavigationResponse,
        didBecome download: WKDownload
    ) {
        MainActor.assumeIsolated {
            download.delegate = self
            if navigationResponse.isForMainFrame {
                self.mainFrameDownload = download
                self.restorePhaseForMainFrameDownload()
            }
        }
    }

    nonisolated func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            guard self.webView === webView else { return }
            self.beginProvisionalNavigation()
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            guard self.webView === webView else { return }
            self.completeNavigation()
            Task { @MainActor in
                await self.detectVerificationChallenge(in: webView)
                await self.retryBlankInitialClaudeLoadIfNeeded(in: webView)
            }
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated {
            guard self.webView === webView else { return }
            self.handleNavigationFailure(error)
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated {
            guard self.webView === webView else { return }
            self.handleNavigationFailure(error)
        }
    }

    private func openExternalURLIfSafe(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(), ["https", "http", "mailto"].contains(scheme) else { return }
        NSWorkspace.shared.open(url)
    }

}

extension BrowserController: WKDownloadDelegate {
    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping @MainActor (URL?) -> Void
    ) {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = Self.safeDownloadFilename(suggestedFilename)
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.title = "Save Download"
        panel.prompt = "Save"

        let finish: @MainActor (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let destination = panel.url else {
                completionHandler(nil)
                return
            }

            do {
                // NSSavePanel already confirms replacement. WKDownload requires
                // a destination URL that does not exist when downloading begins.
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                completionHandler(destination)
            } catch {
                completionHandler(nil)
                self.presentDownloadError(error)
            }
        }

        if let window = webView?.window ?? NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(panel.runModal())
        }
    }

    func download(
        _ download: WKDownload,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @MainActor (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        completionHandler(.performDefaultHandling, nil)
    }

    func download(
        _ download: WKDownload,
        didFailWithError error: Error,
        resumeData: Data?
    ) {
        completeMainFrameDownload(download)
        let nsError = error as NSError
        guard !(nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled) else { return }
        presentDownloadError(error)
    }

    func downloadDidFinish(_ download: WKDownload) {
        completeMainFrameDownload(download)
    }

    private static func safeDownloadFilename(_ suggestedFilename: String) -> String {
        let filename = URL(fileURLWithPath: suggestedFilename).lastPathComponent
        return filename.isEmpty || filename == "." || filename == ".." ? "Download" : filename
    }

    private func presentDownloadError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Download Failed"
        alert.informativeText = error.localizedDescription
        if let window = webView?.window ?? NSApp.keyWindow {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}

extension BrowserController: WKUIDelegate {
    nonisolated func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor ([URL]?) -> Void
    ) {
        MainActor.assumeIsolated {
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = parameters.allowsMultipleSelection
            panel.canChooseDirectories = parameters.allowsDirectories
            panel.canChooseFiles = !parameters.allowsDirectories
            panel.resolvesAliases = true

            if let window = webView.window {
                panel.beginSheetModal(for: window) { response in
                    completionHandler(response == .OK ? panel.urls : nil)
                }
            } else {
                completionHandler(panel.runModal() == .OK ? panel.urls : nil)
            }
        }
    }

    nonisolated func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        // Disposing a provider-created WKWebView window can crash on macOS 26.
        // Use the system browser for new windows, which also gives those flows
        // their normal browser popup and authentication behavior.
        MainActor.assumeIsolated {
            if let url = navigationAction.request.url {
                self.openExternalURLIfSafe(url)
            }
            return nil
        }
    }
}

final class BrowserHostView: NSView {
    // The browser controller owns the web view. The host only tracks the view
    // while it is mounted so a cached SwiftUI host cannot keep a released
    // provider page and its WebContent process alive.
    private weak var hostedWebView: WKWebView?
    private var acceptsKeyboardInput = true
    private var windowAttachmentTask: Task<Void, Never>?
    var onWindowAttachment: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            scheduleWindowAttachment()
        } else {
            windowAttachmentTask?.cancel()
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            prepareHostedWebViewForDetachment()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    func install(_ webView: WKWebView) {
        guard hostedWebView !== webView else { return }
        prepareHostedWebViewForDetachment()
        hostedWebView?.removeFromSuperview()
        hostedWebView = webView
        webView.frame = bounds
        webView.autoresizingMask = [.width, .height]
        addSubview(webView)
        resignHostedFirstResponderIfNeeded()
    }

    func setAcceptsKeyboardInput(_ acceptsKeyboardInput: Bool) {
        self.acceptsKeyboardInput = acceptsKeyboardInput
        resignHostedFirstResponderIfNeeded()
    }

    func clear() {
        windowAttachmentTask?.cancel()
        windowAttachmentTask = nil
        // During a switch from a single pane to split view, SwiftUI may move
        // this WKWebView into its replacement host before dismantling this
        // host. Only remove a view we still own; otherwise the old host tears
        // the visible split-pane view back out of its new parent.
        if hostedWebView?.superview === self {
            prepareHostedWebViewForDetachment()
            hostedWebView?.removeFromSuperview()
        }
        hostedWebView = nil
    }

    /// SwiftUI can build transient representable hosts while animating between
    /// workspace layouts. Only a host attached to a real window may claim the
    /// controller-owned web view; otherwise a cached host can steal it from the
    /// visible pane and leave that pane blank.
    func synchronizeHostedWebView(_ webView: WKWebView?) {
        guard let window,
              DuetWindowRegistry.isActiveWorkspaceWindow(window) else { return }
        if let webView {
            install(webView)
        } else {
            clear()
        }
    }

    /// AppKit can attach or update this host while SwiftUI is still rendering.
    /// Defer activation and mount bookkeeping to the next main-actor turn so
    /// those callbacks never publish observable state from `updateNSView`.
    func scheduleWindowAttachment() {
        windowAttachmentTask?.cancel()
        windowAttachmentTask = Task { @MainActor [weak self] in
            for _ in 0..<40 {
                await Task.yield()
                guard !Task.isCancelled, let self, let window = self.window else { return }
                if DuetWindowRegistry.isActiveWorkspaceWindow(window) {
                    self.resignHostedFirstResponderIfNeeded()
                    self.onWindowAttachment?()
                    self.windowAttachmentTask = nil
                    return
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
            self?.windowAttachmentTask = nil
        }
    }

    private func resignHostedFirstResponderIfNeeded() {
        guard !acceptsKeyboardInput else { return }
        resignHostedFirstResponder()
    }

    private func prepareHostedWebViewForDetachment() {
        guard let hostedWebView, hostedWebView.superview === self else { return }
        resignHostedFirstResponder()
    }

    private func resignHostedFirstResponder() {
        guard let hostedWebView,
              let window,
              let firstResponder = window.firstResponder as? NSView,
              firstResponder === hostedWebView || firstResponder.isDescendant(of: hostedWebView) else { return }
        window.makeFirstResponder(nil)
    }
}

struct BrowserView: NSViewRepresentable {
    @ObservedObject var browser: BrowserController
    let acceptsKeyboardInput: Bool
    let onMounted: () -> Void

    func makeNSView(context: Context) -> BrowserHostView {
        let host = BrowserHostView()
        configure(host)
        host.setAcceptsKeyboardInput(acceptsKeyboardInput)
        return host
    }

    func updateNSView(_ nsView: BrowserHostView, context: Context) {
        configure(nsView)
        if browser.webView == nil {
            nsView.clear()
        }
        nsView.setAcceptsKeyboardInput(acceptsKeyboardInput)
        if nsView.window != nil {
            nsView.scheduleWindowAttachment()
        }
    }

    static func dismantleNSView(_ nsView: BrowserHostView, coordinator: ()) {
        nsView.clear()
    }

    private func configure(_ host: BrowserHostView) {
        host.onWindowAttachment = { [weak host, weak browser] in
            guard let host, let browser else { return }
            guard let webView = browser.webView else {
                host.clear()
                return
            }
            host.synchronizeHostedWebView(webView)
            browser.activateWhenHosted()
            onMounted()
        }
    }
}
