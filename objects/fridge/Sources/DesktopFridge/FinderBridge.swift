import AppKit
import FridgeCore

/// Optional Finder niceties through AppleScript. First use triggers the Automation permission
/// prompt. If it is denied, everything here quietly returns nil and files still move normally.
final class FinderBridge {
    private let queue = DispatchQueue(label: "in.krisby.desktopfridge.applescript", qos: .utility)
    private let desktopPath = FridgeStore.defaultDesktop.standardizedFileURL.path

    /// Where Finder shows this item's icon on the desktop. Only asked for items that sit directly
    /// on the Desktop. The completion handler runs on the main queue.
    func desktopPosition(of url: URL, completion: @escaping ((x: Double, y: Double)?) -> Void) {
        let parent = url.deletingLastPathComponent().standardizedFileURL.path
        guard parent == desktopPath else {
            completion(nil)
            return
        }
        let name = FinderBridge.escape(url.lastPathComponent)
        let source = "tell application \"Finder\" to get desktop position of item \"\(name)\" of desktop"
        queue.async {
            let pair = FinderBridge.run(source).flatMap(FinderBridge.pair)
            DispatchQueue.main.async { completion(pair) }
        }
    }

    /// Puts the icon back where it sat. A short delay lets Finder notice the restored file first.
    func setDesktopPosition(ofItemNamed name: String, x: Double, y: Double) {
        let escaped = FinderBridge.escape(name)
        let source = "tell application \"Finder\" to set desktop position of item \"\(escaped)\" of desktop to {\(Int(x.rounded())), \(Int(y.rounded()))}"
        queue.asyncAfter(deadline: .now() + 0.4) {
            _ = FinderBridge.run(source)
        }
    }

    // MARK: Helpers

    private static func escape(_ text: String) -> String {
        return text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func run(_ source: String) -> NSAppleEventDescriptor? {
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        return error == nil ? result : nil
    }

    private static func pair(_ descriptor: NSAppleEventDescriptor) -> (x: Double, y: Double)? {
        guard descriptor.numberOfItems == 2,
              let x = descriptor.atIndex(1), let y = descriptor.atIndex(2) else { return nil }
        return (Double(x.int32Value), Double(y.int32Value))
    }
}
