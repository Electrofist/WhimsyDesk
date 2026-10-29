import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: DrawerController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = DrawerController(store: DrawerStore())
        controller?.show()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // no Dock icon, no menu bar
app.run()
