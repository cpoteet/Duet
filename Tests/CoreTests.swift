import Foundation
import JavaScriptCore

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

        let chatGPTAdapter = ProviderAdapter.adapter(for: .chatGPT)
        let claudeAdapter = ProviderAdapter.adapter(for: .claude)
        let url = { (string: String) in URL(string: string) }
        expect(
            chatGPTAdapter.startedConversation(from: ChatService.chatGPT.newConversationURL, to: url("https://chatgpt.com/c/abc123")),
            "A ChatGPT new conversation moving to /c/<id> should confirm the send"
        )
        expect(
            chatGPTAdapter.startedConversation(from: url("https://chatgpt.com/g/g-p-123/project"), to: url("https://chatgpt.com/g/g-p-123/c/abc")),
            "A ChatGPT project conversation should confirm the send"
        )
        expect(
            !chatGPTAdapter.startedConversation(from: url("https://chatgpt.com/c/abc"), to: url("https://chatgpt.com/c/abc")),
            "An existing ChatGPT conversation must not confirm from its URL"
        )
        expect(
            !chatGPTAdapter.startedConversation(from: url("https://chatgpt.com/"), to: url("https://chatgpt.com/c/")),
            "A conversation path with no ID must not confirm"
        )
        expect(
            claudeAdapter.startedConversation(from: ChatService.claude.newConversationURL, to: url("https://claude.ai/chat/4c1e")),
            "A Claude new conversation moving to /chat/<id> should confirm the send"
        )
        expect(
            !claudeAdapter.startedConversation(from: url("https://claude.ai/chat/4c1e"), to: url("https://claude.ai/chat/9f2a")),
            "Moving between existing Claude conversations must not confirm"
        )
        expect(
            !claudeAdapter.startedConversation(from: url("https://claude.ai/new"), to: url("https://claude.ai/c/4c1e")),
            "Claude must use its own conversation path, not ChatGPT's"
        )
        expect(BrowserPhase.loading.promptReadinessTimeout > 12, "A cold provider must have time to finish loading before prompt dispatch gives up")
        expect(BrowserPhase.unloaded.promptReadinessTimeout == BrowserPhase.loading.promptReadinessTimeout, "An unloaded provider needs the same cold-load wait")
        expect(BrowserPhase.ready.promptReadinessTimeout == 12, "A loaded page with no composer should fail promptly")
        expect(BrowserPhase.failed("The request timed out.").failureMessage == "The request timed out.", "A failed provider load must expose its error for the pane")
        expect(BrowserPhase.loading.failureMessage == nil, "A loading provider must not show a failure")
        expect(StartupDestination.askEveryTime.title == "Ask Every Time", "Ask-every-time startup label changed")
        expect(
            StartupDestination.chatGPT.resolvedPromptTarget(lastWorkspaceDestinationRawValue: nil) == .service(.chatGPT),
            "ChatGPT startup destination should open ChatGPT"
        )
        expect(
            StartupDestination.claude.resolvedPromptTarget(lastWorkspaceDestinationRawValue: nil) == .service(.claude),
            "Claude startup destination should open Claude"
        )
        expect(
            StartupDestination.both.resolvedPromptTarget(lastWorkspaceDestinationRawValue: nil) == .both,
            "Both startup destination should open split view"
        )
        expect(
            StartupDestination.lastUsed.resolvedPromptTarget(lastWorkspaceDestinationRawValue: StartupDestination.claude.rawValue) == .service(.claude),
            "Last Used should restore its saved provider"
        )
        expect(
            StartupDestination.lastUsed.resolvedPromptTarget(lastWorkspaceDestinationRawValue: "invalid") == nil,
            "An invalid Last Used destination should show the chooser"
        )
        expect(ChatService.chatGPT.allowsNavigation(to: URL(string: "https://auth.openai.com/login")!), "ChatGPT auth host must be allowed")
        expect(ChatService.claude.allowsNavigation(to: URL(string: "https://accounts.google.com/signin")!), "Shared identity provider must be allowed")
        expect(!ChatService.chatGPT.allowsNavigation(to: URL(string: "http://chatgpt.com")!), "Non-HTTPS provider navigation must be rejected")
        expect(!ChatService.chatGPT.allowsNavigation(to: URL(string: "https://chatgpt.com.evil.example")!), "Host suffix spoof must be rejected")
        expect(!ChatService.chatGPT.allowsNavigation(to: URL(string: "https://example.com")!), "Unrelated navigation must be rejected")
        expect(ChatService.chatGPT.allowsPromptInjection(at: URL(string: "https://chatgpt.com/c/123")!), "ChatGPT prompt origin must be allowed")
        expect(!ChatService.chatGPT.allowsPromptInjection(at: URL(string: "https://openai.com")!), "Related marketing hosts must not receive prompt injection")
        expect(!ChatService.chatGPT.allowsPromptInjection(at: URL(string: "https://accounts.google.com/signin")!), "Authentication pages must not receive prompt injection")
        expect(ChatService.chatGPT.isProviderPageOrigin(protocol: "https", host: "www.chatgpt.com"), "ChatGPT provider pages must be allowed to request media capture")
        expect(ChatService.claude.isProviderPageOrigin(protocol: "HTTPS", host: "CLAUDE.AI"), "Claude media-capture origins should be case-insensitive")
        expect(!ChatService.chatGPT.isProviderPageOrigin(protocol: "http", host: "chatgpt.com"), "Non-HTTPS media capture must be rejected")
        expect(!ChatService.chatGPT.isProviderPageOrigin(protocol: "https", host: "chatgpt.com.evil.example"), "Media-capture host suffix spoof must be rejected")
        expect(!ChatService.chatGPT.isProviderPageOrigin(protocol: "https", host: "auth.openai.com"), "Authentication pages must not receive media capture access")
        expect(ChatService.chatGPT.isAuthenticationPage(URL(string: "https://auth.openai.com/login")!), "Provider authentication host should require sign-in")
        expect(ChatService.claude.isAuthenticationPage(URL(string: "https://accounts.google.com/signin")!), "Shared identity host should require sign-in")
        expect(ChatService.claude.isAuthenticationPage(URL(string: "https://claude.ai/login")!), "Provider login path should require sign-in")
        expect(!ChatService.chatGPT.isAuthenticationPage(URL(string: "https://chatgpt.com/c/123")!), "Conversation pages must not be classified as authentication")
        expect(ChatService.chatGPT.ownsWebsiteDataRecord(named: "chatgpt.com"), "ChatGPT reset must remove chatgpt.com records")
        expect(ChatService.chatGPT.ownsWebsiteDataRecord(named: "OpenAI.com"), "ChatGPT reset must match record names case-insensitively")
        expect(ChatService.claude.ownsWebsiteDataRecord(named: "anthropic.com"), "Claude reset must remove anthropic.com records")
        expect(!ChatService.claude.ownsWebsiteDataRecord(named: "notclaude.ai"), "Claude reset must not remove a lookalike domain")
        expect(!ChatService.claude.ownsWebsiteDataRecord(named: "chatgpt.com"), "Claude reset must not remove ChatGPT records")
        expect(!ChatService.chatGPT.ownsWebsiteDataRecord(named: "claude.ai"), "ChatGPT reset must not remove Claude records")
        expect(PromptDispatchOutcome.sent.wasSent, "Sent outcome must be marked sent")
        expect(!PromptDispatchOutcome.unavailable.wasSent, "Unavailable outcome must not be marked sent")
        expect(PromptDispatchOutcome.loginRequired.label == "Not sent, sign in first", "Login state must map correctly")
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

        // Cloudflare marks a challenge response with `cf-mitigated: challenge`,
        // whatever its status code.
        let challengeResponse = { (status: Int, headers: [String: String]) in
            HTTPURLResponse(url: URL(string: "https://claude.ai/new")!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        }
        expect(
            claudeAdapter.isVerificationChallengeResponse(challengeResponse(403, ["cf-mitigated": "challenge"])),
            "A cf-mitigated challenge response should mark Claude as needing verification"
        )
        expect(
            claudeAdapter.isVerificationChallengeResponse(challengeResponse(200, ["CF-Mitigated": " Challenge "])),
            "The challenge header should match whatever its case, spacing, or status"
        )
        expect(
            !claudeAdapter.isVerificationChallengeResponse(challengeResponse(403, [:])),
            "A 403 without the challenge header must not count as a challenge"
        )
        expect(
            !claudeAdapter.isVerificationChallengeResponse(challengeResponse(200, ["cf-mitigated": "block"])),
            "Only the challenge value of cf-mitigated counts"
        )
        expect(
            !chatGPTAdapter.isVerificationChallengeResponse(challengeResponse(403, ["cf-mitigated": "challenge"])),
            "A provider without verification detection must ignore the challenge header"
        )
        expect(
            !claudeAdapter.isVerificationChallengeResponse(URLResponse(url: URL(string: "https://claude.ai")!, mimeType: "text/html", expectedContentLength: 0, textEncodingName: nil)),
            "A non-HTTP response is never a challenge"
        )

        for service in ChatService.allCases {
            let adapter = ProviderAdapter.adapter(for: service)
            let readiness = adapter.readinessScript()
            let fill = adapter.fillScript(prompt: "A quote: \\\" and a newline\\nnext line")
            let returnTarget = adapter.returnKeyTargetScript(prompt: "test")
            let confirmation = adapter.submissionConfirmationScript()
            let fileDropCompatibility = adapter.fileDropCompatibilityScript()
            expect(
                (adapter.verificationChallengeScript() != nil) == (service == .claude),
                "Only Claude should check for a verification interstitial"
            )
            expect(
                (adapter.blankPageScript() != nil) == (service == .claude),
                "Only Claude should retry a blank initial load"
            )
            expect(readiness.contains("document.querySelector"), "\(service.title) readiness script has no selector")
            expect(readiness.contains("getClientRects"), "\(service.title) readiness script accepts a hidden composer")
            expect(fill.contains("InputEvent"), "\(service.title) fill script does not notify the page")
            expect(fill.contains("composer-not-empty"), "\(service.title) fill script does not protect provider drafts")
            expect(!fill.contains(".click()"), "\(service.title) fill script must not submit early")
            expect(!returnTarget.contains(".click()"), "\(service.title) must send with Return, not by clicking Send")
            expect(returnTarget.contains("composer-missing-prompt"), "\(service.title) must check the composer before Return")
            expect(returnTarget.contains("document.activeElement"), "\(service.title) must focus the composer before Return")
            expect(
                adapter.composerHoldsPromptScript(prompt: "test").contains("composerSelectors"),
                "\(service.title) must check whether Return left the prompt in the composer"
            )
            expect(confirmation.contains("composerSelectors"), "\(service.title) confirmation must find the current composer")
            expect(confirmation.contains("getClientRects"), "\(service.title) confirmation must require a visible composer")
            if service == .claude {
                expect(
                    fileDropCompatibility?.contains("data-testid='file-upload'") == true,
                    "Claude file drops must use its provider-owned upload input"
                )
                expect(
                    fileDropCompatibility?.contains("location.protocol === 'https:'") == true
                        && fileDropCompatibility?.contains(PageOriginScript.isAllowedHost(service.providerPageHosts)) == true,
                    "Claude file-drop compatibility must be origin-gated"
                )
            } else {
                expect(fileDropCompatibility == nil, "ChatGPT must keep its native file-drop behavior")
            }
        }

        for service in ChatService.allCases {
            let shim = NotificationScript.source(
                initialPermission: .undetermined,
                allowedHosts: service.providerPageHosts
            )
            expect(shim.contains("messageHandlers?.duetNotifications"), "\(service.title) shim does not target the bridge handler")
            expect(shim.contains("\"default\""), "\(service.title) shim does not seed the initial permission")
            for host in service.providerPageHosts {
                expect(shim.contains(host), "\(service.title) shim does not restrict itself to \(host)")
            }
            expect(!service.providerPageHosts.isEmpty, "\(service.title) exposes no notification hosts")
        }
        expect(
            NotificationScript.source(initialPermission: .granted, allowedHosts: ["claude.ai"]).contains("\"granted\""),
            "Shim does not seed a granted permission"
        )
        expect(NotificationPermission.undetermined.rawValue == "default", "Undetermined permission must map to the DOM default state")
        expect(NotificationPermission.granted.rawValue == "granted", "Granted permission must keep its DOM value")
        expect(NotificationPermission.denied.rawValue == "denied", "Denied permission must keep its DOM value")

        expect(
            NotificationBridgeMessage(body: ["type": "permission"]) == .permission,
            "Permission query message was not parsed"
        )
        expect(
            NotificationBridgeMessage(body: ["type": "requestPermission"]) == .requestPermission,
            "Permission request message was not parsed"
        )
        expect(
            NotificationBridgeMessage(body: ["type": "show", "title": "Done", "body": "Reply ready", "tag": "t"])
                == .show(NotificationShowRequest(title: "Done", body: "Reply ready", tag: "t")),
            "Show message was not parsed"
        )
        expect(
            NotificationBridgeMessage(body: ["type": "show", "title": "Done"])
                == .show(NotificationShowRequest(title: "Done", body: "", tag: "")),
            "Show message must tolerate missing optional fields"
        )
        expect(
            NotificationBridgeMessage(body: ["type": "responseComplete"]) == .responseComplete,
            "Response completion message was not parsed"
        )
        expect(NotificationBridgeMessage(body: ["type": "show"]) == nil, "Show message without a title must be rejected")
        expect(NotificationBridgeMessage(body: ["type": "unknown"]) == nil, "Unknown message types must be rejected")
        expect(NotificationBridgeMessage(body: "show") == nil, "Non-dictionary messages must be rejected")
        expect(NotificationBridgeMessage(body: ["type": 3]) == nil, "Non-string message types must be rejected")

        for service in ChatService.allCases {
            let adapter = ProviderAdapter.adapter(for: service)
            expect(
                !adapter.generationIndicatorSelectors.isEmpty || !adapter.generationControlSelectors.isEmpty,
                "\(service.title) has no way to detect generation"
            )
            let watcher = NotificationScript.responseWatcherSource(
                adapter: adapter,
                allowedHosts: service.providerPageHosts
            )
            expect(watcher.contains("responseComplete"), "\(service.title) watcher does not report completions")
            expect(watcher.contains("messageHandlers?.duetNotifications"), "\(service.title) watcher does not target the bridge handler")
            for selector in adapter.generationIndicatorSelectors + adapter.generationControlSelectors {
                expect(watcher.contains(selector), "\(service.title) watcher does not check \(selector)")
            }
            for host in service.providerPageHosts {
                expect(watcher.contains(host), "\(service.title) watcher does not restrict itself to \(host)")
            }
        }
        expect(
            ProviderAdapter.adapter(for: .claude).generationIndicatorSelectors
                .contains("[data-is-streaming='true']"),
            "Claude watcher must use the streaming attribute"
        )

        expect(
            ResponseCompletionPolicy.shouldNotify(
                isEnabled: true, isAppActive: false, isWorkspaceVisible: true,
                secondsSinceSiteNotification: nil
            ),
            "A completion while Duet is inactive must notify"
        )
        expect(
            ResponseCompletionPolicy.shouldNotify(
                isEnabled: true, isAppActive: true, isWorkspaceVisible: false,
                secondsSinceSiteNotification: nil
            ),
            "A completion with the workspace hidden must notify"
        )
        expect(
            !ResponseCompletionPolicy.shouldNotify(
                isEnabled: true, isAppActive: true, isWorkspaceVisible: true,
                secondsSinceSiteNotification: nil
            ),
            "A completion the user is watching must not notify"
        )
        expect(
            !ResponseCompletionPolicy.shouldNotify(
                isEnabled: false, isAppActive: false, isWorkspaceVisible: false,
                secondsSinceSiteNotification: nil
            ),
            "A disabled preference must suppress completion notifications"
        )
        expect(
            !ResponseCompletionPolicy.shouldNotify(
                isEnabled: true, isAppActive: false, isWorkspaceVisible: false,
                secondsSinceSiteNotification: 5
            ),
            "A fresh site notification must suppress the duplicate completion"
        )
        expect(
            ResponseCompletionPolicy.shouldNotify(
                isEnabled: true, isAppActive: false, isWorkspaceVisible: false,
                secondsSinceSiteNotification: 30
            ),
            "An old site notification must not suppress a new completion"
        )

        // Generated scripts embed prompts and selectors as literals, so a
        // value must come back unchanged when JavaScript evaluates it.
        if let context = JSContext() {
            let awkwardValues = [
                "A quote: \" and a newline\nnext line",
                "Backslash \\ and </script> and ${template}",
                "Line separators \u{2028}\u{2029} and emoji 👋",
                "'single' `backtick`"
            ]
            for value in awkwardValues {
                let decoded = context.evaluateScript(JavaScriptLiteral.string(value))?.toString()
                expect(decoded == value, "JavaScriptLiteral.string did not round-trip \(value.debugDescription)")
            }
            let decodedArray = context.evaluateScript(JavaScriptLiteral.array(awkwardValues))?.toArray() as? [String]
            expect(decodedArray == awkwardValues, "JavaScriptLiteral.array did not round-trip its values")

            context.evaluateScript("var location = { hostname: '', pathname: '/' };")
            for (host, allowed) in [("claude.ai", true), ("www.Claude.AI", true), ("notclaude.ai", false), ("claude.ai.evil.example", false)] {
                context.evaluateScript("location.hostname = \(JavaScriptLiteral.string(host));")
                let result = context.evaluateScript(PageOriginScript.isAllowedHost(ChatService.claude.providerPageHosts))?.toBool()
                expect(result == allowed, "Page host check for \(host) returned \(String(describing: result))")
                expect(hostMatches(host, domain: "claude.ai") == allowed, "Native host check for \(host) disagrees with the page check")
            }
            for (path, isAuthentication) in [("/login", true), ("/Sign-In/next", true), ("/new", false), ("/", false)] {
                context.evaluateScript("location.pathname = \(JavaScriptLiteral.string(path));")
                let result = context.evaluateScript(PageOriginScript.isAuthenticationPath)?.toBool()
                expect(result == isAuthentication, "Page sign-in path check for \(path) returned \(String(describing: result))")
            }
        } else {
            failures.append("Couldn't create a JavaScript context")
        }

        if failures.isEmpty {
            print("All Duet tests passed.")
        } else {
            failures.forEach { fputs("FAIL: \($0)\n", stderr) }
            exit(1)
        }
    }
}
