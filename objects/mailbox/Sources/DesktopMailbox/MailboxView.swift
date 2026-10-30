import AppKit
import QuartzCore

protocol MailboxViewDelegate: AnyObject {
    func openLetter(_ id: String, replying: Bool)
    func showReplies()
}

/// The mailbox on the desktop. Layer-hosting: all art is cached in layers, and the display link
/// only runs while the door or the flag is moving.
final class MailboxView: NSView, NSDraggingSource {
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

    private var door = DoorModel()
    private var flag = FlagModel()
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
    private let doorLayer = CATransformLayer()
    private let doorFront = CALayer()
    private let doorShade = CALayer()
    private let doorBack = CALayer()
    private let flagLayer = CALayer()
    private var itemLayers: [String: CALayer] = [:]
    private var slots: [(item: Item, rect: CGRect)] = []
    private var overflowRect: CGRect?
    private var renderedScale: CGFloat = 0

    private enum Grab { case none, door(fraction: CGFloat), item(Item, CGRect), flag, overflow }
    private var grab = Grab.none
    private var downPoint = CGPoint.zero
    private var dragged = false

    init(store: FileStore, post: PostOffice) {
        self.store = store
        self.post = post
        super.init(frame: CGRect(origin: .zero, size: Geo.size))
        layer = CALayer()
        wantsLayer = true
        buildLayers()
        registerForDraggedTypes([.fileURL])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Mailbox")
        flag.angle = post.unreadCount > 0 ? FlagModel.up : FlagModel.down
        flag.target = flag.angle
        applyState()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Layers

    private func buildLayers() {
        guard let root = layer else { return }
        let none: [String: CAAction] = ["position": NSNull(), "bounds": NSNull(), "transform": NSNull(),
                                        "opacity": NSNull(), "contents": NSNull(), "hidden": NSNull(),
                                        "sublayers": NSNull(), "frame": NSNull()]
        for l in [rig, baseLayer, boxLayer, interiorLayer, itemsLayer, bodyLayer, doorFront, doorShade, doorBack, flagLayer] {
            l.actions = none
        }
        doorLayer.actions = none
        let full = CGRect(origin: .zero, size: Geo.size)
        rig.frame = full
        root.addSublayer(rig)

        baseLayer.frame = full
        rig.addSublayer(baseLayer)

        boxLayer.frame = full
        var perspective = CATransform3DIdentity
        perspective.m34 = -1 / 800
        boxLayer.sublayerTransform = perspective
        rig.addSublayer(boxLayer)

        interiorLayer.frame = Geo.door
        boxLayer.addSublayer(interiorLayer)

        itemsLayer.frame = full
        let mask = CAShapeLayer()
        mask.path = Paint.arch(Geo.door)
        itemsLayer.mask = mask
        boxLayer.addSublayer(itemsLayer)

        bodyLayer.frame = full
        boxLayer.addSublayer(bodyLayer)

        doorLayer.bounds = CGRect(origin: .zero, size: Geo.door.size)
        doorLayer.anchorPoint = CGPoint(x: 0.5, y: 0)
        doorLayer.position = CGPoint(x: Geo.door.midX, y: Geo.door.minY)
        boxLayer.addSublayer(doorLayer)

        doorFront.frame = doorLayer.bounds
        doorFront.isDoubleSided = false
        doorShade.frame = doorFront.bounds
        doorShade.backgroundColor = Paint.hex(0x000000)
        doorShade.opacity = 0
        doorShade.mask = CALayer()
        doorShade.mask?.frame = doorFront.bounds
        doorFront.addSublayer(doorShade)
        doorLayer.addSublayer(doorFront)

        doorBack.frame = doorLayer.bounds
        doorBack.isDoubleSided = false
        doorBack.transform = CATransform3DMakeRotation(.pi, 1, 0, 0)
        doorLayer.addSublayer(doorBack)

        flagLayer.bounds = CGRect(origin: .zero, size: Geo.flagSize)
        flagLayer.anchorPoint = CGPoint(x: Geo.flagAnchor.x / Geo.flagSize.width, y: Geo.flagAnchor.y / Geo.flagSize.height)
        flagLayer.position = Geo.flagPivot
        rig.addSublayer(flagLayer)
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
        let scale = window?.backingScaleFactor ?? 2
        guard scale != renderedScale else { return }
        renderedScale = scale
        CATransaction.begin(); CATransaction.setDisableActions(true)
        baseLayer.contents = MailboxArt.base(scale: scale)
        interiorLayer.contents = MailboxArt.interior(scale: scale)
        bodyLayer.contents = MailboxArt.body(scale: scale)
        let front = MailboxArt.doorFront(scale: scale)
        doorFront.contents = front
        doorShade.mask?.contents = front
        doorBack.contents = MailboxArt.doorBack(scale: scale)
        flagLayer.contents = MailboxArt.flag(scale: scale)
        for l in [rig, baseLayer, boxLayer, interiorLayer, itemsLayer, bodyLayer, doorFront, doorShade, doorBack, flagLayer] {
            l.contentsScale = scale
        }
        doorShade.mask?.contentsScale = scale
        itemLayers.removeAll()
        itemsLayer.sublayers = nil
        CATransaction.commit()
        layoutItems()
    }

    private func applyState() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        doorLayer.transform = CATransform3DMakeRotation(CGFloat(door.angle), 1, 0, 0)
        doorShade.opacity = Float(sin(min(door.angle, .pi / 2)) * 0.5)
        flagLayer.transform = CATransform3DMakeRotation(CGFloat(flag.angle), 0, 0, 1)
        CATransaction.commit()
    }

    // MARK: Items on the floor

    private var allItems: [Item] {
        post.inbox.reversed().map { Item.letter($0) } + store.items.map { Item.file($0) }
    }

    /// Two rows on the floor of the box: four in front, five smaller ones behind.
    func layoutItems() {
        let items = allItems
        let d = Geo.door
        let front = (count: 4, slot: CGFloat(44), size: CGFloat(40), y: d.minY + 3)
        let back = (count: 5, slot: CGFloat(34), size: CGFloat(31), y: d.minY + 27)
        let capacity = front.count + back.count
        let shown = items.count > capacity ? capacity - 1 : items.count

        var newSlots: [(item: Item, rect: CGRect)] = []
        for (i, item) in items.prefix(shown).enumerated() {
            let row = i < front.count ? front : back
            let index = i < front.count ? i : i - front.count
            // The overflow badge takes the last spot in the back row.
            let backCount = shown - front.count + (items.count > shown ? 1 : 0)
            let inRow = min(row.count, i < front.count ? min(shown, front.count) : backCount)
            let start = d.midX - CGFloat(inRow) * row.slot / 2
            let rect = CGRect(x: start + CGFloat(index) * row.slot + (row.slot - row.size) / 2, y: row.y,
                              width: row.size, height: row.size)
            newSlots.append((item, rect))
        }
        slots = newSlots

        CATransaction.begin(); CATransaction.setDisableActions(true)
        var keep = Set<String>()
        // Back row first so the front row is drawn over it.
        for (index, slot) in slots.enumerated().reversed() {
            let key = slot.item.key
            keep.insert(key)
            let l = itemLayers[key] ?? makeItemLayer(slot.item)
            itemLayers[key] = l
            l.frame = slot.rect
            l.zPosition = CGFloat(-index)
            if l.superlayer == nil { itemsLayer.addSublayer(l) }
        }
        for (key, l) in itemLayers where !keep.contains(key) {
            l.removeFromSuperlayer()
            itemLayers[key] = nil
        }
        itemsLayer.sublayers?.filter { $0.name == "overflow" }.forEach { $0.removeFromSuperlayer() }
        overflowRect = nil
        if items.count > shown {
            // The last spot in the back row.
            let r = CGRect(x: d.midX + 1.5 * back.slot + (back.slot - back.size) / 2, y: back.y + 6,
                           width: back.size, height: 22)
            let badge = CATextLayer()
            badge.name = "overflow"
            badge.actions = ["contents": NSNull(), "position": NSNull(), "bounds": NSNull()]
            badge.frame = r
            badge.cornerRadius = 11
            badge.backgroundColor = Paint.hex(0xF4EBD8, 0.92)
            badge.foregroundColor = Paint.hex(0x2F4D74)
            badge.font = NSFont.systemFont(ofSize: 12, weight: .bold)
            badge.fontSize = 12
            badge.alignmentMode = .center
            badge.string = "+\(items.count - shown)"
            badge.contentsScale = renderedScale
            itemsLayer.addSublayer(badge)
            overflowRect = r
        }
        CATransaction.commit()
        refreshToolTips()
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
            l.shadowOpacity = 0.35
            l.shadowRadius = 2
            l.shadowOffset = CGSize(width: 0, height: -1.5)
        }
        return l
    }

    private func refreshToolTips() {
        removeAllToolTips()
        guard door.isOpen else { return }
        for slot in slots {
            let tip: String
            switch slot.item {
            case .letter(let d): tip = "A letter from \(post.letter(d.id)?.from ?? "someone")"
            case .file(let f): tip = f.name
            }
            addToolTip(slot.rect, owner: tip as NSString, userData: nil)
        }
        if let r = overflowRect { addToolTip(r, owner: "Open the Mailbox folder to see everything" as NSString, userData: nil) }
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
            case .hitStop(let speed): Sounds.play(.thud, volume: Float(min(1, 0.25 + speed / 7)))
            }
        }
        if closingByClick && door.angle < DoorModel.latchZone {
            door.handTarget = nil
            closingByClick = false
        }
        flag.advance(dt)
        applyState()
        if door.isOpen != wasOpen {
            wasOpen = door.isOpen
            doorOpened(wasOpen)
        }
        let holding: Bool = { if case .door = grab { return dragged }; return false }()
        if door.isAtRest && flag.isAtRest && !holding {
            l.invalidate()
            link = nil
        }
    }

    private func doorOpened(_ open: Bool) {
        if open {
            store.reconcile()
            layoutItems()
            if !post.inbox.isEmpty { Sounds.play(.rustle, volume: 0.35) }
        } else {
            removeAllToolTips()
        }
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

    /// Raises the flag when there is unread mail and lowers it once everything is read.
    func updateFlag() {
        let target = post.unreadCount > 0 ? FlagModel.up : FlagModel.down
        guard target != flag.target else { return }
        flag.target = target
        if target == FlagModel.up { Sounds.play(.boing, volume: 0.7) } else { Sounds.play(.flick, volume: 0.6) }
        startTicking()
    }

    /// A letter arrived: the box shakes a little and the flag pops up.
    func mailArrived() {
        layoutItems()
        let shake = CAKeyframeAnimation(keyPath: "position.x")
        shake.values = [0, -3, 3, -2.5, 2, -1, 0].map { NSNumber(value: $0) }
        shake.isAdditive = true
        shake.duration = 0.45
        rig.add(shake, forKey: "shake")
        Sounds.play(.drop, volume: 0.8)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.updateFlag() }
    }

    // MARK: Hit testing

    private var hingeY: CGFloat { Geo.hingeY }

    private func doorHit(_ p: CGPoint) -> Bool {
        if door.angle < 0.25 { return Paint.arch(Geo.door).contains(p) }
        let reach = Geo.door.height * CGFloat(cos(door.angle)) * 1.15
        let y0 = min(hingeY, hingeY + reach) - 6, y1 = max(hingeY, hingeY + reach) + 6
        return CGRect(x: Geo.door.minX - 20, y: y0, width: Geo.door.width + 40, height: y1 - y0).contains(p)
    }

    private func bodyHit(_ p: CGPoint) -> Bool {
        Paint.arch(Geo.mouth.insetBy(dx: -4, dy: -4)).contains(p) || Geo.post.contains(p)
    }

    private func flagHit(_ p: CGPoint) -> Bool {
        let a = CGFloat(flag.angle)
        // The arm and flag, rotated about the pivot.
        let local = CGPoint(x: p.x - Geo.flagPivot.x, y: p.y - Geo.flagPivot.y)
        let u = CGPoint(x: local.x * cos(-a) - local.y * sin(-a), y: local.x * sin(-a) + local.y * cos(-a))
        return CGRect(x: -10, y: -10, width: 64, height: 90).contains(u)
    }

    private func slot(at p: CGPoint) -> (item: Item, rect: CGRect)? {
        guard door.isOpen else { return nil }
        return slots.first { $0.rect.insetBy(dx: -2, dy: -2).contains(p) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        return doorHit(p) || bodyHit(p) || flagHit(p) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if event.modifierFlags.contains([.option, .command]) {
            window?.performDrag(with: event)
            return
        }
        downPoint = p
        dragged = false
        if flagHit(p) && !doorHit(p) {
            grab = .flag
        } else if door.isOpen, let r = overflowRect, r.contains(p) {
            grab = .overflow
        } else if let s = slot(at: p) {
            grab = .item(s.item, s.rect)
        } else if doorHit(p) {
            let h = Geo.door.height
            let f = door.angle < 0.25 ? max(0.35, (p.y - hingeY) / h) : 0.8
            grab = .door(fraction: min(1, f))
        } else if bodyHit(p) {
            grab = .door(fraction: 0.8)
        } else {
            grab = .none
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if !dragged && hypot(p.x - downPoint.x, p.y - downPoint.y) < 3 { return }
        let first = !dragged
        dragged = true
        switch grab {
        case .door(let f):
            let c = max(-1, min(1, (p.y - hingeY) / (f * Geo.door.height)))
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
        case .flag:
            if !dragged {
                flag.target = flag.target == FlagModel.up ? FlagModel.down : FlagModel.up
                Sounds.play(flag.target == FlagModel.up ? .boing : .flick, volume: 0.6)
                startTicking()
            }
        case .item(let item, _):
            if !dragged {
                switch item {
                case .letter(let d): delegate?.openLetter(d.id, replying: false)
                case .file(let f): if event.clickCount >= 2 { NSWorkspace.shared.open(store.url(of: f)) }
                }
            }
        case .overflow:
            if !dragged { NSWorkspace.shared.open(store.folder) }
        case .none:
            break
        }
        grab = .none
        dragged = false
    }

    // MARK: Dragging files out

    private func beginDrag(_ item: Item, rect: CGRect, event: NSEvent) {
        guard case .file(let f) = item else { return }
        let url = store.url(of: f)
        let dragItem = NSDraggingItem(pasteboardWriter: url as NSURL)
        dragItem.setDraggingFrame(rect, contents: NSWorkspace.shared.icon(forFile: url.path))
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
        store.store(urls) { [weak self] in
            Sounds.play(.drop, volume: 0.7)
            self?.layoutItems()
        }
        return true
    }

    // MARK: Menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        let menu = NSMenu()
        if let s = slot(at: p) {
            switch s.item {
            case .letter(let d):
                menu.addItem(ActionItem("Read") { [weak self] in self?.delegate?.openLetter(d.id, replying: false) })
                menu.addItem(ActionItem(post.reply(for: d.id) == nil ? "Write Back…" : "Edit My Reply…") { [weak self] in
                    self?.delegate?.openLetter(d.id, replying: true)
                })
                menu.addItem(ActionItem("Throw Away") { [weak self] in
                    self?.post.throwAway(d.id)
                    self?.layoutItems()
                    self?.updateFlag()
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
        }
        menu.addItem(ActionItem(door.isOpen ? "Close the Door" : "Open the Door") { [weak self] in self?.toggleDoor() })
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
