import AppKit
import FridgeCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: FridgePanel?
    private var view: FridgeView?
    private var events: SystemEvents?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)   // no Dock icon, no menu bar; right-click the fridge to quit

        let store: FridgeStore
        do {
            // FRIDGE_ROOT points the app at a scratch folder, for development and screenshots.
            if let path = ProcessInfo.processInfo.environment["FRIDGE_ROOT"] {
                store = try FridgeStore(root: URL(fileURLWithPath: path, isDirectory: true))
            } else {
                store = try FridgeStore()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Desktop Fridge could not create ~/Fridge"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        let fridgeView = FridgeView(store: store)
        let fridgePanel = FridgePanel(contentView: fridgeView, origin: initialOrigin())
        fridgePanel.orderFrontRegardless()

        view = fridgeView
        panel = fridgePanel
        events = SystemEvents(view: fridgeView)

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.keepOnScreen()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    // MARK: Placement

    /// Last saved position, or the lower right of the main screen with the feet near the Dock.
    private func initialOrigin() -> NSPoint {
        if let saved = UserDefaults.standard.string(forKey: "windowOrigin") {
            let p = NSPointFromString(saved)
            if bodyIsVisible(windowOrigin: p) { return p }
        }
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(x: visible.maxX - Geo.bodyOrigin.x - Geo.bodySize.width - 36,
                       y: visible.minY + 24 - Geo.bodyOrigin.y)
    }

    private func bodyIsVisible(windowOrigin p: NSPoint) -> Bool {
        let body = NSRect(x: p.x + Geo.bodyOrigin.x, y: p.y + Geo.bodyOrigin.y,
                          width: Geo.bodySize.width, height: Geo.bodySize.height)
        return NSScreen.screens.contains { $0.frame.intersects(body) }
    }

    private func keepOnScreen() {
        guard let panel = panel, !bodyIsVisible(windowOrigin: panel.frame.origin) else { return }
        panel.setFrameOrigin(initialOrigin())
    }
}
