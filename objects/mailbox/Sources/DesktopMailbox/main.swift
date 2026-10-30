import AppKit

/// A borderless, transparent window that sits just above the desktop icons, on every Space.
final class MailboxPanel: NSPanel, NSWindowDelegate {
    private static let originKey = "windowOrigin"

    init(view: NSView) {
        let size = view.frame.size
        super.init(contentRect: NSRect(origin: MailboxPanel.initialOrigin(for: size), size: size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovableByWindowBackground = false     // Option-Command-drag moves it
        contentView = view
        delegate = self
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func windowDidMove(_ notification: Notification) {
        UserDefaults.standard.set(NSStringFromPoint(frame.origin), forKey: MailboxPanel.originKey)
    }

    /// The saved spot if it is still on a screen, otherwise the lower right of the main screen.
    private static func initialOrigin(for size: CGSize) -> NSPoint {
        if let saved = UserDefaults.standard.string(forKey: originKey) {
            let p = NSPointFromString(saved)
            if NSScreen.screens.contains(where: { $0.frame.intersects(NSRect(origin: p, size: size)) }) { return p }
        }
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(x: visible.maxX - size.width - 140, y: visible.minY + 16)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, MailboxViewDelegate {
    private var panel: MailboxPanel?
    private var view: MailboxView?
    private var post: PostOffice?
    private var letterWindow: LetterWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let store = FileStore()
        let post = PostOffice()
        let view = MailboxView(store: store, post: post)
        view.delegate = self
        post.onDelivery = { [weak view] _ in view?.mailArrived() }
        let panel = MailboxPanel(view: view)
        panel.orderFrontRegardless()
        self.panel = panel
        self.view = view
        self.post = post
        post.start()
        view.layoutItems()
        view.updateFlag()
        #if DEBUG
        listenForTestCommands()
        #endif
    }

    #if DEBUG
    /// Debug builds only: drive the mailbox from a script without clicking.
    /// Commands: toggle, deliver, read:<id>, reply:<id>, close-letter.
    private func listenForTestCommands() {
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("io.github.electrofist.mailbox.test"),
                                                            object: nil, queue: .main) { [weak self] note in
            guard let self, let command = note.object as? String else { return }
            switch command {
            case "toggle": self.view?.toggleDoor()
            case "deliver": self.post?.deliverNow()
            case "close-letter": self.letterWindow?.putAway()
            default:
                if command.hasPrefix("sounds:") { Sounds.export(to: URL(fileURLWithPath: String(command.dropFirst(7)))) }
                if command.hasPrefix("read:") { self.openLetter(String(command.dropFirst(5)), replying: false) }
                if command.hasPrefix("reply:") { self.openLetter(String(command.dropFirst(6)), replying: true) }
            }
        }
    }
    #endif

    func openLetter(_ id: String, replying: Bool) {
        guard let post, let letter = post.letter(id), let panel else { return }
        if let open = letterWindow, open.letterID == id {
            if replying && !open.replying { open.showReply() }
            open.makeKeyAndOrderFront(nil)
            return
        }
        letterWindow?.orderOut(nil)
        let window = LetterWindow(letter: letter, post: post, near: panel.frame)
        window.onClose = { [weak self, weak window] in
            if self?.letterWindow === window { self?.letterWindow = nil }
            self?.view?.layoutItems()
        }
        letterWindow = window
        if replying { window.showReply() }
        window.present()
        post.markRead(id)
        view?.layoutItems()
        view?.updateFlag()
    }

    func showReplies() {
        NSWorkspace.shared.open(PostOffice.repliesFolder)
    }
}

// Art export for the app icon and screenshots: DesktopMailbox --render-icon out.png
let args = CommandLine.arguments
if let i = args.firstIndex(of: "--render-icon"), i + 1 < args.count {
    if let image = MailboxArt.iconArt(size: 1024) {
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[i + 1]))
    }
    exit(0)
}
if let i = args.firstIndex(of: "--render-closed"), i + 1 < args.count {
    if let image = MailboxArt.closedComposite(scale: 2, flagUp: true) {
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[i + 1]))
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // no Dock icon; right-click the mailbox to quit
app.run()
