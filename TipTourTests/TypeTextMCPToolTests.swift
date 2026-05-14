import XCTest
@testable import TipTour

@MainActor
final class TypeTextMCPToolTests: XCTestCase {

    func test_rejects_missing_text() async throws {
        let cm = CompanionManager()
        cm.setHermesGUIAutopilotEnabled(true)
        let tool = TypeTextMCPTool(companionManager: cm)
        do {
            _ = try await tool.call(.object([:]))
            XCTFail("expected invalidArguments")
        } catch let MCPToolError.invalidArguments(reason) {
            XCTAssertTrue(reason.contains("text"))
        }
        cm.setHermesGUIAutopilotEnabled(false)
    }

    func test_refuses_when_autopilot_off() async throws {
        let cm = CompanionManager()
        cm.setHermesGUIAutopilotEnabled(false)
        let tool = TypeTextMCPTool(companionManager: cm)
        do {
            _ = try await tool.call(.object(["text": .string("hello")]))
            XCTFail("expected toolFailed")
        } catch let MCPToolError.toolFailed(reason) {
            XCTAssertTrue(reason.lowercased().contains("autopilot"))
        }
    }
}
