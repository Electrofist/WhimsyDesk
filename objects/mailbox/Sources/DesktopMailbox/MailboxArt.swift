import AppKit

/// The kinds of mail, each with its own stamp colour and label.
enum MailKind: String, Codable, CaseIterable {
    case note, movie, book, song, quote

    var color: CGColor {
        switch self {
        case .note: return Paint.hex(0xE0A13A)
        case .movie: return Paint.hex(0xD8432F)
        case .book: return Paint.hex(0x3C7FB1)
        case .song: return Paint.hex(0x7A5BB5)
        case .quote: return Paint.hex(0x3E9A6B)
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

/// All mailbox artwork, drawn in code. Each piece is rendered once per screen scale.
enum MailboxArt {
    // Navy enamel, brass and a red flag.
    static let navyLight = Paint.hex(0x4A6E9C)
    static let navy = Paint.hex(0x2F4D74)
    static let navyDark = Paint.hex(0x1D3150)
    static let brass = Paint.hex(0xC9A24A)
    static let flagRed = Paint.hex(0xD8432F)

    // MARK: Post and shadow (behind everything)

    static func base(scale: CGFloat) -> CGImage? {
        Paint.render(Geo.size, scale: scale) { ctx in
            // Soft contact shadow on the desk.
            let shadow = Paint.gradient([(0, Paint.hex(0x000000, 0.28)), (1, Paint.hex(0x000000, 0))])
            ctx.saveGState()
            ctx.translateBy(x: 160, y: 22)
            ctx.scaleBy(x: 1, y: 0.22)
            ctx.drawRadialGradient(shadow, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 70, options: [])
            ctx.restoreGState()

            // Wooden post with a little depth on the right.
            let p = Geo.post
            let side = CGRect(x: p.maxX, y: p.minY + 4, width: 7, height: p.height - 4)
            Paint.fill(ctx, CGPath(rect: side, transform: nil), Paint.hex(0x553620))
            let wood = Paint.gradient([(0, Paint.hex(0x9C6A40)), (0.55, Paint.hex(0x83552F)), (1, Paint.hex(0x6A4325))])
            Paint.fill(ctx, CGPath(roundedRect: p, cornerWidth: 2, cornerHeight: 2, transform: nil), wood,
                       from: CGPoint(x: p.minX, y: 0), to: CGPoint(x: p.maxX, y: 0))
            var rng = SeededRandom(seed: 7)
            for _ in 0..<9 {
                let x = p.minX + 4 + rng.unit() * (p.width - 8)
                let line = CGMutablePath()
                line.move(to: CGPoint(x: x, y: p.minY + 4))
                line.addCurve(to: CGPoint(x: x + rng.range(-3, 3), y: p.maxY - 6),
                              control1: CGPoint(x: x + rng.range(-4, 4), y: p.minY + p.height * 0.35),
                              control2: CGPoint(x: x + rng.range(-4, 4), y: p.minY + p.height * 0.7))
                Paint.stroke(ctx, line, Paint.hex(0x4A2D17, 0.28), 0.8)
            }
            // Darker where the post meets the box.
            Paint.fill(ctx, CGPath(rect: CGRect(x: p.minX, y: p.maxY - 14, width: p.width, height: 14), transform: nil),
                       Paint.gradient([(0, Paint.hex(0x000000, 0)), (1, Paint.hex(0x000000, 0.35))]),
                       from: CGPoint(x: 0, y: p.maxY - 14), to: CGPoint(x: 0, y: p.maxY))
        }
    }

    // MARK: Interior (seen when the door is open). Drawn in door coordinates.

    static func interior(scale: CGFloat) -> CGImage? {
        let s = Geo.door.size
        return Paint.render(s, scale: scale) { ctx in
            let mouth = Paint.arch(CGRect(origin: .zero, size: s))
            ctx.saveGState(); ctx.addPath(mouth); ctx.clip()
            // Side walls, darker toward the back.
            let walls = Paint.gradient([(0, Paint.hex(0x22324A)), (0.5, Paint.hex(0x0E1622)), (1, Paint.hex(0x22324A))])
            ctx.drawLinearGradient(walls, start: .zero, end: CGPoint(x: s.width, y: 0), options: [])
            // Back wall: a smaller arch deep inside.
            let back = CGRect(x: s.width * 0.2, y: 34, width: s.width * 0.6, height: s.height * 0.62)
            Paint.fill(ctx, Paint.arch(back), Paint.gradient([(0, Paint.hex(0x0B1018)), (1, Paint.hex(0x141E2C))]),
                       from: CGPoint(x: 0, y: back.minY), to: CGPoint(x: 0, y: back.maxY))
            // Floor in perspective, catching a little light from the opening.
            let floor = CGMutablePath()
            floor.move(to: .zero)
            floor.addLine(to: CGPoint(x: s.width, y: 0))
            floor.addLine(to: CGPoint(x: back.maxX, y: back.minY))
            floor.addLine(to: CGPoint(x: back.minX, y: back.minY))
            floor.closeSubpath()
            Paint.fill(ctx, floor, Paint.gradient([(0, Paint.hex(0x3A5070)), (1, Paint.hex(0x18243A))]),
                       from: .zero, to: CGPoint(x: 0, y: back.minY))
            // Ribs pressed into the curved roof.
            for i in 1...3 {
                let t = CGFloat(i) / 4
                let r = CGRect(x: back.minX * (1 - t), y: back.minY * (1 - t),
                               width: s.width - (s.width - back.width) * t,
                               height: s.height - (s.height - back.height - back.minY) * t)
                Paint.stroke(ctx, Paint.arch(r), Paint.hex(0xFFFFFF, 0.05), 1)
            }
            ctx.restoreGState()
        }
    }

    // MARK: Box body: depth, front rim, and a hole where the door sits.

    static func body(scale: CGFloat) -> CGImage? {
        Paint.render(Geo.size, scale: scale) { ctx in
            let m = Geo.mouth
            // Extrude the arch toward the back right to give the box depth.
            let steps = 14
            for i in stride(from: steps, through: 1, by: -1) {
                let t = CGFloat(i) / CGFloat(steps)
                let r = m.offsetBy(dx: Geo.depth.dx * t, dy: Geo.depth.dy * t)
                let shade = 0.25 + 0.35 * t
                Paint.fill(ctx, Paint.arch(r), Paint.hex(0x14223A, 1).copy(alpha: 1)!)
                Paint.fill(ctx, Paint.arch(r), Paint.hex(0x000000, shade * 0.5))
            }
            // Highlight along the top of the extruded roof.
            Paint.stroke(ctx, Paint.arch(m.offsetBy(dx: Geo.depth.dx, dy: Geo.depth.dy)), Paint.hex(0xFFFFFF, 0.12), 1)

            // Front face, lit from the top left.
            let enamel = Paint.gradient([(0, navyLight), (0.45, navy), (1, navyDark)])
            Paint.fill(ctx, Paint.arch(m), enamel, from: CGPoint(x: m.minX, y: m.maxY), to: CGPoint(x: m.maxX, y: m.minY))
            Paint.stroke(ctx, Paint.arch(m.insetBy(dx: 0.6, dy: 0.6)), Paint.hex(0xFFFFFF, 0.22), 1.2)

            // Cut the hole for the door so the interior shows through.
            ctx.saveGState()
            ctx.addPath(Paint.arch(Geo.door))
            ctx.setBlendMode(.clear)
            ctx.fillPath()
            ctx.restoreGState()
            Paint.stroke(ctx, Paint.arch(Geo.door.insetBy(dx: -0.5, dy: -0.5)), Paint.hex(0x0A1220, 0.8), 1.4)

            // Rivets on the rim.
            for p in [CGPoint(x: m.minX + 3.5, y: m.minY + 6), CGPoint(x: m.maxX - 3.5, y: m.minY + 6),
                      CGPoint(x: m.minX + 3.5, y: m.minY + 60), CGPoint(x: m.maxX - 3.5, y: m.minY + 60)] {
                Paint.circle(ctx, p, 1.8, Paint.hex(0x0E182A))
                Paint.circle(ctx, CGPoint(x: p.x - 0.5, y: p.y + 0.5), 0.8, Paint.hex(0xFFFFFF, 0.35))
            }
            // Mounting plate for the flag on the side.
            let plate = CGRect(x: Geo.flagPivot.x - 9, y: Geo.flagPivot.y - 12, width: 14, height: 24)
            Paint.fill(ctx, CGPath(roundedRect: plate, cornerWidth: 3, cornerHeight: 3, transform: nil), Paint.hex(0x15233A))
        }
    }

    // MARK: Door, front and inside. Drawn in door coordinates.

    static func doorFront(scale: CGFloat) -> CGImage? {
        let s = Geo.door.size
        return Paint.render(s, scale: scale) { ctx in
            let r = CGRect(origin: .zero, size: s)
            let enamel = Paint.gradient([(0, navyLight), (0.5, navy), (1, navyDark)])
            Paint.fill(ctx, Paint.arch(r), enamel, from: CGPoint(x: 0, y: s.height), to: CGPoint(x: s.width, y: 0))
            // A soft sheen down the left side.
            Paint.fill(ctx, Paint.arch(r), Paint.gradient([(0, Paint.hex(0xFFFFFF, 0)), (0.3, Paint.hex(0xFFFFFF, 0.10)),
                                                           (0.45, Paint.hex(0xFFFFFF, 0))]),
                       from: .zero, to: CGPoint(x: s.width, y: 0))
            // Pressed inner panel.
            let panel = r.insetBy(dx: 14, dy: 14).offsetBy(dx: 0, dy: 2)
            Paint.stroke(ctx, Paint.arch(panel.offsetBy(dx: 0.7, dy: -0.7)), Paint.hex(0xFFFFFF, 0.16), 1.4)
            Paint.stroke(ctx, Paint.arch(panel), Paint.hex(0x0A1424, 0.55), 1.4)
            // Embossed lettering.
            let font = Paint.serif(19, .semibold)
            Paint.text(ctx, "MAIL", at: CGPoint(x: s.width / 2 + 0.6, y: s.height * 0.33 - 0.6), font: font,
                       color: NSColor(white: 0, alpha: 0.35), kern: 6, centered: true)
            Paint.text(ctx, "MAIL", at: CGPoint(x: s.width / 2, y: s.height * 0.33), font: font,
                       color: NSColor(srgbRed: 0.86, green: 0.9, blue: 0.95, alpha: 0.8), kern: 6, centered: true)
            // Brass latch at the top.
            let latch = CGRect(x: s.width / 2 - 15, y: s.height - 24, width: 30, height: 9)
            Paint.fill(ctx, CGPath(roundedRect: latch, cornerWidth: 4.5, cornerHeight: 4.5, transform: nil),
                       Paint.gradient([(0, Paint.hex(0xF1D58A)), (0.5, brass), (1, Paint.hex(0x8C6A24))]),
                       from: CGPoint(x: 0, y: latch.maxY), to: CGPoint(x: 0, y: latch.minY))
            Paint.circle(ctx, CGPoint(x: s.width / 2, y: latch.midY), 2.2, Paint.hex(0x6E5218))
            // Hinge knuckles along the bottom.
            for x in [CGFloat(22), s.width - 34] {
                Paint.fill(ctx, CGPath(roundedRect: CGRect(x: x, y: -1, width: 12, height: 5), cornerWidth: 2.5,
                                       cornerHeight: 2.5, transform: nil), Paint.hex(0x0E182A))
            }
            Paint.stroke(ctx, Paint.arch(r.insetBy(dx: 0.6, dy: 0.6)), Paint.hex(0x08101C, 0.7), 1.2)
        }
    }

    /// The inside face. It is drawn upside down because the door hangs from its hinge when open.
    static func doorBack(scale: CGFloat) -> CGImage? {
        let s = Geo.door.size
        return Paint.render(s, scale: scale) { ctx in
            let r = CGRect(origin: .zero, size: s)
            ctx.saveGState()
            ctx.translateBy(x: 0, y: s.height)
            ctx.scaleBy(x: 1, y: -1)
            let steel = Paint.gradient([(0, Paint.hex(0x9AA8BA)), (1, Paint.hex(0x6C7A8F))])
            Paint.fill(ctx, Paint.arch(r), steel, from: CGPoint(x: 0, y: s.height), to: .zero)
            for i in 1...3 {
                let inset = CGFloat(i) * 14
                Paint.stroke(ctx, Paint.arch(r.insetBy(dx: inset, dy: inset).offsetBy(dx: 0, dy: inset * 0.4)),
                             Paint.hex(0xFFFFFF, 0.16), 1)
            }
            let tongue = CGRect(x: s.width / 2 - 8, y: s.height - 20, width: 16, height: 10)
            Paint.fill(ctx, CGPath(roundedRect: tongue, cornerWidth: 2, cornerHeight: 2, transform: nil), Paint.hex(0x4D586A))
            Paint.stroke(ctx, Paint.arch(r.insetBy(dx: 0.6, dy: 0.6)), Paint.hex(0x2E3746, 0.8), 1.2)
            ctx.restoreGState()
        }
    }

    // MARK: Flag. Drawn standing up; the pivot is at Geo.flagAnchor.

    static func flag(scale: CGFloat) -> CGImage? {
        Paint.render(Geo.flagSize, scale: scale) { ctx in
            let a = Geo.flagAnchor
            let arm = CGRect(x: a.x - 3, y: a.y, width: 6, height: 68)
            Paint.fill(ctx, CGPath(roundedRect: arm, cornerWidth: 3, cornerHeight: 3, transform: nil),
                       Paint.gradient([(0, Paint.hex(0xE8584A)), (1, Paint.hex(0xA8301F))]),
                       from: CGPoint(x: arm.minX, y: 0), to: CGPoint(x: arm.maxX, y: 0))
            // The flag itself, with a slight wave.
            let top = a.y + 68, x0 = arm.maxX - 1
            let f = CGMutablePath()
            f.move(to: CGPoint(x: x0, y: top))
            f.addCurve(to: CGPoint(x: x0 + 42, y: top - 2), control1: CGPoint(x: x0 + 14, y: top + 5),
                       control2: CGPoint(x: x0 + 28, y: top - 6))
            f.addLine(to: CGPoint(x: x0 + 42, y: top - 28))
            f.addCurve(to: CGPoint(x: x0, y: top - 26), control1: CGPoint(x: x0 + 28, y: top - 32),
                       control2: CGPoint(x: x0 + 14, y: top - 21))
            f.closeSubpath()
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 1, height: -2), blur: 3, color: Paint.hex(0x000000, 0.3))
            Paint.fill(ctx, f, flagRed)
            ctx.restoreGState()
            Paint.fill(ctx, f, Paint.gradient([(0, Paint.hex(0xFFFFFF, 0.18)), (1, Paint.hex(0x000000, 0.12))]),
                       from: CGPoint(x: 0, y: top), to: CGPoint(x: 0, y: top - 28))
            // Bolt at the pivot.
            Paint.circle(ctx, a, 6.5, Paint.hex(0x15233A))
            Paint.circle(ctx, a, 3.2, Paint.hex(0x8C98AA))
        }
    }

    // MARK: Envelopes inside the mailbox

    static let envelopeSize = CGSize(width: 46, height: 31)

    static func envelope(kind: MailKind, read: Bool, scale: CGFloat) -> CGImage? {
        let s = envelopeSize
        return Paint.render(CGSize(width: s.width, height: s.height + 8), scale: scale) { ctx in
            let body = CGRect(x: 1, y: 2, width: s.width - 2, height: s.height - 3)
            if read {
                // A letter peeking out of an opened envelope.
                let paper = CGRect(x: body.minX + 6, y: body.midY, width: body.width - 12, height: body.height * 0.5 + 7)
                Paint.fill(ctx, CGPath(rect: paper, transform: nil), Paint.hex(0xFFFDF6))
                for i in 0..<3 {
                    let y = paper.maxY - 5 - CGFloat(i) * 3.5
                    let l = CGMutablePath(); l.move(to: CGPoint(x: paper.minX + 4, y: y)); l.addLine(to: CGPoint(x: paper.maxX - 6, y: y))
                    Paint.stroke(ctx, l, Paint.hex(0x5A6A85, 0.5), 0.7)
                }
            }
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -1.5), blur: 2.5, color: Paint.hex(0x000000, 0.45))
            Paint.fill(ctx, CGPath(roundedRect: body, cornerWidth: 2, cornerHeight: 2, transform: nil), Paint.hex(0xF4EBD8))
            ctx.restoreGState()
            // Flap lines.
            let flap = CGMutablePath()
            if read {
                flap.move(to: CGPoint(x: body.minX, y: body.maxY)); flap.addLine(to: CGPoint(x: body.midX, y: body.midY - 3))
                flap.addLine(to: CGPoint(x: body.maxX, y: body.maxY))
            } else {
                flap.move(to: CGPoint(x: body.minX + 1, y: body.maxY - 1)); flap.addLine(to: CGPoint(x: body.midX, y: body.midY - 1))
                flap.addLine(to: CGPoint(x: body.maxX - 1, y: body.maxY - 1))
            }
            Paint.stroke(ctx, flap, Paint.hex(0xB8A88A), 0.9)
            // Stamp in the corner, in the colour of the kind of mail.
            let stamp = CGRect(x: body.maxX - 11, y: body.maxY - 11, width: 8, height: 9)
            Paint.fill(ctx, CGPath(rect: stamp.insetBy(dx: -1, dy: -1), transform: nil), Paint.hex(0xFFFFFF))
            Paint.fill(ctx, CGPath(rect: stamp, transform: nil), kind.color)
            if !read {
                // Wax seal.
                Paint.circle(ctx, CGPoint(x: body.midX, y: body.midY - 1), 4.6, Paint.hex(0xA8241A))
                Paint.circle(ctx, CGPoint(x: body.midX - 1, y: body.midY), 1.6, Paint.hex(0xFFFFFF, 0.25))
            }
        }
    }

    // MARK: Stamp and postmark for the letter paper

    static func stamp(kind: MailKind, scale: CGFloat) -> CGImage? {
        let s = CGSize(width: 74, height: 88)
        return Paint.render(s, scale: scale) { ctx in
            let r = CGRect(origin: .zero, size: s).insetBy(dx: 3, dy: 3)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 2, color: Paint.hex(0x000000, 0.25))
            Paint.fill(ctx, CGPath(rect: r, transform: nil), Paint.hex(0xFFFDF8))
            ctx.restoreGState()
            // Perforated edge.
            ctx.saveGState(); ctx.setBlendMode(.clear)
            var x = r.minX
            while x <= r.maxX { Paint.circle(ctx, CGPoint(x: x, y: r.minY), 2.2, Paint.hex(0)); Paint.circle(ctx, CGPoint(x: x, y: r.maxY), 2.2, Paint.hex(0)); x += 7.4 }
            var y = r.minY
            while y <= r.maxY { Paint.circle(ctx, CGPoint(x: r.minX, y: y), 2.2, Paint.hex(0)); Paint.circle(ctx, CGPoint(x: r.maxX, y: y), 2.2, Paint.hex(0)); y += 7.4 }
            ctx.restoreGState()
            let inner = r.insetBy(dx: 6, dy: 6)
            Paint.fill(ctx, CGPath(rect: inner, transform: nil), kind.color)
            // A little mailbox in the stamp.
            let mini = CGRect(x: inner.midX - 11, y: inner.minY + 22, width: 22, height: 24)
            Paint.fill(ctx, Paint.arch(mini), Paint.hex(0xFFFFFF, 0.9))
            Paint.fill(ctx, CGPath(rect: CGRect(x: inner.midX - 2, y: inner.minY + 8, width: 4, height: 14), transform: nil),
                       Paint.hex(0xFFFFFF, 0.9))
            Paint.text(ctx, kind.label, at: CGPoint(x: inner.midX, y: inner.maxY - 13), font: NSFont.systemFont(ofSize: 7, weight: .bold),
                       color: .white, kern: 0.6, centered: true)
        }
    }

    // MARK: The whole mailbox, closed, flag up (app icon and previews)

    static func closedComposite(scale: CGFloat, flagUp: Bool) -> CGImage? {
        Paint.render(Geo.size, scale: scale) { ctx in
            let full = CGRect(origin: .zero, size: Geo.size)
            if let b = base(scale: scale) { ctx.draw(b, in: full) }
            if let b = body(scale: scale) { ctx.draw(b, in: full) }
            if let d = doorFront(scale: scale) { ctx.draw(d, in: Geo.door) }
            if let f = flag(scale: scale) {
                ctx.saveGState()
                ctx.translateBy(x: Geo.flagPivot.x, y: Geo.flagPivot.y)
                ctx.rotate(by: flagUp ? 0 : -.pi / 2)
                ctx.draw(f, in: CGRect(x: -Geo.flagAnchor.x, y: -Geo.flagAnchor.y, width: Geo.flagSize.width, height: Geo.flagSize.height))
                ctx.restoreGState()
            }
        }
    }

    /// Square icon art on a plain white background, ready for scripts/make-icon.swift.
    static func iconArt(size: CGFloat) -> CGImage? {
        Paint.render(CGSize(width: size, height: size), scale: 1) { ctx in
            ctx.setFillColor(Paint.hex(0xFFFFFF)); ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
            let tile = CGRect(x: size * 0.06, y: size * 0.06, width: size * 0.88, height: size * 0.88)
            let path = CGPath(roundedRect: tile, cornerWidth: tile.width * 0.22, cornerHeight: tile.width * 0.22, transform: nil)
            Paint.fill(ctx, path, Paint.gradient([(0, Paint.hex(0xBFE3F5)), (1, Paint.hex(0x7FC1E6))]),
                       from: CGPoint(x: 0, y: tile.maxY), to: CGPoint(x: 0, y: tile.minY))
            // Grass.
            ctx.saveGState(); ctx.addPath(path); ctx.clip()
            Paint.fill(ctx, CGPath(ellipseIn: CGRect(x: tile.minX - tile.width * 0.2, y: tile.minY - tile.height * 0.32,
                                                    width: tile.width * 1.4, height: tile.height * 0.55), transform: nil),
                       Paint.gradient([(0, Paint.hex(0x8CCB6A)), (1, Paint.hex(0x5DA84A))]),
                       from: CGPoint(x: 0, y: tile.minY + tile.height * 0.23), to: CGPoint(x: 0, y: tile.minY))
            if let m = closedComposite(scale: size / Geo.size.height * 1.15, flagUp: true) {
                let h = tile.height * 0.98, w = h * Geo.size.width / Geo.size.height
                ctx.draw(m, in: CGRect(x: tile.midX - w / 2 - tile.width * 0.03, y: tile.minY + tile.height * 0.01, width: w, height: h))
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
