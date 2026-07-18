import AppKit
import SwiftUI

enum DuetWindowIdentifier {
    static let workspace = NSUserInterfaceItemIdentifier("com.siolon.duet.workspace")
}

@MainActor
enum DuetWindowRegistry {
    static weak var workspaceWindow: NSWindow?

    static func register(_ window: NSWindow) {
        if let workspaceWindow,
           workspaceWindow !== window,
           NSApp.windows.contains(where: { $0 === workspaceWindow }),
           workspaceWindow.isVisible || workspaceWindow.isMiniaturized,
           !window.isVisible && !window.isMiniaturized {
            return
        }

        if let workspaceWindow, workspaceWindow !== window {
            workspaceWindow.identifier = nil
            workspaceWindow.isExcludedFromWindowsMenu = true
        }

        window.identifier = DuetWindowIdentifier.workspace
        window.isExcludedFromWindowsMenu = false
        workspaceWindow = window
    }

    static func isActiveWorkspaceWindow(_ window: NSWindow) -> Bool {
        window.identifier == DuetWindowIdentifier.workspace
            && (window.isVisible || window.isMiniaturized)
    }

    static func unregister(_ window: NSWindow) {
        guard workspaceWindow === window else { return }
        workspaceWindow = nil
    }

    static func visibleWorkspaceWindow(in windows: [NSWindow] = NSApp.windows) -> NSWindow? {
        if let workspaceWindow,
           workspaceWindow.identifier == DuetWindowIdentifier.workspace,
           windows.contains(where: { $0 === workspaceWindow }),
           workspaceWindow.isVisible || workspaceWindow.isMiniaturized {
            return workspaceWindow
        }

        guard let identifiedWindow = windows.first(where: {
            $0.identifier == DuetWindowIdentifier.workspace
                && ($0.isVisible || $0.isMiniaturized)
        }) else {
            return nil
        }

        register(identifiedWindow)
        return identifiedWindow
    }
}

@MainActor
struct WorkspaceWindowSnapshot {
    private let visibilityByWindow: [ObjectIdentifier: Bool]

    init(windows: [NSWindow]) {
        visibilityByWindow = Dictionary(uniqueKeysWithValues: windows.map {
            (ObjectIdentifier($0), $0.isVisible || $0.isMiniaturized)
        })
    }

    func reopenedWorkspaceWindow(in windows: [NSWindow]) -> NSWindow? {
        windows.first { window in
            guard !(window is NSPanel), window.isVisible || window.isMiniaturized else {
                return false
            }

            return visibilityByWindow[ObjectIdentifier(window)] != true
        }
    }
}

@MainActor
final class WorkspaceWindowMarkerView: NSView {
    private var registrationTask: Task<Void, Never>?

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if let window, window !== newWindow {
            registrationTask?.cancel()
            registrationTask = nil
            DuetWindowRegistry.unregister(window)
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerWorkspaceWindow()
        scheduleRegistrationRefresh()
    }

    func registerWorkspaceWindow() {
        guard let window else { return }
        DuetWindowRegistry.register(window)
    }

    private func scheduleRegistrationRefresh() {
        registrationTask?.cancel()
        registrationTask = Task { @MainActor [weak self] in
            for _ in 0..<10 {
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled, let self, self.window != nil else { return }
                self.registerWorkspaceWindow()
            }
            self?.registrationTask = nil
        }
    }
}

struct WorkspaceWindowMarker: NSViewRepresentable {
    func makeNSView(context: Context) -> WorkspaceWindowMarkerView {
        WorkspaceWindowMarkerView(frame: .zero)
    }

    func updateNSView(_ nsView: WorkspaceWindowMarkerView, context: Context) {
        nsView.registerWorkspaceWindow()
    }
}
