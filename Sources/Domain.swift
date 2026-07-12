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

    private var authenticationHosts: [String] {
        [
            "accounts.google.com",
            "appleid.apple.com",
            "login.live.com",
            "login.microsoftonline.com"
        ]
    }

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

enum PromptDispatchStatus: Equatable {
    case idle
    case sending
    case sent
    case loginRequired
    case unavailable
    case failed(String)

    var label: String {
        switch self {
        case .idle: "Ready"
        case .sending: "Sending…"
        case .sent: "Sent"
        case .loginRequired: "Sign in required"
        case .unavailable: "Page not ready"
        case .failed(let message): message
        }
    }
}

enum PromptDispatchOutcome: Equatable {
    case sent
    case loginRequired
    case unavailable
    case failed(String)

    var status: PromptDispatchStatus {
        switch self {
        case .sent: .sent
        case .loginRequired: .loginRequired
        case .unavailable: .unavailable
        case .failed(let message): .failed(message)
        }
    }

    var wasSent: Bool {
        if case .sent = self { return true }
        return false
    }
}

struct PromptDispatchResult: Equatable {
    let service: ChatService
    let outcome: PromptDispatchOutcome

    var wasSent: Bool { outcome.wasSent }
}

enum PromptTarget {
    case current
    case both
}
