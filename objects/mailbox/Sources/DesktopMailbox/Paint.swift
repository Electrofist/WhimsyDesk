import AppKit

/// Layout of the mailbox, in points. Origin at the bottom left of the window, y up.
enum Geo {
    /// Wider than the box so the flag fits when it lies down to the right.
    static let size = CGSize(width: 372, height: 400)

    /// The front of the mailbox: an arch (rectangle with a half circle on top).
    static let mouth = CGRect(x: 60, y: 150, width: 200, height: 180)
    /// The door sits just inside the front rim and is hinged along its bottom edge.
    static let door = mouth.insetBy(dx: 7, dy: 7)
    static var hingeY: CGFloat { door.minY }

    /// The wooden post under the box.
    static let post = CGRect(x: 144, y: 22, width: 32, height: 136)

    /// The flag turns around this point on the right side of the box.
    static let flagPivot = CGPoint(x: 278, y: 214)
    static let flagSize = CGSize(width: 96, height: 96)
    /// Where the pivot sits inside the flag image.
    static let flagAnchor = CGPoint(x: 20, y: 20)

    /// Depth of the box seen slightly from the right.
    static let depth = CGVector(dx: 13, dy: 9)
}

/// Small drawing helpers. Everything is drawn once per screen scale and cached as layer contents.
enum Paint {
    static let space = CGColorSpace(name: CGColorSpace.sRGB)!

    static func render(_ size: CGSize, scale: CGFloat, _ draw: (CGContext) -> Void) -> CGImage? {
        let w = Int((size.width * scale).rounded(.up)), h = Int((size.height * scale).rounded(.up))
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        ctx.interpolationQuality = .high
        draw(ctx)
        return ctx.makeImage()
    }

    static func hex(_ v: UInt32, _ alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                blue: CGFloat(v & 0xFF) / 255, alpha: alpha)
    }

    static func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
        CGGradient(colorsSpace: space, colors: stops.map { $0.1 } as CFArray, locations: stops.map { $0.0 })!
    }

    /// A rectangle whose top is a half circle as wide as the rectangle.
    static func arch(_ r: CGRect) -> CGPath {
        let radius = r.width / 2
        let p = CGMutablePath()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY - radius))
        p.addArc(center: CGPoint(x: r.midX, y: r.maxY - radius), radius: radius,
                 startAngle: .pi, endAngle: 0, clockwise: true)
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.closeSubpath()
        return p
    }

    static func fill(_ ctx: CGContext, _ path: CGPath, _ color: CGColor) {
        ctx.saveGState(); ctx.addPath(path); ctx.setFillColor(color); ctx.fillPath(); ctx.restoreGState()
    }

    static func fill(_ ctx: CGContext, _ path: CGPath, _ g: CGGradient, from: CGPoint, to: CGPoint) {
        ctx.saveGState(); ctx.addPath(path); ctx.clip()
        ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
    }

    static func stroke(_ ctx: CGContext, _ path: CGPath, _ color: CGColor, _ width: CGFloat) {
        ctx.saveGState(); ctx.addPath(path); ctx.setStrokeColor(color); ctx.setLineWidth(width); ctx.strokePath(); ctx.restoreGState()
    }

    static func circle(_ ctx: CGContext, _ c: CGPoint, _ r: CGFloat, _ color: CGColor) {
        fill(ctx, CGPath(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r), transform: nil), color)
    }

    /// Draws text with AppKit into a Core Graphics context.
    static func text(_ ctx: CGContext, _ string: String, at point: CGPoint, font: NSFont, color: NSColor,
                     kern: CGFloat = 0, centered: Bool = false) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let s = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color, .kern: kern])
        let x = centered ? point.x - s.size().width / 2 : point.x
        s.draw(at: NSPoint(x: x, y: point.y))
        NSGraphicsContext.restoreGraphicsState()
    }

    static func serif(_ size: CGFloat, _ weight: NSFont.Weight = .bold) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        return NSFont(descriptor: base.fontDescriptor.withDesign(.serif) ?? base.fontDescriptor, size: size) ?? base
    }

    /// A handwriting font that ships with macOS.
    static func hand(_ size: CGFloat) -> NSFont {
        NSFont(name: "BradleyHandITCTT-Bold", size: size)
            ?? NSFont(name: "Noteworthy-Light", size: size)
            ?? NSFont.systemFont(ofSize: size)
    }
}
