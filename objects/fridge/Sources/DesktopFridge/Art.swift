import AppKit

/// Small CoreGraphics helpers shared by the art renderers. Everything here runs at event time
/// (launch, scale change), never per frame.
enum Art {
    static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    static func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
        return CGColor(srgbRed: r, green: g, blue: b, alpha: a)
    }

    static func hex(_ value: UInt32, _ alpha: CGFloat = 1) -> CGColor {
        let r = CGFloat((value >> 16) & 0xFF) / 255
        let g = CGFloat((value >> 8) & 0xFF) / 255
        let b = CGFloat(value & 0xFF) / 255
        return CGColor(srgbRed: r, green: g, blue: b, alpha: alpha)
    }

    static func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
        let colors = stops.map { $0.1 } as CFArray
        var locations = stops.map { $0.0 }
        return CGGradient(colorsSpace: colorSpace, colors: colors, locations: &locations)!
    }

    /// Draws into a bitmap of `size` points at `scale`, with a bottom-left origin in points.
    static func render(size: CGSize, scale: CGFloat, _ draw: (CGContext) -> Void) -> CGImage? {
        let w = max(1, Int((size.width * scale).rounded()))
        let h = max(1, Int((size.height * scale).rounded()))
        guard let ctx = CGContext(data: nil,
                                  width: w,
                                  height: h,
                                  bitsPerComponent: 8,
                                  bytesPerRow: 0,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.setAllowsAntialiasing(true)
        ctx.scaleBy(x: scale, y: scale)
        draw(ctx)
        return ctx.makeImage()
    }

    static func roundedPath(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
        let r = min(radius, min(rect.width, rect.height) / 2)
        return CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
    }

    static func polygon(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        for p in points.dropFirst() { path.addLine(to: p) }
        path.closeSubpath()
        return path
    }

    /// Fills `path` with a linear gradient between two points.
    static func fill(_ ctx: CGContext, path: CGPath, gradient: CGGradient, from: CGPoint, to: CGPoint) {
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.drawLinearGradient(gradient, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
    }

    static func fill(_ ctx: CGContext, path: CGPath, color: CGColor) {
        ctx.saveGState()
        ctx.addPath(path)
        ctx.setFillColor(color)
        ctx.fillPath()
        ctx.restoreGState()
    }

    static func stroke(_ ctx: CGContext, path: CGPath, color: CGColor, width: CGFloat) {
        ctx.saveGState()
        ctx.addPath(path)
        ctx.setStrokeColor(color)
        ctx.setLineWidth(width)
        ctx.strokePath()
        ctx.restoreGState()
    }
}

/// Deterministic random numbers so generated frost and droplets look the same on every launch.
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed &+ 0x9E37_79B9_7F4A_7C15
    }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func unit() -> CGFloat {
        return CGFloat(Double(next() >> 11) / Double(1 << 53))
    }

    mutating func range(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
        return a + (b - a) * unit()
    }
}
