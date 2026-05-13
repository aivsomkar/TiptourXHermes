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
}
