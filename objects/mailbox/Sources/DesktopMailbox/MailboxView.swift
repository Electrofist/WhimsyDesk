import AppKit
import QuartzCore

protocol MailboxViewDelegate: AnyObject {
    /// `from` is where the letter starts on screen, if it was pulled from the slot.
    func openLetter(_ id: String, replying: Bool, from: NSRect?)
    func showReplies()
}

/// The post box on the desktop. Layer-hosting: all art is cached in layers, and the display link
/// only runs while the door is moving.
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
    private var itemLayers: [String: CALayer] = [:]
    private var slots: [(item: Item, rect: CGRect)] = []
    private var overflowRect: CGRect?
    private var renderedScale: CGFloat = 0
    /// The letter sticking out of the slot, if any.
    private var waitingID: String?

    private enum Grab { case none, door(fraction: CGFloat), item(Item, CGRect), peek, overflow }
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

        doorBack.frame = doorLayer.bounds
        doorBack.isDoubleSided = false
        doorBack.transform = CATransform3DMakeRotation(.pi, 0, 1, 0)
        doorLayer.addSublayer(doorBack)
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
        hoodLayer.contents = MailboxArt.hood(scale: scale)
        doorFront.contents = MailboxArt.doorFront(scale: scale)
        doorBack.contents = MailboxArt.doorBack(scale: scale)
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
        post.inbox.reversed().map { Item.letter($0) } + store.items.map { Item.file($0) }
    }

    /// Four on the floor, four on the shelf.
    func layoutItems() {
        let items = allItems
        let d = Geo.door
        let front = (count: 4, slot: CGFloat(42), size: CGFloat(38), y: d.minY + 4)
        let back = (count: 4, slot: CGFloat(40), size: CGFloat(34), y: d.minY + 76)
        let capacity = front.count + back.count
        let shown = items.count > capacity ? capacity - 1 : items.count
        let backCount = max(0, shown - front.count) + (items.count > shown ? 1 : 0)

        var newSlots: [(item: Item, rect: CGRect)] = []
        for (i, item) in items.prefix(shown).enumerated() {
            let isFront = i < front.count
            let row = isFront ? front : back
            let index = isFront ? i : i - front.count
            let inRow = isFront ? min(shown, front.count) : backCount
            let start = d.midX - CGFloat(inRow) * row.slot / 2
            let rect = CGRect(x: start + CGFloat(index) * row.slot + (row.slot - row.size) / 2, y: row.y,
                              width: row.size, height: row.size)
            newSlots.append((item, rect))
        }
        slots = newSlots

        CATransaction.begin(); CATransaction.setDisableActions(true)
        var keep = Set<String>()
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
            let start = d.midX - CGFloat(backCount) * back.slot / 2
            let r = CGRect(x: start + CGFloat(backCount - 1) * back.slot + 1, y: back.y + 5, width: back.slot - 2, height: 20)
            let badge = CATextLayer()
            badge.name = "overflow"
            badge.actions = ["contents": NSNull(), "position": NSNull(), "bounds": NSNull()]
            badge.frame = r
            badge.cornerRadius = 10
            badge.backgroundColor = Paint.hex(0xF4EBD8, 0.92)
            badge.foregroundColor = Paint.hex(0x8F2018)
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
        if waitingID != nil { addToolTip(Geo.peek, owner: "A letter for you" as NSString, userData: nil) }
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
        return window.convertToScreen(convert(Geo.peek, to: nil))
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
            refreshToolTips()
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
        let p = convert(point, from: superview)
        return doorHit(p) || bodyHit(p) ? self : nil
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
        if peekHit(p) && !(door.angle > 0.2 && doorHit(p)) {
            grab = .peek
        } else if door.isOpen, let r = overflowRect, r.contains(p) {
            grab = .overflow
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
        let p = convert(event.locationInWindow, from: nil)
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
                    if event.clickCount >= 2 { NSWorkspace.shared.open(store.url(of: f)) }
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

    #if DEBUG
    /// For test scripts: open the letter in the slot as if it were clicked.
    func openWaiting(_ id: String) { delegate?.openLetter(id, replying: false, from: peekScreenRect) }
    #endif

    /// After a letter is opened: the slot letter is pulled out, and the floor shows it as read.
    func letterTaken() {
        layoutItems()
        updateWaiting(animated: true)
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
