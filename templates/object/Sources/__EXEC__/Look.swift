import AppKit

/// The object's art and layout. Art comes from Art/closed.png and Art/open.png; layout comes from
/// the "look" section of object.json. Both are copied into the app by build.sh.
struct Look {
    let closed: NSImage
    let open: NSImage
    /// Where stored files appear when the object is open, as fractions of the object's size,
    /// measured from the bottom left: x, y, width, height.
    let itemsArea: CGRect
    /// File icon size in points.
    let iconSize: CGFloat

    var size: CGSize { closed.size }

    static func load() -> Look {
        let closed = image(named: "closed") ?? placeholder()
        let open = image(named: "open") ?? closed
        open.size = closed.size

        var area = CGRect(x: 0.12, y: 0.12, width: 0.76, height: 0.74)
        var icon: CGFloat = 48
        if let url = Bundle.main.url(forResource: "object", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let look = json["look"] as? [String: Any] {
            if let a = look["itemsArea"] as? [Double], a.count == 4 {
                area = CGRect(x: a[0], y: a[1], width: a[2], height: a[3])
            }
            if let s = look["iconSize"] as? Double {
                icon = CGFloat(min(max(s, 24), 128))
            }
        }
        // Keep the area inside the object whatever the JSON says.
        area = area.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        if area.isNull || area.isEmpty { area = CGRect(x: 0.12, y: 0.12, width: 0.76, height: 0.74) }

        return Look(closed: closed, open: open, itemsArea: area, iconSize: icon)
    }

    /// Art is drawn at 2x: a 560 x 480 px PNG shows as 280 x 240 points on screen.
    private static func image(named name: String) -> NSImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
              let image = NSImage(contentsOf: url),
              let rep = image.representations.first,
              rep.pixelsWide > 0, rep.pixelsHigh > 0 else { return nil }
        image.size = NSSize(width: CGFloat(rep.pixelsWide) / 2, height: CGFloat(rep.pixelsHigh) / 2)
        return image
    }

    /// Used only if the art is missing, so the app still starts.
    private static func placeholder() -> NSImage {
        NSImage(size: NSSize(width: 240, height: 200), flipped: false) { rect in
            NSColor.systemBrown.setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 4, dy: 4), xRadius: 18, yRadius: 18).fill()
            return true
        }
    }
}
