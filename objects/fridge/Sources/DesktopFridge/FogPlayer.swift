import AppKit

/// Plays the pre-rendered fog sprite sequence once, then removes the layer from the tree.
///
/// The frames are swapped by a Core Animation keyframe animation on `contents`, which the render
/// server runs. The app does not wake per frame and no display link is needed. Frames are decoded
/// off the main thread and released as soon as the plume ends.
final class FogPlayer {
    private weak var host: CALayer?
    private var fogLayer: CALayer?
    private var generation = 0
    private(set) var isActive = false

    init(host: CALayer) {
        self.host = host
    }

    func play(scale: CGFloat) {
        guard !isActive else { return }
        isActive = true
        generation &+= 1
        let ticket = generation

        // Looking images up by name is cheap and stays on the main thread. Decoding is not.
        let images: [NSImage] = (0..<Geo.fogFrameCount).compactMap { NSImage(named: String(format: "fog_%02d", $0)) }
        guard images.count == Geo.fogFrameCount else {
            isActive = false
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let frames = images.compactMap { FogPlayer.bitmap(from: $0, scale: scale) }
            DispatchQueue.main.async {
                guard let self = self, self.isActive, self.generation == ticket else { return }
                guard frames.count == Geo.fogFrameCount else {
                    self.isActive = false
                    return
                }
                self.start(frames: frames, scale: scale)
            }
        }
    }

    /// Stops immediately and removes everything (used on lock, sleep and Low Power Mode changes).
    func cancel() {
        generation &+= 1
        fogLayer?.removeAllAnimations()
        fogLayer?.removeFromSuperlayer()
        fogLayer = nil
        isActive = false
    }

    private func start(frames: [CGImage], scale: CGFloat) {
        guard let host = host else {
            isActive = false
            return
        }
        let layer = CALayer()
        layer.frame = Geo.fogFrame
        layer.contentsScale = scale
        layer.contentsGravity = .resize
        layer.contents = frames.last
        layer.isOpaque = false
        host.addSublayer(layer)
        fogLayer = layer

        let animation = CAKeyframeAnimation(keyPath: "contents")
        animation.values = frames
        animation.calculationMode = .discrete
        animation.duration = Geo.fogDuration
        animation.isRemovedOnCompletion = true

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self, weak layer] in
            guard let self = self, let layer = layer, self.fogLayer === layer else { return }
            layer.removeFromSuperlayer()
            self.fogLayer = nil
            self.isActive = false
        }
        layer.add(animation, forKey: "fog")
        CATransaction.commit()
    }

    /// Picks the representation closest to the screen's pixel density.
    private static func bitmap(from image: NSImage, scale: CGFloat) -> CGImage? {
        let reps = image.representations.compactMap { $0 as? NSBitmapImageRep }
        let wanted = Int((image.size.width * scale).rounded())
        let sorted = reps.sorted { $0.pixelsWide < $1.pixelsWide }
        if let match = sorted.first(where: { $0.pixelsWide >= wanted }) ?? sorted.last, let cg = match.cgImage {
            return cg
        }
        var rect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
}
