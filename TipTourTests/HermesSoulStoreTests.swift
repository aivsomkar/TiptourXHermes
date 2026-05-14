import XCTest
@testable import TipTour

final class HermesSoulStoreTests: XCTestCase {

    private var tempHome: URL!

    override func setUpWithError() throws {
        tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("hermes-soul-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let url = tempHome { try? FileManager.default.removeItem(at: url) }
    }

    func testReadReturnsEmptyStringWhenMissing() {
        let store = HermesSoulStore(hermesHome: tempHome)
        XCTAssertEqual(store.read(), "")
    }

    func testWriteThenReadRoundTrips() throws {
        let store = HermesSoulStore(hermesHome: tempHome)
        try store.write("You are a pirate. Speak in pirate dialect.")
        XCTAssertEqual(store.read(), "You are a pirate. Speak in pirate dialect.")
    }

    func testFilePathPointsAtSoulMD() {
        let store = HermesSoulStore(hermesHome: tempHome)
        XCTAssertEqual(store.filePath, tempHome.appendingPathComponent("SOUL.md"))
    }

    func testWriteEmptyTruncates() throws {
        let store = HermesSoulStore(hermesHome: tempHome)
        try store.write("something")
        try store.write("")
        XCTAssertEqual(store.read(), "")
    }

    func testWriteOverwritesExisting() throws {
        let store = HermesSoulStore(hermesHome: tempHome)
        try store.write("v1")
        try store.write("v2")
        XCTAssertEqual(store.read(), "v2")
    }

    func testWriteLeavesNoTmpStragglers() throws {
        let store = HermesSoulStore(hermesHome: tempHome)
        try store.write("hello")
        let contents = try FileManager.default.contentsOfDirectory(at: tempHome, includingPropertiesForKeys: nil)
        let stragglers = contents.filter { $0.lastPathComponent.hasSuffix(".tmp") }
        XCTAssertTrue(stragglers.isEmpty)
    }
}
