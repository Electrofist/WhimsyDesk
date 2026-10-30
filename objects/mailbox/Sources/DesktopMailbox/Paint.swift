import AppKit

/// Layout of the post box, in points. Origin at the bottom left of the window, y up.
enum Geo {
    /// Room on the left for the door when it swings wide open.
    static let size = CGSize(width: 360, height: 440)

    /// The front face: a tall box with a domed top.
    static let box = CGRect(x: 90, y: 112, width: 220, height: 300)
    static let domeHeight: CGFloat = 64
    /// Depth of the box seen slightly from the right.
    static let depth = CGVector(dx: 12, dy: 8)

    /// The door in the lower front, hinged on its left edge.
    static let door = CGRect(x: 112, y: 122, width: 176, height: 148)
    static var hingeX: CGFloat { door.minX }

    /// The letter slot and the hood over it.
    static let slot = CGRect(x: 120, y: 318, width: 160, height: 13)
    static let hood = CGRect(x: 110, y: 329, width: 180, height: 17)

    /// The grey pole under the box.
    static let post = CGRect(x: 182, y: 20, width: 36, height: 96)

    /// A letter waiting in the slot sticks out this far below it.
    static let peek = CGRect(x: 172, y: 305, width: 56, height: 38)
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

    /// A rectangle with a gently domed top of the given height.
    static func dome(_ r: CGRect, _ height: CGFloat) -> CGPath {
        let h = min(height, r.height), k: CGFloat = 0.5523
        let p = CGMutablePath()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY - h))
        p.addCurve(to: CGPoint(x: r.midX, y: r.maxY), control1: CGPoint(x: r.minX, y: r.maxY - h + h * k),
                   control2: CGPoint(x: r.midX - r.width / 2 * k, y: r.maxY))
        p.addCurve(to: CGPoint(x: r.maxX, y: r.maxY - h), control1: CGPoint(x: r.midX + r.width / 2 * k, y: r.maxY),
                   control2: CGPoint(x: r.maxX, y: r.maxY - h + h * k))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.closeSubpath()
        return p
    }

    static func rounded(_ r: CGRect, _ radius: CGFloat) -> CGPath {
        CGPath(roundedRect: r, cornerWidth: min(radius, r.width / 2), cornerHeight: min(radius, r.height / 2), transform: nil)
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
