import AppKit
import FridgeCore

/// All sizes in points. The window is transparent and larger than the fridge so the door has room
/// to swing past the hinge, and the fog and shadows have room to spill.
///
/// Scene coordinates: origin at the bottom left of the cabinet body, y up.
/// View coordinates: scene origin plus `Geo.bodyOrigin`.
enum Geo {
    /// Room above the cabinet too: a deep door swung toward the viewer looms larger than the body.
    /// Seen from above, an open door's bottom corner hangs well below the feet, so most room is below.
    static let windowSize = CGSize(width: 520, height: 800)

    static let bodyOrigin = CGPoint(x: 190, y: 170)
    /// `bodyOrigin.y` in earlier builds. Saved window origins are shifted by the difference so the
    /// fridge stays put on the desktop after the update.
    static let legacyBodyOriginY: CGFloat = 150
    /// Proportions follow the door artwork (Assets/Door/door_front.png, 872 x 1780 px).
    static let bodySize = CGSize(width: 280, height: 563)

    /// The doors sit 4 pt inside the cabinet on every side and are hinged on the left.
    static let doorInset: CGFloat = 4
    /// Where the freezer door meets the fridge door (scene y). The artwork splits at row 610 of 1780.
    static let doorSplitY: CGFloat = 369

    /// The fridge door (below) and the freezer door (above). Each swings on its own.
    static let fridgeDoor = DoorSpec(name: "fridge",
                                     frame: CGRect(x: 4, y: 4, width: 272, height: doorSplitY - 4),
                                     artwork: "door_fridge",
                                     shelves: [0, 1],
                                     binY: [36, 146, 256],
                                     roundTop: false, roundBottom: true)
    static let freezerDoor = DoorSpec(name: "freezer",
                                      frame: CGRect(x: 4, y: doorSplitY, width: 272, height: 559 - doorSplitY),
                                      artwork: "door_freezer",
                                      shelves: [2],
                                      binY: [46],
                                      roundTop: true, roundBottom: false)
    static let doors = [fridgeDoor, freezerDoor]

    /// Hinge plates on the cabinet (scene y of their bottom edge): top, middle (shared by both doors), bottom.
    static let hingePlateY: [CGFloat] = [505, doorSplitY - 20, 30]
    /// Half the door thickness; front face sits at +z, back face at -z.
    /// A fridge door has some depth (insulation plus the liner), but reads slim at this scale. 18 pt in all.
    static let doorHalfThickness: CGFloat = 9
    static let doorCornerRadius: CGFloat = 24

    /// Door bins: how far each tray stands out of the liner, the height of its front lip, and the
    /// inset from the door's sides. Their heights are per door (`DoorSpec.binY`).
    static let binDepth: CGFloat = 22
    static let binLipHeight: CGFloat = 22
    static let binInset: CGFloat = 26

    /// The opening into the cabinet, in scene coordinates.
    static let opening = CGRect(x: 14, y: 14, width: InteriorGeometry.openingWidth, height: InteriorGeometry.openingHeight)

    /// Perspective: m34 = -1 / distance. Larger is flatter.
    static let eyeDistance = CGFloat(InteriorGeometry.eyeDistance)
    /// Vanishing point of the scene: the interior's eye, so the doors and the shelves are seen from
    /// the same spot (centered, a little below the top of the fridge).
    static let vanishing = CGPoint(x: opening.minX + CGFloat(InteriorGeometry.vanishingX),
                                   y: opening.minY + CGFloat(InteriorGeometry.vanishingY))

    /// Items become interactive past this angle, with hysteresis so they do not flicker.
    static let interactiveOnAngle = 40.0 * Double.pi / 180
    static let interactiveOffAngle = 36.0 * Double.pi / 180
    /// The fog starts and the sound plays when the door first passes this angle.
    static let openedAngle = 8.0 * Double.pi / 180
    /// Below this the door counts as sealed.
    static let sealedAngle = 0.6 * Double.pi / 180

    static let fogFrameCount = 40
    static let fogDuration: CFTimeInterval = 1.7
    /// The plume starts about 15% below the top of this frame, which lands in the lower part of the opening.
    static let fogFrame = CGRect(x: 90, y: -40, width: 480, height: 360)
    /// A second plume that starts mid-opening and rolls out over the bottom shelf (view coordinates).
    static let fogSpillFrame = CGRect(x: 120, y: 130, width: 420, height: 315)

    // MARK: Door projection (used only for hit testing, matches what Core Animation draws)

    /// Projects a point on a door (door space, origin at the door's bottom left) at `angle`
    /// into scene coordinates.
    static func project(doorPoint p: CGPoint, angle: Double, door: DoorSpec) -> CGPoint {
        let a = CGFloat(angle)
        // Rotation about the vertical axis through the hinge. Positive angle swings the free edge
        // toward the viewer (positive z).
        let x = p.x * cos(a)
        let z = p.x * sin(a)
        let sceneX = door.frame.minX + x
        let sceneY = door.frame.minY + p.y
        let w = 1 - z / eyeDistance
        return CGPoint(x: vanishing.x + (sceneX - vanishing.x) / w,
                       y: vanishing.y + (sceneY - vanishing.y) / w)
    }

    /// A whole door as a polygon in scene coordinates.
    static func doorQuad(angle: Double, door: DoorSpec) -> [CGPoint] {
        let s = door.size
        return [
            project(doorPoint: CGPoint(x: 0, y: 0), angle: angle, door: door),
            project(doorPoint: CGPoint(x: s.width, y: 0), angle: angle, door: door),
            project(doorPoint: CGPoint(x: s.width, y: s.height), angle: angle, door: door),
            project(doorPoint: CGPoint(x: 0, y: s.height), angle: angle, door: door)
        ]
    }

    /// Where a point `doorX` across a door (at its mid height) appears horizontally in the scene.
    static func sceneX(ofDoorX doorX: CGFloat, angle: Double, door: DoorSpec) -> CGFloat {
        return project(doorPoint: CGPoint(x: doorX, y: door.size.height / 2), angle: angle, door: door).x
    }

    /// Which point across a door is under scene x, at the current angle. Used once on mouse down
    /// so the hand keeps hold of the same spot on the door wherever it was grabbed.
    static func doorX(underSceneX x: CGFloat, angle: Double, door: DoorSpec) -> CGFloat {
        var lo: CGFloat = 0
        var hi = door.size.width
        let increasing = sceneX(ofDoorX: hi, angle: angle, door: door) >= sceneX(ofDoorX: lo, angle: angle, door: door)
        for _ in 0..<24 {
            let mid = (lo + hi) / 2
            if (sceneX(ofDoorX: mid, angle: angle, door: door) < x) == increasing { lo = mid } else { hi = mid }
        }
        return (lo + hi) / 2
    }

    /// The door angle that puts the grabbed point `doorX` under scene x. Monotonic in angle,
    /// so a bisection is exact enough and costs a few dozen multiplications.
    static func angle(forDoorX doorX: CGFloat, atSceneX x: CGFloat, maxAngle: Double, door: DoorSpec) -> Double {
        var lo = 0.0
        var hi = maxAngle
        if x >= sceneX(ofDoorX: doorX, angle: lo, door: door) { return lo }
        if x <= sceneX(ofDoorX: doorX, angle: hi, door: door) { return hi }
        for _ in 0..<28 {
            let mid = (lo + hi) / 2
            if sceneX(ofDoorX: doorX, angle: mid, door: door) > x { lo = mid } else { hi = mid }
        }
        return (lo + hi) / 2
    }

    /// Convex polygon containment (works for either winding).
    static func contains(_ polygon: [CGPoint], _ point: CGPoint) -> Bool {
        guard polygon.count >= 3 else { return false }
        var sign: CGFloat = 0
        for i in 0..<polygon.count {
            let a = polygon[i]
            let b = polygon[(i + 1) % polygon.count]
            let cross = (b.x - a.x) * (point.y - a.y) - (b.y - a.y) * (point.x - a.x)
            if abs(cross) < 1e-6 { continue }
            if sign == 0 {
                sign = cross > 0 ? 1 : -1
            } else if (cross > 0) != (sign > 0) {
                return false
            }
        }
        return true
    }

    // MARK: Conversions

    static func scenePoint(fromView p: CGPoint) -> CGPoint {
        return CGPoint(x: p.x - bodyOrigin.x, y: p.y - bodyOrigin.y)
    }

    static var bodyRectInView: CGRect {
        return CGRect(origin: bodyOrigin, size: bodySize)
    }
}

/// One of the two doors. Everything else about a door (layers, physics, lighting) lives in `DoorRig`.
struct DoorSpec {
    let name: String
    /// The door's rectangle in scene coordinates when shut. The hinge runs up its left edge.
    let frame: CGRect
    /// Bundled PNG used for the door's front.
    let artwork: String
    /// Shelves (ShelfLayout indexes) behind this door. They are usable only while it is open.
    let shelves: [Int]
    /// Door bins on the liner: bottom edge of each tray, door space.
    let binY: [CGFloat]
    /// Which ends of the door have rounded corners (the outer ends, not where the doors meet).
    let roundTop: Bool
    let roundBottom: Bool

    var size: CGSize { return frame.size }

    /// The part of the opening behind this door, in opening coordinates.
    var openingSlice: CGRect {
        let o = Geo.opening
        let lo = max(frame.minY, o.minY), hi = min(frame.maxY, o.maxY)
        return CGRect(x: 0, y: lo - o.minY, width: o.width, height: hi - lo)
    }

    /// A rounded rectangle with only the outer corners rounded.
    func outline(in rect: CGRect, radius: CGFloat) -> CGPath {
        let r = min(radius, rect.height / 2)
        let top = roundTop ? r : 0, bottom = roundBottom ? r : 0
        let p = CGMutablePath()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY + bottom))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - top))
        p.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX + top, y: rect.maxY), radius: top)
        p.addLine(to: CGPoint(x: rect.maxX - top, y: rect.maxY))
        p.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY), tangent2End: CGPoint(x: rect.maxX, y: rect.maxY - top), radius: top)
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + bottom))
        p.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY), tangent2End: CGPoint(x: rect.maxX - bottom, y: rect.minY), radius: bottom)
        p.addLine(to: CGPoint(x: rect.minX + bottom, y: rect.minY))
        p.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY), tangent2End: CGPoint(x: rect.minX, y: rect.minY + bottom), radius: bottom)
        p.closeSubpath()
        return p
    }
}
