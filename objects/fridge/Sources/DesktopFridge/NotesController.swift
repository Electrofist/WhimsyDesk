import AppKit
import FridgeCore

/// Sticky notes and photo magnets on the door fronts. Each door gets a host layer on its front face,
/// so everything stuck to it swings with the door and hides behind it when it opens. Static layers,
/// redrawn only when a note changes.
final class NotesController: NSObject, NSTextViewDelegate {
    let store: DoorNotesStore
    private var hosts: [String: CALayer] = [:]
    private var layers: [UUID: CALayer] = [:]
    private var scale: CGFloat

    /// Set by the view: where a door-space point on a shut door appears in view coordinates.
    var viewPoint: ((_ door: String, _ point: CGPoint) -> CGPoint)?
    /// Set by the view: lets the panel take the keyboard while a note is being written.
    var setKeyboard: ((Bool) -> Void)?
    /// The view the editor is placed in.
    weak var view: NSView?

    private var editing: (id: UUID, isNew: Bool, container: NSView, textView: NSTextView)?

    init(store: DoorNotesStore, scale: CGFloat) {
        self.store = store
        self.scale = scale
    }

    var isEditing: Bool { return editing != nil }

    // MARK: Layers

    /// Gives a door's front face its notes.
    func attach(host: CALayer, door: String) {
        hosts[door] = host
        for note in store.notes where note.door == door { makeLayer(note) }
    }

    func setScale(_ newScale: CGFloat) {
        guard newScale != scale else { return }
        scale = newScale
        for note in store.notes { render(note) }
    }

    @discardableResult
    private func makeLayer(_ note: DoorNote) -> CALayer? {
        guard let host = hosts[note.door] else { return nil }
        let l = CALayer()
        l.shadowColor = CGColor(gray: 0, alpha: 1)
        l.shadowOpacity = 0.32
        l.shadowRadius = 1.6
        l.shadowOffset = CGSize(width: 0.8, height: -1.6)
        layers[note.id] = l
        host.addSublayer(l)
        render(note)
        return l
    }

    private func render(_ note: DoorNote, hideText: Bool = false) {
        guard let l = layers[note.id] else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        var size = NoteArt.noteSize
        switch note.kind {
        case .note:
            l.contents = NoteArt.note(text: hideText ? "" : note.text, color: note.color, scale: scale)
            l.shadowPath = CGPath(rect: CGRect(origin: .zero, size: size), transform: nil)
        case .photo:
            if let url = store.photoURL(for: note), let image = NoteArt.loadImage(url) {
                let pixels = CGSize(width: image.width, height: image.height)
                size = NoteArt.photoLayerSize(for: pixels)
                l.contents = NoteArt.photo(image, magnetColor: note.color, scale: scale)
                // Shadow from the print only; the magnet draws its own.
                l.shadowPath = CGPath(rect: CGRect(origin: .zero, size: NoteArt.photoSize(for: pixels)), transform: nil)
            }
        }
        l.bounds = CGRect(origin: .zero, size: size)
        l.position = CGPoint(x: note.x, y: note.y)
        l.transform = CATransform3DMakeRotation(CGFloat(note.tilt), 0, 0, 1)
        l.contentsScale = scale
        CATransaction.commit()
    }

    /// Keeps the layer order the same as the store's (last is on top).
    private func restack(door: String) {
        guard let host = hosts[door] else { return }
        for note in store.notes where note.door == door {
            if let l = layers[note.id] { host.addSublayer(l) }
        }
    }

    // MARK: Queries

    /// Top-most note under a door-space point.
    func hit(door: String, point: CGPoint) -> DoorNote? {
        for note in store.notes.reversed() where note.door == door {
            guard let l = layers[note.id] else { continue }
            // Into the note's own frame: undo its position and tilt.
            let dx = point.x - CGFloat(note.x), dy = point.y - CGFloat(note.y)
            let c = cos(-CGFloat(note.tilt)), s = sin(-CGFloat(note.tilt))
            let local = CGPoint(x: dx * c - dy * s, y: dx * s + dy * c)
            let half = CGSize(width: l.bounds.width / 2, height: l.bounds.height / 2)
            if abs(local.x) <= half.width && abs(local.y) <= half.height { return note }
        }
        return nil
    }

    // MARK: Changes

    private static func randomTilt() -> Double {
        return Double.random(in: -0.07...0.07)
    }

    /// Keeps a note's center far enough inside the door that it never hangs off the edge.
    private func clamp(_ p: CGPoint, door: DoorSpec, size: CGSize) -> CGPoint {
        let mx = min(size.width / 2 + 6, door.size.width / 2), my = min(size.height / 2 + 6, door.size.height / 2)
        return CGPoint(x: min(max(p.x, mx), door.size.width - mx), y: min(max(p.y, my), door.size.height - my))
    }

    /// Shift-click on a shut door: a fresh note under the pointer, ready to write on.
    func addNote(on door: DoorSpec, at point: CGPoint, text: String = "", edit: Bool = true) {
        guard !store.isFull(door: door.name) else { NSSound.beep(); return }
        // The next color in the palette, so a few notes in a row come out different.
        let color = (store.notes.last { $0.kind == .note }?.color ?? -1) + 1
        let p = clamp(point, door: door, size: NoteArt.noteSize)
        let note = DoorNote(kind: .note, door: door.name, x: Double(p.x), y: Double(p.y), text: text,
                            color: color % NoteArt.palette.count, tilt: NotesController.randomTilt())
        store.add(note)
        if let l = makeLayer(note) { popIn(l) }
        if edit { beginEditing(note.id, isNew: true) }
    }

    /// An image file dropped on a door with Shift held. Copies a small thumbnail; the original stays put.
    @discardableResult
    func addPhoto(from url: URL, on door: DoorSpec, at point: CGPoint) -> Bool {
        guard !store.isFull(door: door.name) else { NSSound.beep(); return false }
        guard let png = NoteArt.thumbnailPNG(of: url),
              let image = NSBitmapImageRep(data: png)?.cgImage,
              let name = try? store.savePhoto(png) else { return false }
        let size = NoteArt.photoLayerSize(for: CGSize(width: image.width, height: image.height))
        let p = clamp(point, door: door, size: size)
        let note = DoorNote(kind: .photo, door: door.name, x: Double(p.x), y: Double(p.y),
                            color: Int.random(in: 0..<4), tilt: NotesController.randomTilt() * 0.7,
                            photoName: name, originalPath: url.path)
        store.add(note)
        if let l = makeLayer(note) { popIn(l) }
        return true
    }

    /// Moves a note to a door-space point while it is dragged. Saved on `finishMove`.
    func move(_ id: UUID, to point: CGPoint) {
        guard var note = store.note(id: id), let l = layers[id] else { return }
        note.x = Double(point.x)
        note.y = Double(point.y)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        l.position = point
        CATransaction.commit()
        // Keep the model in step without writing to disk on every mouse move.
        pendingMove = note
    }

    private var pendingMove: DoorNote?

    func liftForMove(_ id: UUID) {
        guard let note = store.note(id: id), let l = layers[id] else { return }
        store.update(note, bringToFront: true)
        restack(door: note.door)
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.12)
        l.shadowOpacity = 0.45
        l.shadowRadius = 4
        l.shadowOffset = CGSize(width: 2, height: -4)
        CATransaction.commit()
    }

    /// Drops a dragged note. Let go off the door and it peels away.
    func finishMove(_ id: UUID, door: DoorSpec) {
        guard let l = layers[id] else { return }
        defer { pendingMove = nil }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.12)
        l.shadowOpacity = 0.32
        l.shadowRadius = 1.6
        l.shadowOffset = CGSize(width: 0.8, height: -1.6)
        CATransaction.commit()
        guard var note = pendingMove ?? store.note(id: id) else { return }
        let p = CGPoint(x: note.x, y: note.y)
        let inside = CGRect(origin: .zero, size: door.size).insetBy(dx: -4, dy: -4).contains(p)
        if !inside {
            remove(id)
            return
        }
        let clamped = clamp(p, door: door, size: l.bounds.size)
        note.x = Double(clamped.x)
        note.y = Double(clamped.y)
        store.update(note)
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.15)
        l.position = clamped
        CATransaction.commit()
    }

    func setColor(_ id: UUID, _ color: Int) {
        guard var note = store.note(id: id) else { return }
        note.color = color
        store.update(note)
        render(note)
    }

    func cycleColor(_ id: UUID) {
        guard let note = store.note(id: id) else { return }
        setColor(id, (note.color + 1) % NoteArt.palette.count)
    }

    /// Peels the note off: it tips, drops and fades, then it is gone.
    func remove(_ id: UUID) {
        if editing?.id == id { cancelEditor() }
        store.remove(id: id)
        guard let l = layers.removeValue(forKey: id) else { return }
        let fall = CABasicAnimation(keyPath: "transform")
        fall.fromValue = l.transform
        fall.toValue = CATransform3DConcat(CATransform3DMakeRotation(0.5, 0, 0, 1), CATransform3DMakeTranslation(10, -26, 0))
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [fall, fade]
        group.duration = 0.28
        group.timingFunction = CAMediaTimingFunction(name: .easeIn)
        CATransaction.begin()
        CATransaction.setCompletionBlock { l.removeFromSuperlayer() }
        l.add(group, forKey: "peel")
        l.opacity = 0
        CATransaction.commit()
    }

    private func popIn(_ l: CALayer) {
        let pop = CAKeyframeAnimation(keyPath: "transform.scale")
        pop.values = [0.6, 1.08, 1]
        pop.keyTimes = [0, 0.6, 1]
        pop.duration = 0.22
        pop.timingFunction = CAMediaTimingFunction(name: .easeOut)
        l.add(pop, forKey: "pop")
    }

    // MARK: Writing on a note

    /// Puts a text view over the note, matching its tilt, and hands it the keyboard.
    func beginEditing(_ id: UUID, isNew: Bool = false) {
        endEditing()
        guard let note = store.note(id: id), note.kind == .note,
              let view = view, let center = viewPoint?(note.door, CGPoint(x: note.x, y: note.y)) else { return }

        let size = NoteArt.noteSize
        let container = NSView(frame: CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                                             width: size.width, height: size.height))
        container.frameCenterRotation = CGFloat(note.tilt) * 180 / .pi

        let textView = NSTextView(frame: NoteArt.textRect)
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = NoteArt.font
        textView.textColor = NoteArt.ink
        textView.insertionPointColor = NoteArt.ink
        textView.typingAttributes = NoteArt.textAttributes
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.string = note.text
        textView.delegate = self
        container.addSubview(textView)
        view.addSubview(container)

        editing = (id, isNew, container, textView)
        render(note, hideText: true)
        setKeyboard?(true)
        view.window?.makeFirstResponder(textView)
        textView.selectAll(nil)
    }

    /// Saves what was written. A new note left empty is thrown away.
    func endEditing() {
        guard let e = editing else { return }
        editing = nil
        let text = e.textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        e.container.removeFromSuperview()
        setKeyboard?(false)
        guard var note = store.note(id: e.id) else { return }
        if text.isEmpty && e.isNew {
            remove(e.id)
            return
        }
        note.text = text
        store.update(note)
        render(note)
    }

    /// Escape: leave the note as it was (or drop it, if it was just made).
    private func cancelEditor() {
        guard let e = editing else { return }
        editing = nil
        e.container.removeFromSuperview()
        setKeyboard?(false)
        if e.isNew {
            remove(e.id)
        } else if let note = store.note(id: e.id) {
            render(note)
        }
    }

    // MARK: NSTextViewDelegate

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            // Return finishes the note. ⌥Return adds a line break.
            if NSEvent.modifierFlags.contains(.option) { return false }
            endEditing()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            cancelEditor()
            return true
        case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            textView.insertText("\n", replacementRange: textView.selectedRange())
            return true
        default:
            return false
        }
    }

    func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString text: String?) -> Bool {
        guard let text = text else { return true }
        let current = textView.string as NSString
        return current.length - range.length + (text as NSString).length <= DoorNotesStore.maxTextLength
    }

    func textDidEndEditing(_ notification: Notification) {
        // Clicking anywhere else (another app, the desktop) finishes the note.
        if editing?.textView === notification.object as AnyObject? { endEditing() }
    }
}
