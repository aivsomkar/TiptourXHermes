// TipTour/Hermes/PressKeyboardShortcutMCPTool.swift
//
// MCP tool that posts a keyboard shortcut. ActionExecutor.pressKeyboardShortcut
// parses strings like "Cmd+S", "Cmd+Shift+N", "Return", and posts virtual
// key codes via CGEvent at HID level. GUIActionMutex serialises with
// concurrent click/type calls. Gated by CompanionManager.hermesGUIAutopilotEnabled.

import Foundation
import AppKit

@MainActor
final class PressKeyboardShortcutMCPTool: MCPTool {
    let name = "press_keyboard_shortcut"
    let description = """
        Press a keyboard shortcut like "Cmd+S", "Cmd+Shift+N", "Return", \
        "Esc". Modifiers (Cmd, Ctrl, Option, Shift) can appear in any order, \
        plus-separated. Useful for save/quit/new-tab/etc. \
        Requires the user to have enabled "Hermes can drive my Mac" in the \
        menu bar panel.
        """
    let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "shortcut": .object([
                "type": .string("string"),
                "description": .string("The shortcut string, e.g. \"Cmd+S\", \"Cmd+Shift+T\", \"Return\"."),
            ]),
            "app_hint": .object([
                "type": .string("string"),
                "description": .string("Optional bundle id or partial name of the app to activate before posting. When omitted, the shortcut goes to the frontmost app."),
            ]),
        ]),
        "required": .array([.string("shortcut")]),
    ])

    private weak var companionManager: CompanionManager?

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
    }

    func call(_ arguments: JSONValue) async throws -> [MCPToolContent] {
        guard case .object(let dict) = arguments,
              case .string(let shortcut) = dict["shortcut"] ?? .null,
              !shortcut.isEmpty
        else {
            throw MCPToolError.invalidArguments("press_keyboard_shortcut requires a non-empty `shortcut` string")
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
            try await ActionExecutor.shared.pressKeyboardShortcut(shortcut, activatingTargetApp: targetApp)
        } catch {
            throw MCPToolError.toolFailed("press shortcut failed: \(error.localizedDescription)")
        }

        return [.text("Pressed \(shortcut)")]
    }

    private static func resolveApp(hint: String) -> NSRunningApplication? {
        let byBundle = NSRunningApplication.runningApplications(withBundleIdentifier: hint)
        if let first = byBundle.first { return first }
        let lowered = hint.lowercased()
        return NSWorkspace.shared.runningApplications.first {
            ($0.localizedName ?? "").lowercased().contains(lowered)
        }
    }
}
