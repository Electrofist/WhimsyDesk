import AppKit

/// Placeholder art drawn in code: a chunky yellow toy machine, soft and rounded, lit from the top
/// left. Painted PNGs in Resources/Art replace each piece (see ArtFiles).
enum VendingArt {
    static let yellowLight = Paint.hex(0xFFE27E)
    static let yellow = Paint.hex(0xFFC92E)
    static let yellowDeep = Paint.hex(0xF2A600)
    static let sideLight = Paint.hex(0xE69A00)
    static let sideDark = Paint.hex(0xB97200)
    static let cream = Paint.hex(0xFFF8E9)
    static let creamDeep = Paint.hex(0xEADBB8)
    static let ink = Paint.hex(0x3A2A0E)

    // MARK: Body

    /// The machine without its moving parts: body, window frame, the shelves inside, the screen
    /// surround, the lamp and the bin opening.
    static func body(scale: CGFloat) -> CGImage? {
        Paint.render(Geo.size, scale: scale) { ctx in
            let b = Geo.body

            // Feet.
            for x in [b.minX + 34, b.maxX - 70] {
                Paint.fill(ctx, Paint.rounded(CGRect(x: x, y: b.minY - 12, width: 40, height: 20), 7),
                           Paint.gradient([(0, Paint.hex(0x4A4136)), (1, Paint.hex(0x231E18))]),
                           from: CGPoint(x: 0, y: b.minY), to: CGPoint(x: 0, y: b.minY - 12))
            }

            // The right side, peeking out behind the front.
            let side = Paint.rounded(b.offsetBy(dx: Geo.side, dy: 0), Geo.bodyRadius)
            Paint.fill(ctx, side, Paint.gradient([(0, sideLight), (1, sideDark)]),
                       from: CGPoint(x: 0, y: b.maxY), to: CGPoint(x: 0, y: b.minY))

            // The front: glossy yellow plastic.
            let front = Paint.rounded(b, Geo.bodyRadius)
            Paint.fill(ctx, front, Paint.gradient([(0, yellowLight), (0.35, yellow), (1, yellowDeep)]),
                       from: CGPoint(x: b.minX, y: b.maxY), to: CGPoint(x: b.maxX * 0.8, y: b.minY))
            ctx.saveGState()
            ctx.addPath(front); ctx.clip()
            Paint.glow(ctx, at: CGPoint(x: b.minX + 70, y: b.maxY - 50), radius: 190, Paint.hex(0xFFFFFF, 0.32), squash: 0.8)
            Paint.glow(ctx, at: CGPoint(x: b.maxX, y: b.minY), radius: 220, Paint.hex(0xC97E00, 0.28))
            ctx.restoreGState()
            // A bright rim along the top and left where the light catches the rounded edge.
            Paint.stroke(ctx, Paint.rounded(b.insetBy(dx: 1.5, dy: 1.5), Geo.bodyRadius - 1.5), Paint.hex(0xFFF4C4, 0.8), 2)
            Paint.stroke(ctx, front, Paint.hex(0x9A5E00, 0.35), 1)

            window(ctx)
            screen(ctx)
            bin(ctx)
        }
    }

    /// A raised cream frame, then the inside of the machine: a lit back wall and three thin
    /// white shelves. Kept close to a real cabinet so the files look at home.
    private static func window(_ ctx: CGContext) {
        let g = Geo.glass
        let frame = g.insetBy(dx: -10, dy: -10)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 1, height: -3), blur: 6, color: Paint.hex(0x8A5600, 0.35))
        Paint.fill(ctx, Paint.rounded(frame, 24), cream)
        ctx.restoreGState()
        Paint.fill(ctx, Paint.rounded(frame, 24), Paint.gradient([(0, Paint.hex(0xFBF6EC)), (1, Paint.hex(0xE2D8C4))]),
                   from: CGPoint(x: 0, y: frame.maxY), to: CGPoint(x: 0, y: frame.minY))
        // The rubber seal around the glass.
        Paint.fill(ctx, Paint.rounded(g.insetBy(dx: -2, dy: -2), 17), Paint.hex(0x3A352D))

        let inside = Paint.rounded(g, 15)
        ctx.saveGState()
        ctx.addPath(inside); ctx.clip()
        // Back wall: warm grey, lighter near the light at the top.
        Paint.fill(ctx, CGPath(rect: g, transform: nil), Paint.gradient([(0, Paint.hex(0xF1ECE3)), (1, Paint.hex(0xCBC2B2))]),
                   from: CGPoint(x: 0, y: g.maxY), to: CGPoint(x: 0, y: g.minY))
        // Side walls, seen a little in perspective.
        for (x0, x1, a) in [(g.minX, g.minX + 9, 0.16), (g.maxX, g.maxX - 7, 0.24)] as [(CGFloat, CGFloat, CGFloat)] {
            let wall = Paint.polygon([CGPoint(x: x0, y: g.minY), CGPoint(x: x1, y: g.minY + 6),
                                      CGPoint(x: x1, y: g.maxY - 6), CGPoint(x: x0, y: g.maxY)])
            Paint.fill(ctx, wall, Paint.hex(0x5A4E3C, a))
        }
        // Each shelf space is shaded under the shelf above it.
        for row in 0..<Geo.rows.count {
            let y = Geo.shelfY(row: row) + Geo.lip
            let top = row == 0 ? g.maxY : Geo.shelfY(row: row - 1)
            Paint.fill(ctx, CGPath(rect: CGRect(x: g.minX, y: y, width: g.width, height: top - y), transform: nil),
                       Paint.gradient([(0, Paint.hex(0x4A3E2C, row == 0 ? 0.1 : 0.28)), (0.4, Paint.hex(0x4A3E2C, 0))]),
                       from: CGPoint(x: 0, y: top), to: CGPoint(x: 0, y: y))
        }
        // The light strip along the top, and the light it throws.
        Paint.glow(ctx, at: CGPoint(x: g.midX, y: g.maxY), radius: g.width * 0.75, Paint.hex(0xFFFDF6, 0.6), squash: 0.45)
        Paint.fill(ctx, Paint.rounded(CGRect(x: g.minX + 16, y: g.maxY - 5, width: g.width - 32, height: 2.5), 1.25),
                   Paint.hex(0xFFFFFF, 0.95))
        for row in 0..<Geo.rows.count { shelf(ctx, row: row) }
        // The floor of the drop gap under the bottom shelf.
        ctx.restoreGState()
        Paint.innerShadow(ctx, inside, blur: 6, offset: 2, alpha: 0.4)
    }

    private static func shelf(_ ctx: CGContext, row: Int) {
        let g = Geo.glass, y = Geo.shelfY(row: row), lip = Geo.lip, depth = Geo.shelfDepth
        // The shelf top, going back to the wall, and the dark line where it meets the wall.
        let surface = CGRect(x: g.minX, y: y + lip, width: g.width, height: depth)
        Paint.fill(ctx, CGPath(rect: surface, transform: nil), Paint.gradient([(0, Paint.hex(0xF6F2EA)), (1, Paint.hex(0xD3CBBD))]),
                   from: CGPoint(x: 0, y: surface.minY), to: CGPoint(x: 0, y: surface.maxY))
        Paint.fill(ctx, CGPath(rect: CGRect(x: g.minX, y: surface.maxY, width: g.width, height: 5), transform: nil),
                   Paint.gradient([(0, Paint.hex(0x3A3024, 0.28)), (1, Paint.hex(0x3A3024, 0))]),
                   from: CGPoint(x: 0, y: surface.maxY), to: CGPoint(x: 0, y: surface.maxY + 5))
        // The shelf front: white plastic, casting a soft shadow on the row below.
        let front = CGRect(x: g.minX - 2, y: y, width: g.width + 4, height: lip)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -3), blur: 5, color: Paint.hex(0x2A2116, 0.3))
        Paint.fill(ctx, CGPath(rect: front, transform: nil), Paint.hex(0xF4F0E8))
        ctx.restoreGState()
        Paint.fill(ctx, CGPath(rect: front, transform: nil), Paint.gradient([(0, Paint.hex(0xFBF9F4)), (1, Paint.hex(0xE0D9CC))]),
                   from: CGPoint(x: 0, y: front.maxY), to: CGPoint(x: 0, y: front.minY))
        Paint.fill(ctx, CGPath(rect: CGRect(x: front.minX, y: front.maxY - 1, width: front.width, height: 1), transform: nil),
                   Paint.hex(0xFFFFFF, 0.95))
        // A clear channel holding the paper name tags.
        let channel = CGRect(x: front.minX, y: y + 15.5, width: front.width, height: 12)
        Paint.fill(ctx, CGPath(rect: channel, transform: nil), Paint.hex(0xD9D2C4, 0.55))
        Paint.fill(ctx, CGPath(rect: CGRect(x: channel.minX, y: channel.minY, width: channel.width, height: 0.8), transform: nil),
                   Paint.hex(0x8C8270, 0.5))
        for i in 0..<Geo.columns {
            let index = row * Geo.columns + i
            let tag = Geo.labelRect(index)
            Paint.fill(ctx, CGPath(rect: tag.offsetBy(dx: 0.3, dy: -0.5), transform: nil), Paint.hex(0x3A3024, 0.18))
            Paint.fill(ctx, CGPath(rect: tag, transform: nil), Paint.hex(0xFFFEFA))
            // The hole each button sits in.
            let b = Geo.buttonRect(index)
            Paint.circle(ctx, CGPoint(x: b.midX, y: b.midY - 0.4), b.width / 2 + 0.8, Paint.hex(0x6E6656, 0.6))
        }
    }

    /// The dark screen surround and the little green lamp.
    private static func screen(_ ctx: CGContext) {
        let d = Geo.display.insetBy(dx: -5, dy: -5)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -1.5), blur: 3, color: Paint.hex(0xFFF2B8, 0.9))
        Paint.fill(ctx, Paint.rounded(d, 9), Paint.hex(0x2B2416))
        ctx.restoreGState()
        Paint.innerShadow(ctx, Paint.rounded(d, 9), blur: 3, offset: 1.5, alpha: 0.6)

        let c = Geo.lamp
        Paint.circle(ctx, c, 8.5, Paint.hex(0xD58E00))
        Paint.circle(ctx, c, 7, Paint.hex(0x2B2416))
        Paint.glow(ctx, at: c, radius: 9, Paint.hex(0x8CFFA0, 0.5))
        Paint.circle(ctx, c, 5, Paint.hex(0x5BE27A))
        Paint.circle(ctx, CGPoint(x: c.x - 1.5, y: c.y + 1.5), 1.8, Paint.hex(0xE8FFEC, 0.9))
    }

    /// The opening of the pickup bin, set into the body.
    private static func bin(_ ctx: CGContext) {
        let t = Geo.tray
        let rim = t.insetBy(dx: -8, dy: -8)
        Paint.fill(ctx, Paint.rounded(rim, 20), Paint.gradient([(0, Paint.hex(0xE39B00)), (1, Paint.hex(0xFFDB66))]),
                   from: CGPoint(x: 0, y: rim.maxY), to: CGPoint(x: 0, y: rim.minY))
        Paint.fill(ctx, Paint.rounded(t, 14), Paint.hex(0x2A1E0C))
    }

    /// A soft shadow on the ground under the feet.
    static func shadow(scale: CGFloat) -> CGImage? {
        Paint.render(Geo.size, scale: scale) { ctx in
            let b = Geo.body
            Paint.glow(ctx, at: CGPoint(x: b.midX + 8, y: b.minY - 12), radius: b.width * 0.64, Paint.hex(0x000000, 0.4), squash: 0.07)
        }
    }

    // MARK: Glass, bin and flap

    /// Only the reflections on the window. Everything else stays clear.
    static func glass(scale: CGFloat) -> CGImage? {
        let s = Geo.glass.size
        return Paint.render(s, scale: scale) { ctx in
            ctx.addPath(Paint.rounded(CGRect(origin: .zero, size: s), 15)); ctx.clip()
            let band = Paint.polygon([CGPoint(x: 0, y: s.height * 0.58), CGPoint(x: 0, y: s.height * 0.9),
                                      CGPoint(x: s.width * 0.62, y: s.height), CGPoint(x: s.width * 0.3, y: s.height)])
            Paint.fill(ctx, band, Paint.gradient([(0, Paint.hex(0xFFFFFF, 0.3)), (1, Paint.hex(0xFFFFFF, 0.04))]),
                       from: CGPoint(x: 0, y: s.height), to: CGPoint(x: s.width * 0.4, y: s.height * 0.6))
            let thin = Paint.polygon([CGPoint(x: s.width * 0.62, y: s.height), CGPoint(x: s.width * 0.68, y: s.height),
                                      CGPoint(x: s.width * 0.2, y: 0), CGPoint(x: s.width * 0.14, y: 0)])
            Paint.fill(ctx, thin, Paint.hex(0xFFFFFF, 0.08))
        }
    }

    /// The inside of the pickup bin, with a painted arrow that shows where things come out.
    static func tray(scale: CGFloat) -> CGImage? {
        let s = Geo.tray.size
        return Paint.render(s, scale: scale) { ctx in
            let r = CGRect(origin: .zero, size: s)
            ctx.addPath(Paint.rounded(r, 14)); ctx.clip()
            Paint.fill(ctx, CGPath(rect: r, transform: nil), Paint.gradient([(0, Paint.hex(0x1C1408)), (1, Paint.hex(0x4A3416))]),
                       from: CGPoint(x: 0, y: s.height), to: .zero)
            Paint.glow(ctx, at: CGPoint(x: s.width / 2, y: 0), radius: s.width * 0.55, Paint.hex(0xFFB940, 0.25), squash: 0.35)
            // The arrow, faint on the back wall.
            let cx = s.width / 2, top = s.height - 12
            let arrow = Paint.polygon([CGPoint(x: cx - 6, y: top), CGPoint(x: cx + 6, y: top), CGPoint(x: cx + 6, y: top - 18),
                                       CGPoint(x: cx + 14, y: top - 18), CGPoint(x: cx, y: top - 32),
                                       CGPoint(x: cx - 14, y: top - 18), CGPoint(x: cx - 6, y: top - 18)])
            Paint.fill(ctx, arrow, Paint.hex(0xFFC92E, 0.22))
            // The floor.
            Paint.fill(ctx, CGPath(rect: CGRect(x: 0, y: 0, width: s.width, height: 9), transform: nil),
                       Paint.gradient([(0, Paint.hex(0x6B4A1C)), (1, Paint.hex(0x3A2810))]),
                       from: .zero, to: CGPoint(x: 0, y: 9))
            Paint.innerShadow(ctx, Paint.rounded(r, 14), blur: 8, offset: 3, alpha: 0.7)
        }
    }

    /// The clear plastic flap over the bin, hinged at its top. Files show through it.
    static func flap(scale: CGFloat) -> CGImage? {
        let s = Geo.tray.size
        return Paint.render(s, scale: scale) { ctx in
            let r = CGRect(origin: .zero, size: s)
            let shape = Paint.rounded(r, 14)
            Paint.fill(ctx, shape, Paint.gradient([(0, Paint.hex(0xFFF6DA, 0.16)), (1, Paint.hex(0xFFF6DA, 0.06))]),
                       from: CGPoint(x: 0, y: s.height), to: .zero)
            ctx.saveGState()
            ctx.addPath(shape); ctx.clip()
            let sheen = Paint.polygon([CGPoint(x: s.width * 0.1, y: 0), CGPoint(x: s.width * 0.2, y: 0),
                                       CGPoint(x: s.width * 0.34, y: s.height), CGPoint(x: s.width * 0.24, y: s.height)])
            Paint.fill(ctx, sheen, Paint.hex(0xFFFFFF, 0.12))
            Paint.fill(ctx, CGPath(rect: CGRect(x: 0, y: s.height - 6, width: s.width, height: 6), transform: nil),
                       Paint.gradient([(0, Paint.hex(0xFFE9A8, 0.9)), (1, Paint.hex(0xD99500, 0.7))]),
                       from: CGPoint(x: 0, y: s.height), to: CGPoint(x: 0, y: s.height - 6))
            ctx.restoreGState()
            Paint.stroke(ctx, Paint.rounded(r.insetBy(dx: 0.75, dy: 0.75), 13.5), Paint.hex(0xFFFFFF, 0.22), 1.5)
            Paint.text(ctx, "PUSH", at: CGPoint(x: s.width / 2, y: 6), font: Paint.rounded(7, .heavy),
                       color: NSColor(white: 1, alpha: 0.45), kern: 1.6, centered: true)
        }
    }

    // MARK: Buttons and labels

    enum ButtonState: CaseIterable { case empty, ready, hover, pressed }

    /// The round push button under each file: a metal ring and a plastic cap. Grey when its shelf
    /// spot is empty, red when there is something to get.
    static func button(_ state: ButtonState, scale: CGFloat) -> CGImage? {
        let s = Geo.buttonRect(0).size
        return Paint.render(s, scale: scale) { ctx in
            let c = CGPoint(x: s.width / 2, y: s.height / 2)
            let r = s.width / 2 - 0.3
            // The metal ring.
            ctx.saveGState()
            ctx.addPath(CGPath(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r), transform: nil)); ctx.clip()
            ctx.drawLinearGradient(Paint.gradient([(0, Paint.hex(0xFAFAF7)), (0.5, Paint.hex(0xC9C5BC)), (1, Paint.hex(0x8F8A80))]),
                                   start: CGPoint(x: c.x - r, y: c.y + r), end: CGPoint(x: c.x + r, y: c.y - r), options: [])
            ctx.restoreGState()
            Paint.circle(ctx, c, r - 1.4, Paint.hex(0x4A443A))
            // The cap.
            let pressed = state == .pressed
            let cr = r - (pressed ? 2.3 : 1.9)
            let cc = CGPoint(x: c.x, y: c.y - (pressed ? 0.4 : 0))
            let (top, bottom): (UInt32, UInt32) = {
                switch state {
                case .empty: return (0xE4DFD5, 0xB3AC9F)
                case .ready: return (0xF0664A, 0xB8301A)
                case .hover: return (0xFF8064, 0xD03C22)
                case .pressed: return (0xC8452C, 0x8E2412)
                }
            }()
            ctx.saveGState()
            ctx.addPath(CGPath(ellipseIn: CGRect(x: cc.x - cr, y: cc.y - cr, width: 2 * cr, height: 2 * cr), transform: nil)); ctx.clip()
            ctx.drawLinearGradient(Paint.gradient([(0, Paint.hex(top)), (1, Paint.hex(bottom))]),
                                   start: CGPoint(x: cc.x, y: cc.y + cr), end: CGPoint(x: cc.x, y: cc.y - cr), options: [])
            ctx.restoreGState()
            // A small highlight where the light catches the cap.
            Paint.glow(ctx, at: CGPoint(x: cc.x - cr * 0.3, y: cc.y + cr * 0.38), radius: cr * (pressed ? 0.35 : 0.5),
                       Paint.hex(0xFFFFFF, pressed ? 0.35 : 0.75))
        }
    }

    /// The file's name, printed on its paper tag.
    static func label(name: String?, scale: CGFloat) -> CGImage? {
        let size = Geo.labelRect(0).size
        return Paint.render(size, scale: scale) { ctx in
            guard let name else { return }
            let font = NSFont.systemFont(ofSize: 6.8, weight: .medium)
            let room = size.width - 5
            var text = (name as NSString).deletingPathExtension
            func width(_ t: String) -> CGFloat { (t as NSString).size(withAttributes: [.font: font]).width }
            if width(text) > room {
                while !text.isEmpty && width(text + "…") > room { text.removeLast() }
                text = text.trimmingCharacters(in: .whitespaces) + "…"
            }
            let h = (text as NSString).size(withAttributes: [.font: font]).height
            Paint.text(ctx, text, at: CGPoint(x: size.width / 2, y: (size.height - h) / 2 + 0.4), font: font,
                       color: NSColor(cgColor: Paint.hex(0x2E2A24))!, centered: true)
        }
    }

    // MARK: App icon

    /// The machine on a square canvas, for the app icon: DesktopVendingMachine --render-icon out.png
    static func iconArt(size: CGFloat) -> CGImage? {
        let scale = size / Geo.size.height * 0.94
        return Paint.render(CGSize(width: size, height: size), scale: 1) { ctx in
            let w = Geo.size.width * scale
            ctx.translateBy(x: (size - w) / 2, y: size * 0.02)
            ctx.scaleBy(x: scale, y: scale)
            let draw: (CGImage?, CGRect) -> Void = { image, rect in if let image { ctx.draw(image, in: rect) } }
            draw(body(scale: scale), CGRect(origin: .zero, size: Geo.size))
            draw(tray(scale: scale), Geo.tray)
            let ready = button(.ready, scale: scale)
            for i in 0..<Geo.slotCount {
                let b = Geo.buttonRect(i)
                draw(ready, b)
            }
            draw(glass(scale: scale), Geo.glass)
            draw(flap(scale: scale), Geo.tray)
        }
    }
}

extension Paint {
    static func polygon(_ points: [CGPoint]) -> CGPath {
        let p = CGMutablePath()
        p.addLines(between: points)
        p.closeSubpath()
        return p
    }
}
