import AppKit

/// The tray that slides out beside the box when the door opens: every letter and stored file as a
/// tidy envelope. Read letters, open or drag out files, or Put Back.
final class MailTray: NSPanel {
    static let width: CGFloat = 270

    private let store: FileStore
    private let post: PostOffice
    weak var mailDelegate: MailboxViewDelegate?
    /// Called when something was moved or thrown away, so the box can update.
    var onChange: (() -> Void)?

    private let card = TrayCard()
    private let scroll = NSScrollView()
    private let list = TrayList()
    private let heading = NSTextField(labelWithString: "")
    private let footer = NSTextField(labelWithString: "Drop files on the box to post them here.")
    private(set) var isShown = false

    init(store: FileStore, post: PostOffice) {
        self.store = store
        self.post = post
        super.init(contentRect: CGRect(x: 0, y: 0, width: MailTray.width, height: 300),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        contentView = card

        heading.font = Paint.serif(15, .bold)
        heading.textColor = NSColor(srgbRed: 0.56, green: 0.13, blue: 0.09, alpha: 1)
        footer.font = NSFont.systemFont(ofSize: 11)
        footer.textColor = NSColor(srgbRed: 0.45, green: 0.4, blue: 0.32, alpha: 0.9)
        footer.alignment = .center
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = list
        list.tray = self
        for v in [heading, scroll, footer] as [NSView] { card.addSubview(v) }
    }

    override var canBecomeKey: Bool { false }

    // MARK: Contents

    struct Entry {
        enum Kind { case letter(Delivery, Letter), file(StoredItem) }
        let kind: Kind
        let image: CGImage?
        let name: String
        let detail: String
    }

    private func entries() -> [Entry] {
        let scale = backingScaleFactor
        let size = CGSize(width: 56, height: 38)
        var out: [Entry] = []
        for d in post.inbox.reversed() {
            guard let letter = post.letter(d.id) else { continue }
            out.append(Entry(kind: .letter(d, letter),
                             image: MailboxArt.envelope(kind: letter.kind, read: d.read, size: size, scale: scale),
                             name: letter.title ?? letter.from,
                             detail: (d.read ? "" : "New · ") + "From \(letter.from)"))
        }
        for f in store.items.reversed() {
            let icon = NSWorkspace.shared.icon(forFile: store.url(of: f).path)
            out.append(Entry(kind: .file(f), image: MailboxArt.parcel(name: f.name, icon: icon, size: size, scale: scale),
                             name: f.name, detail: "Posted " + Self.relative(f.storedAt)))
        }
        return out
    }

    private static func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: Date())
    }

    func reload() {
        let items = entries()
        let letters = post.inbox.count, files = store.items.count
        var parts: [String] = []
        if letters > 0 { parts.append(letters == 1 ? "1 letter" : "\(letters) letters") }
        if files > 0 { parts.append(files == 1 ? "1 parcel" : "\(files) parcels") }
        heading.stringValue = parts.isEmpty ? "The box is empty" : parts.joined(separator: " and ")
        list.entries = items

        let rowsHeight = CGFloat(items.count) * TrayList.rowHeight
        let height = min(440, max(150, rowsHeight + 86))
        var frame = self.frame
        frame.origin.y += frame.height - height
        frame.size.height = height
        setFrame(frame, display: true)
        card.frame = CGRect(origin: .zero, size: frame.size)
        heading.frame = CGRect(x: 20, y: height - 40, width: MailTray.width - 40, height: 22)
        footer.frame = CGRect(x: 12, y: 12, width: MailTray.width - 24, height: 16)
        scroll.frame = CGRect(x: 8, y: 36, width: MailTray.width - 16, height: height - 36 - 48)
        list.frame = CGRect(x: 0, y: 0, width: scroll.contentSize.width, height: max(rowsHeight, scroll.contentSize.height))
        list.needsDisplay = true
    }

    // MARK: Showing

    /// Slides out beside the box: to the right if there is room, otherwise to the left.
    func show(beside box: NSRect) {
        let screen = NSScreen.screens.first { $0.frame.intersects(box) }?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        reload()
        let boxRight = box.minX + Geo.box.maxX + Geo.depth.dx
        var x = boxRight + 10
        if x + MailTray.width > screen.maxX { x = box.minX + Geo.box.minX - MailTray.width - 120 }
        let top = box.minY + Geo.box.maxY - 10
        let target = CGRect(x: x, y: top - frame.height, width: MailTray.width, height: frame.height)
        let from = target.offsetBy(dx: x > box.minX ? -24 : 24, dy: 0)
        isShown = true
        setFrame(from, display: false)
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
            animator().setFrame(target, display: true)
            animator().alphaValue = 1
        }
    }

    func hide() {
        guard isShown else { return }
        isShown = false
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, !self.isShown else { return }
            self.orderOut(nil)
        })
    }

    // MARK: Actions from the list

    fileprivate func activate(_ entry: Entry, rowRect: NSRect, doubleClick: Bool) {
        switch entry.kind {
        case .letter(let d, _):
            mailDelegate?.openLetter(d.id, replying: false, from: convertToScreen(list.convert(rowRect, to: nil)))
        case .file(let f):
            if doubleClick { NSWorkspace.shared.open(store.url(of: f)) }
        }
    }

    fileprivate func menu(for entry: Entry) -> NSMenu {
        let menu = NSMenu()
        switch entry.kind {
        case .letter(let d, _):
            menu.addItem(ActionItem("Read") { [weak self] in self?.mailDelegate?.openLetter(d.id, replying: false, from: nil) })
            menu.addItem(ActionItem(post.reply(for: d.id) == nil ? "Write Back…" : "Edit My Reply…") { [weak self] in
                self?.mailDelegate?.openLetter(d.id, replying: true, from: nil)
            })
            menu.addItem(.separator())
            menu.addItem(ActionItem("Throw Away") { [weak self] in
                self?.post.throwAway(d.id)
                self?.changed()
            })
        case .file(let f):
            let url = store.url(of: f)
            menu.addItem(ActionItem("Open") { NSWorkspace.shared.open(url) })
            menu.addItem(ActionItem("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) })
            menu.addItem(.separator())
            menu.addItem(ActionItem("Put Back") { [weak self] in
                self?.store.putBack(f)
                Sounds.play(.rustle, volume: 0.35)
                self?.changed()
            })
        }
        return menu
    }

    fileprivate func url(for entry: Entry) -> URL? {
        if case .file(let f) = entry.kind { return store.url(of: f) }
        return nil
    }

    fileprivate func changed() {
        store.reconcile()
        reload()
        onChange?()
    }
}

/// The tray's paper card.
private final class TrayCard: NSView {
    override var isFlipped: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let r = bounds.insetBy(dx: 1, dy: 1)
        let card = CGPath(roundedRect: r, cornerWidth: 12, cornerHeight: 12, transform: nil)
        Paint.fill(ctx, card, Paint.gradient([(0, Paint.hex(0xFAF3E2)), (1, Paint.hex(0xF1E6CC))]),
                   from: CGPoint(x: 0, y: r.maxY), to: CGPoint(x: 0, y: r.minY))
        // A red band along the top, like the box.
        ctx.saveGState(); ctx.addPath(card); ctx.clip()
        Paint.fill(ctx, CGPath(rect: CGRect(x: r.minX, y: r.maxY - 6, width: r.width, height: 6), transform: nil), MailboxArt.red)
        ctx.restoreGState()
        Paint.stroke(ctx, card, Paint.hex(0x8A7A5A, 0.3), 1)
        let rule = CGMutablePath()
        rule.move(to: CGPoint(x: 18, y: r.maxY - 48)); rule.addLine(to: CGPoint(x: r.maxX - 18, y: r.maxY - 48))
        Paint.stroke(ctx, rule, Paint.hex(0x8A7A5A, 0.25), 1)
    }
}

/// The rows of envelopes. Click a letter to read it; double-click a parcel to open the file,
/// drag it out to move it back, right-click for more.
private final class TrayList: NSView, NSDraggingSource {
    static let rowHeight: CGFloat = 54
    weak var tray: MailTray?
    var entries: [MailTray.Entry] = []
    private var hover: Int?
    private var down: (index: Int, point: CGPoint)?
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true }

    private func rect(_ i: Int) -> CGRect { CGRect(x: 0, y: CGFloat(i) * Self.rowHeight, width: bounds.width, height: Self.rowHeight) }
    private func index(at p: CGPoint) -> Int? {
        let i = Int(p.y / Self.rowHeight)
        return i >= 0 && i < entries.count ? i : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseMoved(with event: NSEvent) {
        let i = index(at: convert(event.locationInWindow, from: nil))
        if i != hover { hover = i; needsDisplay = true }
    }

    override func mouseExited(with event: NSEvent) { hover = nil; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let ink = NSColor(srgbRed: 0.17, green: 0.24, blue: 0.38, alpha: 1)
        let muted = NSColor(srgbRed: 0.45, green: 0.4, blue: 0.32, alpha: 1)
        for (i, e) in entries.enumerated() {
            let r = rect(i)
            guard r.intersects(dirtyRect) else { continue }
            if i == hover {
                Paint.fill(ctx, CGPath(roundedRect: r.insetBy(dx: 4, dy: 2), cornerWidth: 8, cornerHeight: 8, transform: nil),
                           Paint.hex(0x8F2018, 0.07))
            }
            if let image = e.image {
                ctx.saveGState()
                // Flip the image upright inside this flipped view.
                let dest = CGRect(x: 14, y: r.minY + 6, width: 56, height: 46)
                ctx.translateBy(x: 0, y: dest.maxY + dest.minY)
                ctx.scaleBy(x: 1, y: -1)
                ctx.draw(image, in: dest)
                ctx.restoreGState()
            }
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            (e.name as NSString).draw(in: CGRect(x: 82, y: r.minY + 9, width: r.width - 92, height: 22),
                                      withAttributes: [.font: Paint.hand(16), .foregroundColor: ink, .paragraphStyle: style])
            (e.detail as NSString).draw(in: CGRect(x: 82, y: r.minY + 31, width: r.width - 92, height: 16),
                                        withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: muted, .paragraphStyle: style])
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        down = index(at: p).map { ($0, p) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let d = down, let tray, let url = tray.url(for: entries[d.index]) else { return }
        let p = convert(event.locationInWindow, from: nil)
        guard hypot(p.x - d.point.x, p.y - d.point.y) > 4 else { return }
        down = nil
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(CGRect(x: 14, y: rect(d.index).minY + 6, width: 56, height: 46),
                              contents: NSWorkspace.shared.icon(forFile: url.path))
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        guard let d = down else { return }
        down = nil
        tray?.activate(entries[d.index], rowRect: rect(d.index), doubleClick: event.clickCount >= 2)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let i = index(at: convert(event.locationInWindow, from: nil)) else { return nil }
        return tray?.menu(for: entries[i])
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.move, .copy, .generic] : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        tray?.changed()
    }
}
