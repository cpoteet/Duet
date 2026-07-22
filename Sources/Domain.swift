import Foundation

enum ChatService: String, CaseIterable, Identifiable, Hashable {
    case chatGPT
    case claude

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chatGPT: "ChatGPT"
        case .claude: "Claude"
        }
    }

    var startURL: URL {
        switch self {
        case .chatGPT: URL(string: "https://www.chatgpt.com")!
        case .claude: URL(string: "https://claude.ai")!
        }
    }

    /// The blank-conversation entry point used by the native quick prompt.
    var newConversationURL: URL {
        switch self {
        case .chatGPT: URL(string: "https://www.chatgpt.com/")!
        case .claude: URL(string: "https://claude.ai/new")!
        }
    }

    private var promptHosts: [String] {
        switch self {
        case .chatGPT: ["chatgpt.com"]
        case .claude: ["claude.ai"]
        }
    }

    private var providerNavigationHosts: [String] {
        switch self {
        case .chatGPT: promptHosts + ["openai.com"]
        case .claude: promptHosts + ["anthropic.com"]
        }
    }

    private var providerAuthenticationHosts: [String] {
        switch self {
        case .chatGPT: ["auth.openai.com"]
        case .claude: ["auth.anthropic.com"]
        }
    }

    private var authenticationHosts: [String] {
        [
            "accounts.google.com",
            "appleid.apple.com",
            "login.live.com",
            "login.microsoftonline.com"
        ]
    }

    /// Hosts whose pages may use the injected Notification API bridge.
    /// Authentication hosts are intentionally excluded.
    var webNotificationHosts: [String] { promptHosts }

    func allowsNavigation(to url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        if scheme == "about" { return true }
        guard scheme == "https", let host = url.host?.lowercased() else { return false }
        return (providerNavigationHosts + authenticationHosts).contains { hostMatches(host, domain: $0) }
    }

    func allowsPromptInjection(at url: URL?) -> Bool {
        guard url?.scheme?.lowercased() == "https", let host = url?.host?.lowercased() else { return false }
        return promptHosts.contains { hostMatches(host, domain: $0) }
    }

    func isAuthenticationPage(_ url: URL?) -> Bool {
        guard url?.scheme?.lowercased() == "https", let host = url?.host?.lowercased() else { return false }
        if (providerAuthenticationHosts + authenticationHosts).contains(where: { hostMatches(host, domain: $0) }) {
            return true
        }
        guard promptHosts.contains(where: { hostMatches(host, domain: $0) }) else { return false }
        guard let firstPathComponent = url?.path.split(separator: "/").first?.lowercased() else { return false }
        return ["auth", "login", "signin", "sign-in"].contains(firstPathComponent)
    }

    private func hostMatches(_ host: String, domain: String) -> Bool {
        host == domain || host.hasSuffix(".\(domain)")
    }

    /// Tokens used only to find the matching persistent WebKit records during reset.
    var websiteDataTokens: [String] {
        switch self {
        case .chatGPT: ["chatgpt.com", "openai.com"]
        case .claude: ["claude.ai", "anthropic.com"]
        }
    }
}

enum BrowserPhase: Equatable {
    case unloaded
    case loading
    case ready
    case verificationRequired
    case failed(String)
}

enum PromptDispatchOutcome: Equatable {
    case sent
    case loginRequired
    case unavailable
    case composerHasDraft
    case failed(String)

    var label: String {
        switch self {
        case .sent: "Sent"
        case .loginRequired: "Sign in required"
        case .unavailable: "Page not ready"
        case .composerHasDraft: "Composer already has a draft"
        case .failed(let message): message
        }
    }

    var offersBrowserFallback: Bool {
        switch self {
        case .sent, .composerHasDraft: false
        case .loginRequired, .unavailable, .failed: true
        }
    }

    var wasSent: Bool {
        if case .sent = self { return true }
        return false
    }

    var isVisibleInDispatchNotice: Bool {
        if case .loginRequired = self { return false }
        return true
    }
}

struct PromptDispatchResult: Equatable {
    let service: ChatService
    let outcome: PromptDispatchOutcome

    var wasSent: Bool { outcome.wasSent }
}

struct DispatchNotice: Identifiable, Equatable {
    let id = UUID()
    let results: [PromptDispatchResult]
}

enum PromptTarget {
    case current
    case service(ChatService)
    case both
}
