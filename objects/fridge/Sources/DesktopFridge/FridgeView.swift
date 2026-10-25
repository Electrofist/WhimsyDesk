import AppKit
import FridgeCore

/// The whole fridge: layer rig, door interaction and file drag and drop.
/// Nothing in here runs on a timer. Work happens on input events, on the door's display link
/// while it moves, and in short one-shot Core Animation transitions.
final class FridgeView: NSView, NSDraggingSource {
    // MARK: Model and helpers

    let store: FridgeStore
    private let finder = FinderBridge()
    private let sounds = SoundPlayer()
    private var driver: DoorDriver!
    private var items: ItemsController!
    private var fog: FogPlayer!

    /// Set by `SystemEvents`.
    var lowPowerMode = false
    var reduceMotion = false

    // MARK: Layers

    private let contactShadow = CALayer()
    private let liftShadow = CALayer()
    private let scene = CALayer()
    private let body = CALayer()
    private let cabinet = CALayer()
    private let interior = CALayer()
    private let frost = CALayer()
    private let darkness = CALayer()
    private let glow = CAGradientLayer()
    private let doorRoot = CATransformLayer()
    private let doorFront = CALayer()
    private let doorBack = CALayer()
    private let doorEdge = CAGradientLayer()
    private let frontShade = CALayer()
    private let backShade = CALayer()
    private let led = CATextLayer()
    private let hingeTop = CALayer()
    private let hingeBottom = CALayer()
    private let fogHost = CALayer()

    private var artScale: CGFloat = 0
    private var glowPeak: Float = 1
    private var darknessPeak: Float = 0.6

    // MARK: State

    private enum Interaction {
        case none
        /// Pressed on the door, direction not decided yet: sideways swings it, up or down moves the fridge.
        case doorPress(doorX: CGFloat, start: NSPoint)
        /// Holding the door at `doorX` (door space), so that spot stays under the pointer.
        case door(doorX: CGFloat)
        /// ⌥ drag: resizing the whole fridge.
        case resize(startMouse: NSPoint, startScale: CGFloat)
        case window(startMouse: NSPoint, startOrigin: NSPoint)
        case item(entry: FridgeEntry, start: NSPoint)
    }

    private var interaction = Interaction.none
    private var hasOpened = false
    private var itemsInteractive = false
    private var draggingEntry: FridgeEntry?

    private var timeScale: Double {
        if let raw = ProcessInfo.processInfo.environment["FRIDGE_TIME_SCALE"], let v = Double(raw), v > 0 { return v }
        let stored = UserDefaults.standard.double(forKey: "timeScale")
        return stored > 0 ? stored : 1
    }

    // MARK: Setup

    init(store: FridgeStore) {
        self.store = store
        super.init(frame: NSRect(origin: .zero, size: Geo.windowSize))
        wantsLayer = true
        layerContentsRedrawPolicy = .never

        let scale = (NSScreen.main?.backingScaleFactor ?? 2) * userScale
        items = ItemsController(store: store, scale: scale)
        buildLayers()
        driver = DoorDriver(view: self)
        driver.onFrame = { [weak self] angle in self?.applyDoor(angle: angle) }
        driver.onRest = { [weak self] in self?.doorDidRest() }
        fog = FogPlayer(host: fogHost)

        updateLighting()
        renderArt(scale: scale)
        applyDoor(angle: 0)
        registerForDraggedTypes([.fileURL])

        if let raw = ProcessInfo.processInfo.environment["FRIDGE_DEBUG_ANGLE"], let degrees = Double(raw) {
            let angle = degrees * Double.pi / 180
            driver.debugPin(angle: angle)
            applyDoor(angle: angle)
        }    }

    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    private func buildLayers() {
        guard let root = layer else { return }
        root.isOpaque = false

        contactShadow.frame = CGRect(x: Geo.bodyOrigin.x + Geo.bodySize.width / 2 - FridgeArt.contactShadowSize.width / 2,
                                     y: Geo.bodyOrigin.y - FridgeArt.contactShadowSize.height / 2 + 3,
                                     width: FridgeArt.contactShadowSize.width,
                                     height: FridgeArt.contactShadowSize.height)
        liftShadow.frame = CGRect(x: Geo.bodyOrigin.x + Geo.bodySize.width / 2 - FridgeArt.liftShadowSize.width / 2,
                                  y: Geo.bodyOrigin.y - FridgeArt.liftShadowSize.height / 2 - 8,
                                  width: FridgeArt.liftShadowSize.width,
                                  height: FridgeArt.liftShadowSize.height)
        liftShadow.opacity = 0
        root.addSublayer(liftShadow)
        root.addSublayer(contactShadow)

        // Scene: everything that belongs to the cabinet and door, with one shared perspective.
        scene.frame = Geo.bodyRectInView
        var perspective = CATransform3DIdentity
        perspective.m34 = -1 / Geo.eyeDistance
        scene.sublayerTransform = perspective
        root.addSublayer(scene)

        // The scene holds a 3D door, so Core Animation depth-tests its direct children. Everything
        // that lies flat in the cabinet plane goes into one plain container, which flattens it in
        // painter's order. Without this the cabinet z-fights the interior and hides it.
        body.frame = CGRect(origin: .zero, size: Geo.bodySize)
        scene.addSublayer(body)

        cabinet.frame = CGRect(origin: .zero, size: Geo.bodySize)
        body.addSublayer(cabinet)

        interior.frame = Geo.opening
        body.addSublayer(interior)
        frost.frame = Geo.opening
        body.addSublayer(frost)
        body.addSublayer(items.layer)

        darkness.frame = Geo.opening
        darkness.backgroundColor = CGColor(gray: 0, alpha: 1)
        body.addSublayer(darkness)

        glow.frame = Geo.opening
        glow.type = .radial
        glow.startPoint = CGPoint(x: 0.5, y: 0.78)
        glow.endPoint = CGPoint(x: 1.15, y: 0.02)
        body.addSublayer(glow)

        // Door: a transform layer so its faces and edge keep their own 3D positions.
        doorRoot.bounds = CGRect(origin: .zero, size: Geo.doorSize)
        doorRoot.anchorPoint = CGPoint(x: 0, y: 0.5)
        doorRoot.position = Geo.hinge
        // Lift the whole door so its back face sits just in front of the cabinet plane.
        doorRoot.zPosition = Geo.doorHalfThickness + 0.5
        scene.addSublayer(doorRoot)

        let doorBounds = CGRect(origin: .zero, size: Geo.doorSize)
        doorFront.frame = doorBounds
        doorFront.zPosition = Geo.doorHalfThickness
        doorFront.isDoubleSided = false
        doorRoot.addSublayer(doorFront)

        doorBack.frame = doorBounds
        doorBack.zPosition = -Geo.doorHalfThickness
        doorBack.transform = CATransform3DMakeRotation(.pi, 0, 1, 0)
        doorBack.isDoubleSided = false
        doorRoot.addSublayer(doorBack)

        // The free edge is inset by the corner radius so it never pokes past the rounded corners.
        // The free edge is the door's thickness, seen face-on once the door stands open. Its ends are
        // rounded so it follows the rounded corners of the faces.
        doorEdge.bounds = CGRect(x: 0, y: 0, width: Geo.doorHalfThickness * 2, height: Geo.doorSize.height - Geo.doorCornerRadius)
        doorEdge.position = CGPoint(x: Geo.doorSize.width - 2, y: Geo.doorSize.height / 2)
        doorEdge.transform = CATransform3DMakeRotation(.pi / 2, 0, 1, 0)
        doorEdge.cornerRadius = Geo.doorHalfThickness * 0.8
        doorEdge.masksToBounds = true
        // Painted steel rounding over from the front face, then the dark magnetic gasket on the liner side.
        doorEdge.colors = [Art.hex(0x505006), Art.hex(0x9DA716), Art.hex(0xE4E57A), Art.hex(0xB6BD21),
                           Art.hex(0x7D8202), Art.hex(0x2B2E2A), Art.hex(0x3A3D38)]
        doorEdge.locations = [0, 0.10, 0.28, 0.55, 0.72, 0.76, 1]
        doorEdge.startPoint = CGPoint(x: 0, y: 0.5)
        doorEdge.endPoint = CGPoint(x: 1, y: 0.5)
        // Single sided, facing out of the free edge: it shows whenever the door is open, because the
        // edge faces the viewer at any angle up to the open stop.
        doorEdge.isDoubleSided = false
        doorRoot.addSublayer(doorEdge)
        buildDoorBins()

        for shade in [frontShade, backShade] {
            shade.frame = doorBounds
            shade.cornerRadius = Geo.doorCornerRadius
            shade.backgroundColor = CGColor(gray: 0, alpha: 1)
            shade.opacity = 0
        }
        doorFront.addSublayer(frontShade)
        doorBack.addSublayer(backShade)

        led.frame = CGRect(x: FridgeArt.ledRect.minX, y: FridgeArt.ledRect.midY - 11, width: FridgeArt.ledRect.width, height: 22)
        led.alignmentMode = .center
        led.font = "Menlo-Bold" as CFString
        led.fontSize = 17
        led.foregroundColor = Art.hex(0x6BF2E0)
        led.string = "4.0°C"
        doorFront.insertSublayer(led, below: frontShade)
        // The retro door artwork has no display, so the optional readout stays off.
        led.isHidden = true

        // Hinge plates straddle the door's left edge and stay put when the door swings.
        let hingeX = Geo.hinge.x - FridgeArt.hingeSize.width * 0.4
        hingeTop.frame = CGRect(x: hingeX, y: Geo.hingePlateY[0], width: FridgeArt.hingeSize.width, height: FridgeArt.hingeSize.height)
        hingeBottom.frame = CGRect(x: hingeX, y: Geo.hingePlateY[1], width: FridgeArt.hingeSize.width, height: FridgeArt.hingeSize.height)
        // Hinges sit in front of the door's front face so the depth test never hides them.
        for hinge in [hingeTop, hingeBottom] {
            hinge.zPosition = Geo.doorHalfThickness * 2 + 2
            scene.addSublayer(hinge)
        }

        fogHost.frame = CGRect(origin: .zero, size: Geo.windowSize)
        root.addSublayer(fogHost)
    }

    /// Door bins as real 3D trays standing out of the liner: a floor that sticks out toward the
    /// cabinet and a clear front lip. They live in the door's transform layer, so they swing with it
    /// and the depth test tucks them inside the cabinet when the door is shut.
    private func buildDoorBins() {
        let linerZ = -Geo.doorHalfThickness
        let width = Geo.doorSize.width - 2 * Geo.binInset
        let midX = Geo.doorSize.width / 2
        for (index, y) in Geo.binY.enumerated() {
            let depth = Geo.binDepth
            let lipHeight = index == 0 ? Geo.binLipHeight + 8 : Geo.binLipHeight   // the bottom bin is the bottle rack

            let floor = CALayer()
            floor.bounds = CGRect(x: 0, y: 0, width: width, height: depth)
            floor.position = CGPoint(x: midX, y: y)
            floor.zPosition = linerZ - depth / 2
            floor.transform = CATransform3DMakeRotation(.pi / 2, 1, 0, 0)
            floor.backgroundColor = Art.color(0.86, 0.93, 0.96, 0.95)
            floor.borderColor = Art.color(1, 1, 1, 0.8)
            floor.borderWidth = 1
            floor.isDoubleSided = true
            doorRoot.addSublayer(floor)

            let lip = CAGradientLayer()
            lip.bounds = CGRect(x: 0, y: 0, width: width, height: lipHeight)
            lip.position = CGPoint(x: midX, y: y + lipHeight / 2)
            lip.zPosition = linerZ - depth
            lip.transform = CATransform3DMakeRotation(.pi, 0, 1, 0)
            lip.colors = [Art.color(0.97, 0.99, 1, 0.96), Art.color(0.80, 0.90, 0.95, 0.90), Art.color(0.66, 0.80, 0.88, 0.92)]
            lip.locations = [0, 0.55, 1]
            lip.cornerRadius = 3
            lip.borderColor = Art.color(1, 1, 1, 0.9)
            lip.borderWidth = 1
            lip.isDoubleSided = true
            doorRoot.addSublayer(lip)

            // Side cheeks close the tray at both ends.
            for x in [Geo.binInset, Geo.doorSize.width - Geo.binInset] {
                let cheek = CALayer()
                cheek.bounds = CGRect(x: 0, y: 0, width: depth, height: lipHeight)
                cheek.position = CGPoint(x: x, y: y + lipHeight / 2)
                cheek.zPosition = linerZ - depth / 2
                cheek.transform = CATransform3DMakeRotation(.pi / 2, 0, 1, 0)
                cheek.backgroundColor = Art.color(0.78, 0.88, 0.93, 0.92)
                cheek.isDoubleSided = true
                doorRoot.addSublayer(cheek)
            }
        }
    }

    private func renderArt(scale: CGFloat) {
        guard scale != artScale else { return }
        artScale = scale
        cabinet.contents = FridgeArt.cabinet(scale: scale)
        interior.contents = InteriorArt.interior(scale: scale)
        frost.contents = InteriorArt.frost(scale: scale)
        doorFront.contents = FridgeArt.doorFront(scale: scale)
        doorBack.contents = FridgeArt.doorBack(scale: scale)
        let hingeImage = FridgeArt.hinge(scale: scale)
        hingeTop.contents = hingeImage
        hingeBottom.contents = hingeImage
        contactShadow.contents = FridgeArt.contactShadow(scale: scale)
        liftShadow.contents = FridgeArt.liftShadow(scale: scale)

        let all: [CALayer] = [cabinet, interior, frost, doorFront, doorBack, hingeTop, hingeBottom,
                              contactShadow, liftShadow, led, items.layer]
        for l in all { l.contentsScale = scale }
        items.setScale(scale)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let scale = window?.backingScaleFactor { renderArt(scale: scale * userScale) }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateLighting()
        applyDoor(angle: driver.angle)
    }

    /// Dark mode: brighter inside, deeper cyan. Light mode: softer, less saturated.
    private func updateLighting() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if dark {
            glow.colors = [Art.color(0.08, 0.80, 1.0, 0.46), Art.color(0.08, 0.80, 1.0, 0)]
            darknessPeak = 0.48
            frost.opacity = 0.95
        } else {
            glow.colors = [Art.color(0.55, 0.85, 0.96, 0.28), Art.color(0.55, 0.85, 0.96, 0)]
            darknessPeak = 0.60
            frost.opacity = 0.80
        }
    }

    // MARK: Door rendering and events

    private func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = min(max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }

    private func applyDoor(angle: Double) {
        let c = cos(angle)
        let light = smoothstep(3 * Double.pi / 180, 28 * Double.pi / 180, angle)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        doorRoot.transform = CATransform3DMakeRotation(-CGFloat(angle), 0, 1, 0)
        frontShade.opacity = Float(max(0, 1 - c) * 0.40)
        // The liner faces the lit interior, so it only darkens a little while it is edge-on.
        backShade.opacity = Float(max(0, 1 + c) * 0.12)
        darkness.opacity = Float(Double(darknessPeak) * (1 - light))
        glow.opacity = Float(light)
        CATransaction.commit()

        if !hasOpened && angle > Geo.openedAngle {
            hasOpened = true
            doorOpened()
        } else if hasOpened && angle < Geo.sealedAngle {
            hasOpened = false
            doorSealed()
        }

        if !itemsInteractive && angle >= Geo.interactiveOnAngle {
            itemsInteractive = true
            items.interactive = true
        } else if itemsInteractive && angle < Geo.interactiveOffAngle {
            itemsInteractive = false
            items.interactive = false
        }
    }

    private func doorOpened() {
        sounds.playOpen()
        led.string = String(format: "%.1f°C", Double(Int.random(in: 28...46)) / 10)
        items.applyFrost(now: Date(), timeScale: timeScale)
        // The plume is a short frame swap run by the render server, so it stays on in Low Power
        // Mode at half the frame count. Reduce Motion turns it off.
        if !reduceMotion {
            fog.play(scale: artScale, lite: lowPowerMode)
        }
    }

    private func doorSealed() {
        sounds.playSeal()
    }

    private func doorDidRest() {
        // The display link is already gone. Nothing runs until the next input event.
    }

    // MARK: Pause and resume (lock, sleep)

    func pauseEverything() {
        driver.suspend()
        fog.cancel()
        sounds.stopAll()
    }

    func resumeEverything() {
        driver.resume()
    }

    // MARK: Mouse

    override var acceptsFirstResponder: Bool { return true }
    override var mouseDownCanMoveWindow: Bool { return false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { return true }

    private func scenePoint(_ event: NSEvent) -> CGPoint {
        return Geo.scenePoint(fromView: convert(event.locationInWindow, from: nil))
    }

    private func openingPoint(_ scenePoint: CGPoint) -> CGPoint {
        return CGPoint(x: scenePoint.x - Geo.opening.minX, y: scenePoint.y - Geo.opening.minY)
    }

    /// Swing-open angle used by double-click and by files hovering over a closed fridge.
    private static let swingOpenAngle = 96.0 * Double.pi / 180

    /// ⌥ drag resizes the fridge, ⌥⌘ drag moves it. A plain drag only ever works the door.
    private enum Gesture { case none, resize, move }

    private func gesture(for flags: NSEvent.ModifierFlags) -> Gesture {
        let f = flags.intersection(.deviceIndependentFlagsMask)
        if f.contains(.option) && f.contains(.command) { return .move }
        if f.contains(.option) { return .resize }
        return .none
    }

    private func isOnFridge(_ s: CGPoint) -> Bool {
        return Geo.contains(Geo.doorQuad(angle: driver.angle), s)
            || CGRect(origin: .zero, size: Geo.bodySize).contains(s)
    }

    override func mouseDown(with event: NSEvent) {
        let s = scenePoint(event)
        let angle = driver.angle

        switch gesture(for: event.modifierFlags) {
        case .move where isOnFridge(s):
            beginWindowDrag()
            NSCursor.closedHand.set()
            return
        case .resize where isOnFridge(s):
            interaction = .resize(startMouse: NSEvent.mouseLocation, startScale: userScale)
            return
        default:
            break
        }

        if Geo.contains(Geo.doorQuad(angle: angle), s) {
            if event.clickCount == 2 {
                toggleDoor()
                interaction = .none
                return
            }
            // Grabbing right by the hinge would give absurd leverage; hold no closer than this.
            let doorX = max(70, Geo.doorX(underSceneX: s.x, angle: angle))
            interaction = .doorPress(doorX: doorX, start: NSEvent.mouseLocation)
            NSCursor.closedHand.set()
            return
        }
        if items.interactive, let entry = items.hit(at: openingPoint(s)) {
            if event.clickCount == 2 {
                // Double-click opens it, like Finder. Taking it out is Put Back in the right-click menu.
                NSWorkspace.shared.open(store.url(for: entry))
                interaction = .none
            } else {
                interaction = .item(entry: entry, start: event.locationInWindow)
            }
            return
        }
    }

    override func mouseDragged(with event: NSEvent) {
        switch interaction {
        case .doorPress(let doorX, let start):
            let m = NSEvent.mouseLocation
            guard hypot(m.x - start.x, m.y - start.y) > 3 else { return }
            interaction = .door(doorX: doorX)
            driver.hold(at: driver.angle)
            mouseDragged(with: event)

        case .resize(let startMouse, let startScale):
            // Drag up or right to grow, down or left to shrink. The feet stay planted.
            let m = NSEvent.mouseLocation
            let d = (m.y - startMouse.y) + (m.x - startMouse.x) * 0.5
            setUserScale(startScale * exp(d / 320), rerender: false)

        case .door(let doorX):
            let s = scenePoint(event)
            let target = Geo.angle(forDoorX: doorX, atSceneX: s.x, maxAngle: driver.maxAngle)
            driver.hold(at: target)

        case .window(let startMouse, let startOrigin):
            guard let window = window else { return }
            let m = NSEvent.mouseLocation
            window.setFrameOrigin(NSPoint(x: startOrigin.x + (m.x - startMouse.x), y: startOrigin.y + (m.y - startMouse.y)))

        case .item(let entry, let start):
            let dx = event.locationInWindow.x - start.x
            let dy = event.locationInWindow.y - start.y
            if hypot(dx, dy) > 4 {
                interaction = .none
                beginItemDrag(entry, event: event)
            }

        case .none:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        switch interaction {
        case .door:
            driver.release()   // the door keeps the momentum the hand gave it
            NSCursor.openHand.set()
        case .doorPress:
            NSCursor.openHand.set()
        case .resize:
            setUserScale(userScale, rerender: true)   // crisp bitmaps at the new size
            UserDefaults.standard.set(Double(userScale), forKey: "fridgeScale")
            if let origin = window?.frame.origin {
                UserDefaults.standard.set(NSStringFromPoint(origin), forKey: "windowOrigin")
            }
        case .window:
            setLifted(false)
            if let origin = window?.frame.origin {
                UserDefaults.standard.set(NSStringFromPoint(origin), forKey: "windowOrigin")
            }
        default:
            break
        }
        interaction = .none
    }

    private func toggleDoor() {
        driver.swing(to: driver.angle > 30 * Double.pi / 180 ? 0 : FridgeView.swingOpenAngle)
    }

    // MARK: Cursor: an open hand over the door says "you can pull this"

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        guard case .none = interaction else { return }
        let s = scenePoint(event)
        switch gesture(for: event.modifierFlags) {
        case .move where isOnFridge(s):
            NSCursor.openHand.set()
        case .resize where isOnFridge(s):
            resizeCursor.set()
        default:
            let overDoor = Geo.contains(Geo.doorQuad(angle: driver.angle), s)
            (overDoor ? NSCursor.openHand : NSCursor.arrow).set()
        }
    }

    private var resizeCursor: NSCursor {
        if #available(macOS 15.0, *) {
            return NSCursor.frameResize(position: .topRight, directions: .all)
        }
        return NSCursor.resizeUpDown
    }

    // MARK: Size (⌥ drag)

    /// How big the fridge is drawn, relative to its design size. Saved between launches.
    private(set) var userScale: CGFloat = {
        let saved = UserDefaults.standard.double(forKey: "fridgeScale")
        return saved > 0 ? CGFloat(saved) : 1
    }()

    static let scaleRange: ClosedRange<CGFloat> = 0.45...1.6

    /// Resizes the window around the fridge's feet. The view keeps its design-size bounds, so all
    /// geometry and hit testing stay in design points and AppKit scales the result.
    /// `rerender` redraws the art at the new pixel density (skipped mid-drag to keep it smooth).
    /// `windowScale` is the scale the window currently has (defaults to `userScale`).
    /// `keepOrigin` leaves the window's origin alone, for restoring a saved position at launch.
    func setUserScale(_ newScale: CGFloat, rerender: Bool, windowScale: CGFloat? = nil, keepOrigin: Bool = false) {
        guard let window = window else { return }
        let old = windowScale ?? userScale
        let s = min(max(newScale, FridgeView.scaleRange.lowerBound), FridgeView.scaleRange.upperBound)
        userScale = s

        let feet = CGPoint(x: Geo.bodyOrigin.x + Geo.bodySize.width / 2, y: Geo.bodyOrigin.y)
        let planted = NSPoint(x: window.frame.minX + feet.x * old, y: window.frame.minY + feet.y * old)
        let size = NSSize(width: (Geo.windowSize.width * s).rounded(), height: (Geo.windowSize.height * s).rounded())
        let origin = keepOrigin
            ? window.frame.origin
            : NSPoint(x: (planted.x - feet.x * s).rounded(), y: (planted.y - feet.y * s).rounded())
        window.setFrame(NSRect(origin: origin, size: size), display: true)
        setFrameSize(size)
        setBoundsSize(Geo.windowSize)

        if rerender {
            renderArt(scale: window.backingScaleFactor * s)
        }
    }

    override func mouseExited(with event: NSEvent) {
        if case .none = interaction { NSCursor.arrow.set() }
    }

    private func beginWindowDrag() {
        guard let window = window else { return }
        interaction = .window(startMouse: NSEvent.mouseLocation, startOrigin: window.frame.origin)
        setLifted(true)
    }

    /// Lift shadow while the whole fridge is dragged around the desktop.
    private func setLifted(_ lifted: Bool) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.15)
        liftShadow.opacity = lifted ? 1 : 0
        scene.transform = lifted ? CATransform3DMakeTranslation(0, 4, 0) : CATransform3DIdentity
        CATransaction.commit()
    }

    // MARK: Menu

    override func rightMouseDown(with event: NSEvent) {
        let s = scenePoint(event)
        let menu = NSMenu()
        if items.interactive, let entry = items.hit(at: openingPoint(s)) {
            menu.addItem(ActionMenuItem("Open") { [weak self] in
                guard let self = self else { return }
                NSWorkspace.shared.open(self.store.url(for: entry))
            })
            menu.addItem(ActionMenuItem("Put Back") { [weak self] in self?.putBack(entry) })
            menu.addItem(ActionMenuItem("Show in Finder") { [weak self] in
                guard let self = self else { return }
                NSWorkspace.shared.activateFileViewerSelecting([self.store.url(for: entry)])
            })
            menu.addItem(.separator())
        }
        menu.addItem(ActionMenuItem("Open Fridge Folder") { [weak self] in
            guard let self = self else { return }
            NSWorkspace.shared.open(self.store.root)
        })
        menu.addItem(ActionMenuItem("Quit Desktop Fridge") { NSApp.terminate(nil) })
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    // MARK: Taking items out

    private func putBack(_ entry: FridgeEntry) {
        do {
            let result = try store.restore(entry)
            items.remove(id: entry.id)
            if let position = result.desktopPosition {
                finder.setDesktopPosition(ofItemNamed: result.destination.lastPathComponent, x: position.x, y: position.y)
            }
        } catch {
            items.remove(id: entry.id)
        }
    }

    private func beginItemDrag(_ entry: FridgeEntry, event: NSEvent) {
        let url = store.url(for: entry)
        guard FileManager.default.fileExists(atPath: url.path),
              let sceneRect = items.sceneFrame(of: entry.id) else { return }

        let frame = sceneRect.offsetBy(dx: Geo.bodyOrigin.x, dy: Geo.bodyOrigin.y)
        let dragItem = NSDraggingItem(pasteboardWriter: url as NSURL)
        dragItem.setDraggingFrame(frame, contents: NSWorkspace.shared.icon(forFile: url.path))

        draggingEntry = entry
        let session = beginDraggingSession(with: [dragItem], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        switch context {
        case .outsideApplication: return [.move, .copy]
        case .withinApplication: return []
        @unknown default: return []
        }
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        guard let entry = draggingEntry else { return }
        items.setDragging(entry.id, true)
        driver.setItemDrag(true)   // the door now refuses to close
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        driver.setItemDrag(false)
        guard let entry = draggingEntry else { return }
        draggingEntry = nil
        items.setDragging(entry.id, false)
        if operation.isEmpty { return }
        // The receiving app moves the file. Check now, and again shortly after in case it is slow.
        for delay in [0.05, 1.0, 3.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.forgetIfGone(entry)
            }
        }
    }

    private func forgetIfGone(_ entry: FridgeEntry) {
        guard store.entry(id: entry.id) != nil else { return }
        if !FileManager.default.fileExists(atPath: store.url(for: entry).path) {
            store.removeEntry(id: entry.id)
            items.remove(id: entry.id)
        }
    }

    // MARK: Putting items in

    private func dropShelf(for sender: NSDraggingInfo) -> Int? {
        let s = Geo.scenePoint(fromView: convert(sender.draggingLocation, from: nil))
        guard items.interactive, !store.isFull, Geo.opening.contains(s) else { return nil }
        return ShelfLayout.shelfNearest(toY: Double(s.y - Geo.opening.minY))
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if (sender.draggingSource as AnyObject?) === self { return [] }
        // Like a spring-loaded folder: a file hovering over the fridge swings the door open,
        // and the door will not close on the user's hand while the file is over it.
        if !items.interactive && !store.isFull {
            driver.swing(to: FridgeView.swingOpenAngle)
        }
        driver.setItemDrag(true)
        return dropShelf(for: sender) == nil ? [] : .move
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if (sender.draggingSource as AnyObject?) === self { return [] }
        return dropShelf(for: sender) == nil ? [] : .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        driver.setItemDrag(false)
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        driver.setItemDrag(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if (sender.draggingSource as AnyObject?) === self { return false }
        guard let shelf = dropShelf(for: sender),
              let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                                options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return false }

        for url in urls {
            finder.desktopPosition(of: url) { [weak self] position in
                guard let self = self else { return }
                do {
                    let entry = try self.store.store(fileAt: url, desktopPosition: position, preferredShelf: shelf)
                    self.items.add(entry)
                } catch {
                    NSSound.beep()
                }
            }
        }
        return true
    }
}

/// Menu item that runs a closure, so menus need no target and action plumbing.
final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) {
        fatalError("not used")
    }

    @objc private func fire() {
        handler()
    }
}
