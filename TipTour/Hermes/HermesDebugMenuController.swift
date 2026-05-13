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

        // Menu hint shows "⌥Space" next to the item. The real activation
        // path is the global event monitor installed below — NSMenuItem
        // key equivalents only fire when the app is active, and a menu-
        // bar-only LSUIElement app rarely is.
        let talk = NSMenuItem(title: "Talk to Hermes…", action: #selector(openChat), keyEquivalent: " ")
        talk.keyEquivalentModifierMask = [.option]
        talk.target = self
        menu.addItem(talk)

        item.menu = menu
        self.statusItem = item

        installGlobalShortcut()
    }

    // MARK: - Global ⌥+Space shortcut

    /// Installs both a global and a local NSEvent monitor for ⌥+Space.
    /// Global fires when another app is focused; local fires when we are
    /// focused (and lets us swallow the keystroke so it doesn't also
    /// insert a non-breaking space).
    ///
    /// Side note: pressing ⌥+Space inside text fields in OTHER apps
    /// will both open our chat AND insert a non-breaking space — global
    /// monitors are observe-only and can't swallow events. If that
    /// annoys you, switch to a less common chord (e.g. ⌃⌥H) by editing
    /// the modifier/key check in handleEvent(_:).
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
                return nil   // swallow so it doesn't also fire as a typed space
            }
            return event
        }
    }

    /// ⌥+Space with no other modifiers and the space key (keyCode 49).
    private static func isShortcut(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return event.keyCode == 49 && mods == [.option]
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
