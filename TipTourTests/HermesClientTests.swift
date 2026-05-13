import XCTest
import Combine
@testable import TipTour

final class HermesClientTests: XCTestCase {

    @MainActor
    func testNewClientHasEmptyState() async {
        let client = HermesClient()
        XCTAssertTrue(client.transcript.isEmpty)
        XCTAssertFalse(client.isWorking)
        XCTAssertNil(client.lastError)
    }

    /// First send with HERMES_HOME pointing at an empty temp dir
    /// should surface Hermes's "No LLM provider configured" error as
    /// a .system turn rather than hanging.
    @MainActor
    func testFirstSendWithMissingConfigSurfacesSystemTurn() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("hermes-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let client = HermesClient(hermesHome: tmp)
        await client.send("hello")
        // After send returns we expect exactly:
        //   transcript[0] = .user("hello")
        //   transcript[1] = .system("Hermes error: …")
        XCTAssertEqual(client.transcript.count, 2)
        if case .user(_, let t) = client.transcript[0] {
            XCTAssertEqual(t, "hello")
        } else { XCTFail("expected .user at index 0") }
        if case .system(_, let text) = client.transcript[1] {
            XCTAssertTrue(text.lowercased().contains("hermes error"))
            XCTAssertTrue(text.lowercased().contains("provider") || text.lowercased().contains("config"))
        } else { XCTFail("expected .system at index 1") }
        client.stop()
    }
}
