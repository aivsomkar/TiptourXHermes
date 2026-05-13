# Phase 4C: DemonstrationRecorder & SkillExtractor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let users teach TipTour new skills by activating a recording mode (Ctrl+Option+W or panel button), performing a task on their Mac, stopping the recording, naming the skill, and having Claude synthesize the demonstration into a reusable skill stored in `SkillLibraryStore`.

**Architecture:** `DemonstrationRecorder` (`final class @unchecked Sendable`, NSLock-guarded) captures user actions via a `CGEventTap` — cannot be an actor because CGEventTap C callbacks are synchronous and cannot cross an actor boundary. `SkillExtractor` is a Swift actor singleton that formats the recorded trajectory and calls Claude via `AnthropicProvider`. `LLMMessage` gains an optional `imagesJPEG: [Data]?` field so `AnthropicProvider` can send vision content blocks; this is a non-breaking addition since the field is optional. `CompanionManager` owns the recorder, wires the state machine, and exposes four `@Published` properties for the UI. `GlobalPushToTalkShortcutMonitor` gains a second `PassthroughSubject` for the Ctrl+Option+W hotkey.

**Tech Stack:** Swift, SwiftUI/AppKit, CGEventTap, NSWorkspace notifications, ScreenCaptureKit (via `CompanionScreenCaptureUtility`), Anthropic Messages API (claude-sonnet-4-6), Swift Testing framework

---

## File Map

| Action | File | Responsibility |
|--------|------|----------------|
| Create | `TipTour/Agents/Skills/DemonstrationTypes.swift` | `ObservedActionType`, `ObservedAction`, `ActionTrajectory` |
| Create | `TipTour/Agents/Skills/DemonstrationRecorder.swift` | CGEventTap recorder class + `formatForLLM` |
| Create | `TipTour/Agents/Skills/SkillExtractor.swift` | Actor singleton — formats trajectory, calls Claude |
| Modify | `TipTour/Agents/Core/LLMProvider.swift` | Add `imagesJPEG: [Data]?` to `LLMMessage` |
| Modify | `TipTour/Agents/Providers/AnthropicProvider.swift` | Handle image content blocks in user messages |
| Modify | `TipTour/CompanionManager.swift` | 4 `@Published` props + `demonstrationRecorder` + 4 methods |
| Modify | `TipTour/GlobalPushToTalkShortcutMonitor.swift` | `demonstrationShortcutPublisher` + Ctrl+Option+W detection |
| Modify | `TipTour/CompanionPanelView.swift` | Recording button row + `SaveSkillSheetView` confirmation sheet |
| Create | `TipTourTests/DemonstrationTests.swift` | All tests for Phase 4C |

---

## Task 1: Data Model — `DemonstrationTypes.swift`

**Files:**
- Create: `TipTour/Agents/Skills/DemonstrationTypes.swift`
- Create: `TipTourTests/DemonstrationTests.swift` (initial skeleton + Task 1 tests)

- [ ] **Step 1: Write failing tests for the data types**

Create `TipTourTests/DemonstrationTests.swift`:

```swift
// TipTourTests/DemonstrationTests.swift

import Foundation
import Testing
@testable import TipTour

// MARK: - ObservedAction tests

@Suite("ObservedAction")
struct ObservedActionTests {

    @Test func codableRoundTripWithAllFields() throws {
        let original = ObservedAction(
            timestamp: Date(timeIntervalSince1970: 1_000_000),
            type: .click,
            appName: "Xcode",
            point: CGPoint(x: 100, y: 200),
            text: nil,
            keyDescription: nil,
            scrollDelta: nil,
            screenshotJPEG: Data([0xFF, 0xD8, 0xFF])
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ObservedAction.self, from: data)
        #expect(decoded.type == .click)
        #expect(decoded.appName == "Xcode")
        #expect(decoded.point?.x == 100)
        #expect(decoded.screenshotJPEG == Data([0xFF, 0xD8, 0xFF]))
    }

    @Test func codableRoundTripTypeAction() throws {
        let original = ObservedAction(
            timestamp: Date(timeIntervalSince1970: 1_000_001),
            type: .type,
            appName: "Terminal",
            point: nil,
            text: "pnpm install",
            keyDescription: nil,
            scrollDelta: nil,
            screenshotJPEG: nil
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ObservedAction.self, from: data)
        #expect(decoded.type == .type)
        #expect(decoded.text == "pnpm install")
        #expect(decoded.screenshotJPEG == nil)
    }

    @Test func codableRoundTripScrollAction() throws {
        let original = ObservedAction(
            timestamp: Date(timeIntervalSince1970: 1_000_002),
            type: .scroll,
            appName: "Finder",
            point: nil,
            text: nil,
            keyDescription: nil,
            scrollDelta: -340,
            screenshotJPEG: nil
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ObservedAction.self, from: data)
        #expect(decoded.type == .scroll)
        #expect(decoded.scrollDelta == -340)
    }
}

// MARK: - ActionTrajectory tests

@Suite("ActionTrajectory")
struct ActionTrajectoryTests {

    @Test func trajectorySendsable() {
        // Sendable conformance: can be used in async context without compiler warning
        let start = Date(timeIntervalSince1970: 1_000_000)
        let end = Date(timeIntervalSince1970: 1_000_010)
        let trajectory = ActionTrajectory(startedAt: start, endedAt: end, actions: [])
        #expect(trajectory.startedAt == start)
        #expect(trajectory.endedAt == end)
        #expect(trajectory.actions.isEmpty)
    }

    @Test func trajectoryHoldsMultipleActions() {
        let actions = [
            ObservedAction(timestamp: .now, type: .click, appName: "A", point: .zero, text: nil, keyDescription: nil, scrollDelta: nil, screenshotJPEG: nil),
            ObservedAction(timestamp: .now, type: .type, appName: "A", point: nil, text: "hello", keyDescription: nil, scrollDelta: nil, screenshotJPEG: nil)
        ]
        let trajectory = ActionTrajectory(startedAt: .now, endedAt: .now, actions: actions)
        #expect(trajectory.actions.count == 2)
    }
}
```

- [ ] **Step 2: Run tests to confirm they fail**

Open `TipTourTests/DemonstrationTests.swift` in Xcode and run: Cmd+U
Expected: Compiler error — `ObservedAction`, `ActionTrajectory`, `ObservedActionType` are not defined.

- [ ] **Step 3: Create `DemonstrationTypes.swift`**

```swift
// TipTour/Agents/Skills/DemonstrationTypes.swift

import CoreGraphics
import Foundation

// MARK: - Action type taxonomy

enum ObservedActionType: String, Codable, Sendable {
    case click
    case type
    case keyPress
    case appSwitch
    case scroll
}

// MARK: - One recorded user action

struct ObservedAction: Codable, Sendable {
    let timestamp: Date
    let type: ObservedActionType
    let appName: String
    let point: CGPoint?
    let text: String?
    let keyDescription: String?
    let scrollDelta: CGFloat?
    let screenshotJPEG: Data?
}

// MARK: - Full recording session

struct ActionTrajectory: Sendable {
    let startedAt: Date
    let endedAt: Date
    let actions: [ObservedAction]
}
```

- [ ] **Step 4: Run tests to confirm they pass**

Run: Cmd+U in Xcode
Expected: All 5 tests in `ObservedActionTests` and `ActionTrajectoryTests` pass.

- [ ] **Step 5: Commit**

```bash
git add TipTour/Agents/Skills/DemonstrationTypes.swift TipTourTests/DemonstrationTests.swift
git commit -m "add DemonstrationTypes data model for Phase 4C"
```

---

## Task 2: `DemonstrationRecorder`

**Files:**
- Create: `TipTour/Agents/Skills/DemonstrationRecorder.swift`
- Modify: `TipTourTests/DemonstrationTests.swift` (add DemonstrationRecorder test suite)

- [ ] **Step 1: Write failing tests for DemonstrationRecorder**

Append to `TipTourTests/DemonstrationTests.swift`:

```swift
// MARK: - DemonstrationRecorder tests
// All tests inject actions via simulate* methods — no live CGEventTap needed.

@Suite("DemonstrationRecorder")
struct DemonstrationRecorderTests {

    @Test func startClearsPreviousActions() async {
        let recorder = DemonstrationRecorder()
        recorder.start()
        recorder.simulatePrintableKey(appName: "Xcode", characters: "a")
        _ = recorder.stop()
        // Second recording starts fresh
        recorder.start()
        let trajectory = recorder.stop()
        #expect(trajectory.actions.isEmpty)
    }

    @Test func stopReturnsCorrectTimestamps() async {
        let recorder = DemonstrationRecorder()
        let before = Date.now
        recorder.start()
        let trajectory = recorder.stop()
        let after = Date.now
        #expect(trajectory.startedAt >= before)
        #expect(trajectory.endedAt >= trajectory.startedAt)
        #expect(trajectory.endedAt <= after)
    }

    @Test func consecutiveKeystrokesToSameAppMergeIntoOneTypeAction() async {
        let recorder = DemonstrationRecorder()
        recorder.start()
        recorder.simulatePrintableKey(appName: "Terminal", characters: "p")
        recorder.simulatePrintableKey(appName: "Terminal", characters: "n")
        recorder.simulatePrintableKey(appName: "Terminal", characters: "p")
        recorder.simulatePrintableKey(appName: "Terminal", characters: "m")
        let trajectory = recorder.stop()
        let typeActions = trajectory.actions.filter { $0.type == .type }
        #expect(typeActions.count == 1)
        #expect(typeActions.first?.text == "pnpm")
    }

    @Test func keystrokeToNewAppFlushesBufferAndStartsFresh() async {
        let recorder = DemonstrationRecorder()
        recorder.start()
        recorder.simulatePrintableKey(appName: "Terminal", characters: "p")
        recorder.simulatePrintableKey(appName: "Terminal", characters: "n")
        // Switch apps
        recorder.simulatePrintableKey(appName: "Xcode", characters: "x")
        let trajectory = recorder.stop()
        let typeActions = trajectory.actions.filter { $0.type == .type }
        #expect(typeActions.count == 2)
        #expect(typeActions[0].text == "pn")
        #expect(typeActions[0].appName == "Terminal")
        #expect(typeActions[1].text == "x")
        #expect(typeActions[1].appName == "Xcode")
    }

    @Test func nonPrintableKeyFlushesTypingBufferAndAppendsKeyPress() async {
        let recorder = DemonstrationRecorder()
        recorder.start()
        recorder.simulatePrintableKey(appName: "Terminal", characters: "ls")
        recorder.simulateNonPrintableKey(appName: "Terminal", keyDescription: "Return")
        let trajectory = recorder.stop()
        #expect(trajectory.actions.count == 2)
        #expect(trajectory.actions[0].type == .type)
        #expect(trajectory.actions[0].text == "ls")
        #expect(trajectory.actions[1].type == .keyPress)
        #expect(trajectory.actions[1].keyDescription == "Return")
    }

    @Test func appSwitchFlushesPendingTypingBufferBeforeAppendingSwitch() async {
        let recorder = DemonstrationRecorder()
        recorder.start()
        recorder.simulatePrintableKey(appName: "Terminal", characters: "hello")
        recorder.simulateAppSwitch(newAppName: "Finder")
        let trajectory = recorder.stop()
        #expect(trajectory.actions.count == 2)
        #expect(trajectory.actions[0].type == .type)
        #expect(trajectory.actions[0].text == "hello")
        #expect(trajectory.actions[1].type == .appSwitch)
        #expect(trajectory.actions[1].appName == "Finder")
    }

    @Test func stopFlushesRemainingTypingBuffer() async {
        let recorder = DemonstrationRecorder()
        recorder.start()
        recorder.simulatePrintableKey(appName: "Xcode", characters: "run")
        // Do NOT explicitly flush — stop() must do it
        let trajectory = recorder.stop()
        let typeActions = trajectory.actions.filter { $0.type == .type }
        #expect(typeActions.count == 1)
        #expect(typeActions.first?.text == "run")
    }

    @Test func scrollDebounceAllowsOneEntryPerHalfSecondPerApp() async {
        let recorder = DemonstrationRecorder()
        recorder.start()
        recorder.simulateScroll(appName: "Finder", delta: -100)
        recorder.simulateScroll(appName: "Finder", delta: -200)  // debounced
        recorder.simulateScroll(appName: "Safari", delta: -50)   // different app — allowed
        let trajectory = recorder.stop()
        let scrollActions = trajectory.actions.filter { $0.type == .scroll }
        #expect(scrollActions.count == 2)
        #expect(scrollActions[0].appName == "Finder")
        #expect(scrollActions[1].appName == "Safari")
    }

    @Test func formatForLLMProducesOneLinePerAction() async {
        let recorder = DemonstrationRecorder()
        recorder.start()
        recorder.simulateClick(appName: "Xcode", point: CGPoint(x: 540, y: 320))
        recorder.simulatePrintableKey(appName: "Terminal", characters: "pnpm install")
        recorder.simulateNonPrintableKey(appName: "Terminal", keyDescription: "Cmd+Return")
        recorder.simulateAppSwitch(newAppName: "Finder")
        recorder.simulateScroll(appName: "Finder", delta: -340)
        let trajectory = recorder.stop()
        let (text, images) = DemonstrationRecorder.formatForLLM(trajectory)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count == 5)
        #expect(lines[0].contains("click"))
        #expect(lines[0].contains("Xcode"))
        #expect(lines[1].contains("type"))
        #expect(lines[1].contains("pnpm install"))
        #expect(lines[2].contains("keyPress"))
        #expect(lines[2].contains("Cmd+Return"))
        #expect(lines[3].contains("appSwitch"))
        #expect(lines[3].contains("Finder"))
        #expect(lines[4].contains("scroll"))
        // No screenshots injected via simulate — images array should be empty
        #expect(images.isEmpty)
    }

    @Test func formatForLLMIncludesScreenshotNote() async {
        let recorder = DemonstrationRecorder()
        recorder.start()
        let fakeJPEG = Data([0xFF, 0xD8, 0xFF, 0xE0])
        recorder.simulateClick(appName: "Xcode", point: .zero, screenshotJPEG: fakeJPEG)
        let trajectory = recorder.stop()
        let (text, images) = DemonstrationRecorder.formatForLLM(trajectory)
        #expect(text.contains("[screenshot]"))
        #expect(images.count == 1)
        #expect(images[0] == fakeJPEG)
    }
}
```

- [ ] **Step 2: Run tests to confirm they fail**

Run: Cmd+U in Xcode
Expected: Compiler error — `DemonstrationRecorder` is not defined.

- [ ] **Step 3: Create `DemonstrationRecorder.swift`**

```swift
// TipTour/Agents/Skills/DemonstrationRecorder.swift

import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

// Not an actor: CGEventTap C callbacks are synchronous and cannot cross an actor boundary.
// NSLock guards all mutable state instead.
final class DemonstrationRecorder: @unchecked Sendable {

    private let lock = NSLock()
    private var _actions: [ObservedAction] = []
    private var _startedAt: Date = .now
    private var eventTap: CFMachPort?
    private var eventTapRunLoopSource: CFRunLoopSource?
    private var typingBuffer: String = ""
    private var typingAppName: String = ""
    private var lastScrollTimePerApp: [String: Date] = [:]
    private var workspaceObserver: NSObjectProtocol?

    // MARK: - Public API

    func start() {
        lock.withLock {
            _startedAt = .now
            _actions = []
            typingBuffer = ""
            typingAppName = ""
            lastScrollTimePerApp = [:]
        }
        installEventTap()
        installWorkspaceObserver()
    }

    func stop() -> ActionTrajectory {
        let endedAt = Date.now
        flushTypingBuffer()
        removeEventTap()
        removeWorkspaceObserver()
        return lock.withLock {
            ActionTrajectory(startedAt: _startedAt, endedAt: endedAt, actions: _actions)
        }
    }

    // MARK: - Internal for unit tests (inject actions without a live CGEventTap)

    func simulateClick(appName: String, point: CGPoint, screenshotJPEG: Data? = nil) {
        flushTypingBuffer()
        let action = ObservedAction(
            timestamp: .now, type: .click, appName: appName,
            point: point, text: nil, keyDescription: nil,
            scrollDelta: nil, screenshotJPEG: screenshotJPEG
        )
        appendAction(action)
    }

    func simulatePrintableKey(appName: String, characters: String) {
        let currentApp = lock.withLock { typingAppName }
        if appName == currentApp {
            lock.withLock { typingBuffer += characters }
        } else {
            flushTypingBuffer()
            lock.withLock {
                typingBuffer = characters
                typingAppName = appName
            }
        }
    }

    func simulateNonPrintableKey(appName: String, keyDescription: String) {
        flushTypingBuffer()
        let action = ObservedAction(
            timestamp: .now, type: .keyPress, appName: appName,
            point: nil, text: nil, keyDescription: keyDescription,
            scrollDelta: nil, screenshotJPEG: nil
        )
        appendAction(action)
    }

    func simulateAppSwitch(newAppName: String) {
        flushTypingBuffer()
        let action = ObservedAction(
            timestamp: .now, type: .appSwitch, appName: newAppName,
            point: nil, text: nil, keyDescription: nil,
            scrollDelta: nil, screenshotJPEG: nil
        )
        appendAction(action)
        lock.withLock { typingAppName = "" }
    }

    func simulateScroll(appName: String, delta: CGFloat) {
        let now = Date.now
        let debounced = lock.withLock { () -> Bool in
            if let last = lastScrollTimePerApp[appName],
               now.timeIntervalSince(last) < 0.5 { return true }
            lastScrollTimePerApp[appName] = now
            return false
        }
        guard !debounced else { return }
        let action = ObservedAction(
            timestamp: now, type: .scroll, appName: appName,
            point: nil, text: nil, keyDescription: nil,
            scrollDelta: delta, screenshotJPEG: nil
        )
        appendAction(action)
    }

    // MARK: - Trajectory formatting

    static func formatForLLM(_ trajectory: ActionTrajectory) -> (text: String, images: [Data]) {
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm:ss"
        timeFormatter.locale = Locale(identifier: "en_US_POSIX")

        var lines: [String] = []
        var images: [Data] = []

        for action in trajectory.actions {
            let timeStr = timeFormatter.string(from: action.timestamp)
            let line: String

            switch action.type {
            case .click:
                let pointStr = action.point.map { "(\(Int($0.x)), \(Int($0.y)))" } ?? "(?, ?)"
                let screenshotNote = action.screenshotJPEG != nil ? " [screenshot]" : ""
                line = "[\(timeStr)] click at \(pointStr) in \(action.appName)\(screenshotNote)"
                if let jpg = action.screenshotJPEG { images.append(jpg) }
            case .type:
                line = "[\(timeStr)] type \"\(action.text ?? "")\" in \(action.appName)"
            case .keyPress:
                line = "[\(timeStr)] keyPress \(action.keyDescription ?? "?") in \(action.appName)"
            case .appSwitch:
                line = "[\(timeStr)] appSwitch → \(action.appName)"
            case .scroll:
                let direction = (action.scrollDelta ?? 0) <= 0 ? "↓" : "↑"
                let amount = Int(abs(action.scrollDelta ?? 0))
                line = "[\(timeStr)] scroll \(direction) \(amount)pt in \(action.appName)"
            }
            lines.append(line)
        }

        return (lines.joined(separator: "\n"), images)
    }

    // MARK: - Private helpers

    private func appendAction(_ action: ObservedAction) {
        lock.withLock { _actions.append(action) }
    }

    private func flushTypingBuffer() {
        let (text, appName) = lock.withLock { () -> (String, String) in
            let t = typingBuffer
            let a = typingAppName
            typingBuffer = ""
            typingAppName = ""
            return (t, a)
        }
        guard !text.isEmpty else { return }
        let action = ObservedAction(
            timestamp: .now, type: .type, appName: appName,
            point: nil, text: text, keyDescription: nil,
            scrollDelta: nil, screenshotJPEG: nil
        )
        appendAction(action)
    }

    // MARK: - CGEventTap installation

    private func installEventTap() {
        let eventMask: CGEventMask =
            (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.scrollWheel.rawValue)

        let tapCallback: CGEventTapCallBack = { _, eventType, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let recorder = Unmanaged<DemonstrationRecorder>.fromOpaque(userInfo).takeUnretainedValue()
            recorder.handleCGEvent(type: eventType, event: event)
            return Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: tapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("[DemonstrationRecorder] ⚠️ failed to create CGEventTap")
            return
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            return
        }

        eventTap = tap
        eventTapRunLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func removeEventTap() {
        if let source = eventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            eventTapRunLoopSource = nil
        }
        if let tap = eventTap {
            CFMachPortInvalidate(tap)
            eventTap = nil
        }
    }

    // MARK: - NSWorkspace app-switch observer

    private func installWorkspaceObserver() {
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let newAppName = app.localizedName else { return }
            self.flushTypingBuffer()
            let action = ObservedAction(
                timestamp: .now, type: .appSwitch, appName: newAppName,
                point: nil, text: nil, keyDescription: nil,
                scrollDelta: nil, screenshotJPEG: nil
            )
            self.appendAction(action)
            self.lock.withLock { self.typingAppName = "" }
        }
    }

    private func removeWorkspaceObserver() {
        if let observer = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            workspaceObserver = nil
        }
    }

    // MARK: - CGEventTap callback dispatch (runs on main thread)

    private func handleCGEvent(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .leftMouseDown:
            handleClickEvent(event)
        case .keyDown:
            handleKeyDownEvent(event)
        case .scrollWheel:
            handleScrollEvent(event)
        default:
            break
        }
    }

    private func handleClickEvent(_ event: CGEvent) {
        flushTypingBuffer()
        let appName = NSWorkspace.shared.frontmostApplication?.localizedName ?? "Unknown"
        // Convert from Quartz (top-left origin, y-down) to AppKit (bottom-left origin, y-up)
        let quartzLocation = event.location
        let primaryScreenHeight = NSScreen.screens.first?.frame.height ?? 0
        let appKitPoint = CGPoint(x: quartzLocation.x, y: primaryScreenHeight - quartzLocation.y)
        let timestamp = Date.now

        Task { @MainActor [weak self] in
            guard let self else { return }
            let screenshotJPEG = await Self.captureClickScreenshotJPEG()
            let action = ObservedAction(
                timestamp: timestamp, type: .click, appName: appName,
                point: appKitPoint, text: nil, keyDescription: nil,
                scrollDelta: nil, screenshotJPEG: screenshotJPEG
            )
            self.appendAction(action)
        }
    }

    @MainActor
    private static func captureClickScreenshotJPEG() async -> Data? {
        guard let cgImage = try? await CompanionScreenCaptureUtility.capturePrimaryScreenAsCGImage() else {
            return nil
        }
        return NSBitmapImageRep(cgImage: cgImage)
            .representation(using: .jpeg, properties: [.compressionFactor: 0.5])
    }

    private func handleKeyDownEvent(_ event: CGEvent) {
        guard let nsEvent = NSEvent(cgEvent: event) else { return }
        let appName = NSWorkspace.shared.frontmostApplication?.localizedName ?? "Unknown"

        let chars = nsEvent.charactersIgnoringModifiers ?? ""
        let modifiers = nsEvent.modifierFlags
        let hasCommandOrControl = modifiers.contains(.command) || modifiers.contains(.control)

        // Printable: produces a visible character AND no Cmd/Ctrl modifier
        let isPrintable = !chars.isEmpty
            && !hasCommandOrControl
            && chars.unicodeScalars.allSatisfy({ !$0.properties.isControl })

        if isPrintable {
            let currentApp = lock.withLock { typingAppName }
            if appName == currentApp {
                lock.withLock { typingBuffer += chars }
            } else {
                flushTypingBuffer()
                lock.withLock {
                    typingBuffer = chars
                    typingAppName = appName
                }
            }
        } else {
            flushTypingBuffer()
            let keyDescription = buildKeyDescription(from: nsEvent)
            let action = ObservedAction(
                timestamp: .now, type: .keyPress, appName: appName,
                point: nil, text: nil, keyDescription: keyDescription,
                scrollDelta: nil, screenshotJPEG: nil
            )
            appendAction(action)
        }
    }

    private func handleScrollEvent(_ event: CGEvent) {
        let appName = NSWorkspace.shared.frontmostApplication?.localizedName ?? "Unknown"
        let delta = event.getDoubleValueField(.scrollWheelEventDeltaAxis1)
        simulateScroll(appName: appName, delta: CGFloat(delta))
    }

    private func buildKeyDescription(from nsEvent: NSEvent) -> String {
        var parts: [String] = []
        let modifiers = nsEvent.modifierFlags
        if modifiers.contains(.control) { parts.append("Ctrl") }
        if modifiers.contains(.option) { parts.append("Opt") }
        if modifiers.contains(.shift) { parts.append("Shift") }
        if modifiers.contains(.command) { parts.append("Cmd") }

        let keyName: String
        switch nsEvent.keyCode {
        case 36: keyName = "Return"
        case 48: keyName = "Tab"
        case 53: keyName = "Escape"
        case 51: keyName = "Delete"
        case 123: keyName = "Left"
        case 124: keyName = "Right"
        case 125: keyName = "Down"
        case 126: keyName = "Up"
        case 116: keyName = "PageUp"
        case 121: keyName = "PageDown"
        case 115: keyName = "Home"
        case 119: keyName = "End"
        case 49: keyName = "Space"
        default:
            keyName = nsEvent.charactersIgnoringModifiers?.uppercased() ?? "Key\(nsEvent.keyCode)"
        }

        parts.append(keyName)
        return parts.joined(separator: "+")
    }
}
```

- [ ] **Step 4: Run tests to confirm they pass**

Run: Cmd+U in Xcode
Expected: All 9 tests in `DemonstrationRecorderTests` pass.

- [ ] **Step 5: Commit**

```bash
git add TipTour/Agents/Skills/DemonstrationRecorder.swift TipTourTests/DemonstrationTests.swift
git commit -m "add DemonstrationRecorder with CGEventTap recording and formatForLLM"
```

---

## Task 3: LLM Image Support — `LLMProvider.swift` + `AnthropicProvider.swift`

**Files:**
- Modify: `TipTour/Agents/Core/LLMProvider.swift`
- Modify: `TipTour/Agents/Providers/AnthropicProvider.swift`
- Modify: `TipTourTests/DemonstrationTests.swift` (add image content block test)

`LLMMessage` needs an optional `imagesJPEG: [Data]?` field so `SkillExtractor` can attach screenshots to the user message. `AnthropicProvider` must emit Anthropic's content-block array format when images are present instead of a plain string.

- [ ] **Step 1: Write failing test for image content blocks**

Append to `TipTourTests/DemonstrationTests.swift`:

```swift
// MARK: - LLMMessage image field test

@Suite("LLMMessageImages")
struct LLMMessageImagesTests {

    @Test func llmMessageCanCarryImages() {
        let fakeJPEG = Data([0xFF, 0xD8])
        let message = LLMMessage(
            role: .user,
            content: "What is in this image?",
            imagesJPEG: [fakeJPEG]
        )
        #expect(message.imagesJPEG?.count == 1)
        #expect(message.imagesJPEG?.first == fakeJPEG)
    }

    @Test func llmMessageWithoutImagesHasNilImagesJPEG() {
        let message = LLMMessage(role: .user, content: "Hello")
        #expect(message.imagesJPEG == nil)
    }
}
```

- [ ] **Step 2: Run tests to confirm they fail**

Run: Cmd+U in Xcode
Expected: Compiler error — `LLMMessage.init` does not accept `imagesJPEG`.

- [ ] **Step 3: Extend `LLMMessage` with `imagesJPEG`**

Open `TipTour/Agents/Core/LLMProvider.swift`. Add the `imagesJPEG` property and update the initializer. The property is optional and defaults to `nil` so all existing callers continue to compile unchanged.

Replace the `LLMMessage` struct (lines 13–31 in the current file) with:

```swift
struct LLMMessage: Codable, Sendable {
    enum Role: String, Codable, Sendable {
        case system, user, assistant, tool
    }

    let role: Role
    let content: String
    // Only set when role == .tool (the result of a tool call)
    let toolCallId: String?
    // Only set when role == .tool (which tool produced this result)
    let toolName: String?
    // JPEG screenshots to attach as vision content blocks (user messages only)
    let imagesJPEG: [Data]?

    init(
        role: Role,
        content: String,
        toolCallId: String? = nil,
        toolName: String? = nil,
        imagesJPEG: [Data]? = nil
    ) {
        self.role = role
        self.content = content
        self.toolCallId = toolCallId
        self.toolName = toolName
        self.imagesJPEG = imagesJPEG
    }
}
```

- [ ] **Step 4: Update `AnthropicProvider.convertMessageToAnthropicDict` to handle images**

Open `TipTour/Agents/Providers/AnthropicProvider.swift`. Find `convertMessageToAnthropicDict` (around line 82). Replace its `default:` branch so that when `imagesJPEG` is non-empty, the content is a content-block array rather than a plain string:

```swift
private func convertMessageToAnthropicDict(_ message: LLMMessage) -> [String: Any] {
    switch message.role {
    case .tool:
        // Anthropic tool results must be wrapped in a user-role message with content blocks
        return [
            "role": "user",
            "content": [[
                "type": "tool_result",
                "tool_use_id": message.toolCallId ?? "",
                "content": message.content
            ]]
        ]
    case .assistant:
        return ["role": "assistant", "content": message.content]
    default:
        // When images are attached, send a content-block array (images first, then text).
        // The Anthropic Messages API requires base64 JPEG in the "source.data" field.
        if let images = message.imagesJPEG, !images.isEmpty {
            var contentBlocks: [[String: Any]] = images.map { imageData in
                [
                    "type": "image",
                    "source": [
                        "type": "base64",
                        "media_type": "image/jpeg",
                        "data": imageData.base64EncodedString()
                    ] as [String: Any]
                ] as [String: Any]
            }
            contentBlocks.append(["type": "text", "text": message.content])
            return ["role": "user", "content": contentBlocks]
        }
        return ["role": "user", "content": message.content]
    }
}
```

- [ ] **Step 5: Run tests to confirm they pass**

Run: Cmd+U in Xcode
Expected: All 2 tests in `LLMMessageImagesTests` pass. All existing tests still pass.

- [ ] **Step 6: Commit**

```bash
git add TipTour/Agents/Core/LLMProvider.swift TipTour/Agents/Providers/AnthropicProvider.swift TipTourTests/DemonstrationTests.swift
git commit -m "extend LLMMessage with imagesJPEG for vision content blocks in AnthropicProvider"
```

---

## Task 4: `SkillExtractor` Actor

**Files:**
- Create: `TipTour/Agents/Skills/SkillExtractor.swift`
- Modify: `TipTourTests/DemonstrationTests.swift` (add SkillExtractor test suite)

- [ ] **Step 1: Write failing tests for SkillExtractor**

Append to `TipTourTests/DemonstrationTests.swift`:

```swift
// MARK: - SkillExtractor tests

@Suite("SkillExtractor")
struct SkillExtractorTests {

    private func makeTrajectoryWithClickAndType() -> ActionTrajectory {
        let actions: [ObservedAction] = [
            ObservedAction(timestamp: Date(timeIntervalSince1970: 1_000_000), type: .click,
                           appName: "Xcode", point: CGPoint(x: 100, y: 200),
                           text: nil, keyDescription: nil, scrollDelta: nil, screenshotJPEG: nil),
            ObservedAction(timestamp: Date(timeIntervalSince1970: 1_000_001), type: .type,
                           appName: "Terminal", point: nil,
                           text: "pnpm install", keyDescription: nil, scrollDelta: nil, screenshotJPEG: nil)
        ]
        return ActionTrajectory(
            startedAt: Date(timeIntervalSince1970: 1_000_000),
            endedAt: Date(timeIntervalSince1970: 1_000_010),
            actions: actions
        )
    }

    @Test func extractSuccessReturnsMockBody() async throws {
        let mockProvider = MockLLMProvider(id: "skill-extractor-test")
        mockProvider.responseToReturn = .text("## Steps\n\n1. Click in Xcode\n2. Type pnpm install\n\n## Result\n\nDependencies installed.")
        let extractor = SkillExtractor(providerOverride: mockProvider)

        let body = try await extractor.extract(
            trajectory: makeTrajectoryWithClickAndType(),
            name: "Install pnpm deps"
        )
        #expect(body.contains("## Steps"))
        #expect(body.contains("## Result"))
    }

    @Test func extractSendsTrajectoryTextToProvider() async throws {
        let mockProvider = MockLLMProvider(id: "skill-extractor-capture")
        mockProvider.responseToReturn = .text("## Steps\n\n1. Step\n\n## Result\n\nDone.")
        let extractor = SkillExtractor(providerOverride: mockProvider)

        _ = try await extractor.extract(
            trajectory: makeTrajectoryWithClickAndType(),
            name: "test skill"
        )
        // Provider should have received one complete() call
        #expect(mockProvider.capturedMessages.count == 1)
        let messages = mockProvider.capturedMessages[0]
        // Should have system + user messages
        #expect(messages.count == 2)
        #expect(messages[0].role == .system)
        #expect(messages[1].role == .user)
        // User message should contain the trajectory text
        #expect(messages[1].content.contains("click"))
        #expect(messages[1].content.contains("type"))
    }

    @Test func extractEmptyTrajectoryReturnsBodyWithResultSection() async throws {
        let mockProvider = MockLLMProvider(id: "skill-extractor-empty")
        mockProvider.responseToReturn = .text("## Result\n\nEmpty demonstration.")
        let extractor = SkillExtractor(providerOverride: mockProvider)

        let emptyTrajectory = ActionTrajectory(startedAt: .now, endedAt: .now, actions: [])
        let body = try await extractor.extract(trajectory: emptyTrajectory, name: "empty")
        #expect(body.contains("## Result"))
    }

    @Test func extractRethrowsProviderError() async {
        let mockProvider = MockLLMProvider(id: "skill-extractor-throw")
        mockProvider.shouldThrow = true
        let extractor = SkillExtractor(providerOverride: mockProvider)

        do {
            _ = try await extractor.extract(
                trajectory: ActionTrajectory(startedAt: .now, endedAt: .now, actions: []),
                name: "fail"
            )
            Issue.record("Expected error to be thrown")
        } catch {
            #expect(error is LLMProviderError)
        }
    }

    @Test func extractThrowsWhenNoProviderAvailable() async {
        // No providerOverride + LLMProviderRegistry has no anthropic provider registered
        // We can verify this by using a freshly-isolated SkillExtractor instance with nil override
        // and checking the error. Since the registry won't have the key in test context,
        // this should throw SkillExtractorError.missingProvider.
        let extractor = SkillExtractor(providerOverride: nil)
        do {
            _ = try await extractor.extract(
                trajectory: ActionTrajectory(startedAt: .now, endedAt: .now, actions: []),
                name: "no-provider"
            )
            // If the registry happens to have a provider (unlikely in unit tests), that's OK too
        } catch let error as SkillExtractorError {
            #expect(error == .missingProvider)
        } catch {
            // Any error is acceptable here — either missingProvider or an API call failure
        }
    }
}
```

- [ ] **Step 2: Run tests to confirm they fail**

Run: Cmd+U in Xcode
Expected: Compiler error — `SkillExtractor` and `SkillExtractorError` are not defined.

- [ ] **Step 3: Create `SkillExtractor.swift`**

```swift
// TipTour/Agents/Skills/SkillExtractor.swift

import Foundation

// MARK: - Errors

enum SkillExtractorError: Error, Equatable {
    case missingProvider
    case unexpectedResponse
}

// MARK: - Actor singleton

actor SkillExtractor {

    static let shared = SkillExtractor()

    // Injected in tests to avoid hitting LLMProviderRegistry or the network.
    private let providerOverride: (any LLMProvider)?

    init(providerOverride: (any LLMProvider)? = nil) {
        self.providerOverride = providerOverride
    }

    // MARK: - Public API

    /// Formats `trajectory` into text + screenshots, calls Claude, and returns
    /// the raw skill-body markdown string.
    func extract(trajectory: ActionTrajectory, name: String) async throws -> String {
        let provider = try await resolvedProvider()
        let (trajectoryText, screenshotImages) = DemonstrationRecorder.formatForLLM(trajectory)

        let systemMessage = LLMMessage(role: .system, content: Self.skillExtractionSystemPrompt)
        let userContent = "Skill name: \(name)\n\n\(trajectoryText)"
        let userMessage = LLMMessage(
            role: .user,
            content: userContent,
            imagesJPEG: screenshotImages.isEmpty ? nil : screenshotImages
        )

        let response = try await provider.complete(messages: [systemMessage, userMessage], tools: [])

        guard case .text(let body) = response, !body.isEmpty else {
            throw SkillExtractorError.unexpectedResponse
        }

        return body
    }

    // MARK: - Private helpers

    private func resolvedProvider() async throws -> any LLMProvider {
        if let override = providerOverride { return override }
        guard let provider = await LLMProviderRegistry.shared.provider(id: "anthropic-claude-sonnet-4-6") else {
            throw SkillExtractorError.missingProvider
        }
        return provider
    }

    // MARK: - System prompt

    private static let skillExtractionSystemPrompt = """
    You are extracting a reusable skill from a user's screen recording.
    The user performed a task step by step. Your job is to write a clear,
    numbered procedure that a future agent can follow to repeat this task.

    Format your response as:

    ## Steps

    1. [action description]
    2. [action description]
    ...

    ## Result

    [one sentence describing what the procedure accomplishes]

    Be concise. Write each step as a human-readable instruction, not code.
    Do not include timestamps or coordinates. Focus on the intent of each action.
    """
}
```

- [ ] **Step 4: Run tests to confirm they pass**

Run: Cmd+U in Xcode
Expected: 5 tests in `SkillExtractorTests` pass. (The `extractThrowsWhenNoProviderAvailable` test is lenient — any error is acceptable.)

- [ ] **Step 5: Commit**

```bash
git add TipTour/Agents/Skills/SkillExtractor.swift TipTourTests/DemonstrationTests.swift
git commit -m "add SkillExtractor actor — formats trajectory and calls Claude to synthesize skill"
```

---

## Task 5: `CompanionManager` Wiring

**Files:**
- Modify: `TipTour/CompanionManager.swift`
- Modify: `TipTourTests/DemonstrationTests.swift` (add CompanionManager state tests)

- [ ] **Step 1: Write failing tests for CompanionManager demonstration state**

Append to `TipTourTests/DemonstrationTests.swift`:

```swift
// MARK: - CompanionManager demonstration state tests

// .serialized prevents concurrent mutation of CompanionManager (which is @MainActor)
@Suite("CompanionManagerDemonstrationState", .serialized)
struct CompanionManagerDemonstrationStateTests {

    @Test @MainActor func startDemonstrationSetsFlag() {
        let manager = CompanionManager()
        manager.startDemonstration()
        #expect(manager.isDemonstratingSkill == true)
        manager.stopDemonstration()  // clean up
    }

    @Test @MainActor func stopDemonstrationClearsFlagAndPopulatesTrajectory() {
        let manager = CompanionManager()
        manager.startDemonstration()
        manager.stopDemonstration()
        #expect(manager.isDemonstratingSkill == false)
        #expect(manager.pendingTrajectory != nil)
    }

    @Test @MainActor func discardDemonstrationClearsPendingTrajectory() {
        let manager = CompanionManager()
        manager.startDemonstration()
        manager.stopDemonstration()
        #expect(manager.pendingTrajectory != nil)
        manager.discardDemonstration()
        #expect(manager.pendingTrajectory == nil)
        #expect(manager.skillExtractionError == nil)
    }

    @Test @MainActor func saveSkillSuccessClearsPendingTrajectory() async {
        let manager = CompanionManager()
        let mockProvider = MockLLMProvider(id: "save-skill-success")
        mockProvider.responseToReturn = .text("## Steps\n\n1. Do thing\n\n## Result\n\nDone.")
        let mockExtractor = SkillExtractor(providerOverride: mockProvider)
        manager.skillExtractorOverrideForTests = mockExtractor

        manager.startDemonstration()
        manager.stopDemonstration()
        #expect(manager.pendingTrajectory != nil)

        await manager.saveSkill(name: "Test Skill")

        #expect(manager.pendingTrajectory == nil)
        #expect(manager.isExtractingSkill == false)
        #expect(manager.skillExtractionError == nil)
    }

    @Test @MainActor func saveSkillFailureSetsErrorAndClearsExtractingFlag() async {
        let manager = CompanionManager()
        let mockProvider = MockLLMProvider(id: "save-skill-failure")
        mockProvider.shouldThrow = true
        let mockExtractor = SkillExtractor(providerOverride: mockProvider)
        manager.skillExtractorOverrideForTests = mockExtractor

        manager.startDemonstration()
        manager.stopDemonstration()

        await manager.saveSkill(name: "Failing Skill")

        #expect(manager.isExtractingSkill == false)
        #expect(manager.skillExtractionError != nil)
        // pendingTrajectory remains so the user can retry
        #expect(manager.pendingTrajectory != nil)
    }
}
```

- [ ] **Step 2: Run tests to confirm they fail**

Run: Cmd+U in Xcode
Expected: Compiler error — `CompanionManager` missing `isDemonstratingSkill`, `pendingTrajectory`, etc.

- [ ] **Step 3: Add demonstration properties and `demonstrationRecorder` to `CompanionManager`**

Open `TipTour/CompanionManager.swift`. After the `isOverlayVisible` `@Published` property (around line 46), add:

```swift
    // MARK: - Skill Demonstration (Phase 4C)

    @Published var isDemonstratingSkill: Bool = false
    @Published var pendingTrajectory: ActionTrajectory? = nil
    @Published var isExtractingSkill: Bool = false
    @Published var skillExtractionError: String? = nil

    private let demonstrationRecorder = DemonstrationRecorder()

    // Injected in tests to avoid hitting the live SkillExtractor.
    var skillExtractorOverrideForTests: SkillExtractor? = nil

    private var effectiveSkillExtractor: SkillExtractor {
        skillExtractorOverrideForTests ?? .shared
    }
```

- [ ] **Step 4: Add the four demonstration methods to `CompanionManager`**

At the end of `CompanionManager`, before the closing `}`, add a new extension section. Find a logical place — after the `spawnBackgroundAgent` method (around line 635) works well. Add:

```swift
    // MARK: - Skill Demonstration

    func startDemonstration() {
        isDemonstratingSkill = true
        demonstrationRecorder.start()
    }

    func stopDemonstration() {
        let trajectory = demonstrationRecorder.stop()
        pendingTrajectory = trajectory
        isDemonstratingSkill = false
    }

    func saveSkill(name: String) async {
        guard let trajectory = pendingTrajectory else { return }
        isExtractingSkill = true
        skillExtractionError = nil
        do {
            let body = try await effectiveSkillExtractor.extract(trajectory: trajectory, name: name)
            let slug = SkillLibraryStore.generateSlug(from: name)
            await SkillLibraryStore.shared.write(
                slug: slug,
                name: name,
                description: String(body.prefix(120)),
                taskTypes: [.generalMac],
                body: body
            )
            pendingTrajectory = nil
            isExtractingSkill = false
        } catch {
            skillExtractionError = error.localizedDescription
            isExtractingSkill = false
        }
    }

    func discardDemonstration() {
        pendingTrajectory = nil
        skillExtractionError = nil
    }
```

- [ ] **Step 5: Run tests to confirm they pass**

Run: Cmd+U in Xcode
Expected: All 5 tests in `CompanionManagerDemonstrationStateTests` pass.

- [ ] **Step 6: Commit**

```bash
git add TipTour/CompanionManager.swift TipTourTests/DemonstrationTests.swift
git commit -m "wire DemonstrationRecorder and SkillExtractor into CompanionManager"
```

---

## Task 6: Hotkey — Ctrl+Option+W

**Files:**
- Modify: `TipTour/GlobalPushToTalkShortcutMonitor.swift`
- Modify: `TipTour/CompanionManager.swift` (add `demonstrationShortcutCancellable` + subscribe)

There are no unit tests for CGEventTap behavior — test by pressing Ctrl+Option+W while the app is running.

- [ ] **Step 1: Add `demonstrationShortcutPublisher` to `GlobalPushToTalkShortcutMonitor`**

Open `TipTour/GlobalPushToTalkShortcutMonitor.swift`. After the line declaring `shortcutTransitionPublisher` (line 16), add:

```swift
    /// Fires once every time Ctrl+Option+W is pressed.
    /// CompanionManager subscribes to this to toggle demonstration recording.
    let demonstrationShortcutPublisher = PassthroughSubject<Void, Never>()

    private static let demonstrationHotkeyKeyCode: UInt16 = 13  // W key
```

- [ ] **Step 2: Detect Ctrl+Option+W in `handleGlobalEventTap`**

In `handleGlobalEventTap`, after the `switch shortcutTransition {` block (just before `return Unmanaged.passUnretained(event)`), add:

```swift
        // Detect Ctrl+Option+W for demonstration recording toggle
        if eventType == .keyDown {
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            if keyCode == Self.demonstrationHotkeyKeyCode {
                let modifierFlags = NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue))
                let isCtrlOptionHeld = modifierFlags.contains(.control)
                    && modifierFlags.contains(.option)
                    && !modifierFlags.contains(.command)
                    && !modifierFlags.contains(.shift)
                if isCtrlOptionHeld {
                    demonstrationShortcutPublisher.send()
                }
            }
        }
```

- [ ] **Step 3: Subscribe in `CompanionManager.bindShortcutTransitions()`**

Open `TipTour/CompanionManager.swift`. Find `private var shortcutTransitionCancellable: AnyCancellable?` (around line 62) and add:

```swift
    private var demonstrationShortcutCancellable: AnyCancellable?
```

Then find `bindShortcutTransitions()` (around line 749). After the existing `shortcutTransitionCancellable = ...` assignment, add:

```swift
        demonstrationShortcutCancellable = globalPushToTalkShortcutMonitor
            .demonstrationShortcutPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                guard let self else { return }
                if self.isDemonstratingSkill {
                    self.stopDemonstration()
                } else {
                    self.startDemonstration()
                }
            }
```

- [ ] **Step 4: Cancel `demonstrationShortcutCancellable` in `stop()`**

Find `stop()` in `CompanionManager` (around line 637). After `shortcutTransitionCancellable?.cancel()`, add:

```swift
        demonstrationShortcutCancellable?.cancel()
```

- [ ] **Step 5: Verify manually**

Build and run (Cmd+R). Press Ctrl+Option+W. The app should start recording (no visible UI yet — that's Task 7). Press Ctrl+Option+W again to stop. Check the Xcode console for no crashes.

- [ ] **Step 6: Commit**

```bash
git add TipTour/GlobalPushToTalkShortcutMonitor.swift TipTour/CompanionManager.swift
git commit -m "add Ctrl+Option+W hotkey for toggling demonstration recording"
```

---

## Task 7: Panel UI — Recording Button Row + Confirmation Sheet

**Files:**
- Modify: `TipTour/CompanionPanelView.swift`
- Modify: `TipTour/CLAUDE.md` (update file table for new files)

- [ ] **Step 1: Add a `@State` for the skill name input in `CompanionPanelView`**

Open `TipTour/CompanionPanelView.swift`. Find the existing `@State` properties (the `@State private var showDevTools` and related properties, around line 14). Add:

```swift
    @State private var pendingSkillName: String = ""
```

- [ ] **Step 2: Add the recording button row to `devToolsSection`**

Find `devToolsSection` in `CompanionPanelView.swift`. It currently starts with:

```swift
    private var devToolsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            #if DEBUG
            sectionHeader("DEBUG")
```

Just before `sectionHeader("API KEYS (optional)")`, insert the skill recording section. Locate the line `sectionHeader("API KEYS (optional)")` and add the following immediately before it:

```swift
            sectionHeader("SKILL RECORDING")

            if companionManager.isDemonstratingSkill {
                devToolRow("Stop Recording", systemImage: "stop.circle.fill", destructive: true) {
                    companionManager.stopDemonstration()
                } trailing: {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                        .opacity(0.9)
                }
            } else {
                devToolRow("Record Demonstration", systemImage: "record.circle") {
                    companionManager.startDemonstration()
                    NotificationCenter.default.post(name: .tipTourDismissPanel, object: nil)
                }
            }

            Spacer().frame(height: 4)
```

- [ ] **Step 3: Wire the confirmation sheet in `CompanionPanelView.body`**

Find the `.frame(width: 320)` modifier at the end of the `VStack` in `body`. The current code is:

```swift
        .frame(width: 320)
        .background(panelBackground)
```

Change it to:

```swift
        .frame(width: 320)
        .background(panelBackground)
        .sheet(isPresented: Binding(
            get: { companionManager.pendingTrajectory != nil },
            set: { if !$0 { companionManager.discardDemonstration() } }
        )) {
            SaveSkillSheetView(
                companionManager: companionManager,
                skillName: $pendingSkillName
            )
            .onAppear {
                let formatter = DateFormatter()
                formatter.dateStyle = .medium
                formatter.timeStyle = .none
                pendingSkillName = "Demonstration \(formatter.string(from: Date()))"
            }
        }
```

- [ ] **Step 4: Add `SaveSkillSheetView` to `CompanionPanelView.swift`**

At the end of `CompanionPanelView.swift`, after the closing `}` of the `CompanionPanelView` struct, add:

```swift
// MARK: - Save Skill Sheet

private struct SaveSkillSheetView: View {
    @ObservedObject var companionManager: CompanionManager
    @Binding var skillName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Save Demonstration as Skill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)

            VStack(alignment: .leading, spacing: 6) {
                Text("Skill name")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                TextField("Skill name", text: $skillName)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13))
            }

            if companionManager.isExtractingSkill {
                HStack(spacing: 8) {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(0.7)
                    Text("Extracting skill with Claude…")
                        .font(.system(size: 12))
                        .foregroundColor(DS.Colors.textSecondary)
                }
            }

            if let extractionError = companionManager.skillExtractionError {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.orange)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(extractionError)
                            .font(.system(size: 11))
                            .foregroundColor(DS.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Retry") {
                            Task { await companionManager.saveSkill(name: skillName) }
                        }
                        .font(.system(size: 11, weight: .medium))
                        .buttonStyle(.plain)
                        .foregroundColor(DS.Colors.accent)
                        .pointerCursor()
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.08)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.orange.opacity(0.3), lineWidth: 0.5))
            }

            HStack(spacing: 10) {
                Button("Discard") {
                    companionManager.discardDemonstration()
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
                .buttonStyle(.plain)
                .pointerCursor()

                Spacer()

                Button("Save Skill") {
                    Task { await companionManager.saveSkill(name: skillName) }
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(companionManager.isExtractingSkill || skillName.isEmpty
                              ? DS.Colors.accent.opacity(0.4)
                              : DS.Colors.accent)
                )
                .disabled(companionManager.isExtractingSkill || skillName.isEmpty)
                .pointerCursor()
            }
        }
        .padding(24)
        .frame(width: 360)
        .background(DS.Colors.background)
    }
}
```

- [ ] **Step 5: Update CLAUDE.md file table for new files**

Open `CLAUDE.md`. In the Key Files table, add three new rows for the new Swift files after the `SkillTools.swift` row:

```
| `TipTour/Agents/Skills/DemonstrationTypes.swift` | ~45 | `ObservedActionType`, `ObservedAction`, `ActionTrajectory` — data model for user demonstration recordings. |
| `TipTour/Agents/Skills/DemonstrationRecorder.swift` | ~260 | `final class @unchecked Sendable` that captures user actions via CGEventTap + NSWorkspace notifications. Accumulates keystrokes into `.type` actions; captures JPEG screenshots on click. `formatForLLM` converts a trajectory to compact text + ordered screenshot array. |
| `TipTour/Agents/Skills/SkillExtractor.swift` | ~65 | Actor singleton. Calls `DemonstrationRecorder.formatForLLM`, attaches screenshots via `LLMMessage.imagesJPEG`, calls `claude-sonnet-4-6` via `LLMProviderRegistry`, returns the skill-body markdown string. |
```

Also update the existing `CompanionManager.swift` and `GlobalPushToTalkShortcutMonitor.swift` row descriptions to mention the new demonstration functionality.

- [ ] **Step 6: Build and run — manual UI verification**

Run: Cmd+R in Xcode. Open the menu bar panel → click "Dev" → verify "SKILL RECORDING" section appears with "Record Demonstration" button. Click "Record Demonstration": the panel should close and recording should start (Ctrl+Option+W also starts it). Press Ctrl+Option+W to stop: the Save Skill sheet should appear. Enter a name and click "Save Skill": the sheet should close after Claude returns a response. If the Anthropic key is configured in Keychain, the full flow should work end-to-end. Check the `~/Library/Application Support/TipTour/skills/` directory for the saved `.md` file.

- [ ] **Step 7: Commit**

```bash
git add TipTour/CompanionPanelView.swift TipTour/CompanionManager.swift repo/CLAUDE.md
git commit -m "add recording button row and SaveSkillSheetView for Phase 4C demonstration UI"
```

---

## Self-Review

**Spec coverage check:**

| Spec requirement | Implemented in |
|---|---|
| `ObservedActionType`, `ObservedAction`, `ActionTrajectory` | Task 1 |
| `DemonstrationRecorder` final class @unchecked Sendable | Task 2 |
| `start()` / `stop()` / event handling | Task 2 |
| Typing accumulation (same-app merge, flush on switch) | Task 2 |
| Screenshot on click only via `captureClickScreenshotJPEG` | Task 2 |
| Scroll debounce (0.5s per app) | Task 2 |
| `formatForLLM` text + images | Task 2 |
| `LLMMessage.imagesJPEG` extension | Task 3 |
| `AnthropicProvider` image content blocks | Task 3 |
| `SkillExtractor` actor singleton | Task 4 |
| `extract(trajectory:name:)` → calls Claude | Task 4 |
| System prompt template | Task 4 |
| `CompanionManager.isDemonstratingSkill` / `pendingTrajectory` / `isExtractingSkill` / `skillExtractionError` | Task 5 |
| `startDemonstration` / `stopDemonstration` / `saveSkill` / `discardDemonstration` | Task 5 |
| `saveSkill` writes to `SkillLibraryStore` with `taskTypes: [.generalMac]` | Task 5 |
| Ctrl+Option+W hotkey (keycode 13 + Ctrl+Option) | Task 6 |
| `demonstrationShortcutPublisher` in GlobalPushToTalkShortcutMonitor | Task 6 |
| Panel recording button row (idle + recording states) | Task 7 |
| Confirmation sheet with name field + Save + Discard + spinner + error + Retry | Task 7 |
| `taskTypes: [.generalMac]` in `saveSkill` call | Task 5 |
| `DemonstrationTests.swift` | Tasks 1–5 |

**Placeholder scan:** None found.

**Type consistency check:**
- `DemonstrationRecorder.formatForLLM` → `(text: String, images: [Data])` — used consistently in Task 4 `SkillExtractor` and Task 2 tests.
- `SkillExtractor.extract(trajectory:name:)` → `async throws -> String` — used in Task 5 `CompanionManager.saveSkill` and Task 4 tests.
- `LLMMessage(role:content:imagesJPEG:)` — default nil, existing callers unaffected.
- `CompanionManager.saveSkill(name:)` — called as `Task { await companionManager.saveSkill(name: skillName) }` in Task 7 UI.
- `SkillExtractor(providerOverride:)` — used in Tasks 4 and 5 tests; `SkillExtractor.shared` uses `providerOverride: nil` by default.
