import AppKit
import SwiftUI

enum DuetWindowIdentifier {
    static let workspace = NSUserInterfaceItemIdentifier("com.siolon.duet.workspace")
}

@MainActor
enum DuetWindowSizePersistence {
    private static let widthKey = "workspaceWindowWidth"
    private static let heightKey = "workspaceWindowHeight"

    static func save(_ window: NSWindow, userDefaults: UserDefaults = .standard) {
        let size = window.frame.size
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return }
        userDefaults.set(size.width, forKey: widthKey)
        userDefaults.set(size.height, forKey: heightKey)
    }

    static func restore(
        _ window: NSWindow,
        centerInVisibleScreen: Bool,
        userDefaults: UserDefaults = .standard
    ) {
        let width = CGFloat(userDefaults.double(forKey: widthKey))
        let height = CGFloat(userDefaults.double(forKey: heightKey))

        let visibleFrame = (window.screen ?? NSScreen.main)?.visibleFrame
        var frame = window.frame
        if width.isFinite, height.isFinite, width > 0, height > 0 {
            frame.size = NSSize(
                width: min(width, visibleFrame?.width ?? width),
                height: min(height, visibleFrame?.height ?? height)
            )
        }
        if centerInVisibleScreen, let visibleFrame {
            frame.origin = NSPoint(
                x: visibleFrame.midX - (frame.width / 2),
                y: visibleFrame.midY - (frame.height / 2)
            )
        }
        window.setFrame(frame, display: false)
    }
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
final class WorkspaceWindowMarkerView: NSView {
    private static var hasCenteredWorkspaceThisLaunch = false

    private var registrationTask: Task<Void, Never>?
    private weak var observedWindow: NSWindow?
    private weak var restoredWindow: NSWindow?

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if let window, window !== newWindow {
            registrationTask?.cancel()
            registrationTask = nil
            stopObservingWindowResize(window)
            restoredWindow = nil
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
        restoreWindowSizeIfNeeded(window)
        DuetWindowRegistry.register(window)
    }

    private func restoreWindowSizeIfNeeded(_ window: NSWindow) {
        guard restoredWindow !== window else { return }
        restoredWindow = window
        let shouldCenter = !Self.hasCenteredWorkspaceThisLaunch
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, self.window === window else { return }
            if shouldCenter {
                Self.hasCenteredWorkspaceThisLaunch = true
            }
            DuetWindowSizePersistence.restore(
                window,
                centerInVisibleScreen: shouldCenter
            )
            self.observeWindowResize(window)
        }
    }

    private func observeWindowResize(_ window: NSWindow) {
        guard observedWindow !== window else { return }
        observedWindow = window
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidResize(_:)),
            name: NSWindow.didResizeNotification,
            object: window
        )
    }

    private func stopObservingWindowResize(_ window: NSWindow) {
        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.didResizeNotification,
            object: window
        )
        observedWindow = nil
    }

    @objc private func windowDidResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === self.window else { return }
        DuetWindowSizePersistence.save(window)
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
