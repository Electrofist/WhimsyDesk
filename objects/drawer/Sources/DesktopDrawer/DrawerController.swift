import AppKit
import QuartzCore

/// Borderless, non-activating panel that sits just above the Finder desktop icons.
final class DrawerPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Owns the window, the sliding physics and everything that costs power.
///
/// Geometry trick: the drawer artwork is a fixed-size view pinned to the TOP of the window, and the
/// window itself is resized from the bottom of the usable screen. Sliding therefore never redraws
/// anything, and the closed drawer is just a small strip that never overlaps the Dock.
///
/// Power model: the CADisplayLink exists only while something is moving. At rest (closed, or parked
/// open) there is no link, no timer and no polling; everything else is event-driven.
final class DrawerController: NSObject {
    static let width: CGFloat = 720
    static let faceHeight: CGFloat = 56
    static let interiorHeight: CGFloat = 224
    static let totalHeight: CGFloat = faceHeight + interiorHeight

    // Position: 0 = closed … 1 = fully open. Velocity: full travels per second.
    private let interactiveThreshold: CGFloat = 0.6    // items usable / drops accepted past this
    private let driftZone: CGFloat = 0.18              // below this, an unattended drawer drifts shut
    private let friction: CGFloat = 5                  // velocity decay per second
    private let driftAccel: CGFloat = 0.5              // gentle pull toward closed inside the drift zone

    private let store: DrawerStore
    private let panel: DrawerPanel
    private let drawerView: DrawerView

    private(set) var position: CGFloat = 0
    private var velocity: CGFloat = 0
    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0
    private var isGrabbed = false
    private var grabOffset: CGFloat = 0
    private var samples: [(t: TimeInterval, p: CGFloat)] = []
    private var lastThunk: CFTimeInterval = 0

    private var asleep = false { didSet { updateSuspension() } }
    private var locked = false { didSet { updateSuspension() } }
    private var suspended = false

    /// True while a file drag is hovering over the drawer or being pulled out of it.
    /// The drawer never moves toward closed while this is set.
    var dragInProgress = false {
        didSet {
            if dragInProgress, velocity < 0 { velocity = 0 }
            if !dragInProgress { wake() }
        }
    }

    var isInteractive: Bool { position >= interactiveThreshold }
    private var lowPower: Bool { ProcessInfo.processInfo.isLowPowerModeEnabled }
    private var driftActive: Bool {
        position > 0 && position < driftZone && !dragInProgress && !isGrabbed && !lowPower
    }
    private var needsMotion: Bool { velocity != 0 || driftActive }

    init(store: DrawerStore) {
        self.store = store
        panel = DrawerPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.faceHeight),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        drawerView = DrawerView(store: store)
        super.init()
        drawerView.controller = self
        configurePanel()
        observeSystem()
    }

    func show() {
        store.reload { [weak self] in self?.drawerView.refresh() }
        apply()
        panel.orderFrontRegardless()
    }

    // MARK: Window

    private func configurePanel() {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovable = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: Self.width, height: Self.faceHeight))
        container.autoresizesSubviews = false
        drawerView.autoresizingMask = []
        drawerView.frame.origin = NSPoint(x: 0, y: Self.faceHeight - Self.totalHeight)
        container.addSubview(drawerView)
        panel.contentView = container
    }

    /// Resizes the window to the visible slice of the drawer and keeps the artwork pinned to the top.
    private func apply() {
        guard let screen = NSScreen.screens.first else { return }
        let scale = screen.backingScaleFactor
        let height = ((Self.faceHeight + position * Self.interiorHeight) * scale).rounded() / scale
        drawerView.setFrameOrigin(NSPoint(x: 0, y: height - Self.totalHeight))
        panel.setFrame(NSRect(x: (screen.frame.midX - Self.width / 2).rounded(),
                              y: screen.visibleFrame.minY,        // rises from the top of the Dock, if any
                              width: Self.width, height: height),
                       display: false)
    }

    private func commit(from old: CGFloat) {
        apply()
        if old < interactiveThreshold, position >= interactiveThreshold {
            store.reload { [weak self] in self?.drawerView.refresh() }
        }
    }

    // MARK: User input (called by the view)

    func beginGrab(mouseY: CGFloat) {
        isGrabbed = true
        velocity = 0
        stopLink()
        samples.removeAll()
        grabOffset = panel.frame.maxY - mouseY
    }

    func grab(mouseY: CGFloat, time: TimeInterval) {
        guard isGrabbed, let visible = NSScreen.screens.first?.visibleFrame else { return }
        let old = position
        let top = mouseY + grabOffset
        position = min(1, max(0, (top - visible.minY - Self.faceHeight) / Self.interiorHeight))
        samples.append((time, position))
        samples.removeAll { time - $0.t > 0.1 }
        commit(from: old)
        if old > 0, position == 0 { thunk(volume: 0.3) }
    }

    func endGrab(time: TimeInterval) {
        isGrabbed = false
        samples.removeAll { time - $0.t > 0.1 }
        if let a = samples.first, let b = samples.last, b.t > a.t {
            velocity = max(-8, min(8, (b.p - a.p) / CGFloat(b.t - a.t)))      // carry the flick
        } else {
            velocity = 0                                                       // held still: it stays put
        }
        samples.removeAll()
        wake()
    }

    func toggle() {
        guard !suspended else { return }
        velocity = position > 0.5 ? -friction * position * 1.3 : friction * (1 - position) * 1.25
        wake()
    }

    /// A file hovering over the closed drawer pulls it open (like a spring-loaded folder).
    func openForDrag() {
        guard position < interactiveThreshold else { return }
        velocity = max(velocity, friction * (1 - position) * 1.2)
        wake()
    }

    func itemsDropped() { thunk(volume: 0.3) }

    // MARK: Physics (runs only while the display link is alive)

    func wake() {
        guard link == nil, !suspended, !isGrabbed, needsMotion, panel.isVisible else { return }
        let l = drawerView.displayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
        applyFrameRate()
    }

    private func stopLink() {
        link?.invalidate()
        link = nil
        lastTimestamp = 0
    }

    private func applyFrameRate() {
        link?.preferredFrameRateRange = lowPower
            ? CAFrameRateRange(minimum: 24, maximum: 30, preferred: 30)
            : CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
    }

    @objc private func tick(_ link: CADisplayLink) {
        var dt = lastTimestamp == 0 ? link.targetTimestamp - link.timestamp : link.timestamp - lastTimestamp
        lastTimestamp = link.timestamp
        dt = min(max(dt, 1.0 / 240), 1.0 / 20)
        step(CGFloat(dt))
    }

    private func step(_ dt: CGFloat) {
        let old = position
        velocity *= exp(-friction * dt)                       // damping
        if driftActive { velocity -= driftAccel * dt }        // slow drift shut when left barely open
        if dragInProgress, velocity < 0 { velocity = 0 }      // never close during a drag

        position += velocity * dt
        if position >= 1 { position = 1; velocity = 0 }       // solid stop at the open end
        if position <= 0 {                                    // soft thud + tiny rebound at the closed end
            position = 0
            let impact = max(0, -velocity)
            if old > 0 { thunk(volume: Float(min(0.5, 0.15 + impact * 0.5))) }
            velocity = impact * 0.12
        }

        let settled = position == 0 ? velocity < 0.03 : (!driftActive && abs(velocity) < 0.01)
        if settled { velocity = 0 }

        commit(from: old)
        if !needsMotion { stopLink() }                        // at rest: zero cost
    }

    private func thunk(volume: Float) {
        guard !suspended else { return }
        let now = CACurrentMediaTime()
        guard now - lastThunk > 0.5 else { return }
        lastThunk = now
        SoftSound.play(volume: volume)
    }

    // MARK: System events (all event-driven)

    private func updateSuspension() {
        suspended = asleep || locked
        if suspended {
            stopLink()
            velocity = 0            // freeze exactly where it is; nothing is forced shut
        } else {
            wake()                  // resumes in the state it was left (drift continues if it was barely open)
        }
    }

    private func observeSystem() {
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.asleep = true }
        }
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.asleep = false }
        }

        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            self?.locked = true
        }
        distributed.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            self?.locked = false
        }

        NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.applyFrameRate()
            self?.wake()
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.apply()
        }
    }
}
