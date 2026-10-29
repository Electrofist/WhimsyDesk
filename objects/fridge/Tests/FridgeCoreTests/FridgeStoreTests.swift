import XCTest
@testable import FridgeCore

final class FridgeStoreTests: XCTestCase {
    private var sandbox: URL!
    private var fridge: URL!
    private var desk: URL!
    private var realDesktop: URL!

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory.appendingPathComponent("fridge-tests-\(UUID().uuidString)")
        fridge = sandbox.appendingPathComponent("Fridge")
        desk = sandbox.appendingPathComponent("Desk")
        realDesktop = sandbox.appendingPathComponent("Desktop")
        try FileManager.default.createDirectory(at: desk, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: realDesktop, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sandbox)
    }

    private func makeFile(_ name: String, contents: String = "x") throws -> URL {
        let url = desk.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testStoreMovesFileAndWritesIndex() throws {
        let store = try FridgeStore(root: fridge, desktop: realDesktop)
        let file = try makeFile("notes.txt")
        let entry = try store.store(fileAt: file, desktopPosition: (120, 340), preferredShelf: 1)

        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url(for: entry).path))
        XCTAssertEqual(entry.originalX, 120)
        XCTAssertEqual(entry.originalY, 340)
        XCTAssertEqual(entry.shelf, 1)

        let reopened = try FridgeStore(root: fridge, desktop: realDesktop)
        XCTAssertEqual(reopened.entries.count, 1)
        XCTAssertEqual(reopened.entries.first?.id, entry.id)
        XCTAssertEqual(reopened.entries.first?.originalPath, file.standardizedFileURL.path)
    }

    func testNameCollisionsGetFinderStyleSuffix() throws {
        let store = try FridgeStore(root: fridge, desktop: realDesktop)
        let first = try store.store(fileAt: try makeFile("a.txt"), desktopPosition: nil, preferredShelf: 0)
        let second = try store.store(fileAt: try makeFile("a.txt"), desktopPosition: nil, preferredShelf: 0)
        XCTAssertEqual(first.storedName, "a.txt")
        XCTAssertEqual(second.storedName, "a 2.txt")
    }

    func testRestoreMovesBackToOriginalFolderAndFreesTheSlot() throws {
        let store = try FridgeStore(root: fridge, desktop: realDesktop)
        let file = try makeFile("photo.png")
        let entry = try store.store(fileAt: file, desktopPosition: nil, preferredShelf: 2)
        let result = try store.restore(entry)

        XCTAssertEqual(result.destination.standardizedFileURL.path, file.standardizedFileURL.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertNil(result.desktopPosition, "position is only restored on the real Desktop")
    }

    func testRestoreFallsBackWhenOriginalFolderIsGone() throws {
        let store = try FridgeStore(root: fridge, desktop: realDesktop)
        let file = try makeFile("gone.txt")
        let entry = try store.store(fileAt: file, desktopPosition: nil, preferredShelf: 0)
        try FileManager.default.removeItem(at: desk)
        let result = try store.restore(entry)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.destination.path))
        XCTAssertEqual(result.destination.deletingLastPathComponent().standardizedFileURL.path,
                       realDesktop.standardizedFileURL.path)
    }

    func testPositionIsRestoredOnlyForTheDesktopFolder() throws {
        let store = try FridgeStore(root: fridge, desktop: realDesktop)
        let onDesktop = realDesktop.appendingPathComponent("icon.txt")
        try "x".write(to: onDesktop, atomically: true, encoding: .utf8)
        let entry = try store.store(fileAt: onDesktop, desktopPosition: (64, 200), preferredShelf: 0)
        let result = try store.restore(entry)
        XCTAssertEqual(result.desktopPosition?.x, 64)
        XCTAssertEqual(result.desktopPosition?.y, 200)
    }

    func testFullFridgeRefusesWithoutMovingTheFile() throws {
        let store = try FridgeStore(root: fridge, desktop: realDesktop)
        for i in 0..<ShelfLayout.capacity {
            _ = try store.store(fileAt: try makeFile("f\(i).txt"), desktopPosition: nil, preferredShelf: 1)
        }
        XCTAssertTrue(store.isFull)
        let extra = try makeFile("extra.txt")
        XCTAssertThrowsError(try store.store(fileAt: extra, desktopPosition: nil, preferredShelf: 1)) {
            XCTAssertEqual($0 as? FridgeError, .full)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: extra.path))
    }

    func testReconcileDropsMissingFilesAndAdoptsStrangers() throws {
        let store = try FridgeStore(root: fridge, desktop: realDesktop)
        let entry = try store.store(fileAt: try makeFile("keep.txt"), desktopPosition: nil, preferredShelf: 1)
        try FileManager.default.removeItem(at: store.url(for: entry))
        try "hi".write(to: fridge.appendingPathComponent("handmade.txt"), atomically: true, encoding: .utf8)

        let reopened = try FridgeStore(root: fridge, desktop: realDesktop)
        XCTAssertEqual(reopened.entries.map { $0.storedName }, ["handmade.txt"])
    }

    func testStoringSomethingAlreadyInsideThrows() throws {
        let store = try FridgeStore(root: fridge, desktop: realDesktop)
        let entry = try store.store(fileAt: try makeFile("in.txt"), desktopPosition: nil, preferredShelf: 0)
        XCTAssertThrowsError(try store.store(fileAt: store.url(for: entry), desktopPosition: nil, preferredShelf: 0)) {
            XCTAssertEqual($0 as? FridgeError, .alreadyInside)
        }
    }
}
