import Foundation

/// The door's physics. It is hinged at the bottom: gravity pulls it open once it passes the
/// latch, it bounces on its stop, and the latch pulls it shut when it is nearly closed.
/// Angle 0 is closed; `maxAngle` is hanging open.
struct DoorModel {
    enum Event { case unlatched, latched(speed: Double), hitStop(speed: Double) }

    static let maxAngle = 108 * Double.pi / 180
    static let latchZone = 5 * Double.pi / 180

    var angle = 0.0
    var velocity = 0.0
    /// While the hand holds the door, it follows this angle on a spring.
    var handTarget: Double?

    private let gravity = 25.0
    private let drag = 1.6
    private let handStiffness = 90.0
    private let handDamping = 14.0
    private let step = 1.0 / 240
    private var leftover = 0.0

    var isAtRest: Bool {
        handTarget == nil && abs(velocity) < 0.002 && (angle == 0 || angle == DoorModel.maxAngle)
    }
    var isOpen: Bool { angle > 1.2 }

    /// A click on a closed door: lift the latch and give it a nudge.
    mutating func pushOpen() { if angle < DoorModel.latchZone * 2 { velocity = max(velocity, 4.2) } }

    /// Advances by `dt` seconds and reports what happened, for sounds.
    mutating func advance(_ dt: Double) -> [Event] {
        var events: [Event] = []
        leftover += min(dt, 0.05)
        while leftover >= step {
            leftover -= step
            let wasLatched = angle < DoorModel.latchZone
            var torque = gravity * sin(angle) - drag * velocity
            if let target = handTarget {
                torque += handStiffness * (target - angle) - handDamping * velocity
            } else if angle < DoorModel.latchZone && angle > 0 {
                torque += -30 - 8 * velocity
            }
            velocity += torque * step
            angle += velocity * step

            if angle <= 0 {
                if velocity < -0.4 { events.append(.latched(speed: -velocity)) }
                angle = 0
                velocity = abs(velocity) > 0.4 && handTarget == nil ? -velocity * 0.25 : 0
                if velocity < 0.3 { velocity = 0 }
            } else if angle >= DoorModel.maxAngle {
                if velocity > 0.5 { events.append(.hitStop(speed: velocity)) }
                angle = DoorModel.maxAngle
                velocity = velocity > 0.6 ? -velocity * 0.35 : 0
            }
            if wasLatched && angle >= DoorModel.latchZone { events.append(.unlatched) }
        }
        if isAtRest { velocity = 0 }
        return events
    }
}

/// The flag on the side: springs between down and up.
struct FlagModel {
    static let down = -Double.pi / 2
    static let up = 0.0

    var angle = FlagModel.down
    var velocity = 0.0
    var target = FlagModel.down

    var isAtRest: Bool { abs(angle - target) < 0.001 && abs(velocity) < 0.002 }

    mutating func advance(_ dt: Double) {
        var t = min(dt, 0.05)
        while t > 0 {
            let h = min(t, 1.0 / 240)
            t -= h
            velocity += (140 * (target - angle) - 9 * velocity) * h
            angle += velocity * h
        }
        if isAtRest { angle = target; velocity = 0 }
    }
}
