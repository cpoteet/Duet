import Combine
import Foundation

@MainActor
final class AppState: ObservableObject {
    @Published var selectedService: ChatService = .chatGPT
    @Published var isSplitView = false
    @Published var prompt = ""
    @Published private(set) var statuses: [ChatService: PromptDispatchStatus] = Dictionary(
        uniqueKeysWithValues: ChatService.allCases.map { ($0, .idle) }
    )
    @Published private(set) var activeDispatchServices: Set<ChatService> = []
    @Published private(set) var resettingServices: Set<ChatService> = []

    private let browsers: [ChatService: BrowserController]
    private var pendingSinglePaneRelease: ChatService?

    init() {
        browsers = Dictionary(uniqueKeysWithValues: ChatService.allCases.map { ($0, BrowserController(service: $0)) })
        _ = browser(for: selectedService).prepare()
    }

    func browser(for service: ChatService) -> BrowserController {
        browsers[service]!
    }

    func select(_ service: ChatService) {
        let previous = selectedService
        _ = browser(for: service).prepare()
        selectedService = service
        if !isSplitView && previous != service {
            pendingSinglePaneRelease = previous
        }
    }

    /// Called by the native host after the selected provider has been added to a
    /// window. Keeping the old pane alive until this point avoids a blank first
    /// visit when switching providers.
    func browserDidMount(_ service: ChatService) {
        guard !isSplitView, selectedService == service, let previous = pendingSinglePaneRelease else { return }
        pendingSinglePaneRelease = nil
        browser(for: previous).release()
    }

    func setSplitView(_ enabled: Bool) {
        isSplitView = enabled
        if enabled {
            pendingSinglePaneRelease = nil
            ChatService.allCases.forEach { _ = browser(for: $0).prepare() }
        } else {
            pendingSinglePaneRelease = nil
            let inactive = ChatService.allCases.filter { $0 != selectedService }
            inactive.forEach { browser(for: $0).release() }
        }
    }

    @discardableResult
    func send(to target: PromptTarget) async -> [PromptDispatchResult] {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }

        let services = target == .current ? [selectedService] : ChatService.allCases
        guard Set(services).isDisjoint(with: activeDispatchServices),
              Set(services).isDisjoint(with: resettingServices) else {
            return services.map {
                PromptDispatchResult(service: $0, outcome: .failed("A provider operation is already in progress"))
            }
        }

        activeDispatchServices.formUnion(services)
        defer { activeDispatchServices.subtract(services) }
        services.forEach { statuses[$0] = .sending }

        let outcomes: [PromptDispatchResult]
        if target == .both {
            async let chatGPT = browser(for: .chatGPT).dispatch(prompt: text)
            async let claude = browser(for: .claude).dispatch(prompt: text)
            outcomes = [
                PromptDispatchResult(service: .chatGPT, outcome: await chatGPT),
                PromptDispatchResult(service: .claude, outcome: await claude)
            ]
        } else {
            let service = services[0]
            outcomes = [PromptDispatchResult(service: service, outcome: await browser(for: service).dispatch(prompt: text))]
        }

        outcomes.forEach { statuses[$0.service] = $0.outcome.status }
        let allSent = outcomes.allSatisfy(\.wasSent)
        if allSent {
            prompt = ""
        }
        return outcomes
    }

    func clearWebsiteData(for service: ChatService) async {
        guard !activeDispatchServices.contains(service), !resettingServices.contains(service) else { return }
        resettingServices.insert(service)
        defer { resettingServices.remove(service) }
        statuses[service] = .sending
        await browser(for: service).clearWebsiteData()
        statuses[service] = .idle
    }

    func canSend(to target: PromptTarget) -> Bool {
        let services = target == .current ? [selectedService] : ChatService.allCases
        return Set(services).isDisjoint(with: activeDispatchServices)
            && Set(services).isDisjoint(with: resettingServices)
    }

    func isBusy(_ service: ChatService) -> Bool {
        activeDispatchServices.contains(service) || resettingServices.contains(service)
    }

    var hasActiveOperations: Bool {
        !activeDispatchServices.isEmpty || !resettingServices.isEmpty
    }
}
