import AppKit
import Combine
import Darwin
import SwiftUI
import WebKit

@MainActor
final class BrowserController: NSObject, ObservableObject {
    let service: ChatService
    private let adapter: ProviderAdapter

    @Published private(set) var phase: BrowserPhase = .unloaded
    @Published private(set) var webView: WKWebView?
    var reservesFocusForPrompt = false
    var restorePromptFocus: () -> Void = {}
    /// Called when the web view leaves its pane, a turn after the pane lets
    /// go, so the owner can release a provider that is no longer shown.
    var webViewDidLeavePane: () -> Void = {}
    private lazy var notificationBridge = NotificationBridge(
        service: service,
        presenter: DuetNotificationManager.shared
    )
    private lazy var locationBridge = LocationBridge(service: service)
    private lazy var printingBridge = PrintingBridge(service: service, presenter: self)
    private var hasRetriedBlankInitialLoad = false
    /// Set while a send holds the keyboard focus lease.
    private var holdsKeyboardFocus = false
    /// Set while a send holds keyboard focus that belongs to the prompt drawer.
    private var owesPromptFocus = false
    // WebKit ends a main-frame navigation with error 102 after converting it
    // into a WKDownload. Preserve the page's prior phase for that exact path.
    private var phaseBeforeProvisionalNavigation: BrowserPhase?
    private var phaseRestoredForMainFrameDownload: BrowserPhase?
    private weak var mainFrameDownload: WKDownload?
    private var downloadDestinations: [ObjectIdentifier: (staging: URL, destination: URL)] = [:]

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
        locationBridge.install(in: configuration)
        printingBridge.install(in: configuration)
        if let fileDropScript = adapter.fileDropCompatibilityScript() {
            configuration.userContentController.addUserScript(WKUserScript(
                source: fileDropScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            ))
        }

        let newWebView = ProviderWebView(frame: .zero, configuration: configuration)
        newWebView.reservesFocusForPrompt = { [weak self] in self?.reservesFocusForPrompt == true }
        newWebView.onRefusedFocus = { [weak self] in self?.restorePromptFocus() }
        newWebView.onLeftSuperview = { [weak self] in self?.webViewDidLeavePane() }
        newWebView.allowsBackForwardNavigationGestures = true
        newWebView.navigationDelegate = self
        newWebView.uiDelegate = self
        // WKWebView otherwise paints an opaque white base before its document
        // has a chance to render. There's no public switch, so use WebKit's
        // private setter, which KVC reaches through `drawsBackground`. Check
        // for it first: KVC throws an exception for a key WebKit drops.
        if newWebView.responds(to: NSSelectorFromString("_setDrawsBackground:")) {
            newWebView.setValue(false, forKey: "drawsBackground")
        }
        newWebView.underPageBackgroundColor = .clear
        webView = newWebView
        hasRetriedBlankInitialLoad = false
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
            let needsFreshRequest = phase.failureMessage != nil || webView.url == nil
            beginProgrammaticNavigation()
            if needsFreshRequest {
                webView.load(URLRequest(url: service.startURL))
            } else {
                webView.reload()
            }
        } else {
            _ = acquire()
        }
    }

    func openInDefaultBrowser() {
        NSWorkspace.shared.open(service.startURL)
    }

    func dispatch(
        prompt: String,
        startsNewConversation: Bool = false
    ) async -> PromptDispatchOutcome {
        // A new conversation is a fresh page load, so give it the cold-load wait.
        let readinessTimeout = startsNewConversation ? BrowserPhase.loading.promptReadinessTimeout : phase.promptReadinessTimeout
        if startsNewConversation {
            openNewConversation()
        } else {
            _ = acquire()
        }
        switch await waitForComposer(timeout: readinessTimeout) {
        case .ready:
            break
        case .loginRequired:
            return .loginRequired
        case .unavailable:
            return .unavailable
        }

        do {
            guard service.allowsPromptInjection(at: webView?.url) else {
                return .failed("Not sent, the page isn't showing a chat")
            }
            await beginKeyboardFocus()
            defer { endKeyboardFocus() }
            let result = try await evaluate(adapter.fillScript(prompt: prompt), as: ScriptResult.self)
            guard result.ok else {
                if result.reason == "composer-not-found" {
                    return .unavailable
                }
                if result.reason == "composer-not-empty" {
                    return .composerHasDraft
                }
                return .failed("Not sent, couldn't fill its message box")
            }
            return await waitForSubmission(prompt: prompt)
        } catch {
            return .failed("Not sent, couldn't reach the page")
        }
    }

    /// Fill and Return both need the page to hold keyboard focus: while
    /// another view has it, WebKit skips editing commands, so the fill would
    /// fall back to setting text the provider may not register. Send to
    /// Both's web views share a window, so they take turns.
    private func beginKeyboardFocus() async {
        guard !holdsKeyboardFocus else { return }
        await KeyboardFocusLease.shared.acquire()
        holdsKeyboardFocus = true
        owesPromptFocus = reservesFocusForPrompt
        (webView as? ProviderWebView)?.takeKeyboardFocus()
    }

    /// Ends this send's turn with keyboard focus. The last send to finish
    /// gives focus back to the prompt drawer, unless the drawer has closed or
    /// the page no longer holds focus, such as after the user clicked
    /// somewhere else. Giving it back between turns would let the drawer
    /// take focus from the next send in the middle of its fill.
    private func endKeyboardFocus() {
        guard holdsKeyboardFocus else { return }
        holdsKeyboardFocus = false
        let owedPromptFocus = owesPromptFocus
        owesPromptFocus = false
        let anotherSendIsWaiting = KeyboardFocusLease.shared.release()
        guard owedPromptFocus, !anotherSendIsWaiting, reservesFocusForPrompt,
              (webView as? ProviderWebView)?.hasKeyboardFocus == true else { return }
        restorePromptFocus()
    }

    func openNewConversation() {
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
        let matches = records.filter { service.ownsWebsiteDataRecord(named: $0.displayName) }
        if !matches.isEmpty {
            await withCheckedContinuation { continuation in
                dataStore.removeData(ofTypes: recordTypes, for: matches) { continuation.resume() }
            }
        }
        release()
        _ = prepare()
    }

    private func waitForComposer(timeout: TimeInterval) async -> ComposerReadiness {
        let deadline = Date().addingTimeInterval(timeout)
        var nextLoginCheck = Date.distantPast
        while Date() < deadline {
            if Task.isCancelled { return .unavailable }
            if case .failed = phase { return .unavailable }
            if phase == .verificationRequired { return .unavailable }
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
        guard phase == .ready else { return false }
        guard service.allowsPromptInjection(at: webView?.url) else { return false }
        return (try? await evaluate(adapter.readinessScript(), as: Bool.self)) ?? false
    }

    private func isLoginRequired() async -> Bool {
        guard let url = webView?.url else { return false }
        if service.isAuthenticationPage(url) { return true }
        guard service.allowsPromptInjection(at: url) else { return false }
        return (try? await evaluate(adapter.loginRequiredScript(), as: Bool.self)) ?? false
    }

    /// Some providers can complete a navigation while showing only a bot-check
    /// interstitial in an embedded renderer. Surface that separately from a
    /// normal page failure.
    private func detectVerificationChallenge(in loadedWebView: WKWebView) async {
        guard webView === loadedWebView, let script = adapter.verificationChallengeScript() else { return }
        guard (try? await evaluate(script, as: Bool.self)) == true, webView === loadedWebView else { return }
        phase = .verificationRequired
    }

    /// A provider's first embedded navigation can occasionally finish with an
    /// empty root document. Retrying that one unusable result avoids requiring
    /// the user to switch away and back, while leaving normal navigation alone.
    private func retryBlankInitialLoadIfNeeded(in loadedWebView: WKWebView) async {
        guard !hasRetriedBlankInitialLoad, webView === loadedWebView,
              let script = adapter.blankPageScript() else { return }

        // `didFinish` arrives before the provider's client-side app renders,
        // and nothing signals when it has. Give it a moment before treating
        // the document as blank.
        try? await Task.sleep(for: .milliseconds(800))
        guard webView === loadedWebView else { return }
        guard (try? await evaluate(script, as: Bool.self)) == true, webView === loadedWebView else { return }

        hasRetriedBlankInitialLoad = true
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
        } else if Self.isSupersededNavigation(error) {
            // WebKit cancels a provisional load when another navigation
            // replaces it, such as New Conversation during a page load. The
            // replacement drives the phase from here, so don't show a failure.
            // Phase tracking is kept on purpose: the replacement inherits the
            // pre-load phase in case it turns into a main-frame download.
            return
        } else {
            let navigationError = error as NSError
            let message = navigationError.domain == NSURLErrorDomain && navigationError.code == NSURLErrorTimedOut
                ? "The page took too long to respond."
                : error.localizedDescription
            phase = .failed(message)
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

    static func mediaCapturePermissionDecision(
        service: ChatService,
        originProtocol: String,
        originHost: String,
        frameURL: URL?,
        currentPageURL: URL?,
        type: WKMediaCaptureType
    ) -> WKPermissionDecision {
        guard service.isProviderPageOrigin(protocol: originProtocol, host: originHost),
              service.allowsNativePermission(at: frameURL),
              service.allowsNativePermission(at: currentPageURL) else {
            return .deny
        }

        switch type {
        case .microphone:
            return .grant
        case .camera, .cameraAndMicrophone:
            return .prompt
        @unknown default:
            return .deny
        }
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
            || isSupersededNavigation(error)
    }

    private static func isSupersededNavigation(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    /// Once Return has been pressed, a failure can no longer claim "not sent".
    private func cancelledOutcome(didPressReturn: Bool) -> PromptDispatchOutcome {
        didPressReturn
            ? .failed("Couldn't confirm it sent, the send was cancelled")
            : .failed("Not sent, the send was cancelled")
    }

    /// How long a filled composer has to hold the prompt with focus.
    private static let returnKeyTimeout: TimeInterval = 4
    /// How long the provider has to confirm after Return is pressed.
    private static let submissionConfirmationTimeout: TimeInterval = 10

    /// Sends with a real Return keypress, the way a user would, rather than
    /// finding and clicking the provider's Send button. The composer clearing
    /// confirms the send, and so does a new conversation's URL appearing.
    /// Nothing here retries Return: a second press could send twice.
    private func waitForSubmission(prompt: String) async -> PromptDispatchOutcome {
        var deadline = Date().addingTimeInterval(Self.returnKeyTimeout)
        var didPressReturn = false
        var urlBeforeReturn: URL?
        var hasGivenPageTimeWithFocus = false
        while Date() < deadline {
            if Task.isCancelled { return cancelledOutcome(didPressReturn: didPressReturn) }
            do {
                guard service.allowsPromptInjection(at: webView?.url) else {
                    return didPressReturn
                        ? .failed("Couldn't confirm it sent, the page changed")
                        : .failed("Not sent, the page changed first")
                }
                if didPressReturn {
                    if adapter.startedConversation(from: urlBeforeReturn, to: webView?.url) {
                        return .sent
                    }
                    if try await evaluate(adapter.submissionConfirmationScript(), as: Bool.self) {
                        return .sent
                    }
                } else {
                    let result = try await evaluate(adapter.returnKeyTargetScript(prompt: prompt), as: ScriptResult.self)
                    if result.ok, let providerWebView = webView as? ProviderWebView {
                        urlBeforeReturn = providerWebView.url
                        providerWebView.pressReturnKey()
                        didPressReturn = true
                        deadline = Date().addingTimeInterval(Self.submissionConfirmationTimeout)
                    }
                }
            } catch {
                return didPressReturn
                    ? .failed("Couldn't confirm it sent, lost contact with the page")
                    : .failed("Typed but not sent, lost contact with the page")
            }
            do {
                try await Task.sleep(for: .milliseconds(180))
            } catch {
                return cancelledOutcome(didPressReturn: didPressReturn)
            }
            // The send took keyboard focus for the page. Once the page has had
            // a moment with Return, give it back to an open prompt drawer
            // rather than holding it while the send confirms.
            if didPressReturn, !hasGivenPageTimeWithFocus {
                hasGivenPageTimeWithFocus = true
                endKeyboardFocus()
            }
        }
        if await isLoginRequired() { return .loginRequired }
        guard didPressReturn else {
            return .failed("Typed but not sent, couldn't press Return")
        }
        if (try? await evaluate(adapter.composerHoldsPromptScript(prompt: prompt), as: Bool.self)) == true {
            return .failed("Typed but not sent, Return didn't send it")
        }
        return .failed("Couldn't confirm it sent, check the chat")
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

/// Lets one send at a time hold keyboard focus for its web view.
@MainActor
final class KeyboardFocusLease {
    static let shared = KeyboardFocusLease()
    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        guard isHeld else {
            isHeld = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Hands the lease to the next waiting send, if any, and reports whether
    /// there was one.
    @discardableResult
    func release() -> Bool {
        guard !waiters.isEmpty else {
            isHeld = false
            return false
        }
        waiters.removeFirst().resume()
        return true
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

extension BrowserController: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
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

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void
    ) {
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

    func webView(
        _ webView: WKWebView,
        navigationAction: WKNavigationAction,
        didBecome download: WKDownload
    ) {
        download.delegate = self
        if navigationAction.targetFrame?.isMainFrame == true {
            self.mainFrameDownload = download
            self.restorePhaseForMainFrameDownload()
        }
    }

    func webView(
        _ webView: WKWebView,
        navigationResponse: WKNavigationResponse,
        didBecome download: WKDownload
    ) {
        download.delegate = self
        if navigationResponse.isForMainFrame {
            self.mainFrameDownload = download
            self.restorePhaseForMainFrameDownload()
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard self.webView === webView else { return }
        self.beginProvisionalNavigation()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard self.webView === webView else { return }
        self.completeNavigation()
        Task { @MainActor in
            await self.detectVerificationChallenge(in: webView)
            await self.retryBlankInitialLoadIfNeeded(in: webView)
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard self.webView === webView else { return }
        self.handleNavigationFailure(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard self.webView === webView else { return }
        self.handleNavigationFailure(error)
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

            let staging = DownloadFileReplacement.stagingURL(for: destination)
            self.downloadDestinations[ObjectIdentifier(download)] = (staging, destination)
            completionHandler(staging)
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
        if let files = downloadDestinations.removeValue(forKey: ObjectIdentifier(download)) {
            DownloadFileReplacement.discard(files.staging)
        }
        let nsError = error as NSError
        guard !(nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled) else { return }
        presentDownloadError(error)
    }

    func downloadDidFinish(_ download: WKDownload) {
        completeMainFrameDownload(download)
        guard let files = downloadDestinations.removeValue(forKey: ObjectIdentifier(download)) else { return }
        do {
            try DownloadFileReplacement.commit(files.staging, to: files.destination)
        } catch {
            DownloadFileReplacement.discard(files.staging)
            presentDownloadError(error)
        }
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

extension BrowserController: WebPagePrintPresenting {
    func presentPrintPanel(for webView: WKWebView) {
        guard webView === self.webView else { return }

        let printInfo = NSPrintInfo.shared.copy() as? NSPrintInfo ?? NSPrintInfo.shared
        let operation = webView.printOperation(with: printInfo)
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true

        if let window = webView.window {
            operation.runModal(
                for: window,
                delegate: nil,
                didRun: nil,
                contextInfo: nil
            )
        } else {
            operation.run()
        }
    }
}

extension BrowserController: WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void
    ) {
        guard self.webView === webView else {
            decisionHandler(.deny)
            return
        }
        decisionHandler(Self.mediaCapturePermissionDecision(
            service: self.service,
            originProtocol: origin.protocol,
            originHost: origin.host,
            frameURL: frame.request.url,
            currentPageURL: webView.url,
            type: type
        ))
    }

    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor ([URL]?) -> Void
    ) {
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

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        // Disposing a provider-created WKWebView window can crash on macOS 26.
        // Use the system browser for new windows, which also gives those flows
        // their normal browser popup and authentication behavior.
        if let url = navigationAction.request.url {
            self.openExternalURLIfSafe(url)
        }
        return nil
    }
}

enum DownloadFileReplacement {
    static func stagingURL(for destination: URL) -> URL {
        destination.deletingLastPathComponent()
            .appendingPathComponent(".duet-\(UUID().uuidString).download")
    }

    static func commit(_ staging: URL, to destination: URL) throws {
        guard rename(staging.path, destination.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    static func discard(_ staging: URL) {
        try? FileManager.default.removeItem(at: staging)
    }
}

final class BrowserHostView: NSView {
    private enum Canvas {
        static let dark = NSColor(red: 0.055, green: 0.06, blue: 0.07, alpha: 1)
        static let light = NSColor(red: 0.955, green: 0.952, blue: 0.94, alpha: 1)
    }

    // The browser controller owns the web view. The host only tracks the view
    // while it is mounted so a cached SwiftUI host cannot keep a released
    // provider page and its WebContent process alive.
    private weak var hostedWebView: WKWebView?
    private var acceptsKeyboardInput = true
    private var windowAttachmentTask: Task<Void, Never>?
    private var isWaitingForRegistration = false
    var onWindowAttachment: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureCanvas()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureCanvas()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateCanvasColor()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            scheduleWindowAttachment()
        } else {
            windowAttachmentTask?.cancel()
            stopWaitingForWorkspaceRegistration()
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            prepareHostedWebViewForDetachment()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    func install(_ webView: WKWebView) {
        // Check where the view actually is, not what this host last held:
        // another host may have taken it since. During a quick switch
        // between layouts SwiftUI keeps the outgoing host alive, so a host
        // that skipped reclaiming its view left that view inside a host
        // about to be torn down, and the pane went blank.
        guard webView.superview !== self else { return }
        if let previousWebView = hostedWebView, previousWebView !== webView, previousWebView.superview === self {
            prepareHostedWebViewForDetachment()
            previousWebView.removeFromSuperview()
        }
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
        stopWaitingForWorkspaceRegistration()
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
    /// Repeated calls in one turn coalesce into a single attachment.
    func scheduleWindowAttachment() {
        windowAttachmentTask?.cancel()
        windowAttachmentTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self else { return }
            self.windowAttachmentTask = nil
            self.attachIfActiveWorkspace()
        }
    }

    /// A reopened window's hosts can arrive before the window registers as
    /// the workspace. Until it does, wait for the registration.
    private func attachIfActiveWorkspace() {
        guard let window else { return }
        guard DuetWindowRegistry.isActiveWorkspaceWindow(window) else {
            waitForWorkspaceRegistration()
            return
        }
        stopWaitingForWorkspaceRegistration()
        resignHostedFirstResponderIfNeeded()
        onWindowAttachment?()
    }

    private func waitForWorkspaceRegistration() {
        guard !isWaitingForRegistration else { return }
        isWaitingForRegistration = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(workspaceDidRegister),
            name: DuetWindowRegistry.didRegisterWorkspaceNotification,
            object: nil
        )
    }

    private func stopWaitingForWorkspaceRegistration() {
        guard isWaitingForRegistration else { return }
        isWaitingForRegistration = false
        NotificationCenter.default.removeObserver(
            self,
            name: DuetWindowRegistry.didRegisterWorkspaceNotification,
            object: nil
        )
    }

    @objc private func workspaceDidRegister(_ notification: Notification) {
        guard let registeredWindow = notification.object as? NSWindow, registeredWindow === window else { return }
        scheduleWindowAttachment()
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

    private func configureCanvas() {
        wantsLayer = true
        updateCanvasColor()
    }

    private func updateCanvasColor() {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        layer?.backgroundColor = (isDark ? Canvas.dark : Canvas.light).cgColor
    }
}

/// While the prompt drawer is open, pages may not move keyboard focus into themselves; only the user and Duet's own Return keypress can.
final class ProviderWebView: WKWebView {
    var reservesFocusForPrompt: () -> Bool = { false }
    var onRefusedFocus: () -> Void = {}
    var onLeftSuperview: () -> Void = {}
    private var isTakingFocusForKeyPress = false

    /// Makes this view first responder in its window for Duet's own input,
    /// even past an open prompt drawer. WebKit runs editing commands and the
    /// default actions of key events only while the view is first responder
    /// in its window. Only that window changes: neither the key window nor
    /// the active app does. A view with no window needs nothing.
    func takeKeyboardFocus() {
        guard let window, !hasKeyboardFocus else { return }
        isTakingFocusForKeyPress = true
        window.makeFirstResponder(self)
        isTakingFocusForKeyPress = false
    }

    var hasKeyboardFocus: Bool {
        guard let firstResponder = window?.firstResponder as? NSView else { return false }
        return firstResponder === self || firstResponder.isDescendant(of: self)
    }

    /// Presses Return in the page through AppKit, so the page gets a trusted
    /// keyboard event, unlike a script-made `KeyboardEvent`, and handles it as
    /// if the user typed it. The event goes to the page's focused element.
    func pressReturnKey() {
        takeKeyboardFocus()
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(
                with: type,
                location: .zero,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window?.windowNumber ?? 0,
                context: nil,
                characters: "\r",
                charactersIgnoringModifiers: "\r",
                isARepeat: false,
                keyCode: Self.returnKeyCode
            ) else { continue }
            if type == .keyDown {
                keyDown(with: event)
            } else {
                keyUp(with: event)
            }
        }
    }

    /// `kVK_Return`.
    private static let returnKeyCode: UInt16 = 36

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        guard superview == nil else { return }
        // SwiftUI removes a pane's view while it dismantles the pane, so
        // report it on the next turn rather than from inside that update.
        Task { @MainActor [onLeftSuperview] in onLeftSuperview() }
    }

    override func becomeFirstResponder() -> Bool {
        guard isTakingFocusForKeyPress || !reservesFocusForPrompt() || isUserFocusEvent(NSApp.currentEvent) else {
            // AppKit has already taken focus from the prompt, so hand it back once this attempt ends.
            Task { @MainActor [onRefusedFocus] in onRefusedFocus() }
            return false
        }
        return super.becomeFirstResponder()
    }

    private func isUserFocusEvent(_ event: NSEvent?) -> Bool {
        guard let event, event.window === window else { return false }
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            return bounds.contains(convert(event.locationInWindow, from: nil))
        case .keyDown:
            return event.keyCode == 48
        default:
            return false
        }
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
        // The same host survives a release and re-prepare of its web view
        // (Quick Prompt does this), so every update re-attaches and reports
        // the mount again. Both steps do nothing when nothing changed.
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
