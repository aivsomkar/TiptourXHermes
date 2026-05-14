import XCTest
@testable import TipTour

@MainActor
final class ClickElementMCPToolTests: XCTestCase {

    func test_rejects_missing_label() async throws {
        let cm = CompanionManager()
        cm.setHermesGUIAutopilotEnabled(true)
        let tool = ClickElementMCPTool(
            resolver: AccessibilityTreeResolver(),
            companionManager: cm
        )
        do {
            _ = try await tool.call(.object(["bubble": .string("clicking")]))
            XCTFail("expected invalidArguments")
        } catch let MCPToolError.invalidArguments(reason) {
            XCTAssertTrue(reason.contains("label"))
        }
        cm.setHermesGUIAutopilotEnabled(false)
    }

    func test_refuses_when_autopilot_off() async throws {
        let cm = CompanionManager()
        cm.setHermesGUIAutopilotEnabled(false)
        let tool = ClickElementMCPTool(
            resolver: AccessibilityTreeResolver(),
            companionManager: cm
        )
        do {
            _ = try await tool.call(.object([
                "label": .string("Save"),
                "bubble": .string("clicking Save"),
            ]))
            XCTFail("expected toolFailed")
        } catch let MCPToolError.toolFailed(reason) {
            XCTAssertTrue(reason.lowercased().contains("autopilot"))
        }
    }

    func test_throws_when_element_not_found() async throws {
        // Use a deliberately garbled label that no app will have. Skip
        // if Accessibility permission isn't granted (CI / headless).
        try XCTSkipUnless(AXIsProcessTrusted(), "AX permission required")
        let cm = CompanionManager()
        cm.setHermesGUIAutopilotEnabled(true)
        let tool = ClickElementMCPTool(
            resolver: AccessibilityTreeResolver(),
            companionManager: cm
        )
        do {
            _ = try await tool.call(.object([
                "label": .string("zzz_no_element_matches_this_label_zzz"),
                "bubble": .string("test"),
            ]))
            XCTFail("expected toolFailed")
        } catch let MCPToolError.toolFailed(reason) {
            XCTAssertTrue(reason.contains("no UI element"))
        }
        cm.setHermesGUIAutopilotEnabled(false)
    }
}
