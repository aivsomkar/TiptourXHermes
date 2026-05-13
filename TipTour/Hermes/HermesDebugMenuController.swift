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

        let talk = NSMenuItem(title: "Talk to Hermes…", action: #selector(openChat), keyEquivalent: "h")
        talk.keyEquivalentModifierMask = [.command, .shift]
        talk.target = self
        menu.addItem(talk)

        item.menu = menu
        self.statusItem = item
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
