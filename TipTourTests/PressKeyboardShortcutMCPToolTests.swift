import XCTest
@testable import TipTour

@MainActor
final class PressKeyboardShortcutMCPToolTests: XCTestCase {

    func test_rejects_missing_shortcut() async throws {
        let cm = CompanionManager()
        cm.setHermesGUIAutopilotEnabled(true)
        let tool = PressKeyboardShortcutMCPTool(companionManager: cm)
        do {
            _ = try await tool.call(.object([:]))
            XCTFail("expected invalidArguments")
        } catch let MCPToolError.invalidArguments(reason) {
            XCTAssertTrue(reason.contains("shortcut"))
        }
        cm.setHermesGUIAutopilotEnabled(false)
    }

    func test_refuses_when_autopilot_off() async throws {
        let cm = CompanionManager()
        cm.setHermesGUIAutopilotEnabled(false)
        let tool = PressKeyboardShortcutMCPTool(companionManager: cm)
        do {
            _ = try await tool.call(.object(["shortcut": .string("Cmd+S")]))
            XCTFail("expected toolFailed")
        } catch let MCPToolError.toolFailed(reason) {
            XCTAssertTrue(reason.lowercased().contains("autopilot"))
        }
    }
}
