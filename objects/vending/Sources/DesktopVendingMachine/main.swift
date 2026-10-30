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

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: VendingPanel?
    private var view: VendingView?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let view = VendingView(store: FileStore())
        let panel = VendingPanel(view: view)
        panel.orderFrontRegardless()
        self.panel = panel
        self.view = view
        view.layoutItems()
        #if DEBUG
        listenForTestCommands()
        #endif
    }

    #if DEBUG
    /// Debug builds only: drive the machine from a script, since clicks cannot reach a window at
    /// desktop level. Commands: store:<path>.
    private func listenForTestCommands() {
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("io.github.electrofist.vending.test"),
                                                            object: nil, queue: .main) { [weak self] note in
            guard let self, let view = self.view, let command = note.object as? String else { return }
            if command.hasPrefix("store:") { view.storeForTest([URL(fileURLWithPath: String(command.dropFirst(6)))]) }
        }
    }
    #endif
}

// Art export for the app icon: DesktopVendingMachine --render-icon out.png
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
