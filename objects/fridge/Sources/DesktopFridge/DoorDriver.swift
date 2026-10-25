import AppKit
import FridgeCore

/// Runs the door physics on a display link, but only while the door is actually moving.
/// When the door comes to rest the link is invalidated, so a settled fridge costs nothing.
final class DoorDriver: NSObject {
    private(set) var physics = DoorPhysics()
    private weak var view: NSView?
    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0
    private var requestedFast = false
    private(set) var isSuspended = false

    /// Called every frame with the angle to draw.
    var onFrame: ((Double) -> Void)?
    /// Called once when the door stops and the display link is gone.
    var onRest: (() -> Void)?

    init(view: NSView) {
        self.view = view
        super.init()
    }

    var angle: Double { return physics.visualAngle }
    var maxAngle: Double { return physics.parameters.maxAngle }
    var isHeld: Bool { return physics.handTarget != nil }

    // MARK: Input

    func hold(at target: Double) {
        physics.handTarget = target
        wake()
    }

    func release() {
        physics.handTarget = nil
        wake()
    }

    func setItemDrag(_ active: Bool) {
        physics.itemDragActive = active
        wake()
    }

    /// Development aid: pins the door at an angle (no physics), for screenshots.
    func debugPin(angle: Double) {
        physics.reset(angle: angle)
        physics.handTarget = angle
    }

    // MARK: Lifecycle

    /// Freezes the door exactly where it is. Used on lock and sleep.
    func suspend() {
        isSuspended = true
        stopLink()
    }

    func resume() {
        isSuspended = false
        wake()
    }

    private func wake() {
        guard !isSuspended, link == nil, let view = view, !physics.isAtRest else { return }
        let newLink = view.displayLink(target: self, selector: #selector(tick(_:)))
        newLink.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
        requestedFast = true
        lastTimestamp = 0
        newLink.add(to: .main, forMode: .common)
        link = newLink
    }

    private func stopLink() {
        link?.invalidate()
        link = nil
        lastTimestamp = 0
    }

    @objc private func tick(_ sender: CADisplayLink) {
        var dt = lastTimestamp == 0 ? sender.targetTimestamp - sender.timestamp : sender.timestamp - lastTimestamp
        lastTimestamp = sender.timestamp
        if dt <= 0 || dt > 0.1 { dt = 1.0 / 60.0 }

        physics.advance(by: dt)

        // Full refresh rate only while the door is held or moving quickly. A slow drift is fine at 60.
        let fast = physics.handTarget != nil || abs(physics.velocity) > 0.9
        if fast != requestedFast {
            requestedFast = fast
            sender.preferredFrameRateRange = fast
                ? CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
                : CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        }

        onFrame?(physics.visualAngle)

        if physics.isAtRest {
            stopLink()
            onRest?()
        }
    }
}
