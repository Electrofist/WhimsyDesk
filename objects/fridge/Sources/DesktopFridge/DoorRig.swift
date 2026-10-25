import AppKit

/// One door: its 3D layers (front, liner, free edge, bins), its own physics driver, and the darkness
/// and cold light of the compartment behind it. The fridge has two of these, freezer and fridge,
/// and each swings on its own.
final class DoorRig {
    let spec: DoorSpec
    let driver: DoorDriver

    private let root = CATransformLayer()
    private let front = CALayer()
    private let back = CALayer()
    private let edge = CAGradientLayer()
    private let frontShade = CAShapeLayer()
    private let backShade = CAShapeLayer()
    /// Darkness and light for the compartment behind this door. They live in the flat body layer.
    let darkness = CALayer()
    let glow = CAGradientLayer()

    /// True once the door has passed the "opened" angle, until it seals again.
    var hasOpened = false
    /// True while the door is open far enough for its shelves to be used.
    var interactive = false

    init(spec: DoorSpec, view: NSView) {
        self.spec = spec
        driver = DoorDriver(view: view)
    }

    var angle: Double { return driver.angle }

    // MARK: Layers

    func build(scene: CALayer, body: CALayer) {
        let size = spec.size
        let bounds = CGRect(origin: .zero, size: size)

        // Compartment darkness and glow, clipped to the slice of the opening behind this door.
        let slice = spec.openingSlice.offsetBy(dx: Geo.opening.minX, dy: Geo.opening.minY)
        darkness.frame = slice
        darkness.backgroundColor = CGColor(gray: 0, alpha: 1)
        glow.frame = slice
        glow.type = .radial
        glow.startPoint = CGPoint(x: 0.5, y: 0.82)
        glow.endPoint = CGPoint(x: 1.15, y: 0.0)
        body.addSublayer(darkness)
        body.addSublayer(glow)

        // Door: a transform layer so its faces and edge keep their own 3D positions.
        root.bounds = bounds
        root.anchorPoint = CGPoint(x: 0, y: 0.5)
        root.position = CGPoint(x: spec.frame.minX, y: spec.frame.midY)
        // Lift the whole door so its back face sits just in front of the cabinet plane.
        root.zPosition = Geo.doorHalfThickness + 0.5
        scene.addSublayer(root)

        front.frame = bounds
        front.zPosition = Geo.doorHalfThickness
        front.isDoubleSided = false
        root.addSublayer(front)

        back.frame = bounds
        back.zPosition = -Geo.doorHalfThickness
        back.transform = CATransform3DMakeRotation(.pi, 0, 1, 0)
        back.isDoubleSided = false
        root.addSublayer(back)

        // The free edge is the door's thickness, seen face-on once the door stands open. It stops
        // short of the rounded outer corners and runs flush where the two doors meet.
        let topInset: CGFloat = spec.roundTop ? Geo.doorCornerRadius * 0.5 : 1
        let bottomInset: CGFloat = spec.roundBottom ? Geo.doorCornerRadius * 0.5 : 1
        edge.bounds = CGRect(x: 0, y: 0, width: Geo.doorHalfThickness * 2, height: size.height - topInset - bottomInset)
        edge.position = CGPoint(x: size.width - 2, y: bottomInset + (size.height - topInset - bottomInset) / 2)
        edge.transform = CATransform3DMakeRotation(.pi / 2, 0, 1, 0)
        edge.cornerRadius = Geo.doorHalfThickness * 0.8
        edge.masksToBounds = true
        // Painted steel rounding over from the front face, then the dark magnetic gasket on the liner side.
        edge.colors = [Art.hex(0x505006), Art.hex(0x9DA716), Art.hex(0xE4E57A), Art.hex(0xB6BD21),
                       Art.hex(0x7D8202), Art.hex(0x2B2E2A), Art.hex(0x3A3D38)]
        edge.locations = [0, 0.10, 0.28, 0.55, 0.72, 0.76, 1]
        edge.startPoint = CGPoint(x: 0, y: 0.5)
        edge.endPoint = CGPoint(x: 1, y: 0.5)
        // Single sided, facing out of the free edge: it shows whenever the door is open.
        edge.isDoubleSided = false
        root.addSublayer(edge)

        buildBins()

        for (shade, face) in [(frontShade, front), (backShade, back)] {
            shade.frame = bounds
            shade.path = spec.outline(in: bounds, radius: Geo.doorCornerRadius)
            shade.fillColor = CGColor(gray: 0, alpha: 1)
            shade.opacity = 0
            face.addSublayer(shade)
        }
    }

    /// Door bins as real 3D trays standing out of the liner: a floor that sticks out toward the
    /// cabinet and a clear front lip. They swing with the door, and the depth test tucks them inside
    /// the cabinet when it is shut.
    private func buildBins() {
        let linerZ = -Geo.doorHalfThickness
        let width = spec.size.width - 2 * Geo.binInset
        let midX = spec.size.width / 2
        for (index, y) in spec.binY.enumerated() {
            let depth = Geo.binDepth
            // The lowest fridge bin is the bottle rack, a little taller.
            let lipHeight = (index == 0 && spec.binY.count > 1) ? Geo.binLipHeight + 8 : Geo.binLipHeight

            let floor = CALayer()
            floor.bounds = CGRect(x: 0, y: 0, width: width, height: depth)
            floor.position = CGPoint(x: midX, y: y)
            floor.zPosition = linerZ - depth / 2
            floor.transform = CATransform3DMakeRotation(.pi / 2, 1, 0, 0)
            floor.backgroundColor = Art.color(0.86, 0.93, 0.96, 0.95)
            floor.borderColor = Art.color(1, 1, 1, 0.8)
            floor.borderWidth = 1
            floor.isDoubleSided = true
            root.addSublayer(floor)

            let lip = CAGradientLayer()
            lip.bounds = CGRect(x: 0, y: 0, width: width, height: lipHeight)
            lip.position = CGPoint(x: midX, y: y + lipHeight / 2)
            lip.zPosition = linerZ - depth
            lip.transform = CATransform3DMakeRotation(.pi, 0, 1, 0)
            lip.colors = [Art.color(0.97, 0.99, 1, 0.96), Art.color(0.80, 0.90, 0.95, 0.90), Art.color(0.66, 0.80, 0.88, 0.92)]
            lip.locations = [0, 0.55, 1]
            lip.cornerRadius = 3
            lip.borderColor = Art.color(1, 1, 1, 0.9)
            lip.borderWidth = 1
            lip.isDoubleSided = true
            root.addSublayer(lip)

            // Side cheeks close the tray at both ends.
            for x in [Geo.binInset, spec.size.width - Geo.binInset] {
                let cheek = CALayer()
                cheek.bounds = CGRect(x: 0, y: 0, width: depth, height: lipHeight)
                cheek.position = CGPoint(x: x, y: y + lipHeight / 2)
                cheek.zPosition = linerZ - depth / 2
                cheek.transform = CATransform3DMakeRotation(.pi / 2, 0, 1, 0)
                cheek.backgroundColor = Art.color(0.78, 0.88, 0.93, 0.92)
                cheek.isDoubleSided = true
                root.addSublayer(cheek)
            }
        }
    }

    func render(scale: CGFloat) {
        front.contents = FridgeArt.doorFront(spec, scale: scale)
        back.contents = FridgeArt.doorBack(spec, scale: scale)
        for l in [front, back, frontShade, backShade] { l.contentsScale = scale }
    }

    func setLighting(glowColors: [CGColor]) {
        glow.colors = glowColors
    }

    // MARK: Drawing a frame

    private func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = min(max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// Positions the door and the compartment light for `angle`. Runs inside the caller's transaction.
    func apply(angle: Double, darknessPeak: Float) {
        let c = cos(angle)
        let light = smoothstep(3 * Double.pi / 180, 28 * Double.pi / 180, angle)
        root.transform = CATransform3DMakeRotation(-CGFloat(angle), 0, 1, 0)
        frontShade.opacity = Float(max(0, 1 - c) * 0.40)
        // The liner faces the lit interior, so it only darkens a little while it is edge-on.
        backShade.opacity = Float(max(0, 1 + c) * 0.12)
        darkness.opacity = darknessPeak * Float(1 - light)
        glow.opacity = Float(light)
    }

    /// Hit testing: the door as drawn at its current angle, in scene coordinates.
    var quad: [CGPoint] { return Geo.doorQuad(angle: angle, door: spec) }
}
