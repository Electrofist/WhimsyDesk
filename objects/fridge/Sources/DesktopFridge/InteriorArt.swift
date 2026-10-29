import AppKit
import FridgeCore

/// The inside of the fridge, seen from slightly above. Drawn once per backing scale.
/// All depth cues come from `InteriorGeometry`, which the item layout also uses.
enum InteriorArt {
    private static var size: CGSize {
        return CGSize(width: InteriorGeometry.openingWidth, height: InteriorGeometry.openingHeight)
    }

    private static func pt(_ x: Double, _ y: Double, _ depth: Double) -> CGPoint {
        let r = InteriorGeometry.project(x: x, y: y, depth: depth)
        return CGPoint(x: r.x, y: r.y)
    }

    static func interior(scale: CGFloat) -> CGImage? {
        return Art.render(size: size, scale: scale) { ctx in
            let w = InteriorGeometry.openingWidth
            let h = InteriorGeometry.openingHeight

            let fbl = pt(0, 0, 0), fbr = pt(w, 0, 0), ftl = pt(0, h, 0), ftr = pt(w, h, 0)
            let bbl = pt(0, 0, 1), bbr = pt(w, 0, 1), btl = pt(0, h, 1), btr = pt(w, h, 1)

            // Fallback fill so no seam ever shows a hole.
            ctx.setFillColor(Art.hex(0x9DB8C2))
            ctx.fill(CGRect(origin: .zero, size: size))

            // Floor.
            Art.fill(ctx, path: Art.polygon([fbl, fbr, bbr, bbl]),
                     gradient: Art.gradient([(0, Art.hex(0x9DBAC5)), (1, Art.hex(0xD3E4EA))]),
                     from: CGPoint(x: 0, y: fbl.y), to: CGPoint(x: 0, y: bbl.y))
            // A soft sheen on the floor makes it read as glossy plastic.
            Art.fill(ctx, path: Art.polygon([pt(30, 0, 0), pt(110, 0, 0), pt(120, 0, 1), pt(60, 0, 1)]),
                     color: Art.color(1, 1, 1, 0.10))

            // Side walls, darker toward the front.
            Art.fill(ctx, path: Art.polygon([fbl, bbl, btl, ftl]),
                     gradient: Art.gradient([(0, Art.hex(0xB5CFD8)), (1, Art.hex(0xDCEAF0))]),
                     from: CGPoint(x: fbl.x, y: 0), to: CGPoint(x: bbl.x, y: 0))
            Art.fill(ctx, path: Art.polygon([fbr, bbr, btr, ftr]),
                     gradient: Art.gradient([(0, Art.hex(0xA9C5CF)), (1, Art.hex(0xD6E6EC))]),
                     from: CGPoint(x: fbr.x, y: 0), to: CGPoint(x: bbr.x, y: 0))

            // Back wall.
            Art.fill(ctx, path: Art.polygon([bbl, bbr, btr, btl]),
                     gradient: Art.gradient([(0, Art.hex(0xE0EEF3)), (1, Art.hex(0xF6FBFD))]),
                     from: CGPoint(x: 0, y: bbl.y), to: CGPoint(x: 0, y: h))

            // Corner seams.
            ctx.setLineCap(.round)
            ctx.setStrokeColor(Art.color(0.1, 0.25, 0.32, 0.22))
            ctx.setLineWidth(1.4)
            for (a, b) in [(fbl, bbl), (fbr, bbr), (bbl, bbr), (bbl, btl), (bbr, btr)] {
                ctx.move(to: a)
                ctx.addLine(to: b)
                ctx.strokePath()
            }

            // Shelf rails on both walls, then the glass.
            for front in InteriorGeometry.shelfFrontY {
                drawRails(ctx, y: front, w: w)
            }
            for front in InteriorGeometry.shelfFrontY {
                drawShelf(ctx, y: front, w: w)
            }

            // Vignette keeps the eye on the middle and hides polygon corners.
            let vignette = Art.gradient([(0, Art.color(0, 0.05, 0.1, 0)), (0.62, Art.color(0, 0.05, 0.1, 0)), (1, Art.color(0, 0.05, 0.1, 0.30))])
            ctx.drawRadialGradient(vignette,
                                   startCenter: CGPoint(x: w / 2, y: h * 0.52), startRadius: 0,
                                   endCenter: CGPoint(x: w / 2, y: h * 0.52), endRadius: h * 0.68,
                                   options: [.drawsAfterEndLocation])
        }
    }

    private static func drawRails(_ ctx: CGContext, y: Double, w: Double) {
        let railWidth: CGFloat = 3
        for x in [0.0, w] {
            let a = pt(x, y, 0)
            let b = pt(x, y, 1)
            ctx.setStrokeColor(Art.color(0.1, 0.25, 0.32, 0.35))
            ctx.setLineWidth(railWidth)
            ctx.move(to: a)
            ctx.addLine(to: b)
            ctx.strokePath()
            ctx.setStrokeColor(Art.color(1, 1, 1, 0.45))
            ctx.setLineWidth(1)
            ctx.move(to: CGPoint(x: a.x, y: a.y + 2))
            ctx.addLine(to: CGPoint(x: b.x, y: b.y + 2))
            ctx.strokePath()
        }
    }

    private static func drawShelf(_ ctx: CGContext, y: Double, w: Double) {
        let fl = pt(0, y, 0), fr = pt(w, y, 0), br = pt(w, y, 1), bl = pt(0, y, 1)
        let top = Art.polygon([fl, fr, br, bl])

        // Soft shadow the glass throws on the wall behind and below it.
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -5), blur: 9, color: Art.color(0, 0.1, 0.18, 0.32))
        Art.fill(ctx, path: top, color: Art.color(0.80, 0.93, 0.97, 0.9))
        ctx.restoreGState()

        // Glass top: clearer at the front, frosted toward the back.
        Art.fill(ctx, path: top,
                 gradient: Art.gradient([(0, Art.color(0.86, 0.97, 1.0, 0.92)), (1, Art.color(0.70, 0.88, 0.95, 0.88))]),
                 from: CGPoint(x: 0, y: fl.y), to: CGPoint(x: 0, y: bl.y))

        // Diagonal glare streaks across the glass.
        ctx.saveGState()
        ctx.addPath(top)
        ctx.clip()
        ctx.setFillColor(Art.color(1, 1, 1, 0.20))
        ctx.addPath(Art.polygon([CGPoint(x: fl.x + 40, y: fl.y), CGPoint(x: fl.x + 78, y: fl.y),
                                 CGPoint(x: bl.x + 70, y: bl.y), CGPoint(x: bl.x + 48, y: bl.y)]))
        ctx.fillPath()
        ctx.setFillColor(Art.color(1, 1, 1, 0.12))
        ctx.addPath(Art.polygon([CGPoint(x: fl.x + 130, y: fl.y), CGPoint(x: fl.x + 150, y: fl.y),
                                 CGPoint(x: bl.x + 138, y: bl.y), CGPoint(x: bl.x + 124, y: bl.y)]))
        ctx.fillPath()
        ctx.restoreGState()

        // Front lip: a thick glass edge with a bright top and a green-blue underside.
        let lipHeight: CGFloat = 7
        let lip = CGRect(x: fl.x, y: fl.y - lipHeight, width: fr.x - fl.x, height: lipHeight)
        Art.fill(ctx, path: CGPath(rect: lip, transform: nil),
                 gradient: Art.gradient([(0, Art.color(0.45, 0.72, 0.80, 0.95)), (0.5, Art.color(0.75, 0.93, 0.98, 0.98)), (1, Art.color(0.96, 1, 1, 1))]),
                 from: CGPoint(x: 0, y: lip.minY), to: CGPoint(x: 0, y: lip.maxY))
        ctx.setStrokeColor(Art.color(0.1, 0.3, 0.38, 0.45))
        ctx.setLineWidth(0.9)
        ctx.move(to: CGPoint(x: lip.minX, y: lip.minY))
        ctx.addLine(to: CGPoint(x: lip.maxX, y: lip.minY))
        ctx.strokePath()

        // Back edge where the glass meets the wall.
        ctx.setStrokeColor(Art.color(1, 1, 1, 0.55))
        ctx.setLineWidth(1)
        ctx.move(to: bl)
        ctx.addLine(to: br)
        ctx.strokePath()
    }

    // MARK: Frost

    /// Static rime, crystals and condensation. Drawn once, shown under the items.
    static func frost(scale: CGFloat) -> CGImage? {
        return Art.render(size: size, scale: scale) { ctx in
            let w = InteriorGeometry.openingWidth
            let h = InteriorGeometry.openingHeight
            var rng = SeededRandom(seed: 0xF205_7ED)

            // Seams where cold air settles: wall corners, back wall edges, shelf rails.
            var seams: [(CGPoint, CGPoint)] = [
                (pt(0, 0, 0), pt(0, 0, 1)), (pt(w, 0, 0), pt(w, 0, 1)),
                (pt(0, 0, 1), pt(w, 0, 1)),
                (pt(0, 0, 1), pt(0, h, 1)), (pt(w, 0, 1), pt(w, h, 1)),
                (pt(0, h, 0), pt(0, h, 1)), (pt(w, h, 0), pt(w, h, 1))
            ]
            for y in InteriorGeometry.shelfFrontY {
                seams.append((pt(0, y, 0), pt(0, y, 1)))
                seams.append((pt(w, y, 0), pt(w, y, 1)))
                seams.append((pt(0, y, 1), pt(w, y, 1)))
            }

            // Fine grain along every seam, thinning with distance.
            for (a, b) in seams {
                let length = hypot(b.x - a.x, b.y - a.y)
                let count = Int(length * 2.6)
                for _ in 0..<count {
                    let t = rng.unit()
                    let spread = ((rng.unit() + rng.unit() + rng.unit()) / 3 - 0.5) * 2   // roughly -1...1
                    let reach: CGFloat = 20
                    let dx = spread * reach
                    let dy = (rng.unit() - 0.5) * reach * 0.8
                    let x = a.x + (b.x - a.x) * t + dx
                    let y = a.y + (b.y - a.y) * t + dy
                    let fall = max(0, 1 - hypot(dx, dy) / reach)
                    let r = rng.range(0.35, 1.25) * (0.5 + fall)
                    ctx.setFillColor(Art.color(0.95, 0.99, 1, rng.range(0.10, 0.50) * fall))
                    ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
                }
            }

            // Crystal ferns: tiny six-armed stars clustered in the corners.
            ctx.setLineCap(.round)
            ctx.setLineWidth(0.6)
            for _ in 0..<90 {
                let seam = seams[Int(rng.range(0, CGFloat(seams.count)))]
                let t = rng.unit()
                let cx = seam.0.x + (seam.1.x - seam.0.x) * t + (rng.unit() - 0.5) * 14
                let cy = seam.0.y + (seam.1.y - seam.0.y) * t + (rng.unit() - 0.5) * 14
                let arm = rng.range(2.0, 5.5)
                let phase = rng.range(0, .pi / 3)
                ctx.setStrokeColor(Art.color(1, 1, 1, rng.range(0.25, 0.6)))
                for k in 0..<6 {
                    let a = phase + CGFloat(k) * .pi / 3
                    ctx.move(to: CGPoint(x: cx, y: cy))
                    ctx.addLine(to: CGPoint(x: cx + cos(a) * arm, y: cy + sin(a) * arm))
                    ctx.strokePath()
                }
            }

            // Condensation beads on the walls.
            let back = (min: pt(0, 0, 1), max: pt(w, h, 1))
            for _ in 0..<70 {
                let x = rng.range(back.min.x + 6, back.max.x - 6)
                let y = rng.range(back.min.y + 10, min(back.max.y, CGFloat(h)) - 6)
                let r = rng.range(1.1, 3.0)
                let bead = CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)
                ctx.setFillColor(Art.color(0.82, 0.94, 1, 0.20))
                ctx.fillEllipse(in: bead)
                ctx.setStrokeColor(Art.color(1, 1, 1, 0.42))
                ctx.setLineWidth(0.6)
                ctx.strokeEllipse(in: bead)
                ctx.setFillColor(Art.color(1, 1, 1, 0.85))
                ctx.fillEllipse(in: CGRect(x: x - r * 0.55, y: y + r * 0.15, width: r * 0.55, height: r * 0.55))
            }
        }
    }
}
