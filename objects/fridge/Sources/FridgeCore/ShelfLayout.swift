import Foundation

/// Slot bookkeeping: 3 shelves, each with a front and a back row of 4 slots.
public enum ShelfLayout {
    public static let shelfCount = 3
    public static let rowCount = 2
    public static let columnCount = 4
    public static let slotsPerShelf = rowCount * columnCount
    public static let capacity = shelfCount * slotsPerShelf

    public struct Position: Equatable {
        public var shelf: Int
        public var row: Int      // 0 = front, 1 = back
        public var column: Int
    }

    /// Local slot (0..<slotsPerShelf) to row and column. Front row fills first.
    public static func rowAndColumn(forSlot slot: Int) -> (row: Int, column: Int) {
        let s = min(max(slot, 0), slotsPerShelf - 1)
        return (s / columnCount, s % columnCount)
    }

    /// Picks the first free slot, starting on the preferred shelf and fanning outward.
    /// `occupied` holds global indexes (shelf * slotsPerShelf + slot).
    public static func firstFreeSlot(occupied: Set<Int>, preferredShelf: Int) -> (shelf: Int, slot: Int)? {
        let start = min(max(preferredShelf, 0), shelfCount - 1)
        var order: [Int] = [start]
        var distance = 1
        while order.count < shelfCount {
            if start - distance >= 0 { order.append(start - distance) }
            if start + distance < shelfCount { order.append(start + distance) }
            distance += 1
        }
        for shelf in order {
            for slot in 0..<slotsPerShelf where !occupied.contains(shelf * slotsPerShelf + slot) {
                return (shelf, slot)
            }
        }
        return nil
    }

    /// Which shelf a drop at `y` (opening coordinates, origin bottom) is closest to.
    public static func shelfNearest(toY y: Double) -> Int {
        var best = 0
        var bestDistance = Double.greatestFiniteMagnitude
        for (index, front) in InteriorGeometry.shelfFrontY.enumerated() {
            // Items stand somewhere between the front edge and the back edge.
            let middle = InteriorGeometry.project(x: InteriorGeometry.openingWidth / 2, y: front, depth: 0.5).y
            let d = abs(y - middle)
            if d < bestDistance {
                bestDistance = d
                best = index
            }
        }
        return best
    }
}

/// The interior is a box seen from slightly above. Everything shares one vanishing point,
/// so shelves, walls and item scale agree. Coordinates are in the door opening, origin bottom left.
public enum InteriorGeometry {
    public static let openingWidth = 252.0
    public static let openingHeight = 492.0
    public static let vanishingX = 126.0
    public static let vanishingY = 520.0
    /// Scale of the back wall relative to the opening.
    public static let backScale = 0.74
    /// Heights of the shelf front edges on the front plane.
    public static let shelfFrontY: [Double] = [120, 250, 380]
    /// Horizontal extent of a shelf on the front plane.
    public static let shelfMinX = 8.0
    public static let shelfMaxX = 244.0
    /// Depth fraction (0 front edge, 1 back wall) where each row stands.
    public static let rowDepth: [Double] = [0.25, 0.65]
    /// Icon edge length at the front plane, in points.
    public static let baseIconSize = 60.0

    /// Moves a front-plane point back by `depth` (0...1) toward the back wall.
    public static func project(x: Double, y: Double, depth: Double) -> (x: Double, y: Double, scale: Double) {
        let s = 1.0 - depth * (1.0 - backScale)
        return (vanishingX + (x - vanishingX) * s, vanishingY + (y - vanishingY) * s, s)
    }

    /// Base center of an item standing in a slot, plus its scale.
    public static func anchor(shelf: Int, row: Int, column: Int) -> (x: Double, y: Double, scale: Double) {
        let front = shelfFrontY[min(max(shelf, 0), shelfFrontY.count - 1)]
        let columns = Double(ShelfLayout.columnCount)
        let xFront = shelfMinX + (Double(column) + 0.5) / columns * (shelfMaxX - shelfMinX)
        let depth = rowDepth[min(max(row, 0), rowDepth.count - 1)]
        return project(x: xFront, y: front, depth: depth)
    }
}
