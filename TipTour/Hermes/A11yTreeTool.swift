// TipTour/Hermes/A11yTreeTool.swift
//
// MCP tool that returns up to 200 actionable UI elements in the
// frontmost (or hinted) app, with labels, roles, and center positions.
// Wraps AccessibilityTreeResolver.setOfMarksForTargetApp.
//
// ElementMark's actual shape: { role: String, label: String, center: CGPoint }.
// (No frame — only center coordinates.) The JSON output reflects that:
// each element is { label, role, x, y } where x/y are the global-screen
// center coordinates of the element.

import Foundation

@MainActor
final class A11yTreeTool: MCPTool {
    let name = "get_a11y_tree"
    let description = "List up to 80 actionable UI elements on the frontmost (or hinted) app's screen, with labels, roles, and center positions. Use this to find things to click or point at."
    let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "app_hint": .object([
                "type": .string("string"),
                "description": .string("Optional partial name of the target app (e.g. \"Safari\", \"Xcode\"). When omitted, uses the frontmost app."),
            ]),
            "max_elements": .object([
                "type": .string("integer"),
                "description": .string("Maximum number of elements to return. Defaults to 80; cap at 200."),
            ]),
        ]),
        "required": .array([]),
    ])

    private let resolver: AccessibilityTreeResolver

    init(resolver: AccessibilityTreeResolver) {
        self.resolver = resolver
    }

    func call(_ arguments: JSONValue) async throws -> [MCPToolContent] {
        let hint: String? = {
            guard case .object(let d) = arguments,
                  case .string(let s) = d["app_hint"] ?? .null,
                  !s.isEmpty else { return nil }
            return s
        }()
        let maxElements: Int = {
            guard case .object(let d) = arguments,
                  case .number(let n) = d["max_elements"] ?? .null else { return 80 }
            return max(1, min(200, Int(n)))
        }()

        guard let marks = resolver.setOfMarksForTargetApp(hint: hint, maxElements: maxElements) else {
            throw MCPToolError.toolFailed("could not enumerate accessibility tree (permission denied or no target app)")
        }

        if marks.isEmpty {
            return [.text("[]")]
        }

        let payload: [[String: Any]] = marks.map { mark in
            return [
                "label": mark.label,
                "role": mark.role,
                "x": Int(mark.center.x),
                "y": Int(mark.center.y),
            ]
        }
        let json = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])
        let text = String(data: json, encoding: .utf8) ?? "[]"
        return [.text(text)]
    }
}
