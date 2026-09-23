import AppKit
@preconcurrency import Carbon.HIToolbox
import SwiftUI

@MainActor
final class DuetApplicationDelegate: NSObject, NSApplicationDelegate {
    private var quickPrompt: QuickPromptPanelController?
    private var hotKey: GlobalHotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        DuetNotificationManager.shared.start()
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

    /// Brings the workspace forward for surfaces outside the workspace window,
    /// such as clicking a provider notification.
    func revealWorkspace() {
        quickPrompt?.revealWorkspace()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if let workspaceWindow = DuetWindowRegistry.workspaceWindow {
            DuetWindowSizePersistence.save(workspaceWindow)
        }
        return .terminateNow
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
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 212),
            styleMask: [.titled, .closable, .fullSizeContentView, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.title = "Quick Prompt"
        panel.titlebarAppearsTransparent = true
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

    func revealWorkspace() {
        NSApp.unhide(nil)

        if let workspaceWindow = DuetWindowRegistry.visibleWorkspaceWindow() {
            focus(workspaceWindow)
            return
        }

        reopenWorkspace()
        focusReopenedWorkspace()
    }

    private func focusReopenedWorkspace(
        attemptsRemaining: Int = 40
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50)) { [weak self] in
            guard let self else { return }

            if let workspaceWindow = DuetWindowRegistry.visibleWorkspaceWindow() {
                self.focus(workspaceWindow)
            } else if attemptsRemaining > 1 {
                self.focusReopenedWorkspace(
                    attemptsRemaining: attemptsRemaining - 1
                )
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
    @State private var promptRevision = 0
    @FocusState private var isPromptFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            TextEditor(text: Binding(
                get: { prompt },
                set: { prompt = $0; promptRevision &+= 1 }
            ))
                .font(.system(size: 15))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(height: 92)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.separator, lineWidth: 1)
                }
                .focused($isPromptFocused)

            HStack(spacing: 8) {
                Spacer()
                Button("ChatGPT") {
                    send(to: .service(.chatGPT))
                }
                .buttonStyle(.bordered)
                .disabled(!canSend)
                .accessibilityLabel("Send to ChatGPT")

                Button("Claude") {
                    send(to: .service(.claude))
                }
                .buttonStyle(.bordered)
                .disabled(!canSend)
                .accessibilityLabel("Send to Claude")

                Button("Both") {
                    send(to: .both)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSend)
                .accessibilityLabel("Send to ChatGPT and Claude")
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 44)
        .padding(.bottom, 20)
        .frame(width: 500, height: 212)
        .background(.thinMaterial)
        .onAppear {
            isPromptFocused = true
        }
    }

    private var canSend: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !appState.hasActiveOperations
    }

    private func send(to target: QuickPromptTarget) {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let submittedRevision = promptRevision
        guard !text.isEmpty else { return }

        guard appState.openQuickPromptWorkspace(for: target.promptTarget) else { return }
        dismiss()
        revealWorkspace()

        Task {
            guard await appState.waitForQuickPromptWorkspaceMount(for: target.promptTarget) else {
                appState.reportQuickPromptWorkspaceUnavailable(for: target.promptTarget)
                return
            }
            let results = await appState.send(
                prompt: text,
                to: target.promptTarget,
                startingNewConversations: true
            )
            if !results.isEmpty && results.allSatisfy(\.wasSent), promptRevision == submittedRevision {
                prompt = ""
            }
        }
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
