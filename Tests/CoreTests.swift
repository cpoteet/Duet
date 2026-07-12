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
        expect(ChatService.allCases.count == 2, "Expected exactly two services")
        expect(ChatService.chatGPT.allowsNavigation(to: URL(string: "https://auth.openai.com/login")!), "ChatGPT auth host must be allowed")
        expect(ChatService.claude.allowsNavigation(to: URL(string: "https://accounts.google.com/signin")!), "Shared identity provider must be allowed")
        expect(!ChatService.chatGPT.allowsNavigation(to: URL(string: "http://chatgpt.com")!), "Non-HTTPS provider navigation must be rejected")
        expect(!ChatService.chatGPT.allowsNavigation(to: URL(string: "https://chatgpt.com.evil.example")!), "Host suffix spoof must be rejected")
        expect(!ChatService.chatGPT.allowsNavigation(to: URL(string: "https://example.com")!), "Unrelated navigation must be rejected")
        expect(ChatService.chatGPT.allowsPromptInjection(at: URL(string: "https://chatgpt.com/c/123")!), "ChatGPT prompt origin must be allowed")
        expect(!ChatService.chatGPT.allowsPromptInjection(at: URL(string: "https://openai.com")!), "Related marketing hosts must not receive prompt injection")
        expect(!ChatService.chatGPT.allowsPromptInjection(at: URL(string: "https://accounts.google.com/signin")!), "Authentication pages must not receive prompt injection")
        expect(PromptDispatchOutcome.sent.wasSent, "Sent outcome must be marked sent")
        expect(!PromptDispatchOutcome.unavailable.wasSent, "Unavailable outcome must not be marked sent")
        expect(PromptDispatchOutcome.loginRequired.status == .loginRequired, "Login state must map correctly")

        for service in ChatService.allCases {
            let adapter = ProviderAdapter.adapter(for: service)
            let readiness = adapter.readinessScript()
            let fill = adapter.fillScript(prompt: "A quote: \\\" and a newline\\nnext line")
            let submit = adapter.submissionScript()
            let confirmation = adapter.submissionConfirmationScript(prompt: "test")
            expect(readiness.contains("document.querySelector"), "\(service.title) readiness script has no selector")
            expect(fill.contains("InputEvent"), "\(service.title) fill script does not notify the page")
            expect(!fill.contains("sendButton.click()"), "\(service.title) fill script must not submit early")
            expect(submit.contains("sendButton.click()"), "\(service.title) submission script does not execute")
            expect(confirmation.contains("userMessageSelectors"), "\(service.title) confirmation script has no provider evidence")
            expect(fill.contains("A quote:"), "\(service.title) prompt was not encoded")
        }

        let fixtures = ["textarea.html", "contenteditable.html", "signed-out.html", "delayed-send.html"]
        let fixtureDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Tests/Fixtures")
        for fixture in fixtures {
            let url = fixtureDirectory.appendingPathComponent(fixture)
            expect(FileManager.default.fileExists(atPath: url.path), "Missing fixture \(fixture)")
        }

        if failures.isEmpty {
            print("All Duet tests passed.")
        } else {
            failures.forEach { fputs("FAIL: \($0)\\n", stderr) }
            exit(1)
        }
    }
}
