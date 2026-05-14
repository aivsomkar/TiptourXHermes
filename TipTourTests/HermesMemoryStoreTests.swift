import XCTest
@testable import TipTour

final class HermesMemoryStoreTests: XCTestCase {

    private var tempHome: URL!

    override func setUpWithError() throws {
        tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("hermes-memory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let url = tempHome { try? FileManager.default.removeItem(at: url) }
    }

    func testReadReturnsEmptyStringWhenFileMissing() {
        let store = HermesMemoryStore(hermesHome: tempHome)
        XCTAssertEqual(store.read(), "")
    }

    func testWriteThenReadRoundTrips() throws {
        let store = HermesMemoryStore(hermesHome: tempHome)
        try store.write("User's favorite color is blue.")
        XCTAssertEqual(store.read(), "User's favorite color is blue.")
    }

    func testWriteCreatesMemoriesDirectoryIfMissing() throws {
        let store = HermesMemoryStore(hermesHome: tempHome)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.filePath.deletingLastPathComponent().path))
        try store.write("anything")
        var isDir: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: store.filePath.deletingLastPathComponent().path,
                                            isDirectory: &isDir)
            && isDir.boolValue
        )
    }

    func testWriteEmptyStringTruncatesFile() throws {
        let store = HermesMemoryStore(hermesHome: tempHome)
        try store.write("something")
        try store.write("")
        XCTAssertEqual(store.read(), "")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.filePath.path))
    }

    func testWriteOverwritesExisting() throws {
        let store = HermesMemoryStore(hermesHome: tempHome)
        try store.write("first")
        try store.write("second")
        XCTAssertEqual(store.read(), "second")
    }

    func testWriteIsAtomicViaTempRename() throws {
        // Slightly indirect test — we verify no .tmp leftover after a
        // successful write. If atomic-rename wasn't used, a partial write
        // could leave a stale tmp file.
        let store = HermesMemoryStore(hermesHome: tempHome)
        try store.write("hello")
        let dir = store.filePath.deletingLastPathComponent()
        let contents = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        let stragglers = contents.filter { $0.lastPathComponent.hasSuffix(".tmp") }
        XCTAssertTrue(stragglers.isEmpty,
                      "leftover .tmp files: \(stragglers.map(\.lastPathComponent))")
    }

    func testFilePathPointsAtUserMD() {
        let store = HermesMemoryStore(hermesHome: tempHome)
        XCTAssertEqual(
            store.filePath,
            tempHome.appendingPathComponent("memories", isDirectory: true)
                    .appendingPathComponent("USER.md")
        )
    }
}
