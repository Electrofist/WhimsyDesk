import XCTest
@testable import FridgeCore

final class FrostModelTests: XCTestCase {
    func testFreshItemHasNoFrostOrBurn() {
        let s = FrostModel.state(forElapsed: 0)
        XCTAssertEqual(s.frost, 0, accuracy: 1e-9)
        XCTAssertEqual(s.burn, 0, accuracy: 1e-9)
    }

    func testFrostGrowsMonotonicallyAndSaturates() {
        var last = -1.0
        for hours in stride(from: 0.0, through: 24 * 30, by: 6) {
            let s = FrostModel.state(forElapsed: hours * 3600)
            XCTAssertGreaterThanOrEqual(s.frost, last)
            XCTAssertLessThanOrEqual(s.frost, 1.0)
            last = s.frost
        }
        XCTAssertGreaterThan(last, 0.99)
    }

    func testBurnStartsAfterTwoDaysAndIsCappedLight() {
        XCTAssertEqual(FrostModel.state(forElapsed: 1.9 * FrostModel.day).burn, 0, accuracy: 1e-9)
        XCTAssertGreaterThan(FrostModel.state(forElapsed: 10 * FrostModel.day).burn, 0.1)
        XCTAssertEqual(FrostModel.state(forElapsed: 400 * FrostModel.day).burn, FrostModel.burnCap, accuracy: 1e-9)
    }

    func testBucketChangesOnlyWhenLookChanges() {
        let a = FrostModel.state(forElapsed: 3 * 3600)
        let b = FrostModel.state(forElapsed: 3 * 3600 + 60)
        XCTAssertEqual(a.bucket, b.bucket)
        let c = FrostModel.state(forElapsed: 10 * FrostModel.day)
        XCTAssertNotEqual(a.bucket, c.bucket)
    }

    func testTimeScaleAccelerates() {
        let now = Date()
        let placed = now.addingTimeInterval(-3600)
        let slow = FrostModel.state(placedAt: placed, now: now, timeScale: 1)
        let fast = FrostModel.state(placedAt: placed, now: now, timeScale: 100)
        XCTAssertGreaterThan(fast.frost, slow.frost)
    }
}

final class ShelfLayoutTests: XCTestCase {
    func testCapacity() {
        XCTAssertEqual(ShelfLayout.capacity, 24)
    }

    func testFirstFreeSlotPrefersRequestedShelfFrontRowFirst() {
        let spot = ShelfLayout.firstFreeSlot(occupied: [], preferredShelf: 1)
        XCTAssertEqual(spot?.shelf, 1)
        XCTAssertEqual(spot?.slot, 0)
    }

    func testFansOutToNeighbourShelfWhenFull() {
        var occupied = Set<Int>()
        for s in 0..<ShelfLayout.slotsPerShelf { occupied.insert(1 * ShelfLayout.slotsPerShelf + s) }
        let spot = ShelfLayout.firstFreeSlot(occupied: occupied, preferredShelf: 1)
        XCTAssertNotNil(spot)
        XCTAssertNotEqual(spot?.shelf, 1)
    }

    func testReturnsNilWhenEverythingIsFull() {
        let all = Set(0..<ShelfLayout.capacity)
        XCTAssertNil(ShelfLayout.firstFreeSlot(occupied: all, preferredShelf: 0))
    }

    func testBackRowIsSmallerAndHigherOnScreenThanFrontRow() {
        let front = InteriorGeometry.anchor(shelf: 0, row: 0, column: 1)
        let back = InteriorGeometry.anchor(shelf: 0, row: 1, column: 1)
        XCTAssertLessThan(back.scale, front.scale)
        XCTAssertGreaterThan(back.y, front.y)
    }

    func testItemsStayInsideTheOpeningAndBelowTheNextShelf() {
        for shelf in 0..<ShelfLayout.shelfCount {
            for row in 0..<ShelfLayout.rowCount {
                for column in 0..<ShelfLayout.columnCount {
                    let a = InteriorGeometry.anchor(shelf: shelf, row: row, column: column)
                    let half = InteriorGeometry.baseIconSize * a.scale / 2
                    XCTAssertGreaterThanOrEqual(a.x - half, 0)
                    XCTAssertLessThanOrEqual(a.x + half, InteriorGeometry.openingWidth)
                    let top = a.y + InteriorGeometry.baseIconSize * a.scale
                    let ceiling = shelf + 1 < ShelfLayout.shelfCount
                        ? InteriorGeometry.shelfFrontY[shelf + 1]
                        : InteriorGeometry.openingHeight
                    XCTAssertLessThan(top, ceiling)
                }
            }
        }
    }

    func testNearestShelfFromDropHeight() {
        XCTAssertEqual(ShelfLayout.shelfNearest(toY: 40), 0)
        XCTAssertEqual(ShelfLayout.shelfNearest(toY: 480), 2)
    }
}
