import AppKit
import QuartzCore

/// The vending machine on the desktop. Layer-hosting: all art is cached in layers, and the display
/// link only runs while something moves.
final class VendingView: NSView {
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
    private var labelLayers: [CATextLayer] = []
    private var keyLayers: [CALayer] = []
    private var renderedScale: CGFloat = 0
    private var displayLines = ["PICK ONE", ""]

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

    init() {
        let scale = VendingView.savedScale
        super.init(frame: CGRect(origin: .zero, size: CGSize(width: Geo.size.width * scale, height: Geo.size.height * scale)))
        userScale = scale
        layer = CALayer()
        wantsLayer = true
        buildLayers()
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

            let label = CATextLayer()
            label.frame = Geo.labelRect(i).insetBy(dx: 1.5, dy: 0)
            label.truncationMode = .end
            label.isWrapped = false
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
                  flapHolder, flapLayer, panelLayer, displayLayer] + coilBackLayers + coilFrontLayers + keyLayers {
            l.actions = Self.still
        }
        for l in labelLayers { l.actions = Self.still.merging(["string": NSNull()]) { a, _ in a } }
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
        CATransaction.commit()
        refreshLabels()
        showDisplay(displayLines)
    }

    // MARK: Labels and display

    /// Each shelf label shows its code and, if the coil holds a file, the start of its name.
    func refreshLabels() {
        let codeFont = NSFont.systemFont(ofSize: 6.2, weight: .heavy)
        let nameFont = NSFont.systemFont(ofSize: 6.2, weight: .medium)
        let ink = NSColor(cgColor: Paint.hex(0x2B2A27))!
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (i, l) in labelLayers.enumerated() {
            let s = NSMutableAttributedString(string: Geo.code(i), attributes: [.font: codeFont, .foregroundColor: ink])
            if let name = name(at: i) {
                s.append(NSAttributedString(string: " " + name, attributes: [.font: nameFont, .foregroundColor: ink]))
            }
            l.string = s
        }
        CATransaction.commit()
    }

    /// The name of the file in a coil, if any.
    func name(at index: Int) -> String? { nil }

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
}
