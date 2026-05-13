import XCTest
@testable import TipTour

final class ScreenshotToolTests: XCTestCase {

    @MainActor
    func testScreenshotToolReturnsImageBlock() async throws {
        let tool = ScreenshotTool()
        let blocks: [MCPToolContent]
        do {
            blocks = try await tool.call(.object([:]))
        } catch let error as MCPToolError {
            if case .toolFailed(let s) = error,
               s.lowercased().contains("permission") || s.lowercased().contains("denied") {
                throw XCTSkip("Screen Recording permission missing: \(s)")
            }
            throw error
        }
        XCTAssertEqual(blocks.count, 2)
        guard case .text(let breadcrumb) = blocks.first else {
            XCTFail("expected text breadcrumb as first block"); return
        }
        XCTAssertFalse(breadcrumb.isEmpty)
        guard case .image(let b64, let mime) = blocks.last else {
            XCTFail("expected image block as last block"); return
        }
        XCTAssertEqual(mime, "image/jpeg")
        XCTAssertGreaterThan(b64.count, 1_000, "expected a non-trivial JPEG")
    }
}
