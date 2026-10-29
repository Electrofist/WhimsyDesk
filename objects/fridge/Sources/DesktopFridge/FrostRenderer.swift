import AppKit
import FridgeCore

/// Turns a file icon into a shelf-ready bitmap, and bakes frost and freezer burn into it.
/// Baking happens once per item per look (see `FrostState.bucket`), when the door opens.
/// The result is a plain bitmap, so frosted items cost nothing while they sit there.
enum FrostRenderer {
    /// Extra room around the icon, as a fraction of its size, so the icy edge glow fits.
    static let padFraction: CGFloat = 0.07

    /// Rasterizes an icon with padding. `points` is the nominal icon size.
    static func rasterize(_ icon: NSImage, points: CGFloat, scale: CGFloat) -> CGImage? {
        let pad = points * padFraction
        let total = CGSize(width: points + pad * 2, height: points + pad * 2)
        return Art.render(size: total, scale: scale) { ctx in
            let previous = NSGraphicsContext.current
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            icon.draw(in: NSRect(x: pad, y: pad, width: points, height: points),
                      from: .zero,
                      operation: .sourceOver,
                      fraction: 1,
                      respectFlipped: true,
                      hints: [.interpolation: NSNumber(value: NSImageInterpolation.high.rawValue)])
            NSGraphicsContext.current = previous
        }
    }

    /// Returns `base` untouched when the item is fresh.
    static func bake(_ base: CGImage, state: FrostState, seed: UInt64) -> CGImage {
        if state.frost < 0.03 && state.burn < 0.02 { return base }

        let w = base.width
        let h = base.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: Art.colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return base }

        ctx.draw(base, in: CGRect(x: 0, y: 0, width: w, height: h))
        let bytesPerRow = ctx.bytesPerRow
        let px = data.bindMemory(to: UInt8.self, capacity: bytesPerRow * h)

        let desaturate = Float(state.burn) * 0.85          // up to about 47% at the cap
        let iceTint = Float(state.burn) * 0.16
        let frost = Float(state.frost)

        // Row 0 is the top of the image in a bitmap context's memory.
        for y in 0..<h {
            let ty = Float(y) / Float(max(h - 1, 1))
            // Rime gathers on the top half and fades downward.
            let hazeBase = frost * 0.50 * powf(max(0, 1 - ty * 1.35), 1.7)
            let row = y * bytesPerRow
            for x in 0..<w {
                let i = row + x * 4
                let a = Float(px[i + 3])
                if a == 0 { continue }
                var r = Float(px[i]), g = Float(px[i + 1]), b = Float(px[i + 2])

                if desaturate > 0 {
                    let luma = 0.299 * r + 0.587 * g + 0.114 * b
                    r += (luma - r) * desaturate
                    g += (luma - g) * desaturate
                    b += (luma - b) * desaturate
                }
                if iceTint > 0 {
                    // Premultiplied target: ice color scaled by alpha.
                    r += (0.78 * a - r) * iceTint
                    g += (0.91 * a - g) * iceTint
                    b += (1.00 * a - b) * iceTint
                }
                if hazeBase > 0 {
                    r += (a - r) * hazeBase
                    g += (a - g) * hazeBase
                    b += (a - b) * hazeBase
                }
                px[i] = UInt8(max(0, min(255, r)))
                px[i + 1] = UInt8(max(0, min(255, g)))
                px[i + 2] = UInt8(max(0, min(255, b)))
            }
        }

        // Rime specks: tiny bright pixels scattered over opaque areas, denser near the top.
        var rng = SeededRandom(seed: seed)
        let specks = Int(Double(frost) * Double(w * h) * 0.014)
        for _ in 0..<specks {
            let x = Int(rng.range(0, CGFloat(w)))
            // Square the random number so specks bias toward the top rows.
            let u = rng.unit()
            let y = Int(u * u * CGFloat(h))
            let i = min(y, h - 1) * bytesPerRow + min(x, w - 1) * 4
            let a = Float(px[i + 3])
            if a < 200 { continue }
            let k = Float(rng.range(0.4, 0.9))
            px[i] = UInt8(min(255, Float(px[i]) + (a - Float(px[i])) * k))
            px[i + 1] = UInt8(min(255, Float(px[i + 1]) + (a - Float(px[i + 1])) * k))
            px[i + 2] = UInt8(min(255, Float(px[i + 2]) + (a - Float(px[i + 2])) * k))
        }

        guard let processed = ctx.makeImage() else { return base }
        if state.burn < 0.05 { return processed }

        // Thin icy edge: draw again with a pale cyan glow that follows the icon's silhouette.
        guard let glowCtx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: Art.colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return processed
        }
        let blur = CGFloat(w) * 0.035
        glowCtx.setShadow(offset: .zero, blur: blur, color: Art.color(0.80, 0.94, 1.0, CGFloat(state.burn) * 1.4))
        glowCtx.draw(processed, in: CGRect(x: 0, y: 0, width: w, height: h))
        return glowCtx.makeImage() ?? processed
    }
}
