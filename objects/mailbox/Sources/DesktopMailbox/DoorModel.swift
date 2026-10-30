import Foundation

/// The door's physics. It hangs on hinges along its left edge: a push swings it open, friction
/// slows it, it bounces off its stop, and the latch pulls it shut when it is nearly closed.
/// Angle 0 is closed; `maxAngle` is wide open.
struct DoorModel {
    enum Event { case unlatched, latched(speed: Double), hitStop(speed: Double) }

    static let maxAngle = 100 * Double.pi / 180
    static let latchZone = 5 * Double.pi / 180

    var angle = 0.0
    var velocity = 0.0
    /// While the hand holds the door, it follows this angle on a spring.
    var handTarget: Double?

    private let drag = 2.0          // air and hinge drag, grows with speed
    private let friction = 0.7      // steady hinge friction
    private let handStiffness = 90.0
    private let handDamping = 14.0
    private let step = 1.0 / 240
    private var leftover = 0.0

    var isAtRest: Bool {
        handTarget == nil && abs(velocity) < 0.003 && (angle == 0 || angle >= DoorModel.latchZone)
    }
    var isOpen: Bool { angle > 0.9 }

    /// A click on a closed door: lift the latch and swing it.
    mutating func pushOpen() { if angle < DoorModel.latchZone * 2 { velocity = max(velocity, 5.6) } }

    /// Advances by `dt` seconds and reports what happened, for sounds.
    mutating func advance(_ dt: Double) -> [Event] {
        var events: [Event] = []
        leftover += min(dt, 0.05)
        while leftover >= step {
            leftover -= step
            let wasLatched = angle < DoorModel.latchZone
            var torque = -drag * velocity
            if abs(velocity) > 0.001 { torque -= friction * (velocity > 0 ? 1 : -1) }
            if let target = handTarget {
                torque += handStiffness * (target - angle) - handDamping * velocity
            } else if angle < DoorModel.latchZone && angle > 0 {
                torque += -30 - 8 * velocity
            }
            let before = velocity
            velocity += torque * step
            // Friction stops a slow door rather than pushing it backwards.
            if handTarget == nil && before != 0 && (before > 0) != (velocity > 0) && angle >= DoorModel.latchZone { velocity = 0 }
            angle += velocity * step

            if angle <= 0 {
                if velocity < -0.4 { events.append(.latched(speed: -velocity)) }
                angle = 0
                velocity = abs(velocity) > 0.4 && handTarget == nil ? -velocity * 0.2 : 0
                if velocity < 0.3 { velocity = 0 }
            } else if angle >= DoorModel.maxAngle {
                if velocity > 0.5 { events.append(.hitStop(speed: velocity)) }
                angle = DoorModel.maxAngle
                velocity = velocity > 0.6 ? -velocity * 0.3 : 0
            }
            if wasLatched && angle >= DoorModel.latchZone { events.append(.unlatched) }
        }
        if isAtRest { velocity = 0 }
        return events
    }
}
