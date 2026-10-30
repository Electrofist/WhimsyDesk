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
            keypadPlate(ctx)
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
        // A clear channel holding the paper tags.
        let channel = CGRect(x: front.minX, y: y + 1.5, width: front.width, height: 13)
        Paint.fill(ctx, CGPath(rect: channel, transform: nil), Paint.hex(0xD9D2C4, 0.55))
        for i in 0..<Geo.columns {
            let tag = Geo.labelRect(row * Geo.columns + i)
            Paint.fill(ctx, CGPath(rect: tag.offsetBy(dx: 0.3, dy: -0.5), transform: nil), Paint.hex(0x3A3024, 0.18))
            Paint.fill(ctx, CGPath(rect: tag, transform: nil), Paint.hex(0xFFFEFA))
        }
    }

    /// The steel plate the keypad sits on, set into the body.
    private static func keypadPlate(_ ctx: CGContext) {
        let p = Geo.panel
        let plate = Paint.rounded(p, 12)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -1.5), blur: 3, color: Paint.hex(0xFFF2B8, 0.9))
        Paint.fill(ctx, plate, Paint.hex(0xBDB8AE))
        ctx.restoreGState()
        Paint.fill(ctx, plate, Paint.gradient([(0, Paint.hex(0xE6E3DC)), (1, Paint.hex(0xA9A498))]),
                   from: CGPoint(x: p.minX, y: p.maxY), to: CGPoint(x: p.maxX, y: p.minY))
        Paint.innerShadow(ctx, plate, blur: 4, offset: 1.5, alpha: 0.35)
        for (x, y) in [(p.minX + 7, p.maxY - 7), (p.maxX - 7, p.maxY - 7), (p.minX + 7, p.minY + 7), (p.maxX - 7, p.minY + 7)] {
            Paint.circle(ctx, CGPoint(x: x, y: y), 2, Paint.hex(0x7D776C))
            Paint.circle(ctx, CGPoint(x: x - 0.3, y: y + 0.3), 1.3, Paint.hex(0xE2DED6))
        }
        // The well each key sits in.
        for (_, r) in Geo.keys {
            Paint.fill(ctx, Paint.rounded(r.insetBy(dx: -1.5, dy: -1.5).offsetBy(dx: 0, dy: -0.5), 5), Paint.hex(0x5E584E, 0.7))
        }
        let ink = NSColor(cgColor: Paint.hex(0x4A443A))!
        let small = NSFont.systemFont(ofSize: 5.6, weight: .semibold)
        Paint.text(ctx, "PICK A CODE", at: CGPoint(x: p.midX, y: Geo.keys.last!.rect.minY - 22), font: small, color: ink, kern: 0.5, centered: true)
        Paint.text(ctx, "THEN OK", at: CGPoint(x: p.midX, y: Geo.keys.last!.rect.minY - 30), font: small, color: ink, kern: 0.5, centered: true)
        // A speaker grille low on the plate.
        for i in 0..<8 {
            Paint.fill(ctx, Paint.rounded(CGRect(x: p.minX + 14, y: p.minY + 22 + CGFloat(i) * 7, width: p.width - 28, height: 2.6), 1.3),
                       Paint.hex(0x6E685E, 0.75))
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

    // MARK: Keys and labels

    /// A cream plastic key with its label, up or pushed in.
    static func key(_ label: String, ok: Bool, pressed: Bool, size: CGSize, scale: CGFloat) -> CGImage? {
        return Paint.render(CGSize(width: size.width, height: size.height + 2), scale: scale) { ctx in
            let face = CGRect(x: 0, y: pressed ? 1 : 2, width: size.width, height: size.height - (pressed ? 0.5 : 0))
            if !pressed {
                Paint.fill(ctx, Paint.rounded(face.offsetBy(dx: 0, dy: -1.8), 4), ok ? Paint.hex(0x8E2A16) : Paint.hex(0x9C937F))
            }
            let (top, bottom): (UInt32, UInt32) = ok ? (pressed ? (0xC8452C, 0x9A2C18) : (0xF06A4C, 0xC73E22))
                                                     : (pressed ? (0xDCD4C2, 0xBDB39E) : (0xFBF7EE, 0xE2D9C6))
            Paint.fill(ctx, Paint.rounded(face, 4), Paint.gradient([(0, Paint.hex(top)), (1, Paint.hex(bottom))]),
                       from: CGPoint(x: 0, y: face.maxY), to: CGPoint(x: 0, y: face.minY))
            let font = Paint.rounded(label.count > 1 ? 6.8 : 8.5, .heavy)
            let color = ok ? NSColor(white: 1, alpha: 0.95) : NSColor(cgColor: Paint.hex(0x3A3428))!
            let h = (label as NSString).size(withAttributes: [.font: font]).height
            Paint.text(ctx, label, at: CGPoint(x: face.midX, y: face.midY - h / 2 + 0.3), font: font, color: color,
                       kern: label.count > 1 ? 0.4 : 0, centered: true)
        }
    }

    /// The paper tag under a coil: its code in bold, then as much of the name as fits.
    static func label(code: String, name: String?, scale: CGFloat) -> CGImage? {
        let size = Geo.labelRect(0).size
        return Paint.render(size, scale: scale) { ctx in
            let ink = NSColor(cgColor: Paint.hex(0x2E2A24))!
            let codeFont = NSFont.systemFont(ofSize: 6.6, weight: .heavy)
            let nameFont = NSFont.systemFont(ofSize: 6.6, weight: .medium)
            let s = NSMutableAttributedString(string: code, attributes: [.font: codeFont, .foregroundColor: ink])
            if let name {
                let room = size.width - 4 - s.size().width - 3
                var text = (name as NSString).deletingPathExtension
                func width(_ t: String) -> CGFloat { (t as NSString).size(withAttributes: [.font: nameFont]).width }
                if width(text) > room {
                    while !text.isEmpty && width(text + "…") > room { text.removeLast() }
                    text = text.trimmingCharacters(in: .whitespaces) + "…"
                }
                s.append(NSAttributedString(string: " " + text, attributes: [.font: nameFont, .foregroundColor: ink]))
            }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            s.draw(at: NSPoint(x: max(2, (size.width - s.size().width) / 2), y: (size.height - s.size().height) / 2 + 0.4))
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    // MARK: App icon

    /// The machine on a square canvas, for the app icon: DesktopVendingKeypad --render-icon out.png
    static func iconArt(size: CGFloat) -> CGImage? {
        let scale = size / Geo.size.width * 0.94
        return Paint.render(CGSize(width: size, height: size), scale: 1) { ctx in
            let h = Geo.size.height * scale
            ctx.translateBy(x: size * 0.02, y: (size - h) / 2)
            ctx.scaleBy(x: scale, y: scale)
            let draw: (CGImage?, CGRect) -> Void = { image, rect in if let image { ctx.draw(image, in: rect) } }
            draw(body(scale: scale), CGRect(origin: .zero, size: Geo.size))
            draw(tray(scale: scale), Geo.tray)
            for (k, r) in Geo.keys {
                draw(key(k.label, ok: k == .ok, pressed: false, size: r.size, scale: scale), CGRect(x: r.minX, y: r.minY - 2, width: r.width, height: r.height + 2))
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
