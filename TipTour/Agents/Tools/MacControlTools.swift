// TipTour/Agents/Tools/MacControlTools.swift

import AppKit
import Foundation

// MARK: - Read AX Tree

/// Returns a compact set-of-marks listing from the frontmost app's accessibility tree.
/// The output lists interactive elements by role + label, which the agent can reference
/// by label in a follow-up ClickElementTool call.
struct ReadAXTreeTool: AgentTool {

    let name = "read_ax_tree"

    let description = """
        Read the accessibility tree of the currently frontmost macOS app. \
        Returns a list of interactive elements (buttons, text fields, menus, etc.) \
        with their labels. Use these labels with click_element to interact with the UI.
        """

    let parametersJSON = """
        {
            "type": "object",
            "properties": {
                "app_hint": {
                    "type": "string",
                    "description": "Optional app name or bundle ID hint (e.g. 'Safari', 'com.apple.safari'). Defaults to the frontmost app."
                }
            },
            "required": []
        }
        """

    func execute(argumentsJSON: String) async -> String {
        guard AccessibilityTreeResolver.isPermissionGranted else {
            return "Error: TipTour does not have Accessibility permission. Grant it in System Settings → Privacy & Security → Accessibility."
        }

        let appHint = parseAppHint(from: argumentsJSON)

        let resolver = AccessibilityTreeResolver()
        guard let marks = resolver.setOfMarksForTargetApp(hint: appHint) else {
            return "No accessibility elements found for the current app. The app may not expose accessibility data."
        }

        let formatted = AccessibilityTreeResolver.formatMarks(marks)
        return "Accessibility elements:\n\(formatted)"
    }

    private func parseAppHint(from json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return dict["app_hint"] as? String
    }
}

// MARK: - Click Element

/// Resolves a UI element by label using the macOS accessibility tree,
/// then clicks its center point using ActionExecutor (which posts CGEvents at HID level).
struct ClickElementTool: AgentTool {

    let name = "click_element"

    let description = """
        Click a UI element in the frontmost macOS app by its accessibility label. \
        Use read_ax_tree first to get the exact label string. \
        TipTour must have Accessibility permission for this to work.
        """

    let parametersJSON = """
        {
            "type": "object",
            "properties": {
                "label": {
                    "type": "string",
                    "description": "The exact accessibility label of the element to click (from read_ax_tree output)."
                },
                "app_hint": {
                    "type": "string",
                    "description": "Optional app name hint to narrow the search (e.g. 'Safari')."
                }
            },
            "required": ["label"]
        }
        """

    func execute(argumentsJSON: String) async -> String {
        do {
            let args = try parseArguments(from: argumentsJSON)
            return try await performClick(label: args.label, appHint: args.appHint)
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }

    private func performClick(label: String, appHint: String?) async throws -> String {
        guard AccessibilityTreeResolver.isPermissionGranted else {
            throw ClickToolError.noAccessibilityPermission
        }

        // AX lookup is synchronous — resolve the element center on MainActor.
        let center: CGPoint = try await MainActor.run {
            let resolver = AccessibilityTreeResolver()
            guard let element = resolver.findElement(byLabel: label, targetAppHint: appHint) else {
                throw ClickToolError.elementNotFound(label)
            }
            return element.center
        }

        // ActionExecutor.shared is @MainActor — awaiting it hops back to MainActor automatically.
        try await ActionExecutor.shared.click(
            atGlobalScreenPoint: center,
            activatingTargetApp: nil
        )

        return "Clicked '\(label)' at (\(Int(center.x)), \(Int(center.y)))"
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

// MARK: - Click errors

private enum ClickToolError: Error, LocalizedError {
    case elementNotFound(String)
    case noAccessibilityPermission

    var errorDescription: String? {
        switch self {
        case .elementNotFound(let label):
            return "No element with label '\(label)' found in the accessibility tree. Run read_ax_tree to see available elements."
        case .noAccessibilityPermission:
            return "TipTour does not have Accessibility permission. Grant it in System Settings → Privacy & Security → Accessibility."
        }
    }
}

// MARK: - AX Press (cursor-free click)

/// Invokes the accessibility "press" action on an element — the same
/// pathway VoiceOver and Switch Control use. Unlike `ClickElementTool`,
/// this does NOT move the cursor or post CGEvents at the HID layer, so:
///
///   - It does not require the target app to be frontmost.
///   - It does not contend with the GUI mutex — multiple agents can
///     AXPress different apps simultaneously.
///   - It cannot type, drag, or scroll; only "press" (button click,
///     menu item activate, link follow, checkbox toggle).
///
/// Falls back to a regular cursor click when the element doesn't
/// implement the press action — most native Mac apps and well-built
/// Electron apps support it; some custom UIKit-on-Mac / canvas-rendered
/// surfaces don't.
struct AXPressElementTool: AgentTool {

    let name = "ax_press_element"

    let description = """
        Click a UI element by its accessibility label WITHOUT moving the \
        cursor or stealing keyboard focus. Use this when you want to act \
        on a button/link/menu item silently — for example, when another \
        agent is using the cursor in a different app, or when you want to \
        keep the user's current focus undisturbed. Works on standard \
        macOS controls (buttons, menus, links, checkboxes); silently falls \
        back to a real cursor click if the element doesn't expose a press \
        action.
        """

    let parametersJSON = """
        {
            "type": "object",
            "properties": {
                "label": {
                    "type": "string",
                    "description": "The exact accessibility label of the element (from read_ax_tree output)."
                },
                "app_hint": {
                    "type": "string",
                    "description": "Optional app name or bundle ID hint (e.g. 'Safari', 'com.google.Chrome')."
                }
            },
            "required": ["label"]
        }
        """

    func execute(argumentsJSON: String) async -> String {
        do {
            let args = try parseArguments(from: argumentsJSON)
            return try await performPress(label: args.label, appHint: args.appHint)
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }

    private func performPress(label: String, appHint: String?) async throws -> String {
        guard AccessibilityTreeResolver.isPermissionGranted else {
            return "Error: TipTour does not have Accessibility permission."
        }

        // AX lookup happens on the main actor (matches ClickElementTool's pattern).
        let resolution: AXPressResolution = try await MainActor.run {
            let resolver = AccessibilityTreeResolver()
            guard let element = resolver.findElement(byLabel: label, targetAppHint: appHint) else {
                throw AXPressToolError.elementNotFound(label)
            }
            return AXPressResolution(
                axUIElement: element.axUIElement,
                center: element.center,
                role: element.role
            )
        }

        // Try AXPress first. If it returns anything other than .success
        // OR .actionUnsupported, log it but still fall back to a cursor
        // click so the agent has a fighting chance to land the action.
        let pressResult = AXUIElementPerformAction(
            resolution.axUIElement,
            kAXPressAction as CFString
        )

        if pressResult == .success {
            return "AXPressed '\(label)' (\(resolution.role)) — cursor untouched."
        }

        // Fall back to a real click so we don't strand the agent on apps
        // that don't expose AXPress. This DOES grab the cursor / mutex.
        try await ActionExecutor.shared.click(
            atGlobalScreenPoint: resolution.center,
            activatingTargetApp: nil
        )
        return "AXPress unsupported for '\(label)' (\(resolution.role)) — fell back to cursor click."
    }

    private struct AXPressResolution {
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

private enum AXPressToolError: Error, LocalizedError {
    case elementNotFound(String)
    var errorDescription: String? {
        switch self {
        case .elementNotFound(let label):
            return "No element with label '\(label)' found in the accessibility tree. Run read_ax_tree to see available elements."
        }
    }
}

// MARK: - Type Text

/// Types a string into whichever text field the frontmost app currently
/// has focus on, using ActionExecutor's paste-based path (layout-agnostic,
/// fast for long strings, restores the previous clipboard contents).
///
/// All synthetic input runs through GUIActionMutex so two agents can't
/// interleave keystrokes mid-string.
struct TypeTextTool: AgentTool {

    let name = "type_text"

    let description = """
        Type text into the currently focused field of the frontmost macOS app. \
        You must click a text field first (with click_element) so it has \
        keyboard focus — this tool does NOT find or focus a field for you. \
        Restores the user's clipboard contents after typing. Do NOT use this \
        on password fields or other secure-text inputs.
        """

    let parametersJSON = """
        {
            "type": "object",
            "properties": {
                "text": {
                    "type": "string",
                    "description": "The exact text to type, character-for-character. No translation, no quoting."
                }
            },
            "required": ["text"]
        }
        """

    func execute(argumentsJSON: String) async -> String {
        do {
            let text = try parseText(from: argumentsJSON)
            try await ActionExecutor.shared.typeText(text, activatingTargetApp: nil)
            return "Typed \(text.count) characters."
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }

    private func parseText(from json: String) throws -> String {
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = dict["text"] as? String else {
            throw ToolArgumentError.missingRequiredField("text")
        }
        // Empty string is technically valid (a no-op), but it's almost
        // certainly an LLM mistake — surface it as an error so the
        // agent can self-correct rather than silently succeeding.
        if text.isEmpty {
            throw ToolArgumentError.invalidFieldValue(
                field: "text",
                reason: "text must be non-empty"
            )
        }
        return text
    }
}

// MARK: - Press Keyboard Shortcut

/// Presses a single keyboard shortcut against the frontmost app via
/// ActionExecutor — same parser the voice-mode WorkflowRunner uses, so
/// `Cmd+S`, `Cmd+Shift+N`, `Cmd+Space`, `Return`, etc. all work.
struct PressKeyboardShortcutTool: AgentTool {

    let name = "press_keyboard_shortcut"

    let description = """
        Press a keyboard shortcut combination (e.g. "Cmd+S", "Cmd+Space", \
        "Return", "Escape", "Cmd+Shift+T") against the frontmost macOS app. \
        Use Cmd+Space + typing for Spotlight workflows like opening an app. \
        Recognized modifiers: Cmd / Command, Opt / Option / Alt, Ctrl / Control, \
        Shift, Fn. Recognized keys: letters, digits, Space, Return, Tab, Escape, \
        Delete, Left/Right/Up/Down, Home, End, PageUp, PageDown, F1-F12.
        """

    let parametersJSON = """
        {
            "type": "object",
            "properties": {
                "shortcut": {
                    "type": "string",
                    "description": "Shortcut combo as a '+'-joined string. Examples: 'Cmd+S', 'Cmd+Shift+N', 'Cmd+Space', 'Return', 'Escape'."
                }
            },
            "required": ["shortcut"]
        }
        """

    func execute(argumentsJSON: String) async -> String {
        do {
            let shortcut = try parseShortcut(from: argumentsJSON)
            try await ActionExecutor.shared.pressKeyboardShortcut(shortcut, activatingTargetApp: nil)
            return "Pressed '\(shortcut)'."
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }

    private func parseShortcut(from json: String) throws -> String {
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let shortcut = dict["shortcut"] as? String,
              !shortcut.isEmpty else {
            throw ToolArgumentError.missingRequiredField("shortcut")
        }
        return shortcut
    }
}

// MARK: - Open URL

/// Opens a URL in the user's default browser via `NSWorkspace.shared.open`.
/// Optionally targets a specific browser by bundle id ("com.google.Chrome",
/// "com.apple.Safari") so agents can isolate their work to a specific
/// browser instance.
///
/// This is the agent's entry point into the web — combined with read_ax_tree
/// + click_element + type_text + press_keyboard_shortcut it can drive a
/// real visible browser window the user can watch.
struct OpenURLTool: AgentTool {

    let name = "open_url"

    let description = """
        Open a URL in a visible browser window. Returns once the browser \
        has been asked to open the URL (does NOT wait for the page to load). \
        Use the optional 'browser_bundle_id' argument to target a specific \
        browser (e.g. 'com.google.Chrome' to keep work in Chrome, \
        'com.apple.Safari' for Safari). Omit it to use the user's default browser.
        """

    let parametersJSON = """
        {
            "type": "object",
            "properties": {
                "url": {
                    "type": "string",
                    "description": "The URL to open (must be http:// or https://)."
                },
                "browser_bundle_id": {
                    "type": "string",
                    "description": "Optional macOS bundle id of the browser to use. Examples: 'com.google.Chrome', 'com.apple.Safari', 'com.microsoft.edgemac', 'company.thebrowser.Browser' (Arc)."
                }
            },
            "required": ["url"]
        }
        """

    func execute(argumentsJSON: String) async -> String {
        do {
            let args = try parseArguments(from: argumentsJSON)
            return try await openURL(args.url, browserBundleId: args.browserBundleId)
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }

    private func openURL(_ urlString: String, browserBundleId: String?) async throws -> String {
        guard let url = URL(string: urlString),
              url.scheme == "http" || url.scheme == "https" else {
            return "Error: '\(urlString)' is not a valid http/https URL."
        }

        if let browserBundleId,
           let browserURL = await MainActor.run(body: {
               NSWorkspace.shared.urlForApplication(withBundleIdentifier: browserBundleId)
           }) {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            _ = try await NSWorkspace.shared.open(
                [url],
                withApplicationAt: browserURL,
                configuration: configuration
            )
            return "Opened \(urlString) in \(browserBundleId)."
        }

        // Default-browser fallback.
        let didOpen = await MainActor.run { NSWorkspace.shared.open(url) }
        if didOpen {
            return "Opened \(urlString) in the default browser."
        }
        return "Error: NSWorkspace refused to open \(urlString). The URL may be malformed or no app is registered for its scheme."
    }

    private struct ParsedArgs {
        let url: String
        let browserBundleId: String?
    }

    private func parseArguments(from json: String) throws -> ParsedArgs {
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let urlString = dict["url"] as? String, !urlString.isEmpty else {
            throw ToolArgumentError.missingRequiredField("url")
        }
        return ParsedArgs(url: urlString, browserBundleId: dict["browser_bundle_id"] as? String)
    }
}
