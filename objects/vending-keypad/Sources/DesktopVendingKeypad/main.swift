import AppKit

/// A borderless, transparent window that sits just above the desktop icons, on every Space.
final class VendingPanel: NSPanel, NSWindowDelegate {
    private static let originKey = "windowOrigin"

    init(view: NSView) {
        let size = view.frame.size
        super.init(contentRect: NSRect(origin: VendingPanel.initialOrigin(for: size), size: size),
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

    /// Only takes the keyboard while a file is selected, so Space can open Quick Look.
    override var canBecomeKey: Bool { (contentView as? VendingView)?.hasSelection ?? false }
    override var canBecomeMain: Bool { false }

    func windowDidMove(_ notification: Notification) {
        UserDefaults.standard.set(NSStringFromPoint(frame.origin), forKey: VendingPanel.originKey)
    }

    /// The saved spot if it is still on a screen, otherwise the lower right of the main screen.
    private static func initialOrigin(for size: CGSize) -> NSPoint {
        if let saved = UserDefaults.standard.string(forKey: originKey) {
            let p = NSPointFromString(saved)
            if NSScreen.screens.contains(where: { $0.frame.intersects(NSRect(origin: p, size: size)) }) { return p }
        }
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(x: visible.maxX - size.width - 180, y: visible.minY + 16)
    }
}

/// Lock, screen sleep and system sleep. Anything moving holds still and carries on afterwards.
final class SystemEvents {
    private var reasons = Set<String>()
    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []
    private weak var view: VendingView?

    init(view: VendingView) {
        self.view = view
        let workspace = NSWorkspace.shared.notificationCenter
        pair(workspace, NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification, reason: "screen")
        pair(workspace, NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification, reason: "system")
        pair(DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsLocked"),
             Notification.Name("com.apple.screenIsUnlocked"), reason: "lock")
    }

    deinit {
        for (center, token) in tokens { center.removeObserver(token) }
    }

    private func pair(_ center: NotificationCenter, _ begin: Notification.Name, _ end: Notification.Name, reason: String) {
        tokens.append((center, center.addObserver(forName: begin, object: nil, queue: .main) { [weak self] _ in
            self?.reasons.insert(reason)
            self?.view?.pause()
        }))
        tokens.append((center, center.addObserver(forName: end, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.reasons.remove(reason)
            if self.reasons.isEmpty { self.view?.resume() }
        }))
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: VendingPanel?
    private var view: VendingView?
    private var events: SystemEvents?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let view = VendingView(store: FileStore())
        let panel = VendingPanel(view: view)
        panel.orderFrontRegardless()
        self.panel = panel
        self.view = view
        view.layoutItems()
        events = SystemEvents(view: view)
        #if DEBUG
        listenForTestCommands()
        #endif
    }

    #if DEBUG
    /// Debug builds only: drive the machine from a script, since clicks cannot reach a window at
    /// desktop level. Commands: store:<path>, key:<label>, hover:<n>, ghosts:<n>, vend:<code>,
    /// select:<n>, putback:<n>, take:<folder>, scale:<n>, slow:<factor>, sounds:<folder>.
    private func listenForTestCommands() {
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("io.github.electrofist.vendingkeypad.test"),
                                                            object: nil, queue: .main) { [weak self] note in
            guard let self, let view = self.view, let command = note.object as? String else { return }
            if command.hasPrefix("store:") { view.storeForTest([URL(fileURLWithPath: String(command.dropFirst(6)))]) }
            if command.hasPrefix("key:") { view.keyForTest(String(command.dropFirst(4))) }
            if command.hasPrefix("hover:") { view.hoverForTest(Int(command.dropFirst(6)) ?? -1) }
            if command.hasPrefix("ghosts:") { view.ghostsForTest(Int(command.dropFirst(7)) ?? 0) }
            if command.hasPrefix("select:") { view.selectForTest(Int(command.dropFirst(7)) ?? 0) }
            if command.hasPrefix("putback:") { view.putBackForTest(Int(command.dropFirst(8)) ?? 0) }
            if command.hasPrefix("take:") { view.takeForTest(to: URL(fileURLWithPath: String(command.dropFirst(5)))) }
            if command.hasPrefix("scale:") { view.scaleForTest(CGFloat(Double(command.dropFirst(6)) ?? 1)) }
            if command.hasPrefix("slow:") { VendingView.slowMotion = Double(command.dropFirst(5)) ?? 1 }
            if command.hasPrefix("vend:") { view.vend(String(command.dropFirst(5))) }
            if command.hasPrefix("sounds:") { Sounds.export(to: URL(fileURLWithPath: String(command.dropFirst(7)))) }
        }
    }
    #endif
}

// Art export for the app icon: DesktopVendingKeypad --render-icon out.png
let args = CommandLine.arguments
if let i = args.firstIndex(of: "--render-icon"), i + 1 < args.count {
    if let image = VendingArt.iconArt(size: 1024) {
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[i + 1]))
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // no Dock icon; right-click the machine to quit
app.run()
