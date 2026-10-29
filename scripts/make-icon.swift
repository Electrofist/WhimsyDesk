// Turns square icon art on a plain background into a macOS app icon.
//
// Usage: swift scripts/make-icon.swift <art.png|jpg> <output folder>
// Writes <output folder>/icon.png (1024 x 1024, transparent) and <output folder>/AppIcon.icns.
//
// The background colour is read from the corners and removed by flood fill from the edges,
// so colours inside the icon that match the background are kept. Edges are softened and
// cleaned of background fringe. The icon is placed on Apple's 1024 grid (824 px body,
// 100 px margin) with a soft shadow, like the system icons.
import AppKit

let args = CommandLine.arguments
guard args.count == 3 else { print("usage: make-icon.swift <art> <output folder>"); exit(1) }
let outDir = URL(fileURLWithPath: args[2], isDirectory: true)
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

guard let source = NSImage(contentsOfFile: args[1])?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    print("cannot read \(args[1])"); exit(1)
}
let w = source.width, h = source.height
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.draw(source, in: CGRect(x: 0, y: 0, width: w, height: h))
let px = ctx.data!.assumingMemoryBound(to: UInt8.self)

func rgb(_ i: Int) -> (Double, Double, Double) { (Double(px[i * 4]), Double(px[i * 4 + 1]), Double(px[i * 4 + 2])) }

// Background colour: average of the four 10 x 10 corners.
var bg = (0.0, 0.0, 0.0); var n = 0.0
for (cx, cy) in [(0, 0), (w - 10, 0), (0, h - 10), (w - 10, h - 10)] {
    for y in cy..<cy + 10 { for x in cx..<cx + 10 { let c = rgb(y * w + x); bg.0 += c.0; bg.1 += c.1; bg.2 += c.2; n += 1 } }
}
bg = (bg.0 / n, bg.1 / n, bg.2 / n)
func distance(_ i: Int) -> Double { let c = rgb(i); return ((c.0 - bg.0) * (c.0 - bg.0) + (c.1 - bg.1) * (c.1 - bg.1) + (c.2 - bg.2) * (c.2 - bg.2)).squareRoot() }

// Flood fill the background from the border.
let hard = 38.0
var isBackground = [Bool](repeating: false, count: w * h)
var queue: [Int] = []
for x in 0..<w { queue.append(x); queue.append((h - 1) * w + x) }
for y in 0..<h { queue.append(y * w); queue.append(y * w + w - 1) }
var head = 0
while head < queue.count {
    let i = queue[head]; head += 1
    if isBackground[i] || distance(i) > hard { continue }
    isBackground[i] = true
    let x = i % w, y = i / w
    if x > 0 { queue.append(i - 1) }; if x < w - 1 { queue.append(i + 1) }
    if y > 0 { queue.append(i - w) }; if y < h - 1 { queue.append(i + w) }
}

// Alpha: 0 for background, soft on pixels next to it, 1 elsewhere. Then remove the background fringe.
var alpha = [Double](repeating: 1, count: w * h)
for i in 0..<(w * h) where isBackground[i] { alpha[i] = 0 }
for y in 0..<h { for x in 0..<w {
    let i = y * w + x
    if isBackground[i] { continue }
    var nearBackground = false
    for dy in -2...2 { for dx in -2...2 {
        let nx = x + dx, ny = y + dy
        if nx >= 0, ny >= 0, nx < w, ny < h, isBackground[ny * w + nx] { nearBackground = true }
    } }
    guard nearBackground else { continue }
    let a = min(1, max(0, (distance(i) - 12) / 90))
    alpha[i] = a
} }

// Icons are rounded squares. Light parts of the art that touch the edge (like a glossy
// highlight on a white background) can let the fill leak inside, so everything inside the
// icon's own rounded-square outline, a few pixels in from the edge, is kept solid.
var top = h, bottom = 0, left = w, right = 0
for y in 0..<h { for x in 0..<w where !isBackground[y * w + x] {
    top = min(top, y); bottom = max(bottom, y); left = min(left, x); right = max(right, x)
} }
func firstSolid(row y: Int, fromLeft: Bool) -> Int {
    if fromLeft { for x in left...right where !isBackground[y * w + x] { return x - left } }
    else { for x in stride(from: right, through: left, by: -1) where !isBackground[y * w + x] { return right - x } }
    return 0
}
// For a corner of radius r, the edge 3 px in starts o px in: r - sqrt(r^2 - (r-3)^2) = o.
func radius(offset o: Int) -> Double {
    let o = Double(o), b = 2 * o + 6
    return (b + (b * b - 4 * (o * o + 9)).squareRoot()) / 2
}
let r = [radius(offset: firstSolid(row: top + 3, fromLeft: true)), radius(offset: firstSolid(row: top + 3, fromLeft: false)),
         radius(offset: firstSolid(row: bottom - 3, fromLeft: true)), radius(offset: firstSolid(row: bottom - 3, fromLeft: false))].max()!
let inset = 8.0
let innerR = max(0, r - inset)
let x0 = Double(left) + inset, x1 = Double(right) - inset, y0 = Double(top) + inset, y1 = Double(bottom) - inset
func insideOutline(_ x: Double, _ y: Double) -> Bool {
    guard x >= x0, x <= x1, y >= y0, y <= y1 else { return false }
    let cx = min(max(x, x0 + innerR), x1 - innerR), cy = min(max(y, y0 + innerR), y1 - innerR)
    return (x - cx) * (x - cx) + (y - cy) * (y - cy) <= innerR * innerR
}
var restored = 0
for y in top...bottom { for x in left...right {
    let i = y * w + x
    if alpha[i] < 1 && insideOutline(Double(x), Double(y)) { alpha[i] = 1; restored += 1 }
} }

// If the fill leaked, the art's edge is unreliable, so use a smooth rounded-square outline
// for the whole edge instead (anti-aliased over one pixel).
if restored > 0 {
    let ox0 = Double(left), ox1 = Double(right) + 1, oy0 = Double(top), oy1 = Double(bottom) + 1
    for y in 0..<h { for x in 0..<w {
        let px = Double(x) + 0.5, py = Double(y) + 0.5
        let cx = min(max(px, ox0 + r), ox1 - r), cy = min(max(py, oy0 + r), oy1 - r)
        var outside = ((px - cx) * (px - cx) + (py - cy) * (py - cy)).squareRoot() - r   // > 0 means outside
        if px < ox0 || px > ox1 || py < oy0 || py > oy1 { outside = max(outside, 1) }
        alpha[y * w + x] = min(1, max(0, 0.5 - outside))
    } }
}

// Build a clean straight-alpha RGBA image.
var out = [UInt8](repeating: 0, count: w * h * 4)
var minX = w, minY = h, maxX = 0, maxY = 0
for i in 0..<(w * h) {
    let a = alpha[i]
    guard a > 0.01 else { continue }
    var c = rgb(i)
    if a < 1 {   // un-mix the background from edge pixels
        c = ((c.0 - (1 - a) * bg.0) / a, (c.1 - (1 - a) * bg.1) / a, (c.2 - (1 - a) * bg.2) / a)
    }
    out[i * 4] = UInt8(min(255, max(0, c.0 * a)))
    out[i * 4 + 1] = UInt8(min(255, max(0, c.1 * a)))
    out[i * 4 + 2] = UInt8(min(255, max(0, c.2 * a)))
    out[i * 4 + 3] = UInt8(a * 255)
    let x = i % w, y = i / w
    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
}
let cutCtx = CGContext(data: &out, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
// CGContext rows run bottom-up in drawing space, so the bounding box flips vertically.
let cut = cutCtx.makeImage()!.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1))!

// Place on Apple's icon grid with a soft shadow.
func icon(size: Int) -> CGImage {
    let s = CGFloat(size)
    let c = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.interpolationQuality = .high
    let body = s * 824 / 1024
    let scale = body / CGFloat(max(cut.width, cut.height))
    let iw = CGFloat(cut.width) * scale, ih = CGFloat(cut.height) * scale
    let rect = CGRect(x: (s - iw) / 2, y: (s - ih) / 2 + s * 6 / 1024, width: iw, height: ih)
    c.setShadow(offset: CGSize(width: 0, height: -s * 10 / 1024), blur: s * 22 / 1024,
                color: CGColor(gray: 0, alpha: 0.30))
    c.draw(cut, in: rect)
    return c.makeImage()!
}

func writePNG(_ image: CGImage, _ url: URL) {
    try! NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: url)
}

writePNG(icon(size: 1024), outDir.appendingPathComponent("icon.png"))
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    writePNG(icon(size: base), iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    writePNG(icon(size: base * 2), iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", outDir.appendingPathComponent("AppIcon.icns").path]
try! task.run(); task.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print("background removed: rgb(\(Int(bg.0)), \(Int(bg.1)), \(Int(bg.2))); corner radius \(Int(r)) px; \(restored) pixels kept inside the outline")
print("wrote \(outDir.path)/icon.png and AppIcon.icns")
