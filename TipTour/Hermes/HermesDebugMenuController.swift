// TipTour/Hermes/HermesDebugMenuController.swift
//
// Owns the second menu-bar status item ("Hermes" with a debug menu),
// the floating chat window, a single HermesClient instance, and the
// in-process MCPServer that exposes Mac-side tools (Plan 3a: speak;
// Plan 3b adds take_screenshot / get_a11y_tree / point_at).

import AppKit

@MainActor
final class HermesDebugMenuController: NSObject, NSWindowDelegate {
    private var statusItem: NSStatusItem?
    private var window: NSWindow?
    private let client = HermesClient()
    private let mcpServer = MCPServer(name: "tiptour-tools")
    private var globalMonitor: Any?
    private var localMonitor: Any?

    func install() {
        // Register tools once. The server doesn't bind a port until
        // openChat() — we want the loopback port allocated on demand
        // and freed when the chat window closes.
        mcpServer.register(SpeakTool())

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "🛠 Hermes"
        item.button?.toolTip = "Hermes Debug"

        let menu = NSMenu()

        let header = NSMenuItem(title: "Hermes Debug", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        // Menu hint shows "⌥⇧H" next to the item. The real activation
        // path is the global event monitor installed below — NSMenuItem
        // key equivalents only fire when the app is active, and a menu-
        // bar-only LSUIElement app rarely is.
        let talk = NSMenuItem(title: "Talk to Hermes…", action: #selector(openChat), keyEquivalent: "h")
        talk.keyEquivalentModifierMask = [.option, .shift]
        talk.target = self
        menu.addItem(talk)

        item.menu = menu
        self.statusItem = item

        installGlobalShortcut()
    }

    // MARK: - Global ⌥+Space shortcut

    /// Installs both a global and a local NSEvent monitor for ⌥⇧H.
    /// Global fires when another app is focused; local fires when we are
    /// focused (and lets us swallow the keystroke so it doesn't also
    /// type a special character).
    ///
    /// Side note: pressing ⌥⇧H inside text fields in OTHER apps will
    /// both open our chat AND insert whatever character that chord types
    /// in the current keyboard layout (Ó in US English, varies elsewhere).
    /// Global monitors are observe-only and can't swallow events. If
    /// that becomes annoying, switch to a chord that doesn't produce
    /// a glyph (e.g. ⌃⌥H) by editing isShortcut(_:).
    private func installGlobalShortcut() {
        let handler: (NSEvent) -> Void = { [weak self] event in
            self?.handleEvent(event)
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            handler(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if Self.isShortcut(event) {
                handler(event)
                return nil   // swallow so it doesn't also type a glyph
            }
            return event
        }
    }

    /// ⌥⇧H with no other modifiers. The H key is keyCode 4. We compare
    /// modifierFlags & deviceIndependentFlagsMask against exactly
    /// [.option, .shift] so chords like ⌥⇧⌘H don't accidentally match.
    private static func isShortcut(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return event.keyCode == 4 && mods == [.option, .shift]
    }

    private func handleEvent(_ event: NSEvent) {
        guard Self.isShortcut(event) else { return }
        openChat()
    }

    @objc private func openChat() {
        if window == nil {
            do {
                let url = try mcpServer.start()
                client.mcpServerURL = url
                NSLog("[Hermes] MCP server up at %@", url.absoluteString)
            } catch {
                NSLog("[Hermes] MCP server failed to start: %@; chat opens without tools", "\(error)")
                client.mcpServerURL = nil
            }
            let w = makeHermesChatWindow(client: client)
            w.delegate = self
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - NSWindowDelegate

    /// Fires for every close path (red X, ⌘W, programmatic `close()`,
    /// `orderOut:`-on-close, etc).
    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === window else { return }
        NSLog("[HermesDebugMenuController] windowWillClose — terminating Hermes + MCP server")
        client.stop()
        mcpServer.stop()
        client.mcpServerURL = nil
        window = nil
    }
}
