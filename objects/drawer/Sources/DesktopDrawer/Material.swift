import AppKit

/// Small deterministic RNG so every texture comes out identical on every launch.
struct RNG {
    private var s: UInt64
    init(_ seed: UInt64) { s = (seed &+ 1) &* 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> CGFloat {
        s ^= s << 13; s ^= s >> 7; s ^= s << 17
        return CGFloat(s >> 11) / CGFloat(UInt64(1) << 53)
    }
    mutating func range(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * next() }
}

func srgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func nsrgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor { NSColor(cgColor: srgb(hex, alpha)) ?? .gray }

struct Wood {
    let base, dark, light, worn: UInt32
}

/// Procedural materials. Each is rendered once into a bitmap and cached, so drawing them later is a
/// plain image blit; nothing here runs while the drawer slides.
enum Material {
    static let oak = Wood(base: 0xB48659, dark: 0x6E4B2C, light: 0xD3AE80, worn: 0xE4CCA6)
    static let birch = Wood(base: 0xCDAE84, dark: 0x8F6E48, light: 0xE3CBA5, worn: 0xEEDDC0)
    static let walnut = Wood(base: 0x53331F, dark: 0x24140B, light: 0x775036, worn: 0x9C7656)
    static let walnutPly = Wood(base: 0x6E4C34, dark: 0x3B2516, light: 0x8B6649, worn: 0xA88768)

    private static var cache: [String: NSImage] = [:]

    private static func bitmap(_ key: String, _ size: CGSize, _ scale: CGFloat, _ draw: (CGContext) -> Void) -> NSImage {
        let k = "\(key)|\(size.width)x\(size.height)@\(scale)"
        if let hit = cache[k] { return hit }
        let w = max(1, Int((size.width * scale).rounded())), h = max(1, Int((size.height * scale).rounded()))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return NSImage(size: size) }
        ctx.scaleBy(x: scale, y: scale)
        draw(ctx)
        let image = ctx.makeImage().map { NSImage(cgImage: $0, size: size) } ?? NSImage(size: size)
        cache[k] = image
        return image
    }

    /// Per-pixel luminance noise, so flat fills never look like vector art.
    private static func addNoise(_ ctx: CGContext, amount: CGFloat, seed: UInt64) {
        guard let data = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return }
        var rng = RNG(seed)
        let bpr = ctx.bytesPerRow
        for y in 0..<ctx.height {
            for x in 0..<ctx.width {
                let i = y * bpr + x * 4
                let n = Int((rng.next() - 0.5) * amount * 255)
                data[i] = UInt8(clamping: Int(data[i]) + n)
                data[i + 1] = UInt8(clamping: Int(data[i + 1]) + n)
                data[i + 2] = UInt8(clamping: Int(data[i + 2]) + n)
            }
        }
    }

    /// Long-grain wood: tonal bands, fine grain lines and pores; optionally scratches, dings and
    /// finish rubbed away along the edges.
    static func wood(_ wd: Wood, size: CGSize, scale: CGFloat, seed: UInt64, worn: Bool) -> NSImage {
        bitmap("wood\(seed)-\(wd.base)-\(worn)", size, scale) { ctx in
            var rng = RNG(seed)
            let W = size.width, H = size.height
            ctx.setFillColor(srgb(wd.base))
            ctx.fill(CGRect(origin: .zero, size: size))

            let p1 = rng.range(0, 6), p2 = rng.range(0, 6), p3 = rng.range(0, 6)
            func warp(_ x: CGFloat, _ y: CGFloat) -> CGFloat {
                sin(x * 0.0042 + y * 0.035 + p1) * 4.5 + sin(x * 0.012 + y * 0.013 + p2) * 1.6
                    + sin(x * 0.031 + p3) * 0.5
            }
            func strand(_ y0: CGFloat, _ width: CGFloat, _ color: CGColor) {
                let path = CGMutablePath()
                var x: CGFloat = -6
                path.move(to: CGPoint(x: x, y: y0 + warp(x, y0)))
                while x < W + 6 { x += 5; path.addLine(to: CGPoint(x: x, y: y0 + warp(x, y0))) }
                ctx.addPath(path)
                ctx.setStrokeColor(color)
                ctx.setLineWidth(width)
                ctx.strokePath()
            }

            for _ in 0..<max(4, Int(H / 2.5)) {                               // broad tonal bands
                let dark = rng.next() < 0.55
                strand(rng.range(-12, H + 12), rng.range(2, 10), srgb(dark ? wd.dark : wd.light, rng.range(0.05, 0.14)))
            }
            for _ in 0..<Int(H * 1.5) {                                        // fine grain
                let dark = rng.next() < 0.8
                strand(rng.range(-12, H + 12), rng.range(0.25, 1.1),
                       srgb(dark ? wd.dark : wd.light, rng.range(0.05, dark ? 0.3 : 0.14)))
            }
            ctx.setFillColor(srgb(wd.dark, 0.28))                              // open pores
            for _ in 0..<Int(W * H / 45) {
                ctx.fill(CGRect(x: rng.range(0, W), y: rng.range(0, H), width: rng.range(1, 5), height: 0.5))
            }

            if worn {
                ctx.setLineCap(.round)
                for _ in 0..<Int(W / 7) {                                      // light scratches through the finish
                    let x = rng.range(0, W), y = rng.range(0, H)
                    let len = pow(rng.next(), 1.6) * 40 + 2, a = rng.range(-0.5, 0.5) + (rng.next() < 0.15 ? 1.2 : 0)
                    ctx.move(to: CGPoint(x: x, y: y))
                    ctx.addLine(to: CGPoint(x: x + cos(a) * len, y: y + sin(a) * len))
                    ctx.setStrokeColor(srgb(wd.worn, rng.range(0.06, 0.24)))
                    ctx.setLineWidth(rng.range(0.25, 0.7))
                    ctx.strokePath()
                }
                for _ in 0..<Int(W / 30) {                                     // small dings
                    let r = rng.range(0.5, 1.6)
                    ctx.setFillColor(srgb(wd.dark, rng.range(0.15, 0.35)))
                    ctx.fillEllipse(in: CGRect(x: rng.range(0, W), y: rng.range(0, H), width: r * 1.6, height: r))
                }
                for _ in 0..<Int((W + H) * 4) {                                // finish rubbed off at the edges
                    let d = pow(rng.next(), 2.4) * 6
                    let corner = rng.next() < 0.25
                    var x: CGFloat, y: CGFloat
                    switch Int(rng.next() * 4) {
                    case 0: x = corner ? pow(rng.next(), 3) * 30 : rng.range(0, W); y = d
                    case 1: x = corner ? W - pow(rng.next(), 3) * 30 : rng.range(0, W); y = H - d
                    case 2: x = d; y = corner ? pow(rng.next(), 3) * 20 : rng.range(0, H)
                    default: x = W - d; y = corner ? H - pow(rng.next(), 3) * 20 : rng.range(0, H)
                    }
                    let r = rng.range(0.3, 1.4)
                    ctx.setFillColor(srgb(wd.worn, rng.range(0.06, 0.32) * (1 - d / 7)))
                    ctx.fillEllipse(in: CGRect(x: x - r, y: y - r / 2, width: r * rng.range(1.5, 4), height: r))
                }
            }
            addNoise(ctx, amount: 0.035, seed: seed &+ 7)
        }
    }

    /// Felt liner: a fibrous nap of short light and dark hairs over the base colour.
    static func felt(_ color: UInt32, size: CGSize, scale: CGFloat) -> NSImage {
        bitmap("felt\(color)", size, scale) { ctx in
            var rng = RNG(99)
            let W = size.width, H = size.height
            ctx.setFillColor(srgb(color))
            ctx.fill(CGRect(origin: .zero, size: size))
            ctx.setLineWidth(0.35)
            ctx.setLineCap(.round)
            for _ in 0..<Int(W * H / 12) {
                let x = rng.range(0, W), y = rng.range(0, H), a = rng.range(0, .pi * 2), l = rng.range(0.8, 3.2)
                ctx.move(to: CGPoint(x: x, y: y))
                ctx.addLine(to: CGPoint(x: x + cos(a) * l, y: y + sin(a) * l))
                ctx.setStrokeColor(rng.next() < 0.5 ? CGColor(gray: 1, alpha: rng.range(0.03, 0.09))
                                                    : CGColor(gray: 0, alpha: rng.range(0.05, 0.12)))
                ctx.strokePath()
            }
            addNoise(ctx, amount: 0.07, seed: 5)
        }
    }
}
