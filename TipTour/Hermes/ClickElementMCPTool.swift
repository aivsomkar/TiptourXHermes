// TipTour/Hermes/ClickElementMCPTool.swift
//
// MCP tool that visibly clicks a labelled UI element. The Arc Reactor
// cursor flies to the resolved element first (same path as PointAtTool),
// settles, and then ActionExecutor.shared.click posts the click pair
// at HID level. Gated by CompanionManager.hermesGUIAutopilotEnabled so
// Hermes can never click without the user having opted in.
//
// Pairs with type_text and press_keyboard_shortcut. For multi-step
// flows (e.g. fill a form), Hermes is expected to call click_element
// to focus a field, then type_text to fill it.

import Foundation
import AppKit

@MainActor
final class ClickElementMCPTool: MCPTool {
    let name = "click_element"
    let description = """
        Click on a labelled UI element. The visible Arc Reactor cursor flies \
        to the target first so the user sees what's about to be clicked, then \
        ~1.1 seconds later the click is posted. Resolves the label via the \
        macOS Accessibility tree. Use get_a11y_tree first to find element \
        labels. Requires the user to have enabled "Hermes can drive my Mac" \
        in the menu bar panel's developer section — when disabled this tool \
        throws an error and the user must opt in before Hermes can click.
        """
    let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "label": .object([
                "type": .string("string"),
                "description": .string("Exact or partial label of the UI element to click (case-insensitive)."),
            ]),
            "bubble": .object([
                "type": .string("string"),
                "description": .string("Optional text shown in the speech bubble during the flight (≤120 chars). Defaults to \"clicking …\"."),
            ]),
            "app_hint": .object([
                "type": .string("string"),
                "description": .string("Optional partial name of the target app (e.g. \"Safari\"). When omitted, uses the frontmost app."),
            ]),
        ]),
        "required": .array([.string("label")]),
    ])

    private let resolver: AccessibilityTreeResolver
    private weak var companionManager: CompanionManager?

    /// Time we wait between starting the flight and posting the click.
    /// The bezier arc in OverlayWindow tops out at ~1.4s for long flights;
    /// 1.1s covers the common case where the target is within a half-screen
    /// hop. Mirrors WorkflowRunner's autopilot delay so the visual cadence
    /// feels consistent across both paths.
    private let preClickFlightSettleSeconds: Double = 1.1

    init(resolver: AccessibilityTreeResolver, companionManager: CompanionManager) {
        self.resolver = resolver
        self.companionManager = companionManager
    }

    func call(_ arguments: JSONValue) async throws -> [MCPToolContent] {
        guard case .object(let dict) = arguments,
              case .string(let label) = dict["label"] ?? .null,
              !label.isEmpty
        else {
            throw MCPToolError.invalidArguments("click_element requires a non-empty `label` string")
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
        let bubble: String = {
            if case .string(let s) = dict["bubble"] ?? .null, !s.isEmpty { return s }
            return "clicking \(label)"
        }()
        let truncatedBubble = bubble.count > 120 ? String(bubble.prefix(120)) + "…" : bubble

        guard let resolved = resolver.findElement(byLabel: label, targetAppHint: appHint) else {
            throw MCPToolError.toolFailed("no UI element matching label \"\(label)\" was found")
        }

        let center = CGPoint(x: resolved.screenFrame.midX, y: resolved.screenFrame.midY)
        let displayFrame = NSScreen.screens.first(where: { $0.frame.contains(center) })?.frame
            ?? NSScreen.main?.frame
            ?? .zero

        // Trigger the visible flight by setting the @Published vars
        // OverlayWindow watches. Same path PointAtTool uses.
        companionManager.detectedElementScreenLocation = center
        companionManager.detectedElementDisplayFrame = displayFrame
        companionManager.detectedElementBubbleText = truncatedBubble

        // Let the bezier arc land before we post the click. Future work:
        // thread a cancellation token through so the user can abort by,
        // e.g., pressing Esc — see Plan 7 Task 8 follow-ups.
        try? await Task.sleep(nanoseconds: UInt64(preClickFlightSettleSeconds * 1_000_000_000))

        // Resolve the bundle ID → NSRunningApplication so ActionExecutor
        // can activate the right app before clicking. Without this the
        // click can land in the wrong window when the target app isn't
        // frontmost (Apple Forum 724835 — CGEventPostToPid is unreliable;
        // the HID path needs the target activated explicitly).
        let targetApp: NSRunningApplication? = {
            guard let bundleID = resolved.appBundleID else { return nil }
            return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        }()

        do {
            try await ActionExecutor.shared.click(
                atGlobalScreenPoint: center,
                activatingTargetApp: targetApp
            )
        } catch {
            companionManager.clearDetectedElementLocation()
            throw MCPToolError.toolFailed("click failed: \(error.localizedDescription)")
        }

        companionManager.clearDetectedElementLocation()

        return [.text("Clicked \"\(label)\" at \(Int(center.x)),\(Int(center.y))")]
    }
}
