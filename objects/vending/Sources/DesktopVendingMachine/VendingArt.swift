import AppKit

/// Placeholder art drawn in code. Painted PNGs in Resources/Art replace each piece (see ArtFiles).
/// Lit from the top left; the right side and top of the cabinet show a little.
enum VendingArt {
    // Teal enamel cabinet, cream sign, brushed steel panel.
    static let tealLight = Paint.hex(0x47BDB2)
    static let teal = Paint.hex(0x2C9890)
    static let tealDark = Paint.hex(0x1E6E69)
    static let tealSide = Paint.hex(0x175753)
    static let tealTop = Paint.hex(0x63CCC2)

    // MARK: Cabinet

    /// The whole cabinet with its window, empty shelves and coil spots. The tray opening is left dark;
    /// the tray, coils, glass, flap and panel are separate layers on top.
    static func cabinet(scale: CGFloat) -> CGImage? {
        Paint.render(Geo.size, scale: scale) { ctx in
            let c = Geo.cabinet, d = Geo.depth

            // Feet.
            for x in [c.minX + 14, c.maxX - 34] {
                Paint.fill(ctx, Paint.rounded(CGRect(x: x, y: c.minY - 10, width: 20, height: 14), 2),
                           Paint.gradient([(0, Paint.hex(0x3A3A3A)), (1, Paint.hex(0x161616))]),
                           from: CGPoint(x: x, y: 0), to: CGPoint(x: x + 20, y: 0))
            }

            // The right side and the top, seen a little from above and to the right.
            let side = Paint.polygon([CGPoint(x: c.maxX - 6, y: c.minY), CGPoint(x: c.maxX + d.dx, y: c.minY + d.dy),
                                      CGPoint(x: c.maxX + d.dx, y: c.maxY + d.dy - 6), CGPoint(x: c.maxX - 6, y: c.maxY)])
            Paint.fill(ctx, side, Paint.gradient([(0, tealSide), (1, Paint.hex(0x103F3C))]),
                       from: CGPoint(x: 0, y: c.maxY), to: CGPoint(x: 0, y: c.minY))
            let top = Paint.polygon([CGPoint(x: c.minX + 6, y: c.maxY - 2), CGPoint(x: c.minX + 6 + d.dx, y: c.maxY + d.dy),
                                     CGPoint(x: c.maxX + d.dx, y: c.maxY + d.dy), CGPoint(x: c.maxX - 2, y: c.maxY - 2)])
            Paint.fill(ctx, top, Paint.gradient([(0, tealTop), (1, tealLight)]),
                       from: CGPoint(x: c.minX, y: 0), to: CGPoint(x: c.maxX, y: 0))

            // The front, lit from the top left.
            let front = Paint.rounded(c, 10)
            Paint.fill(ctx, front, Paint.gradient([(0, tealLight), (0.45, teal), (1, tealDark)]),
                       from: CGPoint(x: c.minX, y: c.maxY), to: CGPoint(x: c.maxX, y: c.minY))
            Paint.stroke(ctx, Paint.rounded(c.insetBy(dx: 0.75, dy: 0.75), 10), Paint.hex(0xFFFFFF, 0.25), 1.5)
            Paint.stroke(ctx, front, Paint.hex(0x0D3533, 0.6), 1)

            // Kick plate with vent slots.
            let kick = CGRect(x: c.minX + 8, y: c.minY + 6, width: c.width - 16, height: 16)
            Paint.fill(ctx, Paint.rounded(kick, 3), Paint.hex(0x175753))
            for i in 0..<14 {
                let x = kick.minX + 12 + CGFloat(i) * ((kick.width - 24) / 14)
                Paint.fill(ctx, Paint.rounded(CGRect(x: x, y: kick.minY + 5, width: 12, height: 3), 1.5), Paint.hex(0x0A2A28))
            }

            sign(ctx)
            window(ctx)
            trayFrame(ctx)
        }
    }

    /// The cream sign along the top.
    private static func sign(_ ctx: CGContext) {
        let h = Geo.header
        Paint.fill(ctx, Paint.rounded(h.insetBy(dx: -3, dy: -3), 7), Paint.hex(0x123F3C))
        Paint.fill(ctx, Paint.rounded(h, 5), Paint.gradient([(0, Paint.hex(0xFFF6DF)), (1, Paint.hex(0xEADAB4))]),
                   from: CGPoint(x: 0, y: h.maxY), to: CGPoint(x: 0, y: h.minY))
        let font = Paint.rounded(17, .heavy)
        Paint.text(ctx, "VENDING", at: CGPoint(x: h.midX + 1, y: h.minY + 4), font: font,
                   color: NSColor(cgColor: Paint.hex(0x7A2A1C, 0.35))!, kern: 4, centered: true)
        Paint.text(ctx, "VENDING", at: CGPoint(x: h.midX, y: h.minY + 5), font: font,
                   color: NSColor(cgColor: Paint.hex(0xD8472B))!, kern: 4, centered: true)
    }

    /// The window: a gasket, the inside of the machine, the shelves and their labels.
    private static func window(_ ctx: CGContext) {
        let g = Geo.glass
        Paint.fill(ctx, Paint.rounded(g.insetBy(dx: -6, dy: -6), 8), Paint.gradient([(0, Paint.hex(0xD9DEE1)), (1, Paint.hex(0x7D858B))]),
                   from: CGPoint(x: g.minX, y: g.maxY), to: CGPoint(x: g.maxX, y: g.minY))
        Paint.fill(ctx, Paint.rounded(g.insetBy(dx: -2.5, dy: -2.5), 5), Paint.hex(0x161A1B))

        ctx.saveGState()
        ctx.addPath(Paint.rounded(g, 3)); ctx.clip()
        // Back wall, darker toward the bottom, and the inner left wall seen in perspective.
        Paint.fill(ctx, CGPath(rect: g, transform: nil), Paint.gradient([(0, Paint.hex(0x4A4339)), (1, Paint.hex(0x1F1C18))]),
                   from: CGPoint(x: 0, y: g.maxY), to: CGPoint(x: 0, y: g.minY))
        let wall = Paint.polygon([CGPoint(x: g.minX, y: g.minY), CGPoint(x: g.minX + 9, y: g.minY + 8),
                                  CGPoint(x: g.minX + 9, y: g.maxY - 8), CGPoint(x: g.minX, y: g.maxY)])
        Paint.fill(ctx, wall, Paint.hex(0x5A5246, 0.7))
        // The light inside: a tube along the top and its glow. It does not flicker.
        let glow = Paint.gradient([(0, Paint.hex(0xFFF3D6, 0.32)), (1, Paint.hex(0xFFF3D6, 0))])
        ctx.drawRadialGradient(glow, startCenter: CGPoint(x: g.midX, y: g.maxY), startRadius: 0,
                               endCenter: CGPoint(x: g.midX, y: g.maxY), endRadius: g.height * 0.75, options: [])
        Paint.fill(ctx, Paint.rounded(CGRect(x: g.minX + 10, y: g.maxY - 5, width: g.width - 20, height: 3), 1.5), Paint.hex(0xFFFBEF, 0.9))

        for row in 0..<Geo.rows.count { shelf(ctx, row: row) }
        // Floor of the drop gap.
        Paint.fill(ctx, CGPath(rect: CGRect(x: g.minX, y: g.minY, width: g.width, height: 10), transform: nil),
                   Paint.gradient([(0, Paint.hex(0x0E0D0B)), (1, Paint.hex(0x2A2620))]),
                   from: CGPoint(x: 0, y: g.minY), to: CGPoint(x: 0, y: g.minY + 10))
        ctx.restoreGState()
    }

    private static func shelf(_ ctx: CGContext, row: Int) {
        let g = Geo.glass, y = Geo.shelfY(row: row)
        // The shelf's top, going back into the machine.
        let top = Paint.polygon([CGPoint(x: g.minX, y: y + 11), CGPoint(x: g.maxX, y: y + 11),
                                 CGPoint(x: g.maxX - 4, y: y + 19), CGPoint(x: g.minX + 9, y: y + 19)])
        Paint.fill(ctx, top, Paint.gradient([(0, Paint.hex(0x6B645A)), (1, Paint.hex(0x3B362F))]),
                   from: CGPoint(x: 0, y: y + 11), to: CGPoint(x: 0, y: y + 19))
        for i in 0..<Geo.columns {
            let c = Geo.coilCenter(row * Geo.columns + i)
            // A dark hollow where each coil sits, and its soft shadow on the shelf.
            Paint.circle(ctx, CGPoint(x: c.x + 1.5, y: c.y + 2), Geo.coilRadius - 3, Paint.hex(0x14120F, 0.55))
            ctx.saveGState()
            ctx.translateBy(x: c.x, y: y + 15); ctx.scaleBy(x: 1, y: 0.22)
            Paint.circle(ctx, .zero, Geo.coilRadius, Paint.hex(0x000000, 0.35))
            ctx.restoreGState()
        }
        // The front lip with a label for each coil.
        let lip = CGRect(x: g.minX, y: y, width: g.width, height: 12)
        Paint.fill(ctx, CGPath(rect: lip, transform: nil), Paint.gradient([(0, Paint.hex(0xE3E7EA)), (1, Paint.hex(0x878F95))]),
                   from: CGPoint(x: 0, y: lip.maxY), to: CGPoint(x: 0, y: lip.minY))
        Paint.fill(ctx, CGPath(rect: CGRect(x: g.minX, y: lip.maxY - 0.8, width: g.width, height: 0.8), transform: nil), Paint.hex(0xFFFFFF, 0.8))
        for i in 0..<Geo.columns {
            let r = Geo.labelRect(row * Geo.columns + i)
            Paint.fill(ctx, CGPath(rect: r.offsetBy(dx: 0.4, dy: -0.4), transform: nil), Paint.hex(0x000000, 0.25))
            Paint.fill(ctx, CGPath(rect: r, transform: nil), Paint.hex(0xFAF6EA))
        }
    }

    /// A steel frame around the pickup opening.
    private static func trayFrame(_ ctx: CGContext) {
        let t = Geo.tray
        Paint.fill(ctx, Paint.rounded(t.insetBy(dx: -6, dy: -6), 7), Paint.gradient([(0, Paint.hex(0xE0E4E7)), (1, Paint.hex(0x737B81))]),
                   from: CGPoint(x: t.minX, y: t.maxY), to: CGPoint(x: t.maxX, y: t.minY))
        Paint.fill(ctx, Paint.rounded(t.insetBy(dx: -1.5, dy: -1.5), 4), Paint.hex(0x0B0B0B))
    }

    /// A soft shadow on the ground under the feet.
    static func shadow(scale: CGFloat) -> CGImage? {
        Paint.render(Geo.size, scale: scale) { ctx in
            let c = Geo.cabinet
            ctx.saveGState()
            ctx.translateBy(x: c.midX + 6, y: c.minY - 8)
            ctx.scaleBy(x: 1, y: 0.07)
            let g = Paint.gradient([(0, Paint.hex(0x000000, 0.45)), (1, Paint.hex(0x000000, 0))])
            ctx.drawRadialGradient(g, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: c.width * 0.62, options: [])
            ctx.restoreGState()
        }
    }

    // MARK: Glass, tray and flap

    /// Only the reflections on the glass. Everything else stays clear.
    static func glass(scale: CGFloat) -> CGImage? {
        let s = Geo.glass.size
        return Paint.render(s, scale: scale) { ctx in
            Paint.fill(ctx, CGPath(rect: CGRect(origin: .zero, size: s), transform: nil), Paint.hex(0xBFE3E6, 0.05))
            let band1 = Paint.polygon([CGPoint(x: 0, y: s.height * 0.62), CGPoint(x: 0, y: s.height * 0.86),
                                       CGPoint(x: s.width * 0.9, y: s.height), CGPoint(x: s.width * 0.55, y: s.height)])
            Paint.fill(ctx, band1, Paint.gradient([(0, Paint.hex(0xFFFFFF, 0.13)), (1, Paint.hex(0xFFFFFF, 0.02))]),
                       from: CGPoint(x: 0, y: s.height), to: CGPoint(x: s.width * 0.6, y: s.height * 0.6))
            let band2 = Paint.polygon([CGPoint(x: s.width * 0.25, y: 0), CGPoint(x: s.width * 0.36, y: 0),
                                       CGPoint(x: s.width, y: s.height * 0.55), CGPoint(x: s.width, y: s.height * 0.42)])
            Paint.fill(ctx, band2, Paint.hex(0xFFFFFF, 0.05))
            Paint.stroke(ctx, CGPath(rect: CGRect(x: 1, y: 1, width: s.width - 2, height: s.height - 2), transform: nil),
                         Paint.hex(0xFFFFFF, 0.12), 1)
        }
    }

    /// The inside of the pickup tray.
    static func tray(scale: CGFloat) -> CGImage? {
        let s = Geo.tray.size
        return Paint.render(s, scale: scale) { ctx in
            Paint.fill(ctx, CGPath(rect: CGRect(origin: .zero, size: s), transform: nil),
                       Paint.gradient([(0, Paint.hex(0x050505)), (0.6, Paint.hex(0x1A1A1A)), (1, Paint.hex(0x2E2E2E))]),
                       from: CGPoint(x: 0, y: s.height), to: CGPoint(x: 0, y: 0))
            // The sloped steel floor.
            Paint.fill(ctx, CGPath(rect: CGRect(x: 0, y: 0, width: s.width, height: 10), transform: nil),
                       Paint.gradient([(0, Paint.hex(0x5B6166)), (1, Paint.hex(0x2B2F32))]),
                       from: CGPoint(x: 0, y: 0), to: CGPoint(x: 0, y: 10))
        }
    }

    /// The hinged flap over the tray: smoked plastic you can half see through.
    static func flap(scale: CGFloat) -> CGImage? {
        let s = Geo.tray.size
        return Paint.render(s, scale: scale) { ctx in
            let r = CGRect(origin: .zero, size: s)
            Paint.fill(ctx, CGPath(rect: r, transform: nil), Paint.gradient([(0, Paint.hex(0x2A3134, 0.62)), (1, Paint.hex(0x14181A, 0.5))]),
                       from: CGPoint(x: 0, y: s.height), to: CGPoint(x: 0, y: 0))
            let sheen = Paint.polygon([CGPoint(x: s.width * 0.08, y: 0), CGPoint(x: s.width * 0.22, y: 0),
                                       CGPoint(x: s.width * 0.42, y: s.height), CGPoint(x: s.width * 0.28, y: s.height)])
            Paint.fill(ctx, sheen, Paint.hex(0xFFFFFF, 0.07))
            // The hinge bar along the top.
            Paint.fill(ctx, CGPath(rect: CGRect(x: 0, y: s.height - 5, width: s.width, height: 5), transform: nil),
                       Paint.gradient([(0, Paint.hex(0xE6EAEC)), (1, Paint.hex(0x7B8389))]),
                       from: CGPoint(x: 0, y: s.height), to: CGPoint(x: 0, y: s.height - 5))
            Paint.text(ctx, "PUSH", at: CGPoint(x: s.width / 2, y: 6), font: Paint.rounded(7, .bold),
                       color: NSColor(white: 1, alpha: 0.5), kern: 1.5, centered: true)
        }
    }

    // MARK: Coils

    /// A steel spiral seen end on, shrinking toward the back. `front` is the first turn, which
    /// passes in front of the file; the rest is behind it. Turning the coil is turning the picture.
    static func coil(front: Bool, scale: CGFloat) -> CGImage? {
        let box = Geo.coilRect(0).size
        return Paint.render(box, scale: scale) { ctx in
            let c = CGPoint(x: box.width / 2, y: box.height / 2)
            let turns: ClosedRange<Double> = front ? 0...1.0 : 0.96...4.5
            let steps = Int((turns.upperBound - turns.lowerBound) * 90)
            var points: [(CGPoint, Double)] = []
            for i in 0...steps {
                let turn = turns.lowerBound + (turns.upperBound - turns.lowerBound) * Double(i) / Double(steps)
                let f = 1 / (1 + turn * 0.3)
                let angle = -2 * Double.pi * turn - Double.pi / 2
                let r = Double(Geo.coilRadius) * f
                let shift = 1 - f
                points.append((CGPoint(x: c.x + CGFloat(cos(angle) * r + shift * 2.5),
                                       y: c.y + CGFloat(sin(angle) * r + shift * 3)), turn))
            }
            // Draw from the back forward so nearer wire covers farther wire.
            ctx.setLineCap(.round)
            for (pass, width, color) in [(0, 2.6, Paint.hex(0x22272B)), (1, 1.4, Paint.hex(0xE4E8EB))] as [(Int, CGFloat, CGColor)] {
                for i in stride(from: points.count - 1, to: 0, by: -1) {
                    let (a, turn) = points[i], (b, _) = points[i - 1]
                    let fade = CGFloat(min(1, turn / 4.5))
                    ctx.setStrokeColor(pass == 0 ? color : color.copy(alpha: 1 - fade * 0.75)!)
                    ctx.setLineWidth(width * (1 - fade * 0.45))
                    ctx.move(to: a); ctx.addLine(to: b); ctx.strokePath()
                }
            }
            if front, let tip = points.first?.0 {
                Paint.circle(ctx, tip, 1.8, Paint.hex(0x22272B))
                Paint.circle(ctx, CGPoint(x: tip.x - 0.4, y: tip.y + 0.4), 1.1, Paint.hex(0xF4F6F7))
            }
        }
    }

    /// The text on a shelf label: the code in bold, then as much of the name as fits.
    static func label(code: String, name: String?, scale: CGFloat) -> CGImage? {
        let size = Geo.labelRect(0).size
        return Paint.render(size, scale: scale) { ctx in
            let ink = NSColor(cgColor: Paint.hex(0x2B2A27))!
            let codeFont = NSFont.systemFont(ofSize: 6.2, weight: .heavy)
            let nameFont = NSFont.systemFont(ofSize: 6.2, weight: .medium)
            let s = NSMutableAttributedString(string: code, attributes: [.font: codeFont, .foregroundColor: ink])
            if let name {
                let room = size.width - 3 - s.size().width - 2
                var text = name
                func width(_ t: String) -> CGFloat { (t as NSString).size(withAttributes: [.font: nameFont]).width }
                if width(text) > room {
                    while !text.isEmpty && width(text + "…") > room { text.removeLast() }
                    text = text.trimmingCharacters(in: .whitespaces) + "…"
                }
                s.append(NSAttributedString(string: " " + text, attributes: [.font: nameFont, .foregroundColor: ink]))
            }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            s.draw(at: NSPoint(x: 1.5, y: (size.height - s.size().height) / 2 + 0.2))
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    // MARK: Control panel

    /// The steel panel with the display bezel and keys. `pressed` draws every key pushed in,
    /// so each key's pressed look can be cut out of it.
    static func panel(pressed: Bool, scale: CGFloat) -> CGImage? {
        let p = Geo.panel
        return Paint.render(p.size, scale: scale) { ctx in
            ctx.translateBy(x: -p.minX, y: -p.minY)
            Paint.fill(ctx, Paint.rounded(p, 6), Paint.gradient([(0, Paint.hex(0xD3D8DB)), (1, Paint.hex(0x8C949A))]),
                       from: CGPoint(x: p.minX, y: p.maxY), to: CGPoint(x: p.maxX, y: p.minY))
            Paint.stroke(ctx, Paint.rounded(p.insetBy(dx: 0.5, dy: 0.5), 6), Paint.hex(0x3B4246, 0.5), 1)
            for (x, y) in [(p.minX + 6, p.maxY - 6), (p.maxX - 6, p.maxY - 6), (p.minX + 6, p.minY + 6), (p.maxX - 6, p.minY + 6)] {
                Paint.circle(ctx, CGPoint(x: x, y: y), 2.2, Paint.hex(0x6E767C))
                Paint.circle(ctx, CGPoint(x: x - 0.3, y: y + 0.3), 1.4, Paint.hex(0xC9CFD3))
            }
            // Display bezel.
            let d = Geo.display
            Paint.fill(ctx, Paint.rounded(d.insetBy(dx: -3, dy: -3), 4), Paint.hex(0x24292C))
            Paint.fill(ctx, Paint.rounded(d, 2), Paint.hex(0x0E110F))

            for (key, rect) in Geo.keys { drawKey(ctx, key, rect, pressed: pressed) }

            let small = Paint.rounded(6, .semibold)
            let ink = NSColor(cgColor: Paint.hex(0x30373B))!
            Paint.text(ctx, "PICK A CODE", at: CGPoint(x: d.midX, y: 322), font: small, color: ink, kern: 0.6, centered: true)
            Paint.text(ctx, "THEN PRESS OK", at: CGPoint(x: d.midX, y: 313), font: small, color: ink, kern: 0.6, centered: true)

            // A speaker grille low on the panel.
            for i in 0..<9 {
                Paint.fill(ctx, Paint.rounded(CGRect(x: d.minX + 8, y: 180 + CGFloat(i) * 7, width: d.width - 16, height: 2.6), 1.3),
                           Paint.hex(0x3C4347, 0.8))
            }
        }
    }

    private static func drawKey(_ ctx: CGContext, _ key: Geo.Key, _ rect: CGRect, pressed: Bool) {
        let ok = key == .ok
        // The well the key sits in.
        Paint.fill(ctx, Paint.rounded(rect.insetBy(dx: -1.2, dy: -1.2).offsetBy(dx: 0, dy: -0.6), 3.5), Paint.hex(0x3A4145, 0.85))
        let face = pressed ? rect.offsetBy(dx: 0, dy: -1).insetBy(dx: 0.3, dy: 0.3) : rect
        if !pressed {
            Paint.fill(ctx, Paint.rounded(rect.offsetBy(dx: 0, dy: -1.6), 3), ok ? Paint.hex(0x8E2A1A) : Paint.hex(0x9A917E))
        }
        let top = ok ? Paint.hex(pressed ? 0xC4402A : 0xE45A40) : Paint.hex(pressed ? 0xD8D0BE : 0xF6F0E2)
        let bottom = ok ? Paint.hex(pressed ? 0x9E2F1E : 0xC2412B) : Paint.hex(pressed ? 0xB9B09C : 0xDCD3BF)
        Paint.fill(ctx, Paint.rounded(face, 3), Paint.gradient([(0, top), (1, bottom)]),
                   from: CGPoint(x: 0, y: face.maxY), to: CGPoint(x: 0, y: face.minY))
        let font = Paint.rounded(key == .clear ? 6.5 : 8, .heavy)
        let color = ok ? NSColor(white: 1, alpha: 0.95) : NSColor(cgColor: Paint.hex(0x3A3630))!
        let h = (key.label as NSString).size(withAttributes: [.font: font]).height
        Paint.text(ctx, key.label, at: CGPoint(x: face.midX, y: face.midY - h / 2 + 0.3), font: font, color: color,
                   kern: key == .clear ? 0.4 : 0, centered: true)
    }

    // MARK: App icon

    /// The machine on a square canvas, for the app icon: DesktopVendingMachine --render-icon out.png
    static func iconArt(size: CGFloat) -> CGImage? {
        let scale = size / Geo.size.height * 0.94
        return Paint.render(CGSize(width: size, height: size), scale: 1) { ctx in
            let w = Geo.size.width * scale
            ctx.translateBy(x: (size - w) / 2, y: size * 0.03)
            ctx.scaleBy(x: scale, y: scale)
            let full = CGRect(origin: .zero, size: Geo.size)
            let draw: (CGImage?, CGRect) -> Void = { image, rect in if let image { ctx.draw(image, in: rect) } }
            draw(cabinet(scale: scale), full)
            draw(tray(scale: scale), Geo.tray)
            for i in 0..<Geo.slotCount { draw(coil(front: false, scale: scale), Geo.coilRect(i)) }
            for i in 0..<Geo.slotCount { draw(coil(front: true, scale: scale), Geo.coilRect(i)) }
            draw(glass(scale: scale), Geo.glass)
            draw(flap(scale: scale), Geo.tray)
            draw(panel(pressed: false, scale: scale), Geo.panel)
        }
    }
}
