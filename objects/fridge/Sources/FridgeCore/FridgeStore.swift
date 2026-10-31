import Foundation

public struct FridgeEntry: Codable, Equatable, Identifiable {
    public var id: UUID
    /// File name inside ~/Fridge (may differ from the original if it had to be made unique).
    public var storedName: String
    /// Full path the item came from.
    public var originalPath: String
    /// Finder desktop icon position, if it was known when the item went in.
    public var originalX: Double?
    public var originalY: Double?
    public var placedAt: Date
    public var shelf: Int
    public var slot: Int

    public var globalSlot: Int { return shelf * ShelfLayout.slotsPerShelf + slot }
}

public enum FridgeError: Error, Equatable {
    case full
    case alreadyInside
    case missingSource
    case notFound
}

public struct RestoreResult {
    public var destination: URL
    /// Set only when the item went back onto the Desktop and a position was recorded.
    public var desktopPosition: (x: Double, y: Double)?
}

/// Moves files in and out of ~/Fridge and keeps a small JSON index beside them.
public final class FridgeStore {
    private struct IndexFile: Codable {
        var version: Int
        var items: [FridgeEntry]
    }

    public static let indexName = ".fridge-index.json"

    public let root: URL
    /// Where items go when their original folder no longer exists, and the only folder
    /// where a Finder icon position is worth restoring.
    public let desktopDirectory: URL
    public private(set) var entries: [FridgeEntry] = []
    private let fm: FileManager

    public static var defaultRoot: URL {
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Fridge", isDirectory: true)
    }

    public static var defaultDesktop: URL {
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
    }

    public init(root: URL = FridgeStore.defaultRoot,
                desktop: URL = FridgeStore.defaultDesktop,
                fileManager: FileManager = .default) throws {
        self.root = root
        self.desktopDirectory = desktop
        self.fm = fileManager
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        loadIndex()
        reconcile()
    }

    // MARK: Lookup

    public func url(for entry: FridgeEntry) -> URL {
        return root.appendingPathComponent(entry.storedName)
    }

    public func entry(id: UUID) -> FridgeEntry? {
        return entries.first { $0.id == id }
    }

    public var isFull: Bool { return entries.count >= ShelfLayout.capacity }

    // MARK: Store

    /// Moves a file or folder into the fridge. Throws `.full` before touching the file when there is no room.
    @discardableResult
    public func store(fileAt source: URL,
                      desktopPosition: (x: Double, y: Double)?,
                      preferredShelf: Int,
                      now: Date = Date()) throws -> FridgeEntry {
        let standardized = source.standardizedFileURL
        if standardized.deletingLastPathComponent().path == root.standardizedFileURL.path {
            throw FridgeError.alreadyInside
        }
        guard fm.fileExists(atPath: standardized.path) else { throw FridgeError.missingSource }

        let occupied = Set(entries.map { $0.globalSlot })
        guard let spot = ShelfLayout.firstFreeSlot(occupied: occupied, preferredShelf: preferredShelf) else {
            throw FridgeError.full
        }

        let destination = uniqueURL(in: root, name: standardized.lastPathComponent)
        try fm.moveItem(at: standardized, to: destination)

        let entry = FridgeEntry(id: UUID(),
                                storedName: destination.lastPathComponent,
                                originalPath: standardized.path,
                                originalX: desktopPosition?.x,
                                originalY: desktopPosition?.y,
                                placedAt: now,
                                shelf: spot.shelf,
                                slot: spot.slot)
        entries.append(entry)
        saveIndex()
        return entry
    }

    // MARK: Restore

    /// Moves an item back to where it came from. Falls back to ~/Desktop if that folder is gone.
    public func restore(_ entry: FridgeEntry) throws -> RestoreResult {
        let source = url(for: entry)
        guard fm.fileExists(atPath: source.path) else {
            removeEntry(id: entry.id)
            throw FridgeError.notFound
        }

        let originalURL = URL(fileURLWithPath: entry.originalPath)
        let desktop = desktopDirectory
        var parent = originalURL.deletingLastPathComponent()
        var isDir: ObjCBool = false
        if !(fm.fileExists(atPath: parent.path, isDirectory: &isDir) && isDir.boolValue) {
            parent = desktop
        }

        let destination = uniqueURL(in: parent, name: originalURL.lastPathComponent)
        try fm.moveItem(at: source, to: destination)
        removeEntry(id: entry.id)

        var position: (x: Double, y: Double)?
        if let x = entry.originalX, let y = entry.originalY,
           parent.standardizedFileURL.path == desktop.standardizedFileURL.path {
            position = (x, y)
        }
        return RestoreResult(destination: destination, desktopPosition: position)
    }

    /// Moves an item onto ~/Desktop whatever folder it came from. Same naming and index update as `restore`.
    public func moveToDesktop(_ entry: FridgeEntry) throws -> RestoreResult {
        let source = url(for: entry)
        guard fm.fileExists(atPath: source.path) else {
            removeEntry(id: entry.id)
            throw FridgeError.notFound
        }

        let originalURL = URL(fileURLWithPath: entry.originalPath)
        let desktop = desktopDirectory
        let destination = uniqueURL(in: desktop, name: originalURL.lastPathComponent)
        try fm.moveItem(at: source, to: destination)
        removeEntry(id: entry.id)

        var position: (x: Double, y: Double)?
        if let x = entry.originalX, let y = entry.originalY,
           originalURL.deletingLastPathComponent().standardizedFileURL.path == desktop.standardizedFileURL.path {
            position = (x, y)
        }
        return RestoreResult(destination: destination, desktopPosition: position)
    }

    /// Forget an entry without touching files (used when a drag moved the file elsewhere).
    public func removeEntry(id: UUID) {
        entries.removeAll { $0.id == id }
        saveIndex()
    }

    // MARK: Index

    private var indexURL: URL { return root.appendingPathComponent(FridgeStore.indexName) }

    private func loadIndex() {
        guard let data = try? Data(contentsOf: indexURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let file = try? decoder.decode(IndexFile.self, from: data) {
            entries = file.items
        }
    }

    private func saveIndex() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let file = IndexFile(version: 1, items: entries)
        guard let data = try? encoder.encode(file) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    /// Drops entries whose files left the folder and adopts files someone put there by hand.
    private func reconcile() {
        var changed = false

        let before = entries.count
        entries.removeAll { !fm.fileExists(atPath: url(for: $0).path) }
        if entries.count != before { changed = true }

        let names = (try? fm.contentsOfDirectory(atPath: root.path)) ?? []
        let known = Set(entries.map { $0.storedName })
        let desktop = desktopDirectory
        for name in names.sorted() where !name.hasPrefix(".") && !known.contains(name) {
            let occupied = Set(entries.map { $0.globalSlot })
            guard let spot = ShelfLayout.firstFreeSlot(occupied: occupied, preferredShelf: 1) else { break }
            let attributes = try? fm.attributesOfItem(atPath: root.appendingPathComponent(name).path)
            let placed = (attributes?[.creationDate] as? Date) ?? Date()
            entries.append(FridgeEntry(id: UUID(),
                                       storedName: name,
                                       originalPath: desktop.appendingPathComponent(name).path,
                                       originalX: nil,
                                       originalY: nil,
                                       placedAt: placed,
                                       shelf: spot.shelf,
                                       slot: spot.slot))
            changed = true
        }
        if changed { saveIndex() }
    }

    // MARK: Names

    /// "name.ext" then "name 2.ext", "name 3.ext" and so on, like Finder.
    func uniqueURL(in directory: URL, name: String) -> URL {
        var candidate = directory.appendingPathComponent(name)
        if !fm.fileExists(atPath: candidate.path) { return candidate }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var n = 2
        repeat {
            let numbered = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            candidate = directory.appendingPathComponent(numbered)
            n += 1
        } while fm.fileExists(atPath: candidate.path)
        return candidate
    }
}
