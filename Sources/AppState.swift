import AppKit
import Combine
import Foundation

struct PromptDraftSnapshot {
    let text: String
    let revision: Int
}

private struct MountWaiter {
    let services: Set<ChatService>
    let continuation: CheckedContinuation<Bool, Never>
}

@MainActor
final class AppState: ObservableObject {
    @Published var selectedService: ChatService = .chatGPT
    @Published var isSplitView = false
    @Published var isPromptDrawerOpen = false {
        didSet { reservePromptFocus() }
    }
    @Published private(set) var isLaunchChooserVisible = true
    @Published var prompt = "" {
        didSet { promptRevision &+= 1 }
    }
    @Published private(set) var activeDispatchServices: Set<ChatService> = []
    /// Providers whose send is waiting for the page's message box to load.
    @Published private(set) var servicesWaitingForComposer: Set<ChatService> = []
    @Published private(set) var resettingServices: Set<ChatService> = []
    @Published private(set) var dispatchNotice: DispatchNotice?
    @Published private(set) var updateAvailable: UpdateInfo?
    @Published private(set) var promptFocusRequest = 0

    private let browsers: [ChatService: BrowserController]
    private var promptRevision = 0
    private var keepsProvidersLoaded = false
    private var mountedBrowserServices: Set<ChatService> = []
    private var mountWaiters: [UUID: MountWaiter] = [:]
    private var hasCompletedUpdateCheck = false
    private var isCheckingForUpdate = false
    private let userDefaults: UserDefaults?

    init(
        startupDestination: StartupDestination = .askEveryTime,
        userDefaults: UserDefaults? = nil
    ) {
        self.userDefaults = userDefaults
        browsers = Dictionary(uniqueKeysWithValues: ChatService.allCases.map { ($0, BrowserController(service: $0)) })

        let startupTarget = startupDestination.resolvedPromptTarget(
            lastWorkspaceDestinationRawValue: userDefaults?.string(forKey: AppPreferenceKey.lastWorkspaceDestination)
        )
        switch startupTarget {
        case .service(let service):
            selectedService = service
            isLaunchChooserVisible = false
            _ = browser(for: service).prepare()
        case .both:
            isSplitView = true
            isPromptDrawerOpen = true
            isLaunchChooserVisible = false
            ChatService.allCases.forEach { _ = browser(for: $0).prepare() }
        case .current, .none:
            _ = browser(for: selectedService).prepare()
        }
        recordCurrentWorkspaceDestination()
        reservePromptFocus()
        browsers.values.forEach { browser in
            browser.restorePromptFocus = { [weak self] in self?.promptFocusRequest &+= 1 }
            browser.webViewDidLeavePane = { [weak self] in self?.releaseInactiveBrowsersIfNeeded() }
        }
    }

    private func reservePromptFocus() {
        browsers.values.forEach { $0.reservesFocusForPrompt = isPromptDrawerOpen }
    }

    func browser(for service: ChatService) -> BrowserController {
        browsers[service]!
    }

    func select(_ service: ChatService) {
        guard !hasActiveOperations else { return }
        let previous = selectedService
        _ = browser(for: service).prepare()
        selectedService = service
        if previous != service {
            releaseInactiveBrowsersIfNeeded()
        }
        recordCurrentWorkspaceDestination()
    }

    /// Tracks which provider panes are mounted, so a send can wait for them.
    func browserDidMount(_ service: ChatService) {
        mountedBrowserServices.insert(service)
        for (id, waiter) in mountWaiters where waiter.services.isSubset(of: mountedBrowserServices) {
            finishMountWait(id, mounted: true)
        }
    }

    func setKeepsProvidersLoaded(_ enabled: Bool) {
        guard keepsProvidersLoaded != enabled else { return }
        keepsProvidersLoaded = enabled

        if enabled {
            ChatService.allCases.forEach { _ = browser(for: $0).prepare() }
        } else {
            releaseInactiveBrowsersIfNeeded()
        }
    }

    func setSplitView(_ enabled: Bool, opensPromptDrawer: Bool = true) {
        guard !hasActiveOperations else { return }
        let wasSplitView = isSplitView
        if enabled {
            if !wasSplitView {
                if opensPromptDrawer { isPromptDrawerOpen = true }
                mountedBrowserServices.removeAll()
            }
            ChatService.allCases.forEach { _ = browser(for: $0).prepare() }
            isSplitView = true
        } else {
            isSplitView = false
            mountedBrowserServices.removeAll()
            releaseInactiveBrowsersIfNeeded()
        }
        recordCurrentWorkspaceDestination()
    }

    /// Makes the workspace reflect an explicit prompt destination before dispatch begins.
    func openWorkspace(for target: PromptTarget, opensPromptDrawer: Bool = true) {
        // Layout changes are refused during a send or reset, so don't leave
        // the chooser for a layout that never appeared.
        guard !hasActiveOperations else { return }
        switch target {
        case .current:
            break
        case .service(let service):
            select(service)
            setSplitView(false)
        case .both:
            setSplitView(true, opensPromptDrawer: opensPromptDrawer)
        }
        isLaunchChooserVisible = false
        recordCurrentWorkspaceDestination()
    }

    /// The layout the workspace is showing.
    var workspaceLayout: WorkspaceLayout {
        isSplitView ? .both : WorkspaceLayout(service: selectedService)
    }

    private func recordCurrentWorkspaceDestination() {
        guard !isLaunchChooserVisible, let userDefaults else { return }
        userDefaults.set(workspaceLayout.rawValue, forKey: AppPreferenceKey.lastWorkspaceDestination)
    }

    /// Quick Prompt always starts new conversations. Recreate selected provider
    /// views first so an already-mounted conversation cannot interrupt the
    /// fresh-chat navigation while SwiftUI changes panes. The prompt came from
    /// the Quick Prompt panel, so the shared drawer stays out of the way: it is
    /// never opened here, and an open one collapses unless it holds a draft.
    @discardableResult
    func openQuickPromptWorkspace(for target: PromptTarget) -> Bool {
        guard !hasActiveOperations else { return false }
        let recreatedServices = services(for: target)
        mountedBrowserServices.subtract(recreatedServices)
        recreatedServices.forEach { service in
            browser(for: service).release()
        }
        if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            isPromptDrawerOpen = false
        }
        openWorkspace(for: target, opensPromptDrawer: false)
        return true
    }

    /// Waits until every destination pane has mounted its web view, so no
    /// send starts loading into a pane SwiftUI is still building. Mounts
    /// recorded before a layout change were cleared with it and don't count.
    func waitForWorkspaceMount(
        for target: PromptTarget,
        timeout: TimeInterval = 2.5
    ) async -> Bool {
        let expected = Set(services(for: target))
        if expected.isSubset(of: mountedBrowserServices) { return true }

        let id = UUID()
        let timeoutTask = Task { @MainActor [weak self] in
            guard (try? await Task.sleep(for: .seconds(timeout))) != nil else { return }
            self?.finishMountWait(id, mounted: false)
        }
        defer { timeoutTask.cancel() }
        return await withCheckedContinuation { continuation in
            mountWaiters[id] = MountWaiter(services: expected, continuation: continuation)
        }
    }

    private func finishMountWait(_ id: UUID, mounted: Bool) {
        mountWaiters.removeValue(forKey: id)?.continuation.resume(returning: mounted)
    }

    /// Sending the shared drawer to Both must happen from mounted split panes.
    /// Switching to split view also clears any stale single-pane mount state.
    func preparePromptDrawerWorkspace(
        for target: PromptTarget,
        timeout: TimeInterval = 2.5
    ) async -> Bool {
        guard case .both = target else { return true }
        if !isSplitView {
            openWorkspace(for: .both)
        }
        return await waitForWorkspaceMount(for: .both, timeout: timeout)
    }

    func capturePromptDraft() -> PromptDraftSnapshot {
        PromptDraftSnapshot(text: prompt, revision: promptRevision)
    }

    func clearPrompt(ifUnchanged draft: PromptDraftSnapshot) {
        guard promptRevision == draft.revision, prompt == draft.text else { return }
        prompt = ""
        isPromptDrawerOpen = false
    }

    func send(draft: PromptDraftSnapshot, to target: PromptTarget) async -> [PromptDispatchResult] {
        let results = await send(prompt: draft.text, to: target)
        if !results.isEmpty && results.allSatisfy(\.wasSent) {
            clearPrompt(ifUnchanged: draft)
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
                PromptDispatchResult(service: $0, outcome: .failed("Not sent, it's busy with another send or reset"))
            }
            dispatchNotice = DispatchNotice(results: results)
            return results
        }

        activeDispatchServices.formUnion(services)
        defer {
            activeDispatchServices.subtract(services)
            servicesWaitingForComposer.subtract(services)
            releaseInactiveBrowsersIfNeeded()
        }

        let outcomes: [PromptDispatchResult]
        if case .both = target {
            async let chatGPT = dispatch(text, to: .chatGPT, startingNewConversation: startingNewConversations)
            async let claude = dispatch(text, to: .claude, startingNewConversation: startingNewConversations)
            outcomes = [
                PromptDispatchResult(service: .chatGPT, outcome: await chatGPT),
                PromptDispatchResult(service: .claude, outcome: await claude)
            ]
        } else {
            let service = services[0]
            outcomes = [
                PromptDispatchResult(
                    service: service,
                    outcome: await dispatch(text, to: service, startingNewConversation: startingNewConversations)
                )
            ]
        }

        dispatchNotice = DispatchNotice(results: outcomes)
        return outcomes
    }

    private func dispatch(
        _ text: String,
        to service: ChatService,
        startingNewConversation: Bool
    ) async -> PromptDispatchOutcome {
        await browser(for: service).dispatch(
            prompt: text,
            startsNewConversation: startingNewConversation,
            waitingForComposerChanged: { [weak self] isWaiting in
                if isWaiting {
                    self?.servicesWaitingForComposer.insert(service)
                } else {
                    self?.servicesWaitingForComposer.remove(service)
                }
            }
        )
    }

    /// The status a prompt surface shows while a send is under way.
    var dispatchProgressMessage: String {
        DispatchProgress.message(waitingFor: servicesWaitingForComposer)
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

    func reportWorkspaceUnavailable(for target: PromptTarget) {
        dispatchNotice = DispatchNotice(results: services(for: target).map {
            PromptDispatchResult(service: $0, outcome: .unavailable)
        })
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

    /// Whether a provider page holds keyboard focus in its window.
    var providerPageHoldsKeyboardFocus: Bool {
        ChatService.allCases.contains { service in
            guard let webView = browser(for: service).webView,
                  let firstResponder = webView.window?.firstResponder as? NSView else { return false }
            return firstResponder === webView || firstResponder.isDescendant(of: webView)
        }
    }

    func isBusy(_ service: ChatService) -> Bool {
        activeDispatchServices.contains(service) || resettingServices.contains(service)
    }

    var hasActiveOperations: Bool {
        !activeDispatchServices.isEmpty || !resettingServices.isEmpty
    }

    var canStartNewConversation: Bool {
        !isLaunchChooserVisible && !hasActiveOperations
    }

    func startNewConversation() {
        guard canStartNewConversation else { return }
        services(for: isSplitView ? .both : .current).forEach { browser(for: $0).openNewConversation() }
    }

    func isShowingWorkspace(for target: PromptTarget) -> Bool {
        guard !isLaunchChooserVisible else { return false }
        switch target {
        case .current: return true
        case .service(let service): return !isSplitView && selectedService == service
        case .both: return isSplitView
        }
    }

    func consumeDispatchNotice(_ id: UUID) {
        guard dispatchNotice?.id == id else { return }
        dispatchNotice = nil
    }

    func checkForUpdateIfNeeded() async {
        guard !hasCompletedUpdateCheck, !isCheckingForUpdate else { return }
        isCheckingForUpdate = true
        defer { isCheckingForUpdate = false }

        do {
            updateAvailable = try await UpdateChecker.check()
            hasCompletedUpdateCheck = true
        } catch {
            // A later workspace remount can retry after a transient failure.
        }
    }

    func dismissAvailableUpdate() {
        guard let updateAvailable else { return }
        UpdateChecker.dismiss(updateAvailable.version)
        self.updateAvailable = nil
    }

    /// Releases each provider single-pane mode no longer shows. A provider
    /// still in a pane waits: SwiftUI keeps the outgoing pane on screen until
    /// its layout animation ends, and pulling the view out would blank it.
    /// When that pane lets go, the web view reports it and this runs again.
    private func releaseInactiveBrowsersIfNeeded() {
        guard !isSplitView, !keepsProvidersLoaded else { return }
        ChatService.allCases
            .filter { $0 != selectedService && !isBusy($0) }
            .map { browser(for: $0) }
            .filter { $0.webView?.superview == nil }
            .forEach { $0.release() }
    }
}

/// Moves keyboard focus into a native prompt field and checks that it got there.
@MainActor
enum PromptFocus {
    /// SwiftUI sometimes drops a focus request made as the drawer appears,
    /// and nothing asks again: the page that kept first responder never
    /// tries to take focus, so it never refuses an attempt and hands focus
    /// back. Ask, then check, and ask again a few times while the field
    /// still lacks focus. A click or Tab from the user moves focus on
    /// purpose, so stop asking once `userMovedFocus` reports one. Returns
    /// whether the field ended up focused.
    @discardableResult
    static func take(
        attempts: Int = 4,
        checkDelay: Duration = .milliseconds(50),
        setFocused: (Bool) -> Void,
        isFocused: () -> Bool,
        userMovedFocus: () -> Bool = { false }
    ) async -> Bool {
        for attempt in 0..<attempts {
            guard !Task.isCancelled else { return false }
            if attempt > 0 {
                guard !userMovedFocus() else { return false }
                // The focus state may still read true while a page holds
                // first responder, and setting it to true again does
                // nothing. Clear it, then set it on the next turn.
                setFocused(false)
                await Task.yield()
                guard !Task.isCancelled else { return false }
            }
            setFocused(true)
            try? await Task.sleep(for: checkDelay)
            guard !Task.isCancelled else { return false }
            if isFocused() { return true }
        }
        return false
    }
}

/// Notes a click or Tab press, the events by which the user moves keyboard
/// focus on purpose. Call `stop()` when done watching.
@MainActor
final class UserFocusEventMonitor {
    private(set) var sawUserFocusEvent = false
    private var monitor: Any?

    init() {
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]
        ) { [weak self] event in
            if event.type != .keyDown || event.keyCode == 48 {
                MainActor.assumeIsolated { self?.sawUserFocusEvent = true }
            }
            return event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
