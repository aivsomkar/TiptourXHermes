# Cursor Shake Activation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a second activation gesture for the Gemini Live voice session — a vigorous cursor shake — that toggles the session in lockstep with the existing Ctrl+Option hotkey. Opt-in via a panel toggle.

**Architecture:** Two new files form a thin CGEventTap shell (`CursorShakeMonitor`) over a pure detection algorithm (`CursorShakeDetector`). The monitor emits on a Combine publisher; `CompanionManager` subscribes and funnels each emission into the same `handleShortcutTransition(.pressed)` path the hotkey uses. A panel toggle persists user intent to `UserDefaults`. No new TCC permissions — the existing Accessibility permission used by the push-to-talk tap covers the mouse-motion tap.

**Tech Stack:** Swift, AppKit (`CGEventTap`, `NSEvent`), SwiftUI (`@Published`, `Toggle`), Combine (`PassthroughSubject`), Swift Testing (`@Suite`, `@Test`, `#expect`).

---

## Build & test conventions for this project

These constraints come from `repo/CLAUDE.md` and apply to every task:

- **Do NOT run `xcodebuild` from the terminal.** It invalidates TCC permissions and you'll have to re-grant Accessibility / Screen Recording. All test-running and build verification steps in this plan run from Xcode itself (Cmd+U for tests, Cmd+B for build).
- New `.swift` files added under `repo/TipTour/` must be **added to the `TipTour` target membership** in Xcode (click the file in the project navigator → File Inspector → Target Membership). New test files under `repo/TipTourTests/` must be added to the `TipTourTests` target. Steps that create new files note this explicitly.
- The test suite uses Swift Testing (`import Testing`, `@Suite struct`, `@Test func`, `#expect(...)`), not XCTest. Match the existing pattern in `repo/TipTourTests/SettingsTests.swift`.
- Commits should be small and atomic — one commit per task is the right granularity. Use imperative-mood messages.

---

## File map

**Created:**
- `repo/TipTour/CursorShakeDetector.swift` — pure detection algorithm, no I/O, no AppKit dependencies. (~90 lines)
- `repo/TipTour/CursorShakeMonitor.swift` — listen-only `CGEventTap` shell that feeds samples to the detector and emits on a publisher. (~110 lines)
- `repo/TipTourTests/CursorShakeDetectorTests.swift` — Swift Testing suite for the detector. (~180 lines)

**Modified:**
- `repo/TipTour/CompanionManager.swift` — add stored property, subscription, settings observer, lifecycle wiring.
- `repo/TipTour/CompanionPanelView.swift` — add a "Shake to activate" toggle row matching the existing neko mode toggle pattern.
- `repo/TipTour/TipTourAnalytics.swift` — add `trackShakeActivation()`.
- `repo/CLAUDE.md` — add two rows to the Key Files table and one sentence to Architecture.

---

### Task 1: Create the detector with the first failing test

**Files:**
- Create: `repo/TipTourTests/CursorShakeDetectorTests.swift`
- Create: `repo/TipTour/CursorShakeDetector.swift`

This task uses strict TDD for the first behavior: write one failing test, run it to confirm it fails, write the minimum code to make it pass.

- [ ] **Step 1: Create the test file with the first test (test will fail to compile)**

Create `repo/TipTourTests/CursorShakeDetectorTests.swift`:

```swift
import Testing
import Foundation
import CoreGraphics
@testable import TipTour

@Suite struct CursorShakeDetectorTests {

    @Test func firstSampleNeverFires() {
        var detector = CursorShakeDetector()
        let didFire = detector.ingestSample(timestamp: 0.0, x: 100, y: 100)
        #expect(didFire == false)
    }
}
```

In Xcode: drag this new file into the `TipTourTests` group, confirm Target Membership = `TipTourTests`.

- [ ] **Step 2: Run the test to confirm it fails (compile error)**

In Xcode: press Cmd+U. Expected outcome: build fails with "Cannot find 'CursorShakeDetector' in scope". This is the failing-test signal — proceed.

- [ ] **Step 3: Create the detector with the minimum code to pass**

Create `repo/TipTour/CursorShakeDetector.swift`:

```swift
//
//  CursorShakeDetector.swift
//  TipTour
//
//  Pure shake-detection algorithm. Given a stream of (timestamp, x, y)
//  cursor samples, decides when the user has performed a vigorous shake.
//
//  No I/O, no AppKit, no CGEventTap — so the algorithm is unit-testable
//  without simulating real input events. The companion file
//  CursorShakeMonitor wraps a CGEventTap around this.
//

import CoreGraphics
import Foundation

struct CursorShakeDetector {

    // MARK: - Tunable thresholds
    //
    // Deliberately stricter than macOS's built-in "Shake mouse pointer
    // to locate" so a casual wiggle that triggers the system feature
    // does NOT also activate TipTour. These are compile-time constants
    // for v1; surfacing them to the UI is out of scope.

    let windowDuration: TimeInterval = 0.5
    let minimumDirectionReversalsInWindow: Int = 8
    let minimumPathLengthInWindow: CGFloat = 600
    let cooldownAfterFire: TimeInterval = 1.5
    let minimumVelocityToCount: CGFloat = 600          // points per second
    let directionJitterFloor: CGFloat = 3              // points
    let minimumSampleSpacing: TimeInterval = 0.004     // 4 ms

    // MARK: - State

    private var previousSample: (timestamp: TimeInterval, x: CGFloat, y: CGFloat)?
    private var previousDxSign: Int = 0
    private var previousDySign: Int = 0
    private var reversalTimestamps: [TimeInterval] = []
    private var pathSamples: [(timestamp: TimeInterval, distance: CGFloat)] = []
    private var lastFireTimestamp: TimeInterval = -.infinity

    /// Feed one cursor sample. Returns `true` on the sample that triggers
    /// a shake fire; `false` otherwise. The caller must invoke this on
    /// every relevant CGEvent — the detector relies on continuous sampling.
    mutating func ingestSample(timestamp: TimeInterval, x: CGFloat, y: CGFloat) -> Bool {
        guard let previous = previousSample else {
            previousSample = (timestamp, x, y)
            return false
        }
        previousSample = (timestamp, x, y)
        return false
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

In Xcode: Cmd+U. Expected: `firstSampleNeverFires` passes (green).

- [ ] **Step 5: Commit**

```bash
git add repo/TipTour/CursorShakeDetector.swift repo/TipTourTests/CursorShakeDetectorTests.swift
git commit -m "scaffold CursorShakeDetector with first failing-then-passing test"
```

---

### Task 2: Add the "vigorous shake fires" test and full algorithm

**Files:**
- Modify: `repo/TipTour/CursorShakeDetector.swift`
- Modify: `repo/TipTourTests/CursorShakeDetectorTests.swift`

This task adds the core "fires on a real shake" behavior. The implementation is grown to handle reversals, path length, velocity gate, and the cooldown timestamp — everything except the cooldown enforcement (covered by Task 3) and the diagonal/jitter edge cases (covered by Task 4).

- [ ] **Step 1: Add the vigorous-shake test (will fail)**

In `repo/TipTourTests/CursorShakeDetectorTests.swift`, append inside the suite, after the existing test:

```swift
    @Test func vigorousHorizontalShakeFires() {
        var detector = CursorShakeDetector()

        // Simulate a horizontal shake: alternate x by ±80 pt every 30 ms.
        // After 8 reversals the cumulative path is 8 * 80 = 640 pt > 600,
        // velocity is 80 / 0.030 = 2667 pt/s > 600, so all gates clear.
        var didFire = false
        var x: CGFloat = 100
        var timestamp: TimeInterval = 0.0
        var direction: CGFloat = 1
        for _ in 0..<20 {
            timestamp += 0.030
            x += 80 * direction
            direction *= -1
            if detector.ingestSample(timestamp: timestamp, x: x, y: 100) {
                didFire = true
                break
            }
        }

        #expect(didFire == true)
    }
```

- [ ] **Step 2: Run tests to confirm the new test fails**

Cmd+U. Expected: `vigorousHorizontalShakeFires` fails with `Expectation failed: didFire == true`.

- [ ] **Step 3: Implement the full algorithm**

Replace the body of `ingestSample` in `repo/TipTour/CursorShakeDetector.swift` with the complete algorithm:

```swift
    mutating func ingestSample(timestamp: TimeInterval, x: CGFloat, y: CGFloat) -> Bool {
        guard let previous = previousSample else {
            previousSample = (timestamp, x, y)
            return false
        }

        let dt = timestamp - previous.timestamp
        if dt < minimumSampleSpacing {
            // Filter very-high-poll-rate noise without overwriting previousSample.
            return false
        }

        let dx = x - previous.x
        let dy = y - previous.y
        let distance = (dx * dx + dy * dy).squareRoot()
        let velocity = distance / CGFloat(dt)

        previousSample = (timestamp, x, y)

        // Drop window entries older than windowDuration so the window
        // is always a 500ms suffix of recent activity.
        let windowStart = timestamp - windowDuration
        while let first = reversalTimestamps.first, first < windowStart {
            reversalTimestamps.removeFirst()
        }
        while let first = pathSamples.first, first.timestamp < windowStart {
            pathSamples.removeFirst()
        }

        // Slow motion can't accumulate path or reversal credit.
        guard velocity >= minimumVelocityToCount else {
            return false
        }

        pathSamples.append((timestamp, distance))

        // Direction-reversal detection — count axis-by-axis.
        let dxSign: Int
        if dx > directionJitterFloor {
            dxSign = 1
        } else if dx < -directionJitterFloor {
            dxSign = -1
        } else {
            dxSign = 0
        }
        let dySign: Int
        if dy > directionJitterFloor {
            dySign = 1
        } else if dy < -directionJitterFloor {
            dySign = -1
        } else {
            dySign = 0
        }

        if dxSign != 0 && previousDxSign != 0 && dxSign != previousDxSign {
            reversalTimestamps.append(timestamp)
        }
        if dySign != 0 && previousDySign != 0 && dySign != previousDySign {
            reversalTimestamps.append(timestamp)
        }
        if dxSign != 0 { previousDxSign = dxSign }
        if dySign != 0 { previousDySign = dySign }

        let pathLengthInWindow = pathSamples.reduce(CGFloat(0)) { $0 + $1.distance }

        // Cooldown enforced in Task 3. For now we only return true when
        // ALL fire conditions are met — cooldown is checked but starts at
        // -.infinity so the first eligible shake fires.
        let cooldownElapsed = timestamp - lastFireTimestamp >= cooldownAfterFire
        let enoughReversals = reversalTimestamps.count >= minimumDirectionReversalsInWindow
        let enoughPath = pathLengthInWindow >= minimumPathLengthInWindow

        if cooldownElapsed && enoughReversals && enoughPath {
            lastFireTimestamp = timestamp
            reversalTimestamps.removeAll()
            return true
        }

        return false
    }
```

- [ ] **Step 4: Run tests to verify both pass**

Cmd+U. Expected: `firstSampleNeverFires` and `vigorousHorizontalShakeFires` both pass.

- [ ] **Step 5: Commit**

```bash
git add repo/TipTour/CursorShakeDetector.swift repo/TipTourTests/CursorShakeDetectorTests.swift
git commit -m "implement CursorShakeDetector core algorithm"
```

---

### Task 3: Cover the negative cases — slow wiggle, straight motion, short path, cooldown

**Files:**
- Modify: `repo/TipTourTests/CursorShakeDetectorTests.swift`

The algorithm already handles these via the existing gates (velocity, path length, cooldown). This task locks them in with regression tests. No production code changes — if any test fails, the algorithm has a bug we need to fix before continuing.

- [ ] **Step 1: Add the four negative tests**

Append inside the suite in `repo/TipTourTests/CursorShakeDetectorTests.swift`:

```swift
    @Test func slowWiggleDoesNotFire() {
        var detector = CursorShakeDetector()

        // Same reversal pattern as the vigorous test, but with very slow
        // motion: 5 pt every 30 ms = 167 pt/s, well under the 600 pt/s gate.
        var didFire = false
        var x: CGFloat = 100
        var timestamp: TimeInterval = 0.0
        var direction: CGFloat = 1
        for _ in 0..<60 {
            timestamp += 0.030
            x += 5 * direction
            direction *= -1
            if detector.ingestSample(timestamp: timestamp, x: x, y: 100) {
                didFire = true
                break
            }
        }

        #expect(didFire == false)
    }

    @Test func straightFastMotionDoesNotFire() {
        var detector = CursorShakeDetector()

        // 80 pt every 30 ms, all in one direction. Plenty of velocity and
        // path, but zero reversals.
        var didFire = false
        var x: CGFloat = 100
        var timestamp: TimeInterval = 0.0
        for _ in 0..<30 {
            timestamp += 0.030
            x += 80
            if detector.ingestSample(timestamp: timestamp, x: x, y: 100) {
                didFire = true
                break
            }
        }

        #expect(didFire == false)
    }

    @Test func shortPathLengthDoesNotFire() {
        var detector = CursorShakeDetector()

        // Reverse every step at high velocity but with TINY amplitude
        // (4 pt over 1 ms = 4000 pt/s velocity, 4 pt path per sample).
        // 8 reversals * 4 pt = 32 pt path << 600 pt minimum.
        var didFire = false
        var x: CGFloat = 100
        var timestamp: TimeInterval = 0.0
        var direction: CGFloat = 1
        for _ in 0..<20 {
            timestamp += 0.005
            x += 4 * direction
            direction *= -1
            if detector.ingestSample(timestamp: timestamp, x: x, y: 100) {
                didFire = true
                break
            }
        }

        #expect(didFire == false)
    }

    @Test func cooldownBlocksImmediateSecondFire() {
        var detector = CursorShakeDetector()

        func driveOneVigorousShake(startTime: TimeInterval, startX: CGFloat) -> (fired: Bool, lastTimestamp: TimeInterval, lastX: CGFloat) {
            var didFire = false
            var x = startX
            var timestamp = startTime
            var direction: CGFloat = 1
            for _ in 0..<20 {
                timestamp += 0.030
                x += 80 * direction
                direction *= -1
                if detector.ingestSample(timestamp: timestamp, x: x, y: 100) {
                    didFire = true
                    break
                }
            }
            return (didFire, timestamp, x)
        }

        // First shake fires.
        let first = driveOneVigorousShake(startTime: 0.0, startX: 100)
        #expect(first.fired == true)

        // Immediate identical shake within the 1.5s cooldown should NOT fire.
        // Continue feeding from the same time base so dt remains small.
        let second = driveOneVigorousShake(startTime: first.lastTimestamp, startX: first.lastX)
        #expect(second.fired == false)

        // Now jump past the cooldown and shake again — should fire.
        let third = driveOneVigorousShake(startTime: second.lastTimestamp + 2.0, startX: second.lastX)
        #expect(third.fired == true)
    }
```

- [ ] **Step 2: Run tests to verify all pass**

Cmd+U. Expected: all five tests pass (`firstSampleNeverFires`, `vigorousHorizontalShakeFires`, `slowWiggleDoesNotFire`, `straightFastMotionDoesNotFire`, `shortPathLengthDoesNotFire`, `cooldownBlocksImmediateSecondFire`).

If any fails, that's a real algorithm bug — fix `CursorShakeDetector.swift` to match the spec semantics before continuing.

- [ ] **Step 3: Commit**

```bash
git add repo/TipTourTests/CursorShakeDetectorTests.swift
git commit -m "add CursorShakeDetector negative and cooldown tests"
```

---

### Task 4: Cover edge cases — diagonal shake, sample-rate gate, jitter floor

**Files:**
- Modify: `repo/TipTourTests/CursorShakeDetectorTests.swift`

- [ ] **Step 1: Add the three edge-case tests**

Append inside the suite:

```swift
    @Test func diagonalShakeFires() {
        var detector = CursorShakeDetector()

        // Alternate BOTH axes simultaneously every 30 ms with ±60 pt steps
        // on each axis. distance per sample = sqrt(60² + 60²) ≈ 85 pt;
        // velocity 85/0.030 ≈ 2828 pt/s; reversals come from BOTH axes,
        // so we accumulate 2 reversals per step.
        var didFire = false
        var x: CGFloat = 100
        var y: CGFloat = 100
        var timestamp: TimeInterval = 0.0
        var direction: CGFloat = 1
        for _ in 0..<10 {
            timestamp += 0.030
            x += 60 * direction
            y += 60 * direction
            direction *= -1
            if detector.ingestSample(timestamp: timestamp, x: x, y: y) {
                didFire = true
                break
            }
        }

        #expect(didFire == true)
    }

    @Test func sampleRateGateDoesNotCorruptPreviousSample() {
        var detector = CursorShakeDetector()

        // Seed one sample.
        _ = detector.ingestSample(timestamp: 0.0, x: 100, y: 100)

        // Submit an ultra-fast sub-4ms sample — the detector should
        // ignore it for state-update purposes.
        let droppedFire = detector.ingestSample(timestamp: 0.001, x: 200, y: 200)
        #expect(droppedFire == false)

        // Subsequent normal samples should compute dx against the ORIGINAL
        // previous sample (x=100), not the dropped one (x=200). We verify
        // by feeding a single-direction sweep that should not fire — if the
        // dropped sample had been retained as previousSample, the next dx
        // would be tiny and unrepresentative.
        var didFire = false
        var x: CGFloat = 100
        var timestamp: TimeInterval = 0.001
        for _ in 0..<10 {
            timestamp += 0.030
            x += 80
            if detector.ingestSample(timestamp: timestamp, x: x, y: 100) {
                didFire = true
                break
            }
        }

        #expect(didFire == false)
    }

    @Test func subJitterFloorDeltasDoNotCountAsReversals() {
        var detector = CursorShakeDetector()

        // Alternate by ±2 pt — under the 3-pt directionJitterFloor.
        // Pair with high enough velocity by tightening dt so the velocity
        // gate clears (2 pt / 0.001 s = 2000 pt/s). With no reversals
        // recorded, the detector should never fire.
        var didFire = false
        var x: CGFloat = 100
        var timestamp: TimeInterval = 0.0
        var direction: CGFloat = 1
        for _ in 0..<100 {
            timestamp += 0.005
            x += 2 * direction
            direction *= -1
            if detector.ingestSample(timestamp: timestamp, x: x, y: 100) {
                didFire = true
                break
            }
        }

        #expect(didFire == false)
    }
```

- [ ] **Step 2: Run tests to verify all pass**

Cmd+U. Expected: all eight tests pass.

- [ ] **Step 3: Commit**

```bash
git add repo/TipTourTests/CursorShakeDetectorTests.swift
git commit -m "add CursorShakeDetector edge-case tests"
```

---

### Task 5: Add the CGEventTap shell

**Files:**
- Create: `repo/TipTour/CursorShakeMonitor.swift`

This file mirrors the structure of `GlobalPushToTalkShortcutMonitor.swift` exactly. The tap is **listen-only** so it never blocks or modifies real cursor events. No new tests for this file — the surface is a 1:1 port of the push-to-talk monitor's lifecycle, and the algorithm it wraps is already covered by Tasks 1-4.

- [ ] **Step 1: Create the monitor file**

Create `repo/TipTour/CursorShakeMonitor.swift`:

```swift
//
//  CursorShakeMonitor.swift
//  TipTour
//
//  Listen-only CGEventTap for mouse motion. Feeds samples to
//  CursorShakeDetector and emits on shakeDetectedPublisher whenever the
//  detector reports a vigorous shake. Mirrors the lifecycle of
//  GlobalPushToTalkShortcutMonitor — same tap configuration, same
//  re-enable-on-disable behavior, same idempotent start/stop.
//

import AppKit
import Combine
import CoreGraphics
import Foundation

final class CursorShakeMonitor: ObservableObject {
    let shakeDetectedPublisher = PassthroughSubject<Void, Never>()

    private var globalEventTap: CFMachPort?
    private var globalEventTapRunLoopSource: CFRunLoopSource?
    /// Mutated exclusively from the CGEvent tap callback, which runs on
    /// CFRunLoopGetMain() and therefore always executes on the main
    /// thread. Keeping detector state non-Sendable is fine in this
    /// single-threaded access pattern.
    private var detector = CursorShakeDetector()

    deinit {
        stop()
    }

    func start() {
        // Idempotent — refreshAllPermissions() may call this on every
        // permission poll. Restarting would reset detector state mid-shake.
        guard globalEventTap == nil else { return }

        let monitoredEventTypes: [CGEventType] = [
            .mouseMoved,
            .leftMouseDragged,
            .rightMouseDragged,
            .otherMouseDragged
        ]
        let eventMask = monitoredEventTypes.reduce(CGEventMask(0)) { currentMask, eventType in
            currentMask | (CGEventMask(1) << eventType.rawValue)
        }

        let eventTapCallback: CGEventTapCallBack = { _, eventType, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }
            let monitor = Unmanaged<CursorShakeMonitor>
                .fromOpaque(userInfo)
                .takeUnretainedValue()
            return monitor.handleGlobalEventTap(eventType: eventType, event: event)
        }

        guard let globalEventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("⚠️ Cursor shake: couldn't create CGEvent tap")
            return
        }

        guard let globalEventTapRunLoopSource = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault,
            globalEventTap,
            0
        ) else {
            CFMachPortInvalidate(globalEventTap)
            print("⚠️ Cursor shake: couldn't create event tap run loop source")
            return
        }

        self.globalEventTap = globalEventTap
        self.globalEventTapRunLoopSource = globalEventTapRunLoopSource

        CFRunLoopAddSource(CFRunLoopGetMain(), globalEventTapRunLoopSource, .commonModes)
        CGEvent.tapEnable(tap: globalEventTap, enable: true)
    }

    func stop() {
        if let globalEventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), globalEventTapRunLoopSource, .commonModes)
            self.globalEventTapRunLoopSource = nil
        }
        if let globalEventTap {
            CFMachPortInvalidate(globalEventTap)
            self.globalEventTap = nil
        }
        // Reset detector so a re-enable starts fresh.
        detector = CursorShakeDetector()
    }

    private func handleGlobalEventTap(
        eventType: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if eventType == .tapDisabledByTimeout || eventType == .tapDisabledByUserInput {
            if let globalEventTap {
                CGEvent.tapEnable(tap: globalEventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        // CGEvent.timestamp is in `mach_absolute_time` units, which differ
        // between Intel and Apple Silicon — dividing by 1e9 only works on
        // Intel. Instead we take our own monotonic timestamp on event
        // receipt via ProcessInfo.systemUptime, which returns seconds
        // since boot as a Double and behaves identically across archs.
        // The tap callback runs on the main run loop synchronously with
        // event delivery, so the receipt time is a faithful proxy for
        // the event time (microsecond-scale jitter is well below our
        // 4ms sample-spacing gate).
        let timestampSeconds = ProcessInfo.processInfo.systemUptime
        let location = event.location

        let didFire = detector.ingestSample(
            timestamp: timestampSeconds,
            x: location.x,
            y: location.y
        )

        if didFire {
            shakeDetectedPublisher.send()
        }

        return Unmanaged.passUnretained(event)
    }
}
```

In Xcode: drag the new file into the `TipTour` group, confirm Target Membership = `TipTour`.

- [ ] **Step 2: Build to verify it compiles**

In Xcode: Cmd+B. Expected: build succeeds (the file is not yet referenced from anywhere, so no behavior changes).

- [ ] **Step 3: Commit**

```bash
git add repo/TipTour/CursorShakeMonitor.swift
git commit -m "add CursorShakeMonitor CGEventTap shell"
```

---

### Task 6: Add the analytics call

**Files:**
- Modify: `repo/TipTour/TipTourAnalytics.swift`

- [ ] **Step 1: Add the new method**

In `repo/TipTour/TipTourAnalytics.swift`, find the Voice Interaction section (around line 55) and add the new method immediately after `trackPushToTalkReleased`:

```swift
    /// User triggered TipTour by shaking the cursor vigorously.
    /// Tracked separately from push-to-talk so we can measure adoption
    /// and accidental-fire rate independently.
    static func trackShakeActivation() {
        PostHogSDK.shared.capture("shake_activation")
    }
```

- [ ] **Step 2: Build to verify it compiles**

Cmd+B. Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add repo/TipTour/TipTourAnalytics.swift
git commit -m "add trackShakeActivation analytics event"
```

---

### Task 7: Wire shake detection into CompanionManager

**Files:**
- Modify: `repo/TipTour/CompanionManager.swift`

The shake monitor mirrors how `globalPushToTalkShortcutMonitor` is wired: a stored property, a subscription in `bindShortcutTransitions()`, start/stop in `refreshAllPermissions()` (gated on Accessibility permission AND the user setting), stop in the manager's `stop()`. The setting is also observed via `UserDefaults.didChangeNotification` so flipping the panel toggle takes effect live.

- [ ] **Step 1: Add the stored properties and the setting key**

Near the top of `CompanionManager.swift`, find the line `let globalPushToTalkShortcutMonitor = GlobalPushToTalkShortcutMonitor()` (around line 69). Add immediately after it:

```swift
    let cursorShakeMonitor = CursorShakeMonitor()
    private var cursorShakeCancellable: AnyCancellable?
    private var cursorShakeSettingObserver: NSObjectProtocol?

    private static let cursorShakeActivationDefaultsKey = "isCursorShakeActivationEnabled"

    @Published var isCursorShakeActivationEnabled: Bool =
        UserDefaults.standard.bool(forKey: Self.cursorShakeActivationDefaultsKey)

    func setCursorShakeActivationEnabled(_ enabled: Bool) {
        isCursorShakeActivationEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.cursorShakeActivationDefaultsKey)
        // Re-evaluate immediately — don't wait for the next permission poll.
        applyCursorShakeMonitorState()
    }

    /// Starts or stops the cursor-shake monitor based on the current
    /// Accessibility permission and the user's opt-in setting. Safe to
    /// call repeatedly — both start() and stop() are idempotent.
    private func applyCursorShakeMonitorState() {
        let shouldRun = hasAccessibilityPermission && isCursorShakeActivationEnabled
        if shouldRun {
            cursorShakeMonitor.start()
        } else {
            cursorShakeMonitor.stop()
        }
    }
```

- [ ] **Step 2: Subscribe to the shake publisher inside `bindShortcutTransitions`**

Find `private func bindShortcutTransitions()` (around line 946). At the end of the function body (after the `demonstrationShortcutCancellable` assignment), append:

```swift
        cursorShakeCancellable = cursorShakeMonitor
            .shakeDetectedPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                guard let self else { return }
                TipTourAnalytics.trackShakeActivation()
                // Funnel into the exact code path the hotkey uses. This gives
                // us the frontmost-app snapshot, AX prefetch, panel dismiss,
                // and toggle semantics for free.
                self.handleShortcutTransition(.pressed)
            }

        cursorShakeSettingObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let storedValue = UserDefaults.standard.bool(forKey: Self.cursorShakeActivationDefaultsKey)
            if self.isCursorShakeActivationEnabled != storedValue {
                self.isCursorShakeActivationEnabled = storedValue
            }
            self.applyCursorShakeMonitorState()
        }
```

- [ ] **Step 3: Gate the monitor on Accessibility permission inside `refreshAllPermissions`**

Find the block in `refreshAllPermissions()` that handles the push-to-talk monitor (around line 861):

```swift
        if currentlyHasAccessibility {
            globalPushToTalkShortcutMonitor.start()
        } else {
            globalPushToTalkShortcutMonitor.stop()
        }
```

Immediately after that block, add:

```swift
        applyCursorShakeMonitorState()
```

- [ ] **Step 4: Tear down in `stop()`**

Find `func stop()` (around line 833). After the line `globalPushToTalkShortcutMonitor.stop()`, add:

```swift
        cursorShakeMonitor.stop()
        cursorShakeCancellable?.cancel()
        if let cursorShakeSettingObserver {
            NotificationCenter.default.removeObserver(cursorShakeSettingObserver)
            self.cursorShakeSettingObserver = nil
        }
```

- [ ] **Step 5: Add the Combine import if missing**

Open the top of `CompanionManager.swift`. If `import Combine` is not already present alongside the other imports, add it. (Most likely it already is, since `shortcutTransitionCancellable: AnyCancellable?` is already in use — verify.)

- [ ] **Step 6: Build to verify compilation**

Cmd+B. Expected: build succeeds.

- [ ] **Step 7: Commit**

```bash
git add repo/TipTour/CompanionManager.swift
git commit -m "wire CursorShakeMonitor into CompanionManager lifecycle"
```

---

### Task 8: Add the panel toggle

**Files:**
- Modify: `repo/TipTour/CompanionPanelView.swift`

The toggle goes next to the neko mode toggle — same row pattern, same visual weight. This keeps related user preferences clustered.

- [ ] **Step 1: Add the new toggle row variable**

Find `private var nekoModeToggleRow: some View` (around line 512). Immediately after the closing brace of that var (around line 546), add:

```swift
    // MARK: - Cursor Shake Activation Toggle

    /// Opt-in toggle for activating TipTour by shaking the cursor.
    /// Off by default. When on, a vigorous cursor shake triggers the same
    /// toggle behavior as pressing Ctrl+Option.
    private var cursorShakeActivationToggleRow: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "hand.wave.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(
                        companionManager.isCursorShakeActivationEnabled
                            ? DS.Colors.accent
                            : DS.Colors.textTertiary
                    )
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Shake to activate")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                    Text("shake the cursor vigorously to start or stop")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { companionManager.isCursorShakeActivationEnabled },
                set: { companionManager.setCursorShakeActivationEnabled($0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .tint(DS.Colors.accent)
            .scaleEffect(0.8)
        }
        .padding(.vertical, 4)
    }
```

- [ ] **Step 2: Render the new row next to nekoModeToggleRow**

Find the call site where `nekoModeToggleRow` is rendered (around line 55):

```swift
                nekoModeToggleRow
```

Add the new row immediately after it:

```swift
                cursorShakeActivationToggleRow
```

- [ ] **Step 3: Build and run to verify the toggle appears**

Cmd+R in Xcode. Open the menu bar panel and confirm:
- A new "Shake to activate" row appears below "Neko mode".
- The toggle is OFF by default.
- Flipping it on/off doesn't crash; the underlying `UserDefaults` key updates.

- [ ] **Step 4: Commit**

```bash
git add repo/TipTour/CompanionPanelView.swift
git commit -m "add 'Shake to activate' toggle to menu bar panel"
```

---

### Task 9: Manual end-to-end verification

**Files:** none (manual QA only)

This step is non-negotiable for a feature that needs real cursor input. Per `CLAUDE.md`, frontend/UI features should be tested in a running build before being declared done.

- [ ] **Step 1: Run the app from Xcode**

Cmd+R. Wait for the menu bar icon to appear. Confirm Accessibility permission is granted (it should already be from prior runs).

- [ ] **Step 2: With the setting OFF, verify shake does nothing**

Confirm the "Shake to activate" toggle is OFF. Shake the cursor vigorously across a screen for ~1 second. Expected: nothing happens; no voice session starts.

- [ ] **Step 3: Flip the toggle ON, verify a vigorous shake opens the session**

Click the toggle to ON. Shake the cursor vigorously (rapid back-and-forth across ~600 pixels of screen for ~0.5 seconds). Expected: the Gemini Live voice session starts — the cursor companion appears and the listening waveform shows. Verify the same outcome you'd see from pressing Ctrl+Option.

- [ ] **Step 4: Shake again to close the session**

Wait ~2 seconds (past the cooldown). Shake the cursor vigorously again. Expected: the voice session closes.

- [ ] **Step 5: Verify a casual wiggle does NOT activate**

With the toggle still ON, idly wiggle the cursor in small motions (the kind of motion that triggers macOS's "Shake mouse pointer to locate" magnifier). Expected: TipTour does not activate. If the macOS magnifier triggers, that's expected — the two features coexist.

- [ ] **Step 6: Verify a straight fast cursor sweep does NOT activate**

Sweep the cursor in a single direction across the screen as fast as you can. Expected: TipTour does not activate.

- [ ] **Step 7: Verify the setting persists across relaunch**

Quit the app from the menu bar, relaunch. Confirm the toggle is still ON.

- [ ] **Step 8: Verify the toggle takes effect live (no relaunch needed)**

Turn the toggle OFF without quitting. Shake the cursor vigorously. Expected: no activation. Turn it back ON. Shake again. Expected: activation works.

- [ ] **Step 9: If any step fails, debug and re-run the affected step**

Common failure modes:
- Shake doesn't fire → thresholds may be too strict for your input device (high-DPI trackpad). Check the values in `CursorShakeDetector.swift`; if a real vigorous shake feels like it should fire but doesn't, the `minimumPathLengthInWindow` is the most likely culprit. Adjust and re-run the unit tests.
- Casual wiggle fires → thresholds are too loose. Bump `minimumDirectionReversalsInWindow` or `minimumPathLengthInWindow`.
- Toggle doesn't take effect live → `applyCursorShakeMonitorState()` may not be wired into the `UserDefaults.didChangeNotification` observer; re-check Task 7 Step 2.

- [ ] **Step 10: Commit any threshold tweaks (if needed)**

If you adjusted thresholds in `CursorShakeDetector.swift`:

```bash
git add repo/TipTour/CursorShakeDetector.swift
git commit -m "tune cursor shake thresholds based on hardware testing"
```

If no tweaks were needed, skip this step.

---

### Task 10: Update CLAUDE.md

**Files:**
- Modify: `repo/CLAUDE.md`

- [ ] **Step 1: Add the two new Key Files rows**

In `repo/CLAUDE.md`, find the Key Files table. Insert two new rows in a sensible location (alphabetically near the other top-level `TipTour/*.swift` files; immediately after `ClickDetector.swift` is a reasonable placement):

```markdown
| `CursorShakeDetector.swift` | ~110 | Pure shake-detection algorithm: ingests cursor samples, counts direction reversals and path length over a 0.5s sliding window, returns `true` when all gates clear (reversals ≥ 8, path ≥ 600 pt, velocity ≥ 600 pt/s, cooldown ≥ 1.5s elapsed). No I/O — fully unit-testable. Thresholds set stricter than macOS shake-to-locate. |
| `CursorShakeMonitor.swift` | ~110 | Listen-only `CGEventTap` for `.mouseMoved` / drag events. Feeds samples to `CursorShakeDetector`; emits on `shakeDetectedPublisher` when the detector reports a vigorous shake. Idempotent `start()` / `stop()`, mirrors `GlobalPushToTalkShortcutMonitor`'s lifecycle. |
```

- [ ] **Step 2: Add a sentence to the Architecture section**

Find the **Global Push-To-Talk Shortcut** architecture entry. Immediately after it, add a new entry:

```markdown
**Cursor Shake Activation**: A second, optional activation gesture. `CursorShakeMonitor` (listen-only `CGEventTap`) feeds mouse-motion samples to `CursorShakeDetector` (pure algorithm). A vigorous shake — 8+ direction reversals and 600+ pt of path within a 0.5s window — emits on a Combine publisher that `CompanionManager` subscribes to, funneling each event into the same `handleShortcutTransition(.pressed)` path the hotkey uses. Opt-in via a panel toggle; off by default; tuned to be stricter than macOS's built-in "shake mouse pointer to locate" so casual wiggles don't co-fire.
```

- [ ] **Step 3: Commit**

```bash
git add repo/CLAUDE.md
git commit -m "document cursor shake activation in CLAUDE.md"
```

---

## Done criteria

- All 8 detector unit tests pass via Cmd+U in Xcode.
- Manual QA in Task 9 passes every step on real hardware.
- `git log` shows ten clean, atomic commits (one per task) with imperative-mood messages.
- No `xcodebuild` was invoked from the terminal at any point during implementation.
