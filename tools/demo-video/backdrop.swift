import AppKit
// Solid backdrop behind the windows being recorded. Ignores the mouse and never takes focus.
final class Backdrop: NSWindow { override var canBecomeKey: Bool { false }; override var canBecomeMain: Bool { false } }
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let frame = NSScreen.main!.frame
let w = Backdrop(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
w.backgroundColor = NSColor(srgbRed: 0x0f/255, green: 0x19/255, blue: 0x32/255, alpha: 1)
w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
w.ignoresMouseEvents = true
w.isReleasedWhenClosed = false
w.hasShadow = false
w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
w.orderFrontRegardless()
signal(SIGTERM) { _ in exit(0) }
app.run()
