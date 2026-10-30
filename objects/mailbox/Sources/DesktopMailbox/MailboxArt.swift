import AppKit

/// The kinds of mail. Each has its own envelope paper and stamp colour.
enum MailKind: String, Codable, CaseIterable {
    case note, movie, book, song, quote

    /// Stamp colour.
    var color: CGColor {
        switch self {
        case .note: return Paint.hex(0xE0A13A)
        case .movie: return Paint.hex(0xD8432F)
        case .book: return Paint.hex(0x3C7FB1)
        case .song: return Paint.hex(0x7A5BB5)
        case .quote: return Paint.hex(0x3E9A6B)
        }
    }

    /// Envelope paper.
    var paper: UInt32 {
        switch self {
        case .note: return 0x8C9858     // olive
        case .movie: return 0xF3EAD7    // cream
        case .book: return 0xC69C6D     // kraft
        case .song: return 0x9DB4CF     // dusty blue
        case .quote: return 0xE8C3B0    // blush
        }
    }

    /// Inside of the envelope.
    var lining: UInt32 {
        switch self {
        case .note: return 0xE9E2C8
        case .movie: return 0xC9493A
        case .book: return 0xF1E6CF
        case .song: return 0xF4EFE3
        case .quote: return 0xF7EDE4
        }
    }

    var label: String {
        switch self {
        case .note: return "NOTE"
        case .movie: return "MOVIE NIGHT"
        case .book: return "A BOOK"
        case .song: return "A SONG"
        case .quote: return "WORDS"
        }
    }
}

/// All artwork, drawn in code. Each piece is rendered once per screen scale.
enum MailboxArt {
    static let redLight = Paint.hex(0xE25646)
    static let red = Paint.hex(0xC8352B)
    static let redDark = Paint.hex(0x8F2018)
    static let redSide = Paint.hex(0x6A1510)
    static let cream = NSColor(srgbRed: 0.97, green: 0.92, blue: 0.83, alpha: 1)
    static let creamCG = Paint.hex(0xF7EBD4)

    private static var full: CGRect { CGRect(origin: .zero, size: Geo.size) }

    // MARK: Pole and shadow

    static func base(scale: CGFloat) -> CGImage? {
        Paint.render(Geo.size, scale: scale) { ctx in
            let shadow = Paint.gradient([(0, Paint.hex(0x000000, 0.3)), (1, Paint.hex(0x000000, 0))])
            ctx.saveGState()
            ctx.translateBy(x: Geo.post.midX + 4, y: 22)
            ctx.scaleBy(x: 1, y: 0.2)
            ctx.drawRadialGradient(shadow, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 82, options: [])
            ctx.restoreGState()

            let p = Geo.post
            Paint.fill(ctx, CGPath(rect: CGRect(x: p.maxX, y: p.minY + 3, width: 7, height: p.height - 3), transform: nil),
                       Paint.hex(0x4E5359))
            Paint.fill(ctx, Paint.rounded(p, 2), Paint.gradient([(0, Paint.hex(0x9DA3AA)), (0.4, Paint.hex(0xB9BEC4)),
                                                                (1, Paint.hex(0x6E747B))]),
                       from: CGPoint(x: p.minX, y: 0), to: CGPoint(x: p.maxX, y: 0))
            // Collar where the pole meets the box.
            let collar = CGRect(x: p.minX - 8, y: p.maxY - 12, width: p.width + 16, height: 12)
            Paint.fill(ctx, Paint.rounded(collar, 2), Paint.gradient([(0, Paint.hex(0x5C6167)), (1, Paint.hex(0x8B9097))]),
                       from: CGPoint(x: 0, y: collar.minY), to: CGPoint(x: 0, y: collar.maxY))
            for x in [collar.minX + 5, collar.maxX - 5] {
                Paint.circle(ctx, CGPoint(x: x, y: collar.midY), 2, Paint.hex(0x3E4247))
            }
            // A little weathering.
            var rng = SeededRandom(seed: 11)
            for _ in 0..<14 {
                let y = p.minY + rng.unit() * (p.height - 16)
                let l = CGMutablePath()
                l.move(to: CGPoint(x: p.minX + 2, y: y)); l.addLine(to: CGPoint(x: p.minX + 2 + rng.range(4, p.width - 6), y: y))
                Paint.stroke(ctx, l, Paint.hex(0x000000, 0.06), 0.8)
            }
        }
    }

    // MARK: Inside, seen through the open door. Drawn in door coordinates.

    static func interior(scale: CGFloat) -> CGImage? {
        let s = Geo.door.size
        return Paint.render(s, scale: scale) { ctx in
            let r = CGRect(origin: .zero, size: s)
            Paint.fill(ctx, CGPath(rect: r, transform: nil), Paint.gradient([(0, Paint.hex(0x3A110D)), (1, Paint.hex(0x1C0807))]),
                       from: .zero, to: CGPoint(x: 0, y: s.height))
            // Back wall, a little smaller, and the floor in perspective.
            let back = r.insetBy(dx: 18, dy: 0).offsetBy(dx: 6, dy: 0)
            let backRect = CGRect(x: back.minX, y: 30, width: back.width, height: s.height - 42)
            Paint.fill(ctx, CGPath(rect: backRect, transform: nil),
                       Paint.gradient([(0, Paint.hex(0x2A0C0A)), (1, Paint.hex(0x140505))]),
                       from: CGPoint(x: 0, y: backRect.minY), to: CGPoint(x: 0, y: backRect.maxY))
            let floor = CGMutablePath()
            floor.move(to: .zero); floor.addLine(to: CGPoint(x: s.width, y: 0))
            floor.addLine(to: CGPoint(x: backRect.maxX, y: backRect.minY)); floor.addLine(to: CGPoint(x: backRect.minX, y: backRect.minY))
            floor.closeSubpath()
            Paint.fill(ctx, floor, Paint.gradient([(0, Paint.hex(0x6A2019)), (1, Paint.hex(0x35100C))]),
                       from: .zero, to: CGPoint(x: 0, y: backRect.minY))
            // Light from the slot falls on the back wall.
            Paint.fill(ctx, CGPath(rect: CGRect(x: backRect.minX, y: backRect.maxY - 22, width: backRect.width, height: 22), transform: nil),
                       Paint.gradient([(0, Paint.hex(0xFFB09A, 0)), (1, Paint.hex(0xFFB09A, 0.10))]),
                       from: CGPoint(x: 0, y: backRect.maxY - 22), to: CGPoint(x: 0, y: backRect.maxY))
            // A metal shelf halfway up.
            let shelfY: CGFloat = 72
            let top = CGMutablePath()
            top.move(to: CGPoint(x: 0, y: shelfY)); top.addLine(to: CGPoint(x: s.width, y: shelfY))
            top.addLine(to: CGPoint(x: backRect.maxX, y: shelfY + 12)); top.addLine(to: CGPoint(x: backRect.minX, y: shelfY + 12))
            top.closeSubpath()
            Paint.fill(ctx, top, Paint.gradient([(0, Paint.hex(0x7A2A21)), (1, Paint.hex(0x4A1510))]),
                       from: CGPoint(x: 0, y: shelfY), to: CGPoint(x: 0, y: shelfY + 12))
            Paint.fill(ctx, CGPath(rect: CGRect(x: 0, y: shelfY - 5, width: s.width, height: 5), transform: nil),
                       Paint.gradient([(0, Paint.hex(0x5A1A14)), (1, Paint.hex(0xA03A2E))]),
                       from: CGPoint(x: 0, y: shelfY - 5), to: CGPoint(x: 0, y: shelfY))
            Paint.fill(ctx, CGPath(rect: CGRect(x: 0, y: shelfY - 14, width: s.width, height: 9), transform: nil),
                       Paint.gradient([(0, Paint.hex(0x000000, 0)), (1, Paint.hex(0x000000, 0.35))]),
                       from: CGPoint(x: 0, y: shelfY - 14), to: CGPoint(x: 0, y: shelfY - 5))
            // Shadow under the top edge.
            Paint.fill(ctx, CGPath(rect: CGRect(x: 0, y: s.height - 16, width: s.width, height: 16), transform: nil),
                       Paint.gradient([(0, Paint.hex(0x000000, 0)), (1, Paint.hex(0x000000, 0.5))]),
                       from: CGPoint(x: 0, y: s.height - 16), to: CGPoint(x: 0, y: s.height))
        }
    }

    // MARK: The box: depth, front face, slot, lettering, and a hole for the door.

    static func body(scale: CGFloat) -> CGImage? {
        Paint.render(Geo.size, scale: scale) { ctx in
            let b = Geo.box, dome = Geo.domeHeight
            // Depth toward the back right.
            for i in stride(from: 12, through: 1, by: -1) {
                let t = CGFloat(i) / 12
                Paint.fill(ctx, Paint.dome(b.offsetBy(dx: Geo.depth.dx * t, dy: Geo.depth.dy * t), dome), redSide)
            }
            Paint.stroke(ctx, Paint.dome(b.offsetBy(dx: Geo.depth.dx, dy: Geo.depth.dy), dome), Paint.hex(0xFFFFFF, 0.08), 1)

            // Front face, lit from the top left.
            Paint.fill(ctx, Paint.dome(b, dome), Paint.gradient([(0, redLight), (0.45, red), (1, redDark)]),
                       from: CGPoint(x: b.minX, y: b.maxY), to: CGPoint(x: b.maxX, y: b.minY))
            Paint.fill(ctx, Paint.dome(b, dome), Paint.gradient([(0, Paint.hex(0xFFFFFF, 0)), (0.18, Paint.hex(0xFFFFFF, 0.10)),
                                                                (0.3, Paint.hex(0xFFFFFF, 0))]),
                       from: CGPoint(x: b.minX, y: 0), to: CGPoint(x: b.maxX, y: 0))
            Paint.stroke(ctx, Paint.dome(b.insetBy(dx: 0.7, dy: 0.7), dome - 0.7), Paint.hex(0xFFFFFF, 0.25), 1.2)
            // Pressed rim around the front, like the real thing.
            let rim = b.insetBy(dx: 8, dy: 8)
            Paint.stroke(ctx, Paint.dome(rim.offsetBy(dx: 0.8, dy: -0.8), dome - 6), Paint.hex(0xFFFFFF, 0.14), 1.4)
            Paint.stroke(ctx, Paint.dome(rim, dome - 6), Paint.hex(0x5A100B, 0.55), 1.4)
            // Darker plinth along the bottom.
            Paint.fill(ctx, CGPath(rect: CGRect(x: b.minX, y: b.minY, width: b.width, height: 7), transform: nil), Paint.hex(0x000000, 0.18))

            // Envelope emblem.
            let e = CGRect(x: b.midX - 18, y: 362, width: 36, height: 23)
            Paint.stroke(ctx, CGPath(rect: e, transform: nil), creamCG, 2.2)
            let v = CGMutablePath()
            v.move(to: CGPoint(x: e.minX, y: e.maxY)); v.addLine(to: CGPoint(x: e.midX, y: e.midY - 2)); v.addLine(to: CGPoint(x: e.maxX, y: e.maxY))
            Paint.stroke(ctx, v, creamCG, 2.2)

            // The slot: a dark opening with a lit lower lip.
            let s = Geo.slot
            Paint.fill(ctx, Paint.rounded(s, 3), Paint.gradient([(0, Paint.hex(0x1A0504)), (1, Paint.hex(0x050101))]),
                       from: CGPoint(x: 0, y: s.minY), to: CGPoint(x: 0, y: s.maxY))
            let lip = CGMutablePath()
            lip.move(to: CGPoint(x: s.minX + 2, y: s.minY - 0.8)); lip.addLine(to: CGPoint(x: s.maxX - 2, y: s.minY - 0.8))
            Paint.stroke(ctx, lip, Paint.hex(0xFFFFFF, 0.3), 1)

            // Lettering, embossed.
            let font = Paint.serif(23, .bold)
            Paint.text(ctx, "POST", at: CGPoint(x: b.midX + 0.8, y: 278.2), font: font, color: NSColor(white: 0, alpha: 0.3), kern: 5, centered: true)
            Paint.text(ctx, "POST", at: CGPoint(x: b.midX, y: 279), font: font, color: cream, kern: 5, centered: true)

            // Raised frame around the door, then the hole for it.
            let d = Geo.door
            let frame = d.insetBy(dx: -6, dy: -6)
            Paint.fill(ctx, Paint.rounded(frame, 3), Paint.gradient([(0, Paint.hex(0xE86A5A)), (1, Paint.hex(0x7E1A13))]),
                       from: CGPoint(x: frame.minX, y: frame.maxY), to: CGPoint(x: frame.maxX, y: frame.minY))
            Paint.fill(ctx, Paint.rounded(frame.insetBy(dx: 2, dy: 2), 2), red)
            ctx.saveGState()
            ctx.addPath(CGPath(rect: d, transform: nil))
            ctx.setBlendMode(.clear)
            ctx.fillPath()
            ctx.restoreGState()
            Paint.stroke(ctx, CGPath(rect: d.insetBy(dx: -0.5, dy: -0.5), transform: nil), Paint.hex(0x2A0705, 0.8), 1.2)

            // Bolts.
            for p in [CGPoint(x: b.minX + 5, y: b.minY + 16), CGPoint(x: b.maxX - 5, y: b.minY + 16),
                      CGPoint(x: b.minX + 5, y: 300), CGPoint(x: b.maxX - 5, y: 300)] {
                Paint.circle(ctx, p, 1.9, Paint.hex(0x5A100B))
                Paint.circle(ctx, CGPoint(x: p.x - 0.5, y: p.y + 0.5), 0.8, Paint.hex(0xFFFFFF, 0.35))
            }
        }
    }

    /// The hood over the slot. Drawn on its own so a waiting letter can sit between it and the box.
    static func hood(scale: CGFloat) -> CGImage? {
        Paint.render(Geo.size, scale: scale) { ctx in
            let h = Geo.hood
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -3), blur: 4, color: Paint.hex(0x2A0705, 0.55))
            Paint.fill(ctx, Paint.rounded(h, 3), red)
            ctx.restoreGState()
            Paint.fill(ctx, Paint.rounded(h, 3), Paint.gradient([(0, Paint.hex(0xF07A69)), (0.35, Paint.hex(0xD8463A)),
                                                                (1, Paint.hex(0x9A2419))]),
                       from: CGPoint(x: 0, y: h.maxY), to: CGPoint(x: 0, y: h.minY))
            let edge = CGMutablePath()
            edge.move(to: CGPoint(x: h.minX + 3, y: h.maxY - 1)); edge.addLine(to: CGPoint(x: h.maxX - 3, y: h.maxY - 1))
            Paint.stroke(ctx, edge, Paint.hex(0xFFFFFF, 0.4), 1)
            Paint.stroke(ctx, Paint.rounded(h.insetBy(dx: 0.5, dy: 0.5), 3), Paint.hex(0x5A100B, 0.6), 1)
        }
    }

    // MARK: Door, front and inside. Drawn in door coordinates.

    static func doorFront(scale: CGFloat) -> CGImage? {
        let s = Geo.door.size
        return Paint.render(s, scale: scale) { ctx in
            let r = CGRect(origin: .zero, size: s)
            Paint.fill(ctx, CGPath(rect: r, transform: nil), Paint.gradient([(0, redLight), (0.5, red), (1, redDark)]),
                       from: CGPoint(x: 0, y: s.height), to: CGPoint(x: s.width, y: 0))
            Paint.fill(ctx, CGPath(rect: r, transform: nil),
                       Paint.gradient([(0, Paint.hex(0xFFFFFF, 0)), (0.22, Paint.hex(0xFFFFFF, 0.09)), (0.36, Paint.hex(0xFFFFFF, 0))]),
                       from: .zero, to: CGPoint(x: s.width, y: 0))
            // Raised inner panel.
            let panel = r.insetBy(dx: 13, dy: 13)
            Paint.stroke(ctx, CGPath(rect: panel.offsetBy(dx: 0.8, dy: -0.8), transform: nil), Paint.hex(0xFFFFFF, 0.16), 1.4)
            Paint.stroke(ctx, CGPath(rect: panel, transform: nil), Paint.hex(0x5A100B, 0.5), 1.4)
            // Keyhole on a brass plate, near the opening edge.
            let k = CGPoint(x: s.width - 30, y: s.height * 0.56)
            Paint.fill(ctx, Paint.rounded(CGRect(x: k.x - 8, y: k.y - 14, width: 16, height: 26), 8),
                       Paint.gradient([(0, Paint.hex(0xF1D58A)), (0.5, Paint.hex(0xC9A24A)), (1, Paint.hex(0x8C6A24))]),
                       from: CGPoint(x: 0, y: k.y + 12), to: CGPoint(x: 0, y: k.y - 14))
            Paint.circle(ctx, CGPoint(x: k.x, y: k.y + 2), 3, Paint.hex(0x1A0A04))
            Paint.fill(ctx, CGPath(rect: CGRect(x: k.x - 1.4, y: k.y - 7, width: 2.8, height: 8), transform: nil), Paint.hex(0x1A0A04))
            // Hinges on the left edge.
            for y in [CGFloat(22), s.height - 34] {
                Paint.fill(ctx, Paint.rounded(CGRect(x: -1, y: y, width: 5, height: 12), 2.5), Paint.hex(0x5A100B))
            }
            Paint.stroke(ctx, CGPath(rect: r.insetBy(dx: 0.6, dy: 0.6), transform: nil), Paint.hex(0x3A0806, 0.7), 1.2)
        }
    }

    /// The inside face. Drawn mirrored left to right because the door is turned around when open.
    static func doorBack(scale: CGFloat) -> CGImage? {
        let s = Geo.door.size
        return Paint.render(s, scale: scale) { ctx in
            ctx.translateBy(x: s.width, y: 0)
            ctx.scaleBy(x: -1, y: 1)
            let r = CGRect(origin: .zero, size: s)
            Paint.fill(ctx, CGPath(rect: r, transform: nil), Paint.gradient([(0, Paint.hex(0xA8382C)), (1, Paint.hex(0x7A2218))]),
                       from: CGPoint(x: 0, y: s.height), to: .zero)
            // Stiffening ribs.
            for y in [s.height * 0.33, s.height * 0.66] {
                let rib = CGRect(x: 10, y: y - 3, width: s.width - 20, height: 6)
                Paint.fill(ctx, Paint.rounded(rib, 3), Paint.hex(0x000000, 0.12))
                Paint.stroke(ctx, Paint.rounded(rib, 3), Paint.hex(0xFFFFFF, 0.08), 1)
            }
            // Lock box behind the keyhole.
            let lock = CGRect(x: s.width - 46, y: s.height * 0.56 - 18, width: 32, height: 36)
            Paint.fill(ctx, Paint.rounded(lock, 3), Paint.gradient([(0, Paint.hex(0x8C9198)), (1, Paint.hex(0x5C6168))]),
                       from: CGPoint(x: 0, y: lock.maxY), to: CGPoint(x: 0, y: lock.minY))
            Paint.fill(ctx, CGPath(rect: CGRect(x: lock.maxX, y: lock.midY - 3, width: 10, height: 6), transform: nil), Paint.hex(0x6C7178))
            Paint.stroke(ctx, CGPath(rect: r.insetBy(dx: 0.6, dy: 0.6), transform: nil), Paint.hex(0x3A0806, 0.8), 1.2)
        }
    }

    // MARK: Envelopes

    static let envelopeSize = CGSize(width: 46, height: 31)

    /// A small envelope, for the floor of the box and the slot.
    static func envelope(kind: MailKind, read: Bool, size: CGSize = envelopeSize, scale: CGFloat) -> CGImage? {
        let s = size
        return Paint.render(CGSize(width: s.width, height: s.height + 8), scale: scale) { ctx in
            let u = s.width / 46
            let body = CGRect(x: 1, y: 2 * u, width: s.width - 2, height: s.height - 3 * u)
            if read {
                let paper = CGRect(x: body.minX + 6 * u, y: body.midY, width: body.width - 12 * u, height: body.height * 0.5 + 7 * u)
                Paint.fill(ctx, CGPath(rect: paper, transform: nil), Paint.hex(0xFFFDF6))
                for i in 0..<3 {
                    let y = paper.maxY - 5 * u - CGFloat(i) * 3.5 * u
                    let l = CGMutablePath(); l.move(to: CGPoint(x: paper.minX + 4 * u, y: y)); l.addLine(to: CGPoint(x: paper.maxX - 6 * u, y: y))
                    Paint.stroke(ctx, l, Paint.hex(0x5A6A85, 0.5), 0.7 * u)
                }
            }
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -1.5 * u), blur: 2.5 * u, color: Paint.hex(0x000000, 0.45))
            Paint.fill(ctx, Paint.rounded(body, 2 * u), Paint.hex(kind.paper))
            ctx.restoreGState()
            Paint.fill(ctx, Paint.rounded(body, 2 * u), Paint.gradient([(0, Paint.hex(0xFFFFFF, 0.12)), (1, Paint.hex(0x000000, 0.06))]),
                       from: CGPoint(x: 0, y: body.maxY), to: CGPoint(x: 0, y: body.minY))
            let flap = CGMutablePath()
            if read {
                flap.move(to: CGPoint(x: body.minX, y: body.maxY)); flap.addLine(to: CGPoint(x: body.midX, y: body.midY - 3 * u))
                flap.addLine(to: CGPoint(x: body.maxX, y: body.maxY))
            } else {
                flap.move(to: CGPoint(x: body.minX + 1, y: body.maxY - 1)); flap.addLine(to: CGPoint(x: body.midX, y: body.midY - u))
                flap.addLine(to: CGPoint(x: body.maxX - 1, y: body.maxY - 1))
            }
            Paint.stroke(ctx, flap, Paint.hex(0x000000, 0.22), 0.9 * u)
            let stamp = CGRect(x: body.maxX - 11 * u, y: body.maxY - 11 * u, width: 8 * u, height: 9 * u)
            Paint.fill(ctx, CGPath(rect: stamp.insetBy(dx: -u, dy: -u), transform: nil), Paint.hex(0xFFFFFF))
            Paint.fill(ctx, CGPath(rect: stamp, transform: nil), kind.color)
            if !read {
                Paint.circle(ctx, CGPoint(x: body.midX, y: body.midY - u), 4.6 * u, Paint.hex(0xA8241A))
                Paint.circle(ctx, CGPoint(x: body.midX - u, y: body.midY), 1.6 * u, Paint.hex(0xFFFFFF, 0.25))
            }
        }
    }

    /// A kraft parcel envelope for a stored file, with its name written on it and its icon as the stamp.
    static func parcel(name: String, icon: NSImage, size: CGSize = envelopeSize, scale: CGFloat) -> CGImage? {
        Paint.render(CGSize(width: size.width, height: size.height + 8), scale: scale) { ctx in
            let u = size.width / 46
            let body = CGRect(x: 1, y: 2 * u, width: size.width - 2, height: size.height - 3 * u)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -1.5 * u), blur: 2.5 * u, color: Paint.hex(0x000000, 0.45))
            Paint.fill(ctx, Paint.rounded(body, 2 * u), Paint.hex(0xC9A271))
            ctx.restoreGState()
            Paint.fill(ctx, Paint.rounded(body, 2 * u), Paint.gradient([(0, Paint.hex(0xFFFFFF, 0.14)), (1, Paint.hex(0x000000, 0.08))]),
                       from: CGPoint(x: 0, y: body.maxY), to: CGPoint(x: 0, y: body.minY))
            // Twine around it.
            let twine = Paint.hex(0xEFE4CC, 0.9)
            Paint.fill(ctx, CGPath(rect: CGRect(x: body.minX + body.width * 0.3, y: body.minY, width: 1.3 * u, height: body.height), transform: nil), twine)
            Paint.fill(ctx, CGPath(rect: CGRect(x: body.minX, y: body.midY - 0.6 * u, width: body.width, height: 1.3 * u), transform: nil), twine)
            // The file's own icon as the stamp.
            let stamp = CGRect(x: body.maxX - 13 * u, y: body.maxY - 13 * u, width: 11 * u, height: 11 * u)
            Paint.fill(ctx, CGPath(rect: stamp.insetBy(dx: -u, dy: -u), transform: nil), Paint.hex(0xFFFDF6))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            icon.draw(in: stamp)
            NSGraphicsContext.restoreGraphicsState()
            // A label with the name, handwritten.
            let label = CGRect(x: body.minX + body.width * 0.36, y: body.minY + 3 * u, width: body.width * 0.6 - 2 * u, height: 9 * u)
            Paint.fill(ctx, CGPath(rect: label, transform: nil), Paint.hex(0xFBF6EA))
            let shown = name.count > 14 ? String(name.prefix(13)) + "…" : name
            Paint.text(ctx, shown, at: CGPoint(x: label.minX + u, y: label.minY + 0.5 * u), font: Paint.hand(6.2 * u),
                       color: NSColor(srgbRed: 0.17, green: 0.24, blue: 0.38, alpha: 1))
        }
    }

    // MARK: The big envelope for opening a letter

    static let bigEnvelope = CGSize(width: 360, height: 228)
    static var flapHeight: CGFloat { bigEnvelope.height * 0.58 }

    /// The inside back of the envelope.
    static func envelopeBack(kind: MailKind, scale: CGFloat) -> CGImage? {
        let s = bigEnvelope
        return Paint.render(s, scale: scale) { ctx in
            let r = CGRect(origin: .zero, size: s)
            Paint.fill(ctx, Paint.rounded(r, 4), Paint.hex(kind.paper))
            Paint.fill(ctx, Paint.rounded(r.insetBy(dx: 6, dy: 6), 2), Paint.hex(kind.lining))
            Paint.fill(ctx, Paint.rounded(r.insetBy(dx: 6, dy: 6), 2), Paint.gradient([(0, Paint.hex(0x000000, 0.25)), (1, Paint.hex(0x000000, 0.05))]),
                       from: CGPoint(x: 0, y: s.height), to: .zero)
        }
    }

    /// The front pocket: everything but the open V at the top.
    static func envelopePocket(kind: MailKind, scale: CGFloat) -> CGImage? {
        let s = bigEnvelope
        return Paint.render(CGSize(width: s.width, height: s.height + 20), scale: scale) { ctx in
            ctx.translateBy(x: 0, y: 20)
            let w = s.width, h = s.height, v = h * 0.44
            let pocket = CGMutablePath()
            pocket.move(to: CGPoint(x: 0, y: h - 4))
            pocket.addLine(to: CGPoint(x: w / 2 - 12, y: v + 6))
            pocket.addQuadCurve(to: CGPoint(x: w / 2 + 12, y: v + 6), control: CGPoint(x: w / 2, y: v - 2))
            pocket.addLine(to: CGPoint(x: w, y: h - 4))
            pocket.addLine(to: CGPoint(x: w, y: 4))
            pocket.addQuadCurve(to: CGPoint(x: w - 4, y: 0), control: CGPoint(x: w, y: 0))
            pocket.addLine(to: CGPoint(x: 4, y: 0))
            pocket.addQuadCurve(to: CGPoint(x: 0, y: 4), control: .zero)
            pocket.closeSubpath()
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: Paint.hex(0x000000, 0.3))
            Paint.fill(ctx, pocket, Paint.hex(kind.paper))
            ctx.restoreGState()
            // The bottom flap, a shade lighter, with soft folds.
            let bottom = CGMutablePath()
            bottom.move(to: .zero); bottom.addLine(to: CGPoint(x: w / 2, y: h * 0.5)); bottom.addLine(to: CGPoint(x: w, y: 0)); bottom.closeSubpath()
            ctx.saveGState(); ctx.addPath(pocket); ctx.clip()
            Paint.fill(ctx, bottom, Paint.hex(0xFFFFFF, 0.08))
            Paint.stroke(ctx, bottom, Paint.hex(0x000000, 0.10), 1.2)
            ctx.restoreGState()
            Paint.fill(ctx, pocket, Paint.gradient([(0, Paint.hex(0xFFFFFF, 0.10)), (1, Paint.hex(0x000000, 0.08))]),
                       from: CGPoint(x: 0, y: h), to: .zero)
        }
    }

    /// The flap, outside. Its hinge is along the top edge of the image.
    static func flapFront(kind: MailKind, scale: CGFloat) -> CGImage? {
        let s = CGSize(width: bigEnvelope.width, height: flapHeight)
        return Paint.render(s, scale: scale) { ctx in
            let path = flapPath(s)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -3), blur: 6, color: Paint.hex(0x000000, 0.25))
            Paint.fill(ctx, path, Paint.hex(kind.paper))
            ctx.restoreGState()
            Paint.fill(ctx, path, Paint.gradient([(0, Paint.hex(0x000000, 0.04)), (1, Paint.hex(0xFFFFFF, 0.10))]),
                       from: CGPoint(x: 0, y: s.height), to: .zero)
            Paint.stroke(ctx, path, Paint.hex(0x000000, 0.12), 1)
        }
    }

    /// The flap, inside. Drawn upside down because it is seen after folding back.
    static func flapBack(kind: MailKind, scale: CGFloat) -> CGImage? {
        let s = CGSize(width: bigEnvelope.width, height: flapHeight)
        return Paint.render(s, scale: scale) { ctx in
            ctx.translateBy(x: 0, y: s.height)
            ctx.scaleBy(x: 1, y: -1)
            let path = flapPath(s)
            Paint.fill(ctx, path, Paint.hex(kind.lining))
            Paint.fill(ctx, path, Paint.gradient([(0, Paint.hex(0x000000, 0.12)), (1, Paint.hex(0x000000, 0))]),
                       from: CGPoint(x: 0, y: s.height), to: .zero)
        }
    }

    private static func flapPath(_ s: CGSize) -> CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 0, y: s.height))
        p.addLine(to: CGPoint(x: s.width, y: s.height))
        p.addLine(to: CGPoint(x: s.width / 2 + 16, y: 10))
        p.addQuadCurve(to: CGPoint(x: s.width / 2 - 16, y: 10), control: CGPoint(x: s.width / 2, y: -2))
        p.closeSubpath()
        return p
    }

    /// A wax seal.
    static func seal(scale: CGFloat) -> CGImage? {
        let s = CGSize(width: 54, height: 54)
        return Paint.render(s, scale: scale) { ctx in
            let c = CGPoint(x: 27, y: 27)
            // Wobbly edge where the wax spread.
            let blob = CGMutablePath()
            var rng = SeededRandom(seed: 5)
            for i in 0...36 {
                let a = CGFloat(i) / 36 * 2 * .pi
                let r = 22 + rng.range(-1.6, 1.6)
                let p = CGPoint(x: c.x + cos(a) * r, y: c.y + sin(a) * r)
                if i == 0 { blob.move(to: p) } else { blob.addLine(to: p) }
            }
            blob.closeSubpath()
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: 3, color: Paint.hex(0x000000, 0.4))
            Paint.fill(ctx, blob, Paint.hex(0x9E2016))
            ctx.restoreGState()
            Paint.fill(ctx, blob, Paint.gradient([(0, Paint.hex(0xD4483A)), (1, Paint.hex(0x6E120B))]),
                       from: CGPoint(x: 10, y: 46), to: CGPoint(x: 44, y: 8))
            // Pressed ring and an envelope mark.
            Paint.stroke(ctx, CGPath(ellipseIn: CGRect(x: c.x - 14, y: c.y - 14, width: 28, height: 28), transform: nil), Paint.hex(0x5A0C07, 0.6), 1.6)
            Paint.stroke(ctx, CGPath(ellipseIn: CGRect(x: c.x - 13.2, y: c.y - 14.8, width: 28, height: 28), transform: nil), Paint.hex(0xFFFFFF, 0.18), 1)
            let e = CGRect(x: c.x - 8, y: c.y - 5, width: 16, height: 10)
            Paint.stroke(ctx, CGPath(rect: e, transform: nil), Paint.hex(0x5A0C07, 0.7), 1.3)
            let v = CGMutablePath(); v.move(to: CGPoint(x: e.minX, y: e.maxY)); v.addLine(to: CGPoint(x: e.midX, y: e.midY - 1)); v.addLine(to: CGPoint(x: e.maxX, y: e.maxY))
            Paint.stroke(ctx, v, Paint.hex(0x5A0C07, 0.7), 1.3)
            Paint.fill(ctx, CGPath(ellipseIn: CGRect(x: 12, y: 30, width: 12, height: 7), transform: nil), Paint.hex(0xFFFFFF, 0.22))
        }
    }

    // MARK: Stamp for the letter paper

    static func stamp(kind: MailKind, scale: CGFloat) -> CGImage? {
        let s = CGSize(width: 74, height: 88)
        return Paint.render(s, scale: scale) { ctx in
            let r = CGRect(origin: .zero, size: s).insetBy(dx: 3, dy: 3)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 2, color: Paint.hex(0x000000, 0.25))
            Paint.fill(ctx, CGPath(rect: r, transform: nil), Paint.hex(0xFFFDF8))
            ctx.restoreGState()
            ctx.saveGState(); ctx.setBlendMode(.clear)
            var x = r.minX
            while x <= r.maxX { Paint.circle(ctx, CGPoint(x: x, y: r.minY), 2.2, Paint.hex(0)); Paint.circle(ctx, CGPoint(x: x, y: r.maxY), 2.2, Paint.hex(0)); x += 7.4 }
            var y = r.minY
            while y <= r.maxY { Paint.circle(ctx, CGPoint(x: r.minX, y: y), 2.2, Paint.hex(0)); Paint.circle(ctx, CGPoint(x: r.maxX, y: y), 2.2, Paint.hex(0)); y += 7.4 }
            ctx.restoreGState()
            let inner = r.insetBy(dx: 6, dy: 6)
            Paint.fill(ctx, CGPath(rect: inner, transform: nil), kind.color)
            // A little post box in the stamp.
            let mini = CGRect(x: inner.midX - 10, y: inner.minY + 18, width: 20, height: 28)
            Paint.fill(ctx, Paint.dome(mini, 8), Paint.hex(0xFFFFFF, 0.9))
            Paint.fill(ctx, CGPath(rect: CGRect(x: mini.minX + 4, y: mini.maxY - 13, width: mini.width - 8, height: 2.5), transform: nil), kind.color)
            Paint.fill(ctx, CGPath(rect: CGRect(x: inner.midX - 2, y: inner.minY + 7, width: 4, height: 11), transform: nil), Paint.hex(0xFFFFFF, 0.9))
            Paint.text(ctx, kind.label, at: CGPoint(x: inner.midX, y: inner.maxY - 13), font: NSFont.systemFont(ofSize: 7, weight: .bold),
                       color: .white, kern: 0.6, centered: true)
        }
    }

    // MARK: The whole box, closed (app icon and previews)

    static func closedComposite(scale: CGFloat, waiting: MailKind?) -> CGImage? {
        Paint.render(Geo.size, scale: scale) { ctx in
            if let b = base(scale: scale) { ctx.draw(b, in: full) }
            if let b = body(scale: scale) { ctx.draw(b, in: full) }
            if let d = doorFront(scale: scale) { ctx.draw(d, in: Geo.door) }
            if let kind = waiting, let e = envelope(kind: kind, read: false, size: Geo.peek.size, scale: scale) {
                ctx.saveGState()
                ctx.clip(to: CGRect(x: 0, y: 0, width: Geo.size.width, height: Geo.slot.maxY))
                ctx.translateBy(x: Geo.peek.midX, y: Geo.peek.midY)
                ctx.rotate(by: 0.06)
                ctx.draw(e, in: CGRect(x: -Geo.peek.width / 2, y: -Geo.peek.height / 2 - 4, width: Geo.peek.width, height: Geo.peek.height + 8))
                ctx.restoreGState()
            }
            if let h = hood(scale: scale) { ctx.draw(h, in: full) }
        }
    }

    /// Square icon art on a plain white background, ready for scripts/make-icon.swift.
    static func iconArt(size: CGFloat) -> CGImage? {
        Paint.render(CGSize(width: size, height: size), scale: 1) { ctx in
            ctx.setFillColor(Paint.hex(0xFFFFFF)); ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
            let tile = CGRect(x: size * 0.06, y: size * 0.06, width: size * 0.88, height: size * 0.88)
            let path = CGPath(roundedRect: tile, cornerWidth: tile.width * 0.22, cornerHeight: tile.width * 0.22, transform: nil)
            Paint.fill(ctx, path, Paint.gradient([(0, Paint.hex(0xF6E7C8)), (1, Paint.hex(0xEFC99A))]),
                       from: CGPoint(x: 0, y: tile.maxY), to: CGPoint(x: 0, y: tile.minY))
            ctx.saveGState(); ctx.addPath(path); ctx.clip()
            // Show the box, from just under the pole collar up, big in the tile.
            let crop = CGRect(x: 66, y: 60, width: 290, height: 370)
            let h = tile.height * 1.0, k = h / crop.height
            if let m = closedComposite(scale: k * 1.2, waiting: .note) {
                let dest = CGRect(x: tile.midX - (crop.midX - 0) * k + (Geo.size.width / 2 - crop.midX) * 0 , y: tile.minY - crop.minY * k,
                                  width: Geo.size.width * k, height: Geo.size.height * k)
                ctx.draw(m, in: dest.offsetBy(dx: (tile.midX - (dest.minX + (Geo.box.midX + Geo.depth.dx / 2) * k)), dy: 0))
            }
            ctx.restoreGState()
        }
    }
}

/// Repeatable randomness for art.
struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E3779B97F4A7C15 | 1 }
    mutating func next() -> UInt64 { state ^= state << 13; state ^= state >> 7; state ^= state << 17; return state }
    mutating func unit() -> CGFloat { CGFloat(next() % 10_000) / 10_000 }
    mutating func range(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * unit() }
}
