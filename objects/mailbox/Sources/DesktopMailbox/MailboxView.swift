import AppKit
import QuartzCore
import Quartz

protocol MailboxViewDelegate: AnyObject {
    /// `from` is where the letter starts on screen, if it was pulled from the slot.
    func openLetter(_ id: String, replying: Bool, from: NSRect?)
    func showReplies()
}

/// The post box on the desktop. Layer-hosting: all art is cached in layers, and the display link
/// only runs while the door is moving.
final class MailboxView: NSView, NSDraggingSource, QLPreviewPanelDataSource {
    enum Item {
        case letter(Delivery)
        case file(StoredItem)
        var key: String {
            switch self {
            case .letter(let d): return "letter:\(d.id):\(d.read)"
            case .file(let f): return "file:\(f.name)"
            }
        }
    }

    let store: FileStore
    let post: PostOffice
    weak var delegate: MailboxViewDelegate?
    /// The door opened (true) or closed (false).
    var onDoorChange: ((Bool) -> Void)?
    /// Letters or files changed.
    var onContentsChange: (() -> Void)?

    private var door = DoorModel()
    private var closingByClick = false
    private var link: CADisplayLink?
    private var lastTick: CFTimeInterval = 0
    private var wasOpen = false

    private let rig = CALayer()
    private let baseLayer = CALayer()
    private let boxLayer = CALayer()
    private let interiorLayer = CALayer()
    private let itemsLayer = CALayer()
    private let bodyLayer = CALayer()
    private let peekClip = CALayer()
    private let peekLayer = CALayer()
    private let hoodLayer = CALayer()
    private let doorLayer = CATransformLayer()
    private let doorFront = CALayer()
    private let doorShade = CALayer()
    private let doorBack = CALayer()
    private let doorEdge = CALayer()
    private var itemLayers: [String: CALayer] = [:]
    private var slots: [(item: Item, rect: CGRect)] = []
    private var selectedName: String?
    private let nameTag = CATextLayer()
    private var renderedScale: CGFloat = 0
    /// The letter sticking out of the slot, if any.
    private var waitingID: String?

    private enum Grab { case none, door(fraction: CGFloat), item(Item, CGRect), peek, resize(start: CGPoint, scale: CGFloat) }

    // MARK: Size

    /// Option-drag makes the box bigger or smaller. Everything is laid out at scale 1 and the
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

    /// Resizes around the bottom middle, so the pole stays planted.
    private func applyScale(_ s: CGFloat) {
        guard let window else { return }
        userScale = min(max(s, Self.scaleRange.lowerBound), Self.scaleRange.upperBound)
        let old = window.frame
        let size = CGSize(width: Geo.size.width * userScale, height: Geo.size.height * userScale)
        let origin = CGPoint(x: old.midX - size.width / 2, y: old.minY)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        rig.setAffineTransform(CGAffineTransform(scaleX: userScale, y: userScale))
        CATransaction.commit()
        window.setFrame(CGRect(origin: origin, size: size), display: true)
        setFrameSize(size)
        refreshToolTips()
    }
    private var grab = Grab.none
    private var downPoint = CGPoint.zero
    private var dragged = false

    init(store: FileStore, post: PostOffice) {
        self.store = store
        self.post = post
        super.init(frame: CGRect(origin: .zero, size: CGSize(width: Geo.size.width * MailboxView.savedScale,
                                                            height: Geo.size.height * MailboxView.savedScale)))
        userScale = MailboxView.savedScale
        layer = CALayer()
        wantsLayer = true
        buildLayers()
        registerForDraggedTypes([.fileURL])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Post box")
        applyState()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Layers

    private func buildLayers() {
        guard let root = layer else { return }
        let none: [String: CAAction] = ["position": NSNull(), "bounds": NSNull(), "transform": NSNull(),
                                        "opacity": NSNull(), "contents": NSNull(), "hidden": NSNull(),
                                        "sublayers": NSNull(), "frame": NSNull()]
        for l in [rig, baseLayer, boxLayer, interiorLayer, itemsLayer, bodyLayer, peekClip, peekLayer, hoodLayer,
                  doorFront, doorShade, doorBack] {
            l.actions = none
        }
        doorLayer.actions = none
        let full = CGRect(origin: .zero, size: Geo.size)
        rig.anchorPoint = .zero
        rig.bounds = full
        rig.position = .zero
        root.addSublayer(rig)

        baseLayer.frame = full
        rig.addSublayer(baseLayer)

        boxLayer.frame = full
        var perspective = CATransform3DIdentity
        perspective.m34 = -1 / 1100
        boxLayer.sublayerTransform = perspective
        rig.addSublayer(boxLayer)

        interiorLayer.frame = Geo.door
        boxLayer.addSublayer(interiorLayer)

        itemsLayer.frame = full
        let mask = CAShapeLayer()
        mask.path = CGPath(rect: Geo.door, transform: nil)
        itemsLayer.mask = mask
        boxLayer.addSublayer(itemsLayer)

        bodyLayer.frame = full
        boxLayer.addSublayer(bodyLayer)

        // A waiting letter shows below the slot and disappears into it.
        peekClip.frame = CGRect(x: 0, y: 0, width: Geo.size.width, height: Geo.slot.maxY)
        peekClip.masksToBounds = true
        peekLayer.bounds = CGRect(origin: .zero, size: CGSize(width: Geo.peek.width, height: Geo.peek.height + 8))
        peekLayer.position = CGPoint(x: Geo.peek.midX, y: Geo.peek.midY)
        peekLayer.setAffineTransform(CGAffineTransform(rotationAngle: 0.06))
        peekLayer.isHidden = true
        peekClip.addSublayer(peekLayer)
        boxLayer.addSublayer(peekClip)

        hoodLayer.frame = full
        boxLayer.addSublayer(hoodLayer)

        doorLayer.bounds = CGRect(origin: .zero, size: Geo.door.size)
        doorLayer.anchorPoint = CGPoint(x: 0, y: 0.5)
        doorLayer.position = CGPoint(x: Geo.door.minX, y: Geo.door.midY)
        boxLayer.addSublayer(doorLayer)

        doorFront.frame = doorLayer.bounds
        doorFront.isDoubleSided = false
        doorShade.frame = doorFront.bounds
        doorShade.backgroundColor = Paint.hex(0x000000)
        doorShade.opacity = 0
        doorFront.addSublayer(doorShade)
        doorLayer.addSublayer(doorFront)

        // A real door has thickness: the back face sits behind the front, joined by an edge.
        let thickness: CGFloat = 7
        doorBack.frame = doorLayer.bounds
        doorBack.isDoubleSided = false
        doorBack.transform = CATransform3DRotate(CATransform3DMakeTranslation(0, 0, -thickness), .pi, 0, 1, 0)
        doorLayer.addSublayer(doorBack)
        doorEdge.actions = ["contents": NSNull(), "transform": NSNull(), "position": NSNull(), "bounds": NSNull()]
        doorEdge.bounds = CGRect(x: 0, y: 0, width: thickness, height: Geo.door.height)
        doorEdge.anchorPoint = CGPoint(x: 0, y: 0.5)
        doorEdge.position = CGPoint(x: Geo.door.width, y: Geo.door.height / 2)
        doorEdge.transform = CATransform3DMakeRotation(.pi / 2, 0, 1, 0)
        doorEdge.backgroundColor = Paint.hex(0x7E1F16)
        let lip = CAGradientLayer()
        lip.frame = doorEdge.bounds
        lip.startPoint = CGPoint(x: 0, y: 0.5); lip.endPoint = CGPoint(x: 1, y: 0.5)
        lip.colors = [Paint.hex(0xE0685A), Paint.hex(0x9A2A1F), Paint.hex(0x5E140E)]
        doorEdge.addSublayer(lip)
        doorLayer.addSublayer(doorEdge)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        renderArt()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        renderArt()
    }

    private func renderArt() {
        rig.setAffineTransform(CGAffineTransform(scaleX: userScale, y: userScale))
        let scale = (window?.backingScaleFactor ?? 2) * max(1, userScale)
        guard scale != renderedScale else { return }
        renderedScale = scale
        CATransaction.begin(); CATransaction.setDisableActions(true)
        // Painted art in Resources/Art wins; otherwise the art drawn in code.
        baseLayer.contents = ArtFiles.image("base") ?? MailboxArt.base(scale: scale)
        interiorLayer.contents = ArtFiles.image("interior") ?? MailboxArt.interior(scale: scale)
        bodyLayer.contents = ArtFiles.image("box") ?? MailboxArt.body(scale: scale)
        hoodLayer.contents = ArtFiles.image("hood") ?? MailboxArt.hood(scale: scale)
        doorFront.contents = ArtFiles.image("door-front") ?? MailboxArt.doorFront(scale: scale)
        doorBack.contents = ArtFiles.image("door-back") ?? MailboxArt.doorBack(scale: scale)
        for l in [rig, baseLayer, boxLayer, interiorLayer, itemsLayer, bodyLayer, peekClip, peekLayer, hoodLayer,
                  doorFront, doorShade, doorBack] {
            l.contentsScale = scale
        }
        itemLayers.removeAll()
        itemsLayer.sublayers = nil
        waitingID = nil
        CATransaction.commit()
        layoutItems()
        updateWaiting(animated: false)
    }

    private func applyState() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        doorLayer.transform = CATransform3DMakeRotation(-CGFloat(door.angle), 0, 1, 0)
        doorShade.opacity = Float(sin(min(door.angle, .pi / 2)) * 0.45)
        CATransaction.commit()
    }

    // MARK: Items on the floor

    private var allItems: [Item] {
        store.items.map { Item.file($0) }
    }

    /// Most files the box holds: three rows of eight.
    static let capacity = 24
    /// Row heights above the bottom of the door opening: the floor and two shelves.
    static let rowBase: [CGFloat] = [4, 54, 102]

    /// Files sit on the floor and the shelves as their own icons, like in the fridge.
    /// Rows fill from the floor up; icons get a little smaller as a row fills.
    func layoutItems() {
        let items = Array(allItems.prefix(Self.capacity))
        let d = Geo.door
        let perRow = max(5, Int((Double(items.count) / 3).rounded(.up)))
        let width = d.width - 16
        let size = min(34, width / CGFloat(perRow) - 2)
        var newSlots: [(item: Item, rect: CGRect)] = []
        for (i, item) in items.enumerated() {
            let row = i / perRow, column = i % perRow
            let inRow = min(perRow, items.count - row * perRow)
            let step = width / CGFloat(perRow)
            let start = d.midX - step * CGFloat(inRow) / 2
            let rect = CGRect(x: start + step * CGFloat(column) + (step - size) / 2, y: d.minY + Self.rowBase[min(row, 2)],
                              width: size, height: size)
            newSlots.append((item, rect))
        }
        slots = newSlots

        CATransaction.begin(); CATransaction.setDisableActions(true)
        var keep = Set<String>()
        for slot in slots {
            let key = slot.item.key
            keep.insert(key)
            let l = itemLayers[key] ?? makeItemLayer(slot.item)
            itemLayers[key] = l
            l.frame = slot.rect
            if l.superlayer == nil { itemsLayer.addSublayer(l) }
        }
        for (key, l) in itemLayers where !keep.contains(key) {
            l.removeFromSuperlayer()
            itemLayers[key] = nil
        }
        CATransaction.commit()
        if let name = selectedName, !slots.contains(where: { if case .file(let f) = $0.item { return f.name == name }; return false }) {
            select(nil)
        }
        refreshToolTips()
        onContentsChange?()
    }

    private func makeItemLayer(_ item: Item) -> CALayer {
        let l = CALayer()
        l.actions = ["position": NSNull(), "bounds": NSNull(), "contents": NSNull()]
        l.contentsGravity = .resizeAspect
        l.contentsScale = renderedScale
        switch item {
        case .letter(let d):
            let kind = post.letter(d.id)?.kind ?? .note
            l.contents = MailboxArt.envelope(kind: kind, read: d.read, scale: renderedScale * 1.2)
            let tilt = CGFloat(Int(d.id.utf8.reduce(0) { $0 + Int($1) }) % 7 - 3) * 0.025
            l.setAffineTransform(CGAffineTransform(rotationAngle: tilt))
        case .file(let f):
            let icon = NSWorkspace.shared.icon(forFile: store.url(of: f).path)
            var rect = CGRect(x: 0, y: 0, width: 64, height: 64)
            l.contents = icon.cgImage(forProposedRect: &rect, context: nil, hints: nil)
            l.shadowOpacity = 0.4
            l.shadowRadius = 2
            l.shadowOffset = CGSize(width: 0, height: -1.5)
        }
        return l
    }

    private func refreshToolTips() {
        removeAllToolTips()
        if waitingID != nil { addToolTip(viewRect(Geo.peek), owner: "A letter for you" as NSString, userData: nil) }
        guard door.isOpen else { return }
        for slot in slots {
            let tip: String
            switch slot.item {
            case .letter(let d): tip = "A letter from \(post.letter(d.id)?.from ?? "someone")"
            case .file(let f): tip = f.name
            }
            addToolTip(viewRect(slot.rect), owner: tip as NSString, userData: nil)
        }
    }

    // MARK: The letter in the slot

    /// The newest unread letter sticks out of the slot. Once everything is read, the slot is empty.
    func updateWaiting(animated: Bool) {
        let newest = post.inbox.last { !$0.read }
        guard newest?.id != waitingID else { return }
        waitingID = newest?.id
        refreshToolTips()
        let rest = CGPoint(x: Geo.peek.midX, y: Geo.peek.midY)
        let hidden = CGPoint(x: rest.x, y: rest.y + Geo.peek.height)
        guard let newest else {
            if animated && !peekLayer.isHidden { slide(peekLayer, from: rest, to: CGPoint(x: rest.x, y: rest.y - 30), fade: true) }
            else { peekLayer.isHidden = true }
            return
        }
        let kind = post.letter(newest.id)?.kind ?? .note
        CATransaction.begin(); CATransaction.setDisableActions(true)
        peekLayer.contents = MailboxArt.envelope(kind: kind, read: false, size: Geo.peek.size, scale: renderedScale)
        peekLayer.isHidden = false
        peekLayer.opacity = 1
        peekLayer.position = rest
        CATransaction.commit()
        if animated {
            // Pushed in through the slot from outside, then it settles with a little bounce.
            let drop = CAKeyframeAnimation(keyPath: "position.y")
            drop.values = [hidden.y, rest.y - 3, rest.y + 1.5, rest.y].map { NSNumber(value: Double($0)) }
            drop.keyTimes = [0, 0.55, 0.8, 1]
            drop.duration = 0.5
            drop.timingFunctions = [CAMediaTimingFunction(name: .easeIn), CAMediaTimingFunction(name: .easeOut),
                                    CAMediaTimingFunction(name: .easeInEaseOut)]
            peekLayer.add(drop, forKey: "arrive")
        }
    }

    private func slide(_ l: CALayer, from: CGPoint, to: CGPoint, fade: Bool) {
        let move = CABasicAnimation(keyPath: "position")
        move.fromValue = NSValue(point: from)
        move.toValue = NSValue(point: to)
        let group = CAAnimationGroup()
        var animations: [CAAnimation] = [move]
        if fade {
            let f = CABasicAnimation(keyPath: "opacity"); f.fromValue = 1; f.toValue = 0
            animations.append(f)
        }
        group.animations = animations
        group.duration = 0.25
        group.timingFunction = CAMediaTimingFunction(name: .easeIn)
        CATransaction.begin()
        CATransaction.setCompletionBlock { l.isHidden = true; l.position = from; l.opacity = 1 }
        l.add(group, forKey: "leave")
        CATransaction.setDisableActions(true)
        l.position = to
        l.opacity = fade ? 0 : 1
        CATransaction.commit()
    }

    /// Where the waiting letter is, in screen coordinates.
    private var peekScreenRect: NSRect? {
        guard let window else { return nil }
        return window.convertToScreen(convert(viewRect(Geo.peek), to: nil))
    }

    /// A letter arrived: it slides into the slot and the box gives a little shake.
    func mailArrived() {
        layoutItems()
        Sounds.play(.arrive, volume: 0.8)
        updateWaiting(animated: true)
        let shake = CAKeyframeAnimation(keyPath: "position.x")
        shake.values = [0, -2.5, 2.5, -2, 1.5, -0.5, 0].map { NSNumber(value: $0) }
        shake.isAdditive = true
        shake.beginTime = CACurrentMediaTime() + 0.28
        shake.duration = 0.4
        rig.add(shake, forKey: "shake")
    }

    // MARK: Motion

    private func startTicking() {
        guard link == nil else { return }
        let l = displayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
        lastTick = 0
    }

    @objc private func tick(_ l: CADisplayLink) {
        let dt = lastTick == 0 ? 1.0 / 60 : l.timestamp - lastTick
        lastTick = l.timestamp
        for event in door.advance(dt) {
            switch event {
            case .unlatched: break
            case .latched(let speed): Sounds.play(.clunk, volume: Float(min(1, 0.35 + speed / 6)))
            case .hitStop(let speed): Sounds.play(.thud, volume: Float(min(1, 0.2 + speed / 8)))
            }
        }
        if closingByClick && door.angle < DoorModel.latchZone {
            door.handTarget = nil
            closingByClick = false
        }
        applyState()
        if door.isOpen != wasOpen {
            wasOpen = door.isOpen
            doorOpened(wasOpen)
        }
        let holding: Bool = { if case .door = grab { return dragged }; return false }()
        if door.isAtRest && !holding {
            l.invalidate()
            link = nil
        }
    }

    private func doorOpened(_ open: Bool) {
        if open {
            store.reconcile()
            layoutItems()
        } else {
            select(nil)
            refreshToolTips()
        }
        onDoorChange?(open)
    }

    func toggleDoor() {
        if door.angle < 0.3 && !closingByClick {
            door.pushOpen()
            Sounds.play(.creak, volume: 0.45)
        } else {
            door.handTarget = 0
            closingByClick = true
            Sounds.play(.creak, volume: 0.35)
        }
        startTicking()
    }

    func openDoor() { if door.angle < 0.3 { toggleDoor() } }

    // MARK: Hit testing

    private func doorHit(_ p: CGPoint) -> Bool {
        let d = Geo.door
        if door.angle < 0.2 { return d.contains(p) }
        // The open door, roughly as it looks in perspective.
        let reach = d.width * CGFloat(cos(door.angle)) * 1.1
        let x0 = min(d.minX, d.minX + reach) - 14, x1 = max(d.minX, d.minX + reach) + 14
        let grow = d.height * 0.12 * CGFloat(sin(door.angle))
        return CGRect(x: x0, y: d.minY - grow, width: x1 - x0, height: d.height + 2 * grow).contains(p)
    }

    private func bodyHit(_ p: CGPoint) -> Bool {
        Paint.dome(Geo.box.insetBy(dx: -2, dy: -2), Geo.domeHeight).contains(p) || Geo.post.contains(p)
    }

    private func peekHit(_ p: CGPoint) -> Bool {
        waitingID != nil && Geo.peek.insetBy(dx: -4, dy: -2).contains(p) && p.y < Geo.slot.maxY
    }

    private func slot(at p: CGPoint) -> (item: Item, rect: CGRect)? {
        guard door.isOpen else { return nil }
        return slots.first { $0.rect.insetBy(dx: -2, dy: -2).contains(p) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = scene(convert(point, from: superview))
        return doorHit(p) || bodyHit(p) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        let p = scene(convert(event.locationInWindow, from: nil))
        if event.modifierFlags.contains([.option, .command]) {
            window?.performDrag(with: event)
            return
        }
        if event.modifierFlags.contains(.option) && (bodyHit(p) || doorHit(p)) {
            grab = .resize(start: NSEvent.mouseLocation, scale: userScale)
            return
        }
        downPoint = p
        dragged = false
        if slot(at: p) == nil { select(nil) }
        if peekHit(p) && !(door.angle > 0.2 && doorHit(p)) {
            grab = .peek
        } else if let s = slot(at: p) {
            grab = .item(s.item, s.rect)
        } else if doorHit(p) {
            let f = door.angle < 0.2 ? max(0.4, (p.x - Geo.hingeX) / Geo.door.width) : 0.85
            grab = .door(fraction: min(1, f))
        } else if bodyHit(p) {
            grab = .door(fraction: 0.85)
        } else {
            grab = .none
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = scene(convert(event.locationInWindow, from: nil))
        if case .resize(let start, let scale) = grab {
            // Up or right to grow, down or left to shrink.
            let m = NSEvent.mouseLocation
            applyScale(scale + ((m.y - start.y) + (m.x - start.x) * 0.5) / 300)
            return
        }
        if !dragged && hypot(p.x - downPoint.x, p.y - downPoint.y) < 3 { return }
        let first = !dragged
        dragged = true
        switch grab {
        case .door(let f):
            let c = max(-1, min(1, (p.x - Geo.hingeX) / (f * Geo.door.width)))
            door.handTarget = min(DoorModel.maxAngle, max(0, acos(Double(c))))
            closingByClick = false
            if first { Sounds.play(.creak, volume: 0.4) }
            startTicking()
        case .item(let item, let rect):
            if first { beginDrag(item, rect: rect, event: event) }
        default:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        switch grab {
        case .door:
            if dragged {
                door.handTarget = nil
                startTicking()
            } else {
                toggleDoor()
            }
        case .peek:
            if let id = waitingID {
                let rect = peekScreenRect
                delegate?.openLetter(id, replying: false, from: rect)
            }
        case .item(let item, _):
            if !dragged {
                switch item {
                case .letter(let d):
                    let r = slots.first { $0.item.key == item.key }?.rect
                    let screen = r.flatMap { rect in window.map { $0.convertToScreen(convert(rect, to: nil)) } }
                    delegate?.openLetter(d.id, replying: false, from: screen)
                case .file(let f):
                    // One click shows its name, two open it. Space shows it in Quick Look.
                    if event.clickCount >= 2 { NSWorkspace.shared.open(store.url(of: f)) } else { select(f.name) }
                }
            }
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

    #if DEBUG
    /// For test scripts: put files in as if they were dropped on the box.
    func postForTest(_ urls: [URL]) { openDoor(); store(urls) }

    /// For test scripts: select a file and open Quick Look.
    func selectForTest(_ index: Int) {
        guard index < slots.count, case .file(let f) = slots[index].item else { return }
        select(f.name)
    }

    /// For test scripts: open the letter in the slot as if it were clicked.
    func openWaiting(_ id: String) { delegate?.openLetter(id, replying: false, from: peekScreenRect) }
    #endif

    /// After a letter is opened: the slot letter is pulled out, and the floor shows it as read.
    func letterTaken() {
        layoutItems()
        updateWaiting(animated: true)
    }

    // MARK: Putting files in

    /// Moves files in, as long as there is room. A full box gives a shake and refuses.
    private func store(_ urls: [URL]) {
        let room = Self.capacity - store.items.count
        guard room > 0 else { refuseFull(); return }
        store.store(Array(urls.prefix(room))) { [weak self] in
            Sounds.play(.drop, volume: 0.7)
            self?.layoutItems()
        }
        if urls.count > room { refuseFull() }
    }

    private func refuseFull() {
        let shake = CAKeyframeAnimation(keyPath: "position.x")
        shake.values = [0, -4, 4, -3, 2, 0].map { NSNumber(value: $0) }
        shake.isAdditive = true
        shake.duration = 0.35
        rig.add(shake, forKey: "full")
        Sounds.play(.thud, volume: 0.5)
        showTag("The box is full", above: CGRect(x: Geo.door.midX - 1, y: Geo.door.maxY - 30, width: 2, height: 2))
    }

    // MARK: Selection, names and Quick Look

    private func select(_ name: String?) {
        selectedName = name
        for (key, l) in itemLayers {
            let on = name.map { key == "file:\($0)" } ?? false
            l.borderWidth = 0
            l.backgroundColor = on ? Paint.hex(0xFFFFFF, 0.22) : nil
            l.cornerRadius = 5
        }
        guard let name, let slot = slots.first(where: { $0.item.key == "file:\(name)" }) else {
            nameTag.isHidden = true
            if QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible { QLPreviewPanel.shared().orderOut(nil) }
            return
        }
        showTag(name, above: slot.rect)
        // Take the keyboard so Space can open Quick Look.
        window?.makeKey()
        window?.makeFirstResponder(self)
        if QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible { QLPreviewPanel.shared().reloadData() }
    }

    /// A small paper tag with the name, just above the icon.
    private func showTag(_ text: String, above rect: CGRect) {
        if nameTag.superlayer == nil {
            nameTag.actions = ["position": NSNull(), "bounds": NSNull(), "contents": NSNull(), "hidden": NSNull()]
            nameTag.font = NSFont.systemFont(ofSize: 11, weight: .medium)
            nameTag.fontSize = 11
            nameTag.alignmentMode = .center
            nameTag.truncationMode = .middle
            nameTag.foregroundColor = Paint.hex(0x2B3A55)
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
        case 36, 76:                            // Return opens it
            if let name = selectedName, let f = store.items.first(where: { $0.name == name }) {
                NSWorkspace.shared.open(store.url(of: f))
            }
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

    // MARK: Dragging files out

    private func beginDrag(_ item: Item, rect: CGRect, event: NSEvent) {
        guard case .file(let f) = item else { return }
        let url = store.url(of: f)
        let dragItem = NSDraggingItem(pasteboardWriter: url as NSURL)
        dragItem.setDraggingFrame(viewRect(rect), contents: NSWorkspace.shared.icon(forFile: url.path))
        beginDraggingSession(with: [dragItem], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.move, .copy, .generic] : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        store.reconcile()
        layoutItems()
    }

    // MARK: Dropping files in

    private func fileURLs(_ info: NSDraggingInfo) -> [URL] {
        (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    /// Dragging files over the box swings the door open, like the fridge.
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard (sender.draggingSource as AnyObject?) !== self, !fileURLs(sender).isEmpty else { return [] }
        openDoor()
        return .move
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        (sender.draggingSource as AnyObject?) !== self && !fileURLs(sender).isEmpty ? .move : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(sender)
        guard !urls.isEmpty else { return false }
        store(urls)
        return true
    }

    // MARK: Menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let p = scene(convert(event.locationInWindow, from: nil))
        let menu = NSMenu()
        if let s = slot(at: p) {
            switch s.item {
            case .letter(let d):
                menu.addItem(ActionItem("Read") { [weak self] in self?.delegate?.openLetter(d.id, replying: false, from: nil) })
                menu.addItem(ActionItem(post.reply(for: d.id) == nil ? "Write Back…" : "Edit My Reply…") { [weak self] in
                    self?.delegate?.openLetter(d.id, replying: true, from: nil)
                })
                menu.addItem(ActionItem("Throw Away") { [weak self] in
                    self?.post.throwAway(d.id)
                    self?.layoutItems()
                    self?.updateWaiting(animated: true)
                })
            case .file(let f):
                let url = store.url(of: f)
                menu.addItem(ActionItem("Open") { NSWorkspace.shared.open(url) })
                menu.addItem(ActionItem("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) })
                menu.addItem(ActionItem("Put Back") { [weak self] in
                    self?.store.putBack(f)
                    self?.layoutItems()
                })
            }
            menu.addItem(.separator())
        } else if let id = waitingID, peekHit(p) {
            menu.addItem(ActionItem("Read") { [weak self] in self?.delegate?.openLetter(id, replying: false, from: self?.peekScreenRect) })
            menu.addItem(.separator())
        }
        menu.addItem(ActionItem(door.isOpen ? "Close the Door" : "Open the Door") { [weak self] in self?.toggleDoor() })
        // Letters that have arrived live here, not in the box.
        let read = post.inbox.filter(\.read)
        if !read.isEmpty {
            let letters = NSMenuItem(title: "Your Letters", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for d in read.reversed() {
                guard let letter = post.letter(d.id) else { continue }
                sub.addItem(ActionItem(letter.title ?? "From \(letter.from)") { [weak self] in
                    self?.delegate?.openLetter(d.id, replying: false, from: nil)
                })
            }
            letters.submenu = sub
            menu.addItem(letters)
        }
        menu.addItem(ActionItem("Open Mailbox Folder") { [weak self] in
            guard let self else { return }
            NSWorkspace.shared.open(self.store.folder)
        })
        if FileManager.default.fileExists(atPath: PostOffice.repliesFolder.path) {
            menu.addItem(ActionItem("Show My Replies") { [weak self] in self?.delegate?.showReplies() })
        }
        menu.addItem(.separator())
        let next = NSMenuItem(title: post.nextDeliveryText, action: nil, keyEquivalent: "")
        next.isEnabled = false
        menu.addItem(next)
        let pace = NSMenuItem(title: "Letters", action: nil, keyEquivalent: "")
        let paceMenu = NSMenu()
        for option in DeliveryPace.allCases {
            if option == .paused { paceMenu.addItem(.separator()) }
            let item = ActionItem(option.title) { [weak self] in self?.post.setPace(option) }
            item.state = DeliveryPace.current == option ? .on : .off
            paceMenu.addItem(item)
        }
        paceMenu.addItem(.separator())
        let note = NSMenuItem(title: "Handpicked. Never ads, never paid for.", action: nil, keyEquivalent: "")
        note.isEnabled = false
        paceMenu.addItem(note)
        pace.submenu = paceMenu
        menu.addItem(pace)
        if post.readCount > 0 {
            menu.addItem(ActionItem("Throw Away Read Letters") { [weak self] in
                self?.post.throwAwayRead()
                self?.layoutItems()
            })
        }
        let sound = ActionItem("Sound") { Sounds.enabled.toggle() }
        sound.state = Sounds.enabled ? .on : .off
        menu.addItem(sound)
        menu.addItem(.separator())
        menu.addItem(ActionItem("Quit Desktop Mailbox") { NSApp.terminate(nil) })
        return menu
    }
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
