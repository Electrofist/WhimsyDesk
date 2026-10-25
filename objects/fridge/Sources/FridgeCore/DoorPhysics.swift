import Foundation

/// Constants for the door model. Values are tuned and verified by tools/sim_door.py.
/// Keep both files in sync.
public struct DoorParameters {
    /// Angular mass. Everything else is expressed against it.
    public var inertia = 1.0
    /// Viscous damping while the door is free (not held by the hand).
    public var freeDamping = 3.0
    /// Weak spring toward closed. Together with creepTorque it makes an ajar door drift shut.
    public var tiltStiffness = 1.0
    /// Constant torque toward closed so small gaps still close at a visible pace.
    public var creepTorque = 0.04
    /// Hand tether: the grabbed door follows the pointer through this spring-damper.
    /// Low stiffness is what makes slow pulls feel heavy and fast pulls overshoot.
    public var handStiffness = 45.0
    public var handDamping = 8.7
    /// Fully open angle in radians (105 degrees).
    public var maxAngle = 105.0 * Double.pi / 180.0
    /// Closed stop (the door frame). Compression here is the soft seal.
    public var stopStiffness = 900.0
    public var stopDamping = 42.0
    /// Open stop. Lower damping so a hard fling overshoots a little and settles.
    public var maxStopDamping = 17.0
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
        velocity += torque() / parameters.inertia * DoorPhysics.fixedStep
        angle += velocity * DoorPhysics.fixedStep
    }

    /// Net torque at the current state.
    public func torque() -> Double {
        let p = parameters
        var t = 0.0

        if let target = handTarget {
            let clamped = min(max(target, 0), p.maxAngle)
            t += p.handStiffness * (clamped - angle) - p.handDamping * velocity
        } else {
            t -= p.freeDamping * velocity
            if !itemDragActive {
                if angle > 0 {
                    t -= p.tiltStiffness * angle + p.creepTorque
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
        return abs(velocity) < 0.01 && abs(torque()) < 0.005
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
