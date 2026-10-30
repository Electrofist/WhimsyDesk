import AppKit

/// Layout of the machine, in points. Origin at the bottom left of the window, y up.
enum Geo {
    static let size = CGSize(width: 396, height: 560)

    /// The front face of the cabinet. The right side and the top show a little, `depth` deep.
    static let cabinet = CGRect(x: 22, y: 30, width: 342, height: 500)
    static let depth = CGVector(dx: 14, dy: 9)

    /// The lit sign along the top.
    static let header = CGRect(x: 38, y: 494, width: 310, height: 28)

    /// The window on the left two thirds. Rows of coils sit behind it.
    static let glass = CGRect(x: 38, y: 150, width: 212, height: 336)

    /// The control panel on the right third: display and keypad.
    static let panel = CGRect(x: 262, y: 150, width: 88, height: 336)
    static let display = CGRect(x: 268, y: 434, width: 76, height: 42)

    /// The pickup tray under the glass, behind a hinged flap.
    static let tray = CGRect(x: 60, y: 58, width: 168, height: 52)

    // MARK: Slots

    static let rows = ["A", "B", "C", "D"]
    static let columns = 5
    static var slotCount: Int { rows.count * columns }
    static let rowHeight: CGFloat = 78
    /// The bottom of the drop gap under row D, where a falling file passes into the tray.
    static let rowsTop: CGFloat = 480
    static let columnWidth: CGFloat = (glass.width - 4) / CGFloat(columns)
    static let coilRadius: CGFloat = 19
    static let iconSize: CGFloat = 30

    /// "A1" for slot 0, "D5" for slot 19.
    static func code(_ index: Int) -> String { "\(rows[index / columns])\(index % columns + 1)" }

    static func index(of code: String) -> Int? {
        guard code.count == 2, let row = rows.firstIndex(of: String(code.prefix(1))),
              let column = Int(code.suffix(1)), (1...columns).contains(column) else { return nil }
        return row * columns + column - 1
    }

    /// The bottom of the shelf a row of coils sits on.
    static func shelfY(row: Int) -> CGFloat { rowsTop - CGFloat(row + 1) * rowHeight }

    static func coilCenter(_ index: Int) -> CGPoint {
        let row = index / columns, column = index % columns
        return CGPoint(x: glass.minX + 2 + columnWidth * (CGFloat(column) + 0.5), y: shelfY(row: row) + 36)
    }

    /// The icon of a stored file rests in its coil, a touch below the middle.
    static func iconRect(_ index: Int) -> CGRect {
        let c = coilCenter(index)
        return CGRect(x: c.x - iconSize / 2, y: c.y - iconSize / 2 - 1, width: iconSize, height: iconSize)
    }

    static func coilRect(_ index: Int) -> CGRect {
        let c = coilCenter(index), r = coilRadius + 3
        return CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
    }

    /// The little paper label on the shelf edge under each coil.
    static func labelRect(_ index: Int) -> CGRect {
        let c = coilCenter(index)
        return CGRect(x: c.x - 19, y: shelfY(row: index / columns) + 2, width: 38, height: 9)
    }

    /// Where the n-th file of `count` lies in the tray.
    static func traySpot(_ n: Int, of count: Int) -> CGRect {
        let room = tray.width - 16 - iconSize
        let step = count > 1 ? min(34, room / CGFloat(count - 1)) : 0
        let start = tray.midX - step * CGFloat(count - 1) / 2 - iconSize / 2
        return CGRect(x: start + step * CGFloat(n), y: tray.minY + 6, width: iconSize, height: iconSize)
    }

    // MARK: Keypad

    enum Key: Equatable {
        case letter(String), digit(Int), clear, ok

        var label: String {
            switch self {
            case .letter(let l): return l
            case .digit(let d): return "\(d)"
            case .clear: return "CLR"
            case .ok: return "OK"
            }
        }
    }

    /// Letters on top, then digits, Clear and a wide OK.
    static let keys: [(key: Key, rect: CGRect)] = {
        var out: [(Key, CGRect)] = []
        let x0 = display.minX, w = display.width, h: CGFloat = 15, gap: CGFloat = 4
        let small = (w - 3 * gap) / 4
        for (i, l) in rows.enumerated() {
            out.append((.letter(l), CGRect(x: x0 + CGFloat(i) * (small + gap), y: 402, width: small, height: h)))
        }
        let third = (w - 2 * gap) / 3
        let lower: [Key] = [.digit(1), .digit(2), .digit(3), .digit(4), .digit(5), .clear]
        for (i, k) in lower.enumerated() {
            out.append((k, CGRect(x: x0 + CGFloat(i % 3) * (third + gap), y: 382 - CGFloat(i / 3) * (h + gap - 1),
                                  width: third, height: h)))
        }
        out.append((.ok, CGRect(x: x0, y: 342, width: w, height: h)))
        return out
    }()
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

    static func polygon(_ points: [CGPoint]) -> CGPath {
        let p = CGMutablePath()
        p.addLines(between: points)
        p.closeSubpath()
        return p
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
