# DemonstrationRecorder & SkillExtractor Design

## Goal

Let users teach TipTour new skills by demonstrating them. The user activates recording, performs a task on their Mac, stops recording, names the skill, and TipTour uses Claude to synthesize the observation into a reusable skill stored in the existing `SkillLibraryStore`.

## Scope

This spec covers Phase 4C only: `DemonstrationRecorder`, `SkillExtractor`, the confirmation UI, and `CompanionManager` wiring. `EfficiencyMonitor` (Phase 4D) is a separate spec.

---

## Data Model

**File:** `TipTour/Agents/Skills/DemonstrationTypes.swift`

### `ObservedActionType`

```swift
enum ObservedActionType: String, Codable {
    case click
    case type
    case keyPress
    case appSwitch
    case scroll
}
```

### `ObservedAction`

One recorded user action.

```swift
struct ObservedAction: Codable, Sendable {
    let timestamp: Date
    let type: ObservedActionType
    let appName: String           // frontmost app at action time
    let point: CGPoint?           // click and scroll location (global AppKit coords)
    let text: String?             // accumulated typed text (for .type actions)
    let keyDescription: String?   // human-readable key + modifiers (e.g. "Cmd+S")
    let scrollDelta: CGFloat?     // vertical scroll amount
    let screenshotJPEG: Data?     // JPEG screenshot, captured on .click actions only
}
```

**Typing accumulation:** Consecutive printable keystrokes into the same app are accumulated in a buffer and flushed as a single `.type` action on app switch or non-printable key. This keeps the trajectory compact and the LLM prompt readable.

**Screenshot policy:** Screenshots are captured only on `.click` actions (JPEG at 0.5 quality via `CompanionScreenCaptureUtility`). This limits memory usage while preserving context for the most meaningful interaction points.

### `ActionTrajectory`

The full recording session.

```swift
struct ActionTrajectory: Sendable {
    let startedAt: Date
    let endedAt: Date
    let actions: [ObservedAction]
}
```

---

## `DemonstrationRecorder`

**File:** `TipTour/Agents/Skills/DemonstrationRecorder.swift`

A `final class` with `@unchecked Sendable` and `NSLock`-guarded state — same pattern as `ToolCallHistoryBuffer`. Not an actor because CGEventTap callbacks are synchronous C callbacks that cannot cross an actor boundary.

```swift
final class DemonstrationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _actions: [ObservedAction] = []
    private var _startedAt: Date = .now
    private var eventTap: CFMachPort?
    private var typingBuffer: String = ""
    private var typingAppName: String = ""
}
```

### `start()`

- Records `_startedAt = Date.now`
- Clears `_actions`, `typingBuffer`, `typingAppName`
- Activates a `CGEventTap` at `.cgSessionEventTap` listening for `leftMouseDown`, `keyDown`, `scrollWheel`
- Registers for `NSWorkspace.didActivateApplicationNotification`

### `stop() -> ActionTrajectory`

- Flushes any pending `typingBuffer` as a `.type` action
- Deactivates and releases the `CGEventTap`
- Removes the `NSWorkspace` notification observer
- Returns `ActionTrajectory(startedAt: _startedAt, endedAt: Date.now, actions: _actions)`

### Event handling

**`leftMouseDown`**
1. Appends pending `typingBuffer` as `.type` if non-empty
2. Captures a screenshot via `CompanionScreenCaptureUtility.captureMainDisplay()`, encodes as JPEG (quality 0.5)
3. Appends `.click` action with AppKit global point and screenshot data

**`keyDown`**
- If printable character and same app as `typingAppName`: append to `typingBuffer`
- If printable character and different app: flush buffer as `.type`, start new buffer
- If non-printable (Cmd+S, Escape, Return, Tab, etc.): flush buffer, append `.keyPress` with human-readable `keyDescription`

**`scrollWheel`**
- Debounced: one `.scroll` entry per app per 0.5 seconds
- Appends `ObservedAction` with vertical `scrollDelta`

**App switch** (`NSWorkspace.didActivateApplicationNotification`)
- Flushes `typingBuffer` as `.type` for the previous app
- Appends `.appSwitch` action with new `appName`
- Resets `typingAppName`

### Trajectory text formatting

`DemonstrationRecorder` also provides a static helper:

```swift
static func formatForLLM(_ trajectory: ActionTrajectory) -> (text: String, images: [Data])
```

Returns a compact text summary (one line per action, ISO timestamp) and an ordered list of screenshot JPEG `Data` values to attach as vision content blocks:

```
[10:42:01] click at (540, 320) in Xcode [screenshot]
[10:42:03] type "pnpm install" in Terminal
[10:42:05] keyPress Cmd+Return in Terminal
[10:42:08] appSwitch → Finder
[10:42:10] scroll ↓ 340pt in Finder
```

---

## `SkillExtractor`

**File:** `TipTour/Agents/Skills/SkillExtractor.swift`

A Swift `actor` singleton.

```swift
actor SkillExtractor {
    static let shared = SkillExtractor()
    private let provider: AnthropicProvider
    
    init(provider: AnthropicProvider = AnthropicProvider(model: "claude-sonnet-4-6"))
}
```

### `extract(trajectory:name:) async throws -> String`

1. Calls `DemonstrationRecorder.formatForLLM(trajectory)` to get the text summary and screenshot images
2. Constructs an `[LLMMessage]`:
   - System message: instructs the model to write a reusable skill procedure in the established `.md` body format (Steps with human-readable action descriptions + Result section), written for future agents to follow
   - User message: the formatted trajectory text, with JPEG images attached as vision content blocks
3. Calls `provider.complete(messages:tools:)` with no tools
4. Extracts the `.text` response body
5. Returns the raw markdown body string

Throws on network failure, empty response, or non-text LLM response.

### System prompt template

```
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
```

---

## UI

### `CompanionManager` additions

```swift
@Published var isDemonstratingSkill: Bool = false
@Published var pendingTrajectory: ActionTrajectory? = nil
@Published var isExtractingSkill: Bool = false
@Published var skillExtractionError: String? = nil

private let demonstrationRecorder = DemonstrationRecorder()
```

**`startDemonstration()`**
- Sets `isDemonstratingSkill = true`
- Calls `demonstrationRecorder.start()`

**`stopDemonstration()`**
- Calls `demonstrationRecorder.stop()` → stores in `pendingTrajectory`
- Sets `isDemonstratingSkill = false`

**`saveSkill(name: String) async`**
- Sets `isExtractingSkill = true`, clears `skillExtractionError`
- Calls `SkillExtractor.shared.extract(trajectory: pendingTrajectory!, name: name)`
- On success: writes to `SkillLibraryStore.shared` with `taskTypes: [.generalMac]` (user demonstrations are app-agnostic), clears `pendingTrajectory`, sets `isExtractingSkill = false`
- On failure: sets `skillExtractionError`, sets `isExtractingSkill = false`

**`discardDemonstration()`**
- Clears `pendingTrajectory`, `skillExtractionError`

### Hotkey: Ctrl+Option+W

Handled inside `GlobalPushToTalkShortcutMonitor`. Detects keycode 13 (W) with Ctrl+Option modifiers. Calls `CompanionManager.startDemonstration()` or `stopDemonstration()` based on `isDemonstratingSkill`.

### `CompanionPanelView` additions

**Recording button row** (in the tools/developer section):
- Idle: "Record Demonstration" button
- Recording: pulsing red dot + "Stop Recording" button, both driven by `isDemonstratingSkill`

**Confirmation sheet** — presented when `pendingTrajectory != nil`:
- Title: "Save Demonstration as Skill"
- `TextField` pre-filled with `"Demonstration \(formatted date)"`
- "Save" button → calls `CompanionManager.saveSkill(name:)`; disabled while `isExtractingSkill`
- "Discard" button → calls `CompanionManager.discardDemonstration()`
- Progress spinner when `isExtractingSkill == true`
- Inline error text when `skillExtractionError != nil` with a "Retry" button

---

## New Files

| File | Purpose |
|------|---------|
| `TipTour/Agents/Skills/DemonstrationTypes.swift` | `ObservedActionType`, `ObservedAction`, `ActionTrajectory` |
| `TipTour/Agents/Skills/DemonstrationRecorder.swift` | Records user actions via CGEventTap + NSWorkspace notifications |
| `TipTour/Agents/Skills/SkillExtractor.swift` | Actor singleton — formats trajectory, calls Claude, returns skill body |

## Modified Files

| File | Change |
|------|--------|
| `CompanionManager.swift` | Add `demonstrationRecorder`, `isDemonstratingSkill`, `pendingTrajectory`, `isExtractingSkill`, `skillExtractionError`; add `startDemonstration`, `stopDemonstration`, `saveSkill`, `discardDemonstration` |
| `GlobalPushToTalkShortcutMonitor.swift` | Detect Ctrl+Option+W, call CompanionManager toggle |
| `CompanionPanelView.swift` | Add recording button row + confirmation sheet |

---

## Testing

**File:** `TipTourTests/DemonstrationTests.swift`

### `DemonstrationRecorder` tests (actions injected directly — no live CGEventTap)

- `start()` clears previous actions
- `stop()` returns trajectory with correct `startedAt`/`endedAt` timestamps
- Consecutive keystrokes to same app are merged into one `.type` action
- Keystroke to different app flushes buffer and starts a new `.type` entry
- Non-printable key (Cmd+S) flushes typing buffer and appends `.keyPress` immediately
- App switch flushes pending typing buffer before appending `.appSwitch`
- `stop()` flushes pending typing buffer into final `.type` action
- `formatForLLM` produces one line per action with correct format

### `SkillExtractor` tests (mock `AnthropicProvider`)

- Empty trajectory → returns body with `## Result` section, no `## Steps`
- Trajectory with click + type actions → body contains formatted action lines
- Provider throws → `extract` rethrows the error

### `CompanionManager` state tests (unit, no UI)

- `startDemonstration()` sets `isDemonstratingSkill = true`
- `stopDemonstration()` sets `isDemonstratingSkill = false` and populates `pendingTrajectory`
- `saveSkill` on success clears `pendingTrajectory` and `isExtractingSkill`
- `saveSkill` on failure sets `skillExtractionError` and clears `isExtractingSkill`
- `discardDemonstration()` clears `pendingTrajectory`
