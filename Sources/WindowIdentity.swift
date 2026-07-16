import AppKit
import SwiftUI

enum DuetWindowIdentifier {
    static let workspace = NSUserInterfaceItemIdentifier("com.siolon.duet.workspace")
}

@MainActor
final class WorkspaceWindowMarkerView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.identifier = DuetWindowIdentifier.workspace
    }
}

struct WorkspaceWindowMarker: NSViewRepresentable {
    func makeNSView(context: Context) -> WorkspaceWindowMarkerView {
        WorkspaceWindowMarkerView(frame: .zero)
    }

    func updateNSView(_ nsView: WorkspaceWindowMarkerView, context: Context) {
        nsView.window?.identifier = DuetWindowIdentifier.workspace
    }
}
