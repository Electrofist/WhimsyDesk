import AppKit

private typealias DC = DrawerController

/// Light mode: weathered oak front, birch box, green baize, brushed nickel cup pull.
/// Dark mode: old walnut front, walnut box, charcoal felt, aged brass cup pull.
private struct Theme {
    let front: Wood
    let box: Wood
    let felt: UInt32
    let metal: [UInt32]          // cylinder shading, top → bottom
    let dust: UInt32
    let label: CGFloat           // label text alpha

    static let light = Theme(front: Material.oak, box: Material.birch, felt: 0x2F4A3B,
                             metal: [0x54585A, 0x8F9496, 0xF4F6F6, 0xB4B8BA, 0x4A4D4F], dust: 0xE6E0D3, label: 0.95)
    static let dark = Theme(front: Material.walnut, box: Material.walnutPly, felt: 0x2A2A2D,
                            metal: [0x4A3510, 0x9C7A34, 0xF3D892, 0xC09A4C, 0x3E2C0E], dust: 0xB9B1A2, label: 0.88)
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

    // Geometry (flipped, top-left origin).
    static let faceRect = NSRect(x: DC.margin, y: DC.topPad, width: DC.width, height: DC.faceHeight)
    static let boxRect = NSRect(x: DC.margin + DC.boxInset, y: DC.topPad + DC.faceHeight - 8,
                                width: DC.width - DC.boxInset * 2, height: DC.interiorHeight + 8)
    private static let wallTop: CGFloat = 5          // visible top edge of the side and back boards
    private static let floorTop = faceRect.maxY
    private static let floorBottom = boxRect.maxY - wallTop - 5

    /// The felt floor, narrowing slightly towards the back so the side walls read with perspective.
    private static let floorPath: NSBezierPath = {
        let b = boxRect, t = wallTop
        let p = NSBezierPath()
        p.move(to: NSPoint(x: b.minX + t + 9, y: floorTop))
        p.line(to: NSPoint(x: b.maxX - t - 9, y: floorTop))
        p.line(to: NSPoint(x: b.maxX - t - 5, y: floorBottom))
        p.line(to: NSPoint(x: b.minX + t + 5, y: floorBottom))
        p.close()
        return p
    }()

    init(store: DrawerStore) {
        self.store = store
        super.init(frame: NSRect(x: 0, y: 0, width: DC.viewWidth, height: DC.viewHeight))
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
        controller?.contentsChanged()
    }

    private func syncDrag() { controller?.dragInProgress = outgoingDrag || incomingDrag }

    // MARK: Layout

    private func relayout() {
        let count = store.items.count
        // One row up to 8, then two balanced rows; the step shrinks (items overlap) when crowded.
        let perRow = count <= 8 ? 8 : max(5, Int((Double(count) / 2).rounded(.up)))
        let box = Self.boxRect
        let areaX = box.minX + 28, labelW: CGFloat = 76
        let step = min(80, (box.width - 56 - labelW) / CGFloat(perRow - 1))
        iconRects = []
        labelRects = []
        for i in 0..<count {
            let row = CGFloat(i / perRow), col = CGFloat(i % perRow)
            let cx = areaX + labelW / 2 + col * step
            let top = Self.floorTop + 26 + row * 92
            iconRects.append(NSRect(x: cx - iconSize / 2, y: top, width: iconSize, height: iconSize))
            labelRects.append(NSRect(x: cx - labelW / 2, y: top + iconSize + 5, width: labelW, height: 16))
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
    private var scale: CGFloat { window?.backingScaleFactor ?? 2 }
    private var px: CGFloat { 1 / scale }

    private func render() {
        let theme = isDark ? Theme.dark : Theme.light
        drawBox(theme)
        drawFloor(theme)
        if store.items.isEmpty { drawEmptyHint() }
        drawItems(theme)
        drawFace(theme)
    }

    // MARK: Box (side walls, back wall)

    private func drawBox(_ theme: Theme) {
        let b = Self.boxRect, t = Self.wallTop
        Material.wood(theme.box, size: b.size, scale: scale, seed: 3, worn: false).draw(in: b)

        // Top edges of the boards catch the light.
        NSColor.white.withAlphaComponent(0.10).setFill()
        NSBezierPath(rect: b).fill()

        // Inner faces of the walls: in shade, darker the deeper they go.
        let left = NSBezierPath()
        left.move(to: NSPoint(x: b.minX + t, y: b.minY))
        left.line(to: NSPoint(x: b.minX + t + 9, y: b.minY))
        left.line(to: NSPoint(x: b.minX + t + 5, y: Self.floorBottom))
        left.line(to: NSPoint(x: b.minX + t, y: b.maxY - t))
        left.close()
        let right = NSBezierPath()
        right.move(to: NSPoint(x: b.maxX - t, y: b.minY))
        right.line(to: NSPoint(x: b.maxX - t - 9, y: b.minY))
        right.line(to: NSPoint(x: b.maxX - t - 5, y: Self.floorBottom))
        right.line(to: NSPoint(x: b.maxX - t, y: b.maxY - t))
        right.close()
        let back = NSBezierPath()
        back.move(to: NSPoint(x: b.minX + t, y: b.maxY - t))
        back.line(to: NSPoint(x: b.maxX - t, y: b.maxY - t))
        back.line(to: NSPoint(x: b.maxX - t - 5, y: Self.floorBottom))
        back.line(to: NSPoint(x: b.minX + t + 5, y: Self.floorBottom))
        back.close()

        NSColor.black.withAlphaComponent(0.42).setFill(); left.fill()
        NSColor.black.withAlphaComponent(0.30).setFill(); right.fill()
        NSColor.black.withAlphaComponent(0.12).setFill(); back.fill()

        // Arrises: a bright line where each board's top meets its inner face, a dark line on the outside.
        NSColor.white.withAlphaComponent(0.28).setStroke()
        let arris = NSBezierPath()
        arris.move(to: NSPoint(x: b.minX + t, y: b.minY))
        arris.line(to: NSPoint(x: b.minX + t, y: b.maxY - t))
        arris.line(to: NSPoint(x: b.maxX - t, y: b.maxY - t))
        arris.line(to: NSPoint(x: b.maxX - t, y: b.minY))
        arris.lineWidth = px
        arris.stroke()
        NSColor.black.withAlphaComponent(0.45).setStroke()
        let outer = NSBezierPath(rect: b.insetBy(dx: px / 2, dy: px / 2))
        outer.lineWidth = px
        outer.stroke()
    }

    // MARK: Floor (felt liner, light, occlusion, dust)

    private func drawFloor(_ theme: Theme) {
        let floor = Self.floorPath, fb = floor.bounds
        NSGraphicsContext.saveGraphicsState()
        floor.addClip()
        Material.felt(theme.felt, size: fb.size, scale: scale).draw(in: fb)

        // Soft pool of light from above the desk, falling off towards the walls.
        NSGradient(starting: NSColor.white.withAlphaComponent(isDark ? 0.07 : 0.09), ending: .clear)?
            .draw(fromCenter: NSPoint(x: fb.midX, y: fb.midY + 10), radius: 0,
                  toCenter: NSPoint(x: fb.midX, y: fb.midY + 10), radius: fb.width * 0.55, options: [])

        // Ambient occlusion along the walls and in the corners.
        edgeShade(fb, edge: .minX, depth: 22, alpha: 0.40)
        edgeShade(fb, edge: .maxX, depth: 22, alpha: 0.40)
        edgeShade(fb, edge: .maxY, depth: 18, alpha: 0.32)
        // The front panel overhangs the near end of the drawer, so that end is in deep shade.
        edgeShade(fb, edge: .minY, depth: 54, alpha: 0.75)
        for corner in [NSPoint(x: fb.minX, y: fb.maxY), NSPoint(x: fb.maxX, y: fb.maxY),
                       NSPoint(x: fb.minX, y: fb.minY), NSPoint(x: fb.maxX, y: fb.minY)] {
            NSGradient(starting: NSColor.black.withAlphaComponent(0.30), ending: .clear)?
                .draw(fromCenter: corner, radius: 0, toCenter: corner, radius: 34, options: [])
        }

        drawDust(in: fb, theme)
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawDust(in fb: NSRect, _ theme: Theme) {
        var rng = RNG(41)
        let corners = [NSPoint(x: fb.minX, y: fb.maxY), NSPoint(x: fb.maxX, y: fb.maxY),
                       NSPoint(x: fb.minX, y: fb.minY + 30), NSPoint(x: fb.maxX, y: fb.minY + 30)]
        for c in corners {                                   // faint haze that collects in the corners
            NSGradient(starting: nsrgb(theme.dust, 0.07), ending: .clear)?
                .draw(fromCenter: c, radius: 0, toCenter: c, radius: 26, options: [])
        }
        for _ in 0..<260 {                                   // specks and lint, mostly near the walls
            let c = corners[Int(rng.next() * 4)]
            let along = rng.next() < 0.35
            let dx = along ? rng.range(0, fb.width * 0.5) : pow(rng.next(), 2.2) * 40
            let dy = along ? pow(rng.next(), 2.5) * 8 : pow(rng.next(), 2.2) * 34
            let x = c.x < fb.midX ? c.x + dx : c.x - dx
            let y = c.y > fb.midY ? c.y - dy : c.y + dy
            let r = rng.range(0.3, 1.1)
            nsrgb(theme.dust, rng.range(0.10, 0.38)).setFill()
            NSBezierPath(ovalIn: NSRect(x: x, y: y, width: r * rng.range(1, 2.2), height: r)).fill()
        }
        nsrgb(theme.dust, 0.22).setStroke()                  // a couple of stray fibres
        for _ in 0..<7 {
            let x = rng.range(fb.minX + 30, fb.maxX - 30), y = rng.range(fb.minY + 50, fb.maxY - 8)
            let fibre = NSBezierPath()
            fibre.move(to: NSPoint(x: x, y: y))
            fibre.curve(to: NSPoint(x: x + rng.range(-9, 9), y: y + rng.range(-5, 5)),
                        controlPoint1: NSPoint(x: x + rng.range(-6, 6), y: y + rng.range(-6, 6)),
                        controlPoint2: NSPoint(x: x + rng.range(-6, 6), y: y + rng.range(-6, 6)))
            fibre.lineWidth = 0.4
            fibre.stroke()
        }
    }

    private func drawEmptyHint() {
        // Pressed into the felt: dark text with a faint lower highlight.
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.white.withAlphaComponent(0.09)
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.shadowBlurRadius = 0
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.black.withAlphaComponent(0.38),
            .shadow: shadow,
        ]
        let text = "Drop files and folders here" as NSString
        let size = text.size(withAttributes: attrs)
        text.draw(at: NSPoint(x: Self.faceRect.midX - size.width / 2, y: Self.floorTop + 92), withAttributes: attrs)
    }

    private func drawItems(_ theme: Theme) {
        guard iconRects.count == store.items.count else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingMiddle
        let textShadow = NSShadow()
        textShadow.shadowColor = NSColor.black.withAlphaComponent(0.9)
        textShadow.shadowOffset = NSSize(width: 0, height: -0.5)
        textShadow.shadowBlurRadius = 2
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(theme.label),
            .paragraphStyle: paragraph,
            .shadow: textShadow,
        ]

        for (i, item) in store.items.enumerated() {
            let r = iconRects[i]
            let alpha: CGFloat = liftedIndex == i ? 0.3 : 1

            // Ambient occlusion where the item rests on the felt.
            let contact = NSRect(x: r.minX + 6, y: r.maxY - 8, width: r.width - 12, height: 10)
            NSGradient(starting: NSColor.black.withAlphaComponent(0.45 * alpha), ending: .clear)?
                .draw(in: NSBezierPath(ovalIn: contact), relativeCenterPosition: .zero)

            // Items lie slightly askew, as if tossed in.
            let tilt = CGFloat(sin(Double(i) * 12.9898 + 1.7)) * 3.5
            let t = NSAffineTransform()
            t.translateX(by: r.midX, yBy: r.midY)
            t.rotate(byDegrees: tilt)
            t.translateX(by: -r.midX, yBy: -r.midY)
            NSGraphicsContext.saveGraphicsState()
            t.concat()
            let shadow = NSShadow()                          // soft shadow shaped like the icon itself
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.55 * alpha)
            shadow.shadowOffset = NSSize(width: 0.5, height: -2.5)
            shadow.shadowBlurRadius = 3.5
            shadow.set()
            item.icon.draw(in: r, from: .zero, operation: .sourceOver, fraction: alpha, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()

            (item.name as NSString).draw(in: labelRects[i], withAttributes: attrs)
        }
    }

    // MARK: Front panel

    private func drawFace(_ theme: Theme) {
        let f = Self.faceRect, edge: CGFloat = 5
        let body = NSBezierPath(roundedRect: f, xRadius: 4, yRadius: 4)

        // Weight: the panel throws a soft shadow down onto the box.
        NSGraphicsContext.saveGraphicsState()
        let drop = NSShadow()
        drop.shadowColor = NSColor.black.withAlphaComponent(0.6)
        drop.shadowOffset = NSSize(width: 0, height: -6)
        drop.shadowBlurRadius = 12
        drop.set()
        NSColor.black.setFill()
        body.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        body.addClip()
        Material.wood(theme.front, size: f.size, scale: scale, seed: 11, worn: true).draw(in: f)

        // Top of the board: faces the light, so it reads brighter than the front.
        let top = NSRect(x: f.minX, y: f.minY, width: f.width, height: edge)
        NSColor.white.withAlphaComponent(isDark ? 0.13 : 0.20).setFill()
        NSBezierPath(rect: top).fill()
        let front = NSRect(x: f.minX, y: top.maxY, width: f.width, height: f.height - edge)
        NSGradient(colorsAndLocations: (NSColor.white.withAlphaComponent(0.06), 0), (.clear, 0.35),
                   (NSColor.black.withAlphaComponent(isDark ? 0.30 : 0.24), 1))?.draw(in: front, angle: 90)

        // Arris between the top and the front.
        NSColor.black.withAlphaComponent(0.30).setFill()
        NSBezierPath(rect: NSRect(x: f.minX, y: front.minY, width: f.width, height: px)).fill()
        NSColor.white.withAlphaComponent(isDark ? 0.18 : 0.30).setFill()
        NSBezierPath(rect: NSRect(x: f.minX, y: f.minY, width: f.width, height: px)).fill()

        // A faint satin sheen across the varnish.
        NSGradient(colors: [.clear, NSColor.white.withAlphaComponent(isDark ? 0.06 : 0.08), .clear],
                   atLocations: [0.28, 0.45, 0.62], colorSpace: .sRGB)?.draw(in: front, angle: -8)

        // Eased edges: lit on the left, shaded on the right and underneath.
        NSGradient(starting: NSColor.white.withAlphaComponent(0.16), ending: .clear)?
            .draw(from: NSPoint(x: f.minX, y: 0), to: NSPoint(x: f.minX + 4, y: 0), options: [])
        NSGradient(starting: NSColor.black.withAlphaComponent(0.30), ending: .clear)?
            .draw(from: NSPoint(x: f.maxX, y: 0), to: NSPoint(x: f.maxX - 4, y: 0), options: [])
        NSGradient(starting: NSColor.black.withAlphaComponent(0.55), ending: .clear)?
            .draw(from: NSPoint(x: 0, y: f.maxY), to: NSPoint(x: 0, y: f.maxY - 4), options: [])

        // Years of hands have darkened the wood around the pull.
        let pull = NSPoint(x: f.midX, y: front.minY + 17)
        NSGraphicsContext.saveGraphicsState()
        let squash = NSAffineTransform()
        squash.translateX(by: pull.x, yBy: pull.y)
        squash.scaleX(by: 1, yBy: 0.42)
        squash.translateX(by: -pull.x, yBy: -pull.y)
        squash.concat()
        NSGradient(starting: NSColor.black.withAlphaComponent(isDark ? 0.18 : 0.14), ending: .clear)?
            .draw(fromCenter: pull, radius: 0, toCenter: pull, radius: 90, options: [])
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.restoreGraphicsState()

        NSColor.black.withAlphaComponent(0.5).setStroke()
        let rim = NSBezierPath(roundedRect: f.insetBy(dx: px / 2, dy: px / 2), xRadius: 4, yRadius: 4)
        rim.lineWidth = px
        rim.stroke()

        drawCupPull(at: NSPoint(x: f.midX, y: front.minY + 9), theme)
    }

    /// A classic bin (cup) pull: a mounting plate with two screws and a hooded cup below it.
    private func drawCupPull(at p: NSPoint, _ theme: Theme) {
        let plate = NSRect(x: p.x - 56, y: p.y, width: 112, height: 9)
        let platePath = NSBezierPath(roundedRect: plate, xRadius: 3, yRadius: 3)
        let hoodW: CGFloat = 94, hoodH: CGFloat = 21, hoodTop = plate.maxY - 1.5
        let lip = NSBezierPath()
        lip.move(to: NSPoint(x: p.x - hoodW / 2, y: hoodTop))
        lip.curve(to: NSPoint(x: p.x + hoodW / 2, y: hoodTop),
                  controlPoint1: NSPoint(x: p.x - hoodW / 2 + 3, y: hoodTop + hoodH * 1.33),
                  controlPoint2: NSPoint(x: p.x + hoodW / 2 - 3, y: hoodTop + hoodH * 1.33))
        let hood = lip.copy() as! NSBezierPath
        hood.close()

        // Shadows on the wood: the cup stands proud of the panel, the plate sits nearly flush.
        shadowed(offset: NSSize(width: 0, height: -7), blur: 6, alpha: 0.6) { NSColor.black.setFill(); hood.fill() }
        shadowed(offset: NSSize(width: 0, height: -1.5), blur: 2, alpha: 0.55) { NSColor.black.setFill(); platePath.fill() }

        let stops = theme.metal.map { nsrgb($0) }
        // Cup: curved surface, dark just under the plate, a bright band, then the lip falls away.
        NSGraphicsContext.saveGraphicsState()
        hood.addClip()
        NSGradient(colors: stops, atLocations: [0, 0.22, 0.48, 0.72, 1], colorSpace: .sRGB)?
            .draw(from: NSPoint(x: 0, y: hoodTop), to: NSPoint(x: 0, y: hoodTop + hoodH), options: [])
        NSGradient(colorsAndLocations: (NSColor.black.withAlphaComponent(0.45), 0), (.clear, 0.22),
                   (.clear, 0.78), (NSColor.black.withAlphaComponent(0.45), 1))?
            .draw(from: NSPoint(x: p.x - hoodW / 2, y: 0), to: NSPoint(x: p.x + hoodW / 2, y: 0), options: [])
        NSColor.white.withAlphaComponent(0.05).setStroke()     // brushed finish
        var rng = RNG(17)
        for _ in 0..<26 {
            let y = rng.range(hoodTop, hoodTop + hoodH)
            let hair = NSBezierPath()
            hair.move(to: NSPoint(x: p.x - hoodW / 2, y: y))
            hair.line(to: NSPoint(x: p.x + hoodW / 2, y: y + rng.range(-0.4, 0.4)))
            hair.lineWidth = 0.4
            hair.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
        NSColor.white.withAlphaComponent(0.45).setStroke()     // rolled lip catches the light
        lip.lineWidth = 0.8
        lip.stroke()
        NSColor.black.withAlphaComponent(0.4).setStroke()
        hood.lineWidth = px
        hood.stroke()

        // Plate.
        NSGraphicsContext.saveGraphicsState()
        platePath.addClip()
        NSGradient(colors: [stops[2], stops[3], stops[1], stops[4]], atLocations: [0, 0.35, 0.7, 1], colorSpace: .sRGB)?
            .draw(from: NSPoint(x: 0, y: plate.minY), to: NSPoint(x: 0, y: plate.maxY), options: [])
        NSGraphicsContext.restoreGraphicsState()
        NSColor.black.withAlphaComponent(0.45).setStroke()
        platePath.lineWidth = px
        platePath.stroke()

        // Screws, slots at different angles.
        for (x, angle) in [(plate.minX + 7, 0.6), (plate.maxX - 7, -0.25)] as [(CGFloat, CGFloat)] {
            let head = NSRect(x: x - 2.7, y: plate.midY - 2.7, width: 5.4, height: 5.4)
            NSGradient(starting: stops[2], ending: stops[4])?.draw(in: NSBezierPath(ovalIn: head), angle: 90)
            NSColor.black.withAlphaComponent(0.5).setStroke()
            let ring = NSBezierPath(ovalIn: head)
            ring.lineWidth = px
            ring.stroke()
            let slot = NSBezierPath()
            slot.move(to: NSPoint(x: head.midX - cos(angle) * 2.2, y: head.midY - sin(angle) * 2.2))
            slot.line(to: NSPoint(x: head.midX + cos(angle) * 2.2, y: head.midY + sin(angle) * 2.2))
            NSColor.black.withAlphaComponent(0.65).setStroke()
            slot.lineWidth = 0.8
            slot.stroke()
        }
    }

    // MARK: Drawing helpers

    private enum Edge { case minX, maxX, minY, maxY }

    private func edgeShade(_ r: NSRect, edge: Edge, depth: CGFloat, alpha: CGFloat) {
        let (a, b): (NSPoint, NSPoint)
        switch edge {
        case .minX: (a, b) = (NSPoint(x: r.minX, y: 0), NSPoint(x: r.minX + depth, y: 0))
        case .maxX: (a, b) = (NSPoint(x: r.maxX, y: 0), NSPoint(x: r.maxX - depth, y: 0))
        case .minY: (a, b) = (NSPoint(x: 0, y: r.minY), NSPoint(x: 0, y: r.minY + depth))
        case .maxY: (a, b) = (NSPoint(x: 0, y: r.maxY), NSPoint(x: 0, y: r.maxY - depth))
        }
        NSGradient(colorsAndLocations: (NSColor.black.withAlphaComponent(alpha), 0),
                   (NSColor.black.withAlphaComponent(alpha * 0.3), 0.4), (.clear, 1))?.draw(from: a, to: b, options: [])
    }

    private func shadowed(offset: NSSize, blur: CGFloat, alpha: CGFloat, _ body: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        let s = NSShadow()
        s.shadowColor = NSColor.black.withAlphaComponent(alpha)
        s.shadowOffset = offset
        s.shadowBlurRadius = blur
        s.set()
        body()
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: Cursor: an open hand over the front panel says "you can pull this"

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: Self.faceRect, options: [.mouseEnteredAndExited, .activeAlways],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { if !grabbing { NSCursor.openHand.set() } }
    override func mouseExited(with event: NSEvent) { if !grabbing { NSCursor.arrow.set() } }

    // MARK: Mouse: grab the face to slide, drag items out

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if Self.faceRect.contains(p) {
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
            controller?.grab(mouseY: NSEvent.mouseLocation.y)
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
        controller?.endGrab()
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
        menu.autoenablesItems = false
        if controller?.isInteractive == true, let i = itemIndex(at: p) {
            let name = store.items[i].name
            menu.addItem(menuItem("Put Back on Desktop", #selector(putBackOne(_:)), name))
            menu.addItem(menuItem("Show in Finder", #selector(revealOne(_:)), name))
            menu.addItem(.separator())
        }
        menu.addItem(menuItem("Put Everything Back", #selector(putBackAll)))
        menu.addItem(menuItem("Open Drawer Folder", #selector(openFolder)))
        menu.addItem(.separator())
        let moveAll = menuItem("Move Everything to Desktop", #selector(moveAllToDesktop))
        moveAll.isEnabled = !store.items.isEmpty
        menu.addItem(moveAll)
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

    @objc private func moveAllToDesktop() {
        let count = store.items.count
        guard count > 0 else { return }
        let alert = NSAlert()
        alert.messageText = "Move everything to your Desktop?"
        alert.informativeText = (count == 1 ? "The file in the drawer goes back onto your Desktop." : "All \(count) files in the drawer go back onto your Desktop.")
        alert.addButton(withTitle: "Move to Desktop")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.moveAllToDesktop { [weak self] failed in
            self?.refresh()
            guard failed > 0 else { return }
            let notice = NSAlert()
            notice.messageText = failed == 1 ? "1 file could not be moved." : "\(failed) files could not be moved."
            notice.informativeText = "They are still in the drawer."
            notice.runModal()
        }
    }

    @objc private func openFolder() { NSWorkspace.shared.open(store.folderURL) }
}
