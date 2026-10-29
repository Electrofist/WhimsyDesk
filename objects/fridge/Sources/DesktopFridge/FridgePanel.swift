import AppKit

/// Borderless, transparent, non-activating panel that sits just above Finder's desktop icons.
final class FridgePanel: NSPanel {
    init(contentView view: NSView, origin: NSPoint) {
        super.init(contentRect: NSRect(origin: origin, size: Geo.windowSize),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false                       // the fridge draws its own contact shadow
        // One step above the desktop icon layer, so clicks reach it and Finder icons stay underneath.
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        // Development aid: float above other windows so the fridge can be driven while they cover the desktop.
        if ProcessInfo.processInfo.environment["FRIDGE_DEBUG_FLOAT"] != nil { level = .floating }
        // Present on every Space and not moved around by Mission Control.
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovableByWindowBackground = false     // the view moves the window itself, to show the lift shadow
        becomesKeyOnlyIfNeeded = true
        acceptsMouseMovedEvents = true          // for the open-hand cursor over the door
        contentView = view
    }

    /// Only while a sticky note is being written. The panel is non-activating, so typing into it
    /// leaves the app in front where it is.
    var allowsKey = false

    override var canBecomeKey: Bool { return allowsKey }
    override var canBecomeMain: Bool { return false }

    /// Borderless windows are allowed to hang off the screen edge.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        return frameRect
    }
}
