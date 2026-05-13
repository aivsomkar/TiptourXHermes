import XCTest
@testable import TipTour

final class A11yTreeToolTests: XCTestCase {

    @MainActor
    func testA11yTreeToolReturnsNonEmptyForFinder() async throws {
        let resolver = AccessibilityTreeResolver()
        let tool = A11yTreeTool(resolver: resolver)
        let blocks: [MCPToolContent]
        do {
            blocks = try await tool.call(.object(["app_hint": .string("Finder")]))
        } catch let error as MCPToolError {
            if case .toolFailed(let s) = error,
               s.lowercased().contains("permission") || s.lowercased().contains("no target") {
                throw XCTSkip("Accessibility permission missing or Finder absent: \(s)")
            }
            throw error
        }
        guard case .text(let json) = blocks.first else {
            XCTFail("expected text block"); return
        }
        let parsed = (try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]]) ?? []
        XCTAssertFalse(parsed.isEmpty, "expected at least one element for Finder")
        XCTAssertNotNil(parsed.first?["label"])
        XCTAssertNotNil(parsed.first?["role"])
    }
}
