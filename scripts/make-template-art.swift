// Draws the placeholder art for templates/object: a wooden crate, closed and open.
// Usage: swift scripts/make-template-art.swift templates/object/Art
// Output: closed.png and open.png, 560 x 480 px (280 x 240 points at 2x).
import AppKit

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let size = NSSize(width: 560, height: 480)
let box = NSRect(x: 40, y: 30, width: 480, height: 410)    // the crate
let frameWidth: CGFloat = 28                                  // its border when open

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func render(_ name: String, _ draw: () -> Void) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: outDir.appendingPathComponent("\(name).png"))
    print("wrote \(name).png")
}

func shadow() {
    let s = NSShadow()
    s.shadowColor = color(0x000000, 0.35)
    s.shadowBlurRadius = 18
    s.shadowOffset = NSSize(width: 0, height: -8)
    NSGraphicsContext.saveGraphicsState()
    s.set()
    color(0x8A5A2B).setFill()
    NSBezierPath(roundedRect: box, xRadius: 14, yRadius: 14).fill()
    NSGraphicsContext.restoreGraphicsState()
}

func wood(_ rect: NSRect, light: UInt32, dark: UInt32, radius: CGFloat = 10) {
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    NSGradient(starting: color(light), ending: color(dark))!.draw(in: path, angle: -90)
    // A few grain lines.
    color(0x5C3A1A, 0.18).setStroke()
    for i in 1...3 {
        let y = rect.minY + rect.height * CGFloat(i) / 4 + CGFloat(i % 2) * 3
        let grain = NSBezierPath()
        grain.move(to: NSPoint(x: rect.minX + 14, y: y))
        grain.curve(to: NSPoint(x: rect.maxX - 14, y: y + 2),
                    controlPoint1: NSPoint(x: rect.midX - 60, y: y + 5),
                    controlPoint2: NSPoint(x: rect.midX + 60, y: y - 4))
        grain.lineWidth = 1.5
        grain.stroke()
    }
}

func caption(_ text: String, at point: NSPoint) {
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 18, weight: .semibold),
        .foregroundColor: color(0x3B2410, 0.55)
    ]
    let s = NSAttributedString(string: text, attributes: attrs)
    s.draw(at: NSPoint(x: point.x - s.size().width / 2, y: point.y))
}

func screws() {
    color(0x3B2410, 0.55).setFill()
    for p in [NSPoint(x: box.minX + 16, y: box.minY + 16), NSPoint(x: box.maxX - 16, y: box.minY + 16),
              NSPoint(x: box.minX + 16, y: box.maxY - 16), NSPoint(x: box.maxX - 16, y: box.maxY - 16)] {
        NSBezierPath(ovalIn: NSRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)).fill()
    }
}

// Closed: three planks across the front and a rope handle.
render("closed") {
    shadow()
    let plankHeight = (box.height - 8) / 3
    for i in 0..<3 {
        let plank = NSRect(x: box.minX, y: box.minY + CGFloat(i) * (plankHeight + 4), width: box.width, height: plankHeight)
        wood(plank, light: i % 2 == 0 ? 0xD9A866 : 0xD2A060, dark: 0xB07A3E)
    }
    screws()
    let handle = NSBezierPath()
    handle.move(to: NSPoint(x: box.midX - 50, y: box.maxY - 70))
    handle.curve(to: NSPoint(x: box.midX + 50, y: box.maxY - 70),
                 controlPoint1: NSPoint(x: box.midX - 40, y: box.maxY - 110),
                 controlPoint2: NSPoint(x: box.midX + 40, y: box.maxY - 110))
    handle.lineWidth = 10
    handle.lineCapStyle = .round
    color(0x6B4A2A).setStroke()
    handle.stroke()
    caption("closed.png: replace me", at: NSPoint(x: box.midX, y: box.minY + 40))
}

// Open: the frame stays, the front is gone, and a light back wall shows where files sit.
render("open") {
    shadow()
    wood(box, light: 0xD9A866, dark: 0xB07A3E, radius: 14)
    let inside = box.insetBy(dx: frameWidth, dy: frameWidth)
    let wall = NSBezierPath(roundedRect: inside, xRadius: 6, yRadius: 6)
    NSGradient(starting: color(0xF3E3C8), ending: color(0xE6CDA6))!.draw(in: wall, angle: -90)
    // Soft inner shadow along the top, so it reads as a hollow.
    NSGradient(starting: color(0x5C3A1A, 0.28), ending: color(0x5C3A1A, 0))!
        .draw(in: NSRect(x: inside.minX, y: inside.maxY - 34, width: inside.width, height: 34), angle: -90)
    screws()
    caption("open.png", at: NSPoint(x: box.midX, y: inside.minY + 10))
}
