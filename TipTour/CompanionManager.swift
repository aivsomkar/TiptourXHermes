//
//  CompanionManager.swift
//  TipTour
//
//  Central state manager for the Gemini Live voice companion. Owns the
//  push-to-talk hotkey, screen capture, Gemini Live session, tool handlers
//  for cursor pointing + multi-step workflows, and overlay management.
//

import ApplicationServices
import AVFoundation
import Combine
import Foundation
import ScreenCaptureKit
import SwiftUI

enum CompanionVoiceState {
    case idle
    case listening
    case processing
    case responding
}

@MainActor
final class CompanionManager: ObservableObject {
    @Published private(set) var voiceState: CompanionVoiceState = .idle {
        didSet {
            guard oldValue != voiceState else { return }
            handleVoiceStateTransition(to: voiceState)
        }
    }
    @Published private(set) var lastTranscript: String?
    @Published private(set) var currentAudioPowerLevel: CGFloat = 0
    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var hasScreenRecordingPermission = false
    @Published private(set) var hasMicrophonePermission = false
    @Published private(set) var hasScreenContentPermission = false

    /// Screen location (global AppKit coords) of a detected UI element the
    /// cursor should fly to and point at. Observed by BlueCursorView to
    /// trigger the flight animation.
    @Published var detectedElementScreenLocation: CGPoint?
    /// Display frame (global AppKit coords) of the screen the detected
    /// element is on, so BlueCursorView knows which screen overlay should animate.
    @Published var detectedElementDisplayFrame: CGRect?
    /// Custom speech bubble text for the pointing animation.
    @Published var detectedElementBubbleText: String?

    /// Whether the blue cursor overlay is currently visible on screen.
    @Published private(set) var isOverlayVisible: Bool = false

    // MARK: - Skill Demonstration (removed — to be re-routed through HermesClient)
    // TODO(plan-2): re-introduce demonstration recording via HermesClient if needed.

    let globalPushToTalkShortcutMonitor = GlobalPushToTalkShortcutMonitor()
    let overlayWindowManager = OverlayWindowManager()

    /// Base URL for the Cloudflare Worker proxy. All API requests route
    /// through this so keys never ship in the app binary.
    private static let workerBaseURL: String = {
        let url = "https://clicky-proxy.milindsoni201.workers.dev"
        // ElementResolver's multilingual /match-label fallback hits the
        // same worker. Setting the override here means we have one
        // source of truth for the base URL.
        ElementResolver.workerBaseURLOverride = url
        return url
    }()

    private var shortcutTransitionCancellable: AnyCancellable?
    private var demonstrationShortcutCancellable: AnyCancellable?
    private var accessibilityCheckTimer: Timer?
    private var voiceAudioPowerCancellable: AnyCancellable?
    private var voiceModelSpeakingCancellable: AnyCancellable?

    /// One-shot player for voice-state sound effects (Jarvis "listening" /
    /// "working" cues). Held as a stored property so the player isn't
    /// deallocated mid-playback; replaced on each new transition so a
    /// transition cue interrupts any previous one rather than overlapping.
    private var voiceStateSoundPlayer: AVAudioPlayer?

    /// The single Hermes client shared by the voice loop (ask_hermes tool)
    /// and the Talk-to-Hermes chat window. Launches a Python subprocess
    /// lazily on first send; stays alive for the app's lifetime.
    let hermesClient = HermesClient()

    /// In-process MCP server exposing speak / take_screenshot / get_a11y_tree
    /// / point_at to Hermes. Started in `start()`; the URL is set on
    /// hermesClient before the first send so Hermes registers the MCP
    /// server during session/new.
    let mcpServer = MCPServer(name: "tiptour-tools")

    // TODO(plan-2): route background-agent state through HermesClient.
    private var pendingAgentCompletionNotices: [String] = []

    /// True when all four required permissions (accessibility, screen recording,
    /// microphone, screen content) are granted. Used by the panel to show a single "all good" state.
    var allPermissionsGranted: Bool {
        hasAccessibilityPermission && hasScreenRecordingPermission && hasMicrophonePermission && hasScreenContentPermission
    }

    /// Backing storage for the active voice session. Built lazily on first
    /// access via `voiceBackend`. Single backend now — Gemini Live.
    private var _voiceBackend: GeminiLiveSession?

    /// The active voice session. Constructs the Gemini Live session on
    /// first access and wires all the tool / transcript callbacks once.
    var voiceBackend: GeminiLiveSession {
        if let existing = _voiceBackend { return existing }
        let backend = GeminiLiveSession(
            apiKeyURL: "\(Self.workerBaseURL)/gemini-live-key",
            systemPrompt: Self.companionVoiceResponseSystemPrompt()
        )
        wireCallbacks(on: backend)
        _voiceBackend = backend
        rebindVoiceBackendPublishers(backend)
        return backend
    }

    /// Hook all tool / transcript / error callbacks.
    private func wireCallbacks(on backend: GeminiLiveSession) {
        backend.onPointAtElement = { [weak self] id, label, box2DNormalized, screenshotJPEG in
            await self?.handleToolPointAtElement(
                id: id,
                label: label,
                box2DNormalized: box2DNormalized,
                screenshotJPEG: screenshotJPEG
            ) ?? ["ok": false]
        }
        backend.onAskHermes = { [weak self] id, task in
            await self?.handleToolAskHermes(id: id, task: task) ?? ["ok": false, "error": "manager_gone"]
        }
        backend.onInputTranscriptUpdate = { [weak self] fullInputTranscript in
            guard let self else { return }
            let isNewUtterance = fullInputTranscript.trimmingCharacters(in: .whitespacesAndNewlines).count > 0
                && self.previousInputTranscriptLength == 0
            if isNewUtterance {
                self.handledToolCallIDsThisUtterance.removeAll()
            }
            self.previousInputTranscriptLength = fullInputTranscript.count
        }
        backend.onTurnComplete = { [weak self] in
            self?.previousInputTranscriptLength = 0
        }
        backend.onError = { error in
            print("[VoiceBackend] Error: \(error.localizedDescription)")
        }
    }

    /// Fires every time `voiceState` transitions. Plays the corresponding
    /// Jarvis sound cue: "listening" when the mic opens, "working" when
    /// the model starts responding or running a task.
    private func handleVoiceStateTransition(to newState: CompanionVoiceState) {
        switch newState {
        case .listening:
            playVoiceStateSound(named: "jarvislistening")
        case .responding, .processing:
            playVoiceStateSound(named: "jarvisworking")
        case .idle:
            voiceStateSoundPlayer?.stop()
        }
    }

    /// Loads the named .wav from the bundle and plays it. Stops any previous
    /// voice-state cue first so the new state's sound never overlaps the old.
    /// Volume is kept low so the cue doesn't mask Gemini's spoken response.
    private func playVoiceStateSound(named filename: String) {
        voiceStateSoundPlayer?.stop()
        guard let soundURL = Bundle.main.url(forResource: filename, withExtension: "wav") else {
            print("⚠️ TipTour: \(filename).wav not found in bundle")
            return
        }
        do {
            let player = try AVAudioPlayer(contentsOf: soundURL)
            player.volume = 0.25
            player.prepareToPlay()
            player.play()
            voiceStateSoundPlayer = player
        } catch {
            print("⚠️ TipTour: Failed to play \(filename).wav: \(error)")
        }
    }

    /// Subscribe to the backend's audio-power and model-speaking publishers.
    private func rebindVoiceBackendPublishers(_ backend: GeminiLiveSession) {
        voiceAudioPowerCancellable = backend.$currentAudioPowerLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] powerLevel in
                self?.currentAudioPowerLevel = powerLevel
            }
        voiceModelSpeakingCancellable = backend.$isModelSpeaking
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isSpeaking in
                guard let self = self, self.voiceBackend.isActive else { return }
                self.voiceState = isSpeaking ? .responding : .listening
            }
    }

    // MARK: - box_2d → screenshot-pixel conversion

    /// Convert Gemini's `box_2d` (in normalized [y1, x1, y2, x2] form, each
    /// value in [0, 1000]) to the box's center in screenshot-pixel space.
    /// Returns nil when no valid box was provided OR when we don't yet have
    /// a screenshot to scale against.
    ///
    /// Why box_2d at all: Gemini 2.5 / 3.x is natively trained to localize
    /// in this exact format. Asking for free-form (x, y) integers makes the
    /// model do mental math against a downscaled image it never sees the
    /// resolution of, which hurts pixel precision. box_2d normalizes that
    /// away — the model emits the same format the docs prescribe and we
    /// scale to the real screenshot dimensions on our side.
    private func pixelHintFromBox2D(
        box2DNormalized: [Int]?,
        capture: CompanionScreenCapture?
    ) -> CGPoint? {
        guard let box = box2DNormalized, box.count == 4, let capture else {
            return nil
        }
        let y1Norm = CGFloat(box[0])
        let x1Norm = CGFloat(box[1])
        let y2Norm = CGFloat(box[2])
        let x2Norm = CGFloat(box[3])

        let centerNormX = (x1Norm + x2Norm) / 2
        let centerNormY = (y1Norm + y2Norm) / 2

        let screenshotWidth = CGFloat(capture.screenshotWidthInPixels)
        let screenshotHeight = CGFloat(capture.screenshotHeightInPixels)

        let pixelX = centerNormX * screenshotWidth / 1000
        let pixelY = centerNormY * screenshotHeight / 1000
        return CGPoint(x: pixelX, y: pixelY)
    }

    // MARK: - Tool Handlers

    /// Handle the `point_at_element` tool call. Resolves the label via
    /// the AX tree → Gemini box_2d cascade and flies the cursor there.
    /// When Gemini supplies a `box_2d`, its center (in screenshot-pixel
    /// space) is fed to the resolver as the box_2d-tier fallback when
    /// AX misses.
    @MainActor
    private func handleToolPointAtElement(
        id: String,
        label: String,
        box2DNormalized: [Int]?,
        screenshotJPEG: Data?
    ) async -> [String: Any] {
        if handledToolCallIDsThisUtterance.contains(id) {
            print("[Tool] ⏭️  ignoring duplicate point_at_element id=\(id)")
            return ["ok": true, "duplicate": true]
        }
        handledToolCallIDsThisUtterance.insert(id)

        // TODO(plan-2): re-implement workflow short-circuit via HermesClient session state.
        let capture = voiceBackend.latestCapture
        let hintInScreenshotPixels = pixelHintFromBox2D(
            box2DNormalized: box2DNormalized,
            capture: capture
        )
        if let hintInScreenshotPixels {
            print("[Tool] 🔧 point_at_element(label=\"\(label)\", box_2d=\(box2DNormalized ?? []) → screenshot pixel \(hintInScreenshotPixels))")
        } else {
            print("[Tool] 🔧 point_at_element(label=\"\(label)\")")
        }
        let startedAt = Date()
        let resolution = await ElementResolver.shared.resolve(
            label: label,
            llmHintInScreenshotPixels: hintInScreenshotPixels,
            latestCapture: capture
        )
        let elapsed = Int(Date().timeIntervalSince(startedAt) * 1000)
        guard let resolution else {
            print("[Tool] ✗ point_at_element(\"\(label)\") → no match after \(elapsed)ms")
            voiceBackend.invalidateScreenshotHashCache()
            return ["ok": false, "reason": "element_not_found", "label": label]
        }
        print("[Tool] ✓ point_at_element(\"\(label)\") → \(resolution.label) via \(resolution.source) in \(elapsed)ms")
        pointAtResolution(resolution)

        // Single-click ask — disarm any leftover ClickDetector state from a
        // previous workflow.
        ClickDetector.shared.disarm()

        // Mute screenshot pushes until the user speaks again so Gemini doesn't
        // re-emit the same tool call on a "user hasn't moved" frame.
        voiceBackend.suppressScreenshotsUntilUserSpeaks()

        return [
            "ok": true,
            "label": resolution.label,
            "source": String(describing: resolution.source)
        ]
    }

    /// Handle the `ask_hermes` tool call. Routes the task to the shared
    /// HermesClient, awaits its reply, and returns the final agent text as
    /// the toolResponse so Gemini can speak it. Hermes's MCP tool calls
    /// (speak / take_screenshot / get_a11y_tree / point_at) happen as side
    /// effects during the await — by the time we return, the cursor may
    /// already be pointing somewhere.
    @MainActor
    private func handleToolAskHermes(id: String, task: String) async -> [String: Any] {
        print("[Tool] 🔧 ask_hermes(task=\"\(task.prefix(80))\")")
        voiceState = .processing
        await hermesClient.send(task)
        voiceState = .responding
        let replyText = hermesClient.lastAgentReplyText ?? ""
        print("[Tool] ✅ ask_hermes returning text.count=\(replyText.count)")
        return ["ok": true, "text": replyText]
    }

    /// Set of tool-call IDs we've already dispatched within the current
    /// user utterance. Reset when a new user utterance starts.
    private var handledToolCallIDsThisUtterance: Set<String> = []

    /// Tracks input transcript length on the last update so we can detect
    /// "transcript went from empty → non-empty" — the reliable signal that
    /// a new user utterance just began.
    private var previousInputTranscriptLength: Int = 0

    // MARK: - Toggles

    /// Pin the menu bar panel so outside clicks don't dismiss it.
    @Published var isPanelPinned: Bool = UserDefaults.standard.bool(forKey: "isPanelPinned")

    func setPanelPinned(_ pinned: Bool) {
        isPanelPinned = pinned
        UserDefaults.standard.set(pinned, forKey: "isPanelPinned")
        NotificationCenter.default.post(name: .tipTourPanelPinStateChanged, object: nil)
    }

    /// Neko mode: replace the blue triangle cursor with a pixel-art cat
    /// (classic oneko sprites). Defaults ON for new installs since the cat
    /// is part of TipTour's identity.
    @Published var isNekoModeEnabled: Bool = UserDefaults.standard.object(forKey: "isNekoModeEnabled") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "isNekoModeEnabled")

    func setNekoModeEnabled(_ enabled: Bool) {
        isNekoModeEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isNekoModeEnabled")
    }

    /// Debug flag for the workflow checklist: when true, ClickDetector
    /// advances on ANY click instead of requiring the click to land
    /// within 40pt of the resolved target.
    @Published var advanceOnAnyClickEnabled: Bool = UserDefaults.standard.bool(forKey: "advanceOnAnyClickEnabled") {
        didSet {
            ClickDetector.advanceOnAnyClickEnabled = advanceOnAnyClickEnabled
        }
    }

    func setAdvanceOnAnyClickEnabled(_ enabled: Bool) {
        advanceOnAnyClickEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "advanceOnAnyClickEnabled")
    }

    // MARK: - Onboarding

    /// Whether the user has completed onboarding at least once. Persisted
    /// to UserDefaults so the Start button only appears on first launch.
    var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") }
        set { UserDefaults.standard.set(newValue, forKey: "hasCompletedOnboarding") }
    }

    /// Text streamed character-by-character on the cursor when the user
    /// first completes onboarding — "press ctrl+option to talk".
    @Published var onboardingPromptText: String = ""
    @Published var onboardingPromptOpacity: Double = 0.0
    @Published var showOnboardingPrompt: Bool = false

    func triggerOnboarding() {
        NotificationCenter.default.post(name: .tipTourDismissPanel, object: nil)
        hasCompletedOnboarding = true
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    func showOnboardingHotkeyPrompt() {
        startOnboardingPromptStream()
    }

    private func startOnboardingPromptStream() {
        let message = "press control + option and introduce yourself"
        onboardingPromptText = ""
        showOnboardingPrompt = true
        onboardingPromptOpacity = 0.0

        withAnimation(.easeIn(duration: 0.4)) {
            onboardingPromptOpacity = 1.0
        }

        var currentIndex = 0
        Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { timer in
            guard currentIndex < message.count else {
                timer.invalidate()
                DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
                    guard self.showOnboardingPrompt else { return }
                    withAnimation(.easeOut(duration: 0.3)) {
                        self.onboardingPromptOpacity = 0.0
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        self.showOnboardingPrompt = false
                        self.onboardingPromptText = ""
                    }
                }
                return
            }
            let index = message.index(message.startIndex, offsetBy: currentIndex)
            self.onboardingPromptText.append(message[index])
            currentIndex += 1
        }
    }

    // MARK: - Lifecycle

    func start() {
        // MCP server setup: register Mac-side tools, start the listener,
        // and hand the URL to HermesClient so the next session/new registers
        // the server. Guarded against re-entry so a second start() call
        // doesn't replace live tool instances (and their shared
        // AccessibilityTreeResolver) with fresh ones. If the listener fails
        // to bind on first try, Hermes still works for pure text chat but
        // can't call our local tools.
        if hermesClient.mcpServerURL == nil {
            let resolver = AccessibilityTreeResolver()
            mcpServer.register(SpeakTool())
            mcpServer.register(ScreenshotTool())
            mcpServer.register(A11yTreeTool(resolver: resolver))
            mcpServer.register(PointAtTool(resolver: resolver, companionManager: self))
            do {
                let url = try mcpServer.start()
                hermesClient.mcpServerURL = url
                NSLog("[CompanionManager] MCP server up at %@", url.absoluteString)
            } catch {
                NSLog("[CompanionManager] MCP server failed to start: %@; Hermes will run without tools", "\(error)")
                hermesClient.mcpServerURL = nil
            }
        }

        refreshAllPermissions()
        print("🔑 TipTour start — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission), onboarded: \(hasCompletedOnboarding)")
        startPermissionPolling()

        // Cap how long any AX query can hang waiting for a target app's
        // accessibility server. Default is 6 seconds, which freezes the
        // entire AX queue when a slow/unresponsive app is queried. 0.4s
        // is generous enough for healthy responses and aggressive enough
        // that a hung app fails fast and we move on to a fallback path.
        // Per-element timeouts in AccessibilityTreeResolver layer on top.
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.4)

        // Touch the lazy property so the backend is constructed and the
        // publishers are subscribed BEFORE the user opens the panel /
        // presses the hotkey.
        _ = voiceBackend
        bindShortcutTransitions()
        beginTrackingUserTargetApp()
        ClickDetector.advanceOnAnyClickEnabled = advanceOnAnyClickEnabled

        // TODO(plan-2): re-wire background-agent stream and
        // provider/skill/memory bootstrap through HermesClient.

        // If the user already completed onboarding AND all permissions are
        // still granted, show the cursor overlay immediately. If permissions
        // were revoked (e.g. signing change), don't show the cursor — the
        // panel will show the permissions UI instead.
        if hasCompletedOnboarding && allPermissionsGranted {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }
    }

    /// Route an agent-swarm notice (completion summary, failure,
    /// blocker) either into the active voice session immediately, or
    /// onto the pending-notice queue if no session is open. The user
    /// shouldn't have to start a new session to hear that the agent
    /// they asked about a minute ago finished — Gemini gets the text
    /// in-band the moment it arrives.
    @MainActor
    private func deliverAgentNoticeToVoiceSession(_ notice: String) {
        guard voiceBackend.isActive else {
            // No live session — queue for the next session start. The
            // drain runs in injectPendingAgentCompletionNoticesIfNeeded.
            pendingAgentCompletionNotices.append(notice)
            return
        }
        // Don't barge in if either party is mid-utterance. Sending a
        // clientContent text turn while the model is speaking would
        // interrupt its current response; sending while the user is
        // talking would race their utterance and confuse Gemini.
        // Queue for the next idle window instead.
        if voiceBackend.isModelSpeaking || !voiceBackend.inputTranscript.isEmpty {
            pendingAgentCompletionNotices.append(notice)
            print("[CompanionManager] queued agent notice — session busy (model speaking or user mid-utterance)")
            return
        }
        let contextMessage = """
            Background-agent update (just arrived; do not bring this up unprompted, but mention it if the user asks what your agents are up to):
            \(notice)
            """
        voiceBackend.sendText(contextMessage)
        print("[CompanionManager] forwarded live agent notice into active voice session")
    }

    // TODO(plan-2): re-introduce background-agent spawn and skill
    // demonstration capture via HermesClient.

    func stop() {
        mcpServer.stop()
        hermesClient.stop()
        globalPushToTalkShortcutMonitor.stop()
        overlayWindowManager.hideOverlay()
        shortcutTransitionCancellable?.cancel()
        demonstrationShortcutCancellable?.cancel()
        accessibilityCheckTimer?.invalidate()
        accessibilityCheckTimer = nil
        voiceAudioPowerCancellable?.cancel()
        voiceModelSpeakingCancellable?.cancel()
    }

    func clearDetectedElementLocation() {
        detectedElementScreenLocation = nil
        detectedElementDisplayFrame = nil
        detectedElementBubbleText = nil
    }

    // MARK: - Permissions

    func refreshAllPermissions() {
        let previouslyHadAccessibility = hasAccessibilityPermission
        let previouslyHadScreenRecording = hasScreenRecordingPermission
        let previouslyHadMicrophone = hasMicrophonePermission
        let previouslyHadAll = allPermissionsGranted

        let currentlyHasAccessibility = WindowPositionManager.hasAccessibilityPermission()
        hasAccessibilityPermission = currentlyHasAccessibility

        if currentlyHasAccessibility {
            globalPushToTalkShortcutMonitor.start()
        } else {
            globalPushToTalkShortcutMonitor.stop()
        }

        hasScreenRecordingPermission = WindowPositionManager.hasScreenRecordingPermission()

        let micAuthStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        hasMicrophonePermission = micAuthStatus == .authorized

        if previouslyHadAccessibility != hasAccessibilityPermission
            || previouslyHadScreenRecording != hasScreenRecordingPermission
            || previouslyHadMicrophone != hasMicrophonePermission {
            print("🔑 Permissions — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission)")
        }

        // Screen content permission is persisted — once approved it sticks.
        if !hasScreenContentPermission {
            hasScreenContentPermission = UserDefaults.standard.bool(forKey: "hasScreenContentPermission")
        }
    }

    @Published private(set) var isRequestingScreenContent = false

    func requestScreenContentPermission() {
        guard !isRequestingScreenContent else { return }
        isRequestingScreenContent = true
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else {
                    await MainActor.run { isRequestingScreenContent = false }
                    return
                }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.width = 320
                config.height = 240
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                let didCapture = image.width > 0 && image.height > 0
                print("🔑 Screen content capture result — width: \(image.width), height: \(image.height), didCapture: \(didCapture)")
                await MainActor.run {
                    isRequestingScreenContent = false
                    guard didCapture else { return }
                    hasScreenContentPermission = true
                    UserDefaults.standard.set(true, forKey: "hasScreenContentPermission")

                    if hasCompletedOnboarding && allPermissionsGranted && !isOverlayVisible {
                        overlayWindowManager.hasShownOverlayBefore = true
                        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                        isOverlayVisible = true
                    }
                }
            } catch {
                print("⚠️ Screen content permission request failed: \(error)")
                await MainActor.run { isRequestingScreenContent = false }
            }
        }
    }

    // MARK: - Private

    private func startPermissionPolling() {
        accessibilityCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAllPermissions()
            }
        }
    }

    private func bindShortcutTransitions() {
        shortcutTransitionCancellable = globalPushToTalkShortcutMonitor
            .shortcutTransitionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transition in
                self?.handleShortcutTransition(transition)
            }

        // TODO(plan-2): re-wire demonstration shortcut once the
        // skill capture path is reintroduced via HermesClient.
        _ = globalPushToTalkShortcutMonitor.demonstrationShortcutPublisher
    }

    /// Watch NSWorkspace for app-activation events and continuously remember
    /// the last NON-TipTour app the user activated. This is the
    /// `userTargetAppOverride` the AX resolver uses to route queries at
    /// the right app.
    private func beginTrackingUserTargetApp() {
        if let current = NSWorkspace.shared.frontmostApplication,
           current.bundleIdentifier != Bundle.main.bundleIdentifier {
            AccessibilityTreeResolver.userTargetAppOverride = current
            Self.enableManualAccessibilityIfNeeded(for: current)
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            guard app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
            AccessibilityTreeResolver.userTargetAppOverride = app
            Self.enableManualAccessibilityIfNeeded(for: app)
        }
    }

    /// Electron apps (Framer, VS Code, Slack, Discord, Cursor, Notion,
    /// Figma desktop, etc.) ship with their AX tree gated behind a special
    /// `AXManualAccessibility` flag — Electron PR #10305 added this to
    /// avoid the side effects of `AXEnhancedUserInterface` (which makes
    /// Chromium animate window resizes and breaks window managers like
    /// Magnet/Rectangle).
    ///
    /// Setting this attribute on an Electron app's *application* AX
    /// element (not the window) populates the entire web-page AX tree so
    /// our resolver can find buttons, menus, and inputs by label.
    /// Non-Electron apps return `kAXErrorAttributeUnsupported` — which is
    /// harmless; we just ignore it. The cost of setting it universally on
    /// every app activation is one cheap AX call.
    ///
    /// Without this, the AX walk in apps like Framer returns 0 candidates
    /// (`menuBarChildren=7, candidates=0` in logs), forcing a slow,
    /// less-accurate vision fallback. With it, Framer's tree is fully
    /// populated and resolution lands on the right element first try.
    private static func enableManualAccessibilityIfNeeded(for app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard pid > 0 else { return }
        let appElement = AXUIElementCreateApplication(pid)
        // Cap the messaging timeout per-app too, in case the target's AX
        // server is slow on first contact.
        AXUIElementSetMessagingTimeout(appElement, 0.4)
        let attributeName = "AXManualAccessibility" as CFString
        let result = AXUIElementSetAttributeValue(appElement, attributeName, kCFBooleanTrue)
        switch result {
        case .success:
            print("[AX] enabled AXManualAccessibility for \(app.bundleIdentifier ?? "?") (\(app.localizedName ?? "?"))")
        case .attributeUnsupported, .actionUnsupported:
            // Non-Electron app — expected.
            break
        case .cannotComplete, .notImplemented:
            // App not ready / sandboxed — expected for some launchers.
            break
        default:
            // Anything else is unusual but non-fatal; log for diagnosis.
            print("[AX] AXManualAccessibility set returned \(result.rawValue) for \(app.bundleIdentifier ?? "?")")
        }
    }

    private func handleShortcutTransition(_ transition: PushToTalkShortcut.ShortcutTransition) {
        switch transition {
        case .pressed:
            // Snapshot the user's real frontmost app BEFORE opening the
            // menu bar panel or cursor overlay. Once TipTour shows any UI
            // macOS may flip frontmost to us, so this is the only reliable
            // moment to capture which app the user was actually looking at.
            if let frontmost = NSWorkspace.shared.frontmostApplication,
               frontmost.bundleIdentifier != Bundle.main.bundleIdentifier {
                AccessibilityTreeResolver.userTargetAppOverride = frontmost
                print("[Target] user's app at hotkey press: \(frontmost.bundleIdentifier ?? "?") (\(frontmost.localizedName ?? "?"))")
            }

            NotificationCenter.default.post(name: .tipTourDismissPanel, object: nil)
            clearDetectedElementLocation()

            showOnboardingPrompt = false
            onboardingPromptText = ""
            onboardingPromptOpacity = 0.0

            // Gemini Live uses TOGGLE behavior — press once to start, press
            // again to end. The connection stays open across turns so the
            // user can have a real conversation.
            if voiceBackend.isActive {
                stopVoiceSession()
                voiceState = .idle
            } else {
                startVoiceSession()
                voiceState = .listening
            }
        case .released:
            // Release is a no-op — the session is toggled by hotkey PRESS.
            break
        case .none:
            break
        }
    }

    /// Fly the cursor to a resolved element. The Resolution already contains
    /// global AppKit coordinates — no further conversion needed.
    private func pointAtResolution(_ resolution: ElementResolver.Resolution) {
        detectedElementScreenLocation = resolution.globalScreenPoint
        detectedElementDisplayFrame = resolution.displayFrame
        detectedElementBubbleText = resolution.label
    }

    // MARK: - Companion Prompt

    private static func companionVoiceResponseSystemPrompt() -> String {
        return """
you're tiptour, a friendly always-on companion that lives in the user's menu bar. you can see the user's screen(s) at all times via streaming screenshots, and you can hear them when they speak. your reply will be spoken aloud via text-to-speech, so write the way you'd actually talk. this is an ongoing conversation — you remember everything they've said before.

SILENCE-AT-CONNECT RULE (CRITICAL — read every time):
when a session begins, you are silent AND inert. you wait. do NOT greet the user. do NOT say "hi" / "hello" / "i see you have X" / "how can i help". do NOT comment on what's on screen. do NOT narrate anything you see in incoming screenshots. screenshots arriving on their own are NOT a prompt to speak — they're just visual context for when the user eventually does speak. the very first thing you say in this session must be a direct response to the user's actual VOICE — words you heard them speak through the microphone. background noise, breathing, mouse clicks, keyboard taps, room sound, music, or ambient audio are NOT user input — ignore them and stay silent. if the input transcript is empty or contains only non-speech sounds, you stay silent. never speak first.

NO-TOOL-CALLS-BEFORE-USER-SPEECH RULE (CRITICAL — read every time):
silence-at-connect applies to TOOLS as well as speech. do NOT call point_at_element, ask_hermes, or any other tool before the user has spoken in this session. screenshots, ambient noise, on-screen UI changes are NOT triggers to act. they are passive context. acting on them flies the cursor to random elements and reads to the user as "the app is broken / doing things on its own". if you find yourself about to call a tool and the user has not yet spoken in this session, STOP — do not call the tool. the server will refuse it with error=no_user_speech_yet anyway. wait for the user's first real utterance, then act in response to it.

GREETING-ONLY RULE (CRITICAL — read every time):
if the user's utterance is just a greeting ("hi", "hey", "hello", "yo", "what's up", "good morning", etc.) and contains no actual question or request, respond with a brief greeting back ("hey", "hi there", "what's up") and STOP. do NOT volunteer information about what's on screen. do NOT call any tool. do NOT mention menus, buttons, or anything visible. wait for the user to ask an actual question. screen content is reference material for when the user asks about it — never narrate it unprompted, even right after a greeting.

rules:
- default to one or two sentences. be direct and dense. BUT if the user asks you to explain more, go deeper, or elaborate, then go all out — give a thorough, detailed explanation with no length limit.
- all lowercase, casual, warm. no emojis.
- write for the ear, not the eye. short sentences. no lists, bullet points, markdown, or formatting — just natural speech.
- don't use abbreviations or symbols that sound weird read aloud. write "for example" not "e.g.", spell out small numbers.
- if the user's question relates to what's on their screen, reference specific things you see.
- if the screenshot doesn't seem relevant to their question, just answer the question directly.
- you can help with anything — coding, writing, general knowledge, brainstorming.
- never say "simply" or "just".
- don't read out code verbatim. describe what the code does or what needs to change conversationally.
- focus on giving a thorough, useful explanation. don't end with simple yes/no questions like "want me to explain more?" or "should i show you?" — those are dead ends that force the user to just say yes.
- instead, when it fits naturally, end by planting a seed — mention something bigger or more ambitious they could try, a related concept that goes deeper, or a next-level technique that builds on what you just explained. make it something worth coming back for, not a question they'd just nod to. it's okay to not end with anything extra if the answer is complete on its own.
- if you receive multiple screen images, the one labeled "primary focus" is where the cursor is — prioritize that one but reference others if relevant.

tools (VERY IMPORTANT — read carefully):

you have exactly TWO tools. call AT MOST ONE tool per turn.

TOOL: point_at_element(label, box_2d?)
  use for a SINGLE visible element. examples: "where's the save button", "point at the color inspector", "what is this tab".
  label = literal visible text on screen.
  box_2d = OPTIONAL bounding box in [y1, x1, y2, x2] form, each value in [0, 1000] normalized to the screenshot. origin top-left, y first. include this whenever you can — it's how this model is natively trained to localize. ALWAYS include it for apps without accessibility (Blender, games, canvas tools) and whenever the label is ambiguous.

UI ELEMENT HINTS (set-of-marks):
alongside screenshots you will sometimes receive a "UI elements on screen" message listing pointable elements as [role:label] tokens — for example [button:Save] [menu:File] [item:New File...] [tab:Preview] [field:Search].
these labels come straight from the accessibility tree, so they are guaranteed to resolve. when a listed element matches what the user asked for, pass that EXACT label string (the part after the colon) to point_at_element. if nothing matches, fall back to the visible text you see in the screenshot.

LANGUAGE RULE (CRITICAL — read every time):
the user may speak in ANY language. you respond in their language. but tool LABELS are different — they must EXACTLY match what is shown on the user's screen, in whatever language the UI is set to. you NEVER translate UI labels to match the user's spoken language.

rule of thumb: a label that the user can SEE on their screen is the only label that resolves. if the marks say [menu:File], pass "File" — even if the user asked in Hindi or Spanish. if the marks say [menu:Archivo] (the user has a Spanish-localized macOS), pass "Archivo" — even if the user asked in English. literal screen text always wins.

examples:
  user (Hindi): "फ़ाइल मेनू कहाँ है"  (where is File menu)
    screen shows: [menu:File]
    → point_at_element(label: "File")     ✓
    → point_at_element(label: "फ़ाइल")     ✗ won't resolve

  user (English): "open the archivo menu"
    screen shows: [menu:Archivo]
    → point_at_element(label: "Archivo")  ✓
    → point_at_element(label: "File")     ✗ won't resolve

TOOL: ask_hermes(task)
  delegate to hermes — a deeper-reasoning sub-agent with shell, file, web, and screen tools. use for:
    - coding questions, code review, refactoring
    - multi-step research that needs the web
    - tasks that need running commands or reading files
    - anything that benefits from longer, more careful thought
  don't use for:
    - "where is X" on screen → use point_at_element
    - quick chit-chat or knowledge you can answer in one breath
  task = a complete, self-contained description of the work. hermes has no memory of this voice conversation, so include all context it needs.
  hermes returns its final answer as text in the toolResponse. you then speak that answer to the user — paraphrase it for voice if needed (shorter, conversational, no markdown).

  BEFORE calling: speak ONE short acknowledgement ("on it, let me check", "looking into that"), THEN call the tool, THEN speak the result. don't go silent while hermes is working — the user shouldn't hear dead air.

ABSOLUTE RULES — pick by USER INTENT:

1. user wants to be SHOWN a single thing on screen — "where is", "point at", "what is this": → point_at_element (stay silent before the call, speak ONCE after)
2. user wants deep work — coding, research, writing, multi-step reasoning, file operations, shell: → ask_hermes (speak ONE short ack before the call, speak hermes's answer after)
3. pure knowledge / chit-chat → no tool, just speak.

- exactly ONE tool call per turn.

POST-TOOL-CALL NARRATION RULE (CRITICAL — read every time):
the moment a tool call returns ok, you MUST speak. going silent after a tool fires is a bug — the user hears nothing happen. ALWAYS produce one short spoken acknowledgement first ("right at the top left", "okay, here's what i found"), and ONLY THEN go silent and wait for the user. silence comes AFTER the narration, not instead of it.

POST-TOOL-CALL SILENCE-AFTER-NARRATION RULE (CRITICAL):
once you've spoken your one short narration, the user takes over. they read, they think, they act at human speed — this can take many seconds. during that time you stay COMPLETELY SILENT and call NO tool. just wait. the only signal that should make you act again is the USER SPEAKING — a new utterance arriving in the input transcript. screenshots showing an unchanged screen mean nothing; ignore them.

PRE-TOOL-CALL SILENCE (point_at_element):
if your next action is a point_at_element call, stay completely silent — no filler, no "sure", no "hmm". call the tool, wait for toolResponse, THEN speak. if you speak before the tool call, the user hears a half-word that cuts off when the tool fires.

PRE-TOOL-CALL SPOKEN ACK (ask_hermes only):
ask_hermes can take many seconds to return. speak ONE short acknowledgement BEFORE the call ("on it", "let me check") so the user knows you heard them. then call the tool. then speak hermes's result.

examples:

user: "where's the File menu"
  → point_at_element(label: "File")
  → speak: "right at the top left"

user: "what is HTML"
  → no tool
  → speak your answer

user: "write me a haiku about coffee"
  → speak: "on it"
  → ask_hermes(task: "write a haiku about coffee")
  → (hermes returns the haiku)
  → speak the haiku conversationally

user: "what does this regex do" (user has code on screen)
  → speak: "let me look"
  → ask_hermes(task: "the user is looking at a regex on their screen. take a screenshot and explain what the regex does in plain english.")
  → speak hermes's explanation, paraphrased for voice

user: "search for the latest react docs about useEffect and summarize"
  → speak: "looking it up"
  → ask_hermes(task: "search the web for the latest react useEffect documentation and produce a short summary of new behavior and gotchas")
  → speak the summary

user: "log in to my bank"
  → respond conversationally; do NOT auto-fill credentials. you can point at the username field, but stop there and let them type the password themselves.
"""
    }

    // MARK: - Image Conversion

    static func cgImage(from jpegData: Data) -> CGImage? {
        guard let imageSource = CGImageSourceCreateWithData(jpegData as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
    }

    // MARK: - Gemini Live Mode

    // TODO(plan-2): workflow execution now routes through HermesClient.

    /// Start a Gemini Live session on hotkey press. Two things run in
    /// parallel from the instant the hotkey fires:
    ///   1. WebSocket open + Gemini session setup (~300-500ms)
    ///   2. Real AX-tree prefetch on the user's target app — walks the
    ///      frontmost app's AX tree and primes the set-of-marks cache so
    ///      the moment Gemini emits its first tool call, the resolver
    ///      already has the AX data it needs.
    ///
    /// The prefetch overlaps the user's first words / Gemini's session
    /// setup, so the latency cost (typically 50-300ms on Cocoa apps,
    /// up to 1s on heavy Electron trees) lands entirely in "free" time.
    /// This is the single biggest perceived-latency win on the warm
    /// path: by the time the first `point_at_element` arrives,
    /// resolution returns in ~10-30ms instead of 100-400ms.
    func startVoiceSession() {
        Task.detached(priority: .userInitiated) {
            await Self.prefetchAccessibilityTreeForTargetApp()
        }

        Task {
            do {
                try await voiceBackend.start(initialScreenshot: nil)
                // TODO(plan-2): re-inject pending background-agent
                // notices and live status via HermesClient.
                await injectPendingAgentCompletionNoticesIfNeeded()
            } catch {
                print("[GeminiLive] Failed to start session: \(error.localizedDescription)")
            }
        }
    }

    /// Drain any agent completion / failure / blocker notices that
    /// arrived while no voice session was open, and inject them as a
    /// single text turn so Gemini can narrate "while you were away,
    /// the camera-research agent finished" on the next user utterance.
    /// Notices are consumed (removed from the pending queue) so
    /// subsequent sessions don't repeat them.
    private func injectPendingAgentCompletionNoticesIfNeeded() async {
        guard !pendingAgentCompletionNotices.isEmpty else { return }
        let notices = pendingAgentCompletionNotices
        pendingAgentCompletionNotices.removeAll()

        let lines = notices.map { "• \($0)" }.joined(separator: "\n")
        let contextMessage = """
            While we were apart, the following background agents reported in:
            \(lines)
            If the user asks what happened, narrate this in your own words. \
            Do NOT bring it up unprompted — only when they ask or it's relevant.
            """
        voiceBackend.sendText(contextMessage)
        print("[CompanionManager] Drained \(notices.count) pending agent notice(s) into new session")
    }

    // TODO(plan-2): re-introduce live background-agent status injection
    // via HermesClient.

    /// Walk the user's target app AX tree to prime caches so the first
    /// `point_at_element` resolves against warm data. The set-of-marks
    /// walk inside `setOfMarksForTargetApp` is the heaviest AX call
    /// the resolver makes at runtime, so doing it now means the first
    /// real `findElement` call is mostly cached I/O.
    ///
    /// Uses the snapshot of the user's frontmost app captured at hotkey
    /// press time (set in `handleShortcutTransition`) — never our own
    /// menu bar app.
    private static func prefetchAccessibilityTreeForTargetApp() async {
        let resolver = AccessibilityTreeResolver()
        // Touch set-of-marks first (warms the full traversal cache),
        // then a "no-match-expected" findElement call so any
        // empty-tree detection (Blender / canvas apps) is recorded
        // before the first real resolution attempt arrives.
        _ = resolver.setOfMarksForTargetApp(hint: nil)
        _ = await ElementResolver.shared.tryAccessibilityTree(label: "__warmup__")
    }

    /// End the Gemini Live session.
    func stopVoiceSession() {
        // TODO(plan-2): tell HermesClient to abandon any in-flight plan.
        voiceBackend.stop()
    }
}
