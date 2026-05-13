# Cursor Shake Activation — Design

**Date**: 2026-05-13
**Status**: Approved for implementation planning

## Summary

Add a second activation trigger to TipTour: shaking the cursor vigorously toggles the Gemini Live voice session on and off, identical in behavior to the existing Ctrl+Option hotkey. Opt-in; off by default; tuned to be stricter than macOS's built-in "shake mouse pointer to locate" so it does not co-fire on casual wiggles.

## Goals

- Provide a hands-on-mouse activation gesture so users do not have to reach for the keyboard.
- Keep the existing hotkey path untouched and authoritative — shake is an additive trigger that funnels into the same code.
- Be deliberately deaf to incidental cursor motion so the gesture stays a real "I meant to do that" signal.

## Non-goals

- Replacing the hotkey. Hotkey continues to work and remains the primary trigger.
- Customizing shake sensitivity from the UI. Thresholds are constants in the source for v1.
- Cross-process input synthesis or any tap that modifies events — this is listen-only.
- New TCC permissions. The existing Accessibility permission used by `GlobalPushToTalkShortcutMonitor` covers the new mouse-motion event tap.

## User-visible behavior

- A new toggle row appears in `SettingsView`: **"Activate by shaking cursor"**, with subtitle *"Open or close the voice session by shaking the cursor vigorously. Disabled by default."*
- Default state: **OFF**. The user must enable it once for shake detection to run.
- When enabled, shaking the cursor vigorously is functionally identical to pressing Ctrl+Option once:
  - If the voice session is idle → it opens.
  - If the voice session is active → it closes.
- After any shake trigger, a 1.5-second cooldown blocks re-triggers from the same gesture's residual motion.
- The system feature *"Shake mouse pointer to locate"* (macOS Accessibility) is left untouched. TipTour's threshold is stricter so a shake intense enough to trigger TipTour will usually also trigger the macOS cursor magnifier; a shake casual enough to trigger only the magnifier will not trigger TipTour.

## Architecture

The feature is two new files plus small additions to existing files. It mirrors the pattern established by `GlobalPushToTalkShortcutMonitor`.

### New file: `repo/TipTour/CursorShakeDetector.swift`

Pure algorithm. No AppKit, no CGEventTap, no I/O — just sample ingestion and a boolean return. This isolation makes the detection logic unit-testable without simulating real input events.

```swift
struct CursorShakeDetector {
    // Tunable thresholds, deliberately stricter than macOS shake-to-locate.
    let windowDuration: TimeInterval = 0.5
    let minimumDirectionReversalsInWindow = 8
    let minimumPathLengthInWindow: CGFloat = 600
    let cooldownAfterFire: TimeInterval = 1.5
    let minimumVelocityToCount: CGFloat = 600          // points per second
    let directionJitterFloor: CGFloat = 3              // points
    let minimumSampleSpacing: TimeInterval = 0.004     // 4 ms

    // Mutating state.
    private var previousSample: (timestamp: TimeInterval, x: CGFloat, y: CGFloat)?
    private var previousDxSign: Int = 0
    private var previousDySign: Int = 0
    private var reversalTimestamps: [TimeInterval] = []
    private var pathSamples: [(timestamp: TimeInterval, distance: CGFloat)] = []
    private var lastFireTimestamp: TimeInterval = -.infinity

    /// Returns true on the sample that triggers a fire.
    mutating func ingestSample(timestamp: TimeInterval, x: CGFloat, y: CGFloat) -> Bool
}
```

`ingestSample` per-call work:

1. If `previousSample == nil`, store and return `false`.
2. Compute `dt = timestamp - previousSample.timestamp`. If `dt < minimumSampleSpacing`, return `false` without updating state (filters high-poll-rate noise without dropping the previous reference).
3. Compute `dx`, `dy`, `distance = hypot(dx, dy)`, `velocity = distance / dt`.
4. If `velocity < minimumVelocityToCount`, update `previousSample` only — no reversal counting. Slow drift cannot accumulate.
5. **Reversal detection**: compute `dxSign = sign(dx)` (only if `|dx| > directionJitterFloor`, else 0). If `dxSign != 0 && previousDxSign != 0 && dxSign != previousDxSign`, append `timestamp` to `reversalTimestamps`. Same for the Y axis. (Counting both axes independently captures diagonal shakes.)
6. Append `(timestamp, distance)` to `pathSamples`. Drop entries with `timestamp - entry.timestamp > windowDuration` from the front of `pathSamples` and `reversalTimestamps`.
7. Compute `pathLengthInWindow = pathSamples.reduce(0) { $0 + $1.distance }`.
8. **Fire check**:
   - `timestamp - lastFireTimestamp >= cooldownAfterFire`
   - `reversalTimestamps.count >= minimumDirectionReversalsInWindow`
   - `pathLengthInWindow >= minimumPathLengthInWindow`
   - If all hold: set `lastFireTimestamp = timestamp`, clear `reversalTimestamps`, return `true`.
9. Update `previousSample`, `previousDxSign`, `previousDySign`. Return `false`.

### New file: `repo/TipTour/CursorShakeMonitor.swift`

Thin shell around `CursorShakeDetector`. Owns a listen-only `CGEventTap` and a `PassthroughSubject<Void, Never>`.

- Tap configuration:
  - `tap: .cgSessionEventTap`
  - `place: .headInsertEventTap`
  - `options: .listenOnly`
  - `eventsOfInterest`: `.mouseMoved`, `.leftMouseDragged`, `.rightMouseDragged`, `.otherMouseDragged`
- Callback: read `CGEvent.location`, convert `event.timestamp` (Mach absolute time) to seconds, feed to `detector.ingestSample`. On `true`, hop to main and `shakeDetectedPublisher.send()`.
- `start()` / `stop()` mirror `GlobalPushToTalkShortcutMonitor` exactly: idempotent (re-entry checks `globalEventTap == nil`), tears down run-loop source and invalidates the mach port on stop, re-enables the tap on `tapDisabledByTimeout`/`tapDisabledByUserInput`.
- Lives on `CFRunLoopGetMain()` like the push-to-talk tap. Per-event work is O(1) amortized with bounded buffers, so it is safe at 1000 Hz mouse polling.

### Modified file: `repo/TipTour/CompanionManager.swift`

Three additions, all small:

1. **Stored property** near the existing `globalPushToTalkShortcutMonitor`:
   ```swift
   let cursorShakeMonitor = CursorShakeMonitor()
   private var cursorShakeCancellable: AnyCancellable?
   private var cursorShakeSettingObserver: NSObjectProtocol?
   ```

2. **Subscription** added inside `bindShortcutTransitions()`:
   ```swift
   cursorShakeCancellable = cursorShakeMonitor
       .shakeDetectedPublisher
       .receive(on: DispatchQueue.main)
       .sink { [weak self] in self?.handleShortcutTransition(.pressed) }
   ```
   This intentionally funnels shake into the existing hotkey path. Reusing `handleShortcutTransition(.pressed)` gives us — for free — the frontmost-app snapshot, the AX tree prefetch, the panel dismissal, the analytics ping, and the toggle semantics. Shake emits `.pressed` only; the existing `.released` no-op stays compatible.

3. **Setting observer**: a method `configureCursorShakeMonitorFromSettings()` reads `UserDefaults.standard.bool(forKey: "isCursorShakeActivationEnabled")`, then calls either `cursorShakeMonitor.start()` or `cursorShakeMonitor.stop()`. Called once at init (after Accessibility permission is granted, in the same gate already used for `globalPushToTalkShortcutMonitor.start()`) and again whenever a `UserDefaults.didChangeNotification` for this key arrives. The observer is stored in `cursorShakeSettingObserver`.

### Modified file: `repo/TipTour/Agents/UI/SettingsView.swift`

Add a new "Activation" section (or a single row in the most logically-adjacent existing section — to be decided at implementation time by reading the current file structure). The row uses `@AppStorage("isCursorShakeActivationEnabled")` bound to a `Toggle`. Title: "Activate by shaking cursor". Subtitle: "Open or close the voice session by shaking the cursor vigorously. Disabled by default."

`@AppStorage` writes route through `UserDefaults.standard`, which posts `didChangeNotification` — that is what `CompanionManager`'s observer listens for, so flipping the toggle starts/stops the monitor live without an app relaunch.

### Modified file: `repo/CLAUDE.md`

Add two rows to the "Key Files" table:

- `CursorShakeMonitor.swift` (~100 lines): listen-only CGEventTap for mouse motion; feeds samples to `CursorShakeDetector`; emits on `shakeDetectedPublisher` when a vigorous shake is detected.
- `CursorShakeDetector.swift` (~80 lines): pure shake-detection algorithm. Counts direction reversals and total path length in a 0.5s sliding window. Tunable constants set stricter than macOS shake-to-locate.

Also add one sentence to the Architecture section noting that shake activation funnels into the same `.pressed` transition the hotkey uses, and that it is opt-in via a Settings toggle.

## Data flow

```
mouse motion CGEvent
    → CursorShakeMonitor tap callback (main run loop)
    → CursorShakeDetector.ingestSample(timestamp, x, y)
    → (on fire) shakeDetectedPublisher.send()
    → CompanionManager subscription
    → handleShortcutTransition(.pressed)
    → existing toggle logic (start or stop voice session)
```

## Threshold rationale

macOS's "shake mouse pointer to locate" fires on roughly 4–6 direction reversals within ~500 ms at moderate velocity. Setting our thresholds higher across three independent dimensions (reversals, path length, velocity floor) makes co-fires require deliberate gestures only:

| Threshold                       | Value  | Rationale                                                  |
| ------------------------------- | ------ | ---------------------------------------------------------- |
| `windowDuration`                | 0.5 s  | Long enough to catch a real shake, short enough to forget noise. |
| `minimumDirectionReversalsInWindow` | 8 | Roughly 2× macOS's threshold.                              |
| `minimumPathLengthInWindow`     | 600 pt | A casual wiggle covers ~200 pt; a real shake covers >800.  |
| `cooldownAfterFire`             | 1.5 s  | Long enough that post-activation cursor motion can't re-fire; short enough that intentional toggle-off feels responsive. |
| `minimumVelocityToCount`        | 600 pt/s | Filters slow drag-selects from registering as shake samples. |
| `directionJitterFloor`          | 3 pt   | Filters mouse-sensor jitter from registering as direction flips. |

These are constants at the top of `CursorShakeDetector` and can be re-tuned by editing source. Out of scope for v1: surfacing them to the UI.

## Failure modes and edge cases

- **No Accessibility permission**: the `CGEventTap` returns `nil`. `start()` logs and bails, identical to `GlobalPushToTalkShortcutMonitor`. The toggle in Settings still reflects user intent; the tap will start the next time `configureCursorShakeMonitorFromSettings` runs and permission is in place.
- **Tap disabled by timeout / user input**: callback re-enables it, identical to the push-to-talk monitor.
- **High-DPI / Retina coordinates**: `CGEvent.location` is already in points. The thresholds are points; nothing per-display to handle.
- **Multi-display**: cursor motion across display boundaries is just continued motion — no boundary handling needed.
- **Fast scroll wheel / drag-select that *looks* like shake**: filtered by combination of velocity floor and reversal count. A drag-select moves in one direction with few reversals; a scroll wheel does not emit `.mouseMoved` events.
- **Shake while voice session is starting up**: cooldown prevents this. If the user shakes again before the 1.5s cooldown expires, nothing happens — the in-flight startup is not cancelled.
- **Permission revoked at runtime**: the tap stops delivering events. No crash; feature silently no-ops until permission returns and `start()` is called again.

## Testing

Unit tests in a new `repo/TipTourTests/CursorShakeDetectorTests.swift`:

- **fires on synthetic vigorous shake**: Feed a sequence of samples that alternate sign on X with 600 pt/s velocity for 500 ms — should return `true` on or near the 8th reversal.
- **does not fire on slow wiggle**: Same alternation, but velocity below `minimumVelocityToCount`. Never fires.
- **does not fire on straight fast motion**: Single-direction sweep with high velocity. Zero reversals.
- **does not fire when path length below minimum**: High reversal count but tiny amplitude (jitter-floor-borderline samples). No fire.
- **cooldown blocks second fire**: After a fire, identical shake input within 1.5s does not re-fire; same input after 1.5s does.
- **diagonal shake fires**: Alternation on both axes simultaneously counts reversals from each axis.
- **sample-rate gate**: Samples spaced < 4 ms apart do not corrupt previous-sample state.

The `CursorShakeMonitor` itself (the tap shell) is not unit-tested in v1 — its surface is small and mirrors a code path already battle-tested by `GlobalPushToTalkShortcutMonitor`. Manual QA on the actual hardware covers it.

Manual QA checklist:

- Toggle on in Settings → vigorous shake opens voice session.
- Shake again during active session → session closes.
- Casual cursor wiggle does not activate.
- Fast straight cursor sweep does not activate.
- macOS "Shake mouse pointer to locate" enabled simultaneously: confirm a casual wiggle that triggers the macOS magnifier does not trigger TipTour.
- Toggle off in Settings → shake no longer activates, without relaunching the app.
- Quit and relaunch → setting state persists.

## Analytics

Add `TipTourAnalytics.trackShakeActivation()` (parallel to `trackPushToTalkStarted`). Fire it inside the shake subscription **before** delegating to `handleShortcutTransition(.pressed)`, so we can measure adoption and accidental-fire rate separately from keyboard usage.

## Out of scope (explicit YAGNI)

- Configurable thresholds in the UI.
- Per-session "first time you shook, here's what happened" onboarding tip.
- Adapting thresholds based on input device type (mouse vs trackpad). Trackpad shakes naturally produce different velocity profiles, but v1 uses one set of thresholds; we'll re-tune if real-world reports show trackpad users can't easily fire or fire too often.
- Disabling macOS's shake-to-locate setting on TipTour's behalf.
- A visible "shake to activate" hint in the panel.
