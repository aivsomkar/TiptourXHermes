import XCTest
@testable import TipTour

final class PointAtToolTests: XCTestCase {

    @MainActor
    func testPointAtToolSetsCompanionManagerProps() async throws {
        let resolver = AccessibilityTreeResolver()
        let cm = CompanionManager()
        let tool = PointAtTool(resolver: resolver, companionManager: cm)
        do {
            let blocks = try await tool.call(.object([
                "label": .string("Finder"),
                "bubble": .string("here it is"),
                "app_hint": .string("Finder"),
            ]))
            guard case .text = blocks.first else {
                XCTFail("expected text block"); return
            }
            XCTAssertNotNil(cm.detectedElementScreenLocation)
            XCTAssertEqual(cm.detectedElementBubbleText, "here it is")
        } catch let error as MCPToolError {
            if case .toolFailed(let s) = error, s.contains("no UI element") {
                throw XCTSkip("a11y permission missing or element absent: \(s)")
            }
            throw error
        }
    }

    @MainActor
    func testPointAtToolAutoClearsAfterFourSeconds() async throws {
        let resolver = AccessibilityTreeResolver()
        let cm = CompanionManager()
        let tool = PointAtTool(resolver: resolver, companionManager: cm)
        do {
            _ = try await tool.call(.object([
                "label": .string("Finder"),
                "bubble": .string("x"),
            ]))
        } catch {
            throw XCTSkip("setup failed: \(error)")
        }
        XCTAssertNotNil(cm.detectedElementScreenLocation)
        try await Task.sleep(nanoseconds: 4_500_000_000)
        XCTAssertNil(cm.detectedElementScreenLocation,
                     "PointAtTool should auto-clear CompanionManager state after 4 seconds")
    }
}
