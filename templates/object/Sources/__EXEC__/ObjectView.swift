import AppKit

/// Draws the object and handles everything you can do to it:
/// click to open or close, drop files in, drag them out, double-click to open one,
/// right-click for Put Back, Option-Command-drag to move the object.
///
/// Nothing here runs on a timer. The view redraws only when something happens.
final class ObjectView: NSView, NSDraggingSource {
    private let store: ObjectStore
    private let look: Look
    private var isOpen = false
    private var pressed: (index: Int, point: NSPoint)?
    private var dragStarted = false
    private var draggedItem: StoredItem?

    init(store: ObjectStore, look: Look) {
        self.store = store
        self.look = look
        super.init(frame: NSRect(origin: .zero, size: look.size))
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Open and close

    private func setOpen(_ open: Bool) {
        guard open != isOpen else { return }
        isOpen = open
        if open { store.reconcile() }
        Sound.play(open ? "open" : "close")
        needsDisplay = true
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        (isOpen ? look.open : look.closed).draw(in: bounds)
        guard isOpen else { return }

        let frames = itemFrames()
        for (index, frame) in frames.enumerated() {
            drawItem(store.items[index], in: frame)
        }
        let hidden = store.items.count - frames.count
        if hidden > 0 {
            let area = itemsRect
            label("+\(hidden) more").draw(in: NSRect(x: area.minX, y: area.minY, width: area.width, height: 14))
        }
    }

    private var itemsRect: NSRect {
        let a = look.itemsArea
        return NSRect(x: bounds.width * a.minX, y: bounds.height * a.minY,
                      width: bounds.width * a.width, height: bounds.height * a.height)
    }

    private var cellSize: NSSize {
        NSSize(width: look.iconSize + 28, height: look.iconSize + 30)
    }

    /// Frames for as many items as fit, filled left to right from the top of the items area.
    private func itemFrames() -> [NSRect] {
        let area = itemsRect
        let cell = cellSize
        let columns = max(1, Int(area.width / cell.width))
        let rows = max(1, Int(area.height / cell.height))
        let count = min(store.items.count, columns * rows)
        let inset = (area.width - CGFloat(columns) * cell.width) / 2
        return (0..<count).map { index in
            let column = index % columns, row = index / columns
            return NSRect(x: area.minX + inset + CGFloat(column) * cell.width,
                          y: area.maxY - CGFloat(row + 1) * cell.height,
                          width: cell.width, height: cell.height)
        }
    }

    private func iconRect(in frame: NSRect) -> NSRect {
        let s = look.iconSize
        return NSRect(x: frame.midX - s / 2, y: frame.maxY - s - 2, width: s, height: s)
    }

    private func drawItem(_ item: StoredItem, in frame: NSRect) {
        NSWorkspace.shared.icon(forFile: store.url(of: item).path).draw(in: iconRect(in: frame))
        label(item.name).draw(in: NSRect(x: frame.minX, y: frame.minY + 2, width: frame.width, height: 26))
    }

    private func label(_ text: String) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingMiddle
        let glow = NSShadow()
        glow.shadowColor = NSColor(white: 1, alpha: 0.7)
        glow.shadowBlurRadius = 2
        return NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .medium),
            .foregroundColor: NSColor(white: 0.12, alpha: 1),
            .paragraphStyle: style,
            .shadow: glow
        ])
    }

    private func itemIndex(at point: NSPoint) -> Int? {
        itemFrames().firstIndex { $0.contains(point) }
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains([.option, .command]) {
            window?.performDrag(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        dragStarted = false
        pressed = nil
        if isOpen, let index = itemIndex(at: point) {
            if event.clickCount == 2 {
                NSWorkspace.shared.open(store.url(of: store.items[index]))
                return
            }
            pressed = (index, point)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pressed, !dragStarted else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - pressed.point.x, point.y - pressed.point.y) > 4 else { return }
        dragStarted = true
        startDrag(pressed.index, event: event)
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressed = nil }
        if event.modifierFlags.contains([.option, .command]) || dragStarted { return }
        if pressed == nil && event.clickCount == 1 { setOpen(!isOpen) }
    }

    // MARK: Drag out

    private func startDrag(_ index: Int, event: NSEvent) {
        let item = store.items[index]
        let url = store.url(of: item)
        let dragging = NSDraggingItem(pasteboardWriter: url as NSURL)
        dragging.setDraggingFrame(iconRect(in: itemFrames()[index]), contents: NSWorkspace.shared.icon(forFile: url.path))
        draggedItem = item
        let session = beginDraggingSession(with: [dragging], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.move, .copy, .generic] : []
    }

    /// If the file left the folder (Finder moved it), forget it. Finder can finish the move a moment
    /// later, so check once more after a second. A one-off check, not polling.
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        guard let item = draggedItem else { return }
        draggedItem = nil
        if !forgetIfGone(item) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in _ = self?.forgetIfGone(item) }
        }
    }

    @discardableResult
    private func forgetIfGone(_ item: StoredItem) -> Bool {
        guard !FileManager.default.fileExists(atPath: store.url(of: item).path) else { return false }
        store.forget(item)
        needsDisplay = true
        return true
    }

    // MARK: Drop in

    private func isOwnDrag(_ info: NSDraggingInfo) -> Bool {
        (info.draggingSource as? ObjectView) === self
    }

    private func fileURLs(_ info: NSDraggingInfo) -> [URL] {
        let objects = info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                          options: [.urlReadingFileURLsOnly: true])
        return objects as? [URL] ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !isOwnDrag(sender), !fileURLs(sender).isEmpty else { return [] }
        setOpen(true)
        return .move
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        isOwnDrag(sender) || fileURLs(sender).isEmpty ? [] : .move
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard !isOwnDrag(sender) else { return false }
        let urls = fileURLs(sender)
        guard !urls.isEmpty else { return false }
        store.store(urls)
        needsDisplay = true
        return true
    }

    // MARK: Right-click menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let menu = NSMenu()
        menu.autoenablesItems = false   // so isEnabled below is respected
        if isOpen, let index = itemIndex(at: point) {
            let name = store.items[index].name
            menu.addItem(action("Open", #selector(openItem(_:)), name))
            menu.addItem(action("Put Back", #selector(putBackItem(_:)), name))
            menu.addItem(action("Show in Finder", #selector(revealItem(_:)), name))
            menu.addItem(.separator())
        }
        menu.addItem(action(isOpen ? "Close" : "Open \(ObjectInfo.name)", #selector(toggle)))
        if !store.items.isEmpty {
            menu.addItem(action("Put Everything Back", #selector(putBackAll)))
        }
        menu.addItem(action("Open \(ObjectInfo.folderName) Folder", #selector(openFolder)))
        menu.addItem(.separator())
        // Greyed out when the object is empty.
        let moveAll = action("Move Everything to Desktop", #selector(moveEverythingToDesktop))
        moveAll.isEnabled = !store.items.isEmpty
        menu.addItem(moveAll)
        let quit = NSMenuItem(title: "Quit \(ObjectInfo.name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        quit.target = NSApp
        menu.addItem(quit)
        return menu
    }

    private func action(_ title: String, _ selector: Selector, _ name: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        item.representedObject = name
        return item
    }

    private func stored(_ sender: NSMenuItem) -> StoredItem? {
        (sender.representedObject as? String).flatMap(store.item(named:))
    }

    @objc private func openItem(_ sender: NSMenuItem) {
        if let item = stored(sender) { NSWorkspace.shared.open(store.url(of: item)) }
    }

    @objc private func putBackItem(_ sender: NSMenuItem) {
        if let item = stored(sender) { store.putBack(item) }
        needsDisplay = true
    }

    @objc private func revealItem(_ sender: NSMenuItem) {
        if let item = stored(sender) { NSWorkspace.shared.activateFileViewerSelecting([store.url(of: item)]) }
    }

    @objc private func toggle() { setOpen(!isOpen) }

    @objc private func putBackAll() {
        for item in store.items { store.putBack(item) }
        needsDisplay = true
    }

    /// Asks first, then moves every stored file onto the Desktop.
    /// Files are moved, never copied or deleted. Any that fail stay inside.
    @objc private func moveEverythingToDesktop() {
        let items = store.items.filter { !$0.name.hasPrefix(".") }
        guard !items.isEmpty else { return }

        let confirm = NSAlert()
        confirm.messageText = "Move everything to your Desktop?"
        let files = items.count == 1 ? "1 file" : "All \(items.count) files"
        let verb = items.count == 1 ? "goes" : "go"
        confirm.informativeText = "\(files) in the \(ObjectInfo.folderName) \(verb) back onto your Desktop."
        confirm.addButton(withTitle: "Move to Desktop")   // first button is the default
        confirm.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        // Keep going past failures and count them for one message at the end.
        var failed = 0
        for item in items where store.moveToDesktop(item) == nil { failed += 1 }
        needsDisplay = true

        if failed > 0 {
            let problem = NSAlert()
            problem.messageText = failed == 1 ? "1 file could not be moved." : "\(failed) files could not be moved."
            problem.informativeText = "They are still inside the \(ObjectInfo.folderName)."
            problem.runModal()
        }
    }

    @objc private func openFolder() { NSWorkspace.shared.open(store.folder) }
}
