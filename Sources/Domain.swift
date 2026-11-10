import Foundation

enum AppPreferenceKey {
    static let keepProvidersLoaded = "keepProvidersLoaded"
    static let responseCompletionNotifications = "responseCompletionNotifications"
    static let startupDestination = "startupDestination"
    static let lastWorkspaceDestination = "lastWorkspaceDestination"
}

enum StartupDestination: String, CaseIterable, Identifiable {
    case askEveryTime
    case chatGPT
    case claude
    case both
    case lastUsed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .askEveryTime: "Ask Every Time"
        case .chatGPT: "ChatGPT"
        case .claude: "Claude"
        case .both: "Both"
        case .lastUsed: "Last Used"
        }
    }

    static func stored(in userDefaults: UserDefaults) -> StartupDestination {
        guard let rawValue = userDefaults.string(forKey: AppPreferenceKey.startupDestination) else {
            return .askEveryTime
        }
        return StartupDestination(rawValue: rawValue) ?? .askEveryTime
    }

    func resolvedPromptTarget(lastWorkspaceDestinationRawValue: String?) -> PromptTarget? {
        switch self {
        case .askEveryTime:
            nil
        case .chatGPT:
            .service(.chatGPT)
        case .claude:
            .service(.claude)
        case .both:
            .both
        case .lastUsed:
            switch lastWorkspaceDestinationRawValue.flatMap(StartupDestination.init(rawValue:)) {
            case .chatGPT: .service(.chatGPT)
            case .claude: .service(.claude)
            case .both: .both
            case .askEveryTime, .lastUsed, .none: nil
            }
        }
    }
}

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

    /// The provider's own app pages: the only hosts that receive prompt
    /// injection and the notification, location, and printing bridges.
    /// Authentication hosts are intentionally excluded.
    var providerPageHosts: [String] {
        switch self {
        case .chatGPT: ["chatgpt.com"]
        case .claude: ["claude.ai"]
        }
    }

    private var providerNavigationHosts: [String] {
        switch self {
        case .chatGPT: providerPageHosts + ["openai.com"]
        case .claude: providerPageHosts + ["anthropic.com"]
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

    func allowsNavigation(to url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        if scheme == "about" { return true }
        guard scheme == "https", let host = url.host?.lowercased() else { return false }
        return (providerNavigationHosts + authenticationHosts).contains { hostMatches(host, domain: $0) }
    }

    func allowsPromptInjection(at url: URL?) -> Bool {
        guard url?.scheme?.lowercased() == "https", let host = url?.host?.lowercased() else { return false }
        return providerPageHosts.contains { hostMatches(host, domain: $0) }
    }

    func allowsNativePermission(at url: URL?) -> Bool {
        allowsPromptInjection(at: url) && !isAuthenticationPage(url)
    }

    func allowsMediaCapture(originProtocol: String, host: String) -> Bool {
        guard originProtocol.lowercased() == "https" else { return false }
        let normalizedHost = host.lowercased()
        return providerPageHosts.contains { hostMatches(normalizedHost, domain: $0) }
    }

    func isAuthenticationPage(_ url: URL?) -> Bool {
        guard url?.scheme?.lowercased() == "https", let host = url?.host?.lowercased() else { return false }
        if (providerAuthenticationHosts + authenticationHosts).contains(where: { hostMatches(host, domain: $0) }) {
            return true
        }
        guard providerPageHosts.contains(where: { hostMatches(host, domain: $0) }) else { return false }
        guard let firstPathComponent = url?.path.split(separator: "/").first?.lowercased() else { return false }
        return ["auth", "login", "signin", "sign-in"].contains(firstPathComponent)
    }

    private func hostMatches(_ host: String, domain: String) -> Bool {
        host == domain || host.hasSuffix(".\(domain)")
    }

    /// Domains whose persistent WebKit records belong to this provider.
    var websiteDataDomains: [String] {
        switch self {
        case .chatGPT: ["chatgpt.com", "openai.com"]
        case .claude: ["claude.ai", "anthropic.com"]
        }
    }

    /// Matches a `WKWebsiteDataRecord.displayName`, which WebKit reports as a
    /// registrable domain, against this provider's domains. A plain substring
    /// match would also claim unrelated sites such as `notclaude.ai`.
    func ownsWebsiteDataRecord(named displayName: String) -> Bool {
        let name = displayName.lowercased()
        return websiteDataDomains.contains { hostMatches(name, domain: $0) }
    }
}

enum BrowserPhase: Equatable {
    case unloaded
    case loading
    case ready
    case verificationRequired
    case failed(String)

    var failureMessage: String? {
        if case .failed(let message) = self { return message }
        return nil
    }

    var promptReadinessTimeout: TimeInterval {
        self == .ready ? 12 : 60
    }
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
        case .loginRequired: "Not sent, sign in first"
        case .unavailable: "Not sent, its message box didn't load"
        case .composerHasDraft: "Not sent, its message box already has text"
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

enum PromptTarget: Equatable {
    case current
    case service(ChatService)
    case both
}
