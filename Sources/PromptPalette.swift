import AppKit
@preconcurrency import Carbon.HIToolbox
import SwiftUI

@MainActor
final class DuetApplicationDelegate: NSObject, NSApplicationDelegate {
    private var quickPrompt: QuickPromptPanelController?
    private var hotKey: GlobalHotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    func configureQuickPrompt(with appState: AppState, reopenWorkspace: @escaping () -> Void) {
        guard quickPrompt == nil else { return }

        let quickPrompt = QuickPromptPanelController(
            appState: appState,
            reopenWorkspace: reopenWorkspace
        )
        self.quickPrompt = quickPrompt
        hotKey = GlobalHotKey(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey)) { [weak quickPrompt] in
            quickPrompt?.show()
        }
    }

    func showQuickPrompt() {
        quickPrompt?.show()
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotKey?.invalidate()
    }
}

@MainActor
private final class QuickPromptPanelController: NSObject, NSWindowDelegate {
    private let appState: AppState
    private let reopenWorkspace: () -> Void
    private let panel: NSPanel

    init(appState: AppState, reopenWorkspace: @escaping () -> Void) {
        self.appState = appState
        self.reopenWorkspace = reopenWorkspace
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 234),
            styleMask: [.titled, .closable, .fullSizeContentView, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.title = "Quick Prompt"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.backgroundColor = NSColor(name: nil) { appearance in
            if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
                NSColor(red: 0.055, green: 0.06, blue: 0.07, alpha: 1)
            } else {
                NSColor(red: 0.985, green: 0.983, blue: 0.975, alpha: 1)
            }
        }
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.contentViewController = NSHostingController(
            rootView: QuickPromptView(appState: appState) { [weak self] in
                self?.dismiss()
            } revealWorkspace: { [weak self] in
                self?.revealWorkspace()
            }
        )
        panel.center()
    }

    func show() {
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { [weak panel] in
            panel?.makeKeyAndOrderFront(nil)
        }
    }

    private func dismiss() {
        panel.orderOut(nil)
    }

    private func revealWorkspace() {
        NSApp.unhide(nil)

        if let workspaceWindow = workspaceWindow(), workspaceWindow.isVisible || workspaceWindow.isMiniaturized {
            focus(workspaceWindow)
            return
        }

        reopenWorkspace()
        focusReopenedWorkspace()
    }

    private func workspaceWindow() -> NSWindow? {
        if let registeredWorkspaceWindow = DuetWindowRegistry.workspaceWindow {
            return registeredWorkspaceWindow
        }
        return NSApp.windows.first { $0.identifier == DuetWindowIdentifier.workspace }
    }

    private func focusReopenedWorkspace(attemptsRemaining: Int = 20) {
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50)) { [weak self] in
            guard let self else { return }
            if let workspaceWindow = self.workspaceWindow(), workspaceWindow.isVisible || workspaceWindow.isMiniaturized {
                self.focus(workspaceWindow)
            } else if attemptsRemaining > 1 {
                self.focusReopenedWorkspace(attemptsRemaining: attemptsRemaining - 1)
            }
        }
    }

    private func focus(_ workspaceWindow: NSWindow) {
        workspaceWindow.deminiaturize(nil)
        NSApp.activate(ignoringOtherApps: true)
        workspaceWindow.makeKeyAndOrderFront(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}

private struct QuickPromptView: View {
    @ObservedObject var appState: AppState
    let dismiss: () -> Void
    let revealWorkspace: () -> Void

    @State private var prompt = ""
    @FocusState private var isPromptFocused: Bool
    @Environment(\.colorScheme) private var colorScheme

    private var palette: QuickPromptPalette { QuickPromptPalette(scheme: colorScheme) }

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(palette.border)
                .frame(height: 1)

            VStack(alignment: .leading, spacing: 0) {
                Text("Quick prompt")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(palette.primaryText)

                TextEditor(text: $prompt)
                    .font(.system(size: 15))
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .frame(height: 76)
                    .background(palette.textField, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(palette.fieldBorder, lineWidth: 1)
                    }
                    .focused($isPromptFocused)
                    .padding(.top, 16)

                HStack(spacing: 10) {
                    Spacer(minLength: 16)

                    deliveryButton("ChatGPT", target: .service(.chatGPT))
                    deliveryButton("Claude", target: .service(.claude))
                    deliveryButton("Both", target: .both, prominent: true)
                }
                .padding(.top, 16)
            }
            .padding(.horizontal, 42)
            .padding(.top, 24)
            .padding(.bottom, 24)
        }
        .background(palette.canvas)
        .frame(width: 540, alignment: .top)
        .frame(maxHeight: .infinity, alignment: .top)
        .onAppear {
            isPromptFocused = true
        }
    }

    @ViewBuilder
    private func deliveryButton(_ title: String, target: QuickPromptTarget, prominent: Bool = false) -> some View {
        if prominent {
            Button(title) {
                send(to: target)
            }
            .buttonStyle(QuickPromptActionStyle(kind: .primary, palette: palette))
            .disabled(!canSend(to: target))
            .accessibilityLabel("Send to \(target.accessibilityName)")
        } else {
            Button {
                send(to: target)
            } label: {
                HStack(spacing: 7) {
                    Circle()
                        .fill(providerColor(for: target))
                        .frame(width: 8, height: 8)
                    Text(title)
                }
            }
            .buttonStyle(QuickPromptActionStyle(kind: .secondary, palette: palette))
            .disabled(!canSend(to: target))
            .accessibilityLabel("Send to \(target.accessibilityName)")
        }
    }

    private func providerColor(for target: QuickPromptTarget) -> Color {
        switch target {
        case .service(.chatGPT): return Color(red: 0.25, green: 0.60, blue: 0.93)
        case .service(.claude): return Color(red: 0.92, green: 0.49, blue: 0.23)
        case .both: return palette.accent
        }
    }

    private func canSend(to target: QuickPromptTarget) -> Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !appState.hasActiveOperations
    }

    private func send(to target: QuickPromptTarget) {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        guard appState.openQuickPromptWorkspace(for: target.promptTarget) else { return }
        dismiss()
        revealWorkspace()

        Task {
            if case .both = target {
                _ = await appState.waitForSplitWorkspaceMount()
            }
            let results = await appState.send(
                prompt: text,
                to: target.promptTarget,
                startingNewConversations: true
            )
            if !results.isEmpty && results.allSatisfy(\.wasSent) {
                prompt = ""
            }
        }
    }
}

private struct QuickPromptPalette {
    let scheme: ColorScheme

    private var isDark: Bool { scheme == .dark }

    var canvas: Color { isDark ? Color(red: 0.055, green: 0.06, blue: 0.07) : Color(red: 0.985, green: 0.983, blue: 0.975) }
    var textField: Color { isDark ? Color(red: 0.105, green: 0.11, blue: 0.13) : .white }
    var primaryText: Color { isDark ? Color(red: 0.91, green: 0.92, blue: 0.94) : Color(red: 0.10, green: 0.11, blue: 0.13) }
    var border: Color { isDark ? Color.white.opacity(0.10) : Color.black.opacity(0.12) }
    var fieldBorder: Color { isDark ? Color.white.opacity(0.16) : Color.black.opacity(0.16) }
    var accent: Color { Color(red: 0.34, green: 0.40, blue: 0.82) }
}

private struct QuickPromptActionStyle: ButtonStyle {
    enum Kind {
        case primary
        case secondary
    }

    let kind: Kind
    let palette: QuickPromptPalette

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(kind == .primary ? Color.white : palette.primaryText)
            .padding(.horizontal, 14)
            .frame(minHeight: 36)
            .background(background(for: configuration))
            .overlay {
                if kind == .secondary {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(palette.fieldBorder, lineWidth: 1)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .opacity(configuration.isPressed ? 0.82 : 1)
    }

    @ViewBuilder
    private func background(for configuration: Configuration) -> some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(kind == .primary ? palette.accent.opacity(configuration.isPressed ? 0.86 : 1) : palette.textField)
    }
}

private enum QuickPromptTarget {
    case service(ChatService)
    case both

    var promptTarget: PromptTarget {
        switch self {
        case .service(let service): .service(service)
        case .both: .both
        }
    }

    var accessibilityName: String {
        switch self {
        case .service(let service): service.title
        case .both: "ChatGPT and Claude"
        }
    }
}

/// A Carbon hot key is system-wide and does not require Accessibility permission.
@MainActor
private final class GlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private let action: () -> Void

    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        self.action = action

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let userData = Unmanaged.passUnretained(self).toOpaque()
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            globalHotKeyEventHandler,
            1,
            &eventType,
            userData,
            &eventHandlerRef
        )
        guard handlerStatus == noErr else { return nil }

        let identifier = EventHotKeyID(signature: OSType(0x4455_4554), id: 1)
        let registrationStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            identifier,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard registrationStatus == noErr else {
            invalidate()
            return nil
        }
    }

    func invalidate() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
    }

    fileprivate func invoke() {
        action()
    }
}

private func globalHotKeyEventHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let userData else { return noErr }
    let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
    Task { @MainActor in
        hotKey.invoke()
    }
    return noErr
}
