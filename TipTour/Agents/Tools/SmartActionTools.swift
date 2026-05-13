// TipTour/Agents/Tools/SmartActionTools.swift

import AppKit
import Foundation

// MARK: - Smart Click

/// Single click tool that auto-picks the best channel for the target app:
///
///   - Chrome    → AppleScript via ChromeControlTool (no cursor, parallel)
///   - Safari    → AppleScript (no cursor, parallel)
///   - default   → AXPress (no cursor, parallel) with cursor-click fallback
///
/// Agents that don't care about the underlying channel should use this
/// tool. Agents that want a specific behaviour (visible cursor flight,
/// or strictly text-only Chrome scripting) can still call the lower-level
/// tools (`click_element`, `ax_press_element`, `chrome_control`) directly.
struct SmartClickTool: AgentTool {

    let name = "smart_click"

    let description = """
        Click an element using whichever method is most efficient for the \
        target app. Prefer this for general "click X" actions — it picks \
        AppleScript for Chrome/Safari (no cursor, parallel with other agents), \
        AXPress for everything else (no cursor when possible), and falls back \
        to a real cursor click only when no other channel works. Use \
        click_element directly if you specifically want the user to SEE the \
        cursor fly to the target.
        """

    let parametersJSON = """
        {
            "type": "object",
            "properties": {
                "label": {
                    "type": "string",
                    "description": "The exact visible/accessibility label of the element to click."
                },
                "app_hint": {
                    "type": "string",
                    "description": "Optional app name or bundle ID hint (e.g. 'Safari', 'com.google.Chrome'). Defaults to the frontmost app."
                }
            },
            "required": ["label"]
        }
        """

    func execute(argumentsJSON: String) async -> String {
        do {
            let args = try parseArguments(from: argumentsJSON)
            return try await dispatch(label: args.label, appHint: args.appHint)
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }

    // MARK: - Dispatch

    private func dispatch(label: String, appHint: String?) async throws -> String {
        let bundleID = try await resolveTargetBundleID(appHint: appHint)
        let channel = AppChannelRegistry.preferredClickChannel(forBundleID: bundleID)

        switch channel {
        case .chromeAppleScript:
            // Chrome's AppleScript dictionary doesn't have a generic
            // "click element by label" verb, so we fall back to AXPress
            // for the actual click. The Chrome adapter is preferred for
            // higher-level operations (open_url, execute_javascript).
            return try await pressViaAX(label: label, appHint: appHint, channelNote: "Chrome AXPress (AppleScript reserved for higher-level ops)")

        case .safariAppleScript:
            return try await pressViaAX(label: label, appHint: appHint, channelNote: "Safari AXPress (AppleScript reserved for higher-level ops)")

        case .appleScript:
            return try await pressViaAX(label: label, appHint: appHint, channelNote: "AXPress (generic AppleScript reserved for app-specific verbs)")

        case .axPress:
            return try await pressViaAX(label: label, appHint: appHint, channelNote: "AXPress")

        case .cursorClick:
            return try await clickViaCursor(label: label, appHint: appHint)
        }
    }

    private func pressViaAX(label: String, appHint: String?, channelNote: String) async throws -> String {
        guard AccessibilityTreeResolver.isPermissionGranted else {
            return "Error: TipTour does not have Accessibility permission."
        }
        let resolution: SmartClickResolution = try await MainActor.run {
            let resolver = AccessibilityTreeResolver()
            guard let element = resolver.findElement(byLabel: label, targetAppHint: appHint) else {
                throw SmartClickError.elementNotFound(label)
            }
            return SmartClickResolution(
                axUIElement: element.axUIElement,
                center: element.center,
                role: element.role
            )
        }

        let pressResult = AXUIElementPerformAction(resolution.axUIElement, kAXPressAction as CFString)
        if pressResult == .success {
            return "Pressed '\(label)' via \(channelNote)."
        }

        // AXPress not supported on this element — fall through to cursor click.
        try await ActionExecutor.shared.click(
            atGlobalScreenPoint: resolution.center,
            activatingTargetApp: nil
        )
        return "Pressed '\(label)' via cursor click (\(channelNote) was unavailable for this element)."
    }

    private func clickViaCursor(label: String, appHint: String?) async throws -> String {
        guard AccessibilityTreeResolver.isPermissionGranted else {
            return "Error: TipTour does not have Accessibility permission."
        }
        let center: CGPoint = try await MainActor.run {
            let resolver = AccessibilityTreeResolver()
            guard let element = resolver.findElement(byLabel: label, targetAppHint: appHint) else {
                throw SmartClickError.elementNotFound(label)
            }
            return element.center
        }
        try await ActionExecutor.shared.click(atGlobalScreenPoint: center, activatingTargetApp: nil)
        return "Clicked '\(label)' via cursor at (\(Int(center.x)), \(Int(center.y)))."
    }

    /// Resolve the target app's bundle ID from the hint, or fall back to
    /// whatever app is frontmost when no hint is supplied. The frontmost
    /// snapshot is taken from `AccessibilityTreeResolver.userTargetAppOverride`
    /// when set (voice mode keeps it pinned to the user's real target app)
    /// so we don't accidentally route to TipTour's own menu bar window.
    private func resolveTargetBundleID(appHint: String?) async throws -> String? {
        if let appHint, !appHint.isEmpty {
            // Hint can be either a bundle ID or a human-readable app name.
            // Bundle IDs always contain a dot — use that as a quick check.
            if appHint.contains(".") {
                return appHint
            }
            // Look up the bundle ID by app name via NSWorkspace.
            return await MainActor.run { () -> String? in
                let lowercasedHint = appHint.lowercased()
                let runningApps = NSWorkspace.shared.runningApplications
                for app in runningApps {
                    if let name = app.localizedName, name.lowercased() == lowercasedHint {
                        return app.bundleIdentifier
                    }
                }
                return nil
            }
        }
        return await MainActor.run {
            AccessibilityTreeResolver.userTargetAppOverride?.bundleIdentifier
                ?? AppChannelRegistry.frontmostBundleID()
        }
    }

    // MARK: - Types

    private struct SmartClickResolution {
        let axUIElement: AXUIElement
        let center: CGPoint
        let role: String
    }

    private struct ParsedArgs {
        let label: String
        let appHint: String?
    }

    private func parseArguments(from json: String) throws -> ParsedArgs {
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let label = dict["label"] as? String, !label.isEmpty else {
            throw ToolArgumentError.missingRequiredField("label")
        }
        return ParsedArgs(label: label, appHint: dict["app_hint"] as? String)
    }
}

private enum SmartClickError: Error, LocalizedError {
    case elementNotFound(String)
    var errorDescription: String? {
        switch self {
        case .elementNotFound(let label):
            return "No element with label '\(label)' found in the accessibility tree. Run read_ax_tree to see available elements."
        }
    }
}
