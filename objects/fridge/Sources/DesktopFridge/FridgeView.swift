import AppKit
import UniformTypeIdentifiers
import FridgeCore

/// The whole fridge: layer rig, door interaction and file drag and drop.
/// Nothing in here runs on a timer. Work happens on input events, on the door's display link
/// while it moves, and in short one-shot Core Animation transitions.
final class FridgeView: NSView, NSDraggingSource {
    // MARK: Model and helpers

    let store: FridgeStore
    private let finder = FinderBridge()
    private let sounds = SoundPlayer()
    /// Fridge door (index 0, below) and freezer door (index 1, above).
    private var doors: [DoorRig] = []
    private var items: ItemsController!
    private var notes: NotesController!
    private var fog: FogPlayer!

    /// Set by `SystemEvents`.
    var lowPowerMode = false
    var reduceMotion = false

    // MARK: Layers

    private let contactShadow = CALayer()
    private let liftShadow = CALayer()
    private let scene = CALayer()
    private let body = CALayer()
    private let cabinet = CALayer()
    private let interior = CALayer()
    private let frost = CALayer()
    /// The white crossbar in the cabinet between the freezer and the fridge compartment.
    private let divider = CAGradientLayer()
    private let hinges = [CALayer(), CALayer(), CALayer()]
    private let fogHost = CALayer()

    private var artScale: CGFloat = 0
    private var darknessPeak: Float = 0.6

    // MARK: State

    private enum Interaction {
        case none
        /// Pressed on a door, not dragged yet.
        case doorPress(door: Int, doorX: CGFloat, start: NSPoint)
        /// Holding a door at `doorX` (door space), so that spot stays under the pointer.
        case door(door: Int, doorX: CGFloat)
        /// ⌥ drag: resizing the whole fridge.
        case resize(startMouse: NSPoint, startScale: CGFloat)
        case window(startMouse: NSPoint, startOrigin: NSPoint)
        case item(entry: FridgeEntry, start: NSPoint)
        /// ⇧ press on a sticky note or photo: a click changes its color, a drag moves it.
        /// `grab` is where on the note it was picked up, relative to its center.
        case notePress(id: UUID, door: Int, grab: CGPoint, start: NSPoint, moved: Bool)
    }

    private var interaction = Interaction.none
    private var draggingEntry: FridgeEntry?

    private var timeScale: Double {
        if let raw = ProcessInfo.processInfo.environment["FRIDGE_TIME_SCALE"], let v = Double(raw), v > 0 { return v }
        let stored = UserDefaults.standard.double(forKey: "timeScale")
        return stored > 0 ? stored : 1
    }

    // MARK: Setup

    init(store: FridgeStore) {
        self.store = store
        super.init(frame: NSRect(origin: .zero, size: Geo.windowSize))
        wantsLayer = true
        layerContentsRedrawPolicy = .never

        let scale = (NSScreen.main?.backingScaleFactor ?? 2) * userScale
        items = ItemsController(store: store, scale: scale)
        doors = Geo.doors.map { DoorRig(spec: $0, view: self) }
        for (index, rig) in doors.enumerated() {
            rig.driver.onFrame = { [weak self] angle in self?.applyDoor(index, angle: angle) }
        }
        buildLayers()
        fog = FogPlayer(host: fogHost)

        notes = NotesController(store: DoorNotesStore(root: store.root), scale: scale)
        notes.view = self
        notes.viewPoint = { [weak self] name, p in
            guard let spec = self?.doors.first(where: { $0.spec.name == name })?.spec else { return p }
            let s = Geo.sceneFrontPoint(ofDoorPoint: p, door: spec)
            return CGPoint(x: s.x + Geo.bodyOrigin.x, y: s.y + Geo.bodyOrigin.y)
        }
        notes.setKeyboard = { [weak self] on in
            guard let window = self?.window as? FridgePanel else { return }
            window.allowsKey = on
            if on { window.makeKey() } else { window.makeFirstResponder(self) }
        }
        for rig in doors { notes.attach(host: rig.notesHost, door: rig.spec.name) }

        updateLighting()
        renderArt(scale: scale)
        for index in doors.indices { applyDoor(index, angle: 0) }
        registerForDraggedTypes([.fileURL, .string])

        // Development aid: FRIDGE_DEBUG_ANGLE="fridge,freezer" in degrees pins the doors open.
        if let raw = ProcessInfo.processInfo.environment["FRIDGE_DEBUG_ANGLE"] {
            for (index, part) in raw.split(separator: ",").prefix(doors.count).enumerated() {
                guard let degrees = Double(part) else { continue }
                let angle = degrees * Double.pi / 180
                doors[index].driver.debugPin(angle: angle)
                applyDoor(index, angle: angle)
            }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    private func buildLayers() {
        guard let root = layer else { return }
        root.isOpaque = false

        contactShadow.frame = CGRect(x: Geo.bodyOrigin.x + Geo.bodySize.width / 2 - FridgeArt.contactShadowSize.width / 2,
                                     y: Geo.bodyOrigin.y - FridgeArt.contactShadowSize.height / 2 + 3,
                                     width: FridgeArt.contactShadowSize.width,
                                     height: FridgeArt.contactShadowSize.height)
        liftShadow.frame = CGRect(x: Geo.bodyOrigin.x + Geo.bodySize.width / 2 - FridgeArt.liftShadowSize.width / 2,
                                  y: Geo.bodyOrigin.y - FridgeArt.liftShadowSize.height / 2 - 8,
                                  width: FridgeArt.liftShadowSize.width,
                                  height: FridgeArt.liftShadowSize.height)
        liftShadow.opacity = 0
        root.addSublayer(liftShadow)
        root.addSublayer(contactShadow)

        // Scene: everything that belongs to the cabinet and door, with one shared perspective.
        scene.frame = Geo.bodyRectInView
        // Core Animation projects about the layer's center; shift so the vanishing point is the
        // interior's eye instead, and the doors and shelves are seen from one spot.
        var perspective = CATransform3DIdentity
        perspective.m34 = -1 / Geo.eyeDistance
        let dx = Geo.vanishing.x - Geo.bodySize.width / 2
        let dy = Geo.vanishing.y - Geo.bodySize.height / 2
        scene.sublayerTransform = CATransform3DConcat(CATransform3DConcat(CATransform3DMakeTranslation(-dx, -dy, 0), perspective),
                                                      CATransform3DMakeTranslation(dx, dy, 0))
        root.addSublayer(scene)

        // The scene holds a 3D door, so Core Animation depth-tests its direct children. Everything
        // that lies flat in the cabinet plane goes into one plain container, which flattens it in
        // painter's order. Without this the cabinet z-fights the interior and hides it.
        body.frame = CGRect(origin: .zero, size: Geo.bodySize)
        scene.addSublayer(body)

        cabinet.frame = CGRect(origin: .zero, size: Geo.bodySize)
        body.addSublayer(cabinet)

        interior.frame = Geo.opening
        body.addSublayer(interior)
        frost.frame = Geo.opening
        body.addSublayer(frost)
        body.addSublayer(items.layer)

        // Each door brings its own compartment darkness and glow, then its 3D door layers.
        for rig in doors { rig.build(scene: scene, body: body) }

        // Crossbar between the compartments, part of the white cabinet liner.
        divider.frame = CGRect(x: Geo.opening.minX - 2, y: Geo.doorSplitY - 6, width: Geo.opening.width + 4, height: 12)
        divider.colors = [Art.hex(0xC9D0D2), Art.hex(0xF4F7F7), Art.hex(0xDDE3E4), Art.hex(0xA9B2B5)]
        divider.locations = [0, 0.35, 0.7, 1]
        divider.cornerRadius = 3
        body.addSublayer(divider)

        // Hinge plates straddle the doors' left edge and stay put when the doors swing.
        let hingeX = Geo.doorInset - FridgeArt.hingeSize.width * 0.4
        for (hinge, y) in zip(hinges, Geo.hingePlateY) {
            hinge.frame = CGRect(x: hingeX, y: y, width: FridgeArt.hingeSize.width, height: FridgeArt.hingeSize.height)
            // In front of the doors' front faces so the depth test never hides them.
            hinge.zPosition = Geo.doorHalfThickness * 2 + 2
            scene.addSublayer(hinge)
        }

        fogHost.frame = CGRect(origin: .zero, size: Geo.windowSize)
        root.addSublayer(fogHost)
    }

    private func renderArt(scale: CGFloat) {
        guard scale != artScale else { return }
        artScale = scale
        cabinet.contents = FridgeArt.cabinet(scale: scale)
        interior.contents = InteriorArt.interior(scale: scale)
        frost.contents = InteriorArt.frost(scale: scale)
        for rig in doors { rig.render(scale: scale) }
        let hingeImage = FridgeArt.hinge(scale: scale)
        for hinge in hinges { hinge.contents = hingeImage }
        contactShadow.contents = FridgeArt.contactShadow(scale: scale)
        liftShadow.contents = FridgeArt.liftShadow(scale: scale)

        let all: [CALayer] = [cabinet, interior, frost, contactShadow, liftShadow, items.layer] + hinges
        for l in all { l.contentsScale = scale }
        items.setScale(scale)
        notes?.setScale(scale)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let scale = window?.backingScaleFactor { renderArt(scale: scale * userScale) }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateLighting()
        for (index, rig) in doors.enumerated() { applyDoor(index, angle: rig.angle) }
    }

    /// Dark mode: brighter inside, deeper cyan. Light mode: softer, less saturated.
    private func updateLighting() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let colors: [CGColor]
        if dark {
            colors = [Art.color(0.08, 0.80, 1.0, 0.46), Art.color(0.08, 0.80, 1.0, 0)]
            darknessPeak = 0.48
            frost.opacity = 0.95
        } else {
            colors = [Art.color(0.55, 0.85, 0.96, 0.28), Art.color(0.55, 0.85, 0.96, 0)]
            darknessPeak = 0.60
            frost.opacity = 0.80
        }
        for rig in doors { rig.setLighting(glowColors: colors) }
    }

    // MARK: Door rendering and events

    private func applyDoor(_ index: Int, angle: Double) {
        let rig = doors[index]
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rig.apply(angle: angle, darknessPeak: darknessPeak)
        CATransaction.commit()

        if !rig.hasOpened && angle > Geo.openedAngle {
            rig.hasOpened = true
            doorOpened(rig)
        } else if rig.hasOpened && angle < Geo.sealedAngle {
            rig.hasOpened = false
            sounds.playSeal()
        }

        let wasInteractive = rig.interactive
        if !rig.interactive && angle >= Geo.interactiveOnAngle {
            rig.interactive = true
        } else if rig.interactive && angle < Geo.interactiveOffAngle {
            rig.interactive = false
        }
        if rig.interactive != wasInteractive {
            items.openShelves = Set(doors.filter { $0.interactive }.flatMap { $0.spec.shelves })
        }
    }

    private func doorOpened(_ rig: DoorRig) {
        sounds.playOpen()
        items.applyFrost(now: Date(), timeScale: timeScale)
        // The plume is a short frame swap run by the render server, so it stays on in Low Power
        // Mode at half the frame count. Reduce Motion turns it off.
        if !reduceMotion {
            fog.play(scale: artScale, lite: lowPowerMode)
        }
    }

    // MARK: Pause and resume (lock, sleep)

    func pauseEverything() {
        notes.endEditing()
        for rig in doors { rig.driver.suspend() }
        fog.cancel()
        sounds.stopAll()
    }

    func resumeEverything() {
        for rig in doors { rig.driver.resume() }
    }

    /// The door under a scene point. An open door stands in front of the other, so it wins.
    private func doorIndex(at s: CGPoint) -> Int? {
        let hits = doors.indices.filter { Geo.contains(doors[$0].quad, s) }
        return hits.max { doors[$0].angle < doors[$1].angle }
    }

    /// While a file is dragged in or out, no open door may close on the user's hand. Shut doors are
    /// left alone (the drag lock would otherwise push them ajar). `alsoDoor` covers a door that is
    /// only now swinging open for a hovering file.
    private func setItemDrag(_ active: Bool, alsoDoor: Int? = nil) {
        for (index, rig) in doors.enumerated() {
            if !active {
                rig.driver.setItemDrag(false)
            } else if rig.hasOpened || index == alsoDoor {
                rig.driver.setItemDrag(true)
            }
        }
    }

    // MARK: Mouse

    override var acceptsFirstResponder: Bool { return true }
    override var mouseDownCanMoveWindow: Bool { return false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { return true }

    private func scenePoint(_ event: NSEvent) -> CGPoint {
        return Geo.scenePoint(fromView: convert(event.locationInWindow, from: nil))
    }

    private func openingPoint(_ scenePoint: CGPoint) -> CGPoint {
        return CGPoint(x: scenePoint.x - Geo.opening.minX, y: scenePoint.y - Geo.opening.minY)
    }

    /// Swing-open angle used by double-click and by files hovering over a closed fridge.
    private static let swingOpenAngle = 96.0 * Double.pi / 180

    /// ⌥ drag resizes the fridge, ⌥⌘ drag moves it. A plain drag only ever works the door.
    private enum Gesture { case none, resize, move }

    private func gesture(for flags: NSEvent.ModifierFlags) -> Gesture {
        let f = flags.intersection(.deviceIndependentFlagsMask)
        if f.contains(.option) && f.contains(.command) { return .move }
        if f.contains(.option) { return .resize }
        return .none
    }

    private func isOnFridge(_ s: CGPoint) -> Bool {
        return doorIndex(at: s) != nil || CGRect(origin: .zero, size: Geo.bodySize).contains(s)
    }

    override func mouseDown(with event: NSEvent) {
        let s = scenePoint(event)
        // A click anywhere else on the fridge finishes the note being written.
        if notes.isEditing { notes.endEditing() }

        switch gesture(for: event.modifierFlags) {
        case .move where isOnFridge(s):
            beginWindowDrag()
            NSCursor.closedHand.set()
            return
        case .resize where isOnFridge(s):
            interaction = .resize(startMouse: NSEvent.mouseLocation, startScale: userScale)
            return
        default:
            break
        }

        if notesMouseDown(event, at: s) { return }

        if let index = doorIndex(at: s) {
            if event.clickCount == 2 {
                toggleDoor(index)
                interaction = .none
                return
            }
            // Grabbing right by the hinge would give absurd leverage; hold no closer than this.
            let rig = doors[index]
            let doorX = max(70, Geo.doorX(underSceneX: s.x, angle: rig.angle, door: rig.spec))
            interaction = .doorPress(door: index, doorX: doorX, start: NSEvent.mouseLocation)
            NSCursor.closedHand.set()
            return
        }
        if let entry = items.hit(at: openingPoint(s)) {
            if event.clickCount == 2 {
                // Double-click opens it, like Finder. Taking it out is Put Back in the right-click menu.
                NSWorkspace.shared.open(store.url(for: entry))
                interaction = .none
            } else {
                interaction = .item(entry: entry, start: event.locationInWindow)
            }
            return
        }
    }

    override func mouseDragged(with event: NSEvent) {
        switch interaction {
        case .doorPress(let index, let doorX, let start):
            let m = NSEvent.mouseLocation
            guard hypot(m.x - start.x, m.y - start.y) > 3 else { return }
            interaction = .door(door: index, doorX: doorX)
            doors[index].driver.hold(at: doors[index].angle)
            mouseDragged(with: event)

        case .resize(let startMouse, let startScale):
            // Drag up or right to grow, down or left to shrink. The feet stay planted.
            let m = NSEvent.mouseLocation
            let d = (m.y - startMouse.y) + (m.x - startMouse.x) * 0.5
            setUserScale(startScale * exp(d / 320), rerender: false)

        case .door(let index, let doorX):
            let rig = doors[index]
            let s = scenePoint(event)
            let target = Geo.angle(forDoorX: doorX, atSceneX: s.x, maxAngle: rig.driver.maxAngle, door: rig.spec)
            rig.driver.hold(at: target)

        case .window(let startMouse, let startOrigin):
            guard let window = window else { return }
            let m = NSEvent.mouseLocation
            window.setFrameOrigin(NSPoint(x: startOrigin.x + (m.x - startMouse.x), y: startOrigin.y + (m.y - startMouse.y)))

        case .item(let entry, let start):
            let dx = event.locationInWindow.x - start.x
            let dy = event.locationInWindow.y - start.y
            if hypot(dx, dy) > 4 {
                interaction = .none
                beginItemDrag(entry, event: event)
            }

        case .notePress(let id, let index, let grab, let start, let moved):
            let m = NSEvent.mouseLocation
            if !moved {
                guard hypot(m.x - start.x, m.y - start.y) > 3 else { return }
                notes.liftForMove(id)
                interaction = .notePress(id: id, door: index, grab: grab, start: start, moved: true)
            }
            let p = Geo.doorPoint(underScene: scenePoint(event), door: doors[index].spec)
            notes.move(id, to: CGPoint(x: p.x - grab.x, y: p.y - grab.y))

        case .none:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        switch interaction {
        case .door(let index, _):
            doors[index].driver.release()   // the door keeps the momentum the hand gave it
            NSCursor.openHand.set()
        case .doorPress:
            NSCursor.openHand.set()
        case .resize:
            setUserScale(userScale, rerender: true)   // crisp bitmaps at the new size
            UserDefaults.standard.set(Double(userScale), forKey: "fridgeScale")
            if let origin = window?.frame.origin {
                UserDefaults.standard.set(NSStringFromPoint(origin), forKey: "windowOrigin")
            }
        case .notePress(let id, let index, _, _, let moved):
            if moved {
                notes.finishMove(id, door: doors[index].spec)
            } else {
                notes.cycleColor(id)
            }
            NSCursor.arrow.set()
        case .window:
            setLifted(false)
            if let origin = window?.frame.origin {
                UserDefaults.standard.set(NSStringFromPoint(origin), forKey: "windowOrigin")
            }
        default:
            break
        }
        interaction = .none
    }

    private func toggleDoor(_ index: Int) {
        let rig = doors[index]
        rig.driver.swing(to: rig.angle > 30 * Double.pi / 180 ? 0 : FridgeView.swingOpenAngle)
    }

    // MARK: Cursor: an open hand over the door says "you can pull this"

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        guard case .none = interaction else { return }
        let s = scenePoint(event)
        switch gesture(for: event.modifierFlags) {
        case .move where isOnFridge(s):
            NSCursor.openHand.set()
        case .resize where isOnFridge(s):
            resizeCursor.set()
        default:
            (doorIndex(at: s) != nil ? NSCursor.openHand : NSCursor.arrow).set()
        }
    }

    private var resizeCursor: NSCursor {
        if #available(macOS 15.0, *) {
            return NSCursor.frameResize(position: .topRight, directions: .all)
        }
        return NSCursor.resizeUpDown
    }

    // MARK: Size (⌥ drag)

    /// How big the fridge is drawn, relative to its design size. Saved between launches.
    private(set) var userScale: CGFloat = {
        let saved = UserDefaults.standard.double(forKey: "fridgeScale")
        return saved > 0 ? CGFloat(saved) : 1
    }()

    static let scaleRange: ClosedRange<CGFloat> = 0.45...1.6

    /// Resizes the window around the fridge's feet. The view keeps its design-size bounds, so all
    /// geometry and hit testing stay in design points and AppKit scales the result.
    /// `rerender` redraws the art at the new pixel density (skipped mid-drag to keep it smooth).
    /// `windowScale` is the scale the window currently has (defaults to `userScale`).
    /// `keepOrigin` leaves the window's origin alone, for restoring a saved position at launch.
    func setUserScale(_ newScale: CGFloat, rerender: Bool, windowScale: CGFloat? = nil, keepOrigin: Bool = false) {
        guard let window = window else { return }
        let old = windowScale ?? userScale
        let s = min(max(newScale, FridgeView.scaleRange.lowerBound), FridgeView.scaleRange.upperBound)
        userScale = s

        let feet = CGPoint(x: Geo.bodyOrigin.x + Geo.bodySize.width / 2, y: Geo.bodyOrigin.y)
        let planted = NSPoint(x: window.frame.minX + feet.x * old, y: window.frame.minY + feet.y * old)
        let size = NSSize(width: (Geo.windowSize.width * s).rounded(), height: (Geo.windowSize.height * s).rounded())
        let origin = keepOrigin
            ? window.frame.origin
            : NSPoint(x: (planted.x - feet.x * s).rounded(), y: (planted.y - feet.y * s).rounded())
        window.setFrame(NSRect(origin: origin, size: size), display: true)
        setFrameSize(size)
        setBoundsSize(Geo.windowSize)

        if rerender {
            renderArt(scale: window.backingScaleFactor * s)
        }
    }

    override func mouseExited(with event: NSEvent) {
        if case .none = interaction { NSCursor.arrow.set() }
    }

    private func beginWindowDrag() {
        guard let window = window else { return }
        interaction = .window(startMouse: NSEvent.mouseLocation, startOrigin: window.frame.origin)
        setLifted(true)
    }

    /// Lift shadow while the whole fridge is dragged around the desktop.
    private func setLifted(_ lifted: Bool) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.15)
        liftShadow.opacity = lifted ? 1 : 0
        scene.transform = lifted ? CATransform3DMakeTranslation(0, 4, 0) : CATransform3DIdentity
        CATransaction.commit()
    }

    // MARK: Menu

    override func rightMouseDown(with event: NSEvent) {
        let s = scenePoint(event)
        let menu = NSMenu()
        if let (_, note) = noteHit(at: s) {
            addNoteMenuItems(note, to: menu)
            menu.addItem(.separator())
        } else if let entry = items.hit(at: openingPoint(s)) {
            menu.addItem(ActionMenuItem("Open") { [weak self] in
                guard let self = self else { return }
                NSWorkspace.shared.open(self.store.url(for: entry))
            })
            menu.addItem(ActionMenuItem("Put Back") { [weak self] in self?.putBack(entry) })
            menu.addItem(ActionMenuItem("Show in Finder") { [weak self] in
                guard let self = self else { return }
                NSWorkspace.shared.activateFileViewerSelecting([self.store.url(for: entry)])
            })
            menu.addItem(.separator())
        }
        menu.addItem(ActionMenuItem("Open Fridge Folder") { [weak self] in
            guard let self = self else { return }
            NSWorkspace.shared.open(self.store.root)
        })
        menu.addItem(ActionMenuItem("Quit Desktop Fridge") { NSApp.terminate(nil) })
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    // MARK: Taking items out

    private func putBack(_ entry: FridgeEntry) {
        do {
            let result = try store.restore(entry)
            items.remove(id: entry.id)
            if let position = result.desktopPosition {
                finder.setDesktopPosition(ofItemNamed: result.destination.lastPathComponent, x: position.x, y: position.y)
            }
        } catch {
            items.remove(id: entry.id)
        }
    }

    private func beginItemDrag(_ entry: FridgeEntry, event: NSEvent) {
        let url = store.url(for: entry)
        guard FileManager.default.fileExists(atPath: url.path),
              let sceneRect = items.sceneFrame(of: entry.id) else { return }

        let frame = sceneRect.offsetBy(dx: Geo.bodyOrigin.x, dy: Geo.bodyOrigin.y)
        let dragItem = NSDraggingItem(pasteboardWriter: url as NSURL)
        dragItem.setDraggingFrame(frame, contents: NSWorkspace.shared.icon(forFile: url.path))

        draggingEntry = entry
        let session = beginDraggingSession(with: [dragItem], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        switch context {
        case .outsideApplication: return [.move, .copy]
        case .withinApplication: return []
        @unknown default: return []
        }
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        guard let entry = draggingEntry else { return }
        items.setDragging(entry.id, true)
        setItemDrag(true)   // the open doors now refuse to close
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        setItemDrag(false)
        guard let entry = draggingEntry else { return }
        draggingEntry = nil
        items.setDragging(entry.id, false)
        if operation.isEmpty { return }
        // The receiving app moves the file. Check now, and again shortly after in case it is slow.
        for delay in [0.05, 1.0, 3.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.forgetIfGone(entry)
            }
        }
    }

    private func forgetIfGone(_ entry: FridgeEntry) {
        guard store.entry(id: entry.id) != nil else { return }
        if !FileManager.default.fileExists(atPath: store.url(for: entry).path) {
            store.removeEntry(id: entry.id)
            items.remove(id: entry.id)
        }
    }

    // MARK: Putting items in

    /// Which door's compartment a scene point is in, by height. Outside the cabinet it is the door under it.
    private func compartment(at s: CGPoint) -> Int? {
        if Geo.opening.contains(s) {
            return doors.firstIndex { $0.spec.frame.minY <= s.y && s.y < $0.spec.frame.maxY }
        }
        return doorIndex(at: s)
    }

    private func dropShelf(for sender: NSDraggingInfo) -> Int? {
        let s = Geo.scenePoint(fromView: convert(sender.draggingLocation, from: nil))
        guard !store.isFull, Geo.opening.contains(s), let index = compartment(at: s), doors[index].interactive else { return nil }
        // The nearest shelf behind the open door at that height.
        let y = Double(s.y - Geo.opening.minY)
        return doors[index].spec.shelves.min {
            abs(InteriorGeometry.shelfFrontY[$0] - y) < abs(InteriorGeometry.shelfFrontY[$1] - y)
        }
    }

    /// Like a spring-loaded folder: a file hovering over a shut door swings it open, and it will not
    /// close on the user's hand while the file is over it.
    private func springOpen(for sender: NSDraggingInfo) {
        let s = Geo.scenePoint(fromView: convert(sender.draggingLocation, from: nil))
        // Only files go inside. Text can only be stuck on the door (with ⇧).
        guard sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]),
              !store.isFull, let index = compartment(at: s) else { return }
        if !doors[index].interactive && !doors[index].driver.isHeld {
            doors[index].driver.swing(to: FridgeView.swingOpenAngle)
        }
        setItemDrag(true, alsoDoor: index)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if (sender.draggingSource as AnyObject?) === self { return [] }
        if NSEvent.modifierFlags.contains(.shift) { return stickTarget(for: sender) == nil ? [] : .copy }
        springOpen(for: sender)
        return dropShelf(for: sender) == nil ? [] : .move
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if (sender.draggingSource as AnyObject?) === self { return [] }
        if NSEvent.modifierFlags.contains(.shift) { return stickTarget(for: sender) == nil ? [] : .copy }
        springOpen(for: sender)
        return dropShelf(for: sender) == nil ? [] : .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        setItemDrag(false)
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        setItemDrag(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if (sender.draggingSource as AnyObject?) === self { return false }
        if NSEvent.modifierFlags.contains(.shift) { return stickOnDoor(sender) }
        guard let shelf = dropShelf(for: sender),
              let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                                options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return false }

        for url in urls {
            finder.desktopPosition(of: url) { [weak self] position in
                guard let self = self else { return }
                do {
                    let entry = try self.store.store(fileAt: url, desktopPosition: position, preferredShelf: shelf)
                    self.items.add(entry)
                } catch {
                    NSSound.beep()
                }
            }
        }
        return true
    }

    // MARK: Sticky notes and photo magnets (⇧)

    /// A shut door under a scene point. Notes are on the front face, which only faces the user
    /// while the door is (nearly) closed.
    private func shutDoor(at s: CGPoint) -> Int? {
        guard let index = doorIndex(at: s), doors[index].angle < Geo.openedAngle else { return nil }
        return index
    }

    private func noteHit(at s: CGPoint) -> (door: Int, note: DoorNote)? {
        guard let index = shutDoor(at: s) else { return nil }
        let spec = doors[index].spec
        guard let note = notes.hit(door: spec.name, point: Geo.doorPoint(underScene: s, door: spec)) else { return nil }
        return (index, note)
    }

    /// ⇧-click a shut door for a new note, ⇧-click a note to change its color, ⇧-drag to move it,
    /// double-click a note to write on it. Returns true when the click was about notes.
    private func notesMouseDown(_ event: NSEvent, at s: CGPoint) -> Bool {
        guard let index = shutDoor(at: s) else { return false }
        let spec = doors[index].spec
        let p = Geo.doorPoint(underScene: s, door: spec)
        let shift = event.modifierFlags.contains(.shift)
        if let note = notes.hit(door: spec.name, point: p) {
            if shift {
                let grab = CGPoint(x: p.x - CGFloat(note.x), y: p.y - CGFloat(note.y))
                interaction = .notePress(id: note.id, door: index, grab: grab, start: NSEvent.mouseLocation, moved: false)
                NSCursor.closedHand.set()
                return true
            }
            if event.clickCount == 2 && note.kind == .note {
                notes.beginEditing(note.id)
                interaction = .none
                return true
            }
            return false   // a plain grab on a note still works the door
        }
        if shift && event.clickCount == 1 {
            notes.addNote(on: spec, at: p)
            interaction = .none
            return true
        }
        return false
    }

    private func addNoteMenuItems(_ note: DoorNote, to menu: NSMenu) {
        let id = note.id
        if note.kind == .note {
            menu.addItem(ActionMenuItem("Edit Note") { [weak self] in self?.notes.beginEditing(id) })
            let colors = NSMenuItem(title: "Color", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for (index, c) in NoteArt.palette.enumerated() {
                let item = ActionMenuItem(c.name) { [weak self] in self?.notes.setColor(id, index) }
                item.state = index == note.color ? .on : .off
                sub.addItem(item)
            }
            colors.submenu = sub
            menu.addItem(colors)
            menu.addItem(ActionMenuItem("Peel Off Note") { [weak self] in self?.notes.remove(id) })
        } else {
            if let path = note.originalPath, FileManager.default.fileExists(atPath: path) {
                menu.addItem(ActionMenuItem("Open Original") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) })
            }
            menu.addItem(ActionMenuItem("Take Photo Down") { [weak self] in self?.notes.remove(id) })
        }
    }

    private static func isImage(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image)
    }

    /// With ⇧ held, pictures and text dragged onto a shut door get stuck on it instead of going inside.
    private func stickTarget(for sender: NSDraggingInfo) -> (door: Int, point: CGPoint)? {
        let s = Geo.scenePoint(fromView: convert(sender.draggingLocation, from: nil))
        guard let index = shutDoor(at: s), !notes.store.isFull(door: doors[index].spec.name) else { return nil }
        let pb = sender.draggingPasteboard
        let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        let hasImage = urls.contains(where: FridgeView.isImage)
        let hasText = urls.isEmpty && !(pb.string(forType: .string) ?? "").isEmpty
        guard hasImage || hasText else { return nil }
        return (index, Geo.doorPoint(underScene: s, door: doors[index].spec))
    }

    private func stickOnDoor(_ sender: NSDraggingInfo) -> Bool {
        guard let target = stickTarget(for: sender) else { return false }
        let spec = doors[target.door].spec
        let pb = sender.draggingPasteboard
        let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        let images = urls.filter(FridgeView.isImage)
        if !images.isEmpty {
            var placed = false
            for (offset, url) in images.prefix(4).enumerated() {
                // Several at once fan out a little instead of stacking exactly.
                let p = CGPoint(x: target.point.x + CGFloat(offset) * 14, y: target.point.y - CGFloat(offset) * 10)
                placed = notes.addPhoto(from: url, on: spec, at: p) || placed
            }
            return placed
        }
        if let text = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            notes.addNote(on: spec, at: target.point, text: text, edit: false)
            return true
        }
        return false
    }
}

/// Menu item that runs a closure, so menus need no target and action plumbing.
final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) {
        fatalError("not used")
    }

    @objc private func fire() {
        handler()
    }
}
