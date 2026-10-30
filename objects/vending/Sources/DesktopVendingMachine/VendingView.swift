import AppKit
import QuartzCore
import Quartz

/// The vending machine on the desktop. Layer-hosting: all art is cached in layers, and the display
/// link only runs while something moves.
final class VendingView: NSView, NSDraggingSource, QLPreviewPanelDataSource {
    let store: FileStore

    private let rig = CALayer()
    private let shadowLayer = CALayer()
    private let cabinetLayer = CALayer()
    private let trayLayer = CALayer()
    private let backCoils = CALayer()
    /// Holds the file icons. Masked to the window and the tray, so a falling file passes
    /// behind the cabinet front between them.
    private let itemsLayer = CALayer()
    private let frontCoils = CALayer()
    private let labelsLayer = CALayer()
    /// A file that has left its coil falls here, in front of the coils and shelf edges.
    private let dropLayer = CALayer()
    private let glassLayer = CALayer()
    private let flapHolder = CALayer()
    private let flapLayer = CALayer()
    private let panelLayer = CALayer()
    private let displayLayer = CALayer()
    private var coilBackLayers: [CALayer] = []
    private var coilFrontLayers: [CALayer] = []
    private var labelLayers: [CALayer] = []
    private var keyLayers: [CALayer] = []
    private var itemLayers: [String: CALayer] = [:]
    private var renderedScale: CGFloat = 0
    private var displayLines: [String] = []
    private var idleWork: DispatchWorkItem?

    /// How far each coil has turned, in radians. Only the picture turns; a full turn looks the same.
    private var coilAngles = [CGFloat](repeating: 0, count: Geo.slotCount)
    /// Files whose layers a motion is moving right now; layout leaves them alone.
    private var moving = Set<String>()

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

    /// The code being typed on the keypad.
    private var entryLetter: String?
    private var entryDigit: Int?
    /// A coil is turning or a file is falling; the keypad waits.
    private var vending = false
    /// What the mouse is holding.
    private enum Grab { case none, key(Int), item(StoredItem, CGRect), move(start: CGPoint, origin: CGPoint), resize(start: CGPoint, scale: CGFloat) }
    private var grab = Grab.none
    private var downPoint = CGPoint.zero
    private var dragged = false
    private var selectedName: String?
    private let nameTag = CATextLayer()

    /// The tray flap: how far it has swung out (radians) and how fast.
    private var flapAngle = 0.0
    private var flapSpeed = 0.0
    private var flapMoving = false

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
        displayLines = idleLines
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Vending machine")
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Layers

    private static let still: [String: CAAction] = ["position": NSNull(), "bounds": NSNull(), "transform": NSNull(),
                                                     "opacity": NSNull(), "contents": NSNull(), "hidden": NSNull(),
                                                     "sublayers": NSNull(), "frame": NSNull(), "contentsRect": NSNull()]

    private func buildLayers() {
        guard let root = layer else { return }
        let full = CGRect(origin: .zero, size: Geo.size)
        rig.anchorPoint = .zero
        rig.bounds = full
        rig.position = .zero
        root.addSublayer(rig)

        for l in [shadowLayer, cabinetLayer, backCoils, itemsLayer, frontCoils, labelsLayer, dropLayer] {
            l.frame = full
            rig.addSublayer(l)
        }
        rig.insertSublayer(trayLayer, above: cabinetLayer)
        trayLayer.frame = Geo.tray

        // Files show only through the window and the tray opening.
        let openings = CGMutablePath()
        openings.addRect(Geo.glass)
        openings.addRect(Geo.tray)
        var perspective = CATransform3DIdentity
        perspective.m34 = -1 / 600
        for l in [itemsLayer, dropLayer] {
            let mask = CAShapeLayer()
            mask.path = openings
            l.mask = mask
            l.sublayerTransform = perspective
        }

        let labelMask = CAShapeLayer()
        labelMask.path = CGPath(rect: Geo.glass, transform: nil)
        labelsLayer.mask = labelMask

        for i in 0..<Geo.slotCount {
            let back = CALayer(), front = CALayer()
            for l in [back, front] { l.frame = Geo.coilRect(i) }
            backCoils.addSublayer(back)
            frontCoils.addSublayer(front)
            coilBackLayers.append(back)
            coilFrontLayers.append(front)

            let label = CALayer()
            label.frame = Geo.labelRect(i)
            labelsLayer.addSublayer(label)
            labelLayers.append(label)
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

        panelLayer.frame = Geo.panel
        rig.addSublayer(panelLayer)
        for (_, rect) in Geo.keys {
            let k = CALayer()
            k.frame = rect.insetBy(dx: -2, dy: -2.5)
            k.isHidden = true
            rig.addSublayer(k)
            keyLayers.append(k)
        }
        displayLayer.frame = Geo.display
        rig.addSublayer(displayLayer)

        for l in [rig, shadowLayer, cabinetLayer, trayLayer, backCoils, itemsLayer, frontCoils, labelsLayer, dropLayer, glassLayer,
                  flapHolder, flapLayer, panelLayer, displayLayer] + coilBackLayers + coilFrontLayers + keyLayers + labelLayers {
            l.actions = Self.still
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        renderArt()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
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
        cabinetLayer.contents = ArtFiles.image("cabinet") ?? VendingArt.cabinet(scale: scale)
        trayLayer.contents = ArtFiles.image("tray") ?? VendingArt.tray(scale: scale)
        glassLayer.contents = ArtFiles.image("glass") ?? VendingArt.glass(scale: scale)
        flapLayer.contents = ArtFiles.image("flap") ?? VendingArt.flap(scale: scale)
        panelLayer.contents = ArtFiles.image("panel") ?? VendingArt.panel(pressed: false, scale: scale)
        let back = ArtFiles.image("coil-back") ?? VendingArt.coil(front: false, scale: scale)
        let front = ArtFiles.image("coil-front") ?? VendingArt.coil(front: true, scale: scale)
        for l in coilBackLayers { l.contents = back }
        for l in coilFrontLayers { l.contents = front }
        // Each key's pushed-in look is cut out of a picture of the whole panel with every key pressed.
        let pressed = ArtFiles.image("keys-pressed") ?? VendingArt.panel(pressed: true, scale: scale)
        for l in keyLayers {
            l.contents = pressed
            let f = l.frame, p = Geo.panel
            l.contentsRect = CGRect(x: (f.minX - p.minX) / p.width, y: 1 - (f.maxY - p.minY) / p.height,
                                    width: f.width / p.width, height: f.height / p.height)
        }
        for l in [rig, shadowLayer, cabinetLayer, trayLayer, backCoils, itemsLayer, frontCoils, labelsLayer, dropLayer, glassLayer,
                  flapHolder, flapLayer, panelLayer, displayLayer] + coilBackLayers + coilFrontLayers + keyLayers + labelLayers {
            l.contentsScale = scale
        }
        for l in itemLayers.values { l.contentsScale = scale }
        CATransaction.commit()
        layoutItems()
        showDisplay(displayLines)
    }

    // MARK: Files in coils and in the tray

    /// Puts each file's icon in its coil or in the tray. Files that are moving are left alone.
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
                place(l, in: Geo.iconRect(i))
            } else if let n = tray.firstIndex(of: item) {
                let before = l.position
                place(l, in: Geo.traySpot(n, of: tray.count), pose: Self.trayPose(item.name))
                if animated && before != l.position && before != .zero {
                    // The others in the tray shuffle along to make room.
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
        for (i, angle) in coilAngles.enumerated() { turnCoil(i, to: angle) }
        CATransaction.commit()
        refreshLabels()
    }

    private func makeItemLayer(_ item: StoredItem) -> CALayer {
        let l = CALayer()
        l.actions = Self.still
        l.anchorPoint = CGPoint(x: 0.5, y: 0)
        l.bounds = CGRect(x: 0, y: 0, width: Geo.iconSize, height: Geo.iconSize)
        l.contentsGravity = .resizeAspect
        l.contentsScale = renderedScale
        let icon = NSWorkspace.shared.icon(forFile: store.url(of: item).path)
        var rect = CGRect(x: 0, y: 0, width: 128, height: 128)
        l.contents = icon.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        l.shadowOpacity = 0.45
        l.shadowRadius = 1.5
        l.shadowOffset = CGSize(width: 0, height: -1)
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

    /// Files in the tray lean a little, each its own way.
    private static func trayPose(_ name: String) -> Pose {
        let h = name.utf8.reduce(5381) { ($0 &* 33) &+ Int($1) }
        return Pose(scale: 1, tip: 0.28, tilt: CGFloat(abs(h) % 17 - 8) * 0.012)
    }

    private func turnCoil(_ i: Int, to angle: CGFloat) {
        coilAngles[i] = angle
        let t = CGAffineTransform(rotationAngle: angle)
        coilBackLayers[i].setAffineTransform(t)
        coilFrontLayers[i].setAffineTransform(t)
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

    static func easeOut(_ t: Double) -> Double { 1 - pow(1 - min(max(t, 0), 1), 3) }

    // MARK: Putting files in

    /// Moves files into free coils. A full machine rattles its glass and says so.
    func storeFiles(_ urls: [URL]) {
        let room = store.freeSlots.count
        guard room > 0 else { refuseFull(); return }
        store.store(Array(urls.prefix(room))) { [weak self] added in
            guard let self else { return }
            self.moving.formUnion(added.map(\.name))
            self.layoutItems()
            for (n, item) in added.enumerated() { self.pullIn(item, delay: Double(n) * 0.12) }
            if let last = added.last, let slot = last.slot { self.say([slot, Self.displayName(last.name)]) }
            if urls.count > room { DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.refuseFull() } }
        }
    }

    /// The coil gives a short turn backwards and draws the new file into place.
    private func pullIn(_ item: StoredItem, delay: Double) {
        guard let slot = item.slot, let i = Geo.index(of: slot), let l = itemLayers[item.name] else { return }
        let start = coilAngles[i], rect = Geo.iconRect(i), duration = 0.5
        l.opacity = 0
        place(l, in: rect, pose: Pose(scale: 1.16))
        var t = -delay
        run { [weak self] dt in
            guard let self else { return true }
            t += dt
            guard t >= 0 else { return false }
            if t - dt < 0 && delay == 0 { Sounds.play(.motorShort, volume: 0.4) }
            let u = t / duration
            self.turnCoil(i, to: start + CGFloat(Self.easeInOut(u)) * .pi / 2)
            l.opacity = Float(min(1, u / 0.3))
            self.place(l, in: rect, pose: Pose(scale: 1 + 0.16 * CGFloat(1 - Self.easeOut(u))))
            if u >= 1 {
                self.moving.remove(item.name)
                return true
            }
            return false
        }
    }

    // MARK: Keypad

    /// A key was pressed: letters pick a row, digits a coil, OK vends.
    func press(_ key: Geo.Key) {
        guard !vending else { return }
        switch key {
        case .letter(let l):
            entryLetter = l
            entryDigit = nil
            say(["\(l)_", ""], for: 8)
        case .digit(let d):
            guard let l = entryLetter else { say(["--", ""]); return }
            entryDigit = d
            let code = "\(l)\(d)"
            say([code, store.item(in: code).map { Self.displayName($0.name) } ?? ""], for: 8)
        case .clear:
            entryLetter = nil
            entryDigit = nil
            idleWork?.cancel()
            showDisplay(idleLines)
        case .ok:
            guard let l = entryLetter, let d = entryDigit else {
                Sounds.play(.error, volume: 0.3)
                say(["--", ""])
                return
            }
            entryLetter = nil
            entryDigit = nil
            vend("\(l)\(d)")
        }
    }

    private func keyIndex(at p: CGPoint) -> Int? {
        Geo.keys.firstIndex { $0.rect.insetBy(dx: -1.5, dy: -1.5).contains(p) }
    }

    private func showKey(_ index: Int, down: Bool) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        keyLayers[index].isHidden = !down
        CATransaction.commit()
    }

    // MARK: Vending

    /// The heart of it: the coil turns once and pushes the file forward until it tips off the
    /// shelf, falls, lands in the tray with a knock and a bounce, and the flap swings and settles.
    func vend(_ code: String) {
        guard !vending else { return }
        guard let i = Geo.index(of: code) else {
            Sounds.play(.error, volume: 0.3)
            say(["--", ""])
            return
        }
        guard store.item(in: code) != nil, let item = store.vend(code), let l = itemLayers[item.name] else {
            Sounds.play(.error, volume: 0.3)
            say(["EMPTY", ""])
            return
        }
        select(nil)
        vending = true
        moving.insert(item.name)
        Sounds.play(.beep, volume: 0.3)
        say([code, Self.displayName(item.name)], for: 30)

        let start = coilAngles[i], rest = Geo.iconRect(i)
        let tray = store.trayItems
        let spot = Geo.traySpot(tray.firstIndex(of: item) ?? max(0, tray.count - 1), of: tray.count)
        let landing = Self.trayPose(item.name)
        let turn = 0.9, gravity = 2400.0, step = 1.0 / 240
        let x0 = Double(rest.midX), floor = Double(spot.minY)
        let top = Double(Geo.glass.minY), bottom = Double(Geo.tray.maxY)
        let drift = Double(landing.tilt) > 0 ? 0.18 : -0.18
        var t = -0.14, leftover = 0.0
        var falling = false, landed = false, bounces = 0
        var y = Double(rest.minY), vy = 0.0, tip = 0.4, tipSpeed = 1.6, fallTime = 0.0

        run { [weak self] dt in
            guard let self else { return true }
            t += dt
            if t < 0 { return false }
            if !falling {
                if t - dt < 0 { Sounds.play(.motor, volume: 0.55) }
                // One full turn of the spiral, easing in and out. The file rides forward on it
                // and starts to lean as it runs out of wire.
                let e = Self.easeInOut(t / turn)
                self.turnCoil(i, to: start - CGFloat(e) * 2 * .pi)
                let lean = e > 0.72 ? (e - 0.72) / 0.28 * 0.4 : 0
                // Past the last loop of wire it is in front of everything behind the glass.
                if e > 0.8 && l.superlayer !== self.dropLayer { self.dropLayer.addSublayer(l) }
                self.place(l, in: rest, pose: Pose(scale: CGFloat(1 + 0.14 * e), tip: CGFloat(lean)))
                if t >= turn {
                    falling = true
                    self.refreshLabels()
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
                tip = min(0.9, tip + tipSpeed * step)
                tipSpeed += 2 * step
                if y <= floor {
                    y = floor
                    let impact = -vy
                    if impact > 90 && bounces < 3 {
                        Sounds.play(.thunk, volume: Float(min(0.9, 0.15 + impact / 1800)))
                        self.knockFlap(impact * 0.0021)
                        vy = impact * 0.27
                        bounces += 1
                    } else {
                        vy = 0
                        landed = true
                    }
                }
            }
            // Out of sight between the window and the tray, it slides over to its place in the tray.
            let k = Self.easeInOut((top - y) / (top - bottom))
            let x = x0 + (Double(spot.midX) - x0) * k
            let pose = Pose(scale: CGFloat(1.14 + (1 - 1.14) * k),
                            tip: CGFloat(tip + (Double(landing.tip) - tip) * k),
                            tilt: CGFloat(drift * min(1, fallTime * 3) * (1 - k) + Double(landing.tilt) * k))
            self.place(l, in: CGRect(x: x - Double(Geo.iconSize) / 2, y: y, width: Double(Geo.iconSize), height: Double(Geo.iconSize)),
                       pose: pose)
            if landed && !self.flapMoving {
                self.itemsLayer.addSublayer(l)
                self.moving.remove(item.name)
                self.vending = false
                self.layoutItems()
                self.say([code, Self.displayName(item.name)])
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
        say(["SOLD OUT", ""])
    }

    // MARK: Labels and display

    /// Each shelf label shows its code and, if the coil holds a file, the start of its name.
    func refreshLabels() {
        let scale = renderedScale == 0 ? 2 : renderedScale
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (i, l) in labelLayers.enumerated() {
            l.contents = VendingArt.label(code: Geo.code(i), name: name(at: i), scale: scale)
        }
        CATransaction.commit()
    }

    /// The name of the file in a coil, if any.
    func name(at index: Int) -> String? { store.item(in: Geo.code(index))?.name }

    /// What the display says while nobody is using it.
    private var idleLines: [String] { store.items.contains { $0.slot != nil } ? ["PICK ONE", ""] : ["DROP FILES", "ON GLASS"] }

    /// The display shows a message, then goes back to its resting text after a few seconds.
    func say(_ lines: [String], for seconds: Double = 5) {
        idleWork?.cancel()
        showDisplay(lines)
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.showDisplay(self.idleLines)
        }
        idleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// A file name as the display shows it: without its extension.
    static func displayName(_ name: String) -> String { (name as NSString).deletingPathExtension }

    func showDisplay(_ lines: [String]) {
        displayLines = lines
        CATransaction.begin(); CATransaction.setDisableActions(true)
        displayLayer.contents = Segments.render(lines, scale: renderedScale == 0 ? 2 : renderedScale)
        CATransaction.commit()
    }

    // MARK: Hit testing

    /// The cabinet and its feet. The transparent corners let clicks through to the desktop.
    private func bodyHit(_ p: CGPoint) -> Bool {
        let c = Geo.cabinet
        return CGRect(x: c.minX, y: c.minY - 10, width: c.width + Geo.depth.dx, height: c.height + 10 + Geo.depth.dy).contains(p)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bodyHit(scene(convert(point, from: superview))) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Mouse

    /// The file under the mouse: one in a coil behind the glass, or one in the tray.
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
            if let slot = item.slot, let i = Geo.index(of: slot), Geo.iconRect(i).insetBy(dx: -3, dy: -3).contains(p) {
                return (item, Geo.iconRect(i))
            }
        }
        return nil
    }

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
        if let k = keyIndex(at: p) {
            // Only the keys press. The key goes down with the mouse and comes up with it.
            grab = .key(k)
            showKey(k, down: true)
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
        case .key(let k):
            showKey(k, down: keyIndex(at: p) == k)
        case .item(let item, let rect):
            // Files come out only from the tray. Behind the glass they wait for their code.
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
        case .key(let k):
            showKey(k, down: false)
            if keyIndex(at: p) == k { press(Geo.keys[k].key) }
        case .item(let item, _):
            guard !dragged else { break }
            if event.clickCount >= 2 {
                // Two clicks: behind the glass it vends, in the tray it opens.
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
        for (key, l) in itemLayers {
            l.backgroundColor = key == name ? Paint.hex(0xFFFFFF, 0.25) : nil
            l.cornerRadius = 5
        }
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
        showTag(item.slot.map { "\($0)  \(name)" } ?? name, above: rect)
        // Take the keyboard so Space can open Quick Look.
        window?.makeKey()
        window?.makeFirstResponder(self)
        if QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible { QLPreviewPanel.shared().reloadData() }
    }

    /// A small paper tag with the name, just above the icon.
    private func showTag(_ text: String, above rect: CGRect) {
        if nameTag.superlayer == nil {
            nameTag.actions = ["position": NSNull(), "bounds": NSNull(), "contents": NSNull(), "hidden": NSNull(), "string": NSNull()]
            nameTag.font = NSFont.systemFont(ofSize: 11, weight: .medium)
            nameTag.fontSize = 11
            nameTag.alignmentMode = .center
            nameTag.truncationMode = .middle
            nameTag.foregroundColor = Paint.hex(0x24302F)
            nameTag.backgroundColor = Paint.hex(0xFAF3E2)
            nameTag.cornerRadius = 6
            nameTag.borderWidth = 0.5
            nameTag.borderColor = Paint.hex(0x8A7A5A, 0.4)
            nameTag.shadowOpacity = 0.3
            nameTag.shadowRadius = 3
            nameTag.shadowOffset = CGSize(width: 0, height: -1)
            rig.addSublayer(nameTag)
        }
        nameTag.contentsScale = renderedScale
        let width = min(220, (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium)]).width + 16)
        var x = rect.midX - width / 2
        x = min(max(x, 4), Geo.size.width - width - 4)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        nameTag.string = text
        nameTag.frame = CGRect(x: x, y: rect.maxY + 4, width: width, height: 18)
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

    // MARK: Taking files out of the tray

    private func beginDrag(_ item: StoredItem, rect: CGRect, event: NSEvent) {
        select(nil)
        let url = store.url(of: item)
        let dragItem = NSDraggingItem(pasteboardWriter: url as NSURL)
        dragItem.setDraggingFrame(viewRect(rect), contents: NSWorkspace.shared.icon(forFile: url.path))
        beginDraggingSession(with: [dragItem], event: event, source: self)
        // Your hand pushes the flap in on the way out.
        knockFlap(1.8)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.move, .copy, .generic] : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        store.reconcile()
        layoutItems(animated: true)
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
                let vendItem = ActionItem("Vend \(slot)") { [weak self] in self?.vend(slot) }
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
        let inCoils = store.items.filter { $0.slot != nil }.sorted { ($0.slot ?? "") < ($1.slot ?? "") }
        for item in inCoils {
            guard let slot = item.slot else { continue }
            let entry = ActionItem("\(slot)   \(item.name)") { [weak self] in self?.vend(slot) }
            entry.isEnabled = !vending
            vendMenu.addItem(entry)
        }
        if inCoils.isEmpty {
            let none = NSMenuItem(title: "Nothing inside yet. Drop files on the glass.", action: nil, keyEquivalent: "")
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
        menu.addItem(ActionItem("Quit Desktop Vending Machine") { NSApp.terminate(nil) })
        return menu
    }

    /// Sends files back where they came from. A file in the middle of falling finishes first.
    private func putBack(_ items: [StoredItem]) {
        select(nil)
        for item in items where !moving.contains(item.name) { store.putBack(item) }
        layoutItems(animated: true)
        if store.items.allSatisfy({ $0.slot == nil }) { idleWork?.cancel(); showDisplay(idleLines) }
    }

    // MARK: Dropping files in

    private func fileURLs(_ info: NSDraggingInfo) -> [URL] {
        (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    /// Only the glass takes files.
    private func overGlass(_ info: NSDraggingInfo) -> Bool {
        (info.draggingSource as AnyObject?) !== self && !fileURLs(info).isEmpty
            && Geo.glass.contains(scene(convert(info.draggingLocation, from: nil)))
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { overGlass(sender) ? .move : [] }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { overGlass(sender) ? .move : [] }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard overGlass(sender) else { return false }
        storeFiles(fileURLs(sender))
        return true
    }

    #if DEBUG
    /// For test scripts: 0.1 plays every motion ten times slower.
    static var slowMotion = 1.0

    /// For test scripts: put files in as if they were dropped on the glass.
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

    /// For test scripts: Put Back the n-th file.
    func putBackForTest(_ n: Int) {
        guard n < store.items.count else { return }
        putBack([store.items[n]])
    }

    /// For test scripts: take the first file in the tray out into a folder, as a drag would.
    func takeForTest(to folder: URL) {
        guard let item = store.trayItems.first else { return }
        knockFlap(1.8)
        try? FileManager.default.moveItem(at: store.url(of: item), to: folder.appendingPathComponent(item.name))
        store.reconcile()
        layoutItems(animated: true)
    }

    /// For test scripts: press a key by its label (A, 1, CLR, OK), as a click would.
    func keyForTest(_ label: String) {
        guard let k = Geo.keys.firstIndex(where: { $0.key.label == label }) else { return }
        showKey(k, down: true)
        Sounds.play(.click, volume: 0.35)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.showKey(k, down: false)
            self?.press(Geo.keys[k].key)
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
