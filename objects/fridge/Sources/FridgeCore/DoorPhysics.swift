import Foundation

/// Constants for the door model. Values are tuned and verified by tools/sim_door.py.
/// Keep both files in sync.
public struct DoorParameters {
    /// Angular mass. Everything else is expressed against it.
    public var inertia = 1.0
    /// Viscous damping while the door is free (not held by the hand): air and gasket drag.
    public var freeDamping = 1.6
    /// Dry friction in the hinges. This is what lets an open door stay where it was left.
    public var hingeFriction = 0.9
    /// Below this angle the door counts as ajar: hinge friction gives way and it drifts shut.
    public var driftZone = 22.0 * Double.pi / 180.0
    /// Gentle closing pull inside the drift zone (self-closing hinge cam).
    public var driftTorque = 0.16
    public var driftDamping = 2.2
    /// Hand tether: the grabbed door follows the pointer through this spring-damper.
    /// The door lags the hand a little, like something heavy, but stays under control.
    public var handStiffness = 150.0
    public var handDamping = 19.0
    /// Fully open angle in radians (105 degrees).
    public var maxAngle = 105.0 * Double.pi / 180.0
    /// Closed stop (the door frame). Compression here is the soft seal.
    public var stopStiffness = 900.0
    public var stopDamping = 42.0
    /// Open stop. Lower damping so a hard fling overshoots a little and settles.
    public var maxStopDamping = 34.0
    /// Within this angle of closed the magnet gasket pulls the door in.
    public var magnetRange = 7.0 * Double.pi / 180.0
    public var magnetStrength = 14.0
    /// While an item drag is in progress the door cannot close below this angle.
    public var itemFloor = 34.0 * Double.pi / 180.0
    public var itemFloorStiffness = 18.0
    public var itemFloorDamping = 6.0

    public init() {}
}

/// Damped angular spring: angle, angular velocity, mass. No collision physics.
/// Angles are radians, 0 is closed, positive is open toward the viewer.
public struct DoorPhysics {
    public static let fixedStep = 1.0 / 240.0
    public static let maxFrameDelta = 0.05

    public var parameters: DoorParameters
    public private(set) var angle: Double
    public private(set) var velocity: Double

    /// Non-nil while the user holds the door. The value is where the pointer wants the door.
    public var handTarget: Double?
    /// True while a file is being dragged out of the fridge.
    public var itemDragActive = false

    private var accumulator = 0.0

    public init(parameters: DoorParameters = DoorParameters(), angle: Double = 0, velocity: Double = 0) {
        self.parameters = parameters
        self.angle = angle
        self.velocity = velocity
    }

    public mutating func reset(angle: Double, velocity: Double = 0) {
        self.angle = angle
        self.velocity = velocity
        self.accumulator = 0
    }

    /// Advance by a frame delta. Uses a fixed inner step so results do not depend on refresh rate.
    public mutating func advance(by frameDelta: Double) {
        let dt = min(max(frameDelta, 0), DoorPhysics.maxFrameDelta)
        accumulator += dt
        while accumulator >= DoorPhysics.fixedStep {
            stepOnce()
            accumulator -= DoorPhysics.fixedStep
        }
    }

    /// One semi-implicit Euler step.
    public mutating func stepOnce() {
        let h = DoorPhysics.fixedStep
        velocity += torque() / parameters.inertia * h

        // Hinge friction: opposes motion and never reverses it, so a slowing door comes to a real stop.
        if handTarget == nil && hingeFrictionApplies {
            let dv = parameters.hingeFriction / parameters.inertia * h
            velocity = abs(velocity) <= dv ? 0 : velocity - (velocity > 0 ? dv : -dv)
        }
        angle += velocity * h
    }

    /// Friction holds the door anywhere it is open wide enough, and while an item is being dragged out.
    private var hingeFrictionApplies: Bool {
        let p = parameters
        return angle >= p.driftZone && angle <= p.maxAngle
    }

    /// Net torque at the current state (hinge friction is applied separately in `stepOnce`).
    public func torque() -> Double {
        let p = parameters
        var t = 0.0

        if let target = handTarget {
            let clamped = min(max(target, 0), p.maxAngle)
            t += p.handStiffness * (clamped - angle) - p.handDamping * velocity
        } else {
            t -= p.freeDamping * velocity
            if !itemDragActive {
                if angle > 0 && angle < p.driftZone {
                    // Ajar: drift shut at a calm pace. Fades in at the zone edge so nothing jumps.
                    let fade = min(1, (p.driftZone - angle) / (4 * Double.pi / 180))
                    t -= p.driftTorque * fade + p.driftDamping * velocity * fade
                }
                if angle < p.magnetRange {
                    let x = 1.0 - max(angle, 0) / p.magnetRange
                    t -= p.magnetStrength * x * x
                }
            }
        }

        if angle < 0 {
            t += p.stopStiffness * (-angle) - p.stopDamping * velocity
        }
        if angle > p.maxAngle {
            t += -p.stopStiffness * (angle - p.maxAngle) - p.maxStopDamping * velocity
        }
        if itemDragActive && angle < p.itemFloor {
            t += p.itemFloorStiffness * (p.itemFloor - angle) - p.itemFloorDamping * velocity
        }
        return t
    }

    /// True when nothing will move on the next frame. The driver invalidates the display link here.
    public var isAtRest: Bool {
        guard abs(velocity) < 0.01 else { return false }
        let t = torque()
        // Parked open: static hinge friction holds against anything weaker than itself.
        if handTarget == nil && hingeFrictionApplies && abs(t) < parameters.hingeFriction { return true }
        return abs(t) < 0.005
    }

    /// Angle used for drawing: never negative, never absurdly past the open stop.
    public var visualAngle: Double {
        return min(max(angle, 0), parameters.maxAngle + 0.2)
    }

    /// Convert pointer position to a door angle for a door of width `doorWidth` hinged at `hingeX`.
    /// The free edge sits at hingeX + doorWidth * cos(angle) in the flat projection.
    public static func angle(forFreeEdgeX x: Double, hingeX: Double, doorWidth: Double, maxAngle: Double) -> Double {
        let ratio = min(max((x - hingeX) / doorWidth, -1), 1)
        return min(max(acos(ratio), 0), maxAngle)
    }
}
