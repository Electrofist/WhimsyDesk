import Foundation

/// One stored file or folder.
struct StoredItem: Codable, Equatable {
    /// Name inside the object's folder (may differ from the original if it had to be made unique).
    var name: String
    /// Full path it came from, for Put Back.
    var originalPath: String
    var storedAt: Date
}

/// Moves files into ~/Desktop Objects/<folder> and back out, and keeps a small index of where
/// each one came from. Files are always moved, never copied or deleted.
final class ObjectStore {
    let folder: URL
    private(set) var items: [StoredItem] = []
    private let fm = FileManager.default
    private var indexURL: URL { folder.appendingPathComponent(".index.json") }
    private var desktop: URL {
        fm.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
    }

    init(folderName: String) {
        folder = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop Objects", isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
            .standardizedFileURL
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        load()
        reconcile()
    }

    func url(of item: StoredItem) -> URL { folder.appendingPathComponent(item.name) }

    func item(named name: String) -> StoredItem? { items.first { $0.name == name } }

    // MARK: In and out

    /// Moves files in. Skips anything already inside, and never takes a folder that contains this one.
    func store(_ urls: [URL]) {
        for source in urls.map({ $0.standardizedFileURL }) {
            if source.deletingLastPathComponent().path == folder.path { continue }
            if (folder.path + "/").hasPrefix(source.path + "/") { continue }
            let target = uniqueURL(in: folder, name: source.lastPathComponent)
            do {
                try fm.moveItem(at: source, to: target)
            } catch {
                NSLog("Could not store \(source.path): \(error)")
                continue
            }
            items.append(StoredItem(name: target.lastPathComponent, originalPath: source.path, storedAt: Date()))
        }
        save()
    }

    /// Moves an item back to where it came from, or to the Desktop if that folder is gone.
    @discardableResult
    func putBack(_ item: StoredItem) -> URL? {
        let original = URL(fileURLWithPath: item.originalPath)
        var parent = original.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        if !(fm.fileExists(atPath: parent.path, isDirectory: &isDirectory) && isDirectory.boolValue) {
            parent = desktop
        }
        return move(item, into: parent, name: original.lastPathComponent)
    }

    /// Moves an item onto the Desktop, whatever folder it came from.
    /// Hidden bookkeeping files (names starting with ".") are never moved.
    @discardableResult
    func moveToDesktop(_ item: StoredItem) -> URL? {
        guard !item.name.hasPrefix(".") else { return nil }
        return move(item, into: desktop, name: item.name)
    }

    /// Shared by Put Back and Move to Desktop: moves the file out under a unique name,
    /// then drops it from the index. If the move fails the file stays inside and stays listed.
    private func move(_ item: StoredItem, into parent: URL, name: String) -> URL? {
        let target = uniqueURL(in: parent, name: name)
        do {
            try fm.moveItem(at: url(of: item), to: target)
        } catch {
            NSLog("Could not move out \(item.name): \(error)")
            return nil
        }
        forget(item)
        return target
    }

    /// Drops an item from the index without touching files (used when it was dragged out).
    func forget(_ item: StoredItem) {
        items.removeAll { $0.name == item.name }
        save()
    }

    /// Drops entries whose files left the folder and adopts files put there by hand.
    /// Runs at launch and each time the object opens. Never on a timer.
    func reconcile() {
        let before = items
        items.removeAll { !fm.fileExists(atPath: url(of: $0).path) }
        let known = Set(items.map(\.name))
        let names = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names.sorted() where !name.hasPrefix(".") && !known.contains(name) {
            items.append(StoredItem(name: name, originalPath: desktop.appendingPathComponent(name).path, storedAt: Date()))
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
