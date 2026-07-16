import Combine
import Foundation

@MainActor
final class AppState: ObservableObject {
    @Published var selectedService: ChatService = .chatGPT
    @Published var isSplitView = false
    @Published private(set) var isLaunchChooserVisible = true
    @Published var prompt = ""
    @Published private(set) var activeDispatchServices: Set<ChatService> = []
    @Published private(set) var resettingServices: Set<ChatService> = []
    @Published private(set) var dispatchNotice: DispatchNotice?

    private let browsers: [ChatService: BrowserController]
    private var keepsProvidersLoaded = false
    private var pendingSinglePaneRelease: ChatService?
    private var mountedSplitServices: Set<ChatService> = []

    init() {
        browsers = Dictionary(uniqueKeysWithValues: ChatService.allCases.map { ($0, BrowserController(service: $0)) })
        _ = browser(for: selectedService).prepare()
    }

    func browser(for service: ChatService) -> BrowserController {
        browsers[service]!
    }

    func select(_ service: ChatService) {
        guard !hasActiveOperations else { return }
        let previous = selectedService
        _ = browser(for: service).prepare()
        selectedService = service
        if !isSplitView, !keepsProvidersLoaded, previous != service {
            pendingSinglePaneRelease = previous
        }
    }

    /// Tracks split-pane mounting and releases the previous single-pane browser
    /// only after its replacement belongs to the visible window.
    func browserDidMount(_ service: ChatService) {
        if isSplitView {
            mountedSplitServices.insert(service)
            return
        }

        guard !keepsProvidersLoaded,
              selectedService == service,
              let previous = pendingSinglePaneRelease else { return }
        pendingSinglePaneRelease = nil
        guard previous != selectedService else { return }
        releaseInactiveBrowsersIfNeeded()
    }

    func setKeepsProvidersLoaded(_ enabled: Bool) {
        guard keepsProvidersLoaded != enabled else { return }
        keepsProvidersLoaded = enabled
        pendingSinglePaneRelease = nil

        if enabled {
            ChatService.allCases.forEach { _ = browser(for: $0).prepare() }
        } else if !isSplitView {
            releaseInactiveBrowsersIfNeeded()
        }
    }

    func setSplitView(_ enabled: Bool) {
        guard !hasActiveOperations else { return }
        let wasSplitView = isSplitView
        isSplitView = enabled
        if enabled {
            pendingSinglePaneRelease = nil
            if !wasSplitView {
                mountedSplitServices.removeAll()
            }
            ChatService.allCases.forEach { _ = browser(for: $0).prepare() }
        } else {
            mountedSplitServices.removeAll()
            releaseInactiveBrowsersIfNeeded()
        }
    }

    /// Makes the workspace reflect an explicit prompt destination before dispatch begins.
    func openWorkspace(for target: PromptTarget) {
        switch target {
        case .current:
            break
        case .service(let service):
            select(service)
            setSplitView(false)
        case .both:
            setSplitView(true)
        }
        isLaunchChooserVisible = false
    }

    /// Quick Prompt always starts new conversations. Recreate selected provider
    /// views first so an already-mounted conversation cannot interrupt the
    /// fresh-chat navigation while SwiftUI changes panes.
    @discardableResult
    func openQuickPromptWorkspace(for target: PromptTarget) -> Bool {
        guard !hasActiveOperations else { return false }
        let recreatedServices = services(for: target)
        mountedSplitServices.subtract(recreatedServices)
        recreatedServices.forEach { service in
            browser(for: service).release()
        }
        openWorkspace(for: target)
        return true
    }

    /// Lets a quick-prompt split transition finish moving both WebKit views
    /// into their replacement hosts before either view begins a fresh-chat load.
    func waitForSplitWorkspaceMount(timeout: TimeInterval = 1.5) async -> Bool {
        guard isSplitView else { return true }

        let expected = Set(ChatService.allCases)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if expected.isSubset(of: mountedSplitServices) { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return expected.isSubset(of: mountedSplitServices)
    }

    @discardableResult
    func send(to target: PromptTarget) async -> [PromptDispatchResult] {
        let results = await send(prompt: prompt, to: target)
        if !results.isEmpty && results.allSatisfy(\.wasSent) {
            prompt = ""
        }
        return results
    }

    /// Dispatches text owned by another native surface, such as the quick-prompt panel.
    /// The caller keeps its text until every selected provider confirms submission.
    @discardableResult
    func send(
        prompt: String,
        to target: PromptTarget,
        startingNewConversations: Bool = false
    ) async -> [PromptDispatchResult] {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }

        let services = services(for: target)
        guard Set(services).isDisjoint(with: activeDispatchServices),
              Set(services).isDisjoint(with: resettingServices) else {
            let results = services.map {
                PromptDispatchResult(service: $0, outcome: .failed("A provider operation is already in progress"))
            }
            dispatchNotice = DispatchNotice(results: results)
            return results
        }

        activeDispatchServices.formUnion(services)
        defer {
            activeDispatchServices.subtract(services)
            releaseInactiveBrowsersIfNeeded()
        }

        let outcomes: [PromptDispatchResult]
        if case .both = target {
            async let chatGPT = browser(for: .chatGPT).dispatch(
                prompt: text,
                startsNewConversation: startingNewConversations
            )
            async let claude = browser(for: .claude).dispatch(
                prompt: text,
                startsNewConversation: startingNewConversations
            )
            outcomes = [
                PromptDispatchResult(service: .chatGPT, outcome: await chatGPT),
                PromptDispatchResult(service: .claude, outcome: await claude)
            ]
        } else {
            let service = services[0]
            outcomes = [
                PromptDispatchResult(
                    service: service,
                    outcome: await browser(for: service).dispatch(
                        prompt: text,
                        startsNewConversation: startingNewConversations
                    )
                )
            ]
        }

        dispatchNotice = DispatchNotice(results: outcomes)
        return outcomes
    }

    func clearWebsiteData(for service: ChatService) async {
        guard !activeDispatchServices.contains(service), !resettingServices.contains(service) else { return }
        resettingServices.insert(service)
        defer {
            resettingServices.remove(service)
            releaseInactiveBrowsersIfNeeded()
        }
        await browser(for: service).clearWebsiteData()
    }

    func canSend(to target: PromptTarget) -> Bool {
        let services = services(for: target)
        return Set(services).isDisjoint(with: activeDispatchServices)
            && Set(services).isDisjoint(with: resettingServices)
    }

    private func services(for target: PromptTarget) -> [ChatService] {
        switch target {
        case .current:
            [selectedService]
        case .service(let service):
            [service]
        case .both:
            ChatService.allCases
        }
    }

    func isBusy(_ service: ChatService) -> Bool {
        activeDispatchServices.contains(service) || resettingServices.contains(service)
    }

    var hasActiveOperations: Bool {
        !activeDispatchServices.isEmpty || !resettingServices.isEmpty
    }

    func consumeDispatchNotice(_ id: UUID) {
        guard dispatchNotice?.id == id else { return }
        dispatchNotice = nil
    }

    private func releaseInactiveBrowsersIfNeeded() {
        guard !isSplitView, !keepsProvidersLoaded else { return }
        ChatService.allCases
            .filter { $0 != selectedService && !isBusy($0) }
            .forEach { browser(for: $0).release() }
    }
}
