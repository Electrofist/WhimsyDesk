import Foundation

/// Something stuck on the outside of a door: a sticky note or a photo held by a magnet.
public struct DoorNote: Codable, Equatable, Identifiable {
    public enum Kind: String, Codable {
        case note
        case photo
    }

    public var id: UUID
    public var kind: Kind
    /// `DoorSpec.name` of the door it is stuck to.
    public var door: String
    /// Center of the note in door space (origin at the door's bottom left), points.
    public var x: Double
    public var y: Double
    public var text: String
    /// Index into the sticky note palette.
    public var color: Int
    /// Rotation in radians, picked once so every note sits a little crooked.
    public var tilt: Double
    /// Photo magnets: file name of the thumbnail inside the magnets folder.
    public var photoName: String?
    /// Photo magnets: where the picture came from, for Show Original.
    public var originalPath: String?
    public var createdAt: Date

    public init(id: UUID = UUID(), kind: Kind, door: String, x: Double, y: Double, text: String = "",
                color: Int = 0, tilt: Double = 0, photoName: String? = nil, originalPath: String? = nil,
                createdAt: Date = Date()) {
        self.id = id
        self.kind = kind
        self.door = door
        self.x = x
        self.y = y
        self.text = text
        self.color = color
        self.tilt = tilt
        self.photoName = photoName
        self.originalPath = originalPath
        self.createdAt = createdAt
    }
}

/// Keeps the notes and magnets in a small JSON file beside the fridge index, and the magnet
/// thumbnails in a hidden folder. Both start with a dot, so `FridgeStore` never adopts them as items.
public final class DoorNotesStore {
    private struct IndexFile: Codable {
        var version: Int
        var notes: [DoorNote]
    }

    public static let indexName = ".fridge-notes.json"
    public static let photoFolderName = ".magnets"
    /// Enough to cover a door, few enough to stay tidy.
    public static let maxPerDoor = 16
    /// Notes are short reminders, not documents.
    public static let maxTextLength = 90

    public let root: URL
    public private(set) var notes: [DoorNote] = []
    private let fm: FileManager

    public init(root: URL, fileManager: FileManager = .default) {
        self.root = root
        self.fm = fileManager
        load()
        // A magnet whose picture went missing has nothing left to show.
        let before = notes.count
        notes.removeAll { $0.kind == .photo && !fm.fileExists(atPath: photoURL(for: $0)?.path ?? "") }
        if notes.count != before { save() }
    }

    public var photoFolder: URL { return root.appendingPathComponent(DoorNotesStore.photoFolderName, isDirectory: true) }

    public func photoURL(for note: DoorNote) -> URL? {
        guard let name = note.photoName else { return nil }
        return photoFolder.appendingPathComponent(name)
    }

    public func note(id: UUID) -> DoorNote? {
        return notes.first { $0.id == id }
    }

    public func isFull(door: String) -> Bool {
        return notes.filter { $0.door == door }.count >= DoorNotesStore.maxPerDoor
    }

    // MARK: Changes

    public func add(_ note: DoorNote) {
        var n = note
        n.text = String(n.text.prefix(DoorNotesStore.maxTextLength))
        notes.append(n)
        save()
    }

    /// Replaces the stored note with the same id. Moving a note to the end also puts it on top.
    public func update(_ note: DoorNote, bringToFront: Bool = false) {
        guard let index = notes.firstIndex(where: { $0.id == note.id }) else { return }
        var n = note
        n.text = String(n.text.prefix(DoorNotesStore.maxTextLength))
        if bringToFront {
            notes.remove(at: index)
            notes.append(n)
        } else {
            notes[index] = n
        }
        save()
    }

    public func remove(id: UUID) {
        guard let note = note(id: id) else { return }
        if let url = photoURL(for: note) { try? fm.removeItem(at: url) }
        notes.removeAll { $0.id == id }
        save()
    }

    /// Writes PNG data for a new magnet photo and returns the file name to store on the note.
    public func savePhoto(_ png: Data) throws -> String {
        try fm.createDirectory(at: photoFolder, withIntermediateDirectories: true)
        let name = UUID().uuidString + ".png"
        try png.write(to: photoFolder.appendingPathComponent(name), options: .atomic)
        return name
    }

    // MARK: File

    private var indexURL: URL { return root.appendingPathComponent(DoorNotesStore.indexName) }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let file = try? decoder.decode(IndexFile.self, from: data) {
            notes = file.notes
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(IndexFile(version: 1, notes: notes)) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }
}
