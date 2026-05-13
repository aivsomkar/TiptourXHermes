//
//  TipTourApp.swift
//  TipTour
//
//  Menu bar-only companion app. No dock icon, no main window — just an
//  always-available status item in the macOS menu bar. Clicking the icon
//  opens a floating panel with companion voice controls.
//

import AVFoundation
import ServiceManagement
import SwiftUI

@main
struct TipTour_HermesApp: App {
    @NSApplicationDelegateAdaptor(CompanionAppDelegate.self) var appDelegate

    var body: some Scene {
        // The app lives entirely in the menu bar panel managed by the AppDelegate.
        // This empty Settings scene satisfies SwiftUI's requirement for at least
        // one scene but is never shown (LSUIElement=true removes the app menu).
        Settings {
            EmptyView()
        }
    }
}

/// Manages the companion lifecycle: creates the menu bar panel and starts
/// the companion voice pipeline on launch.
@MainActor
final class CompanionAppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarPanelManager: MenuBarPanelManager?
    private var hermesDebugMenu: HermesDebugMenuController?
    // agentOverlayWindowController removed with Overlay/ strip
    private let companionManager = CompanionManager()
    /// Held as a stored property so the player isn't deallocated mid-playback.
    private var launchSoundPlayer: AVAudioPlayer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("🎯 TipTour: Starting...")
        print("🎯 TipTour: Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")")

        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 0])

        playLaunchSound()

        // Analytics removed during rebrand; see Plan 2 if reinstating.

        menuBarPanelManager = MenuBarPanelManager(companionManager: companionManager)
        companionManager.start()  // starts MCP server + sets hermesClient.mcpServerURL
        hermesDebugMenu = HermesDebugMenuController(
            client: companionManager.hermesClient,
            mcpServer: companionManager.mcpServer
        )
        hermesDebugMenu?.install(companionManager: companionManager)
        // Auto-open the panel if the user still needs to do something:
        // either they haven't onboarded yet, or permissions were revoked.
        if !companionManager.hasCompletedOnboarding || !companionManager.allPermissionsGranted {
            menuBarPanelManager?.showPanelOnLaunch()
        }
        registerAsLoginItemIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        companionManager.stop()
    }

    /// Registers the app as a login item so it launches automatically on
    /// startup. Uses SMAppService which shows the app in System Settings >
    /// General > Login Items, letting the user toggle it off if they want.
    private func registerAsLoginItemIfNeeded() {
        let loginItemService = SMAppService.mainApp
        if loginItemService.status != .enabled {
            do {
                try loginItemService.register()
                print("🎯 TipTour: Registered as login item")
            } catch {
                print("⚠️ TipTour: Failed to register as login item: \(error)")
            }
        }
    }

    /// Plays the Iron Man repulsor sound effect on every app launch, in sync
    /// with the Arc Reactor boot animation. Bundled as a loose resource at
    /// TipTour/ironman-repulsors.mp3.
    private func playLaunchSound() {
        guard let soundURL = Bundle.main.url(forResource: "ironman-repulsors", withExtension: "mp3") else {
            print("⚠️ TipTour: ironman-repulsors.mp3 not found in bundle")
            return
        }
        do {
            let player = try AVAudioPlayer(contentsOf: soundURL)
            player.prepareToPlay()
            player.play()
            launchSoundPlayer = player
        } catch {
            print("⚠️ TipTour: Failed to play launch sound: \(error)")
        }
    }

}
