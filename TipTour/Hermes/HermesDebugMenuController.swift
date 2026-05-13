// TipTour/Hermes/HermesDebugMenuController.swift
//
// Owns the second menu-bar status item ("Hermes" with a debug menu)
// and the floating chat window. The HermesClient + in-process MCPServer
// are shared with the voice loop and OWNED by CompanionManager — this
// controller just holds references.

import AppKit

@MainActor
final class HermesDebugMenuController: NSObject, NSWindowDelegate {
    private var statusItem: NSStatusItem?
    private var window: NSWindow?
    private let client: HermesClient
    private let mcpServer: MCPServer
    private weak var companionManager: CompanionManager?
    private var globalMonitor: Any?
    private var localMonitor: Any?

    init(client: HermesClient, mcpServer: MCPServer) {
        self.client = client
        self.mcpServer = mcpServer
        super.init()
    }

    func install(companionManager: CompanionManager) {
        self.companionManager = companionManager

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "🛠 Hermes"
        item.button?.toolTip = "Hermes Debug"

        let menu = NSMenu()

        let header = NSMenuItem(title: "Hermes Debug", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let talk = NSMenuItem(title: "Talk to Hermes…", action: #selector(openChat), keyEquivalent: "h")
        talk.keyEquivalentModifierMask = [.option, .shift]
        talk.target = self
        menu.addItem(talk)

        item.menu = menu
        self.statusItem = item

        installGlobalShortcut()
    }

    // MARK: - Global ⌥⇧H shortcut

    /// Installs both a global and a local NSEvent monitor for ⌥⇧H so the
    /// chat window opens whether or not TipTour has focus.
    ///
    /// Known gotcha: global NSEvent monitors are observe-only — they can't
    /// swallow events. Pressing ⌥⇧H inside a text field in another app will
    /// open our chat AND insert whatever glyph that chord types in the
    /// current keyboard layout (Ó in US English; varies elsewhere). If this
    /// gets annoying, switch to a chord that doesn't produce a glyph
    /// (e.g. ⌃⌥H) by editing isShortcut(_:).
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
                return nil
            }
            return event
        }
    }

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
            let w = makeHermesChatWindow(client: client)
            w.delegate = self
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - NSWindowDelegate

    /// Closing the chat window must NOT terminate the Hermes subprocess
    /// — it's shared with the voice path. Just drop the window reference
    /// so a future openChat() builds a fresh window pointing at the same
    /// HermesClient.
    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === window else { return }
        window = nil
    }
}
