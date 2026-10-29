import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: ObjectPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let look = Look.load()
        let store = ObjectStore(folderName: ObjectInfo.folderName)
        let view = ObjectView(store: store, look: look)
        let panel = ObjectPanel(view: view)
        panel.orderFrontRegardless()
        self.panel = panel
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // no Dock icon, no menu bar; right-click the object to quit
app.run()
