import AppKit
import QuartzCore

/// A letter on the desktop. New letters arrive in an envelope that opens: the seal pops, the flap
/// folds back and the letter slides out. Read it, write back, or put it away.
final class LetterWindow: NSPanel, NSTextViewDelegate {
    /// The window is bigger than the paper so the envelope has room to open.
    static let size = CGSize(width: 520, height: 760)
    static let paperSize = CGSize(width: 440, height: 580)
    private static let ink = NSColor(srgbRed: 0.17, green: 0.24, blue: 0.38, alpha: 1)

    var onClose: (() -> Void)?
    let letterID: String
    private let letter: Letter
    private let delivery: Delivery?
    private let post: PostOffice
    private let root = NSView()
    private let paper: PaperView
    private let scroll = NSScrollView()
    private let text = NSTextView()
    private let primary = NSButton()
    private let secondary = NSButton()
    private let discard = NSButton()
    private(set) var replying = false
    private var stage: CALayer?

    private var paperFrame: CGRect {
        CGRect(x: (LetterWindow.size.width - LetterWindow.paperSize.width) / 2, y: 110,
               width: LetterWindow.paperSize.width, height: LetterWindow.paperSize.height)
    }

    init(letter: Letter, post: PostOffice, near anchor: NSRect) {
        self.letter = letter
        self.letterID = letter.id
        self.post = post
        self.delivery = post.inbox.first { $0.id == letter.id }
        paper = PaperView(frame: CGRect(origin: .zero, size: LetterWindow.paperSize), letter: letter,
                          date: delivery?.deliveredAt ?? Date())
        let size = LetterWindow.size
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) }?.visibleFrame
            ?? NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        // Beside the post box if there is room, otherwise in the middle of the screen.
        var origin = CGPoint(x: anchor.maxX - 20, y: anchor.midY - size.height / 2 + 60)
        if origin.x + size.width > screen.maxX { origin.x = anchor.minX - size.width + 20 }
        if origin.x < screen.minX { origin.x = screen.midX - size.width / 2 }
        origin.y = min(max(origin.y, screen.minY - 40), screen.maxY - size.height + 40)

        super.init(contentRect: CGRect(origin: origin, size: size), styleMask: [.borderless],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]

        root.frame = CGRect(origin: .zero, size: size)
        root.wantsLayer = true
        contentView = root
        paper.frame = paperFrame
        paper.wantsLayer = true
        paper.shadow = {
            let s = NSShadow()
            s.shadowColor = NSColor(white: 0, alpha: 0.35)
            s.shadowBlurRadius = 18
            s.shadowOffset = CGSize(width: 0, height: -8)
            return s
        }()
        root.addSubview(paper)
        buildText()
        buildButtons()
        showLetter()
    }

    override var canBecomeKey: Bool { true }

    // MARK: Layout

    private func buildText() {
        let s = LetterWindow.paperSize
        scroll.frame = CGRect(x: 40, y: 82, width: s.width - 80, height: s.height - 82 - 150)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        text.frame = CGRect(origin: .zero, size: scroll.contentSize)
        text.autoresizingMask = [.width]
        text.isVerticallyResizable = true
        text.textContainer?.widthTracksTextView = true
        text.textContainerInset = CGSize(width: 4, height: 6)
        text.drawsBackground = false
        text.isRichText = false
        text.allowsUndo = true
        text.font = Paint.hand(20)
        text.textColor = LetterWindow.ink
        text.insertionPointColor = LetterWindow.ink
        text.delegate = self
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 4
        style.paragraphSpacing = 8
        text.defaultParagraphStyle = style
        text.typingAttributes = [.font: Paint.hand(20), .foregroundColor: LetterWindow.ink, .paragraphStyle: style]
        scroll.documentView = text
        paper.addSubview(scroll)
    }

    private func buildButtons() {
        let s = LetterWindow.paperSize
        for (button, x) in [(secondary, CGFloat(40)), (primary, s.width - 40 - 150)] {
            button.frame = CGRect(x: x, y: 28, width: 150, height: 34)
            button.isBordered = false
            button.bezelStyle = .regularSquare
            button.wantsLayer = true
            button.layer?.cornerRadius = 17
            button.target = self
            paper.addSubview(button)
        }
        discard.frame = CGRect(x: s.width / 2 - 45, y: 2, width: 90, height: 22)
        discard.isBordered = false
        discard.attributedTitle = NSAttributedString(string: "Throw away", attributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor(srgbRed: 0.45, green: 0.4, blue: 0.32, alpha: 0.9),
            .underlineStyle: NSUnderlineStyle.single.rawValue])
        discard.target = self
        discard.action = #selector(throwAway)
        paper.addSubview(discard)
        primary.layer?.backgroundColor = Paint.hex(0x8F2018)
        secondary.layer?.borderWidth = 1.2
        secondary.layer?.borderColor = Paint.hex(0x8F2018, 0.5)
        primary.keyEquivalent = "\r"
        primary.action = #selector(primaryPressed)
        secondary.action = #selector(secondaryPressed)
    }

    private func setTitles(primary p: String, secondary s: String) {
        let font = Paint.serif(15, .semibold)
        primary.attributedTitle = NSAttributedString(string: p, attributes: [.font: font, .foregroundColor: NSColor.white])
        secondary.attributedTitle = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: LetterWindow.ink])
    }

    // MARK: Modes

    private func showLetter() {
        replying = false
        paper.mode = .reading
        var body = letter.body
        if let signoff = letter.signoff, !signoff.isEmpty { body += "\n\n" + signoff }
        text.string = body
        text.isEditable = false
        text.isSelectable = true
        discard.isHidden = false
        let hasReply = post.reply(for: letter.id) != nil
        setTitles(primary: hasReply ? "Your reply" : "Write back", secondary: "Put away")
        text.scrollToBeginningOfDocument(nil)
    }

    func showReply() {
        replying = true
        paper.mode = .replying
        text.isEditable = true
        discard.isHidden = true
        text.string = post.reply(for: letter.id) ?? "\(LetterWindow.greeting(for: letter.from))\n\n"
        setTitles(primary: "Keep reply", secondary: "Never mind")
        makeFirstResponder(text)
        text.setSelectedRange(NSRange(location: (text.string as NSString).length, length: 0))
        text.scrollToEndOfDocument(nil)
        Sounds.play(.rustle, volume: 0.3)
    }

    /// "Dear Sam," for a name, "Hello," for a description like "A friend who likes slow films".
    static func greeting(for from: String) -> String {
        let words = from.split(separator: " ")
        let described = ["a", "an", "the", "someone", "your"].contains(words.first?.lowercased() ?? "")
        return words.count <= 3 && !described ? "Dear \(from)," : "Hello,"
    }

    /// Saves the reply, unless nothing was written past the greeting.
    private func keepReply() {
        let written = text.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !written.isEmpty, written != LetterWindow.greeting(for: letter.from) else { return }
        post.saveReply(text.string, for: letter.id)
    }

    @objc private func primaryPressed() {
        if replying {
            keepReply()
            Sounds.play(.rustle, volume: 0.3)
            showLetter()
        } else {
            showReply()
        }
    }

    /// Removes the letter from the mailbox for good.
    @objc private func throwAway() {
        post.throwAway(letter.id)
        putAway()
    }

    @objc private func secondaryPressed() {
        if replying { showLetter() } else { putAway() }
    }

    override func cancelOperation(_ sender: Any?) {
        if replying { showLetter() } else { putAway() }
    }

    // MARK: Showing and hiding

    /// Shows the letter. A new letter arrives in its envelope; `source` is where it starts on screen.
    func present(inEnvelope: Bool, from source: NSRect?) {
        NSApp.activate(ignoringOtherApps: true)
        if !inEnvelope || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            alphaValue = 0
            makeKeyAndOrderFront(nil)
            Sounds.play(.rustle, volume: 0.5)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                animator().alphaValue = 1
            }
            return
        }
        paper.layoutSubtreeIfNeeded()
        let snapshot = snapshotPaper()
        paper.alphaValue = 0
        makeKeyAndOrderFront(nil)
        playEnvelope(snapshot: snapshot, from: source)
    }

    private func snapshotPaper() -> CGImage? {
        guard let rep = paper.bitmapImageRepForCachingDisplay(in: paper.bounds) else { return nil }
        paper.cacheDisplay(in: paper.bounds, to: rep)
        return rep.cgImage
    }

    private func playEnvelope(snapshot: CGImage?, from source: NSRect?) {
        guard let rootLayer = root.layer else { return }
        let kind = letter.kind
        let scale = backingScaleFactor
        let env = MailboxArt.bigEnvelope
        let w = LetterWindow.size.width
        let envRect = CGRect(x: (w - env.width) / 2, y: 40, width: env.width, height: env.height)
        let flapH = MailboxArt.flapHeight
        let none: [String: CAAction] = ["position": NSNull(), "bounds": NSNull(), "transform": NSNull(),
                                        "opacity": NSNull(), "sublayers": NSNull(), "zPosition": NSNull()]

        let stage = CALayer()
        stage.frame = root.bounds
        stage.actions = none
        var p = CATransform3DIdentity
        p.m34 = -1 / 900
        stage.sublayerTransform = p
        rootLayer.addSublayer(stage)
        self.stage = stage

        func layer(_ image: CGImage?, _ frame: CGRect) -> CALayer {
            let l = CALayer()
            l.actions = none
            l.contents = image
            l.contentsScale = scale
            l.frame = frame
            return l
        }

        let back = layer(MailboxArt.envelopeBack(kind: kind, scale: scale), envRect)
        let clip = CALayer()
        clip.actions = none
        clip.frame = CGRect(x: 0, y: envRect.minY + 8, width: w, height: LetterWindow.size.height - envRect.minY - 8)
        clip.masksToBounds = true
        let inScale: CGFloat = 0.78
        let small = CGSize(width: LetterWindow.paperSize.width * inScale, height: LetterWindow.paperSize.height * inScale)
        let letterLayer = layer(snapshot, CGRect(origin: .zero, size: LetterWindow.paperSize))
        letterLayer.shadowOpacity = 0.25
        letterLayer.shadowRadius = 8
        letterLayer.shadowOffset = CGSize(width: 0, height: -4)
        letterLayer.transform = CATransform3DMakeScale(inScale, inScale, 1)
        // Tucked in, its top just under the edge of the envelope (in clip coordinates).
        let tucked = CGPoint(x: w / 2, y: envRect.maxY - 18 - small.height / 2 - clip.frame.minY)
        letterLayer.position = tucked
        clip.addSublayer(letterLayer)

        let pocket = layer(MailboxArt.envelopePocket(kind: kind, scale: scale),
                           CGRect(x: envRect.minX, y: envRect.minY - 20, width: env.width, height: env.height + 20))
        let flap = CATransformLayer()
        flap.actions = none
        flap.bounds = CGRect(x: 0, y: 0, width: env.width, height: flapH)
        flap.anchorPoint = CGPoint(x: 0.5, y: 1)
        flap.position = CGPoint(x: envRect.midX, y: envRect.maxY)
        let flapFront = layer(MailboxArt.flapFront(kind: kind, scale: scale), flap.bounds)
        flapFront.isDoubleSided = false
        let flapBack = layer(MailboxArt.flapBack(kind: kind, scale: scale), flap.bounds)
        flapBack.isDoubleSided = false
        flapBack.transform = CATransform3DMakeRotation(.pi, 1, 0, 0)
        flap.addSublayer(flapFront)
        flap.addSublayer(flapBack)
        let seal = layer(MailboxArt.seal(scale: scale), CGRect(x: envRect.midX - 27, y: envRect.maxY - flapH - 10, width: 54, height: 54))

        let envelope = CALayer()
        envelope.actions = none
        envelope.frame = stage.bounds
        envelope.sublayerTransform = p
        for l in [back, clip, pocket, flap, seal] as [CALayer] { envelope.addSublayer(l) }
        stage.addSublayer(envelope)

        let t0 = CACurrentMediaTime()
        func animate(_ l: CALayer, _ key: String, from: Any?, to: Any?, at: Double, for d: Double,
                     _ timing: CAMediaTimingFunctionName = .easeInEaseOut) {
            let a = CABasicAnimation(keyPath: key)
            a.fromValue = from
            a.toValue = to
            a.beginTime = t0 + at
            a.duration = d
            a.timingFunction = CAMediaTimingFunction(name: timing)
            a.fillMode = .both
            a.isRemovedOnCompletion = false
            l.add(a, forKey: key + "\(at)")
        }

        // 1. The envelope comes out of the slot toward you.
        if let source {
            let local = convertFromScreen(source)
            let start = CGPoint(x: local.midX, y: local.midY)
            let k = max(0.08, source.width / env.width)
            var from = CATransform3DMakeTranslation(start.x - envRect.midX, start.y - envRect.midY, 0)
            from = CATransform3DScale(from, k, k, 1)
            from = CATransform3DRotate(from, 0.3, 0, 0, 1)
            animate(envelope, "transform", from: NSValue(caTransform3D: from), to: NSValue(caTransform3D: CATransform3DIdentity),
                    at: 0, for: 0.45, .easeOut)
            animate(envelope, "opacity", from: 0, to: 1, at: 0, for: 0.15)
        } else {
            animate(envelope, "transform", from: NSValue(caTransform3D: CATransform3DMakeTranslation(0, -30, 0)),
                    to: NSValue(caTransform3D: CATransform3DIdentity), at: 0, for: 0.35, .easeOut)
            animate(envelope, "opacity", from: 0, to: 1, at: 0, for: 0.25)
        }
        Sounds.play(.rustle, volume: 0.35)

        // 2. The seal pops.
        animate(seal, "transform", from: NSValue(caTransform3D: CATransform3DIdentity),
                to: NSValue(caTransform3D: CATransform3DMakeScale(1.25, 1.25, 1)), at: 0.55, for: 0.08, .easeOut)
        animate(seal, "opacity", from: 1, to: 0, at: 0.6, for: 0.12)
        after(0.55) { Sounds.play(.seal, volume: 0.8) }

        // 3. The flap folds back. Halfway, it moves behind the letter.
        animate(flap, "transform", from: NSValue(caTransform3D: CATransform3DIdentity),
                to: NSValue(caTransform3D: CATransform3DMakeRotation(-.pi, 1, 0, 0)), at: 0.7, for: 0.5)
        after(0.7) { Sounds.play(.rustle, volume: 0.4) }
        after(0.95) { envelope.insertSublayer(flap, below: clip) }

        // 4. The letter slides out.
        let out = CGPoint(x: tucked.x, y: envRect.maxY + 14 + small.height / 2 - clip.frame.minY)
        animate(letterLayer, "position", from: NSValue(point: tucked), to: NSValue(point: out), at: 1.2, for: 0.5)
        after(1.2) { Sounds.play(.rustle, volume: 0.5) }

        // 5. The envelope drops away and the letter opens up to full size.
        after(1.72) { [weak self] in
            guard let self else { return }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            let world = clip.convert(letterLayer.presentation()?.position ?? out, to: stage)
            letterLayer.removeAllAnimations()
            letterLayer.removeFromSuperlayer()
            letterLayer.position = world
            stage.addSublayer(letterLayer)
            CATransaction.commit()
            let t = CACurrentMediaTime()
            for (l, key, from, to) in [(envelope, "position.y", envelope.position.y, envelope.position.y - 120),
                                       (envelope, "opacity", 1, 0)] as [(CALayer, String, Any, Any)] {
                let a = CABasicAnimation(keyPath: key)
                a.fromValue = from; a.toValue = to; a.duration = 0.35; a.beginTime = t
                a.timingFunction = CAMediaTimingFunction(name: .easeIn)
                a.fillMode = .both; a.isRemovedOnCompletion = false
                l.add(a, forKey: key)
            }
            let final = CGPoint(x: self.paperFrame.midX, y: self.paperFrame.midY)
            let grow = CABasicAnimation(keyPath: "transform")
            grow.fromValue = NSValue(caTransform3D: letterLayer.transform)
            grow.toValue = NSValue(caTransform3D: CATransform3DIdentity)
            let move = CABasicAnimation(keyPath: "position")
            move.fromValue = NSValue(point: world)
            move.toValue = NSValue(point: final)
            let group = CAAnimationGroup()
            group.animations = [grow, move]
            group.duration = 0.42
            group.beginTime = t + 0.08
            group.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
            group.fillMode = .both
            group.isRemovedOnCompletion = false
            letterLayer.add(group, forKey: "open")
        }
        after(2.25) { [weak self] in
            self?.paper.alphaValue = 1
            self?.stage?.removeFromSuperlayer()
            self?.stage = nil
        }
    }

    private func after(_ seconds: Double, _ work: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func putAway() {
        if replying { keepReply() }
        Sounds.play(.rustle, volume: 0.3)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            animator().alphaValue = 0
            animator().setFrame(frame.offsetBy(dx: 0, dy: -10), display: true)
        }, completionHandler: { [weak self] in
            self?.orderOut(nil)
            self?.onClose?()
        })
    }
}

/// The paper: cream stock folded in thirds, a stamp, a postmark and the sender.
final class PaperView: NSView {
    enum Mode { case reading, replying }
    var mode = Mode.reading { didSet { needsDisplay = true } }

    private let letter: Letter
    private let date: Date
    private var stamp: CGImage?

    init(frame: CGRect, letter: Letter, date: Date) {
        self.letter = letter
        self.date = date
        super.init(frame: frame)
        stamp = MailboxArt.stamp(kind: letter.kind, scale: 2)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var mouseDownCanMoveWindow: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let r = bounds.insetBy(dx: 2, dy: 2)
        let sheet = CGPath(roundedRect: r, cornerWidth: 4, cornerHeight: 4, transform: nil)
        let tint: UInt32 = mode == .replying ? 0xFBF8EE : 0xFAF3E2
        Paint.fill(ctx, sheet, Paint.gradient([(0, Paint.hex(tint)), (1, Paint.hex(0xF1E6CC))]),
                   from: CGPoint(x: r.minX, y: r.maxY), to: CGPoint(x: r.maxX, y: r.minY))
        // Folded in thirds.
        for y in [r.height / 3, r.height * 2 / 3] {
            let line = CGMutablePath()
            line.move(to: CGPoint(x: r.minX, y: r.minY + y)); line.addLine(to: CGPoint(x: r.maxX, y: r.minY + y))
            Paint.stroke(ctx, line, Paint.hex(0x8A7A5A, 0.16), 1)
            let light = CGMutablePath()
            light.move(to: CGPoint(x: r.minX, y: r.minY + y - 1)); light.addLine(to: CGPoint(x: r.maxX, y: r.minY + y - 1))
            Paint.stroke(ctx, light, Paint.hex(0xFFFFFF, 0.5), 1)
        }
        Paint.stroke(ctx, sheet, Paint.hex(0x8A7A5A, 0.25), 1)

        let ink = NSColor(srgbRed: 0.17, green: 0.24, blue: 0.38, alpha: 1)
        let muted = NSColor(srgbRed: 0.45, green: 0.4, blue: 0.32, alpha: 1)
        if mode == .reading {
            let stampRect = CGRect(x: r.maxX - 92, y: r.maxY - 108, width: 74, height: 88)
            if let stamp { ctx.draw(stamp, in: stampRect) }
            drawPostmark(ctx, center: CGPoint(x: stampRect.minX - 4, y: stampRect.minY + 6))
            Paint.text(ctx, "From", at: CGPoint(x: r.minX + 42, y: r.maxY - 52), font: Paint.serif(12, .semibold),
                       color: muted, kern: 1.5)
            // Shrink a long name so it stays clear of the stamp.
            var size: CGFloat = 24
            let room = stampRect.minX - 44 - (r.minX + 42)
            while size > 15 && (letter.from as NSString).size(withAttributes: [.font: Paint.hand(size)]).width > room { size -= 1 }
            Paint.text(ctx, letter.from, at: CGPoint(x: r.minX + 42, y: r.maxY - 84), font: Paint.hand(size), color: ink)
            if let title = letter.title, !title.isEmpty {
                Paint.text(ctx, title, at: CGPoint(x: r.minX + 42, y: r.maxY - 128), font: Paint.serif(17, .bold), color: ink)
            }
        } else {
            Paint.text(ctx, "Your reply to \(letter.from)", at: CGPoint(x: r.minX + 42, y: r.maxY - 60),
                       font: Paint.serif(14, .semibold), color: muted)
            Paint.text(ctx, "Kept on this Mac. Nothing is sent.", at: CGPoint(x: r.minX + 42, y: r.maxY - 80),
                       font: NSFont.systemFont(ofSize: 11), color: muted.withAlphaComponent(0.8))
        }
    }

    private func drawPostmark(_ ctx: CGContext, center c: CGPoint) {
        let ink = Paint.hex(0x3A3F4A, 0.5)
        ctx.saveGState()
        ctx.translateBy(x: c.x, y: c.y)
        ctx.rotate(by: -0.18)
        Paint.stroke(ctx, CGPath(ellipseIn: CGRect(x: -32, y: -32, width: 64, height: 64), transform: nil), ink, 1.6)
        Paint.stroke(ctx, CGPath(ellipseIn: CGRect(x: -26, y: -26, width: 52, height: 52), transform: nil), ink, 0.8)
        let f = DateFormatter()
        f.dateFormat = "d MMM"
        let color = NSColor(srgbRed: 0.23, green: 0.25, blue: 0.29, alpha: 0.6)
        Paint.text(ctx, "MAILBOX", at: CGPoint(x: 0, y: 8), font: NSFont.systemFont(ofSize: 7, weight: .bold),
                   color: color, kern: 1, centered: true)
        Paint.text(ctx, f.string(from: date).uppercased(), at: CGPoint(x: 0, y: -6), font: NSFont.systemFont(ofSize: 10, weight: .heavy),
                   color: color, centered: true)
        f.dateFormat = "yyyy"
        Paint.text(ctx, f.string(from: date), at: CGPoint(x: 0, y: -17), font: NSFont.systemFont(ofSize: 7, weight: .bold),
                   color: color, centered: true)
        // Wavy cancellation lines to the right, across the stamp.
        for i in 0..<4 {
            let y = CGFloat(i - 2) * 7 + 3
            let wave = CGMutablePath()
            wave.move(to: CGPoint(x: 36, y: y))
            var x: CGFloat = 36
            while x < 110 {
                wave.addQuadCurve(to: CGPoint(x: x + 10, y: y), control: CGPoint(x: x + 5, y: y + (Int(x) % 20 < 10 ? 3 : -3)))
                x += 10
            }
            Paint.stroke(ctx, wave, ink, 1.2)
        }
        ctx.restoreGState()
    }
}
