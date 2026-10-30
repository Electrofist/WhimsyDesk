import AppKit
import QuartzCore

/// The vending machine on the desktop. Layer-hosting: all art is cached in layers, and the display
/// link only runs while something moves.
final class VendingView: NSView {
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

        for l in [shadowLayer, cabinetLayer, backCoils, itemsLayer, frontCoils, labelsLayer] {
            l.frame = full
            rig.addSublayer(l)
        }
        rig.insertSublayer(trayLayer, above: cabinetLayer)
        trayLayer.frame = Geo.tray

        // Files show only through the window and the tray opening.
        let mask = CAShapeLayer()
        let openings = CGMutablePath()
        openings.addRect(Geo.glass)
        openings.addRect(Geo.tray)
        mask.path = openings
        itemsLayer.mask = mask
        var perspective = CATransform3DIdentity
        perspective.m34 = -1 / 600
        itemsLayer.sublayerTransform = perspective

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

        for l in [rig, shadowLayer, cabinetLayer, trayLayer, backCoils, itemsLayer, frontCoils, labelsLayer, glassLayer,
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
        for l in [rig, shadowLayer, cabinetLayer, trayLayer, backCoils, itemsLayer, frontCoils, labelsLayer, glassLayer,
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
    func layoutItems() {
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
                place(l, in: Geo.traySpot(n, of: tray.count), pose: Self.trayPose(item.name))
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
        let dt = lastTick == 0 ? 1.0 / 60 : min(0.05, l.timestamp - lastTick)
        lastTick = l.timestamp
        CATransaction.begin(); CATransaction.setDisableActions(true)
        motions.removeAll { $0.step(dt) }
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

    private func refuseFull() {
        let shake = CAKeyframeAnimation(keyPath: "position.x")
        shake.values = [0, -2.5, 2.5, -2, 1.5, -0.8, 0].map { NSNumber(value: $0) }
        shake.isAdditive = true
        shake.duration = 0.38
        glassLayer.add(shake, forKey: "full")
        let rattle = shake.copy() as! CAKeyframeAnimation
        rattle.values = [0, -0.8, 0.8, -0.5, 0.3, 0].map { NSNumber(value: $0) }
        rig.add(rattle, forKey: "full")
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
    /// For test scripts: put files in as if they were dropped on the glass.
    func storeForTest(_ urls: [URL]) { storeFiles(urls) }
    #endif
}
