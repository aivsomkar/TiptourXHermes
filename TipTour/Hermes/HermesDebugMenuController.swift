// TipTour/Hermes/HermesDebugMenuController.swift
//
// Owns the second menu-bar status item ("Hermes" with a debug menu)
// plus the chat window and a single HermesClient instance. Standalone
// from MenuBarPanelManager so it can be removed cleanly when Plan 3
// folds Hermes into the user-facing surface.

import AppKit

@MainActor
final class HermesDebugMenuController: NSObject {
    private var statusItem: NSStatusItem?
    private var window: NSWindow?
    private let client = HermesClient()

    func install() {
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
            window = makeHermesChatWindow(client: client) { [weak self] in
                // windowWillClose: terminate subprocess so closing the
                // window actually frees ~400 MB of Python runtime.
                self?.client.stop()
                self?.window = nil
            }
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
