import AppKit
import FridgeCore

final class ItemNode {
    var entry: FridgeEntry
    let icon = CALayer()
    let shadow = CALayer()
    var base: CGImage?
    var bakedBucket = -1
    /// Hit rectangle in opening coordinates.
    var nominal = CGRect.zero
    var points: CGFloat = 0

    init(entry: FridgeEntry) {
        self.entry = entry
    }
}

/// Owns one pair of layers (icon and contact shadow) per stored item. Layers are static; nothing
/// here runs per frame.
final class ItemsController {
    let layer = CALayer()
    /// Set by the view once the door is past the open-angle threshold.
    var interactive = false

    private let store: FridgeStore
    private var nodes: [UUID: ItemNode] = [:]
    private var scale: CGFloat
    private var shadowImage: CGImage?
    private var bakeTicket = 0

    init(store: FridgeStore, scale: CGFloat) {
        self.store = store
        self.scale = scale
        layer.frame = Geo.opening
        shadowImage = FridgeArt.itemShadow(scale: scale)
        for entry in store.entries { makeNode(entry) }
        arrange()
    }

    static func stableSeed(_ id: UUID) -> UInt64 {
        return withUnsafeBytes(of: id.uuid) { $0.loadUnaligned(as: UInt64.self) }
    }

    // MARK: Changes

    func add(_ entry: FridgeEntry) {
        let node = makeNode(entry)
        arrange()

        let slide = CABasicAnimation(keyPath: "position.y")
        slide.isAdditive = true
        slide.fromValue = 28
        slide.toValue = 0
        slide.duration = 0.30
        slide.timingFunction = CAMediaTimingFunction(name: .easeOut)
        node.icon.add(slide, forKey: "dropIn")

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.2
        node.icon.add(fade, forKey: "fadeIn")
        node.shadow.add(fade, forKey: "fadeIn")
    }

    func remove(id: UUID) {
        guard let node = nodes.removeValue(forKey: id) else { return }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.18)
        CATransaction.setCompletionBlock {
            node.icon.removeFromSuperlayer()
            node.shadow.removeFromSuperlayer()
        }
        node.icon.opacity = 0
        node.shadow.opacity = 0
        CATransaction.commit()
    }

    func setScale(_ newScale: CGFloat) {
        guard newScale != scale else { return }
        scale = newScale
        shadowImage = FridgeArt.itemShadow(scale: newScale)
        for node in nodes.values { layout(node) }
    }

    func setDragging(_ id: UUID, _ dragging: Bool) {
        nodes[id]?.icon.opacity = dragging ? 0.25 : 1
    }

    // MARK: Queries

    /// Front-most item under a point in opening coordinates.
    func hit(at point: CGPoint) -> FridgeEntry? {
        for node in drawOrder.reversed() where node.nominal.contains(point) {
            return node.entry
        }
        return nil
    }

    /// The icon's rectangle in scene coordinates, used as the drag image frame.
    func sceneFrame(of id: UUID) -> CGRect? {
        guard let node = nodes[id] else { return nil }
        return node.nominal.offsetBy(dx: Geo.opening.minX, dy: Geo.opening.minY)
    }

    // MARK: Frost

    /// Called once when the door opens. Works out frost and freezer burn from each item's
    /// timestamp and bakes it into the icon bitmap off the main thread. Items whose look has
    /// not changed since the last bake are skipped.
    func applyFrost(now: Date, timeScale: Double) {
        bakeTicket += 1
        let ticket = bakeTicket
        var jobs: [(UUID, CGImage, FrostState)] = []
        for node in nodes.values {
            let state = FrostModel.state(placedAt: node.entry.placedAt, now: now, timeScale: timeScale)
            if state.bucket == node.bakedBucket { continue }
            guard let base = node.base else { continue }
            jobs.append((node.entry.id, base, state))
        }
        if jobs.isEmpty { return }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var results: [(UUID, CGImage, Int)] = []
            for job in jobs {
                let image = FrostRenderer.bake(job.1, state: job.2, seed: ItemsController.stableSeed(job.0))
                results.append((job.0, image, job.2.bucket))
            }
            DispatchQueue.main.async {
                guard let self = self, self.bakeTicket == ticket else { return }
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                for result in results {
                    if let node = self.nodes[result.0] {
                        node.icon.contents = result.1
                        node.bakedBucket = result.2
                    }
                }
                CATransaction.commit()
            }
        }
    }

    // MARK: Layout

    private var drawOrder: [ItemNode] {
        return nodes.values.sorted { a, b in
            let pa = ShelfLayout.rowAndColumn(forSlot: a.entry.slot)
            let pb = ShelfLayout.rowAndColumn(forSlot: b.entry.slot)
            if a.entry.shelf != b.entry.shelf { return a.entry.shelf < b.entry.shelf }
            if pa.row != pb.row { return pa.row > pb.row }   // back row first
            return pa.column < pb.column
        }
    }

    @discardableResult
    private func makeNode(_ entry: FridgeEntry) -> ItemNode {
        let node = ItemNode(entry: entry)
        nodes[entry.id] = node
        layout(node)
        return node
    }

    private func layout(_ node: ItemNode) {
        let spot = ShelfLayout.rowAndColumn(forSlot: node.entry.slot)
        let anchor = InteriorGeometry.anchor(shelf: node.entry.shelf, row: spot.row, column: spot.column)
        var rng = SeededRandom(seed: ItemsController.stableSeed(node.entry.id))
        let jitterX = rng.range(-3, 3)
        let tilt = rng.range(-0.045, 0.045)

        let points = CGFloat(InteriorGeometry.baseIconSize * anchor.scale)
        let ax = CGFloat(anchor.x) + jitterX
        let ay = CGFloat(anchor.y)
        node.points = points
        node.nominal = CGRect(x: ax - points / 2, y: ay, width: points, height: points)

        let pad = points * FrostRenderer.padFraction
        let total = points + pad * 2
        node.icon.bounds = CGRect(x: 0, y: 0, width: total, height: total)
        node.icon.anchorPoint = CGPoint(x: 0.5, y: pad / total)
        node.icon.position = CGPoint(x: ax, y: ay)
        node.icon.transform = CATransform3DMakeRotation(tilt, 0, 0, 1)
        node.icon.contentsScale = scale

        node.shadow.bounds = CGRect(x: 0, y: 0, width: points * 0.95, height: points * 0.26)
        node.shadow.position = CGPoint(x: ax, y: ay + 1)
        node.shadow.contents = shadowImage
        node.shadow.contentsScale = scale
        node.shadow.contentsGravity = .resize

        let icon = NSWorkspace.shared.icon(forFile: store.url(for: node.entry).path)
        node.base = FrostRenderer.rasterize(icon, points: points, scale: scale)
        node.bakedBucket = -1
        node.icon.contents = node.base
    }

    private func arrange() {
        for sub in layer.sublayers ?? [] { sub.removeFromSuperlayer() }
        for node in drawOrder {
            layer.addSublayer(node.shadow)
            layer.addSublayer(node.icon)
        }
    }
}
