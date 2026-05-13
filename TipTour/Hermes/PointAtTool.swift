// TipTour/Hermes/PointAtTool.swift
//
// MCP tool that flies the Arc Reactor cursor to a labelled UI element
// and shows a speech bubble next to it. Resolves the label via the
// existing AccessibilityTreeResolver.findElement; drives the overlay
// by writing to CompanionManager's @Published vars. Auto-clears the
// cursor after 4 seconds.

import Foundation
import AppKit

@MainActor
final class PointAtTool: MCPTool {
    let name = "point_at"
    let description = "Fly the Arc Reactor cursor to an on-screen UI element identified by a label, with a speech bubble. Use get_a11y_tree first to find element labels. The cursor auto-clears after 4 seconds."
    let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "label": .object([
                "type": .string("string"),
                "description": .string("Exact or partial label of the UI element to point at (case-insensitive)."),
            ]),
            "bubble": .object([
                "type": .string("string"),
                "description": .string("Short text shown in the speech bubble next to the cursor (≤120 chars)."),
            ]),
            "app_hint": .object([
                "type": .string("string"),
                "description": .string("Optional partial name of the target app (e.g. \"Safari\"). When omitted, uses the frontmost app."),
            ]),
        ]),
        "required": .array([.string("label"), .string("bubble")]),
    ])

    private let resolver: AccessibilityTreeResolver
    private weak var companionManager: CompanionManager?
    /// Token cancelled when a new point_at call arrives, so a stacked pair
    /// doesn't fight over the auto-clear timer.
    private var autoClearTask: Task<Void, Never>?

    init(resolver: AccessibilityTreeResolver, companionManager: CompanionManager) {
        self.resolver = resolver
        self.companionManager = companionManager
    }

    func call(_ arguments: JSONValue) async throws -> [MCPToolContent] {
        guard case .object(let dict) = arguments,
              case .string(let label) = dict["label"] ?? .null,
              !label.isEmpty,
              case .string(let bubble) = dict["bubble"] ?? .null
        else {
            throw MCPToolError.invalidArguments("point_at requires `label` and `bubble` strings")
        }
        let hint: String? = {
            if case .string(let s) = dict["app_hint"] ?? .null, !s.isEmpty { return s }
            return nil
        }()

        guard let resolved = resolver.findElement(byLabel: label, targetAppHint: hint) else {
            throw MCPToolError.toolFailed("no UI element matching label \"\(label)\" was found")
        }
        guard let cm = companionManager else {
            throw MCPToolError.toolFailed("companion manager is gone")
        }

        let center = CGPoint(x: resolved.screenFrame.midX, y: resolved.screenFrame.midY)
        let displayFrame = NSScreen.screens.first(where: { $0.frame.contains(center) })?.frame
            ?? NSScreen.main?.frame
            ?? .zero

        let truncatedBubble = bubble.count > 120 ? String(bubble.prefix(120)) + "…" : bubble

        cm.detectedElementScreenLocation = center
        cm.detectedElementDisplayFrame = displayFrame
        cm.detectedElementBubbleText = truncatedBubble

        autoClearTask?.cancel()
        autoClearTask = Task { [weak self, weak cm] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                cm?.clearDetectedElementLocation()
                self?.autoClearTask = nil
            }
        }

        return [.text("Pointing at \"\(label)\" at \(Int(center.x)),\(Int(center.y)); bubble: \"\(truncatedBubble)\"")]
    }
}
