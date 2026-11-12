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
        let layout = self == .lastUsed
            ? lastWorkspaceDestinationRawValue.flatMap(WorkspaceLayout.init(rawValue:))
            : WorkspaceLayout(rawValue: rawValue)
        return layout?.promptTarget
    }
}

/// The provider layouts the workspace can show. The raw values are saved as
/// `lastWorkspaceDestination` and match the `StartupDestination` cases of the
/// same name, so existing preferences keep working.
enum WorkspaceLayout: String, CaseIterable, Hashable {
    case chatGPT
    case claude
    case both

    init(service: ChatService) {
        switch service {
        case .chatGPT: self = .chatGPT
        case .claude: self = .claude
        }
    }

    var title: String {
        switch self {
        case .chatGPT: ChatService.chatGPT.title
        case .claude: ChatService.claude.title
        case .both: "Both"
        }
    }

    var promptTarget: PromptTarget {
        switch self {
        case .chatGPT: .service(.chatGPT)
        case .claude: .service(.claude)
        case .both: .both
        }
    }
}

/// `true` when `host` is `domain` or one of its subdomains, ignoring case.
/// A plain suffix match would also accept lookalikes such as `notclaude.ai`.
func hostMatches(_ host: String, domain: String) -> Bool {
    let host = host.lowercased()
    let domain = domain.lowercased()
    return host == domain || host.hasSuffix(".\(domain)")
}

/// Page-side versions of the origin checks above, for Duet's injected scripts.
enum PageOriginScript {
    /// A JavaScript expression that is `true` when the page's host is one of
    /// `allowedHosts` or a subdomain, matching `hostMatches(_:domain:)`.
    static func isAllowedHost(_ allowedHosts: [String]) -> String {
        """
        ((host => \(JavaScriptLiteral.array(allowedHosts.map { $0.lowercased() })).some(domain => host === domain || host.endsWith('.' + domain)))((location.hostname || '').toLowerCase()))
        """
    }

    /// A JavaScript expression that is `true` on a provider sign-in path,
    /// matching `ChatService.isAuthenticationPage`.
    static var isAuthenticationPath: String {
        """
        \(JavaScriptLiteral.array(ChatService.authenticationPathComponents)).includes((location.pathname.split('/').filter(Boolean)[0] || '').toLowerCase())
        """
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

    /// Every domain the provider owns: its app pages plus its company
    /// domain. Navigation stays inside these, and a website-data reset removes
    /// exactly their records.
    private var providerDomains: [String] {
        switch self {
        case .chatGPT: providerPageHosts + ["openai.com"]
        case .claude: providerPageHosts + ["anthropic.com"]
        }
    }

    /// First path components that mark a provider's own sign-in pages.
    static let authenticationPathComponents = ["auth", "login", "signin", "sign-in"]

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
        return (providerDomains + authenticationHosts).contains { hostMatches(host, domain: $0) }
    }

    func allowsPromptInjection(at url: URL?) -> Bool {
        guard url?.scheme?.lowercased() == "https", let host = url?.host?.lowercased() else { return false }
        return providerPageHosts.contains { hostMatches(host, domain: $0) }
    }

    func allowsNativePermission(at url: URL?) -> Bool {
        allowsPromptInjection(at: url) && !isAuthenticationPage(url)
    }

    /// Whether a script message or media request from this security origin
    /// comes from one of the provider's own HTTPS app pages.
    func isProviderPageOrigin(protocol originProtocol: String, host: String) -> Bool {
        guard originProtocol.lowercased() == "https" else { return false }
        return providerPageHosts.contains { hostMatches(host, domain: $0) }
    }

    /// Whether a native bridge should answer a script message: only the
    /// provider's own HTTPS main frame may talk to Duet.
    func acceptsBridgeMessage(isMainFrame: Bool, protocol originProtocol: String, host: String) -> Bool {
        isMainFrame && isProviderPageOrigin(protocol: originProtocol, host: host)
    }

    func isAuthenticationPage(_ url: URL?) -> Bool {
        guard url?.scheme?.lowercased() == "https", let host = url?.host?.lowercased() else { return false }
        if (providerAuthenticationHosts + authenticationHosts).contains(where: { hostMatches(host, domain: $0) }) {
            return true
        }
        guard providerPageHosts.contains(where: { hostMatches(host, domain: $0) }) else { return false }
        guard let firstPathComponent = url?.path.split(separator: "/").first?.lowercased() else { return false }
        return Self.authenticationPathComponents.contains(firstPathComponent)
    }

    /// Matches a `WKWebsiteDataRecord.displayName`, which WebKit reports as a
    /// registrable domain, against this provider's domains.
    func ownsWebsiteDataRecord(named displayName: String) -> Bool {
        providerDomains.contains { hostMatches(displayName, domain: $0) }
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

/// The status Duet shows while a send is under way.
enum DispatchProgress {
    /// Names each provider whose page is still loading its message box, which
    /// a cold Claude load can take about 20 seconds to do. Once none is,
    /// the send itself is under way.
    static func message(waitingFor services: Set<ChatService>) -> String {
        let waiting = ChatService.allCases.filter(services.contains).map(\.title)
        guard !waiting.isEmpty else { return "Sending…" }
        return "Waiting for \(waiting.joined(separator: " and ")) to load…"
    }
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
