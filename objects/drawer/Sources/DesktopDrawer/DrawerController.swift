import AppKit
import QuartzCore

/// Borderless, non-activating panel that sits just above the Finder desktop icons.
final class DrawerPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Layer-only helper views. They never draw through draw(_:), so moving or resizing them every frame
/// is just a compositor update.
private class PassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class GradientView: PassthroughView {
    override func makeBackingLayer() -> CALayer { CAGradientLayer() }
}

/// Owns the window, the sliding physics and everything that costs power.
///
/// Geometry trick: the drawer artwork is a fixed-size view pinned to the TOP of the window, and the
/// window itself is resized from the bottom of the usable screen. Sliding therefore never redraws
/// anything, and the closed drawer is just a small strip that never overlaps the Dock.
///
/// Power model: the CADisplayLink (and the sliding sound) exist only while something is moving. At
/// rest (closed, or parked open) there is no link, no timer and no polling; everything else is event-driven.
final class DrawerController: NSObject {
    static let width: CGFloat = 720
    static let faceHeight: CGFloat = 60
    static let interiorHeight: CGFloat = 224
    static let totalHeight: CGFloat = faceHeight + interiorHeight
    static let margin: CGFloat = 30              // room around the drawer for its soft shadow
    static let topPad: CGFloat = 16
    static let boxInset: CGFloat = 16            // the box is a little narrower than the front panel
    static let viewWidth: CGFloat = width + margin * 2
    static let viewHeight: CGFloat = topPad + totalHeight

    // Position: 0 = closed … 1 = fully open (slightly negative = pressed into the soft-close bumpers).
    // Velocity: full travels per second.
    private let interactiveThreshold: CGFloat = 0.6    // items usable / drops accepted past this
    private let driftZone: CGFloat = 0.16              // below this, an unattended drawer is pulled shut
    private let driftAccel: CGFloat = 0.9
    private let viscous: CGFloat = 3.0                 // greased runners: velocity decay per second
    private let coulomb: CGFloat = 1.2                 // dry wood-on-wood friction, travels/s²
    private let bumperStiffness: CGFloat = 1500        // felt bumpers at the back of the cabinet
    private let bumperDamping: CGFloat = 48
    private let bumperLimit: CGFloat = -0.05
    private let stopRestitution: CGFloat = 0.22        // rebound off the stop block at full extension
    private let handStiffness: CGFloat = 240           // hand → drawer coupling: it lags like something heavy
    private let handDamping: CGFloat = 27

    private let store: DrawerStore
    private let panel: DrawerPanel
    private let drawerView: DrawerView
    private let castShadow = PassthroughView()
    private let cabinetShade = GradientView()

    private(set) var position: CGFloat = 0
    private var velocity: CGFloat = 0
    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0
    private var isGrabbed = false
    private var grabOffset: CGFloat = 0
    private var grabTarget: CGFloat = 0
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
    private var needsMotion: Bool {
        if isGrabbed { return abs(grabTarget - position) > 0.0005 || abs(velocity) > 0.001 }
        return velocity != 0 || driftActive || position < 0
    }
    /// A loaded drawer sits a touch lower on its runners.
    private var sag: CGFloat { store.items.isEmpty ? 0 : 1.5 }

    init(store: DrawerStore) {
        self.store = store
        panel = DrawerPanel(contentRect: NSRect(x: 0, y: 0, width: Self.viewWidth, height: Self.topPad + Self.faceHeight),
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

    func contentsChanged() { apply() }

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

        let container = NSView(frame: NSRect(x: 0, y: 0, width: Self.viewWidth, height: Self.topPad + Self.faceHeight))
        container.wantsLayer = true
        container.autoresizesSubviews = false

        castShadow.wantsLayer = true
        castShadow.layer?.shadowColor = NSColor.black.cgColor
        castShadow.layer?.masksToBounds = false

        cabinetShade.wantsLayer = true
        if let g = cabinetShade.layer as? CAGradientLayer {
            g.colors = [NSColor.black.withAlphaComponent(0.85).cgColor, NSColor.black.withAlphaComponent(0.35).cgColor,
                        NSColor.black.withAlphaComponent(0).cgColor]
            g.locations = [0, 0.3, 1]
            g.startPoint = CGPoint(x: 0.5, y: 0)
            g.endPoint = CGPoint(x: 0.5, y: 1)
        }

        drawerView.autoresizingMask = []
        container.addSubview(castShadow)
        container.addSubview(drawerView)
        container.addSubview(cabinetShade)
        panel.contentView = container
    }

    /// Resizes the window to the visible slice of the drawer and keeps the artwork pinned to the top.
    private func apply() {
        guard let screen = NSScreen.screens.first else { return }
        let scale = screen.backingScaleFactor
        let open = Self.topPad + Self.faceHeight + position * Self.interiorHeight
        let height = max(Self.topPad + 8, (open * scale).rounded() / scale)
        let s = sag

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        drawerView.setFrameOrigin(NSPoint(x: 0, y: height - Self.viewHeight - s))

        // Contact shadow on the desktop: follows the visible drawer and grows softer and deeper the
        // further it's pulled out, as the drawer stands further proud of the cabinet.
        let faceTop = height - Self.topPad - s, faceBottom = faceTop - Self.faceHeight
        let p = max(0, min(1, position))
        let outline = CGMutablePath()
        outline.addRoundedRect(in: CGRect(x: Self.margin, y: faceBottom, width: Self.width, height: Self.faceHeight),
                               cornerWidth: 4, cornerHeight: 4)
        if faceBottom > 0 {
            outline.addRect(CGRect(x: Self.margin + Self.boxInset, y: 0, width: Self.width - Self.boxInset * 2,
                                   height: faceBottom + 2))
        }
        castShadow.frame = NSRect(x: 0, y: 0, width: Self.viewWidth, height: height)
        if let l = castShadow.layer {
            l.shadowPath = outline
            l.shadowRadius = 7 + 9 * p
            l.shadowOpacity = Float(0.34 + 0.16 * p)
            l.shadowOffset = CGSize(width: 0, height: -(3 + 5 * p))
        }

        // Darkness inside the cabinet, right where the drawer disappears into it.
        cabinetShade.frame = NSRect(x: Self.margin + Self.boxInset, y: 0, width: Self.width - Self.boxInset * 2,
                                    height: min(60, max(0, faceBottom)))
        CATransaction.commit()

        panel.setFrame(NSRect(x: (screen.frame.midX - Self.viewWidth / 2).rounded(),
                              y: screen.visibleFrame.minY,        // rises from the top of the Dock, if any
                              width: Self.viewWidth, height: height),
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
        grabTarget = position                 // catching a moving drawer: the hand takes over from here
        grabOffset = panel.frame.maxY - mouseY
        wake()
    }

    func grab(mouseY: CGFloat) {
        guard isGrabbed, let visible = NSScreen.screens.first?.visibleFrame else { return }
        let top = mouseY + grabOffset
        grabTarget = min(1, max(-0.02, (top - visible.minY - Self.topPad - Self.faceHeight) / Self.interiorHeight))
        wake()
    }

    func endGrab() {
        isGrabbed = false
        velocity = max(-6, min(6, velocity))  // the drawer keeps whatever momentum the hand gave it
        wake()
    }

    func toggle() {
        guard !suspended else { return }
        velocity = position > 0.5 ? -launchSpeed(toTravel: position + 0.05) : launchSpeed(toTravel: 1 - position + 0.04)
        wake()
    }

    /// A file hovering over the closed drawer pulls it open (like a spring-loaded folder).
    func openForDrag() {
        guard position < interactiveThreshold else { return }
        velocity = max(velocity, launchSpeed(toTravel: 1 - position + 0.03))
        wake()
    }

    func itemsDropped() { thunk(.close, volume: 0.25) }

    /// Initial speed that coasts exactly `d` travels under viscous + dry friction (bisection on the
    /// closed-form stopping distance of dv/dt = −k·v − c).
    private func launchSpeed(toTravel d: CGFloat) -> CGFloat {
        let k = viscous, c = coulomb
        func travel(_ v: CGFloat) -> CGFloat { v / k - (c / (k * k)) * log(1 + k * v / c) }
        var lo: CGFloat = 0, hi: CGFloat = 30
        for _ in 0..<40 {
            let mid = (lo + hi) / 2
            if travel(mid) < d { lo = mid } else { hi = mid }
        }
        return hi
    }

    // MARK: Physics (runs only while the display link is alive)

    func wake() {
        guard link == nil, !suspended, needsMotion, panel.isVisible else { return }
        let l = drawerView.displayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
        applyFrameRate()
        SoftSound.beginSlide()
    }

    private func stopLink() {
        guard link != nil else { return }
        link?.invalidate()
        link = nil
        lastTimestamp = 0
        SoftSound.endSlide()
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
        let old = position
        let substeps = Int((dt * 480).rounded(.up))            // the bumpers are stiff; keep integration stable
        for _ in 0..<substeps { step(CGFloat(dt) / CGFloat(substeps)) }
        commit(from: old)
        SoftSound.slide(speed: isGrabbed || position > 0 ? abs(velocity) : 0)
        if !needsMotion { stopLink() }                          // at rest: zero cost
    }

    private func step(_ dt: CGFloat) {
        let wasOut = position >= 0

        if isGrabbed {
            velocity += (handStiffness * (grabTarget - position) - handDamping * velocity) * dt
        } else {
            velocity *= exp(-viscous * dt)
            if driftActive {
                velocity -= driftAccel * dt                     // soft-close pull when left barely open
            } else if position > 0, velocity != 0 {
                let dv = coulomb * dt
                velocity = abs(velocity) <= dv ? 0 : velocity - (velocity > 0 ? dv : -dv)
            }
            if dragInProgress, velocity < 0 { velocity = 0 }    // never close during a drag
        }
        if position < 0 {                                       // pressed into the felt bumpers
            velocity += (-bumperStiffness * position - bumperDamping * velocity) * dt
        }

        position += velocity * dt

        if wasOut, position < 0, velocity < 0 {                 // front panel meets the cabinet
            thunk(.close, volume: Float(min(0.6, 0.1 + -velocity * 0.16)))
        }
        if position < bumperLimit { position = bumperLimit; velocity = max(0, velocity) }
        if position >= 1 {                                      // stop block at full extension: knock, small rebound
            position = 1
            if velocity > 0 {
                if velocity > 0.12 { thunk(.open, volume: Float(min(0.45, 0.08 + velocity * 0.14))) }
                velocity = isGrabbed ? 0 : -velocity * stopRestitution
            }
        }

        guard !isGrabbed else { return }
        if abs(position) < 0.002, abs(velocity) < 0.05 {        // settled shut
            position = 0
            velocity = 0
        } else if position > 0, !driftActive, abs(velocity) < 0.004 {
            velocity = 0
        }
    }

    private func thunk(_ kind: SoftSound.Kind, volume: Float) {
        guard !suspended else { return }
        let now = CACurrentMediaTime()
        guard now - lastThunk > 0.35 else { return }
        lastThunk = now
        SoftSound.play(kind, volume: volume)
    }

    // MARK: System events (all event-driven)

    private func updateSuspension() {
        suspended = asleep || locked
        if suspended {
            stopLink()
            velocity = 0            // freeze exactly where it is; nothing is forced shut
            if position < 0 { position = 0; apply() }
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
