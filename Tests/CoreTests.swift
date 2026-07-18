import Foundation

@main
struct CoreTests {
    static func main() {
        var failures: [String] = []

        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() { failures.append(message) }
        }

        expect(ChatService.chatGPT.startURL.absoluteString == "https://www.chatgpt.com", "ChatGPT start URL changed")
        expect(ChatService.claude.startURL.absoluteString == "https://claude.ai", "Claude start URL changed")
        expect(ChatService.chatGPT.newConversationURL.absoluteString == "https://www.chatgpt.com/", "ChatGPT new conversation URL changed")
        expect(ChatService.claude.newConversationURL.absoluteString == "https://claude.ai/new", "Claude new conversation URL changed")
        expect(ChatService.allCases.count == 2, "Expected exactly two services")
        expect(ChatService.chatGPT.allowsNavigation(to: URL(string: "https://auth.openai.com/login")!), "ChatGPT auth host must be allowed")
        expect(ChatService.claude.allowsNavigation(to: URL(string: "https://accounts.google.com/signin")!), "Shared identity provider must be allowed")
        expect(!ChatService.chatGPT.allowsNavigation(to: URL(string: "http://chatgpt.com")!), "Non-HTTPS provider navigation must be rejected")
        expect(!ChatService.chatGPT.allowsNavigation(to: URL(string: "https://chatgpt.com.evil.example")!), "Host suffix spoof must be rejected")
        expect(!ChatService.chatGPT.allowsNavigation(to: URL(string: "https://example.com")!), "Unrelated navigation must be rejected")
        expect(ChatService.chatGPT.allowsPromptInjection(at: URL(string: "https://chatgpt.com/c/123")!), "ChatGPT prompt origin must be allowed")
        expect(!ChatService.chatGPT.allowsPromptInjection(at: URL(string: "https://openai.com")!), "Related marketing hosts must not receive prompt injection")
        expect(!ChatService.chatGPT.allowsPromptInjection(at: URL(string: "https://accounts.google.com/signin")!), "Authentication pages must not receive prompt injection")
        expect(ChatService.chatGPT.isAuthenticationPage(URL(string: "https://auth.openai.com/login")!), "Provider authentication host should require sign-in")
        expect(ChatService.claude.isAuthenticationPage(URL(string: "https://accounts.google.com/signin")!), "Shared identity host should require sign-in")
        expect(ChatService.claude.isAuthenticationPage(URL(string: "https://claude.ai/login")!), "Provider login path should require sign-in")
        expect(!ChatService.chatGPT.isAuthenticationPage(URL(string: "https://chatgpt.com/c/123")!), "Conversation pages must not be classified as authentication")
        expect(PromptDispatchOutcome.sent.wasSent, "Sent outcome must be marked sent")
        expect(!PromptDispatchOutcome.unavailable.wasSent, "Unavailable outcome must not be marked sent")
        expect(PromptDispatchOutcome.loginRequired.label == "Sign in required", "Login state must map correctly")
        expect(!PromptDispatchOutcome.loginRequired.isVisibleInDispatchNotice, "Sign-in results must not create persistent notices")
        expect(PromptDispatchOutcome.unavailable.isVisibleInDispatchNotice, "Non-authentication failures must remain visible")
        expect(!PromptDispatchOutcome.composerHasDraft.offersBrowserFallback, "Draft conflicts should stay in the provider pane")
        expect(UpdateChecker.isNewer(remote: "2.0.0", local: "1.9.9"), "A newer major version should be detected")
        expect(UpdateChecker.isNewer(remote: "1.4.0", local: "1.3.9"), "A newer minor version should be detected")
        expect(UpdateChecker.isNewer(remote: "1.3.1", local: "1.3.0"), "A newer patch version should be detected")
        expect(UpdateChecker.isNewer(remote: "1.0.1", local: "1.0"), "Missing local segments should be treated as zero")
        expect(!UpdateChecker.isNewer(remote: "1.0", local: "1.0.1"), "Missing remote segments should be treated as zero")
        expect(!UpdateChecker.isNewer(remote: "1.3.0", local: "1.3.0"), "Equal versions should not notify")
        expect(!UpdateChecker.isNewer(remote: "1.2.9", local: "1.3.0"), "Older versions should not notify")
        expect(UpdateChecker.isNewer(remote: "10.20.30", local: "10.20.29"), "Multi-digit segments must compare numerically")
        expect(UpdateChecker.normalizedVersion("v1.4.0") == "1.4.0", "Release tags should allow a leading v")
        expect(UpdateChecker.normalizedVersion(" 1.4.0 ") == "1.4.0", "Release versions should trim whitespace")
        expect(UpdateChecker.normalizedVersion("1.beta.0") == nil, "Non-numeric release versions should be rejected")
        expect(!UpdateChecker.isNewer(remote: "1..1", local: "1.0.0"), "Malformed versions should not compare as newer")

        for service in ChatService.allCases {
            let adapter = ProviderAdapter.adapter(for: service)
            let readiness = adapter.readinessScript()
            let fill = adapter.fillScript(prompt: "A quote: \\\" and a newline\\nnext line")
            let submit = adapter.submissionScript()
            let baseline = adapter.submissionBaselineScript()
            let confirmation = adapter.submissionConfirmationScript(prompt: "test", baselineMessageCount: 0)
            expect(readiness.contains("document.querySelector"), "\(service.title) readiness script has no selector")
            expect(fill.contains("InputEvent"), "\(service.title) fill script does not notify the page")
            expect(fill.contains("composer-not-empty"), "\(service.title) fill script does not protect provider drafts")
            expect(!fill.contains("sendButton.click()"), "\(service.title) fill script must not submit early")
            expect(submit.contains("sendButton.click()"), "\(service.title) submission script does not execute")
            expect(baseline.contains("userMessageSelectors"), "\(service.title) submission baseline has no provider evidence")
            expect(confirmation.contains("userMessageSelectors"), "\(service.title) confirmation script has no provider evidence")
            expect(fill.contains("A quote:"), "\(service.title) prompt was not encoded")
        }

        let fixtures = ["textarea.html", "contenteditable.html", "signed-out.html", "login-discussion.html", "delayed-send.html"]
        let fixtureDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Tests/Fixtures")
        for fixture in fixtures {
            let url = fixtureDirectory.appendingPathComponent(fixture)
            expect(FileManager.default.fileExists(atPath: url.path), "Missing fixture \(fixture)")
        }

        if failures.isEmpty {
            print("All Duet tests passed.")
        } else {
            failures.forEach { fputs("FAIL: \($0)\n", stderr) }
            exit(1)
        }
    }
}
