import AppKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var appState: AppState
    @State private var isComposerOpen = false
    @AppStorage("splitViewRatio") private var splitViewRatio = 0.5
    @State private var isSplitDividerHovering = false
    @State private var splitRatioAtDragStart: CGFloat?
    @State private var toast: DispatchToast?
    @State private var toastDismissal: Task<Void, Never>?
    @Environment(\.colorScheme) private var colorScheme

    private let splitDividerWidth: CGFloat = 9
    private let minimumPaneWidth: CGFloat = 280

    private var palette: AppPalette { AppPalette(scheme: colorScheme) }

    var body: some View {
        VStack(spacing: 0) {
            if appState.isLaunchChooserVisible {
                launchChooser
                launchPromptDrawer
            } else {
                controlBar
                browserAreaWithToast
                promptDrawer
            }
        }
        .frame(minWidth: 900, minHeight: 650)
        .background(palette.canvas)
        .animation(.easeOut(duration: 0.2), value: appState.isSplitView)
        .onAppear {
            isComposerOpen = false
        }
        .onDisappear {
            toastDismissal?.cancel()
        }
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

    private var launchPromptDrawer: some View {
        Color.clear
        .frame(maxWidth: .infinity)
        .frame(height: 43)
        .background(palette.drawer)
        .overlay(alignment: .top) { hairline }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var controlBar: some View {
        if appState.isSplitView {
            HStack(spacing: 12) {
                Spacer()
                splitToggle
                resetSplitViewButton
            }
            .padding(.horizontal, 20)
            .frame(height: 54)
            .background(palette.controlBar)
            .overlay(alignment: .bottom) { hairline }
        } else {
            HStack(spacing: 16) {
                providerPicker
                Spacer(minLength: 20)
                splitToggle
                divider
                serviceStatus(appState.selectedService)
            }
            .padding(.horizontal, 16)
            .frame(height: 54)
            .background(palette.controlBar)
            .overlay(alignment: .bottom) { hairline }
        }
    }

    private var providerPicker: some View {
        HStack(spacing: 1) {
            ForEach(ChatService.allCases) { service in
                Button {
                    appState.select(service)
                } label: {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(providerColor(for: service))
                            .frame(width: 7, height: 7)
                        Text(service.title)
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(appState.selectedService == service ? palette.primaryText : palette.secondaryText)
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                    .background {
                        if appState.selectedService == service {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(palette.selectedControl)
                                .shadow(color: .black.opacity(colorScheme == .dark ? 0 : 0.07), radius: 4, y: 1)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Show \(service.title)")
                .accessibilityAddTraits(appState.selectedService == service ? .isSelected : [])
            }
        }
        .padding(2)
        .background(palette.controlWell, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .disabled(appState.hasActiveOperations)
    }

    private var splitToggle: some View {
        Toggle("Split", isOn: Binding(
            get: { appState.isSplitView },
            set: { appState.setSplitView($0) }
        ))
        .toggleStyle(.switch)
        .font(.system(size: 14, weight: .medium))
        .foregroundStyle(palette.secondaryText)
        .tint(palette.accent)
        .disabled(appState.hasActiveOperations)
        .accessibilityHint("Shows ChatGPT and Claude side by side")
    }

    private var resetSplitViewButton: some View {
        Button {
            splitViewRatio = 0.5
        } label: {
            Label("Reset View", systemImage: "arrow.counterclockwise")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help("Reset split panes to equal widths")
        .accessibilityHint("Restores ChatGPT and Claude to equal widths")
    }

    @ViewBuilder
    private var browserArea: some View {
        if appState.isSplitView {
            GeometryReader { proxy in
                let paneWidth = splitPaneWidth(in: proxy.size.width)

                HStack(spacing: 0) {
                    servicePane(.chatGPT)
                        .frame(width: paneWidth)
                    splitViewDivider(totalWidth: proxy.size.width)
                    servicePane(.claude)
                        .frame(maxWidth: .infinity)
                }
            }
        } else {
            servicePane(appState.selectedService)
        }
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

    private func splitPaneWidth(in totalWidth: CGFloat) -> CGFloat {
        let availableWidth = max(0, totalWidth - splitDividerWidth)
        return availableWidth * clampedSplitRatio(for: totalWidth)
    }

    private func clampedSplitRatio(for totalWidth: CGFloat) -> CGFloat {
        let availableWidth = max(1, totalWidth - splitDividerWidth)
        let minimumRatio = min(0.5, minimumPaneWidth / availableWidth)
        let maximumRatio = max(0.5, 1 - minimumRatio)
        return min(max(CGFloat(splitViewRatio), minimumRatio), maximumRatio)
    }

    private func setSplitRatio(_ ratio: CGFloat, in totalWidth: CGFloat) {
        let availableWidth = max(1, totalWidth - splitDividerWidth)
        let minimumRatio = min(0.5, minimumPaneWidth / availableWidth)
        let maximumRatio = max(0.5, 1 - minimumRatio)
        splitViewRatio = Double(min(max(ratio, minimumRatio), maximumRatio))
    }

    private func splitViewDivider(totalWidth: CGFloat) -> some View {
        Rectangle()
            .fill(palette.border)
            .frame(width: 1)
            .frame(width: splitDividerWidth)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .overlay {
                if isSplitDividerHovering || splitRatioAtDragStart != nil {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(palette.controlWell)
                        .frame(width: 5, height: 54)
                        .overlay {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .stroke(palette.accent.opacity(0.8), lineWidth: 1)
                        }
                        .overlay {
                            VStack(spacing: 3) {
                                ForEach(0..<3, id: \.self) { _ in
                                    Circle()
                                        .fill(palette.accent)
                                        .frame(width: 2, height: 2)
                                }
                            }
                        }
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.15), value: isSplitDividerHovering)
            .onHover { isHovering in
                isSplitDividerHovering = isHovering
                if isHovering {
                    NSCursor.resizeLeftRight.set()
                } else {
                    NSCursor.arrow.set()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if splitRatioAtDragStart == nil {
                            splitRatioAtDragStart = clampedSplitRatio(for: totalWidth)
                        }
                        let availableWidth = max(1, totalWidth - splitDividerWidth)
                        setSplitRatio((splitRatioAtDragStart ?? 0.5) + value.translation.width / availableWidth, in: totalWidth)
                    }
                    .onEnded { _ in
                        splitRatioAtDragStart = nil
                    }
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Split view divider")
            .accessibilityValue("\(Int(clampedSplitRatio(for: totalWidth) * 100)) percent ChatGPT")
            .accessibilityHint("Drag left or right to resize the ChatGPT and Claude panes")
            .accessibilityAdjustableAction { direction in
                let adjustment: CGFloat = direction == .increment ? 0.05 : -0.05
                setSplitRatio(clampedSplitRatio(for: totalWidth) + adjustment, in: totalWidth)
            }
    }

    private func servicePane(_ service: ChatService) -> some View {
        VStack(spacing: 0) {
            if appState.isSplitView {
                HStack(spacing: 8) {
                    Circle()
                        .fill(providerColor(for: service))
                        .frame(width: 9, height: 9)
                    Text(service.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(palette.primaryText)
                    if appState.statuses[service] == .sending {
                        Text("·")
                            .foregroundStyle(palette.tertiaryText)
                        Text("Sending…")
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(palette.secondaryText)
                    }
                    Spacer(minLength: 12)
                }
                .padding(.horizontal, 20)
                .frame(height: 52)
                .background(palette.paneHeader)
                .overlay(alignment: .bottom) { hairline }
            }

            ZStack {
                BrowserView(browser: appState.browser(for: service)) {
                        appState.browserDidMount(service)
                    }
                    .id(service)
                if appState.browser(for: service).phase == .verificationRequired {
                    verificationNotice(for: service)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var promptDrawer: some View {
        Group {
            if isComposerOpen {
                expandedComposer
            } else {
                collapsedComposer
            }
        }
        .background(palette.drawer)
        .overlay(alignment: .top) { hairline }
    }

    private var expandedComposer: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("PROMPT")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(1.15)
                    .foregroundStyle(palette.secondaryText)
                Spacer()
                Button {
                    isComposerOpen = false
                } label: {
                    Label("Collapse", systemImage: "chevron.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(palette.secondaryText)
                }
                .buttonStyle(.plain)
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .help("Collapse prompt composer")
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
                Spacer()
                if !appState.isSplitView {
                    Button("Send to Both") {
                        sendAndCollapse(to: .both)
                    }
                    .buttonStyle(PromptButtonStyle(kind: .secondary, palette: palette))
                    .keyboardShortcut(.return, modifiers: [.command, .option])
                    .disabled(!canSend(to: .both))

                    Button("Send to \(appState.selectedService.title)") {
                        sendAndCollapse(to: .current)
                    }
                    .buttonStyle(PromptButtonStyle(kind: .primary, palette: palette))
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(!canSend(to: .current))
                } else {
                    Button("Send to Both") {
                        sendAndCollapse(to: .both)
                    }
                    .buttonStyle(PromptButtonStyle(kind: .primary, palette: palette))
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(!canSend(to: .both))
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func sendAndCollapse(to target: PromptTarget) {
        Task {
            let results = await appState.send(to: target)
            presentToast(for: results)
            if !results.isEmpty && results.allSatisfy(\.wasSent) {
                isComposerOpen = false
            }
        }
    }

    private func canSend(to target: PromptTarget) -> Bool {
        !appState.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && appState.canSend(to: target)
    }

    private var collapsedComposer: some View {
        Button {
            isComposerOpen = true
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "chevron.up")
                Text("Prompt — collapsed, ⌘⇧P to expand")
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(palette.secondaryText)
            .frame(maxWidth: .infinity)
            .frame(height: 43)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut("p", modifiers: [.command, .shift])
        .help("Open shared prompt")
    }

    private func serviceStatus(_ service: ChatService) -> some View {
        let status = appState.statuses[service] ?? .idle
        return HStack(spacing: 7) {
            Circle()
                .fill(statusColor(for: status, service: service))
                .frame(width: 9, height: 9)
            if status == .sending {
                Text("Sending…")
            }
        }
        .font(.system(size: 14, weight: .medium))
        .foregroundStyle(palette.secondaryText)
        .accessibilityLabel("\(service.title): \(status.label)")
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
        guard !results.isEmpty else { return }
        let failedResults = results.filter { !$0.wasSent }
        let sentServices = results.filter(\.wasSent).map(\.service.title)
        let nextToast: DispatchToast

        if failedResults.isEmpty {
            let destination = sentServices.joined(separator: " and ")
            nextToast = DispatchToast(message: "Sent to \(destination)", style: .success)
        } else {
            let failed = failedResults[0]
            let successPrefix = sentServices.isEmpty ? "" : "Sent to \(sentServices.joined(separator: " and ")) · "
            let failures = failedResults
                .map { "\($0.service.title): \($0.outcome.status.label)" }
                .joined(separator: " · ")
            nextToast = DispatchToast(
                message: "\(successPrefix)\(failures)",
                style: .error,
                actionService: failed.service
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

    private func dismissToast() {
        toastDismissal?.cancel()
        withAnimation(.easeOut(duration: 0.2)) {
            toast = nil
        }
    }

    private func verificationNotice(for service: ChatService) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.shield.trianglebadge.exclamationmark")
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
                Button("Retry here") { appState.browser(for: service).reload() }
                Button("Open in browser") { appState.browser(for: service).openInDefaultBrowser() }
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

    private func providerColor(for service: ChatService) -> Color {
        switch service {
        case .chatGPT: return Color(red: 0.25, green: 0.60, blue: 0.93)
        case .claude: return Color(red: 0.92, green: 0.49, blue: 0.23)
        }
    }

    private func statusColor(for status: PromptDispatchStatus, service: ChatService) -> Color {
        switch status {
        case .idle, .sent: return providerColor(for: service)
        case .sending: return Color(red: 0.25, green: 0.60, blue: 0.93)
        case .loginRequired, .unavailable, .failed: return Color(red: 0.92, green: 0.49, blue: 0.23)
        }
    }

    private var hairline: some View {
        Rectangle()
            .fill(palette.border)
            .frame(height: 1)
    }

    private var divider: some View {
        Rectangle()
            .fill(palette.border)
            .frame(width: 1, height: 28)
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

private struct AppPalette {
    let scheme: ColorScheme

    private var isDark: Bool { scheme == .dark }
    var canvas: Color { isDark ? Color(red: 0.055, green: 0.06, blue: 0.07) : Color(red: 0.955, green: 0.952, blue: 0.94) }
    var controlBar: Color { isDark ? Color(red: 0.085, green: 0.09, blue: 0.105) : Color(red: 0.94, green: 0.938, blue: 0.925) }
    var paneHeader: Color { isDark ? Color(red: 0.075, green: 0.08, blue: 0.09) : Color(red: 0.985, green: 0.983, blue: 0.975) }
    var drawer: Color { isDark ? Color(red: 0.08, green: 0.085, blue: 0.10) : Color(red: 0.965, green: 0.963, blue: 0.95) }
    var controlWell: Color { isDark ? Color(red: 0.035, green: 0.04, blue: 0.05) : Color(red: 0.89, green: 0.888, blue: 0.875) }
    var selectedControl: Color { isDark ? Color(red: 0.17, green: 0.18, blue: 0.21) : .white }
    var textField: Color { isDark ? Color(red: 0.105, green: 0.11, blue: 0.13) : .white }
    var primaryText: Color { isDark ? Color(red: 0.91, green: 0.92, blue: 0.94) : Color(red: 0.10, green: 0.11, blue: 0.13) }
    var secondaryText: Color { isDark ? Color(red: 0.62, green: 0.64, blue: 0.68) : Color(red: 0.36, green: 0.38, blue: 0.42) }
    var tertiaryText: Color { isDark ? Color(red: 0.45, green: 0.47, blue: 0.51) : Color(red: 0.50, green: 0.52, blue: 0.56) }
    var border: Color { isDark ? Color.white.opacity(0.10) : Color.black.opacity(0.12) }
    var fieldBorder: Color { isDark ? Color.white.opacity(0.16) : Color.black.opacity(0.16) }
    var success: Color { Color(red: 0.20, green: 0.64, blue: 0.42) }
    var warning: Color { Color(red: 0.92, green: 0.49, blue: 0.23) }
    var accent: Color { Color(red: 0.34, green: 0.40, blue: 0.82) }
}

private enum LaunchDestination {
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
                    .font(.system(size: 35, weight: .medium))
                    .foregroundStyle(service == .chatGPT ? Color(red: 0.25, green: 0.60, blue: 0.93) : Color(red: 0.92, green: 0.49, blue: 0.23))
            }
        }
        .frame(width: 38, height: 38)
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

private enum PromptButtonKind {
    case primary
    case secondary
}

private struct PromptButtonStyle: ButtonStyle {
    let kind: PromptButtonKind
    let palette: AppPalette

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(kind == .primary ? Color.white : palette.primaryText)
            .padding(.horizontal, 16)
            .frame(height: 36)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(kind == .primary ? palette.accent : palette.textField)
                    .opacity(configuration.isPressed ? 0.82 : 1)
            }
            .overlay {
                if kind == .secondary {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(palette.fieldBorder, lineWidth: 1)
                }
            }
            .opacity(configuration.isPressed ? 0.88 : 1)
    }
}
