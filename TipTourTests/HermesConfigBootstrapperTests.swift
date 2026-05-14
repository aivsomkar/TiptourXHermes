import XCTest
@testable import TipTour

/// Tests run against an isolated temp directory passed as HERMES_HOME,
/// so they never touch the user's real ~/.hermes. Each test wipes its
/// own tempdir on teardown to avoid leaking state between runs.
final class HermesConfigBootstrapperTests: XCTestCase {

    private var tempHome: URL!

    override func setUpWithError() throws {
        tempHome = try makeTempHome()
    }

    override func tearDownWithError() throws {
        if let url = tempHome,
           FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func makeTempHome() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("hermes-bootstrapper-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    func testPlaceholderExistsSoTestTargetCompiles() {
        XCTAssertTrue(true)
    }
}
