import AppKit

/// One file or folder hidden in the mailbox.
struct StoredItem: Codable, Equatable {
    /// Name inside ~/Mailbox (may differ from the original if it had to be made unique).
    var name: String
    /// Full path it came from, for Put Back.
    var originalPath: String
    var storedAt: Date
    /// Where its icon sat on the desktop, if it came from there.
    var desktopX: Double?
    var desktopY: Double?
}

/// Moves files into ~/Mailbox and back out, and keeps a small index of where each one came from.
/// Files are always moved, never copied or deleted.
final class FileStore {
    static let folder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Mailbox", isDirectory: true).standardizedFileURL
    static let desktop = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Desktop", isDirectory: true).standardizedFileURL

    var folder: URL { FileStore.folder }
    private(set) var items: [StoredItem] = []
    private let fm = FileManager.default
    private let finder = FinderBridge()
    private var indexURL: URL { folder.appendingPathComponent(".mailbox-index.json") }

    init() {
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        load()
        reconcile()
    }

    func url(of item: StoredItem) -> URL { folder.appendingPathComponent(item.name) }

    // MARK: In and out

    /// Moves files in. Skips anything already inside, and never takes a folder that contains ~/Mailbox.
    func store(_ urls: [URL], completion: @escaping () -> Void) {
        let sources = urls.map { $0.standardizedFileURL }.filter { source in
            source.deletingLastPathComponent().path != folder.path && !(folder.path + "/").hasPrefix(source.path + "/")
        }
        guard !sources.isEmpty else { completion(); return }
        // Ask Finder where the icons sat first, then move them.
        let group = DispatchGroup()
        var positions: [String: (x: Double, y: Double)] = [:]
        for source in sources {
            group.enter()
            finder.desktopPosition(of: source) { pair in
                if let pair { positions[source.path] = pair }
                group.leave()
            }
        }
        group.notify(queue: .main) { [self] in
            for source in sources {
                let target = uniqueURL(in: folder, name: source.lastPathComponent)
                do { try fm.moveItem(at: source, to: target) } catch {
                    NSLog("Could not store \(source.path): \(error)")
                    continue
                }
                let p = positions[source.path]
                items.append(StoredItem(name: target.lastPathComponent, originalPath: source.path, storedAt: Date(),
                                        desktopX: p?.x, desktopY: p?.y))
            }
            save()
            completion()
        }
    }

    /// Moves an item back to where it came from, or to the Desktop if that folder is gone.
    @discardableResult
    func putBack(_ item: StoredItem) -> URL? {
        let original = URL(fileURLWithPath: item.originalPath)
        var parent = original.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        if !(fm.fileExists(atPath: parent.path, isDirectory: &isDirectory) && isDirectory.boolValue) {
            parent = FileStore.desktop
        }
        let target = uniqueURL(in: parent, name: original.lastPathComponent)
        do { try fm.moveItem(at: url(of: item), to: target) } catch {
            NSLog("Could not put back \(item.name): \(error)")
            return nil
        }
        forget(item)
        if parent.standardizedFileURL.path == FileStore.desktop.path, let x = item.desktopX, let y = item.desktopY {
            finder.setDesktopPosition(ofItemNamed: target.lastPathComponent, x: x, y: y)
        }
        return target
    }

    /// Drops an item from the index without touching files (used when it was dragged out).
    func forget(_ item: StoredItem) {
        items.removeAll { $0.name == item.name }
        save()
    }

    /// Drops entries whose files left the folder and adopts files put there by hand.
    /// Runs at launch and each time the door opens. Never on a timer.
    func reconcile() {
        let before = items
        items.removeAll { !fm.fileExists(atPath: url(of: $0).path) }
        let known = Set(items.map(\.name))
        let names = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names.sorted() where !name.hasPrefix(".") && !known.contains(name) {
            items.append(StoredItem(name: name, originalPath: FileStore.desktop.appendingPathComponent(name).path,
                                    storedAt: Date()))
        }
        if items != before { save() }
    }

    // MARK: Index

    private func load() {
        guard let data = try? Data(contentsOf: indexURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        items = (try? decoder.decode([StoredItem].self, from: data)) ?? []
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(items) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    /// "name.ext", then "name 2.ext", "name 3.ext", like Finder.
    private func uniqueURL(in directory: URL, name: String) -> URL {
        var candidate = directory.appendingPathComponent(name)
        guard fm.fileExists(atPath: candidate.path) else { return candidate }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var n = 2
        repeat {
            candidate = directory.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        } while fm.fileExists(atPath: candidate.path)
        return candidate
    }
}

/// Optional Finder niceties through AppleScript. If permission is denied, files still move normally.
final class FinderBridge {
    private let queue = DispatchQueue(label: "io.github.electrofist.mailbox.applescript", qos: .utility)

    /// Where Finder shows this item's icon on the desktop. Completion runs on the main queue.
    func desktopPosition(of url: URL, completion: @escaping ((x: Double, y: Double)?) -> Void) {
        guard url.deletingLastPathComponent().standardizedFileURL.path == FileStore.desktop.path else {
            completion(nil); return
        }
        let source = "tell application \"Finder\" to get desktop position of item \"\(Self.escape(url.lastPathComponent))\" of desktop"
        queue.async {
            let pair = Self.run(source).flatMap(Self.pair)
            DispatchQueue.main.async { completion(pair) }
        }
    }

    /// Puts the icon back where it sat. A short delay lets Finder notice the restored file first.
    func setDesktopPosition(ofItemNamed name: String, x: Double, y: Double) {
        let source = "tell application \"Finder\" to set desktop position of item \"\(Self.escape(name))\" of desktop to {\(Int(x.rounded())), \(Int(y.rounded()))}"
        queue.asyncAfter(deadline: .now() + 0.4) { _ = Self.run(source) }
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func run(_ source: String) -> NSAppleEventDescriptor? {
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        return error == nil ? result : nil
    }

    private static func pair(_ d: NSAppleEventDescriptor) -> (x: Double, y: Double)? {
        guard d.numberOfItems == 2, let x = d.atIndex(1), let y = d.atIndex(2) else { return nil }
        return (Double(x.int32Value), Double(y.int32Value))
    }
}
