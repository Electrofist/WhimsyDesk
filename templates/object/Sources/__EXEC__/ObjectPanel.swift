import AppKit

/// A borderless, transparent window that sits just above the desktop icons, on every Space.
/// Clicks reach it, normal windows cover it.
final class ObjectPanel: NSPanel, NSWindowDelegate {
    private static let originKey = "windowOrigin"

    init(view: NSView) {
        let size = view.frame.size
        super.init(contentRect: NSRect(origin: ObjectPanel.initialOrigin(for: size), size: size),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false                       // draw the shadow into your art instead
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovableByWindowBackground = false     // Option-Command-drag moves it (see ObjectView)
        contentView = view
        delegate = self
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Remember where the object was left.
    func windowDidMove(_ notification: Notification) {
        UserDefaults.standard.set(NSStringFromPoint(frame.origin), forKey: ObjectPanel.originKey)
    }

    /// The saved spot if it is still on a screen, otherwise the lower left of the main screen.
    private static func initialOrigin(for size: CGSize) -> NSPoint {
        if let saved = UserDefaults.standard.string(forKey: originKey) {
            let p = NSPointFromString(saved)
            let frame = NSRect(origin: p, size: size)
            if NSScreen.screens.contains(where: { $0.frame.intersects(frame) }) { return p }
        }
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(x: visible.minX + 48, y: visible.minY + 24)
    }
}
