import AppKit
import FridgeCore

/// Sticky notes and photo magnets for the door fronts. Each one is drawn once when it changes.
enum NoteArt {
    static let noteSize = CGSize(width: 70, height: 70)
    /// Text sits below the adhesive strip, inset from the paper's edges.
    static let textInsets = NSEdgeInsets(top: 13, left: 7, bottom: 6, right: 7)

    /// Paper colors: classic yellow, pink, mint, sky.
    static let palette: [(paper: UInt32, strip: UInt32, name: String)] = [
        (0xFFE873, 0xF2D649, "Yellow"),
        (0xFFB3C7, 0xF297B0, "Pink"),
        (0xB8F0C8, 0x96DFAD, "Mint"),
        (0xB5DDFF, 0x92C8F5, "Blue")
    ]

    static var font: NSFont {
        return NSFont(name: "Noteworthy-Bold", size: 11) ?? NSFont.systemFont(ofSize: 10.5, weight: .medium)
    }

    static let ink = NSColor(srgbRed: 0.16, green: 0.17, blue: 0.22, alpha: 0.92)

    static var textAttributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = -1
        return [.font: font, .foregroundColor: ink, .paragraphStyle: paragraph]
    }

    static func color(_ index: Int) -> (paper: UInt32, strip: UInt32, name: String) {
        return palette[((index % palette.count) + palette.count) % palette.count]
    }

    // MARK: Sticky note

    static func note(text: String, color index: Int, scale: CGFloat) -> CGImage? {
        let c = color(index)
        let size = noteSize
        return Art.render(size: size, scale: scale) { ctx in
            let rect = CGRect(origin: .zero, size: size)
            // Paper, a touch darker toward the lifted bottom edge.
            Art.fill(ctx, path: CGPath(rect: rect, transform: nil),
                     gradient: Art.gradient([(0, Art.hex(c.strip)), (0.35, Art.hex(c.paper)), (1, Art.hex(c.paper))]),
                     from: .zero, to: CGPoint(x: 0, y: size.height))
            // The adhesive strip along the top is a shade deeper.
            ctx.setFillColor(Art.hex(c.strip, 0.55))
            ctx.fill(CGRect(x: 0, y: size.height - 10, width: size.width, height: 10))
            // The bottom right corner curls up a little and catches light.
            let curl = Art.polygon([CGPoint(x: size.width - 13, y: 0), CGPoint(x: size.width, y: 0), CGPoint(x: size.width, y: 11)])
            Art.fill(ctx, path: curl, color: Art.color(1, 1, 1, 0.32))
            Art.stroke(ctx, path: CGPath(rect: rect.insetBy(dx: 0.25, dy: 0.25), transform: nil), color: Art.color(0, 0, 0, 0.10), width: 0.5)

            guard !text.isEmpty else { return }
            let graphics = NSGraphicsContext(cgContext: ctx, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphics
            NSAttributedString(string: text, attributes: textAttributes).draw(with: textRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    /// Where the text goes on the note, bottom-left origin.
    static var textRect: CGRect {
        let i = textInsets
        return CGRect(x: i.left, y: i.bottom, width: noteSize.width - i.left - i.right,
                      height: noteSize.height - i.top - i.bottom)
    }

    // MARK: Photo magnet

    /// White border round the picture, deeper at the bottom like an instant photo.
    static let photoBorder: CGFloat = 4
    static let photoChin: CGFloat = 11
    static let photoMaxSide: CGFloat = 84
    /// The round magnet overlaps the top edge, so the image has this much room above the print.
    static let magnetRadius: CGFloat = 7

    /// The print's size for a picture of `pixelSize`, before the magnet headroom.
    static func photoSize(for pixelSize: CGSize) -> CGSize {
        let aspect = max(0.4, min(2.5, pixelSize.width / max(pixelSize.height, 1)))
        let inner = aspect >= 1
            ? CGSize(width: photoMaxSide, height: (photoMaxSide / aspect).rounded())
            : CGSize(width: (photoMaxSide * aspect).rounded(), height: photoMaxSide)
        return CGSize(width: inner.width + photoBorder * 2, height: inner.height + photoBorder + photoChin)
    }

    /// Full layer size: the print plus room for the magnet on top.
    static func photoLayerSize(for pixelSize: CGSize) -> CGSize {
        let print = photoSize(for: pixelSize)
        return CGSize(width: print.width, height: print.height + magnetRadius)
    }

    static func photo(_ image: CGImage, magnetColor index: Int, scale: CGFloat) -> CGImage? {
        let pixel = CGSize(width: image.width, height: image.height)
        let print = photoSize(for: pixel)
        let size = photoLayerSize(for: pixel)
        return Art.render(size: size, scale: scale) { ctx in
            let paper = CGRect(origin: .zero, size: print)
            Art.fill(ctx, path: CGPath(rect: paper, transform: nil),
                     gradient: Art.gradient([(0, Art.hex(0xEDEBE6)), (1, Art.hex(0xFBFAF7))]),
                     from: .zero, to: CGPoint(x: 0, y: print.height))
            Art.stroke(ctx, path: CGPath(rect: paper.insetBy(dx: 0.25, dy: 0.25), transform: nil), color: Art.color(0, 0, 0, 0.14), width: 0.5)

            // Picture, cropped to fill its window.
            let window = CGRect(x: photoBorder, y: photoChin, width: print.width - photoBorder * 2, height: print.height - photoBorder - photoChin)
            ctx.saveGState()
            ctx.clip(to: window)
            let fill = max(window.width / pixel.width, window.height / pixel.height)
            let drawn = CGSize(width: pixel.width * fill, height: pixel.height * fill)
            ctx.draw(image, in: CGRect(x: window.midX - drawn.width / 2, y: window.midY - drawn.height / 2,
                                       width: drawn.width, height: drawn.height))
            // A faint gloss across the print.
            Art.fill(ctx, path: CGPath(rect: window, transform: nil),
                     gradient: Art.gradient([(0, Art.color(1, 1, 1, 0)), (0.6, Art.color(1, 1, 1, 0.0)), (1, Art.color(1, 1, 1, 0.16))]),
                     from: CGPoint(x: window.minX, y: window.minY), to: CGPoint(x: window.maxX, y: window.maxY))
            ctx.restoreGState()

            drawMagnet(ctx, center: CGPoint(x: print.width / 2, y: print.height - 1), color: index)
        }
    }

    /// A glossy round magnet button with a soft drop shadow.
    private static func drawMagnet(_ ctx: CGContext, center: CGPoint, color index: Int) {
        let colors: [UInt32] = [0xE8453C, 0x2F7DE1, 0x2DB36B, 0xF2A516]
        let base = colors[((index % colors.count) + colors.count) % colors.count]
        let r = magnetRadius - 0.5
        let disc = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -1.5), blur: 2.5, color: Art.color(0, 0, 0, 0.45))
        ctx.setFillColor(Art.hex(base))
        ctx.fillEllipse(in: disc)
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addEllipse(in: disc)
        ctx.clip()
        let shine = Art.gradient([(0, Art.color(1, 1, 1, 0.65)), (0.45, Art.color(1, 1, 1, 0.08)), (1, Art.color(0, 0, 0, 0.25))])
        ctx.drawRadialGradient(shine, startCenter: CGPoint(x: center.x - r * 0.35, y: center.y + r * 0.4), startRadius: 0,
                               endCenter: center, endRadius: r * 1.1, options: [.drawsAfterEndLocation])
        ctx.restoreGState()
    }

    /// A downsized PNG of an image file, small enough to keep beside the fridge. Nil if it is not a picture.
    static func thumbnailPNG(of url: URL, maxPixels: Int = 480) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, thumb, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    static func loadImage(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
