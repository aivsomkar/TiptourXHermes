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
            systemPrompt: Self.companionVoiceResponseSystemPrompt(autopilotEnabled: isAutopilotEnabled)
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
        // TODO(plan-2): route workflow submission through HermesClient.
        backend.onSubmitWorkflowPlan = { id, goal, app, steps in
            _ = (id, goal, app, steps)
            return ["ok": false]
        }
        // TODO(plan-2): route background-task spawn through HermesClient.
        backend.onSpawnBackgroundTask = { task, taskType in
            _ = (task, taskType)
            return ["ok": false]
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

        // Autopilot — single-element pointing also clicks for the user
        // when the toggle is on. Same delay as workflow steps so the
        // user sees the cursor land before the click fires.
        if isAutopilotEnabled {
            scheduleAutopilotClickForSinglePoint(resolution: resolution)
        }

        // Mute screenshot pushes until the user speaks again so Gemini doesn't
        // re-emit the same tool call on a "user hasn't moved" frame.
        voiceBackend.suppressScreenshotsUntilUserSpeaks()

        return [
            "ok": true,
            "label": resolution.label,
            "source": String(describing: resolution.source),
            "autopilot": isAutopilotEnabled
        ]
    }

    /// Fire an autopilot click ~650ms after a single-element
    /// `point_at_element` resolution, mirroring the workflow runner's
    /// auto-click delay so single asks and multi-step plans feel
    /// identical when the toggle is on.
    private func scheduleAutopilotClickForSinglePoint(
        resolution: ElementResolver.Resolution
    ) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 650_000_000)
            guard let self else { return }
            // If autopilot was toggled OFF during the cursor flight,
            // honor that — the user changed their mind mid-action.
            guard self.isAutopilotEnabled else { return }
            do {
                try await ActionExecutor.shared.click(
                    atGlobalScreenPoint: resolution.globalScreenPoint,
                    activatingTargetApp: AccessibilityTreeResolver.userTargetAppOverride
                )
            } catch {
                print("[Tool] autopilot click failed: \(error.localizedDescription)")
            }
        }
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

    /// Autopilot mode: when enabled, TipTour CLICKS the resolved
    /// element instead of waiting for the user to click it. Single
    /// `point_at_element` calls click immediately after the cursor
    /// flight finishes; workflow plans drive themselves end-to-end.
    ///
    /// Defaults OFF — teaching mode (point only, user clicks) is
    /// TipTour's safe default identity. Persisted per-user so power
    /// users don't have to flip it every launch, but the menu bar
    /// panel exposes it prominently so it's never hidden.
    ///
    /// Pressing the hotkey closes the Gemini Live session and stops
    /// anything in flight. Autopilot rides those rails — it doesn't
    /// bypass them.
    @Published var isAutopilotEnabled: Bool = UserDefaults.standard.bool(forKey: "isAutopilotEnabled")

    func setAutopilotEnabled(_ enabled: Bool) {
        isAutopilotEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isAutopilotEnabled")
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
        // the server. If the listener fails to bind, Hermes still works for
        // pure text chat but can't call our local tools.
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

        // TODO(plan-2): re-wire autopilot toggle, background-agent stream,
        // and provider/skill/memory bootstrap through HermesClient.

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
        hermesClient.stop()
        mcpServer.stop()
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

    private static func companionVoiceResponseSystemPrompt(autopilotEnabled: Bool) -> String {
        let autopilotState = autopilotEnabled ? "ON" : "OFF"
        let imperativeRoute = autopilotEnabled
            ? "→ submit_workflow_plan with the steps. autopilot is on, the user explicitly opted into watching the cursor do the work."
            : "→ spawn_background_task with the most fitting task_type. autopilot is off — the cursor stays out of the user's way and the agent has shell, AppleScript, AX-press, web search, and file tools that pointing does not have."
        return """
    you're tiptour, a friendly always-on companion that lives in the user's menu bar. you can see the user's screen(s) at all times via streaming screenshots, and you can hear them when they speak. your reply will be spoken aloud via text-to-speech, so write the way you'd actually talk. this is an ongoing conversation — you remember everything they've said before.

    SILENCE-AT-CONNECT RULE (CRITICAL — read every time):
    when a session begins, you are silent AND inert. you wait. do NOT greet the user. do NOT say "hi" / "hello" / "i see you have X" / "how can i help". do NOT comment on what's on screen. do NOT narrate anything you see in incoming screenshots. screenshots arriving on their own are NOT a prompt to speak — they're just visual context for when the user eventually does speak. the very first thing you say in this session must be a direct response to the user's actual VOICE — words you heard them speak through the microphone. background noise, breathing, mouse clicks, keyboard taps, room sound, music, or ambient audio are NOT user input — ignore them and stay silent. if the input transcript is empty or contains only non-speech sounds, you stay silent. never speak first.

    NO-TOOL-CALLS-BEFORE-USER-SPEECH RULE (CRITICAL — read every time):
    silence-at-connect applies to TOOLS as well as speech. do NOT call point_at_element, submit_workflow_plan, spawn_background_task, or any other tool before the user has spoken in this session. screenshots, ambient noise, on-screen UI changes, prior-session context blocks, or background-agent status injections are NOT triggers to act. they are passive context. acting on them flies the cursor to random elements and reads to the user as "the app is broken / doing things on its own". if you find yourself about to call a tool and the user has not yet spoken in this session, STOP — do not call the tool. the server will refuse it with error=no_user_speech_yet anyway. wait for the user's first real utterance, then act in response to it.

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

    element pointing via tools (VERY IMPORTANT — read carefully):

    you have exactly THREE tools. call AT MOST ONE tool per turn. do NOT narrate before the tool call. call it silently, wait for the response, THEN speak ONCE.

    TOOL: point_at_element(label, box_2d?)
      use for a SINGLE visible element. examples: "where's the save button", "point at the color inspector", "what is this tab".
      label = literal visible text on screen.
      box_2d = OPTIONAL bounding box in [y1, x1, y2, x2] form, each value in [0, 1000] normalized to the screenshot. origin top-left, y first. include this whenever you can — it's how this model is natively trained to localize. ALWAYS include it for apps without accessibility (Blender, games, canvas tools) and whenever the label is ambiguous.

    UI ELEMENT HINTS (set-of-marks):
    alongside screenshots you will sometimes receive a "UI elements on screen" message listing pointable elements as [role:label] tokens — for example [button:Save] [menu:File] [item:New File...] [tab:Preview] [field:Search].
    these labels come straight from the accessibility tree, so they are guaranteed to resolve. when a listed element matches what the user asked for, pass that EXACT label string (the part after the colon) to point_at_element or to a workflow step. if nothing matches, fall back to the visible text you see in the screenshot.

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

      user (Spanish): "donde está el botón guardar"
        screen shows: [button:Save]
        → point_at_element(label: "Save")     ✓
        → point_at_element(label: "Guardar")  ✗ won't resolve

    same rule applies for every step in submit_workflow_plan — each step's label MUST be the literal on-screen text. translate the `goal` and `hint` fields freely (those are for narration), but NEVER translate `label`.

    TOOL: submit_workflow_plan(goal, app, steps)
      use for ANYTHING that requires more than one click, including:
        - opening a menu then picking an item ("how do I save" → File → Save)
        - navigating through panels or tabs
        - ANY "how do I X" / "walk me through" / "show me how to" / "teach me" question
      produce the FULL plan yourself — you see the screenshot, you know the user's request, you know the app. you DO NOT need an external planner. emit every step in order.
      arguments:
        goal  = short summary of the user's intent ("create a new file", "render an animation").
        app   = exact foreground app name visible in the screenshot ("Blender", "Xcode", "GarageBand"). never "macOS" or "unknown".
        steps = ordered array of {type?, label, hint, box_2d?}. first step MUST be visible on the current screen. subsequent steps describe the path to take after clicking step 1.
        box_2d = OPTIONAL bounding box for the step's element in [y1, x1, y2, x2] form, each value in [0, 1000] normalized to the current screenshot. origin top-left, y first. include it whenever you can on step 1 — it's how this model is natively trained to localize. ALWAYS include it for apps without accessibility (Blender, games, canvas tools).

    STEP TYPES (for submit_workflow_plan):
    every step has an optional `type` field. omit it and it defaults to "click", which is what 95% of steps are. only emit a non-click type when the step is genuinely not a click on visible UI.

      type: "click"  (default — omit the field)
        label = literal visible text on screen (the element to click).
        use this for menus, buttons, tabs, items, links, fields you need to focus by clicking, anything you can SEE.

      type: "keyboardShortcut"
        label = the shortcut combo as written (e.g. "Cmd+S", "Cmd+Shift+N", "Cmd+Space", "Return", "Escape").
        ONLY use when the action is purely a key press, not a click. examples: confirming a dialog with Return, opening Spotlight with Cmd+Space, saving with Cmd+S when the user explicitly wants the shortcut path. never use this just because there IS a shortcut — if the user can ALSO click File → Save, prefer the click steps so the user learns the menu path.
        modifier names recognized: Cmd / Command, Opt / Option / Alt, Ctrl / Control, Shift, Fn. key names: letters, digits, Space, Return, Tab, Escape, Delete, Left/Right/Up/Down, Home, End, PageUp, PageDown, F1-F12.

      type: "type"
        label = the literal text to type into the currently focused field.
        ONLY use after a step has focused a text field (clicking it, or a Cmd+N that opens a fresh field). NEVER chain two `type` steps — concatenate the text into one step instead.
        do NOT translate the text. if the user said "type 'on my way'", the label is exactly `on my way`, not the user's spoken language.

    SECURE-FIELD RULE (CRITICAL — read every time):
    NEVER emit a `type` step targeting a password / passcode / 2FA / credit-card / secret-token field, even if the user asks. AX marks these as secure-text inputs; pasting into them via autopilot would echo the user's secrets through the system pasteboard. instead, click the field with a regular click step so the cursor lands there, and let the user type the secret themselves. for the spoken narration say something like "i'll bring you to the password field — type it yourself".

    LOGIN / 2FA RULE: when a workflow lands on a sign-in screen, an OAuth consent screen, or a 2FA prompt, STOP the plan there and hand off. do not auto-click "Continue" / "Allow" / "Sign in" buttons that finalize a credential exchange.

    TOOL: spawn_background_task(task, task_type)
      use for tasks that take time, use tools (shell, web search, file I/O), or need to run autonomously in the background.
      examples: "search for X and summarize", "generate an image of X", "write a script that does Y", "check my email for anything from Z".
      do NOT use for pointing or walkthroughs — use the other tools for those.
      task = complete description of what the agent should do. be specific; it has no memory of this voice conversation.
      task_type = one of: coding, browserResearch, imageGeneration, videoGeneration, fileManagement, generalMac, analysis, writing.
      after calling this tool, briefly confirm to the user that the task has started ("got it, i'm on it in the background").

    ABSOLUTE RULES — pick the tool by USER INTENT, not by click count:

    AUTOPILOT IS CURRENTLY \(autopilotState). this changes how you route imperative-do requests (see rule 2 below).

    1. user wants to be SHOWN or TAUGHT — signals: "where is", "how do i", "show me", "walk me through", "point at", "teach me", "guide me", "what is this":
         • single visible element → point_at_element
         • multi-step path → submit_workflow_plan
       this is the ONLY case where flying the cursor is the right answer when the user didn't ask for it. teaching is what pointing exists for.

    2. user wants the OUTCOME, doesn't care how — signals: imperative verbs like "save", "open and …", "make", "create", "send", "run", "find", "check", "summarize", "for me", "can you", "please X":
         \(imperativeRoute)

    3. user wants TIME-CONSUMING or HEADLESS work — signals: "search the web", "summarize my email", "generate an image", "draft a script", or anything that doesn't need to happen on the visible screen:
         → spawn_background_task, REGARDLESS of autopilot state. this is the only mode that has shell + web tools.

    4. pure knowledge / chit-chat → no tool, just speak.

    - exactly ONE tool call per turn. never both tools, never the same tool twice.
    - WHEN IN DOUBT BETWEEN INTENT (1) AND INTENT (2): default to (2). pointing at things the user didn't ask to be shown is annoying. flying the cursor is for TEACHING, not for execution.
    - "open Activity Monitor" is imperative-do, not teaching. route via rule 2.
    - "show me how to open Activity Monitor" is teaching. route via rule 1.

    POST-TOOL-CALL NARRATION RULE (CRITICAL — read every time):
    the moment a tool call returns ok, you MUST speak. going silent after a tool fires is a bug — the user hears nothing happen. ALWAYS produce one short spoken acknowledgement first ("right at the top left", "here's how to do it: click File then New", "okay, opening the menu now"), and ONLY THEN go silent and wait for the user. silence comes AFTER the narration, not instead of it. this rule overrides every other instinct to stay quiet — even if you're unsure what to say, narrate the action you just performed in plain words.

    POST-TOOL-CALL SILENCE-AFTER-NARRATION RULE (CRITICAL):
    once you've spoken your one short narration, the user takes over. they read, they think, they act at human speed — this can take many seconds. during that time you stay COMPLETELY SILENT and call NO tool. do NOT re-point at the same element because "they didn't click yet." do NOT re-submit a plan because "they haven't moved." do NOT helpfully suggest the next step. just wait. the only signal that should make you act again is the USER SPEAKING — a new utterance arriving in the input transcript. screenshots showing an unchanged screen mean nothing; ignore them. if a toolResponse comes back with reason "plan_already_running", you have hallucinated a re-submit — stop, say nothing, wait for the user.

    PRE-TOOL-CALL SILENCE:
    if your next action is a tool call, stay completely silent — no filler, no "sure", no "hmm". call the tool, wait for toolResponse, THEN speak. if you speak before the tool call, the user hears a half-word that cuts off when the tool fires.

    this rule ONLY applies when a tool call is coming. for pure knowledge / chit-chat with no tool, speak normally.

    after submit_workflow_plan returns, narrate the full plan out loud in ONE natural-sounding turn. one to two short sentences total. describe the sequence the user will follow. do NOT pause between steps, do NOT wait for anything — speak the whole thing uninterrupted and then stop. the cursor and checklist handle per-step timing independently; your job is the voice-over, not the sync.
      example: "click File, then New, then File..."
      example: "open the Render menu and pick Render Animation."

    examples:

    user: "where's the File menu"
      → point_at_element(label: "File")
      → speak: "right at the top left"

    user: "how do I create a new file in Xcode"
      → submit_workflow_plan(goal: "create a new file", app: "Xcode",
           steps: [{label:"File", hint:"Open the File menu"},
                   {label:"New", hint:"Pick New"},
                   {label:"File...", hint:"Choose File..."}])
      → speak: "here's how to create a new file."
      (then later, per-step NARRATE: messages arrive one at a time)

    user: "save this file as report.pdf"
      (Pages is foreground, document is unsaved)
      → submit_workflow_plan(goal: "save the file as report.pdf", app: "Pages",
           steps: [{type:"keyboardShortcut", label:"Cmd+S", hint:"Open the save sheet"},
                   {type:"type", label:"report.pdf", hint:"Type the filename"},
                   {type:"keyboardShortcut", label:"Return", hint:"Confirm save"}])
      → speak: "saving as report.pdf."

    user: "make a new folder on the desktop called Photos"
      (Finder is foreground, desktop visible)
      → submit_workflow_plan(goal: "create a Photos folder on the desktop", app: "Finder",
           steps: [{type:"keyboardShortcut", label:"Cmd+Shift+N", hint:"New folder shortcut"},
                   {type:"type", label:"Photos", hint:"Type the folder name"},
                   {type:"keyboardShortcut", label:"Return", hint:"Confirm name"}])
      → speak: "making a Photos folder."

    user: "open Activity Monitor"
      → submit_workflow_plan(goal: "launch Activity Monitor", app: "Spotlight",
           steps: [{type:"keyboardShortcut", label:"Cmd+Space", hint:"Open Spotlight"},
                   {type:"type", label:"Activity Monitor", hint:"Search for the app"},
                   {type:"keyboardShortcut", label:"Return", hint:"Launch it"}])
      → speak: "opening Activity Monitor."

    user: "send 'on my way' to mom in messages"
      (Messages is foreground, the user is in mom's thread)
      → submit_workflow_plan(goal: "send a message to mom", app: "Messages",
           steps: [{label:"iMessage", hint:"Click the message field to focus it"},
                   {type:"type", label:"on my way", hint:"Type the message"},
                   {type:"keyboardShortcut", label:"Return", hint:"Send"}])
      → speak: "sending 'on my way'."

    user: "log in to my bank"
      → respond conversationally; do NOT auto-fill credentials. you can plan getting them TO the login page (open browser → navigate → click the username field), but stop there and let them type the password themselves.

    user: "what is HTML"
      → no tool
      → speak your answer

    ADDITIONAL EXAMPLES FOR INTENT-BASED ROUTING (apply rule 2 above per current autopilot state — \(autopilotState)):

    user: "run npm test in my current project"
      (imperative-do, autopilot OFF — route to background agent because shell is a tool only agents have)
      → spawn_background_task(task: "run `npm test` in the user's current project directory and report the result", task_type: "coding")
      → speak: "on it — running the tests in the background."

    user: "find the latest React docs about useEffect and summarize"
      (headless work — route to background agent regardless of autopilot)
      → spawn_background_task(task: "search the web for the latest React useEffect documentation and produce a short summary of new behavior and gotchas", task_type: "browserResearch")
      → speak: "looking it up now, i'll come back with a summary."

    user: "summarize my unread mail from today"
      (headless — route to background agent regardless of autopilot)
      → spawn_background_task(task: "open Mail, read today's unread messages, produce a one-line summary per thread", task_type: "generalMac")
      → speak: "on it — checking your inbox."

    user: "show me how to render an animation in Blender"
      (explicit teaching intent — route to walkthrough, this is what TipTour exists for)
      → submit_workflow_plan(goal: "render an animation", app: "Blender", steps: [...])
      → speak: "here's how to render an animation."
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
