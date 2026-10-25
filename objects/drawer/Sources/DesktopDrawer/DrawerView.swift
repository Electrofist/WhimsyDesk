import AppKit

private enum Palette {
    static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
    static func dyn(_ light: UInt32, _ dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? rgb(dark) : rgb(light)
        }
    }
    static let faceTop = dyn(0xE6E3DD, 0x5A5A61)       // matte modern face
    static let faceBottom = dyn(0xC8C4BB, 0x3B3B41)
    static let wall = dyn(0xB4B0A6, 0x3A3A40)
    static let floorTop = dyn(0x6C675F, 0x141416)
    static let floorBottom = dyn(0x8B867D, 0x232327)
    static let barTop = dyn(0xFAFAFB, 0x9A9AA2)        // brushed-metal handle
    static let barBottom = dyn(0x9E9EA5, 0x55555C)
}

/// The drawer artwork is a fixed-size, top-left-origin view. The controller reveals it by resizing the
/// window, so this view only redraws when its contents change, never while sliding.
final class DrawerView: NSView, NSDraggingSource {
    weak var controller: DrawerController?
    private let store: DrawerStore

    private var iconRects: [NSRect] = []
    private var labelRects: [NSRect] = []
    private var liftedIndex: Int?
    private var grabbing = false
    private var pressedIndex: Int?
    private var pressPoint = NSPoint.zero
    private var outgoingDrag = false { didSet { syncDrag() } }
    private var incomingDrag = false { didSet { syncDrag() } }
    private let iconSize: CGFloat = 52

    init(store: DrawerStore) {
        self.store = store
        super.init(frame: NSRect(x: 0, y: 0, width: DrawerController.width, height: DrawerController.totalHeight))
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }

    func refresh() {
        relayout()
        needsDisplay = true
    }

    private func syncDrag() { controller?.dragInProgress = outgoingDrag || incomingDrag }

    // MARK: Layout

    private func relayout() {
        let count = store.items.count
        let perRow = max(8, Int((Double(count) / 2).rounded(.up)))     // two light rows; step shrinks (stacks) when crowded
        let areaX: CGFloat = 38, labelW: CGFloat = 76
        let step = min(80, (bounds.width - areaX * 2 - labelW) / CGFloat(perRow - 1))
        iconRects = []
        labelRects = []
        for i in 0..<count {
            let row = CGFloat(i / perRow), col = CGFloat(i % perRow)
            let cx = areaX + labelW / 2 + col * step
            let top = DrawerController.faceHeight + 24 + row * 94
            iconRects.append(NSRect(x: cx - iconSize / 2, y: top, width: iconSize, height: iconSize))
            labelRects.append(NSRect(x: cx - labelW / 2, y: top + iconSize + 6, width: labelW, height: 16))
        }
    }

    private func itemIndex(at p: NSPoint) -> Int? {
        guard iconRects.count == store.items.count else { return nil }
        return store.items.indices.reversed().first {
            iconRects[$0].insetBy(dx: -4, dy: -4).contains(p) || labelRects[$0].contains(p)
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance { render() }
    }

    private var isDark: Bool { effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }

    private func render() {
        let w = bounds.width, h = bounds.height, faceH = DrawerController.faceHeight

        // Tray: side walls and floor, with a little depth.
        let tray = NSRect(x: 10, y: faceH - 10, width: w - 20, height: h - faceH + 10)
        Palette.wall.setFill()
        tray.fill()
        let floor = tray.insetBy(dx: 8, dy: 0)
        fill(NSBezierPath(rect: floor), top: Palette.floorTop, bottom: Palette.floorBottom, y0: faceH, y1: h)
        shade(in: floor, from: NSPoint(x: floor.minX, y: 0), to: NSPoint(x: floor.minX + 18, y: 0), alpha: 0.30)
        shade(in: floor, from: NSPoint(x: floor.maxX, y: 0), to: NSPoint(x: floor.maxX - 18, y: 0), alpha: 0.30)

        if store.items.isEmpty { drawEmptyHint(in: floor) }
        drawItems()

        // Soft shadow the front face throws onto the tray.
        shade(in: floor, from: NSPoint(x: 0, y: faceH), to: NSPoint(x: 0, y: faceH + 26), alpha: isDark ? 0.55 : 0.42)

        drawFace()
    }

    private func drawEmptyHint(in floor: NSRect) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.32),
        ]
        let text = "Drop files and folders here" as NSString
        let size = text.size(withAttributes: attrs)
        text.draw(at: NSPoint(x: floor.midX - size.width / 2, y: DrawerController.faceHeight + 70), withAttributes: attrs)
    }

    private func drawItems() {
        guard iconRects.count == store.items.count else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingMiddle
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .medium),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph,
        ]

        for (i, item) in store.items.enumerated() {
            let r = iconRects[i]
            let alpha: CGFloat = liftedIndex == i ? 0.3 : 1

            // Contact shadow (manual radial gradient, so flipped coordinates can't invert it).
            let contact = NSRect(x: r.minX + 3, y: r.maxY - 11, width: r.width - 6, height: 15)
            NSGradient(starting: NSColor.black.withAlphaComponent(0.40 * alpha), ending: .clear)?
                .draw(in: NSBezierPath(ovalIn: contact), relativeCenterPosition: .zero)

            // Light stacking: a deterministic few-degree tilt per item.
            let tilt = CGFloat(sin(Double(i) * 12.9898 + 1.7)) * 3
            let t = NSAffineTransform()
            t.translateX(by: r.midX, yBy: r.midY)
            t.rotate(byDegrees: tilt)
            t.translateX(by: -r.midX, yBy: -r.midY)
            NSGraphicsContext.saveGraphicsState()
            t.concat()
            item.icon.draw(in: r, from: .zero, operation: .sourceOver, fraction: alpha, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()

            // Label pill.
            let name = item.name as NSString
            let textW = min(labelRects[i].width, name.size(withAttributes: attrs).width + 12)
            let pill = NSRect(x: labelRects[i].midX - textW / 2, y: labelRects[i].minY, width: textW, height: 15)
            NSColor.black.withAlphaComponent(0.38 * alpha).setFill()
            NSBezierPath(roundedRect: pill, xRadius: 7.5, yRadius: 7.5).fill()
            name.draw(in: NSRect(x: pill.minX + 5, y: pill.minY + 1.5, width: pill.width - 10, height: 13), withAttributes: attrs)
        }
    }

    private func drawFace() {
        let w = bounds.width, fh = DrawerController.faceHeight, radius: CGFloat = 14
        let px = 1 / (window?.backingScaleFactor ?? 2)

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: w, height: fh)).addClip()

        let outline = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: w, height: fh + radius * 2), xRadius: radius, yRadius: radius)
        fill(outline, top: Palette.faceTop, bottom: Palette.faceBottom, y0: 0, y1: fh)

        let rim = NSBezierPath(roundedRect: NSRect(x: 0.5, y: 0.5, width: w - 1, height: fh + radius * 2), xRadius: radius, yRadius: radius)
        rim.lineWidth = 1
        NSColor.white.withAlphaComponent(isDark ? 0.14 : 0.55).setStroke()
        rim.stroke()

        NSColor.black.withAlphaComponent(0.35).setFill()
        NSRect(x: 0, y: fh - px, width: w, height: px).fill()
        NSGraphicsContext.restoreGraphicsState()

        // Handle: recessed pocket, soft shadow, brushed-metal bar.
        let pocket = NSRect(x: (w - 176) / 2, y: 15, width: 176, height: 26)
        NSColor.black.withAlphaComponent(isDark ? 0.35 : 0.14).setFill()
        NSBezierPath(roundedRect: pocket, xRadius: 13, yRadius: 13).fill()

        let bar = NSRect(x: (w - 148) / 2, y: 22, width: 148, height: 12)
        NSColor.black.withAlphaComponent(0.30).setFill()
        NSBezierPath(roundedRect: bar.offsetBy(dx: 0, dy: 2.5), xRadius: 6, yRadius: 6).fill()
        let barPath = NSBezierPath(roundedRect: bar, xRadius: 6, yRadius: 6)
        fill(barPath, top: Palette.barTop, bottom: Palette.barBottom, y0: bar.minY, y1: bar.maxY)
        NSColor.white.withAlphaComponent(0.55).setStroke()
        barPath.lineWidth = px
        barPath.stroke()
    }

    private func fill(_ path: NSBezierPath, top: NSColor, bottom: NSColor, y0: CGFloat, y1: CGFloat) {
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        NSGradient(starting: top, ending: bottom)?.draw(from: NSPoint(x: 0, y: y0), to: NSPoint(x: 0, y: y1),
                                                        options: [.drawsBeforeStartingLocation, .drawsAfterEndingLocation])
        NSGraphicsContext.restoreGraphicsState()
    }

    private func shade(in rect: NSRect, from a: NSPoint, to b: NSPoint, alpha: CGFloat) {
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rect).addClip()
        NSGradient(starting: NSColor.black.withAlphaComponent(alpha), ending: .clear)?.draw(from: a, to: b, options: [])
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: Mouse: grab the face to slide, drag items out

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if p.y < DrawerController.faceHeight {
            if event.clickCount == 2 { controller?.toggle(); return }
            grabbing = true
            NSCursor.closedHand.push()
            controller?.beginGrab(mouseY: NSEvent.mouseLocation.y)
        } else if controller?.isInteractive == true, let i = itemIndex(at: p) {
            if event.clickCount == 2 {
                putBack([store.items[i].name])
            } else {
                pressedIndex = i
                pressPoint = p
            }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if grabbing {
            controller?.grab(mouseY: NSEvent.mouseLocation.y, time: event.timestamp)
            return
        }
        guard let i = pressedIndex else { return }
        let p = convert(event.locationInWindow, from: nil)
        guard hypot(p.x - pressPoint.x, p.y - pressPoint.y) > 4 else { return }
        pressedIndex = nil
        startDrag(i, event: event)
    }

    override func mouseUp(with event: NSEvent) {
        pressedIndex = nil
        guard grabbing else { return }
        grabbing = false
        NSCursor.pop()
        controller?.endGrab(time: event.timestamp)
    }

    // MARK: Dragging out (NSDraggingSource)

    private func startDrag(_ i: Int, event: NSEvent) {
        guard store.items.indices.contains(i), iconRects.indices.contains(i) else { return }
        let item = store.items[i]
        let dragItem = NSDraggingItem(pasteboardWriter: item.url as NSURL)
        dragItem.setDraggingFrame(iconRects[i], contents: item.icon)
        liftedIndex = i
        needsDisplay = true
        beginDraggingSession(with: [dragItem], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.move, .copy, .generic] : []
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        outgoingDrag = true
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        outgoingDrag = false
        liftedIndex = nil
        store.reload { [weak self] in self?.refresh() }
        if !operation.isEmpty {         // the destination (Finder, usually) may finish moving the file a beat later
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.store.reload { self?.refresh() }
            }
        }
    }

    // MARK: Dropping in (NSDraggingDestination)

    private func isOwn(_ info: NSDraggingInfo) -> Bool { (info.draggingSource as? DrawerView) === self }

    private func dropOperation(_ info: NSDraggingInfo) -> NSDragOperation {
        guard !isOwn(info), controller?.isInteractive == true,
              info.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        else { return [] }
        return .move
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !isOwn(sender) else { return [] }
        incomingDrag = true
        controller?.openForDrag()
        return dropOperation(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { dropOperation(sender) }

    override func draggingExited(_ sender: NSDraggingInfo?) { incomingDrag = false }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard dropOperation(sender) == .move,
              let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                               options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return false }
        store.stash(urls) { [weak self] in
            self?.refresh()
            self?.controller?.itemsDropped()
        }
        return true
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) { incomingDrag = false }

    // MARK: Context menu (right-click the face or an item)

    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        let menu = NSMenu()
        if controller?.isInteractive == true, let i = itemIndex(at: p) {
            let name = store.items[i].name
            menu.addItem(menuItem("Put Back on Desktop", #selector(putBackOne(_:)), name))
            menu.addItem(menuItem("Show in Finder", #selector(revealOne(_:)), name))
            menu.addItem(.separator())
        }
        menu.addItem(menuItem("Put Everything Back", #selector(putBackAll)))
        menu.addItem(menuItem("Open Drawer Folder", #selector(openFolder)))
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Desktop Drawer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        quit.target = NSApp
        menu.addItem(quit)
        return menu
    }

    private func menuItem(_ title: String, _ action: Selector, _ object: Any? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = object
        return item
    }

    private func putBack(_ names: [String]) {
        store.putBack(names) { [weak self] in self?.refresh() }
    }

    @objc private func putBackOne(_ sender: NSMenuItem) {
        if let name = sender.representedObject as? String { putBack([name]) }
    }

    @objc private func revealOne(_ sender: NSMenuItem) {
        if let name = sender.representedObject as? String {
            NSWorkspace.shared.activateFileViewerSelecting([store.folderURL.appendingPathComponent(name)])
        }
    }

    @objc private func putBackAll() { putBack(store.items.map(\.name)) }

    @objc private func openFolder() { NSWorkspace.shared.open(store.folderURL) }
}
