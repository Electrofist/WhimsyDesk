import AppKit

/// Exterior art: cabinet, door faces, hinges and shadows. Rendered once per backing scale
/// and then handed to Core Animation as static layer contents.
enum FridgeArt {
    // MARK: Cabinet

    static func cabinet(scale: CGFloat) -> CGImage? {
        return Art.render(size: Geo.bodySize, scale: scale) { ctx in
            let body = CGRect(x: 0, y: 8, width: Geo.bodySize.width, height: Geo.bodySize.height - 8)
            let bodyPath = Art.roundedPath(body, 28)

            // Feet.
            for x in [CGFloat(22), CGFloat(230)] {
                Art.fill(ctx, path: Art.roundedPath(CGRect(x: x, y: 0, width: 28, height: 14), 4), color: Art.hex(0x262A2D))
            }

            // Painted steel, lighter on the left where the window light hits.
            // Glossy lime enamel, matching the door artwork.
            let paint = Art.gradient([(0, Art.hex(0xC9CF3A)), (0.5, Art.hex(0x9DA716)), (1, Art.hex(0x6E7303))])
            Art.fill(ctx, path: bodyPath, gradient: paint, from: CGPoint(x: 0, y: 0), to: CGPoint(x: body.width, y: 0))

            // Right side shows the slight thickness of the cabinet.
            ctx.saveGState()
            ctx.addPath(bodyPath)
            ctx.clip()
            let side = Art.gradient([(0, Art.color(0, 0, 0, 0)), (1, Art.color(0.05, 0.12, 0.10, 0.34))])
            ctx.drawLinearGradient(side, start: CGPoint(x: body.width - 16, y: 0), end: CGPoint(x: body.width, y: 0), options: [])
            // Top edge catches light.
            let top = Art.gradient([(0, Art.color(1, 1, 1, 0)), (1, Art.color(1, 1, 1, 0.55))])
            ctx.drawLinearGradient(top, start: CGPoint(x: 0, y: body.maxY - 12), end: CGPoint(x: 0, y: body.maxY), options: [])
            // Bottom plinth is in shade.
            let plinth = Art.gradient([(0, Art.color(0, 0, 0, 0.30)), (1, Art.color(0, 0, 0, 0))])
            ctx.drawLinearGradient(plinth, start: CGPoint(x: 0, y: body.minY), end: CGPoint(x: 0, y: body.minY + 14), options: [])
            ctx.restoreGState()

            // Chrome rim around the opening, only visible when the door is open.
            // White moulded liner frame around the opening, only visible when the door is open.
            let rimRect = CGRect(x: 7, y: 15, width: Geo.bodySize.width - 14, height: Geo.bodySize.height - 22)
            Art.fill(ctx, path: Art.roundedPath(rimRect, 14),
                     gradient: Art.gradient([(0, Art.hex(0xDDE2E2)), (0.5, Art.hex(0xF6F8F7)), (1, Art.hex(0xD2D8D9))]),
                     from: CGPoint(x: rimRect.minX, y: 0), to: CGPoint(x: rimRect.maxX, y: 0))
            Art.stroke(ctx, path: Art.roundedPath(rimRect.insetBy(dx: 0.5, dy: 0.5), 14),
                       color: Art.color(0, 0, 0, 0.18), width: 1)
            Art.stroke(ctx, path: Art.roundedPath(Geo.opening.insetBy(dx: -1.5, dy: -1.5), 6),
                       color: Art.color(0.3, 0.36, 0.38, 0.35), width: 1.2)

            // Outer bevel.
            Art.stroke(ctx, path: bodyPath, color: Art.color(0, 0, 0, 0.22), width: 1)
            Art.stroke(ctx, path: Art.roundedPath(body.insetBy(dx: 1.2, dy: 1.2), 27), color: Art.color(1, 1, 1, 0.45), width: 1)
        }
    }

    // MARK: Door

    /// The retro door artwork (lime enamel, chrome levers and trim), one bundled PNG per door.
    private static func artwork(named name: String) -> CGImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    static func doorFront(_ door: DoorSpec, scale: CGFloat) -> CGImage? {
        let image = artwork(named: door.artwork)
        return Art.render(size: door.size, scale: scale) { ctx in
            let rect = CGRect(origin: .zero, size: door.size)
            let path = door.outline(in: rect, radius: Geo.doorCornerRadius)
            ctx.saveGState()
            ctx.addPath(path)
            ctx.clip()
            if let image = image {
                ctx.draw(image, in: rect)
            } else {
                Art.fill(ctx, path: path, color: Art.hex(0x9DA716))   // artwork missing from the bundle
            }
            ctx.restoreGState()
            // Thin bevels so the enamel edge reads against any wallpaper.
            Art.stroke(ctx, path: path, color: Art.color(0, 0, 0, 0.35), width: 1)
            Art.stroke(ctx, path: door.outline(in: rect.insetBy(dx: 1.3, dy: 1.3), radius: Geo.doorCornerRadius - 1),
                       color: Art.color(1, 1, 0.8, 0.30), width: 1)
        }
    }

    static func doorBack(_ door: DoorSpec, scale: CGFloat) -> CGImage? {
        return Art.render(size: door.size, scale: scale) { ctx in
            let rect = CGRect(origin: .zero, size: door.size)
            let path = door.outline(in: rect, radius: Geo.doorCornerRadius)
            Art.fill(ctx, path: path, gradient: Art.gradient([(0, Art.hex(0xDCE8EE)), (1, Art.hex(0xF3F8FA))]),
                     from: .zero, to: CGPoint(x: 0, y: rect.height))

            // Moulded liner panel, recessed inside the gasket. The bins are real 3D layers in front of it.
            let panel = Art.roundedPath(rect.insetBy(dx: 18, dy: 18), 12)
            Art.fill(ctx, path: panel, gradient: Art.gradient([(0, Art.hex(0xC9D8E0)), (1, Art.hex(0xE6EFF3))]),
                     from: CGPoint(x: 0, y: 0), to: CGPoint(x: rect.width, y: 0))
            Art.stroke(ctx, path: panel, color: Art.color(0.2, 0.3, 0.36, 0.25), width: 1.2)
            Art.stroke(ctx, path: Art.roundedPath(rect.insetBy(dx: 19.5, dy: 19.5), 11), color: Art.color(1, 1, 1, 0.6), width: 1)
            // Shadows the bins throw onto the liner below them.
            for y in door.binY {
                let shade = CGRect(x: Geo.binInset, y: y - 18, width: rect.width - 2 * Geo.binInset, height: 18)
                Art.fill(ctx, path: CGPath(rect: shade, transform: nil),
                         gradient: Art.gradient([(0, Art.color(0, 0.1, 0.15, 0)), (1, Art.color(0, 0.1, 0.15, 0.22))]),
                         from: CGPoint(x: 0, y: shade.minY), to: CGPoint(x: 0, y: shade.maxY))
            }

            // Magnetic gasket frame.
            let gasketOuter = door.outline(in: rect.insetBy(dx: 7, dy: 7), radius: 18)
            Art.stroke(ctx, path: gasketOuter, color: Art.hex(0x3A4449), width: 13)
            Art.stroke(ctx, path: door.outline(in: rect.insetBy(dx: 10.5, dy: 10.5), radius: 15), color: Art.color(1, 1, 1, 0.18), width: 1.2)
            Art.stroke(ctx, path: door.outline(in: rect.insetBy(dx: 3.5, dy: 3.5), radius: 21), color: Art.color(0, 0, 0, 0.35), width: 1)

            Art.stroke(ctx, path: path, color: Art.color(0, 0, 0, 0.25), width: 1)
        }
    }

    // MARK: Hinge

    static let hingeSize = CGSize(width: 13, height: 40)
    /// The hinge is drawn on a 20 x 64 grid and scaled down to `hingeSize`.
    private static let hingeDesign = CGSize(width: 20, height: 64)

    static func hinge(scale: CGFloat) -> CGImage? {
        return Art.render(size: hingeSize, scale: scale) { ctx in
            ctx.scaleBy(x: hingeSize.width / hingeDesign.width, y: hingeSize.height / hingeDesign.height)
            let plate = Art.roundedPath(CGRect(x: 1, y: 2, width: 18, height: 60), 4)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 1, height: -1.5), blur: 2.5, color: Art.color(0, 0, 0, 0.5))
            Art.fill(ctx, path: plate, color: Art.hex(0x9AA9A3))
            ctx.restoreGState()
            let steel = Art.gradient([(0, Art.hex(0x6D7E78)), (0.35, Art.hex(0xF2F8F6)), (0.7, Art.hex(0xB0C0BA)), (1, Art.hex(0x72847D))])
            Art.fill(ctx, path: plate, gradient: steel, from: CGPoint(x: 1, y: 0), to: CGPoint(x: 19, y: 0))
            Art.stroke(ctx, path: plate, color: Art.color(0, 0, 0, 0.35), width: 0.8)
            // Knuckle segments.
            ctx.setStrokeColor(Art.color(0, 0, 0, 0.3))
            ctx.setLineWidth(0.8)
            for y in [CGFloat(22), CGFloat(32), CGFloat(42)] {
                ctx.move(to: CGPoint(x: 2, y: y))
                ctx.addLine(to: CGPoint(x: 18, y: y))
                ctx.strokePath()
            }
            // Screws.
            for y in [CGFloat(10), CGFloat(54)] {
                let screw = CGRect(x: 7, y: y - 3, width: 6, height: 6)
                Art.fill(ctx, path: CGPath(ellipseIn: screw, transform: nil), color: Art.hex(0x5A6B65))
                ctx.setStrokeColor(Art.color(1, 1, 1, 0.6))
                ctx.setLineWidth(0.8)
                ctx.move(to: CGPoint(x: 7.8, y: y))
                ctx.addLine(to: CGPoint(x: 12.2, y: y))
                ctx.strokePath()
            }
        }
    }

    // MARK: Shadows

    static let contactShadowSize = CGSize(width: 380, height: 70)

    /// Contact shadow plus a tight ambient occlusion line right under the cabinet.
    static func contactShadow(scale: CGFloat) -> CGImage? {
        return Art.render(size: contactShadowSize, scale: scale) { ctx in
            let size = contactShadowSize
            ctx.saveGState()
            ctx.translateBy(x: size.width / 2, y: size.height / 2)
            ctx.scaleBy(x: 1, y: 0.18)
            let g = Art.gradient([(0, Art.color(0, 0, 0, 0.55)), (0.55, Art.color(0, 0, 0, 0.22)), (1, Art.color(0, 0, 0, 0))])
            ctx.drawRadialGradient(g, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: size.width / 2, options: [])
            ctx.restoreGState()

            // Ambient occlusion: darkest where the feet meet the floor.
            ctx.saveGState()
            ctx.translateBy(x: size.width / 2, y: size.height / 2 + 1)
            ctx.scaleBy(x: 1, y: 0.06)
            let ao = Art.gradient([(0, Art.color(0, 0, 0, 0.70)), (0.8, Art.color(0, 0, 0, 0.30)), (1, Art.color(0, 0, 0, 0))])
            ctx.drawRadialGradient(ao, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: Geo.bodySize.width / 2 + 6, options: [])
            ctx.restoreGState()
        }
    }

    static let liftShadowSize = CGSize(width: 460, height: 150)

    /// Wider, softer, lower shadow that fades in while the window is being dragged.
    static func liftShadow(scale: CGFloat) -> CGImage? {
        return Art.render(size: liftShadowSize, scale: scale) { ctx in
            let size = liftShadowSize
            ctx.translateBy(x: size.width / 2, y: size.height / 2)
            ctx.scaleBy(x: 1, y: 0.30)
            let g = Art.gradient([(0, Art.color(0, 0, 0, 0.42)), (0.5, Art.color(0, 0, 0, 0.18)), (1, Art.color(0, 0, 0, 0))])
            ctx.drawRadialGradient(g, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: size.width / 2, options: [])
        }
    }

    static let itemShadowSize = CGSize(width: 64, height: 18)

    static func itemShadow(scale: CGFloat) -> CGImage? {
        return Art.render(size: itemShadowSize, scale: scale) { ctx in
            let size = itemShadowSize
            ctx.translateBy(x: size.width / 2, y: size.height / 2)
            ctx.scaleBy(x: 1, y: size.height / size.width)
            let g = Art.gradient([(0, Art.color(0, 0.05, 0.1, 0.55)), (0.6, Art.color(0, 0.05, 0.1, 0.22)), (1, Art.color(0, 0, 0, 0))])
            ctx.drawRadialGradient(g, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: size.width / 2, options: [])
        }
    }
}
