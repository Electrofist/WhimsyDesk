import AppKit

struct DrawerItem {
    let url: URL
    let icon: NSImage
    var name: String { url.lastPathComponent }
}

private struct IndexEntry: Codable {
    var originalName: String
    var originalDirectory: String
    var desktopPosition: [Double]?      // Finder icon position {x, y} if it came from the Desktop
}

/// Owns ~/Desktop Drawer/ and a small JSON index of where each stashed item came from.
/// All disk mutation happens on a private serial queue; `items` is read on the main thread only.
final class DrawerStore {
    private(set) var items: [DrawerItem] = []

    private let fm = FileManager.default
    private let folder: URL
    private let desktop: URL
    private let indexURL: URL
    private var index: [String: IndexEntry] = [:]      // keyed by stored file name; touched only on `queue`
    private let queue = DispatchQueue(label: "DesktopDrawer.files", qos: .userInitiated)

    var folderURL: URL { folder }

    init() {
        folder = fm.homeDirectoryForCurrentUser.appendingPathComponent("Desktop Drawer", isDirectory: true)
        desktop = fm.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DesktopDrawer", isDirectory: true)
        indexURL = support.appendingPathComponent("index.json")
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try? fm.createDirectory(at: support, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: indexURL),
           let decoded = try? JSONDecoder().decode([String: IndexEntry].self, from: data) {
            index = decoded
        }
    }

    // MARK: Listing

    /// Cheap directory listing (call on main). Also forgets index entries whose files left the drawer.
    func reload(_ done: (() -> Void)? = nil) {
        let keys: [URLResourceKey] = [.addedToDirectoryDateKey, .contentModificationDateKey]
        let urls = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                options: [.skipsHiddenFiles])) ?? []
        let dated = urls.map { url -> (URL, Date) in
            let v = try? url.resourceValues(forKeys: Set(keys))
            return (url, v?.addedToDirectoryDate ?? v?.contentModificationDate ?? .distantPast)
        }
        items = dated.sorted { $0.1 < $1.1 }.map { DrawerItem(url: $0.0, icon: Self.icon(for: $0.0)) }

        queue.async { [self] in
            let present = Set((try? fm.contentsOfDirectory(atPath: folder.path)) ?? [])
            let stale = index.keys.filter { !present.contains($0) }
            guard !stale.isEmpty else { return }
            stale.forEach { index[$0] = nil }
            saveIndex()
        }
        done?()
    }

    private static func icon(for url: URL) -> NSImage {
        let image = NSWorkspace.shared.icon(forFile: url.path)
        image.size = NSSize(width: 52, height: 52)
        return image
    }

    // MARK: Stash / put back

    /// Moves dropped files into the drawer folder, remembering where they came from.
    func stash(_ urls: [URL], done: @escaping () -> Void) {
        queue.async { [self] in
            let folderPath = folder.standardizedFileURL.path
            let desktopPath = desktop.standardizedFileURL.path
            for url in urls {
                let source = url.standardizedFileURL
                let parent = source.deletingLastPathComponent().path
                if parent == folderPath { continue }                                   // already inside
                if (folderPath + "/").hasPrefix(source.path + "/") { continue }        // never swallow our own ancestors
                let position = parent == desktopPath ? FinderScript.position(of: source.lastPathComponent) : nil
                let target = uniqueURL(named: source.lastPathComponent, in: folder)
                do { try fm.moveItem(at: source, to: target) } catch {
                    NSLog("DesktopDrawer: could not stash \(source.path): \(error)")
                    continue
                }
                index[target.lastPathComponent] = IndexEntry(originalName: source.lastPathComponent,
                                                             originalDirectory: parent,
                                                             desktopPosition: position)
            }
            saveIndex()
            DispatchQueue.main.async { self.reload(done) }
        }
    }

    /// Moves items back to where they came from (Desktop if that's gone) and, best effort,
    /// restores the Finder icon position via AppleScript.
    func putBack(_ names: [String], done: @escaping () -> Void) {
        moveOut(names, toDesktop: false) { _ in done() }
    }

    /// Moves every item in the drawer straight onto the Desktop. Reports how many could not be moved.
    func moveAllToDesktop(_ done: @escaping (_ failed: Int) -> Void) {
        moveOut(items.map(\.name), toDesktop: true, done: done)
    }

    private func moveOut(_ names: [String], toDesktop: Bool, done: @escaping (_ failed: Int) -> Void) {
        queue.async { [self] in
            var failed = 0
            let desktopPath = desktop.standardizedFileURL.path
            var placements: [(String, [Double])] = []
            for name in names {
                let source = folder.appendingPathComponent(name)
                guard fm.fileExists(atPath: source.path) else { continue }
                let entry = index[name]
                var destination = desktop
                var isDir: ObjCBool = false
                if !toDesktop, let dir = entry?.originalDirectory, fm.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue {
                    destination = URL(fileURLWithPath: dir, isDirectory: true)
                }
                let target = uniqueURL(named: entry?.originalName ?? name, in: destination)
                do { try fm.moveItem(at: source, to: target) } catch {
                    NSLog("DesktopDrawer: could not put back \(name): \(error)")
                    failed += 1
                    continue
                }
                index[name] = nil
                if destination.standardizedFileURL.path == desktopPath, let p = entry?.desktopPosition, p.count == 2 {
                    placements.append((target.lastPathComponent, p))
                }
            }
            saveIndex()
            DispatchQueue.main.async { self.reload { done(failed) } }
            for (name, position) in placements { FinderScript.setPosition(of: name, to: position) }
        }
    }

    // MARK: Helpers

    private func uniqueURL(named name: String, in dir: URL) -> URL {
        var candidate = dir.appendingPathComponent(name)
        guard fm.fileExists(atPath: candidate.path) else { return candidate }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var n = 2
        repeat {
            candidate = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        } while fm.fileExists(atPath: candidate.path)
        return candidate
    }

    private func saveIndex() {
        if let data = try? JSONEncoder().encode(index) { try? data.write(to: indexURL, options: .atomic) }
    }
}

/// Finder icon positions via AppleScript. Needs the Automation permission; every call is best effort.
/// Only ever called from the store's serial queue.
enum FinderScript {
    private static func run(_ source: String) -> NSAppleEventDescriptor? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error { NSLog("DesktopDrawer AppleScript: \(error)"); return nil }
        return result
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    static func position(of name: String) -> [Double]? {
        let script = "tell application \"Finder\" to get position of item \"\(escape(name))\" of desktop"
        guard let d = run(script), d.numberOfItems >= 2,
              let x = d.atIndex(1)?.int32Value, let y = d.atIndex(2)?.int32Value else { return nil }
        return [Double(x), Double(y)]
    }

    static func setPosition(of name: String, to p: [Double]) {
        let script = "tell application \"Finder\" to set position of item \"\(escape(name))\" of desktop to {\(Int(p[0])), \(Int(p[1]))}"
        for _ in 0..<6 {                          // Finder may need a moment to notice the moved file
            if run(script) != nil { return }
            Thread.sleep(forTimeInterval: 0.2)
        }
    }
}
