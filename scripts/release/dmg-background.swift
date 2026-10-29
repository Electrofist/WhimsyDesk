// Draws the background of the DMG window: "Drag <App> into Applications" with an arrow
// between where the app icon and the Applications folder sit.
// Usage: swift dmg-background.swift "<Object Name>" "<app file name without .app>" <output.tiff>
// Writes a 1x + 2x TIFF for a 660 x 400 point window. Icons sit at x 165 and 495, y 190 (from the top).
import AppKit

let args = CommandLine.arguments
guard args.count == 4 else { print("usage: dmg-background.swift <name> <app> <out.tiff>"); exit(1) }
let objectName = args[1], appName = args[2], output = args[3]
let size = NSSize(width: 660, height: 400)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func centered(_ text: String, y: CGFloat, font: NSFont, color c: NSColor) {
    let s = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: c])
    s.draw(at: NSPoint(x: (size.width - s.size().width) / 2, y: y))
}

func draw() {
    NSGradient(starting: color(0xF6F0E7), ending: color(0xEADFCF))!
        .draw(in: NSRect(origin: .zero, size: size), angle: -90)

    let serif = NSFont.systemFont(ofSize: 24, weight: .bold).fontDescriptor.withDesign(.serif)!
    centered("Drag \(appName) into Applications", y: 330, font: NSFont(descriptor: serif, size: 24)!, color: color(0x2B2118))

    // Arrow from the app icon (x 165) to Applications (x 495), at icon height (y 190 from top = 210 from bottom).
    let y: CGFloat = 210
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 252, y: y))
    arrow.curve(to: NSPoint(x: 400, y: y), controlPoint1: NSPoint(x: 300, y: y + 26), controlPoint2: NSPoint(x: 352, y: y + 26))
    arrow.lineWidth = 5
    arrow.lineCapStyle = .round
    color(0x9DA716).setStroke()
    arrow.stroke()
    let head = NSBezierPath()
    head.move(to: NSPoint(x: 386, y: y + 16))
    head.line(to: NSPoint(x: 404, y: y))
    head.line(to: NSPoint(x: 384, y: y - 10))
    head.lineWidth = 5
    head.lineCapStyle = .round
    head.lineJoinStyle = .round
    head.stroke()

    let body = NSFont.systemFont(ofSize: 13.5, weight: .regular)
    centered("Then open it from Applications. \(objectName) appears on your desktop, not in the Dock.",
             y: 74, font: body, color: color(0x5E4E3E))
    centered("First time only: if macOS blocks it, open System Settings → Privacy & Security → Open Anyway.",
             y: 50, font: NSFont.systemFont(ofSize: 11.5, weight: .regular), color: color(0x7A6A58))
}

func bitmap(scale: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let tiff = NSBitmapImageRep.tiffRepresentationOfImageReps(in: [bitmap(scale: 1), bitmap(scale: 2)], using: .lzw, factor: 0)!
try! tiff.write(to: URL(fileURLWithPath: output))
print("wrote \(output)")
