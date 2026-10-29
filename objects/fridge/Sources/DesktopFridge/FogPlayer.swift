import AppKit

/// Plays the pre-rendered fog sprite sequence once, then removes the layer from the tree.
///
/// The frames are swapped by a Core Animation keyframe animation on `contents`, which the render
/// server runs. The app does not wake per frame and no display link is needed. Frames are decoded
/// off the main thread and released as soon as the plume ends.
final class FogPlayer {
    private weak var host: CALayer?
    private var fogLayers: [CALayer] = []
    private var generation = 0
    private(set) var isActive = false

    init(host: CALayer) {
        self.host = host
    }

    /// `lite` (Low Power Mode) plays every other frame, at 1x, without the contrast shadow.
    func play(scale: CGFloat, lite: Bool = false) {
        guard !isActive else { return }
        isActive = true
        generation &+= 1
        let ticket = generation

        // Looking images up by name is cheap and stays on the main thread. Decoding is not.
        let stride = lite ? 2 : 1
        let names = Swift.stride(from: 0, to: Geo.fogFrameCount, by: stride).map { String(format: "fog_%02d", $0) }
        let images: [NSImage] = names.compactMap { NSImage(named: $0) }
        guard images.count == names.count else {
            isActive = false
            return
        }
        let decodeScale = lite ? 1 : scale

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let frames = images.compactMap { FogPlayer.bitmap(from: $0, scale: decodeScale) }
            DispatchQueue.main.async {
                guard let self = self, self.isActive, self.generation == ticket else { return }
                guard frames.count == names.count else {
                    self.isActive = false
                    return
                }
                self.start(frames: frames, scale: decodeScale, lite: lite)
            }
        }
    }

    /// Stops immediately and removes everything (used on lock, sleep and Low Power Mode changes).
    func cancel() {
        generation &+= 1
        for layer in fogLayers {
            layer.removeAllAnimations()
            layer.removeFromSuperlayer()
        }
        fogLayers = []
        isActive = false
    }

    private func start(frames: [CGImage], scale: CGFloat, lite: Bool) {
        guard let host = host else {
            isActive = false
            return
        }
        // Two plumes from the same frames: one spills out of the lower half of the opening and
        // sinks, the other pools on the floor in front of the feet a beat later.
        let plumes: [(frame: CGRect, delay: CFTimeInterval, flip: Bool)] = [
            (Geo.fogSpillFrame, 0, false),
            (Geo.fogFrame, 0.18, true)
        ]
        let now = CACurrentMediaTime()
        let ticket = generation
        var remaining = plumes.count

        for plume in plumes {
            let layer = CALayer()
            layer.frame = plume.frame
            layer.contentsScale = scale
            layer.contentsGravity = .resize
            layer.isOpaque = false
            layer.opacity = 0           // invisible until its animation starts
            if plume.flip { layer.transform = CATransform3DMakeScale(-1, 1, 1) }   // so the two never look alike
            if !lite {
                // A faint cool shadow under the vapour so it reads on light wallpapers too.
                layer.shadowColor = Art.color(0.10, 0.20, 0.30, 1)
                layer.shadowOpacity = 0.22
                layer.shadowRadius = 9
                layer.shadowOffset = CGSize(width: 0, height: -5)
            }
            host.addSublayer(layer)
            fogLayers.append(layer)

            let swap = CAKeyframeAnimation(keyPath: "contents")
            swap.values = frames
            swap.calculationMode = .discrete
            let show = CABasicAnimation(keyPath: "opacity")
            show.fromValue = 1
            show.toValue = 1
            let group = CAAnimationGroup()
            group.animations = [swap, show]
            group.duration = Geo.fogDuration
            group.beginTime = now + plume.delay
            group.fillMode = .backwards
            group.isRemovedOnCompletion = true

            CATransaction.begin()
            CATransaction.setCompletionBlock { [weak self, weak layer] in
                layer?.removeFromSuperlayer()
                guard let self = self, self.generation == ticket else { return }
                remaining -= 1
                if remaining == 0 {
                    self.fogLayers = []
                    self.isActive = false
                }
            }
            layer.add(group, forKey: "fog")
            CATransaction.commit()
        }
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
