import AppKit
import SwiftUI

enum DuetWindowIdentifier {
    static let workspace = NSUserInterfaceItemIdentifier("com.siolon.duet.workspace")
}

@MainActor
enum DuetWindowRegistry {
    static weak var workspaceWindow: NSWindow?
}

@MainActor
final class WorkspaceWindowMarkerView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerWorkspaceWindow()
    }

    func registerWorkspaceWindow() {
        guard let window else { return }
        window.identifier = DuetWindowIdentifier.workspace
        DuetWindowRegistry.workspaceWindow = window
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
