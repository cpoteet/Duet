import AppKit
import Foundation
import WebKit

private enum IntegrationTestError: Error {
    case navigationFailed(String)
    case invalidJavaScriptResult
}

private struct ScriptResult: Decodable, Sendable {
    let ok: Bool
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

        let workspaceState = AppState()
        expect(workspaceState.isLaunchChooserVisible, "Workspace should begin at the tool chooser")
        workspaceState.openWorkspace(for: .service(.claude))
        expect(!workspaceState.isLaunchChooserVisible, "A provider destination should leave the tool chooser")
        expect(workspaceState.selectedService == .claude, "Claude destination should select Claude")
        expect(!workspaceState.isSplitView, "A single-provider destination should use one pane")
        let releasableClaudeView = workspaceState.browser(for: .claude).webView
        workspaceState.openWorkspace(for: .service(.chatGPT))
        workspaceState.browserDidMount(.chatGPT)
        expect(
            releasableClaudeView != nil && workspaceState.browser(for: .claude).webView == nil,
            "The default single-pane mode should release its inactive web view"
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
        expect(
            workspaceState.browser(for: .chatGPT).webView == nil,
            "Turning faster switching off should immediately release the inactive provider"
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
            try await testSignedOutFixture(failures: &failures)
        } catch {
            failures.append("Fixture integration test threw: \(error)")
        }

        if failures.isEmpty {
            print("Browser host and fixture integration tests passed.")
        } else {
            failures.forEach { fputs("FAIL: \($0)\n", stderr) }
            exit(1)
        }
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

        let fill: ScriptResult = try await evaluate(adapter.fillScript(prompt: prompt), in: webView)
        expect(fill.ok, "\(name) composer was not filled", failures: &failures)

        let beforeClick: Bool = try await evaluate(
            adapter.submissionConfirmationScript(prompt: prompt),
            in: webView
        )
        expect(!beforeClick, "\(name) reported submission before click", failures: &failures)

        let submit: ScriptResult = try await evaluate(adapter.submissionScript(), in: webView)
        expect(submit.ok, "\(name) send control was not clicked", failures: &failures)

        let confirmed: Bool = try await evaluate(
            adapter.submissionConfirmationScript(prompt: prompt),
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
        _ = try await evaluate(adapter.fillScript(prompt: prompt), in: webView) as ScriptResult

        let early: ScriptResult = try await evaluate(adapter.submissionScript(), in: webView)
        expect(!early.ok, "Delayed send control was available too early", failures: &failures)
        try await Task.sleep(for: .milliseconds(350))

        let submit: ScriptResult = try await evaluate(adapter.submissionScript(), in: webView)
        expect(submit.ok, "Delayed send control never became ready", failures: &failures)
        let confirmed: Bool = try await evaluate(
            adapter.submissionConfirmationScript(prompt: prompt),
            in: webView
        )
        expect(confirmed, "Delayed submission was not confirmed", failures: &failures)
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
