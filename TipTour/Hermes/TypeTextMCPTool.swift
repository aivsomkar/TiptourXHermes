// TipTour/Hermes/TypeTextMCPTool.swift
//
// MCP tool that types a string into whatever currently has keyboard
// focus, using ActionExecutor's pasteboard-staging + Cmd+V path
// (layout-agnostic, fast for long strings, restores the user's
// clipboard after). Gated by CompanionManager.hermesGUIAutopilotEnabled.
//
// Pairs with click_element. Hermes is expected to call click_element
// first to focus the target field, then type_text to fill it.

import Foundation
import AppKit

@MainActor
final class TypeTextMCPTool: MCPTool {
    let name = "type_text"
    let description = """
        Type text into the currently focused field. Uses pasteboard staging \
        + Cmd+V (layout-agnostic, fast for long strings). The user's \
        clipboard contents are saved before and restored after. Call \
        click_element on the target field first to ensure focus. \
        Requires the user to have enabled "Hermes can drive my Mac" in the \
        menu bar panel.
        """
    let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "text": .object([
                "type": .string("string"),
                "description": .string("The text to type into the focused field. Multi-line is supported."),
            ]),
            "app_hint": .object([
                "type": .string("string"),
                "description": .string("Optional bundle id or partial name of the app to activate before typing. When omitted, uses the frontmost app."),
            ]),
        ]),
        "required": .array([.string("text")]),
    ])

    private weak var companionManager: CompanionManager?

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
    }

    func call(_ arguments: JSONValue) async throws -> [MCPToolContent] {
        guard case .object(let dict) = arguments,
              case .string(let text) = dict["text"] ?? .null,
              !text.isEmpty
        else {
            throw MCPToolError.invalidArguments("type_text requires a non-empty `text` string")
        }
        guard let companionManager else {
            throw MCPToolError.toolFailed("companion manager is gone")
        }
        guard companionManager.hermesGUIAutopilotEnabled else {
            throw MCPToolError.toolFailed(
                "autopilot for Hermes is disabled. Ask the user to enable \"Hermes can drive my Mac\" in the menu bar panel's developer section, then try again."
            )
        }

        let appHint: String? = {
            if case .string(let s) = dict["app_hint"] ?? .null, !s.isEmpty { return s }
            return nil
        }()
        let targetApp: NSRunningApplication? = appHint.flatMap { Self.resolveApp(hint: $0) }

        do {
            try await ActionExecutor.shared.typeText(text, activatingTargetApp: targetApp)
        } catch {
            throw MCPToolError.toolFailed("type failed: \(error.localizedDescription)")
        }

        return [.text("Typed \(text.count) characters")]
    }

    /// Resolve an `app_hint` to an `NSRunningApplication` using two
    /// strategies: exact bundle-id match first, then a localized-name
    /// substring match. Matches PointAtTool's hint semantics so Hermes
    /// can pass the same string ("Safari", "com.apple.Safari",
    /// "Notion") to either tool.
    private static func resolveApp(hint: String) -> NSRunningApplication? {
        let byBundle = NSRunningApplication.runningApplications(withBundleIdentifier: hint)
        if let first = byBundle.first { return first }
        let lowered = hint.lowercased()
        return NSWorkspace.shared.runningApplications.first {
            ($0.localizedName ?? "").lowercased().contains(lowered)
        }
    }
}
