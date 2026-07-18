import AppKit
import SwiftUI

enum DuetWindowIdentifier {
    static let workspace = NSUserInterfaceItemIdentifier("com.siolon.duet.workspace")
}

@MainActor
enum DuetWindowRegistry {
    static weak var workspaceWindow: NSWindow?

    static func register(_ window: NSWindow) {
        window.identifier = DuetWindowIdentifier.workspace
        workspaceWindow = window
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

        workspaceWindow = nil

        guard let identifiedWindow = windows.first(where: {
            $0.identifier == DuetWindowIdentifier.workspace
                && ($0.isVisible || $0.isMiniaturized)
        }) else {
            return nil
        }

        workspaceWindow = identifiedWindow
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
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if let window, window !== newWindow {
            DuetWindowRegistry.unregister(window)
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerWorkspaceWindow()
    }

    func registerWorkspaceWindow() {
        guard let window else { return }
        DuetWindowRegistry.register(window)
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
