import AppKit
import QuartzCore
import Quartz

/// The vending machine on the desktop. Layer-hosting: all art is cached in layers, and the display
/// link only runs while something moves.
///
/// How it is used: drop files on the window and each one stands on a shelf. Press the button under
/// a file and it is pushed off the shelf, falls, and lands in the bin. Take it from the bin.
final class VendingView: NSView, NSDraggingSource, QLPreviewPanelDataSource {
    let store: FileStore

    private let rig = CALayer()
    private let shadowLayer = CALayer()
    private let bodyLayer = CALayer()
    private let trayLayer = CALayer()
    /// Holds the file icons. Masked to the window and the bin, so a falling file passes behind
    /// the body between them.
    private let itemsLayer = CALayer()
    private let labelsLayer = CALayer()
    private let buttonsLayer = CALayer()
    /// Outlines showing where dropped files will stand.
    private let ghostsLayer = CALayer()
    /// A file pushed off its shelf falls here, in front of the shelves and buttons.
    private let dropLayer = CALayer()
    private let glassLayer = CALayer()
    private let flapHolder = CALayer()
    private let flapLayer = CALayer()
    private let displayLayer = CALayer()
    private let nameTag = CATextLayer()
    private var labelLayers: [CALayer] = []
    private var buttonLayers: [CALayer] = []
    private var ghostLayers: [CAShapeLayer] = []
    private var buttonImages: [VendingArt.ButtonState: CGImage] = [:]
    private var itemLayers: [String: CALayer] = [:]
    private var renderedScale: CGFloat = 0
    private var displayText = ""
    private var idleWork: DispatchWorkItem?

    /// Files whose layers a motion is moving right now; layout leaves them alone.
    private var moving = Set<String>()
    /// A file is being pushed or is falling; the buttons wait.
    private var vending = false
    /// The file being pushed toward the shelf edge. Its name and button stay until it falls.
    private var pushing: (slot: Int, name: String)?
    /// The slot under the pointer, and the button held down.
    private var hovered: Int?
    private var pressedButton: Int?
    private var selectedName: String?

    /// The bin flap: how far it has swung out (radians) and how fast.
    private var flapAngle = 0.0
    private var flapSpeed = 0.0
    private var flapMoving = false

    // MARK: Motion

    /// Something that moves for a while. `step` returns true when it has finished.
    private final class Motion {
        let step: (Double) -> Bool
        init(_ step: @escaping (Double) -> Bool) { self.step = step }
    }
    private var motions: [Motion] = []
    private var link: CADisplayLink?
    private var lastTick: CFTimeInterval = 0
    /// Lock or sleep: everything holds still where it is until it ends.
    private var paused = false

    /// What the mouse is holding.
    private enum Grab { case none, button(Int), item(StoredItem, CGRect), move(start: CGPoint, origin: CGPoint), resize(start: CGPoint, scale: CGFloat) }
    private var grab = Grab.none
    private var downPoint = CGPoint.zero
    private var dragged = false

    // MARK: Size

    /// Option-drag makes the machine bigger or smaller. Everything is laid out at scale 1 and the
    /// whole drawing is scaled; mouse points are scaled back with `scene`.
    private(set) var userScale: CGFloat = 1
    private static let scaleRange: ClosedRange<CGFloat> = 0.6...1.6
    static var savedScale: CGFloat {
        let v = UserDefaults.standard.double(forKey: "scale")
        return v == 0 ? 1 : min(max(CGFloat(v), scaleRange.lowerBound), scaleRange.upperBound)
    }

    private func scene(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x / userScale, y: p.y / userScale) }
    private func viewRect(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX * userScale, y: r.minY * userScale, width: r.width * userScale, height: r.height * userScale)
    }

    init(store: FileStore) {
        self.store = store
        let scale = VendingView.savedScale
        super.init(frame: CGRect(origin: .zero, size: CGSize(width: Geo.size.width * scale, height: Geo.size.height * scale)))
        userScale = scale
        layer = CALayer()
        wantsLayer = true
        buildLayers()
        registerForDraggedTypes([.fileURL])
        displayText = idleText
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Vending machine")
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Layers

    private static let still: [String: CAAction] = ["position": NSNull(), "bounds": NSNull(), "transform": NSNull(),
                                                     "opacity": NSNull(), "contents": NSNull(), "hidden": NSNull(),
                                                     "sublayers": NSNull(), "frame": NSNull(), "contentsRect": NSNull(),
                                                     "backgroundColor": NSNull(), "path": NSNull()]

    private func buildLayers() {
        guard let root = layer else { return }
        let full = CGRect(origin: .zero, size: Geo.size)
        rig.anchorPoint = .zero
        rig.bounds = full
        rig.position = .zero
        root.addSublayer(rig)

        for l in [shadowLayer, bodyLayer] {
            l.frame = full
            rig.addSublayer(l)
        }
        trayLayer.frame = Geo.tray
        rig.addSublayer(trayLayer)
        for l in [itemsLayer, labelsLayer, buttonsLayer, ghostsLayer, dropLayer] {
            l.frame = full
            rig.addSublayer(l)
        }

        // Files show only through the window and the bin opening.
        let openings = CGMutablePath()
        openings.addPath(Paint.rounded(Geo.glass, 15))
        openings.addPath(Paint.rounded(Geo.tray, 14))
        var perspective = CATransform3DIdentity
        perspective.m34 = -1 / 600
        for l in [itemsLayer, dropLayer] {
            let mask = CAShapeLayer()
            mask.path = openings
            l.mask = mask
            l.sublayerTransform = perspective
        }

        for i in 0..<Geo.slotCount {
            let label = CALayer()
            label.frame = Geo.labelRect(i)
            labelsLayer.addSublayer(label)
            labelLayers.append(label)

            let button = CALayer()
            button.frame = Geo.buttonRect(i)
            buttonsLayer.addSublayer(button)
            buttonLayers.append(button)

            let ghost = CAShapeLayer()
            ghost.path = Paint.rounded(Geo.slotRect(i), 10)
            ghost.fillColor = Paint.hex(0xFFFFFF, 0.28)
            ghost.strokeColor = Paint.hex(0xE8401E, 0.8)
            ghost.lineWidth = 1.5
            ghost.lineDashPattern = [5, 3]
            ghost.isHidden = true
            ghostsLayer.addSublayer(ghost)
            ghostLayers.append(ghost)
        }

        glassLayer.frame = Geo.glass
        rig.addSublayer(glassLayer)

        // The flap hangs from its top edge and swings out toward you.
        flapHolder.frame = full
        flapHolder.sublayerTransform = perspective
        flapLayer.anchorPoint = CGPoint(x: 0.5, y: 1)
        flapLayer.bounds = CGRect(origin: .zero, size: Geo.tray.size)
        flapLayer.position = CGPoint(x: Geo.tray.midX, y: Geo.tray.maxY)
        flapHolder.addSublayer(flapLayer)
        rig.addSublayer(flapHolder)

        displayLayer.frame = Geo.display
        rig.addSublayer(displayLayer)

        for l in [rig, shadowLayer, bodyLayer, trayLayer, itemsLayer, labelsLayer, buttonsLayer, ghostsLayer, dropLayer,
                  glassLayer, flapHolder, flapLayer, displayLayer] + labelLayers + buttonLayers + ghostLayers {
            l.actions = Self.still
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        renderArt()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
        renderArt()
    }

    /// Resizes around the bottom middle, so the machine stays standing where it was.
    private func applyScale(_ s: CGFloat) {
        guard let window else { return }
        userScale = min(max(s, Self.scaleRange.lowerBound), Self.scaleRange.upperBound)
        let old = window.frame
        let size = CGSize(width: Geo.size.width * userScale, height: Geo.size.height * userScale)
        applyTransforms()
        window.setFrame(CGRect(origin: CGPoint(x: old.midX - size.width / 2, y: old.minY), size: size), display: true)
        setFrameSize(size)
    }

    private func applyTransforms() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        rig.setAffineTransform(CGAffineTransform(scaleX: userScale, y: userScale))
        CATransaction.commit()
    }

    private func renderArt() {
        applyTransforms()
        let scale = (window?.backingScaleFactor ?? 2) * max(1, userScale)
        guard scale != renderedScale else { return }
        renderedScale = scale
        CATransaction.begin(); CATransaction.setDisableActions(true)
        // Painted art in Resources/Art wins; otherwise the art drawn in code.
        shadowLayer.contents = ArtFiles.image("shadow") ?? VendingArt.shadow(scale: scale)
        bodyLayer.contents = ArtFiles.image("body") ?? VendingArt.body(scale: scale)
        trayLayer.contents = ArtFiles.image("bin") ?? VendingArt.tray(scale: scale)
        glassLayer.contents = ArtFiles.image("glass") ?? VendingArt.glass(scale: scale)
        flapLayer.contents = ArtFiles.image("flap") ?? VendingArt.flap(scale: scale)
        let names: [VendingArt.ButtonState: String] = [.empty: "button-empty", .ready: "button", .hover: "button-hover", .pressed: "button-pressed"]
        for state in VendingArt.ButtonState.allCases {
            buttonImages[state] = ArtFiles.image(names[state]!) ?? VendingArt.button(state, scale: scale)
        }
        for l in [rig, shadowLayer, bodyLayer, trayLayer, itemsLayer, labelsLayer, buttonsLayer, ghostsLayer, dropLayer,
                  glassLayer, flapHolder, flapLayer, displayLayer] + labelLayers + buttonLayers {
            l.contentsScale = scale
        }
        for l in itemLayers.values { l.contentsScale = scale }
        CATransaction.commit()
        layoutItems()
        showDisplay(displayText)
    }

    // MARK: Files on the shelves and in the bin

    /// Puts each file's icon on its shelf or in the bin. Files that are moving are left alone.
    func layoutItems(animated: Bool = false) {
        let tray = store.trayItems
        CATransaction.begin(); CATransaction.setDisableActions(true)
        var keep = Set<String>()
        for item in store.items {
            keep.insert(item.name)
            let l = itemLayers[item.name] ?? makeItemLayer(item)
            itemLayers[item.name] = l
            if l.superlayer == nil { itemsLayer.addSublayer(l) }
            guard !moving.contains(item.name) else { continue }
            if let slot = item.slot, let i = Geo.index(of: slot) {
                place(l, in: Geo.iconRect(i), pose: Pose(scale: hovered == i ? 1.06 : 1))
            } else if let n = tray.firstIndex(of: item) {
                let before = l.position
                place(l, in: Geo.traySpot(n, of: tray.count), pose: Self.trayPose(item.name))
                if animated && before != l.position && before != .zero {
                    // The others in the bin shuffle along to make room.
                    let slide = CABasicAnimation(keyPath: "position")
                    slide.fromValue = NSValue(point: before)
                    slide.duration = 0.22
                    slide.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    l.add(slide, forKey: "slide")
                }
            }
        }
        for (name, l) in itemLayers where !keep.contains(name) {
            l.removeFromSuperlayer()
            itemLayers[name] = nil
            moving.remove(name)
        }
        CATransaction.commit()
        refreshShelves()
    }

    private func makeItemLayer(_ item: StoredItem) -> CALayer {
        let l = CALayer()
        l.actions = Self.still
        l.anchorPoint = CGPoint(x: 0.5, y: 0)
        l.bounds = CGRect(x: 0, y: 0, width: Geo.iconSize, height: Geo.iconSize)
        l.contentsGravity = .resizeAspect
        l.contentsScale = renderedScale
        l.cornerRadius = 8
        let icon = NSWorkspace.shared.icon(forFile: store.url(of: item).path)
        var rect = CGRect(x: 0, y: 0, width: 128, height: 128)
        l.contents = icon.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        // A soft contact shadow where it stands, rather than a floating drop shadow.
        let s = Geo.iconSize
        l.shadowPath = CGPath(ellipseIn: CGRect(x: s * 0.14, y: -2.5, width: s * 0.76, height: 6), transform: nil)
        l.shadowOpacity = 0.38
        l.shadowRadius = 2.4
        l.shadowOffset = CGSize(width: 1, height: 0)
        l.shadowColor = Paint.hex(0x2A2116)
        return l
    }

    /// How an icon sits: `tip` leans its top toward you (radians), `tilt` turns it in the picture.
    struct Pose { var scale: CGFloat = 1; var tip: CGFloat = 0; var tilt: CGFloat = 0 }

    /// Places a layer by the bottom middle of `rect`, in the given pose.
    private func place(_ l: CALayer, in rect: CGRect, pose: Pose = Pose()) {
        l.position = CGPoint(x: rect.midX, y: rect.minY)
        var t = CATransform3DMakeScale(pose.scale, pose.scale, 1)
        t = CATransform3DRotate(t, pose.tilt, 0, 0, 1)
        t = CATransform3DRotate(t, pose.tip, 1, 0, 0)
        l.transform = t
    }

    /// Files in the bin lie a little crooked, each its own way.
    private static func trayPose(_ name: String) -> Pose {
        let h = name.utf8.reduce(5381) { ($0 &* 33) &+ Int($1) }
        return Pose(scale: Geo.trayIcon / Geo.iconSize, tip: 0.22, tilt: CGFloat(abs(h) % 17 - 8) * 0.014)
    }

    /// Names on the shelf fronts, and each button lit if there is something to get.
    private func refreshShelves() {
        let scale = renderedScale == 0 ? 2 : renderedScale
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for i in 0..<Geo.slotCount {
            let item = store.item(in: Geo.code(i))
            let name = pushing?.slot == i ? pushing?.name : item.flatMap { moving.contains($0.name) ? nil : $0.name }
            labelLayers[i].contents = VendingArt.label(name: name, scale: scale)
            let state: VendingArt.ButtonState = pressedButton == i || pushing?.slot == i ? .pressed
                : name == nil ? .empty : (hovered == i && !vending ? .hover : .ready)
            buttonLayers[i].contents = buttonImages[state]
        }
        CATransaction.commit()
    }

    // MARK: Moving things

    private func run(_ step: @escaping (Double) -> Bool) {
        motions.append(Motion(step))
        startTicking()
    }

    private func startTicking() {
        guard link == nil, !paused, !motions.isEmpty else { return }
        let l = displayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
        lastTick = 0
    }

    @objc private func tick(_ l: CADisplayLink) {
        var dt = lastTick == 0 ? 1.0 / 60 : min(0.05, l.timestamp - lastTick)
        lastTick = l.timestamp
        #if DEBUG
        dt *= Self.slowMotion
        #endif
        CATransaction.begin(); CATransaction.setDisableActions(true)
        // A motion may start another one (a landing knocks the flap), so step a copy.
        let finished = Set(motions.filter { $0.step(dt) }.map(ObjectIdentifier.init))
        motions.removeAll { finished.contains(ObjectIdentifier($0)) }
        CATransaction.commit()
        if motions.isEmpty {
            l.invalidate()
            link = nil
        }
    }

    /// Lock or sleep: freeze exactly where things are.
    func pause() {
        paused = true
        link?.invalidate()
        link = nil
    }

    func resume() {
        paused = false
        startTicking()
    }

    static func easeInOut(_ t: Double) -> Double {
        let x = min(max(t, 0), 1)
        return x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
    }

    static func easeIn(_ t: Double) -> Double { let x = min(max(t, 0), 1); return x * x * x }

    // MARK: Putting files in

    /// Moves files onto free shelf spots. A full machine rattles its glass and says so.
    func storeFiles(_ urls: [URL]) {
        let room = store.freeSlots.count
        guard room > 0 else { refuseFull(); return }
        store.store(Array(urls.prefix(room))) { [weak self] added in
            guard let self else { return }
            self.moving.formUnion(added.map(\.name))
            self.layoutItems()
            for (n, item) in added.enumerated() { self.setDown(item, delay: Double(n) * 0.09) }
            if let last = added.last { self.say(added.count == 1 ? Self.displayName(last.name) : "\(added.count) FILES IN") }
            if urls.count > room { DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.refuseFull() } }
        }
    }

    /// A new file drops onto its shelf from just above, with a small bounce.
    private func setDown(_ item: StoredItem, delay: Double) {
        guard let slot = item.slot, let i = Geo.index(of: slot), let l = itemLayers[item.name] else { return }
        let rest = Geo.iconRect(i), duration = 0.42
        l.opacity = 0
        var t = -delay
        run { [weak self] dt in
            guard let self else { return true }
            t += dt
            guard t >= 0 else { return false }
            if t - dt < 0 { Sounds.play(.plop, volume: 0.35) }
            let u = min(1, t / duration)
            // Falls 16 points, lands, hops a little, settles.
            let y: Double = u < 0.55 ? 16 * (1 - pow(u / 0.55, 2)) : 3 * sin(Double.pi * (u - 0.55) / 0.45)
            l.opacity = Float(min(1, u / 0.25))
            let squash = u > 0.5 && u < 0.7 ? 1 - 0.06 * sin(Double.pi * (u - 0.5) / 0.2) : 1
            var pose = Pose(scale: 1)
            pose.scale = CGFloat(squash)
            self.place(l, in: rest.offsetBy(dx: 0, dy: CGFloat(y)), pose: pose)
            if u >= 1 {
                self.moving.remove(item.name)
                self.refreshShelves()
                return true
            }
            return false
        }
    }

    private func refuseFull() {
        let shake = CAKeyframeAnimation(keyPath: "position.x")
        shake.values = [0, -2.5, 2.5, -2, 1.5, -0.8, 0].map { NSNumber(value: $0) }
        shake.isAdditive = true
        shake.duration = 0.38
        glassLayer.add(shake, forKey: "full")
        let rattle = shake.copy() as! CAKeyframeAnimation
        rattle.values = [0, -0.8, 0.8, -0.5, 0.3, 0].map { NSNumber(value: $0) }
        rig.add(rattle, forKey: "full")
        Sounds.play(.rattle, volume: 0.4)
        say("SOLD OUT")
    }

    // MARK: Vending

    /// The button under a file: it goes in, and the file is pushed off its shelf.
    func pressButton(_ i: Int) {
        guard !vending else { return }
        vend(Geo.code(i))
    }

    /// The heart of it: the file is pushed forward until it tips off the shelf, falls, lands in
    /// the bin with a knock and a bounce, and the flap swings and settles.
    func vend(_ code: String) {
        guard !vending, let i = Geo.index(of: code) else { return }
        guard let waiting = store.item(in: code), itemLayers[waiting.name] != nil else {
            Sounds.play(.error, volume: 0.25)
            say("EMPTY")
            return
        }
        guard let item = store.vend(code), let l = itemLayers[item.name] else {
            Sounds.play(.error, volume: 0.25)
            say("EMPTY")
            return
        }
        select(nil)
        vending = true
        moving.insert(item.name)
        pushing = (i, item.name)
        hovered = nil
        refreshShelves()
        say(Self.displayName(item.name), for: 30)

        let rest = Geo.iconRect(i)
        let tray = store.trayItems
        let spot = Geo.traySpot(tray.firstIndex(of: item) ?? max(0, tray.count - 1), of: tray.count)
        let landing = Self.trayPose(item.name)
        let push = 0.5, gravity = 2400.0, step = 1.0 / 240
        let x0 = Double(rest.midX), floor = Double(spot.minY)
        let top = Double(Geo.glass.minY), bottom = Double(Geo.tray.maxY)
        let drift = Double(landing.tilt) > 0 ? 0.16 : -0.16
        var t = -0.08, leftover = 0.0
        var falling = false, landed = false, bounces = 0
        var y = Double(rest.minY), vy = 0.0, tip = 0.35, tipSpeed = 1.6, fallTime = 0.0

        run { [weak self] dt in
            guard let self else { return true }
            t += dt
            if t < 0 { return false }
            if !falling {
                if t - dt < 0 { Sounds.play(.motorShort, volume: 0.45) }
                // A pusher behind the file slides it forward to the edge of the shelf, where it
                // starts to lean.
                let e = Self.easeIn(t / push)
                let lean = e > 0.6 ? (e - 0.6) / 0.4 * 0.35 : 0
                if e > 0.4 && l.superlayer !== self.dropLayer { self.dropLayer.addSublayer(l) }
                // Coming toward you along the shelf, it also sits a little lower in the picture.
                self.place(l, in: rest.offsetBy(dx: 0, dy: CGFloat(-6 * e)), pose: Pose(scale: CGFloat(1 + 0.16 * e), tip: CGFloat(lean)))
                if t >= push {
                    falling = true
                    y -= 6
                    self.pushing = nil
                    self.refreshShelves()
                    self.layoutItems(animated: true)
                }
                return false
            }

            leftover += dt
            while leftover >= step && !landed {
                leftover -= step
                fallTime += step
                vy -= gravity * step
                y += vy * step
                tip = min(0.85, tip + tipSpeed * step)
                tipSpeed += 2 * step
                if y <= floor {
                    y = floor
                    let impact = -vy
                    if impact > 90 && bounces < 3 {
                        Sounds.play(.thunk, volume: Float(min(0.85, 0.15 + impact / 1800)))
                        self.knockFlap(impact * 0.0021)
                        vy = impact * 0.26
                        bounces += 1
                    } else {
                        vy = 0
                        landed = true
                    }
                }
            }
            // Out of sight between the window and the bin, it slides over to its place in the bin.
            let k = Self.easeInOut((top - y) / (top - bottom))
            let x = x0 + (Double(spot.midX) - x0) * k
            let pose = Pose(scale: CGFloat(1.16 + (Double(landing.scale) - 1.16) * k),
                            tip: CGFloat(tip + (Double(landing.tip) - tip) * k),
                            tilt: CGFloat(drift * min(1, fallTime * 3) * (1 - k) + Double(landing.tilt) * k))
            self.place(l, in: CGRect(x: x - 1, y: y, width: 2, height: 2), pose: pose)
            if landed && !self.flapMoving {
                self.itemsLayer.addSublayer(l)
                self.moving.remove(item.name)
                self.vending = false
                self.layoutItems()
                self.say("TAKE IT BELOW")
                return true
            }
            return false
        }
    }

    /// The flap hangs from its top edge. A knock swings it out; it falls back, taps its frame and settles.
    private func knockFlap(_ speed: Double) {
        flapSpeed += speed
        guard !flapMoving else { return }
        flapMoving = true
        let step = 1.0 / 240
        var leftover = 0.0
        run { [weak self] dt in
            guard let self else { return true }
            leftover += dt
            while leftover >= step {
                leftover -= step
                self.flapSpeed += (-150 * self.flapAngle - 5.5 * self.flapSpeed) * step
                self.flapAngle += self.flapSpeed * step
                if self.flapAngle < 0 {
                    if self.flapSpeed < -0.35 { Sounds.play(.flap, volume: Float(min(0.5, 0.1 - self.flapSpeed * 0.12))) }
                    self.flapAngle = 0
                    self.flapSpeed = self.flapSpeed < -0.25 ? -self.flapSpeed * 0.3 : 0
                }
            }
            self.flapLayer.transform = CATransform3DMakeRotation(-CGFloat(self.flapAngle), 1, 0, 0)
            if self.flapAngle == 0 && self.flapSpeed == 0 {
                self.flapMoving = false
                return true
            }
            return false
        }
    }

    // MARK: Display

    /// What the screen says while nobody is using it.
    private var idleText: String {
        if store.items.contains(where: { $0.slot != nil }) { return "PICK A FILE" }
        return store.trayItems.isEmpty ? "DROP FILES IN" : "TAKE IT BELOW"
    }

    /// The screen shows a message, then goes back to its resting text after a few seconds.
    func say(_ text: String, for seconds: Double = 4) {
        idleWork?.cancel()
        showDisplay(text)
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.vending else { return }
            self.showDisplay(self.hoverText ?? self.idleText)
        }
        idleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// A file name as the screen shows it: without its extension.
    static func displayName(_ name: String) -> String { (name as NSString).deletingPathExtension }

    func showDisplay(_ text: String) {
        displayText = text
        CATransaction.begin(); CATransaction.setDisableActions(true)
        displayLayer.contents = Segments.render(text, scale: renderedScale == 0 ? 2 : renderedScale)
        CATransaction.commit()
    }

    // MARK: Hit testing

    /// The body and its feet. The transparent corners let clicks through to the desktop.
    private func bodyHit(_ p: CGPoint) -> Bool {
        let b = Geo.body
        let shape = Paint.rounded(CGRect(x: b.minX, y: b.minY, width: b.width + Geo.side, height: b.height), Geo.bodyRadius)
        return shape.contains(p) || CGRect(x: b.minX + 30, y: b.minY - 12, width: b.width - 56, height: 14).contains(p)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bodyHit(scene(convert(point, from: superview))) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The button under the pointer, if any.
    private func button(at p: CGPoint) -> Int? {
        (0..<Geo.slotCount).first { Geo.buttonRect($0).insetBy(dx: -5, dy: -5).contains(p) }
    }

    /// The slot the pointer is over: its file, its button or its name.
    private func slot(at p: CGPoint) -> Int? {
        guard Geo.glass.contains(p) else { return nil }
        return (0..<Geo.slotCount).first {
            Geo.slotRect($0).contains(p) || Geo.buttonRect($0).insetBy(dx: -5, dy: -5).contains(p) || Geo.labelRect($0).contains(p)
        }
    }

    /// The file under the pointer: one on a shelf, or one in the bin.
    private func item(at p: CGPoint) -> (item: StoredItem, rect: CGRect)? {
        if Geo.tray.contains(p) {
            let tray = store.trayItems
            // The front-most (last placed) icon wins where they overlap.
            for (n, item) in tray.enumerated().reversed() where !moving.contains(item.name) {
                let r = Geo.traySpot(n, of: tray.count)
                if r.insetBy(dx: -2, dy: -2).contains(p) { return (item, r) }
            }
            return nil
        }
        guard Geo.glass.contains(p) else { return nil }
        for item in store.items where !moving.contains(item.name) {
            if let slot = item.slot, let i = Geo.index(of: slot), Geo.iconRect(i).insetBy(dx: -4, dy: -4).contains(p) {
                return (item, Geo.iconRect(i))
            }
        }
        return nil
    }

    // MARK: Hover

    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    /// The name of the file under the pointer, for the screen.
    private var hoverText: String? {
        guard let i = hovered, let item = store.item(in: Geo.code(i)), !moving.contains(item.name) else { return nil }
        return Self.displayName(item.name)
    }

    /// Pointing at a file or its button lifts the file a touch, brightens its button and puts its
    /// name on the screen.
    private func setHover(_ i: Int?) {
        let target = i.flatMap { store.item(in: Geo.code($0)) != nil ? $0 : nil }
        guard target != hovered else { return }
        hovered = target
        layoutItems()
        guard !vending else { return }
        if let text = hoverText {
            idleWork?.cancel()
            showDisplay(text)
        } else if idleWork == nil || displayText != idleText {
            showDisplay(idleText)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        guard case .none = grab else { return }
        setHover(slot(at: scene(convert(event.locationInWindow, from: nil))))
    }

    override func mouseExited(with event: NSEvent) { setHover(nil) }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        let p = scene(convert(event.locationInWindow, from: nil))
        downPoint = p
        dragged = false
        grab = .none
        // Read the keys held right now as well as the event's, in case another app rewrites them.
        let keys = event.modifierFlags.union(NSEvent.modifierFlags).intersection([.option, .command, .shift, .control])
        if keys == [.option, .command], let window {
            // The system's window drag does not work at desktop level, so the machine follows the mouse itself.
            grab = .move(start: NSEvent.mouseLocation, origin: window.frame.origin)
            NSCursor.closedHand.set()
            return
        }
        if keys == .option {
            grab = .resize(start: NSEvent.mouseLocation, scale: userScale)
            return
        }
        if let b = button(at: p), !vending {
            // The button goes in with the mouse and comes out with it.
            grab = .button(b)
            pressedButton = b
            refreshShelves()
            Sounds.play(.click, volume: 0.35)
        } else if let hit = item(at: p) {
            grab = .item(hit.item, hit.rect)
        } else {
            select(nil)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = scene(convert(event.locationInWindow, from: nil))
        switch grab {
        case .button(let b):
            let inside = button(at: p) == b
            if (pressedButton == b) != inside {
                pressedButton = inside ? b : nil
                refreshShelves()
            }
        case .item(let item, let rect):
            // Files come out only from the bin. On the shelves they wait for their button.
            guard item.inTray, !dragged, hypot(p.x - downPoint.x, p.y - downPoint.y) >= 3 else { return }
            dragged = true
            beginDrag(item, rect: rect, event: event)
        case .move(let start, let origin):
            let m = NSEvent.mouseLocation
            window?.setFrameOrigin(CGPoint(x: origin.x + m.x - start.x, y: origin.y + m.y - start.y))
        case .resize(let start, let scale):
            // Up or right to grow, down or left to shrink.
            let m = NSEvent.mouseLocation
            applyScale(scale + ((m.y - start.y) + (m.x - start.x) * 0.5) / 300)
        case .none:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        let p = scene(convert(event.locationInWindow, from: nil))
        switch grab {
        case .button(let b):
            pressedButton = nil
            refreshShelves()
            if button(at: p) == b { pressButton(b) }
        case .item(let item, _):
            guard !dragged else { break }
            if event.clickCount >= 2 {
                // Two clicks: on a shelf it vends, in the bin it opens.
                if let slot = item.slot { vend(slot) } else { NSWorkspace.shared.open(store.url(of: item)) }
            } else {
                select(item.name)
            }
        case .move:
            NSCursor.arrow.set()
        case .resize:
            UserDefaults.standard.set(Double(userScale), forKey: "scale")
            renderedScale = 0
            renderArt()      // redraw sharp at the new size
        case .none:
            break
        }
        grab = .none
        dragged = false
    }

    // MARK: Selection, names and Quick Look

    private func select(_ name: String?) {
        selectedName = name
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (key, l) in itemLayers { l.backgroundColor = key == name ? Paint.hex(0xFFFFFF, 0.45) : nil }
        CATransaction.commit()
        guard let name, let item = store.items.first(where: { $0.name == name }) else {
            nameTag.isHidden = true
            if QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible { QLPreviewPanel.shared().orderOut(nil) }
            return
        }
        let rect: CGRect
        if let slot = item.slot, let i = Geo.index(of: slot) {
            rect = Geo.iconRect(i)
        } else {
            let tray = store.trayItems
            rect = Geo.traySpot(tray.firstIndex(of: item) ?? 0, of: tray.count)
        }
        showTag(name, above: rect)
        // Take the keyboard so Space can open Quick Look.
        window?.makeKey()
        window?.makeFirstResponder(self)
        if QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible { QLPreviewPanel.shared().reloadData() }
    }

    /// A small tag with the full name, just above the icon.
    private func showTag(_ text: String, above rect: CGRect) {
        if nameTag.superlayer == nil {
            nameTag.actions = ["position": NSNull(), "bounds": NSNull(), "contents": NSNull(), "hidden": NSNull(), "string": NSNull()]
            nameTag.font = NSFont.systemFont(ofSize: 11, weight: .medium)
            nameTag.fontSize = 11
            nameTag.alignmentMode = .center
            nameTag.truncationMode = .middle
            nameTag.foregroundColor = Paint.hex(0x3A2A0E)
            nameTag.backgroundColor = Paint.hex(0xFFFBF0)
            nameTag.cornerRadius = 9
            nameTag.shadowOpacity = 0.3
            nameTag.shadowRadius = 4
            nameTag.shadowOffset = CGSize(width: 0, height: -1.5)
            rig.addSublayer(nameTag)
        }
        nameTag.contentsScale = renderedScale
        let width = min(230, (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium)]).width + 20)
        var x = rect.midX - width / 2
        x = min(max(x, 6), Geo.size.width - width - 6)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        nameTag.string = text
        nameTag.frame = CGRect(x: x, y: rect.maxY + 5, width: width, height: 19)
        nameTag.isHidden = false
        CATransaction.commit()
    }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 49 where selectedName != nil:      // Space
            let panel = QLPreviewPanel.shared()!
            if panel.isVisible { panel.orderOut(nil) } else { panel.makeKeyAndOrderFront(nil) }
        case 53:                                // Escape
            select(nil)
        default:
            super.keyDown(with: event)
        }
    }

    var hasSelection: Bool { selectedName != nil }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = self }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = nil }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { selectedName == nil ? 0 : 1 }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        guard let name = selectedName, let f = store.items.first(where: { $0.name == name }) else { return nil }
        return store.url(of: f) as NSURL
    }

    // MARK: Taking files out of the bin

    private func beginDrag(_ item: StoredItem, rect: CGRect, event: NSEvent) {
        select(nil)
        let url = store.url(of: item)
        let dragItem = NSDraggingItem(pasteboardWriter: url as NSURL)
        dragItem.setDraggingFrame(viewRect(rect), contents: NSWorkspace.shared.icon(forFile: url.path))
        beginDraggingSession(with: [dragItem], event: event, source: self)
        // Your hand pushes the flap on the way out.
        knockFlap(1.8)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.move, .copy, .generic] : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        store.reconcile()
        layoutItems(animated: true)
        if !vending { showDisplay(idleText) }
    }

    // MARK: Menu

    override func menu(for event: NSEvent) -> NSMenu? {
        store.reconcile()
        layoutItems()
        let p = scene(convert(event.locationInWindow, from: nil))
        let menu = NSMenu()
        if let hit = item(at: p) {
            let item = hit.item, url = store.url(of: item)
            if let slot = item.slot {
                let vendItem = ActionItem("Vend") { [weak self] in self?.vend(slot) }
                vendItem.isEnabled = !vending
                menu.addItem(vendItem)
            } else {
                menu.addItem(ActionItem("Open") { NSWorkspace.shared.open(url) })
                menu.addItem(ActionItem("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) })
            }
            menu.addItem(ActionItem("Put Back") { [weak self] in self?.putBack([item]) })
            menu.addItem(.separator())
        }
        let vendMenu = NSMenu()
        let onShelves = store.items.filter { $0.slot != nil }.sorted { ($0.slot ?? "") < ($1.slot ?? "") }
        for item in onShelves {
            guard let slot = item.slot else { continue }
            let entry = ActionItem(item.name) { [weak self] in self?.vend(slot) }
            entry.image = NSWorkspace.shared.icon(forFile: store.url(of: item).path)
            entry.image?.size = NSSize(width: 16, height: 16)
            entry.isEnabled = !vending
            vendMenu.addItem(entry)
        }
        if onShelves.isEmpty {
            let none = NSMenuItem(title: "Nothing inside yet. Drop files on the window.", action: nil, keyEquivalent: "")
            none.isEnabled = false
            vendMenu.addItem(none)
        }
        let vendRoot = NSMenuItem(title: "Vend", action: nil, keyEquivalent: "")
        vendRoot.submenu = vendMenu
        menu.addItem(vendRoot)
        menu.addItem(ActionItem("Open Vending Machine Folder") { [weak self] in
            guard let self else { return }
            NSWorkspace.shared.open(self.store.folder)
        })
        let all = ActionItem("Put Back All") { [weak self] in
            guard let self else { return }
            self.putBack(self.store.items)
        }
        all.isEnabled = !store.items.isEmpty
        menu.addItem(all)
        let sound = ActionItem("Sound") { Sounds.enabled.toggle() }
        sound.state = Sounds.enabled ? .on : .off
        menu.addItem(sound)
        menu.addItem(.separator())
        let everything = ActionItem("Move Everything to Desktop") { [weak self] in self?.moveEverythingToDesktop() }
        everything.isEnabled = store.items.contains { !$0.name.hasPrefix(".") }
        menu.addItem(everything)
        menu.addItem(ActionItem("Quit Desktop Vending Machine") { NSApp.terminate(nil) })
        return menu
    }

    /// Sends files back where they came from. A file in the middle of falling finishes first.
    private func putBack(_ items: [StoredItem]) {
        select(nil)
        for item in items where !moving.contains(item.name) { store.putBack(item) }
        layoutItems(animated: true)
        idleWork?.cancel()
        showDisplay(idleText)
    }

    /// Asks first, then moves every file in the machine onto the Desktop, with the same
    /// bookkeeping as Put Back. Anything that cannot move stays inside and is counted at the end.
    private func moveEverythingToDesktop() {
        store.reconcile()
        let items = store.items.filter { !$0.name.hasPrefix(".") }
        guard !items.isEmpty else { return }
        let confirm = NSAlert()
        confirm.messageText = "Move everything to your Desktop?"
        confirm.informativeText = (items.count == 1 ? "The file in the vending machine goes back onto your Desktop." : "All \(items.count) files in the vending machine go back onto your Desktop.")
        confirm.addButton(withTitle: "Move to Desktop")
        confirm.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard confirm.runModal() == .alertFirstButtonReturn else { return }
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first ?? FileStore.desktop
        select(nil)
        var failed = 0
        for item in items {
            if moving.contains(item.name) || store.putBack(item, to: desktop) == nil { failed += 1 }
        }
        layoutItems(animated: true)
        idleWork?.cancel()
        showDisplay(idleText)
        guard failed > 0 else { return }
        let problem = NSAlert()
        problem.messageText = failed == 1 ? "1 file could not be moved." : "\(failed) files could not be moved."
        problem.informativeText = "They are still in the vending machine."
        problem.addButton(withTitle: "OK")
        problem.runModal()
    }

    // MARK: Dropping files in

    private func fileURLs(_ info: NSDraggingInfo) -> [URL] {
        (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    /// Only the window takes files. While they hover over it, outlines show where they will stand.
    private func dragOperation(_ info: NSDraggingInfo) -> NSDragOperation {
        let urls = fileURLs(info)
        let over = (info.draggingSource as AnyObject?) !== self && !urls.isEmpty
            && Geo.glass.contains(scene(convert(info.draggingLocation, from: nil)))
        let free = store.freeSlots.compactMap(Geo.index(of:))
        let landing = over ? Array(free.prefix(urls.count)) : []
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (i, ghost) in ghostLayers.enumerated() { ghost.isHidden = !landing.contains(i) }
        CATransaction.commit()
        guard over else {
            if displayText == "SOLD OUT" || displayText.hasPrefix("DROP ") { showDisplay(idleText) }
            return []
        }
        if free.isEmpty {
            if displayText != "SOLD OUT" { showDisplay("SOLD OUT") }
            return []
        }
        idleWork?.cancel()
        let text = urls.count == 1 ? "DROP IT IN" : "DROP \(min(urls.count, free.count)) IN"
        if displayText != text { showDisplay(text) }
        return .move
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { dragOperation(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { dragOperation(sender) }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        hideGhosts()
        if !vending { showDisplay(idleText) }
    }

    private func hideGhosts() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for ghost in ghostLayers { ghost.isHidden = true }
        CATransaction.commit()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        hideGhosts()
        guard Geo.glass.contains(scene(convert(sender.draggingLocation, from: nil))) else { return false }
        storeFiles(fileURLs(sender))
        return true
    }

    #if DEBUG
    /// For test scripts: 0.1 plays every motion ten times slower.
    static var slowMotion = 1.0

    /// For test scripts: put files in as if they were dropped on the window.
    func storeForTest(_ urls: [URL]) { storeFiles(urls) }

    /// For test scripts: resize as an Option-drag would.
    func scaleForTest(_ scale: CGFloat) {
        applyScale(scale)
        renderedScale = 0
        renderArt()
    }

    /// For test scripts: select the n-th file, as a click would.
    func selectForTest(_ n: Int) {
        guard n < store.items.count else { return }
        select(store.items[n].name)
    }

    /// For test scripts: point at a slot, as the mouse would (-1 for none).
    func hoverForTest(_ i: Int) { setHover(i < 0 ? nil : i) }

    /// For test scripts: show the drop outlines for `count` files.
    func ghostsForTest(_ count: Int) {
        let free = store.freeSlots.compactMap(Geo.index(of:)).prefix(count)
        for (i, ghost) in ghostLayers.enumerated() { ghost.isHidden = !free.contains(i) }
        showDisplay(count == 0 ? idleText : (count == 1 ? "DROP IT IN" : "DROP \(count) IN"))
    }

    /// For test scripts: Put Back the n-th file.
    func putBackForTest(_ n: Int) {
        guard n < store.items.count else { return }
        putBack([store.items[n]])
    }

    /// For test scripts: take the first file in the bin out into a folder, as a drag would.
    func takeForTest(to folder: URL) {
        guard let item = store.trayItems.first else { return }
        knockFlap(1.8)
        try? FileManager.default.moveItem(at: store.url(of: item), to: folder.appendingPathComponent(item.name))
        store.reconcile()
        layoutItems(animated: true)
    }

    /// For test scripts: press the button under slot n, as a click would.
    func pressForTest(_ i: Int) {
        guard i < Geo.slotCount, !vending else { return }
        pressedButton = i
        refreshShelves()
        Sounds.play(.click, volume: 0.35)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) { [weak self] in
            self?.pressedButton = nil
            self?.refreshShelves()
            self?.pressButton(i)
        }
    }
    #endif
}

/// A menu item that runs a closure.
final class ActionItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, _ handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func run() { handler() }
}
