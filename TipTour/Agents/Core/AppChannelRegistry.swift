// TipTour/Agents/Core/AppChannelRegistry.swift

import AppKit
import Foundation

/// One specific way an agent can issue an action against an app.
/// Channels are ranked per-app by `AppChannelRegistry.preferredChannels`
/// so agents pick the lowest-friction option that still works.
enum AppActionChannel: String, CaseIterable, Sendable {
    /// Drive Chrome via its AppleScript dictionary. No cursor, fully
    /// parallel with other agents driving different apps. Only valid
    /// for Chrome.
    case chromeAppleScript

    /// Drive Safari via its AppleScript dictionary. Same parallelism
    /// benefits as Chrome's; only valid for Safari.
    case safariAppleScript

    /// Generic AppleScript against any scriptable app. The fallback
    /// scriptable channel when we don't have a specialized adapter.
    case appleScript

    /// Invoke kAXPressAction on the resolved AX element. No cursor,
    /// parallel-friendly. Works on most native + Electron apps.
    case axPress

    /// Synthetic cursor click via CGEvent. Visible to the user, takes
    /// the GUI mutex, exclusive of other CGEvent callers.
    case cursorClick
}

/// Static registry mapping bundle ID → ordered list of channels the
/// agent should try in priority order. The first channel in the list
/// that's actually applicable to the action (e.g. you can only AppleScript
/// a scriptable app) is the one we use.
///
/// This is intentionally a hardcoded table — the list of apps we have
/// good adapters for is small, well-known, and changes rarely. A future
/// version could let users override entries via UserDefaults, but for
/// now baking the table in keeps the cost zero and the behavior
/// inspectable from source.
enum AppChannelRegistry {

    /// Channels in preferred order for the given bundle ID. The caller
    /// filters this list down to channels that are valid for the action
    /// they want (e.g. AppleScript supports a focused set of verbs;
    /// AXPress works on any clickable element).
    static func preferredChannels(forBundleID bundleID: String?) -> [AppActionChannel] {
        guard let bundleID else {
            return defaultRanking
        }
        return customRankings[bundleID.lowercased()] ?? defaultRanking
    }

    /// Best-channel shortcut for the common "I want to click element X" case.
    /// Returns the highest-priority channel that supports the click verb.
    static func preferredClickChannel(forBundleID bundleID: String?) -> AppActionChannel {
        let ranking = preferredChannels(forBundleID: bundleID)
        for channel in ranking where channelSupportsClick(channel) {
            return channel
        }
        return .cursorClick
    }

    /// Whether the given channel can execute a "click-like" action
    /// (button press, link follow, menu item activate). Used by the
    /// click-dispatch path to filter the per-app ranking.
    static func channelSupportsClick(_ channel: AppActionChannel) -> Bool {
        switch channel {
        case .chromeAppleScript, .safariAppleScript, .appleScript:
            // AppleScript can drive these apps without a real click —
            // but for arbitrary "click any element" semantics we'd need
            // to know the element's selector or AX path. For now we
            // treat AppleScript as click-capable ONLY for the dedicated
            // adapters (Chrome, Safari) where we have richer adapters.
            return channel != .appleScript
        case .axPress:
            return true
        case .cursorClick:
            return true
        }
    }

    /// The bundle ID of the user's currently-frontmost app, snapshotted
    /// from `NSWorkspace`. The agent's tool dispatchers use this when
    /// the LLM didn't pass an explicit app_hint.
    @MainActor
    static func frontmostBundleID() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    // MARK: - Tables

    /// Apps we have dedicated AppleScript adapters for. Their preferred
    /// ranking puts the adapter first, then AX as a fallback.
    private static let customRankings: [String: [AppActionChannel]] = [
        // Chrome family (uses Chrome's AppleScript dictionary). Brave
        // and Edge inherit it; Arc has its own dictionary so it gets
        // generic AppleScript routing.
        "com.google.chrome":           [.chromeAppleScript, .axPress, .cursorClick],
        "com.google.chrome.canary":    [.chromeAppleScript, .axPress, .cursorClick],
        "com.google.chrome.beta":      [.chromeAppleScript, .axPress, .cursorClick],
        "com.google.chrome.dev":       [.chromeAppleScript, .axPress, .cursorClick],
        "com.brave.browser":           [.chromeAppleScript, .axPress, .cursorClick],
        "com.microsoft.edgemac":       [.chromeAppleScript, .axPress, .cursorClick],
        "com.microsoft.edgemac.beta":  [.chromeAppleScript, .axPress, .cursorClick],
        "com.microsoft.edgemac.dev":   [.chromeAppleScript, .axPress, .cursorClick],
        "com.vivaldi.vivaldi":         [.chromeAppleScript, .axPress, .cursorClick],

        // Safari family.
        "com.apple.safari":            [.safariAppleScript, .axPress, .cursorClick],
        "com.apple.SafariTechnologyPreview": [.safariAppleScript, .axPress, .cursorClick],

        // Other browsers (Arc, Firefox) — own dictionaries or limited
        // AppleScript support. Route to generic AppleScript first; AX
        // and cursor click fall back if the agent's AppleScript fails.
        "company.thebrowser.Browser":  [.appleScript, .axPress, .cursorClick],   // Arc
        "org.mozilla.firefox":         [.axPress, .cursorClick],                  // Firefox AppleScript is minimal
        "org.mozilla.firefoxdeveloperedition": [.axPress, .cursorClick],

        // Scriptable Apple-native apps where the generic AppleScriptTool
        // is the parallel-friendly option but we don't have a typed
        // adapter for them yet. Listed here for completeness; the
        // SmartActionTool will route arbitrary AppleScript through
        // `run_applescript` for these.
        "com.apple.finder":          [.appleScript, .axPress, .cursorClick],
        "com.apple.mail":            [.appleScript, .axPress, .cursorClick],
        "com.apple.messages":        [.appleScript, .axPress, .cursorClick],
        "com.apple.notes":           [.appleScript, .axPress, .cursorClick],
        "com.apple.reminders":       [.appleScript, .axPress, .cursorClick],
        "com.apple.iCal":            [.appleScript, .axPress, .cursorClick],
        "com.apple.iWork.Numbers":   [.appleScript, .axPress, .cursorClick],
        "com.apple.iWork.Pages":     [.appleScript, .axPress, .cursorClick],
        "com.apple.iWork.Keynote":   [.appleScript, .axPress, .cursorClick]
    ]

    /// Default ranking for apps with no specialized adapter — try the
    /// cursor-free AX path first, fall back to cursor click.
    private static let defaultRanking: [AppActionChannel] = [
        .axPress,
        .cursorClick
    ]
}
