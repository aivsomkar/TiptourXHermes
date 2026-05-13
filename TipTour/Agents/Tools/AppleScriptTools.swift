// TipTour/Agents/Tools/AppleScriptTools.swift

import AppKit
import Foundation

// MARK: - AppleScript Runner

/// Shared helper for executing AppleScript via NSAppleScript. NSAppleScript
/// is documented as main-thread-only — we hop to MainActor inside the
/// helper so callers can be on any actor.
///
/// Returns the descriptor's string value when the script produced one,
/// otherwise a short success message. Throws an `AppleScriptError` with
/// the human-readable error message NSAppleScript surfaces (which usually
/// includes the failing line and an Automation-permission hint when
/// macOS blocked the script).
enum AppleScriptRunner {

    static func run(_ source: String, timeoutSeconds: Double = 30) async throws -> String {
        // Execute on the main thread because NSAppleScript holds Apple
        // Event machinery that is not safe to drive concurrently. The
        // Task.detached + MainActor.run combo lets us also enforce a
        // wall-clock timeout — long-running scripts (e.g. ones that wait
        // on a page load) shouldn't pin the agent loop indefinitely.
        let resultTask = Task<String, Error> { @MainActor in
            try executeScriptOnMainThread(source)
        }

        // Race the result against a sleep. If the timeout wins, cancel
        // the script task. NSAppleScript itself doesn't have a kill
        // primitive, so the script will keep running silently in the
        // background until it finishes — but we stop waiting.
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await resultTask.value
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                throw AppleScriptError.timedOut(seconds: timeoutSeconds)
            }
            do {
                let first = try await group.next()!
                group.cancelAll()
                return first
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }

    @MainActor
    private static func executeScriptOnMainThread(_ source: String) throws -> String {
        guard let script = NSAppleScript(source: source) else {
            throw AppleScriptError.compilationFailed("NSAppleScript refused to construct from the supplied source.")
        }

        var errorDictionary: NSDictionary?
        let descriptor = script.executeAndReturnError(&errorDictionary)

        if let errorDictionary {
            let message = (errorDictionary[NSAppleScript.errorMessage] as? String) ?? "Unknown AppleScript error."
            let number = (errorDictionary[NSAppleScript.errorNumber] as? Int) ?? -1
            throw AppleScriptError.runtimeFailure(number: number, message: message)
        }

        // descriptor.stringValue is nil for scripts that returned a list,
        // record, number, etc. Coerce to a string description in those
        // cases so the agent gets *something* back.
        if let stringValue = descriptor.stringValue {
            return stringValue
        }
        if descriptor.numberOfItems > 0 {
            return String(describing: descriptor)
        }
        return "OK"
    }
}

enum AppleScriptError: Error, LocalizedError {
    case compilationFailed(String)
    case runtimeFailure(number: Int, message: String)
    case timedOut(seconds: Double)

    var errorDescription: String? {
        switch self {
        case .compilationFailed(let message):
            return "AppleScript compilation failed: \(message)"
        case .runtimeFailure(let number, let message):
            // Error -1743 is the "user did not grant permission" Automation error.
            // Surface that specifically because it's the most common failure mode
            // and the user has to fix it in System Settings → Privacy → Automation.
            if number == -1743 {
                return "AppleScript was blocked by macOS Automation permission. Grant TipTour permission for the target app in System Settings → Privacy & Security → Automation."
            }
            return "AppleScript failed (\(number)): \(message)"
        case .timedOut(let seconds):
            return "AppleScript timed out after \(Int(seconds))s. The script kept running in the background — we just stopped waiting on it."
        }
    }
}

// MARK: - Generic AppleScript Tool

/// Generic escape hatch for any AppleScript. Higher-level tools (like
/// `ChromeControlTool`) wrap this for specific apps; this tool is the
/// fallback when no specialized adapter exists for what the agent wants.
///
/// **Concurrency note**: AppleScript runs on its own Apple-Event channel,
/// not the GUI mutex, so two agents calling AppleScript against different
/// apps can genuinely run in parallel (e.g. one updates a Numbers
/// spreadsheet while another sends an iMessage). They only serialize when
/// targeting the same app's event loop.
struct AppleScriptTool: AgentTool {

    let name = "run_applescript"

    let description = """
        Run an AppleScript and return whatever the script produced. Use this \
        to drive any scriptable Mac app (Chrome, Safari, Finder, Mail, Messages, \
        Notes, Reminders, Calendar, Numbers, Pages, Keynote, Music, Photos, etc.) \
        WITHOUT moving the cursor — agents using this tool can run in parallel \
        with agents that DO use the cursor. \
        First-time use against an app triggers a macOS Automation permission \
        prompt; the user must approve once per app. 30 second timeout.
        """

    let parametersJSON = """
        {
            "type": "object",
            "properties": {
                "script": {
                    "type": "string",
                    "description": "The AppleScript source code to execute. Example: 'tell application \\"Finder\\" to return name of every window'"
                }
            },
            "required": ["script"]
        }
        """

    func execute(argumentsJSON: String) async -> String {
        do {
            let source = try parseScript(from: argumentsJSON)
            let result = try await AppleScriptRunner.run(source)
            return result.isEmpty ? "OK (no output)" : result
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }

    private func parseScript(from json: String) throws -> String {
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let source = dict["script"] as? String, !source.isEmpty else {
            throw ToolArgumentError.missingRequiredField("script")
        }
        return source
    }
}

// MARK: - Chrome Control Tool

/// Opinionated Chrome adapter. Wraps the most common Chrome AppleScript
/// operations behind a single tool with a discriminator so the LLM
/// doesn't have to hand-write `tell application "Google Chrome"` blocks
/// (and so we can sanitize input for the URL/script subcommands).
///
/// Operations:
///   - `open_url`            — open a URL in a new tab and focus it
///   - `current_url`         — get the URL of the active tab
///   - `current_title`       — get the title of the active tab
///   - `execute_javascript`  — run JS in the active tab, return the result
///   - `list_tabs`           — list all open tabs across all windows
///   - `close_active_tab`    — close the active tab in the frontmost window
///
/// `execute_javascript` requires "Allow JavaScript from Apple Events" to
/// be enabled in Chrome's View → Developer menu. If it's not, the script
/// returns a clear error and the agent knows to fall back to AX driving.
struct ChromeControlTool: AgentTool {

    let name = "chrome_control"

    let description = """
        Control Google Chrome without using the cursor. Pick one operation: \
        'open_url' (open URL in new tab), 'current_url', 'current_title', \
        'execute_javascript' (requires Chrome → View → Developer → Allow \
        JavaScript from Apple Events), 'list_tabs', 'close_active_tab'. \
        Runs in parallel with other agents that drive different apps. \
        First-time use prompts for Automation permission.
        """

    let parametersJSON = """
        {
            "type": "object",
            "properties": {
                "operation": {
                    "type": "string",
                    "enum": ["open_url", "current_url", "current_title", "execute_javascript", "list_tabs", "close_active_tab"],
                    "description": "Which Chrome operation to perform."
                },
                "url": {
                    "type": "string",
                    "description": "Required for 'open_url'. The URL to open (http:// or https://)."
                },
                "javascript": {
                    "type": "string",
                    "description": "Required for 'execute_javascript'. The JS source to run in the active tab. Returns whatever the JS expression evaluates to (truncated at 4KB)."
                }
            },
            "required": ["operation"]
        }
        """

    func execute(argumentsJSON: String) async -> String {
        do {
            let args = try parseArguments(from: argumentsJSON)
            let script = try buildScript(for: args)
            let result = try await AppleScriptRunner.run(script)
            return truncateForAgent(result)
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }

    // MARK: - Script builders

    private func buildScript(for args: ParsedArgs) throws -> String {
        switch args.operation {
        case "open_url":
            guard let url = args.url, !url.isEmpty,
                  url.hasPrefix("http://") || url.hasPrefix("https://") else {
                throw ToolArgumentError.invalidFieldValue(
                    field: "url",
                    reason: "open_url requires an http:// or https:// URL"
                )
            }
            // Escape any embedded double quotes so the AppleScript stays valid.
            let escaped = url.replacingOccurrences(of: "\"", with: "\\\"")
            return """
                tell application "Google Chrome"
                    activate
                    if (count of windows) = 0 then
                        make new window
                    end if
                    tell window 1
                        set newTab to make new tab with properties {URL:"\(escaped)"}
                        set active tab index to (count of tabs)
                    end tell
                    return "Opened \(escaped)"
                end tell
                """

        case "current_url":
            return """
                tell application "Google Chrome"
                    if (count of windows) = 0 then
                        return "No Chrome windows open"
                    end if
                    return URL of active tab of window 1
                end tell
                """

        case "current_title":
            return """
                tell application "Google Chrome"
                    if (count of windows) = 0 then
                        return "No Chrome windows open"
                    end if
                    return title of active tab of window 1
                end tell
                """

        case "execute_javascript":
            guard let js = args.javascript, !js.isEmpty else {
                throw ToolArgumentError.missingRequiredField("javascript")
            }
            // We can't safely string-escape JavaScript inside an AppleScript
            // literal because JS uses both single and double quotes. So we
            // pass the JS via the AppleScript clipboard pattern — set a
            // variable to the JS, then call `execute javascript`.
            let asLiteral = appleScriptStringLiteral(js)
            return """
                tell application "Google Chrome"
                    if (count of windows) = 0 then
                        return "No Chrome windows open"
                    end if
                    tell active tab of window 1
                        try
                            set jsResult to execute javascript \(asLiteral)
                            if jsResult is missing value then
                                return "(JS returned undefined / null)"
                            end if
                            return jsResult as text
                        on error errMsg number errNum
                            return "JS_ERROR (" & errNum & "): " & errMsg
                        end try
                    end tell
                end tell
                """

        case "list_tabs":
            return """
                tell application "Google Chrome"
                    set output to ""
                    set winIndex to 1
                    repeat with w in windows
                        set tabIndex to 1
                        repeat with t in tabs of w
                            set output to output & "Window " & winIndex & " Tab " & tabIndex & ": " & (title of t) & " — " & (URL of t) & linefeed
                            set tabIndex to tabIndex + 1
                        end repeat
                        set winIndex to winIndex + 1
                    end repeat
                    if output = "" then
                        return "No Chrome windows open"
                    end if
                    return output
                end tell
                """

        case "close_active_tab":
            return """
                tell application "Google Chrome"
                    if (count of windows) = 0 then
                        return "No Chrome windows open"
                    end if
                    set closedTitle to title of active tab of window 1
                    close active tab of window 1
                    return "Closed: " & closedTitle
                end tell
                """

        default:
            throw ToolArgumentError.invalidFieldValue(
                field: "operation",
                reason: "Unknown operation '\(args.operation)'. Valid: open_url, current_url, current_title, execute_javascript, list_tabs, close_active_tab"
            )
        }
    }

    /// Build a safe AppleScript double-quoted string literal — escapes
    /// backslash and double-quote, leaves everything else (including
    /// JavaScript's own single-quotes and JSON syntax) untouched.
    private func appleScriptStringLiteral(_ source: String) -> String {
        let escapedBackslashes = source.replacingOccurrences(of: "\\", with: "\\\\")
        let escapedQuotes = escapedBackslashes.replacingOccurrences(of: "\"", with: "\\\"")
        return "\"" + escapedQuotes + "\""
    }

    /// Cap the agent response at 4KB so a Chrome page that returns a
    /// giant JSON blob from `execute_javascript` doesn't blow out the
    /// LLM context window.
    private func truncateForAgent(_ result: String) -> String {
        let limit = 4_000
        if result.count <= limit { return result }
        return String(result.prefix(limit)) + "\n\n[Truncated — showing first \(limit) of \(result.count) characters]"
    }

    // MARK: - Argument parsing

    private struct ParsedArgs {
        let operation: String
        let url: String?
        let javascript: String?
    }

    private func parseArguments(from json: String) throws -> ParsedArgs {
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let operation = dict["operation"] as? String, !operation.isEmpty else {
            throw ToolArgumentError.missingRequiredField("operation")
        }
        return ParsedArgs(
            operation: operation,
            url: dict["url"] as? String,
            javascript: dict["javascript"] as? String
        )
    }
}

// MARK: - Safari Control Tool

/// Opinionated Safari adapter. Mirrors `ChromeControlTool`'s operation
/// set so the agent's mental model stays consistent across browsers:
///   - `open_url`            — open a URL in a new tab
///   - `current_url`         — get the URL of the active tab
///   - `current_title`       — get the title of the active tab
///   - `execute_javascript`  — run JS in the active tab (requires
///                             Safari → Develop → "Allow JavaScript
///                             from Apple Events")
///   - `list_tabs`           — list all open tabs across all windows
///   - `close_active_tab`    — close the active tab of the frontmost window
///
/// Safari's AppleScript dictionary differs from Chrome's: `do JavaScript`
/// instead of `execute javascript`, `URL` is set directly on a tab
/// instead of via `{URL: …}` at creation. This adapter handles the
/// differences so the agent doesn't have to.
struct SafariControlTool: AgentTool {

    let name = "safari_control"

    let description = """
        Control Apple Safari without using the cursor. Pick one operation: \
        'open_url' (open URL in new tab), 'current_url', 'current_title', \
        'execute_javascript' (requires Safari → Develop → "Allow JavaScript \
        from Apple Events" → ON), 'list_tabs', 'close_active_tab'. \
        Runs in parallel with other agents that drive different apps. \
        First-time use prompts for Automation permission.
        """

    let parametersJSON = """
        {
            "type": "object",
            "properties": {
                "operation": {
                    "type": "string",
                    "enum": ["open_url", "current_url", "current_title", "execute_javascript", "list_tabs", "close_active_tab"],
                    "description": "Which Safari operation to perform."
                },
                "url": {
                    "type": "string",
                    "description": "Required for 'open_url'. The URL to open (http:// or https://)."
                },
                "javascript": {
                    "type": "string",
                    "description": "Required for 'execute_javascript'. The JS source to run in the active tab."
                }
            },
            "required": ["operation"]
        }
        """

    func execute(argumentsJSON: String) async -> String {
        do {
            let args = try parseArguments(from: argumentsJSON)
            let script = try buildScript(for: args)
            let result = try await AppleScriptRunner.run(script)
            return truncateForAgent(result)
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }

    private func buildScript(for args: ParsedArgs) throws -> String {
        switch args.operation {
        case "open_url":
            guard let url = args.url, !url.isEmpty,
                  url.hasPrefix("http://") || url.hasPrefix("https://") else {
                throw ToolArgumentError.invalidFieldValue(
                    field: "url",
                    reason: "open_url requires an http:// or https:// URL"
                )
            }
            let escaped = url.replacingOccurrences(of: "\"", with: "\\\"")
            return """
                tell application "Safari"
                    activate
                    if (count of windows) = 0 then
                        make new document with properties {URL:"\(escaped)"}
                    else
                        tell window 1
                            set newTab to make new tab with properties {URL:"\(escaped)"}
                            set current tab to newTab
                        end tell
                    end if
                    return "Opened \(escaped)"
                end tell
                """

        case "current_url":
            return """
                tell application "Safari"
                    if (count of windows) = 0 then
                        return "No Safari windows open"
                    end if
                    return URL of current tab of window 1
                end tell
                """

        case "current_title":
            return """
                tell application "Safari"
                    if (count of windows) = 0 then
                        return "No Safari windows open"
                    end if
                    return name of current tab of window 1
                end tell
                """

        case "execute_javascript":
            guard let js = args.javascript, !js.isEmpty else {
                throw ToolArgumentError.missingRequiredField("javascript")
            }
            // Safari uses `do JavaScript`, not `execute javascript`.
            let asLiteral = appleScriptStringLiteral(js)
            return """
                tell application "Safari"
                    if (count of windows) = 0 then
                        return "No Safari windows open"
                    end if
                    try
                        set jsResult to do JavaScript \(asLiteral) in current tab of window 1
                        if jsResult is missing value then
                            return "(JS returned undefined / null)"
                        end if
                        return jsResult as text
                    on error errMsg number errNum
                        return "JS_ERROR (" & errNum & "): " & errMsg
                    end try
                end tell
                """

        case "list_tabs":
            return """
                tell application "Safari"
                    set output to ""
                    set winIndex to 1
                    repeat with w in windows
                        set tabIndex to 1
                        repeat with t in tabs of w
                            set output to output & "Window " & winIndex & " Tab " & tabIndex & ": " & (name of t) & " — " & (URL of t) & linefeed
                            set tabIndex to tabIndex + 1
                        end repeat
                        set winIndex to winIndex + 1
                    end repeat
                    if output = "" then
                        return "No Safari windows open"
                    end if
                    return output
                end tell
                """

        case "close_active_tab":
            return """
                tell application "Safari"
                    if (count of windows) = 0 then
                        return "No Safari windows open"
                    end if
                    set closedTitle to name of current tab of window 1
                    close current tab of window 1
                    return "Closed: " & closedTitle
                end tell
                """

        default:
            throw ToolArgumentError.invalidFieldValue(
                field: "operation",
                reason: "Unknown operation '\(args.operation)'. Valid: open_url, current_url, current_title, execute_javascript, list_tabs, close_active_tab"
            )
        }
    }

    private func appleScriptStringLiteral(_ source: String) -> String {
        let escapedBackslashes = source.replacingOccurrences(of: "\\", with: "\\\\")
        let escapedQuotes = escapedBackslashes.replacingOccurrences(of: "\"", with: "\\\"")
        return "\"" + escapedQuotes + "\""
    }

    private func truncateForAgent(_ result: String) -> String {
        let limit = 4_000
        if result.count <= limit { return result }
        return String(result.prefix(limit)) + "\n\n[Truncated — showing first \(limit) of \(result.count) characters]"
    }

    private struct ParsedArgs {
        let operation: String
        let url: String?
        let javascript: String?
    }

    private func parseArguments(from json: String) throws -> ParsedArgs {
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let operation = dict["operation"] as? String, !operation.isEmpty else {
            throw ToolArgumentError.missingRequiredField("operation")
        }
        return ParsedArgs(
            operation: operation,
            url: dict["url"] as? String,
            javascript: dict["javascript"] as? String
        )
    }
}

// MARK: - System Events Tool

/// Typed wrapper around the macOS **System Events** scripting interface.
/// System Events is built into every Mac and provides UI-scripting
/// access to every app, including ones with no AppleScript dictionary —
/// you can synthesize keystrokes, click menu bar items, query the
/// frontmost process, list windows, and more.
///
/// Why this exists alongside `run_applescript`: the generic tool needs
/// the agent to author correct AppleScript every time, including the
/// `tell application "System Events"` boilerplate and tricky quoting.
/// This typed wrapper exposes the operations agents need most often
/// with simple JSON arguments, and handles escaping internally.
///
/// First-time use against System Events triggers a macOS Automation
/// prompt distinct from per-target-app prompts (and is also separate
/// from Accessibility permission, which TipTour already has).
struct SystemEventsTool: AgentTool {

    let name = "system_events"

    let description = """
        Drive macOS via System Events — works on any app even without an \
        AppleScript dictionary. Pick one operation: 'keystroke' (type a \
        string into the focused element), 'key_code' (press a modifier+key \
        combo like Cmd+T), 'click_menu_item' (click File → Save type \
        sequences), 'frontmost_app' (name + bundle ID of the foreground app), \
        'list_processes' (every running app with UI). \
        First-time use prompts for Automation permission for System Events.
        """

    let parametersJSON = """
        {
            "type": "object",
            "properties": {
                "operation": {
                    "type": "string",
                    "enum": ["keystroke", "key_code", "click_menu_item", "frontmost_app", "list_processes"],
                    "description": "Which System Events operation to perform."
                },
                "text": {
                    "type": "string",
                    "description": "Required for 'keystroke'. The literal text to type into the focused element of the frontmost app."
                },
                "shortcut": {
                    "type": "string",
                    "description": "Required for 'key_code'. Modifier+key combo like 'cmd+t', 'cmd+shift+n', 'option+space', 'return', 'escape'."
                },
                "app_name": {
                    "type": "string",
                    "description": "Required for 'click_menu_item'. The exact process name (e.g. 'Safari', 'Google Chrome', 'Finder')."
                },
                "menu_path": {
                    "type": "array",
                    "items": { "type": "string" },
                    "description": "Required for 'click_menu_item'. Top-level → submenu → … → target item. Example: ['File', 'New Tab']."
                }
            },
            "required": ["operation"]
        }
        """

    func execute(argumentsJSON: String) async -> String {
        do {
            let args = try parseArguments(from: argumentsJSON)
            let script = try buildScript(for: args)
            let result = try await AppleScriptRunner.run(script)
            return result.isEmpty ? "OK" : result
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }

    // MARK: - Script builders

    private func buildScript(for args: ParsedArgs) throws -> String {
        switch args.operation {
        case "keystroke":
            guard let text = args.text, !text.isEmpty else {
                throw ToolArgumentError.missingRequiredField("text")
            }
            let escaped = appleScriptStringLiteral(text)
            // Synthesize the text into whatever app is frontmost.
            return """
                tell application "System Events"
                    keystroke \(escaped)
                end tell
                return "Typed \(text.count) character(s) via System Events"
                """

        case "key_code":
            guard let shortcut = args.shortcut, !shortcut.isEmpty else {
                throw ToolArgumentError.missingRequiredField("shortcut")
            }
            let (keyDescription, modifiers, keyToken) = try parseShortcutForSystemEvents(shortcut)
            let usingClause = modifiers.isEmpty
                ? ""
                : " using {\(modifiers.joined(separator: ", "))}"
            // For named keys (return, escape, tab, space, arrows) we use
            // `key code` with the Carbon virtual key number. For single
            // letters/digits, plain `keystroke` is more reliable than
            // remembering 26 key codes.
            let action: String
            if let keyCode = systemEventsKeyCode(forNamedKey: keyToken) {
                action = "key code \(keyCode)\(usingClause)"
            } else {
                let charLiteral = appleScriptStringLiteral(keyToken)
                action = "keystroke \(charLiteral)\(usingClause)"
            }
            return """
                tell application "System Events"
                    \(action)
                end tell
                return "Pressed \(keyDescription) via System Events"
                """

        case "click_menu_item":
            guard let appName = args.appName, !appName.isEmpty else {
                throw ToolArgumentError.missingRequiredField("app_name")
            }
            guard let menuPath = args.menuPath, !menuPath.isEmpty else {
                throw ToolArgumentError.missingRequiredField("menu_path")
            }
            // Build the nested menu path. menuPath = [topLevel, sub1, sub2, ...]
            // The TARGET to click is the last element; everything before
            // it just identifies which menu to open. We use System
            // Events' AX hierarchy: menu bar 1 → menu bar item "File" →
            // menu 1 → menu item "New Tab" → click.
            let appLiteral = appleScriptStringLiteral(appName)
            let topLevelLiteral = appleScriptStringLiteral(menuPath[0])
            let menuPathDescription = menuPath.joined(separator: " → ")

            if menuPath.count == 1 {
                // Just clicking a top-level menu bar item (rare).
                return """
                    tell application \(appLiteral) to activate
                    delay 0.2
                    tell application "System Events"
                        tell process \(appLiteral)
                            click menu bar item \(topLevelLiteral) of menu bar 1
                        end tell
                    end tell
                    return "Clicked \(menuPathDescription) via System Events"
                    """
            }

            // For deeper paths we descend explicitly. Build the inner
            // tell so each level's `menu` and `menu item` are nested
            // correctly. Walk from the target back to the top-level.
            var script = "tell application \(appLiteral) to activate\n"
            script += "delay 0.2\n"
            script += "tell application \"System Events\"\n"
            script += "    tell process \(appLiteral)\n"
            // Build nested chain: menu bar item → menu → menu item → (deeper menu) → click target
            var chain = "menu bar item \(topLevelLiteral) of menu bar 1"
            for index in 1..<menuPath.count {
                let segment = appleScriptStringLiteral(menuPath[index])
                if index < menuPath.count - 1 {
                    // Intermediate: open a submenu.
                    chain = "menu item \(segment) of menu 1 of \(chain)"
                } else {
                    // Final item to click.
                    chain = "menu item \(segment) of menu 1 of \(chain)"
                }
            }
            script += "        click \(chain)\n"
            script += "    end tell\n"
            script += "end tell\n"
            script += "return \"Clicked \(menuPathDescription) via System Events\"\n"
            return script

        case "frontmost_app":
            return """
                tell application "System Events"
                    set frontApp to first application process whose frontmost is true
                    set appName to name of frontApp
                    set appPid to unix id of frontApp
                end tell
                tell application "System Events"
                    tell application process appName
                        try
                            set bundleId to bundle identifier
                        on error
                            set bundleId to "(unknown)"
                        end try
                    end tell
                end tell
                return appName & " (pid " & appPid & ", " & bundleId & ")"
                """

        case "list_processes":
            return """
                tell application "System Events"
                    set output to ""
                    repeat with proc in (application processes whose background only is false)
                        try
                            set bundleId to bundle identifier of proc
                        on error
                            set bundleId to "(no bundle id)"
                        end try
                        set output to output & (name of proc) & " — " & bundleId & linefeed
                    end repeat
                    return output
                end tell
                """

        default:
            throw ToolArgumentError.invalidFieldValue(
                field: "operation",
                reason: "Unknown operation '\(args.operation)'. Valid: keystroke, key_code, click_menu_item, frontmost_app, list_processes"
            )
        }
    }

    // MARK: - Shortcut parsing

    /// Parse a shortcut string like "cmd+t" or "shift+option+return"
    /// into a System Events `using {...}` modifier list + the final key
    /// token. Returns the human-readable description for the result
    /// message and the AppleScript modifier strings.
    private func parseShortcutForSystemEvents(_ shortcut: String) throws -> (description: String, modifiers: [String], keyToken: String) {
        let tokens = shortcut
            .split(whereSeparator: { $0 == "+" || $0 == "-" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard !tokens.isEmpty else {
            throw ToolArgumentError.invalidFieldValue(field: "shortcut", reason: "shortcut was empty")
        }

        var modifiers: [String] = []
        var keyToken: String?

        for token in tokens {
            switch token.lowercased() {
            case "cmd", "command", "⌘":   modifiers.append("command down")
            case "opt", "option", "alt", "⌥": modifiers.append("option down")
            case "ctrl", "control", "⌃":  modifiers.append("control down")
            case "shift", "⇧":            modifiers.append("shift down")
            default:
                if keyToken != nil {
                    throw ToolArgumentError.invalidFieldValue(field: "shortcut", reason: "shortcut had two key tokens — only one non-modifier allowed")
                }
                keyToken = token
            }
        }

        guard let key = keyToken else {
            throw ToolArgumentError.invalidFieldValue(field: "shortcut", reason: "shortcut needs a key in addition to modifiers")
        }

        return (shortcut, modifiers, key)
    }

    /// Map common named keys to Carbon virtual key codes. Returns nil
    /// for letters/digits — those go through the `keystroke` path
    /// instead because System Events resolves them against the user's
    /// active keyboard layout.
    private func systemEventsKeyCode(forNamedKey token: String) -> Int? {
        switch token.lowercased() {
        case "return", "enter":   return 36
        case "tab":               return 48
        case "space":             return 49
        case "delete", "backspace": return 51
        case "escape", "esc":     return 53
        case "left":              return 123
        case "right":             return 124
        case "down":              return 125
        case "up":                return 126
        case "fwddelete", "forwarddelete": return 117
        case "home":              return 115
        case "end":               return 119
        case "pageup":            return 116
        case "pagedown":          return 121
        case "f1":                return 122
        case "f2":                return 120
        case "f3":                return 99
        case "f4":                return 118
        case "f5":                return 96
        case "f6":                return 97
        case "f7":                return 98
        case "f8":                return 100
        case "f9":                return 101
        case "f10":               return 109
        case "f11":               return 103
        case "f12":               return 111
        default:                  return nil
        }
    }

    // MARK: - Argument parsing

    private struct ParsedArgs {
        let operation: String
        let text: String?
        let shortcut: String?
        let appName: String?
        let menuPath: [String]?
    }

    private func parseArguments(from json: String) throws -> ParsedArgs {
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let operation = dict["operation"] as? String, !operation.isEmpty else {
            throw ToolArgumentError.missingRequiredField("operation")
        }
        return ParsedArgs(
            operation: operation,
            text: dict["text"] as? String,
            shortcut: dict["shortcut"] as? String,
            appName: dict["app_name"] as? String,
            menuPath: dict["menu_path"] as? [String]
        )
    }

    /// Escape a string for embedding in an AppleScript double-quoted
    /// literal. Same algorithm as the Chrome adapter — backslash first,
    /// then double-quote.
    private func appleScriptStringLiteral(_ source: String) -> String {
        let escapedBackslashes = source.replacingOccurrences(of: "\\", with: "\\\\")
        let escapedQuotes = escapedBackslashes.replacingOccurrences(of: "\"", with: "\\\"")
        return "\"" + escapedQuotes + "\""
    }
}
