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
        let origin = initialOrigin()
        let fridgePanel = FridgePanel(contentView: fridgeView, origin: origin.point)
        // The panel starts at design size. A saved origin already belongs to the saved size; the default
        // spot is worked out at design size, so grow or shrink around the feet from there.
        fridgeView.setUserScale(fridgeView.userScale, rerender: false, windowScale: 1, keepOrigin: origin.saved)
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
    private func initialOrigin() -> (point: NSPoint, saved: Bool) {
        let scale = view?.userScale ?? CGFloat(max(UserDefaults.standard.double(forKey: "fridgeScale"), 0))
        if let saved = UserDefaults.standard.string(forKey: "windowOrigin") {
            let p = NSPointFromString(saved)
            if bodyIsVisible(windowOrigin: p, scale: scale > 0 ? scale : 1) { return (p, true) }
        }
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return (NSPoint(x: visible.maxX - Geo.bodyOrigin.x - Geo.bodySize.width - 36,
                        y: visible.minY + 24 - Geo.bodyOrigin.y), false)
    }

    private func bodyIsVisible(windowOrigin p: NSPoint, scale: CGFloat) -> Bool {
        let body = NSRect(x: p.x + Geo.bodyOrigin.x * scale, y: p.y + Geo.bodyOrigin.y * scale,
                          width: Geo.bodySize.width * scale, height: Geo.bodySize.height * scale)
        return NSScreen.screens.contains { $0.frame.intersects(body) }
    }

    private func keepOnScreen() {
        guard let panel = panel, let view = view,
              !bodyIsVisible(windowOrigin: panel.frame.origin, scale: view.userScale) else { return }
        let origin = initialOrigin()
        panel.setFrameOrigin(origin.point)
        view.setUserScale(view.userScale, rerender: false, windowScale: 1, keepOrigin: origin.saved)
    }
}
