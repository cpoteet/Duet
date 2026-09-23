import AppKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var appState: AppState
    @State private var isComposerOpen = false
    @State private var isPreparingPromptDispatch = false
    @AppStorage("splitViewRatio") private var splitViewRatio = 0.5
    @AppStorage(AppPreferenceKey.keepProvidersLoaded) private var keepProvidersLoaded = false
    @State private var splitViewResetID = 0
    @State private var toast: DispatchToast?
    @State private var toastDismissal: Task<Void, Never>?
    @Environment(\.colorScheme) private var colorScheme

    private let minimumPaneWidth: CGFloat = 280

    private var palette: AppPalette { AppPalette(scheme: colorScheme) }

    var body: some View {
        VStack(spacing: 0) {
            if let update = appState.updateAvailable {
                updateBanner(update)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            if appState.isLaunchChooserVisible {
                launchChooser
            } else {
                browserAreaWithToast
                if isComposerOpen {
                    promptDrawer
                }
            }
        }
        .frame(minWidth: 900, minHeight: 650)
        .background { WorkspaceWindowMarker() }
        .toolbar(removing: .title)
        .toolbarBackground(.thinMaterial, for: .windowToolbar)
        .toolbar {
            if !appState.isLaunchChooserVisible {
                ToolbarItem(placement: .principal) {
                    workspacePicker
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        isComposerOpen.toggle()
                    } label: {
                        Label("Prompt", systemImage: "paperplane")
                            .padding(.horizontal, 6)
                    }
                    .labelStyle(.titleAndIcon)
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                    .help(isComposerOpen ? "Close shared prompt" : "Open shared prompt")

                    layoutMenu
                }
            }
        }
        .animation(.easeOut(duration: 0.2), value: appState.isSplitView)
        .animation(.easeOut(duration: 0.2), value: appState.updateAvailable)
        .task {
            await appState.checkForUpdateIfNeeded()
        }
        .onAppear {
            isComposerOpen = false
            appState.setKeepsProvidersLoaded(keepProvidersLoaded)
            presentPendingDispatchNotice()
        }
        .onChange(of: keepProvidersLoaded) { _, isEnabled in
            appState.setKeepsProvidersLoaded(isEnabled)
        }
        .onChange(of: appState.dispatchNotice) { _, _ in
            presentPendingDispatchNotice()
        }
        .onDisappear {
            toastDismissal?.cancel()
        }
    }

    private func updateBanner(_ update: UpdateInfo) -> some View {
        HStack(spacing: 0) {
            Button {
                NSWorkspace.shared.open(update.releaseURL)
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "arrow.down.circle.fill")
                    Text("Duet \(update.version) is available")
                        .fontWeight(.medium)
                    Spacer(minLength: 12)
                    Text("View Release")
                    Image(systemName: "arrow.up.right")
                }
                .font(.system(size: 12))
                .foregroundStyle(palette.primaryText)
                .padding(.leading, 16)
                .padding(.trailing, 10)
                .frame(maxWidth: .infinity, minHeight: 34)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the Duet release page in your browser")

            Button {
                appState.dismissAvailableUpdate()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(palette.secondaryText)
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Dismiss this version")
            .accessibilityLabel("Dismiss Duet \(update.version) update")
        }
        .background(.thinMaterial)
        .overlay(alignment: .bottom) { hairline }
    }

    private var launchChooser: some View {
        VStack(spacing: 30) {
            Spacer(minLength: 56)

            Text("Choose a tool")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(palette.primaryText)

            HStack(spacing: 16) {
                launchChoice(.chatGPT)
                launchChoice(.claude)
                launchChoice(.both)
            }
            .frame(maxWidth: 680)

            Spacer(minLength: 56)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 28)
        .background(.thinMaterial)
    }

    private func launchChoice(_ destination: LaunchDestination) -> some View {
        Button {
            beginSession(with: destination)
        } label: {
            VStack(spacing: 15) {
                launchChoiceMark(for: destination)
                    .frame(height: 42)
                Text(destination.title)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 144)
        }
        .buttonStyle(LaunchChoiceButtonStyle(accent: launchChoiceColor(for: destination), palette: palette))
        .accessibilityLabel("Open \(destination.title)")
    }

    @ViewBuilder
    private func launchChoiceMark(for destination: LaunchDestination) -> some View {
        switch destination {
        case .chatGPT:
            ProviderMark(service: .chatGPT)
        case .claude:
            ProviderMark(service: .claude)
        case .both:
            HStack(spacing: 10) {
                ProviderMark(service: .chatGPT)
                ProviderMark(service: .claude)
            }
        }
    }

    private func launchChoiceColor(for destination: LaunchDestination) -> Color {
        switch destination {
        case .chatGPT: providerColor(for: .chatGPT)
        case .claude: providerColor(for: .claude)
        case .both: palette.accent
        }
    }

    private func beginSession(with destination: LaunchDestination) {
        isComposerOpen = false
        appState.openWorkspace(for: destination.promptTarget)
    }

    private var workspacePicker: some View {
        Picker("Workspace", selection: Binding(
            get: {
                appState.isSplitView ? LaunchDestination.both :
                    (appState.selectedService == .chatGPT ? .chatGPT : .claude)
            },
            set: { appState.openWorkspace(for: $0.promptTarget) }
        )) {
            Label {
                Text("ChatGPT")
                    .padding(.trailing, 7)
            } icon: {
                ProviderMark(service: .chatGPT, size: 16)
                    .accessibilityHidden(true)
                    .padding(.trailing, 9)
            }
            .tag(LaunchDestination.chatGPT)
            Label {
                Text("Claude")
            } icon: {
                ProviderMark(service: .claude, size: 16)
                    .accessibilityHidden(true)
                    .padding(.trailing, 9)
            }
            .tag(LaunchDestination.claude)
            Label {
                Text("Both")
            } icon: {
                HStack(spacing: 2) {
                    ProviderMark(service: .chatGPT, size: 14)
                    ProviderMark(service: .claude, size: 14)
                }
                .accessibilityHidden(true)
                .padding(.trailing, 9)
            }
            .tag(LaunchDestination.both)
            .accessibilityLabel("Both")
        }
        .labelsHidden()
        .labelStyle(.titleAndIcon)
        .pickerStyle(.menu)
        .disabled(appState.hasActiveOperations)
        .help("Choose which providers to show")
    }

    private var layoutMenu: some View {
        Menu {
            Button("Single Pane") { appState.setSplitView(false) }
                .disabled(!appState.isSplitView)
            Button("Split View") { appState.setSplitView(true) }
                .disabled(appState.isSplitView)
            Divider()
            Button("Equal Widths") {
                splitViewRatio = 0.5
                splitViewResetID += 1
            }
            .disabled(!appState.isSplitView)
        } label: {
            Label("Layout", systemImage: "rectangle.split.2x1")
        }
        .disabled(appState.hasActiveOperations)
        .help("Change the workspace layout")
    }

    @ViewBuilder
    private var browserArea: some View {
        if appState.isSplitView {
            GeometryReader { proxy in
                HSplitView {
                    servicePane(.chatGPT)
                        .frame(minWidth: minimumPaneWidth)
                        .background {
                            NativeSplitRatioRestorer(
                                ratio: splitViewRatio,
                                minimumPaneWidth: minimumPaneWidth
                            )
                        }
                        .onGeometryChange(for: CGFloat.self) { pane in
                            pane.size.width
                        } action: { _, width in
                            guard width > 0, proxy.size.width > 0 else { return }
                            splitViewRatio = Double(width / proxy.size.width)
                        }
                    servicePane(.claude)
                        .frame(minWidth: minimumPaneWidth)
                }
                .id(splitViewResetID)
            }
        } else if keepProvidersLoaded {
            ZStack {
                retainedSinglePane(.chatGPT)
                retainedSinglePane(.claude)
            }
        } else {
            servicePane(appState.selectedService)
        }
    }

    private func retainedSinglePane(_ service: ChatService) -> some View {
        let isSelected = appState.selectedService == service
        return servicePane(service)
            .opacity(isSelected ? 1 : 0)
            .allowsHitTesting(isSelected)
            .accessibilityHidden(!isSelected)
            .zIndex(isSelected ? 1 : 0)
    }

    private var browserAreaWithToast: some View {
        ZStack(alignment: .bottom) {
            browserArea
            if let toast {
                dispatchToast(toast)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: toast)
    }

    private func servicePane(_ service: ChatService) -> some View {
        ObservedServicePane(
            service: service,
            browser: appState.browser(for: service),
            acceptsKeyboardInput: appState.isSplitView || appState.selectedService == service
        ) {
            appState.browserDidMount(service)
        }
    }

    private var promptDrawer: some View {
        expandedComposer
        .background(.thinMaterial)
        .overlay(alignment: .top) { hairline }
    }

    private var expandedComposer: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Prompt")
                    .font(.headline)
                Spacer()
                Button {
                    isComposerOpen = false
                } label: {
                    Label("Close", systemImage: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(palette.secondaryText)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Close shared prompt")
            }

            TextEditor(text: $appState.prompt)
                .font(.system(size: 15))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 70, maxHeight: 118)
                .background(palette.textField, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(palette.fieldBorder, lineWidth: 1)
                }

            HStack {
                if isPreparingPromptDispatch || !appState.activeDispatchServices.isEmpty {
                    ProgressView()
                        .controlSize(.small)
                    Text("Sending…")
                        .font(.caption)
                        .foregroundStyle(palette.secondaryText)
                }
                Spacer()
                if !appState.isSplitView {
                    Button("Send to Both") {
                        sendFromDrawer(to: .both)
                    }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.return, modifiers: [.command, .option])
                    .disabled(!canSend(to: .both))

                    Button("Send to \(appState.selectedService.title)") {
                        sendFromDrawer(to: .current)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(!canSend(to: .current))
                } else {
                    Button("Send to Both") {
                        sendFromDrawer(to: .both)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(!canSend(to: .both))
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func sendFromDrawer(to target: PromptTarget) {
        guard canSend(to: target) else { return }
        let draft = appState.capturePromptDraft()
        isPreparingPromptDispatch = true
        Task {
            defer { isPreparingPromptDispatch = false }
            guard await appState.preparePromptDrawerWorkspace(for: target) else {
                appState.reportQuickPromptWorkspaceUnavailable(for: target)
                return
            }
            _ = await appState.send(draft: draft, to: target)
        }
    }

    private func canSend(to target: PromptTarget) -> Bool {
        hasPromptText && !isPreparingPromptDispatch && appState.canSend(to: target)
    }

    private var hasPromptText: Bool {
        !appState.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func dispatchToast(_ toast: DispatchToast) -> some View {
        HStack(spacing: 10) {
            Image(systemName: toast.style == .success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(toast.style == .success ? palette.success : palette.warning)

            Text(toast.message)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(palette.primaryText)
                .lineLimit(2)

            if let service = toast.actionService {
                Button("Open \(service.title)") {
                    appState.browser(for: service).openInDefaultBrowser()
                    dismissToast()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Button(action: dismissToast) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(palette.secondaryText)
                    .frame(width: 24, height: 24)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss notification")
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .padding(.vertical, 8)
        .background(palette.drawer, in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .stroke(palette.fieldBorder, lineWidth: 1)
        }
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.28 : 0.16), radius: 12, y: 5)
        .accessibilityElement(children: .contain)
    }

    private func presentToast(for results: [PromptDispatchResult]) {
        let visibleResults = results.filter { $0.outcome.isVisibleInDispatchNotice }
        guard !visibleResults.isEmpty else {
            dismissToast()
            return
        }
        let failedResults = visibleResults.filter { !$0.wasSent }
        let sentServices = visibleResults.filter(\.wasSent).map(\.service.title)
        let nextToast: DispatchToast

        if failedResults.isEmpty {
            let destination = sentServices.joined(separator: " and ")
            nextToast = DispatchToast(message: "Sent to \(destination)", style: .success)
        } else {
            let failed = failedResults[0]
            let successPrefix = sentServices.isEmpty ? "" : "Sent to \(sentServices.joined(separator: " and ")) · "
            let failures = failedResults
                .map { "\($0.service.title): \($0.outcome.label)" }
                .joined(separator: " · ")
            nextToast = DispatchToast(
                message: "\(successPrefix)\(failures)",
                style: .error,
                actionService: failed.outcome.offersBrowserFallback ? failed.service : nil
            )
        }

        toastDismissal?.cancel()
        withAnimation(.easeOut(duration: 0.2)) {
            toast = nextToast
        }

        guard nextToast.style == .success else { return }
        toastDismissal = Task { @MainActor [nextToast] in
            do {
                try await Task.sleep(nanoseconds: 3_000_000_000)
            } catch {
                return
            }
            guard toast?.id == nextToast.id else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                toast = nil
            }
        }
    }

    private func presentPendingDispatchNotice() {
        guard let notice = appState.dispatchNotice else { return }
        presentToast(for: notice.results)
        appState.consumeDispatchNotice(notice.id)
    }

    private func dismissToast() {
        toastDismissal?.cancel()
        withAnimation(.easeOut(duration: 0.2)) {
            toast = nil
        }
    }

    private func providerColor(for service: ChatService) -> Color {
        switch service {
        case .chatGPT: return Color(red: 0.25, green: 0.60, blue: 0.93)
        case .claude: return Color(red: 0.92, green: 0.49, blue: 0.23)
        }
    }

    private var hairline: some View {
        Rectangle()
            .fill(palette.border)
            .frame(height: 1)
    }

}

private struct ObservedServicePane: View {
    let service: ChatService
    @ObservedObject var browser: BrowserController
    let acceptsKeyboardInput: Bool
    let onMounted: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    private var palette: AppPalette { AppPalette(scheme: colorScheme) }

    var body: some View {
        ZStack {
            BrowserView(browser: browser, acceptsKeyboardInput: acceptsKeyboardInput, onMounted: onMounted)
                .id(service)
            if browser.phase == .verificationRequired {
                verificationNotice
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var verificationNotice: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.shield.fill")
                .font(.system(size: 28))
                .foregroundStyle(.orange)
            Text("\(service.title) needs browser verification")
                .font(.headline)
                .foregroundStyle(palette.primaryText)
            Text("The provider returned a verification page that this embedded WebKit view could not complete.")
                .multilineTextAlignment(.center)
                .foregroundStyle(palette.secondaryText)
                .frame(maxWidth: 330)
            HStack {
                Button("Retry here") { browser.reload() }
                Button("Open in browser") { browser.openInDefaultBrowser() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .background(palette.drawer, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(palette.border, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.18), radius: 14, y: 5)
        .padding(24)
    }
}

private struct DispatchToast: Identifiable, Equatable {
    enum Style: Equatable {
        case success
        case error
    }

    let id = UUID()
    let message: String
    let style: Style
    let actionService: ChatService?

    init(message: String, style: Style, actionService: ChatService? = nil) {
        self.message = message
        self.style = style
        self.actionService = actionService
    }
}

private struct NativeSplitRatioRestorer: NSViewRepresentable {
    let ratio: Double
    let minimumPaneWidth: CGFloat

    func makeNSView(context: Context) -> SplitRatioMarkerView {
        SplitRatioMarkerView(ratio: ratio, minimumPaneWidth: minimumPaneWidth)
    }

    func updateNSView(_ nsView: SplitRatioMarkerView, context: Context) { }
}

final class SplitRatioMarkerView: NSView {
    private let ratio: Double
    private let minimumPaneWidth: CGFloat
    private var hasRestored = false
    private var attempts = 0

    init(ratio: Double, minimumPaneWidth: CGFloat) {
        self.ratio = ratio
        self.minimumPaneWidth = minimumPaneWidth
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in self?.restorePosition() }
    }

    private func restorePosition() {
        guard !hasRestored, window != nil else { return }

        var ancestor = superview
        while let view = ancestor {
            if let splitView = view as? NSSplitView {
                let availableWidth = splitView.bounds.width - splitView.dividerThickness
                if availableWidth >= 2 * minimumPaneWidth {
                    let position = min(
                        max(splitView.bounds.width * ratio, minimumPaneWidth),
                        availableWidth - minimumPaneWidth
                    )
                    splitView.setPosition(position, ofDividerAt: 0)
                    hasRestored = true
                    return
                }
            }
            ancestor = view.superview
        }

        guard attempts < 20 else { return }
        attempts += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50)) { [weak self] in
            self?.restorePosition()
        }
    }
}

private struct AppPalette {
    let scheme: ColorScheme

    private var isDark: Bool { scheme == .dark }
    var drawer: Color { isDark ? Color(red: 0.08, green: 0.085, blue: 0.10) : Color(red: 0.965, green: 0.963, blue: 0.95) }
    var textField: Color { isDark ? Color(red: 0.105, green: 0.11, blue: 0.13) : .white }
    var primaryText: Color { isDark ? Color(red: 0.91, green: 0.92, blue: 0.94) : Color(red: 0.10, green: 0.11, blue: 0.13) }
    var secondaryText: Color { isDark ? Color(red: 0.62, green: 0.64, blue: 0.68) : Color(red: 0.36, green: 0.38, blue: 0.42) }
    var border: Color { isDark ? Color.white.opacity(0.10) : Color.black.opacity(0.12) }
    var fieldBorder: Color { isDark ? Color.white.opacity(0.16) : Color.black.opacity(0.16) }
    var success: Color { Color(red: 0.20, green: 0.64, blue: 0.42) }
    var warning: Color { Color(red: 0.92, green: 0.49, blue: 0.23) }
    var accent: Color { Color(red: 0.34, green: 0.40, blue: 0.82) }
}

private enum LaunchDestination: Hashable {
    case chatGPT
    case claude
    case both

    var title: String {
        switch self {
        case .chatGPT: "ChatGPT"
        case .claude: "Claude"
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

private struct ProviderMark: View {
    let service: ChatService
    var size: CGFloat = 38

    private var image: NSImage? {
        let resourceName = service == .chatGPT ? "ChatGPT" : "Claude"
        guard let url = Bundle.main.url(forResource: resourceName, withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .renderingMode(service == .chatGPT ? .template : .original)
                    .foregroundStyle(Color.primary)
                    .scaledToFit()
            } else {
                Image(systemName: service == .chatGPT ? "circle.hexagongrid.fill" : "sparkles")
                    .font(.system(size: size * 0.92, weight: .medium))
                    .foregroundStyle(service == .chatGPT ? Color(red: 0.25, green: 0.60, blue: 0.93) : Color(red: 0.92, green: 0.49, blue: 0.23))
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(service.title)
    }
}

private struct LaunchChoiceButtonStyle: ButtonStyle {
    let accent: Color
    let palette: AppPalette

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(palette.primaryText)
            .background(
                palette.textField,
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(accent.opacity(configuration.isPressed ? 0.85 : 0.52), lineWidth: configuration.isPressed ? 2 : 1)
            }
            .shadow(
                color: .black.opacity(configuration.isPressed ? 0.04 : (palette.scheme == .dark ? 0.16 : 0.08)),
                radius: configuration.isPressed ? 2 : 8,
                y: configuration.isPressed ? 1 : 3
            )
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
    }
}
