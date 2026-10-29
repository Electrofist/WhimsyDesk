// Draws the DMG window background: a tall, playful "drag me home" scene.
// The app icon sits at the top, Applications at the bottom, with a soft glow in the
// object's accent colour between them and a trail of hands showing the drag.
//
// Usage: swift dmg-background.swift "<Object Name>" "<accent #RRGGBB>" <output.tiff>
// Writes a 1x + 2x TIFF for a 440 x 540 point window.
// Icon centres (Finder coordinates, from the top left): app at (220, 150), Applications at (220, 390).
import AppKit
import CoreImage

let args = CommandLine.arguments
guard args.count == 4 else { print("usage: dmg-background.swift <name> <#accent> <out.tiff>"); exit(1) }
let objectName = args[1], output = args[3]
let size = NSSize(width: 440, height: 540)
let appCenter = NSPoint(x: 220, y: 540 - 150)      // drawing coordinates, from the bottom left
let folderCenter = NSPoint(x: 220, y: 540 - 390)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}
let accentHex = UInt32(args[2].trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0xB7C23A
let accent = color(accentHex)

func centered(_ text: String, y: CGFloat, _ attributes: [NSAttributedString.Key: Any]) {
    let s = NSAttributedString(string: text, attributes: attributes)
    s.draw(at: NSPoint(x: (size.width - s.size().width) / 2, y: y))
}

/// The glow: a cone from the app down to the folder, blurred into light.
func glow(scale: CGFloat) -> CGImage? {
    let w = Int(size.width * scale), h = Int(size.height * scale)
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.scaleBy(x: scale, y: scale)
    let cone = CGMutablePath()
    cone.move(to: CGPoint(x: appCenter.x - 34, y: appCenter.y - 20))
    cone.addLine(to: CGPoint(x: appCenter.x + 34, y: appCenter.y - 20))
    cone.addQuadCurve(to: CGPoint(x: folderCenter.x + 150, y: folderCenter.y + 10),
                      control: CGPoint(x: appCenter.x + 60, y: folderCenter.y + 90))
    cone.addQuadCurve(to: CGPoint(x: folderCenter.x - 150, y: folderCenter.y + 10),
                      control: CGPoint(x: folderCenter.x, y: folderCenter.y - 60))
    cone.addQuadCurve(to: CGPoint(x: appCenter.x - 34, y: appCenter.y - 20),
                      control: CGPoint(x: appCenter.x - 60, y: folderCenter.y + 90))
    ctx.addPath(cone)
    ctx.setFillColor(accent.withAlphaComponent(0.55).cgColor)
    ctx.fillPath()
    // A brighter pool of light where the app lands.
    ctx.setFillColor(accent.withAlphaComponent(0.9).cgColor)
    ctx.fillEllipse(in: CGRect(x: folderCenter.x - 70, y: folderCenter.y - 10, width: 140, height: 70))
    guard let sharp = ctx.makeImage() else { return nil }
    let blurred = CIImage(cgImage: sharp).clampedToExtent()
        .applyingGaussianBlur(sigma: Double(30 * scale))
        .cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
    return CIContext().createCGImage(blurred, from: blurred.extent)
}

func sparkle(at p: NSPoint, size s: CGFloat, alpha: CGFloat) {
    let star = NSBezierPath()
    star.move(to: NSPoint(x: p.x, y: p.y + s))
    star.curve(to: NSPoint(x: p.x + s, y: p.y), controlPoint1: NSPoint(x: p.x + s * 0.12, y: p.y + s * 0.12), controlPoint2: NSPoint(x: p.x + s * 0.12, y: p.y + s * 0.12))
    star.curve(to: NSPoint(x: p.x, y: p.y - s), controlPoint1: NSPoint(x: p.x + s * 0.12, y: p.y - s * 0.12), controlPoint2: NSPoint(x: p.x + s * 0.12, y: p.y - s * 0.12))
    star.curve(to: NSPoint(x: p.x - s, y: p.y), controlPoint1: NSPoint(x: p.x - s * 0.12, y: p.y - s * 0.12), controlPoint2: NSPoint(x: p.x - s * 0.12, y: p.y - s * 0.12))
    star.curve(to: NSPoint(x: p.x, y: p.y + s), controlPoint1: NSPoint(x: p.x - s * 0.12, y: p.y + s * 0.12), controlPoint2: NSPoint(x: p.x - s * 0.12, y: p.y + s * 0.12))
    accent.blended(withFraction: 0.35, of: .white)!.withAlphaComponent(alpha).setFill()
    star.fill()
}

func draw(scale: CGFloat) {
    // Paper.
    color(0xFAF6F0).setFill()
    NSRect(origin: .zero, size: size).fill()

    // A faint dot grid, like graph paper on a desk.
    color(0x8A7A66, 0.10).setFill()
    var y: CGFloat = 6
    while y < size.height {
        var x: CGFloat = 6
        while x < size.width {
            NSBezierPath(ovalIn: NSRect(x: x - 0.6, y: y - 0.6, width: 1.2, height: 1.2)).fill()
            x += 12
        }
        y += 12
    }

    if let light = glow(scale: scale) {
        NSGraphicsContext.current?.cgContext.draw(light, in: CGRect(origin: .zero, size: size))
    }

    for (p, s, a) in [(NSPoint(x: 112, y: 300), CGFloat(7), CGFloat(0.9)), (NSPoint(x: 336, y: 248), 5, 0.8),
                      (NSPoint(x: 140, y: 196), 4, 0.7), (NSPoint(x: 318, y: 352), 4, 0.6),
                      (NSPoint(x: 92, y: 236), 3, 0.5)] {
        sparkle(at: p, size: s, alpha: a)
    }

    // A trail of hands curving from the app down to the folder: open, open, open, then grabbing.
    let trail: [(NSPoint, CGFloat, Bool)] = [
        (NSPoint(x: 292, y: 352), 0.22, false),
        (NSPoint(x: 312, y: 300), 0.38, false),
        (NSPoint(x: 314, y: 246), 0.58, false),
        (NSPoint(x: 296, y: 196), 1.0, true)
    ]
    for (p, alpha, grabbing) in trail {
        let image = (grabbing ? NSCursor.closedHand : NSCursor.openHand).image
        let s = image.size.width * 1.7
        image.draw(in: NSRect(x: p.x - s / 2, y: p.y - s / 2, width: s, height: s),
                   from: .zero, operation: .sourceOver, fraction: alpha)
    }

    // A friendly line on top and a first-launch hint at the bottom.
    let serif = NSFont.systemFont(ofSize: 19, weight: .semibold).fontDescriptor.withDesign(.serif)!
    centered("Drag me into Applications", y: size.height - 56,
             [.font: NSFont(descriptor: serif, size: 19)!, .foregroundColor: color(0x2B2118)])
    centered("First time? System Settings → Privacy & Security → Open Anyway", y: 30,
             [.font: NSFont.systemFont(ofSize: 10.5), .foregroundColor: color(0x8A7A66)])
}

func bitmap(scale: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(scale: scale)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let tiff = NSBitmapImageRep.tiffRepresentationOfImageReps(in: [bitmap(scale: 1), bitmap(scale: 2)], using: .lzw, factor: 0)!
try! tiff.write(to: URL(fileURLWithPath: output))
print("wrote \(output)")
