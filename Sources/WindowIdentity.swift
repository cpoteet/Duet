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
    /// Posted, with the window as its object, when a window becomes the
    /// registered workspace.
    static let didRegisterWorkspaceNotification = Notification.Name("com.siolon.duet.workspaceDidRegister")

    static weak var workspaceWindow: NSWindow?

    static func register(_ window: NSWindow) {
        if let workspaceWindow,
           workspaceWindow !== window,
           NSApp.windows.contains(where: { $0 === workspaceWindow }),
           workspaceWindow.isVisible || workspaceWindow.isMiniaturized,
           !window.isVisible && !window.isMiniaturized {
            return
        }

        let replacedWindow = workspaceWindow === window ? nil : workspaceWindow
        let isNewRegistration = replacedWindow != nil
            || workspaceWindow == nil
            || window.identifier != DuetWindowIdentifier.workspace
        // Switch the registry before touching identifiers, so the replaced
        // window's marker sees it is no longer the workspace and doesn't
        // restore the identifier cleared below.
        workspaceWindow = window
        window.identifier = DuetWindowIdentifier.workspace
        window.isExcludedFromWindowsMenu = false
        if let replacedWindow {
            replacedWindow.identifier = nil
            replacedWindow.isExcludedFromWindowsMenu = true
        }
        if isNewRegistration {
            NotificationCenter.default.post(name: didRegisterWorkspaceNotification, object: window)
        }
    }

    /// Only the registered workspace may host the provider web views, so a
    /// stale or replaced window can't take them. Registration is the test,
    /// not visibility: a window reopened on another Space, or still being
    /// ordered in, is the workspace before it is visible.
    static func isActiveWorkspaceWindow(_ window: NSWindow) -> Bool {
        window === workspaceWindow && window.identifier == DuetWindowIdentifier.workspace
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

    /// The workspace to bring back: a visible or minimized one, or, while
    /// Duet is hidden, the registered window that hiding took off screen.
    /// Hidden windows don't report as visible until the unhide finishes, so
    /// without this a reveal would open a second workspace.
    static func restorableWorkspaceWindow(
        in windows: [NSWindow] = NSApp.windows,
        appIsHidden: Bool = NSApp.isHidden
    ) -> NSWindow? {
        if let visibleWindow = visibleWorkspaceWindow(in: windows) { return visibleWindow }
        guard appIsHidden,
              let workspaceWindow,
              workspaceWindow.identifier == DuetWindowIdentifier.workspace,
              windows.contains(where: { $0 === workspaceWindow }) else { return nil }
        return workspaceWindow
    }
}

@MainActor
final class WorkspaceWindowMarkerView: NSView {
    private static var hasCenteredWorkspaceThisLaunch = false

    private weak var observedWindow: NSWindow?
    private weak var registrationWindow: NSWindow?
    private var identifierObservation: NSKeyValueObservation?
    private weak var restoredWindow: NSWindow?

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if let window, window !== newWindow {
            stopObservingRegistrationTriggers(window)
            stopObservingWindowResize(window)
            restoredWindow = nil
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
        observeRegistrationTriggers(window)
        restoreWindowSizeIfNeeded(window)
        DuetWindowRegistry.register(window)
    }

    /// `register` refuses a window that isn't on screen yet while another
    /// workspace still is. Becoming key or main, or coming back from the Dock,
    /// means this window is in front, so register it again then.
    private static let registrationTriggers: [Notification.Name] = [
        NSWindow.didBecomeKeyNotification,
        NSWindow.didBecomeMainNotification,
        NSWindow.didDeminiaturizeNotification
    ]

    private func observeRegistrationTriggers(_ window: NSWindow) {
        guard registrationWindow !== window else { return }
        registrationWindow = window
        // SwiftUI replaces the identifier with its own (such as
        // "workspace-AppWindow-1") shortly after a reopened window appears.
        // Put Duet's back right away, or the panes treat the window as
        // inactive and never mount.
        identifierObservation = window.observe(\.identifier) { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.restoreIdentifierIfNeeded()
            }
        }
        for name in Self.registrationTriggers {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowMayNeedRegistration(_:)),
                name: name,
                object: window
            )
        }
    }

    private func restoreIdentifierIfNeeded() {
        guard let window,
              window.identifier != DuetWindowIdentifier.workspace,
              DuetWindowRegistry.workspaceWindow === window else { return }
        DuetWindowRegistry.register(window)
    }

    private func stopObservingRegistrationTriggers(_ window: NSWindow) {
        identifierObservation?.invalidate()
        identifierObservation = nil
        for name in Self.registrationTriggers {
            NotificationCenter.default.removeObserver(self, name: name, object: window)
        }
        registrationWindow = nil
    }

    @objc private func windowMayNeedRegistration(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === self.window else { return }
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
}

struct WorkspaceWindowMarker: NSViewRepresentable {
    func makeNSView(context: Context) -> WorkspaceWindowMarkerView {
        WorkspaceWindowMarkerView(frame: .zero)
    }

    func updateNSView(_ nsView: WorkspaceWindowMarkerView, context: Context) {
        nsView.registerWorkspaceWindow()
    }
}
