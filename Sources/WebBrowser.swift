import AppKit
import Combine
import SwiftUI
import WebKit

@MainActor
final class BrowserController: NSObject, ObservableObject {
    let service: ChatService
    private let adapter: ProviderAdapter

    @Published private(set) var phase: BrowserPhase = .unloaded
    private(set) var webView: WKWebView?
    private var hasRetriedBlankInitialClaudeLoad = false

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

        let newWebView = WKWebView(frame: .zero, configuration: configuration)
        newWebView.allowsBackForwardNavigationGestures = true
        newWebView.navigationDelegate = self
        newWebView.uiDelegate = self
        newWebView.setValue(false, forKey: "drawsBackground")
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
        let webView = prepare()
        guard webView.superview?.window != nil else { return }
        startInitialNavigationIfNeeded(in: webView)
    }

    func release() {
        guard let webView else { return }
        webView.stopLoading()
        webView.removeFromSuperview()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        self.webView = nil
        phase = .unloaded
    }

    func reload() {
        if let webView {
            phase = .loading
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
        let ready = await waitForComposer(timeout: timeout)
        guard ready else {
            if await isLoginRequired() { return .loginRequired }
            return .unavailable
        }

        do {
            guard service.allowsPromptInjection(at: webView?.url) else {
                return .failed("Provider page is not active")
            }
            let result = try await evaluate(adapter.fillScript(prompt: prompt), as: ScriptResult.self)
            guard result.ok else {
                if result.reason == "composer-not-found" {
                    return .unavailable
                }
                return .failed("Unexpected page response")
            }
            return await waitForSubmission(prompt: prompt, timeout: 4)
        } catch {
            return .failed("Could not talk to page")
        }
    }

    private func openNewConversation() {
        let webView = prepare()
        webView.stopLoading()
        phase = .loading
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

    private func waitForComposer(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if Task.isCancelled { return false }
            if await hasComposer() { return true }
            do {
                try await Task.sleep(for: .milliseconds(300))
            } catch {
                return false
            }
        }
        return false
    }

    private func startInitialNavigationIfNeeded(in webView: WKWebView) {
        guard phase == .unloaded else { return }
        phase = .loading
        webView.load(URLRequest(url: service.startURL))
    }

    private func hasComposer() async -> Bool {
        guard service.allowsPromptInjection(at: webView?.url) else { return false }
        return (try? await evaluate(adapter.readinessScript(), as: Bool.self)) ?? false
    }

    private func isLoginRequired() async -> Bool {
        (try? await evaluate(adapter.loginRequiredScript(), as: Bool.self)) ?? false
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
        phase = .loading
        loadedWebView.reload()
    }

    private func waitForSubmission(prompt: String, timeout: TimeInterval) async -> PromptDispatchOutcome {
        let deadline = Date().addingTimeInterval(timeout)
        var didClickSend = false
        while Date() < deadline {
            if Task.isCancelled { return .failed("Send cancelled") }
            do {
                guard service.allowsPromptInjection(at: webView?.url) else {
                    return .failed("Provider page changed before sending")
                }
                if didClickSend {
                    if try await evaluate(adapter.submissionConfirmationScript(prompt: prompt), as: Bool.self) {
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

    nonisolated func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        Task { @MainActor in
            guard self.webView === webView else { return }
            self.phase = .loading
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            guard self.webView === webView else { return }
            self.phase = .ready
            await self.detectVerificationChallenge(in: webView)
            await self.retryBlankInitialClaudeLoadIfNeeded(in: webView)
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            guard self.webView === webView else { return }
            self.phase = .failed(error.localizedDescription)
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            guard self.webView === webView else { return }
            self.phase = .failed(error.localizedDescription)
        }
    }

    private func openExternalURLIfSafe(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(), ["https", "http", "mailto"].contains(scheme) else { return }
        NSWorkspace.shared.open(url)
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
    private var hostedWebView: WKWebView?
    private var acceptsKeyboardInput = true
    var onWindowAttachment: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            resignHostedFirstResponderIfNeeded()
            onWindowAttachment?()
        }
    }

    func install(_ webView: WKWebView) {
        guard hostedWebView !== webView else { return }
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
        // During a switch from a single pane to split view, SwiftUI may move
        // this WKWebView into its replacement host before dismantling this
        // host. Only remove a view we still own; otherwise the old host tears
        // the visible split-pane view back out of its new parent.
        if hostedWebView?.superview === self {
            hostedWebView?.removeFromSuperview()
        }
        hostedWebView = nil
    }

    private func resignHostedFirstResponderIfNeeded() {
        guard !acceptsKeyboardInput,
              let hostedWebView,
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
        host.install(browser.prepare())
        host.setAcceptsKeyboardInput(acceptsKeyboardInput)
        return host
    }

    func updateNSView(_ nsView: BrowserHostView, context: Context) {
        configure(nsView)
        nsView.install(browser.prepare())
        nsView.setAcceptsKeyboardInput(acceptsKeyboardInput)
        if nsView.window != nil {
            browser.activateWhenHosted()
            onMounted()
        }
    }

    static func dismantleNSView(_ nsView: BrowserHostView, coordinator: ()) {
        nsView.clear()
    }

    private func configure(_ host: BrowserHostView) {
        host.onWindowAttachment = {
            browser.activateWhenHosted()
            onMounted()
        }
    }
}
