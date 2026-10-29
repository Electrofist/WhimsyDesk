import XCTest
@testable import FridgeCore

final class DoorPhysicsTests: XCTestCase {
    private let deg = Double.pi / 180.0

    /// Run until the door reports rest. Returns seconds elapsed, or nil if it never rests.
    private func timeToRest(_ door: inout DoorPhysics, limit: Double = 30) -> Double? {
        var t = 0.0
        while t < limit {
            door.stepOnce()
            t += DoorPhysics.fixedStep
            if door.isAtRest { return t }
        }
        return nil
    }

    func testAjarDoorDriftsShutWithinFourToEightSeconds() {
        for start in [10.0, 15.0, 20.0] {
            var door = DoorPhysics(angle: start * deg)
            guard let t = timeToRest(&door) else { return XCTFail("never rested from \(start)") }
            XCTAssertGreaterThanOrEqual(t, 4.0, "closed too fast from \(start)")
            XCTAssertLessThanOrEqual(t, 8.0, "closed too slow from \(start)")
            XCTAssertLessThan(door.visualAngle, 0.5 * deg)
        }
    }

    func testWideOpenDoorStaysWhereItWasLeft() {
        for start in [30.0, 60.0, 90.0, 105.0] {
            var door = DoorPhysics(angle: start * deg)
            for _ in 0..<(240 * 10) { door.stepOnce() }
            XCTAssertEqual(door.angle, start * deg, accuracy: 0.01 * deg, "moved from \(start)")
            XCTAssertTrue(door.isAtRest)
        }
    }

    func testReleasedSwingCoastsAndParks() {
        var door = DoorPhysics(angle: 40 * deg, velocity: 1.5)
        guard let t = timeToRest(&door, limit: 5) else { return XCTFail("never parked") }
        XCTAssertLessThan(t, 2.5)
        XCTAssertGreaterThan(door.angle, 50 * deg)
        XCTAssertLessThanOrEqual(door.angle, door.parameters.maxAngle + 1 * deg)
    }

    func testSealCompressionIsSmall() {
        var door = DoorPhysics(angle: 20 * deg)
        _ = timeToRest(&door)
        XCTAssertGreaterThan(door.angle, -2 * deg)
        XCTAssertEqual(door.visualAngle, 0, accuracy: 1e-9)
    }

    func testHardFlingOvershootsOpenStopSlightlyAndSettlesThere() {
        var door = DoorPhysics(angle: 20 * deg, velocity: 10)
        var peak = 0.0
        var t = 0.0
        while t < 1.5 {
            door.stepOnce()
            peak = max(peak, door.angle)
            t += DoorPhysics.fixedStep
        }
        let openStop = door.parameters.maxAngle
        XCTAssertGreaterThan(peak, openStop)
        XCTAssertLessThan(peak, openStop + 10 * deg)
    }

    func testHandDragOvershootsASmallAmountAndSettlesOnTarget() {
        var door = DoorPhysics()
        var peak = 0.0
        var t = 0.0
        while t < 2.5 {
            // Pointer swings 0 to 60 degrees in 0.15 s, then holds.
            let target = min(t / 0.15, 1.0) * 60 * deg
            door.handTarget = target
            door.stepOnce()
            peak = max(peak, door.angle)
            t += DoorPhysics.fixedStep
        }
        XCTAssertGreaterThan(peak, 60 * deg)
        XCTAssertLessThan(peak, 70 * deg)
        XCTAssertEqual(door.angle, 60 * deg, accuracy: 0.2 * deg)
        XCTAssertTrue(door.isAtRest)
    }

    func testHeldDoorStopsMovingWhenPointerStops() {
        var door = DoorPhysics()
        door.handTarget = 50 * deg
        guard let t = timeToRest(&door, limit: 5) else { return XCTFail("did not settle") }
        XCTAssertLessThan(t, 3)
        XCTAssertEqual(door.angle, 50 * deg, accuracy: 0.5 * deg)
    }

    func testDoorCannotCloseWhileItemDragIsActive() {
        var door = DoorPhysics(angle: 45 * deg)
        door.itemDragActive = true
        // Shove it shut hard.
        door.reset(angle: 45 * deg, velocity: -3)
        door.itemDragActive = true
        var lowest = door.angle
        var t = 0.0
        while t < 8 {
            door.stepOnce()
            lowest = min(lowest, door.angle)
            t += DoorPhysics.fixedStep
        }
        XCTAssertGreaterThan(lowest, 15 * deg)
        XCTAssertEqual(door.angle, door.parameters.itemFloor, accuracy: 1 * deg)
    }

    func testDoorDoesNotCreepWhileItemDragIsActive() {
        var door = DoorPhysics(angle: 70 * deg)
        door.itemDragActive = true
        for _ in 0..<(240 * 5) { door.stepOnce() }
        XCTAssertEqual(door.angle, 70 * deg, accuracy: 0.01 * deg)
        XCTAssertTrue(door.isAtRest)
    }

    func testClosedDoorIsAtRest() {
        var door = DoorPhysics()
        _ = timeToRest(&door, limit: 5)
        XCTAssertTrue(door.isAtRest)
    }

    func testAdvanceIsIndependentOfFrameRate() {
        var a = DoorPhysics(angle: 80 * deg)
        var b = DoorPhysics(angle: 80 * deg)
        for _ in 0..<(60 * 3) { a.advance(by: 1.0 / 60.0) }
        for _ in 0..<(120 * 3) { b.advance(by: 1.0 / 120.0) }
        XCTAssertEqual(a.angle, b.angle, accuracy: 0.5 * deg)
    }

    func testAngleFromPointer() {
        let limit = 105 * deg
        XCTAssertEqual(DoorPhysics.angle(forFreeEdgeX: 272, hingeX: 0, doorWidth: 272, maxAngle: limit), 0, accuracy: 1e-9)
        XCTAssertEqual(DoorPhysics.angle(forFreeEdgeX: 0, hingeX: 0, doorWidth: 272, maxAngle: limit), 90 * deg, accuracy: 1e-9)
        XCTAssertEqual(DoorPhysics.angle(forFreeEdgeX: -500, hingeX: 0, doorWidth: 272, maxAngle: limit), limit, accuracy: 1e-9)
    }
}
