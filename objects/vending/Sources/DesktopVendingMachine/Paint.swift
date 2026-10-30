import AppKit

/// Layout of the machine, in points. Origin at the bottom left of the window, y up.
enum Geo {
    /// The machine grows taller with each shelf; the shelves never get squeezed.
    static let rowHeight: CGFloat = 96
    static var shelvesHeight: CGFloat { rowHeight * CGFloat(rows.count) }

    static let size = CGSize(width: 360, height: 232 + shelvesHeight)

    /// The rounded body, seen from the front. Its right side shows a little, `side` deep.
    static let body = CGRect(x: 20, y: 30, width: 310, height: 186 + shelvesHeight)
    static let bodyRadius: CGFloat = 38
    static let side: CGFloat = 9

    /// The window. Four shelves of files stand behind it, A at the top to D at the bottom.
    static let glass = CGRect(x: 42, y: 196, width: 266, height: shelvesHeight)

    /// The little screen between the window and the bin, and the lamp beside it.
    static let display = CGRect(x: 112, y: 152, width: 126, height: 24)
    static let lamp = CGPoint(x: 262, y: 164)

    /// The pickup bin, behind a clear flap.
    static let tray = CGRect(x: 52, y: 58, width: 246, height: 74)

    // MARK: Slots

    static let rows = ["A", "B", "C", "D"]
    static let columns = 3
    static var slotCount: Int { rows.count * columns }
    static let columnWidth: CGFloat = glass.width / CGFloat(columns)
    static let iconSize: CGFloat = 44
    /// Height of the shelf front, where the button and the name sit.
    static let lip: CGFloat = 28
    /// Depth of a shelf's top surface, seen from a little above.
    static let shelfDepth: CGFloat = 9

    /// "A1" for slot 0. Codes are only used inside; the buttons are what you press.
    static func code(_ index: Int) -> String { "\(rows[index / columns])\(index % columns + 1)" }

    static func index(of code: String) -> Int? {
        guard code.count == 2, let row = rows.firstIndex(of: String(code.prefix(1))),
              let column = Int(code.suffix(1)), (1...columns).contains(column) else { return nil }
        return row * columns + column - 1
    }

    /// The bottom of a row's shelf front.
    static func shelfY(row: Int) -> CGFloat { glass.maxY - CGFloat(row + 1) * rowHeight }

    static func columnMidX(_ index: Int) -> CGFloat { glass.minX + columnWidth * (CGFloat(index % columns) + 0.5) }

    /// A stored file stands on its shelf.
    static func iconRect(_ index: Int) -> CGRect {
        let y = shelfY(row: index / columns) + lip + 3
        return CGRect(x: columnMidX(index) - iconSize / 2, y: y, width: iconSize, height: iconSize)
    }

    /// The space above a shelf front that belongs to one slot: where a dropped file will stand.
    static func slotRect(_ index: Int) -> CGRect {
        let y = shelfY(row: index / columns)
        return CGRect(x: columnMidX(index) - columnWidth / 2 + 4, y: y + lip + 1, width: columnWidth - 8, height: rowHeight - lip - 5)
    }

    /// The round push button under each file, below its name tag.
    static func buttonRect(_ index: Int) -> CGRect {
        CGRect(x: columnMidX(index) - 7, y: shelfY(row: index / columns) + 2, width: 14, height: 14)
    }

    /// The paper name tag in the shelf edge, just under the file.
    static func labelRect(_ index: Int) -> CGRect {
        CGRect(x: columnMidX(index) - 29, y: shelfY(row: index / columns) + 17, width: 58, height: 10)
    }

    /// Where the n-th file of `count` lies in the bin.
    static let trayIcon: CGFloat = 40
    static func traySpot(_ n: Int, of count: Int) -> CGRect {
        let room = tray.width - 24 - trayIcon
        let step = count > 1 ? min(46, room / CGFloat(count - 1)) : 0
        let start = tray.midX - step * CGFloat(count - 1) / 2 - trayIcon / 2
        return CGRect(x: start + step * CGFloat(n), y: tray.minY + 9, width: trayIcon, height: trayIcon)
    }
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

    /// A soft glow or shade: a radial fade from `color` at the centre to nothing at `radius`.
    static func glow(_ ctx: CGContext, at c: CGPoint, radius: CGFloat, _ color: CGColor, squash: CGFloat = 1) {
        ctx.saveGState()
        ctx.translateBy(x: c.x, y: c.y)
        ctx.scaleBy(x: 1, y: squash)
        let g = gradient([(0, color), (1, color.copy(alpha: 0)!)])
        ctx.drawRadialGradient(g, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: radius, options: [])
        ctx.restoreGState()
    }

    /// Clips to the inside of `path`, then draws a soft shadow falling in from its top edge,
    /// so the area looks set into the surface.
    static func innerShadow(_ ctx: CGContext, _ path: CGPath, blur: CGFloat, offset: CGFloat, alpha: CGFloat) {
        ctx.saveGState()
        ctx.addPath(path); ctx.clip()
        let outer = CGMutablePath()
        outer.addRect(path.boundingBox.insetBy(dx: -60, dy: -60))
        outer.addPath(path)
        ctx.setShadow(offset: CGSize(width: 0, height: -offset), blur: blur, color: hex(0x000000, alpha))
        ctx.addPath(outer)
        ctx.setFillColor(hex(0x000000))
        ctx.fillPath(using: .evenOdd)
        ctx.restoreGState()
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

    static func rounded(_ size: CGFloat, _ weight: NSFont.Weight = .bold) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        return NSFont(descriptor: base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor, size: size) ?? base
    }
}
