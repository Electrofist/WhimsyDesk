import AppKit

/// The little green screen, drawn as fourteen-segment characters. Unlit segments show faintly,
/// like on the real thing. Redrawn only when the text changes.
enum Segments {
    static let columns = 15

    // Segment ends inside a character cell, from the corners, edge middles and centre.
    private enum P { case tl, tc, tr, ml, c, mr, bl, bc, br }
    private static let segments: [Character: (P, P)] = [
        "a": (.tl, .tr), "b": (.tr, .mr), "c": (.mr, .br), "d": (.bl, .br), "e": (.ml, .bl), "f": (.tl, .ml),
        "g": (.ml, .c), "G": (.c, .mr), "h": (.tl, .c), "i": (.tc, .c), "j": (.tr, .c), "k": (.bl, .c),
        "l": (.c, .bc), "m": (.br, .c),
    ]

    /// Which segments light for each character (keys of `segments`).
    private static let font: [Character: String] = [
        "0": "abcdefjk", "1": "bc", "2": "abdegG", "3": "abcdG", "4": "bcfgG", "5": "acdfgG", "6": "acdefgG",
        "7": "abc", "8": "abcdefgG", "9": "abcdfgG",
        "A": "abcefgG", "B": "abcdGil", "C": "adef", "D": "abcdil", "E": "adefg", "F": "aefg", "G": "acdefG",
        "H": "bcefgG", "I": "adil", "J": "bcde", "K": "efgjm", "L": "def", "M": "bcefhj", "N": "bcefhm",
        "O": "abcdef", "P": "abefgG", "Q": "abcdefm", "R": "abefgGm", "S": "acdfgG", "T": "ail", "U": "bcdef",
        "V": "efkj", "W": "bcefkm", "X": "hjkm", "Y": "hjl", "Z": "adjk",
        "-": "gG", "_": "d", "/": "jk", "'": "i", "+": "gGil", "*": "gGhjkm", "?": "abGl", "=": "dgG",
    ]

    /// Upper case, plain letters only; anything the display cannot show becomes a space.
    static func clean(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).uppercased()
        return String(folded.map { font[$0] != nil ? $0 : " " })
    }

    /// One centred line of green characters. Longer text is cut to fit.
    static func render(_ line: String, scale: CGFloat) -> CGImage? {
        let size = Geo.display.size
        return Paint.render(size, scale: scale) { ctx in
            let r = CGRect(origin: .zero, size: size)
            ctx.addPath(Paint.rounded(r, 5)); ctx.clip()
            Paint.fill(ctx, CGPath(rect: r, transform: nil), Paint.gradient([(0, Paint.hex(0x14261A)), (1, Paint.hex(0x0B160E))]),
                       from: CGPoint(x: 0, y: size.height), to: .zero)
            let cell = CGSize(width: 5.2, height: 10.5)
            let advance: CGFloat = 7.9
            let left = (size.width - advance * CGFloat(columns - 1) - cell.width) / 2
            let y = (size.height - cell.height) / 2
            var text = Array(clean(line).trimmingCharacters(in: .whitespaces))
            if text.count > columns { text = Array(text.prefix(columns - 1)) + ["-"] }
            let pad = (columns - text.count) / 2
            let lit = Paint.hex(0x8DFFA6)
            ctx.setLineCap(.round)
            for col in 0..<columns {
                let origin = CGPoint(x: left + CGFloat(col) * advance, y: y)
                let n = col - pad
                let on = n >= 0 && n < text.count ? (font[text[n]] ?? "") : ""
                for (name, ends) in segments {
                    let path = segment(ends, origin: origin, cell: cell)
                    if on.contains(name) {
                        ctx.saveGState()
                        ctx.setShadow(offset: .zero, blur: 3, color: Paint.hex(0x3DFF73, 0.8))
                        Paint.stroke(ctx, path, lit, 1.15)
                        ctx.restoreGState()
                    } else {
                        Paint.stroke(ctx, path, Paint.hex(0x8DFFA6, 0.06), 1.15)
                    }
                }
            }
            // A faint reflection on the screen.
            Paint.fill(ctx, CGPath(rect: CGRect(x: 0, y: size.height * 0.55, width: size.width, height: size.height * 0.45), transform: nil),
                       Paint.hex(0xFFFFFF, 0.04))
        }
    }

    private static func segment(_ ends: (P, P), origin: CGPoint, cell: CGSize) -> CGPath {
        func point(_ p: P) -> CGPoint {
            let x: CGFloat, y: CGFloat
            switch p {
            case .tl: (x, y) = (0, 1)
            case .tc: (x, y) = (0.5, 1)
            case .tr: (x, y) = (1, 1)
            case .ml: (x, y) = (0, 0.5)
            case .c: (x, y) = (0.5, 0.5)
            case .mr: (x, y) = (1, 0.5)
            case .bl: (x, y) = (0, 0)
            case .bc: (x, y) = (0.5, 0)
            case .br: (x, y) = (1, 0)
            }
            // A slight forward lean, like a real segment display.
            return CGPoint(x: origin.x + x * cell.width + y * cell.height * 0.12, y: origin.y + y * cell.height)
        }
        var a = point(ends.0), b = point(ends.1)
        // Leave a small gap where segments meet.
        let dx = b.x - a.x, dy = b.y - a.y, len = max(0.001, hypot(dx, dy)), gap: CGFloat = 0.9
        a = CGPoint(x: a.x + dx / len * gap, y: a.y + dy / len * gap)
        b = CGPoint(x: b.x - dx / len * gap, y: b.y - dy / len * gap)
        let path = CGMutablePath()
        path.move(to: a)
        path.addLine(to: b)
        return path
    }
}
