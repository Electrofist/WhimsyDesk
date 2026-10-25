import AppKit
import FridgeCore

/// All sizes in points. The window is transparent and larger than the fridge so the door has room
/// to swing past the hinge, and the fog and shadows have room to spill.
///
/// Scene coordinates: origin at the bottom left of the cabinet body, y up.
/// View coordinates: scene origin plus `Geo.bodyOrigin`.
enum Geo {
    /// Room above the cabinet too: a deep door swung toward the viewer looms larger than the body.
    static let windowSize = CGSize(width: 520, height: 844)

    static let bodyOrigin = CGPoint(x: 190, y: 150)
    /// Proportions follow the door artwork (Assets/Door/door_front.png, 872 x 1780 px).
    static let bodySize = CGSize(width: 280, height: 563)

    /// The door sits 4 pt inside the cabinet on every side.
    static let doorInset: CGFloat = 4
    static let doorSize = CGSize(width: 272, height: 555)
    /// Hinge is on the left edge of the door, at mid height.
    static let hinge = CGPoint(x: 4, y: 4 + 555.0 / 2)
    /// Hinge plates on the cabinet (scene y of their bottom edge), near the top and bottom of the door.
    static let hingePlateY: [CGFloat] = [470, 50]
    /// Half the door thickness; front face sits at +z, back face at -z.
    /// A fridge door has some depth (insulation plus the liner), but reads slim at this scale. 18 pt in all.
    static let doorHalfThickness: CGFloat = 9
    static let doorCornerRadius: CGFloat = 24

    /// Door bins on the liner (door space, y up): bottom edge of each tray, how far it stands out
    /// of the liner, the height of its front lip, and the inset from the door's sides.
    static let binY: [CGFloat] = [76, 205, 330, 455]
    static let binDepth: CGFloat = 22
    static let binLipHeight: CGFloat = 22
    static let binInset: CGFloat = 26

    /// The opening into the cabinet, in scene coordinates.
    static let opening = CGRect(x: 14, y: 14, width: InteriorGeometry.openingWidth, height: InteriorGeometry.openingHeight)

    /// Perspective: m34 = -1 / distance. Larger is flatter.
    static let eyeDistance: CGFloat = 1150
    /// Vanishing point of the scene, which is the center of the body.
    static let vanishing = CGPoint(x: bodySize.width / 2, y: bodySize.height / 2)

    /// The handle sits on the right of the door, recessed.
    static let handleRect = CGRect(x: 226, y: 160, width: 34, height: 200)
    /// Width of the grabbable strip along the door's free edge, in door space.
    static let edgeGrabWidth: CGFloat = 30

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
    static let fogFrame = CGRect(x: 90, y: -60, width: 480, height: 360)
    /// A second plume that starts mid-opening and rolls out over the bottom shelf (view coordinates).
    static let fogSpillFrame = CGRect(x: 120, y: 110, width: 420, height: 315)

    // MARK: Door projection (used only for hit testing, matches what Core Animation draws)

    /// Projects a point on the door (door space, origin at the door's bottom left) at `angle`
    /// into scene coordinates.
    static func project(doorPoint p: CGPoint, angle: Double) -> CGPoint {
        let a = CGFloat(angle)
        // Rotation about the vertical axis through the hinge. Positive angle swings the free edge
        // toward the viewer (positive z).
        let x = p.x * cos(a)
        let z = p.x * sin(a)
        let sceneX = hinge.x + x
        let sceneY = doorInset + p.y
        let w = 1 - z / eyeDistance
        return CGPoint(x: vanishing.x + (sceneX - vanishing.x) / w,
                       y: vanishing.y + (sceneY - vanishing.y) / w)
    }

    /// The part of the door a hand can grab: a strip along the free edge (which also covers the handle).
    static func grabQuad(angle: Double) -> [CGPoint] {
        let x0 = doorSize.width - edgeGrabWidth
        let x1 = doorSize.width
        return [
            project(doorPoint: CGPoint(x: x0, y: 0), angle: angle),
            project(doorPoint: CGPoint(x: x1, y: 0), angle: angle),
            project(doorPoint: CGPoint(x: x1, y: doorSize.height), angle: angle),
            project(doorPoint: CGPoint(x: x0, y: doorSize.height), angle: angle)
        ]
    }

    /// The whole door as a polygon in scene coordinates.
    static func doorQuad(angle: Double) -> [CGPoint] {
        return [
            project(doorPoint: CGPoint(x: 0, y: 0), angle: angle),
            project(doorPoint: CGPoint(x: doorSize.width, y: 0), angle: angle),
            project(doorPoint: CGPoint(x: doorSize.width, y: doorSize.height), angle: angle),
            project(doorPoint: CGPoint(x: 0, y: doorSize.height), angle: angle)
        ]
    }

    /// Where the free edge appears horizontally in scene coordinates, used to keep a grab offset.
    static func freeEdgeX(angle: Double) -> CGFloat {
        return project(doorPoint: CGPoint(x: doorSize.width, y: doorSize.height / 2), angle: angle).x
    }

    /// Inverse of `freeEdgeX`: the door angle whose free edge appears at scene x. The projection is
    /// monotonic in angle, so a bisection is exact enough and costs a few dozen multiplications.
    static func angle(forFreeEdgeX x: CGFloat, maxAngle: Double) -> Double {
        var lo = 0.0
        var hi = maxAngle
        if x >= freeEdgeX(angle: lo) { return lo }
        if x <= freeEdgeX(angle: hi) { return hi }
        for _ in 0..<28 {
            let mid = (lo + hi) / 2
            if freeEdgeX(angle: mid) > x {
                lo = mid
            } else {
                hi = mid
            }
        }
        return (lo + hi) / 2
    }

    /// Where a point `doorX` across the door (at mid height) appears horizontally in the scene.
    static func sceneX(ofDoorX doorX: CGFloat, angle: Double) -> CGFloat {
        return project(doorPoint: CGPoint(x: doorX, y: doorSize.height / 2), angle: angle).x
    }

    /// Which point across the door is under scene x, at the current angle. Used once on mouse down
    /// so the hand keeps hold of the same spot on the door wherever it was grabbed.
    static func doorX(underSceneX x: CGFloat, angle: Double) -> CGFloat {
        var lo: CGFloat = 0
        var hi = doorSize.width
        let increasing = sceneX(ofDoorX: hi, angle: angle) >= sceneX(ofDoorX: lo, angle: angle)
        for _ in 0..<24 {
            let mid = (lo + hi) / 2
            if (sceneX(ofDoorX: mid, angle: angle) < x) == increasing { lo = mid } else { hi = mid }
        }
        return (lo + hi) / 2
    }

    /// The door angle that puts the grabbed point `doorX` under scene x. Monotonic in angle,
    /// so a bisection is exact enough and costs a few dozen multiplications.
    static func angle(forDoorX doorX: CGFloat, atSceneX x: CGFloat, maxAngle: Double) -> Double {
        var lo = 0.0
        var hi = maxAngle
        if x >= sceneX(ofDoorX: doorX, angle: lo) { return lo }
        if x <= sceneX(ofDoorX: doorX, angle: hi) { return hi }
        for _ in 0..<28 {
            let mid = (lo + hi) / 2
            if sceneX(ofDoorX: doorX, angle: mid) > x { lo = mid } else { hi = mid }
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
