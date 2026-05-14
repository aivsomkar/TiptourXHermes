import XCTest
@testable import TipTour

final class HermesRuntimeVersionTests: XCTestCase {

    private func fixtureURL() -> URL {
        Bundle(for: HermesRuntimeVersionTests.self)
            .url(forResource: "sample-hermes-version", withExtension: "txt")!
    }

    func testParsesAllFiveFieldsFromFixture() throws {
        let version = try HermesRuntimeVersion.read(from: fixtureURL())
        XCTAssertEqual(version.hermesGitRef, "abc1234deadbeef")
        XCTAssertEqual(version.hermesVersion, "0.13.0")
        XCTAssertEqual(version.pythonVersion, "3.11.15")
        XCTAssertEqual(version.pythonBuild, "20260510")
        XCTAssertEqual(version.bundledAt, "2026-05-14T18:00:00Z")
    }

    func testShortDisplayStringIsHumanReadable() throws {
        let version = try HermesRuntimeVersion.read(from: fixtureURL())
        // Short string for footer display — readable, ~50 chars max.
        XCTAssertEqual(
            version.shortDisplayString,
            "Hermes 0.13.0 (abc1234) · Python 3.11.15"
        )
    }

    func testMissingFileThrowsReadableError() {
        let bogus = URL(fileURLWithPath: "/nonexistent/hermes-version.txt")
        XCTAssertThrowsError(try HermesRuntimeVersion.read(from: bogus)) { error in
            XCTAssertTrue(error is HermesRuntimeVersion.ReadError)
        }
    }

    func testMalformedFileThrowsReadableError() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("malformed-\(UUID()).txt")
        try "not a key value file at all".write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }
        XCTAssertThrowsError(try HermesRuntimeVersion.read(from: tmp)) { error in
            guard case HermesRuntimeVersion.ReadError.missingField(let field) = error else {
                return XCTFail("expected missingField, got \(error)")
            }
            // Any of the five required fields can be the first missing one.
            XCTAssertTrue(
                ["hermes_git_ref", "hermes_version", "python_version",
                 "python_build", "bundled_at"].contains(field)
            )
        }
    }
}
