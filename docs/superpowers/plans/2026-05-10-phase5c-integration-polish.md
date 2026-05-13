# Phase 5C: Integration & Polish Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire voice (Gemini Live) to background agent spawning via a new `spawn_background_task` tool, enforce memory prune on app launch, and fill the remaining integration gaps so the full agent swarm works end-to-end from a voice command.

**Architecture:** A third Gemini Live tool `spawn_background_task(task, task_type)` is declared in `GeminiLiveClient` alongside the existing two tools. `GeminiLiveSession` routes it via a new `onSpawnBackgroundTask` callback to `CompanionManager.spawnBackgroundAgent()`, which calls `AgentSwarmManager.spawn()`. On app launch, `AgentMemoryStore` prunes expired entries. The companion system prompt is updated to mention when to use the new tool.

**Tech Stack:** Swift, `GeminiLiveClient` (WebSocket JSON setup), Swift Testing

---

## File Map

| Action | File | Responsibility |
|--------|------|----------------|
| Modify | `TipTour/GeminiLiveClient.swift` | Declare `spawn_background_task` tool in session setup JSON |
| Modify | `TipTour/GeminiLiveSession.swift` | Add `onSpawnBackgroundTask` callback + route in `handleToolCall` |
| Modify | `TipTour/CompanionManager.swift` | Wire `onSpawnBackgroundTask` callback; prune expired memory on init |
| Modify | `TipTour/CompanionManager.swift:970` | Update system prompt to mention the third tool |
| Create | `TipTourTests/IntegrationPolishTests.swift` | Tests for spawn routing and memory prune |

---

## Task 1: Declare `spawn_background_task` tool in `GeminiLiveClient`

**Files:**
- Modify: `TipTour/GeminiLiveClient.swift`

The `GeminiLiveClient.connect()` method sends a setup JSON message that includes `"tools": [{"functionDeclarations": [...]}]`. Add `spawn_background_task` to that array alongside `point_at_element` and `submit_workflow_plan`.

`spawn_background_task` parameters:
- `task` (string, required): natural-language description of what the background agent should do
- `task_type` (string, required): one of the `TaskType` raw values (`"coding"`, `"browserResearch"`, `"imageGeneration"`, `"videoGeneration"`, `"fileManagement"`, `"generalMac"`, `"analysis"`, `"writing"`)

- [ ] **Step 1: Write the failing test**

Create `TipTourTests/IntegrationPolishTests.swift`:

```swift
import Testing
import Foundation
@testable import TipTour

@Suite struct IntegrationPolishTests {

    // Verify the GeminiLiveClient setup JSON includes spawn_background_task.
    // We do this by reading the static tool dictionary defined in GeminiLiveClient.
    @Test func geminiLiveClientDecloresSpawnBackgroundTaskTool() {
        // The tool is a static let on GeminiLiveClient — check it contains the right fields.
        let tool = GeminiLiveClient.spawnBackgroundTaskToolDeclaration
        #expect((tool["name"] as? String) == "spawn_background_task")
        let params = tool["parameters"] as? [String: Any]
        let props = params?["properties"] as? [String: Any]
        #expect(props?["task"] != nil)
        #expect(props?["task_type"] != nil)
        let required = params?["required"] as? [String]
        #expect(required?.contains("task") == true)
        #expect(required?.contains("task_type") == true)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd /Users/omkar/Desktop/TipTour-macOS/repo
xcodebuild test -scheme TipTour \
  -only-testing:TipTourTests/IntegrationPolishTests/IntegrationPolishTests/geminiLiveClientDecloresSpawnBackgroundTaskTool \
  2>&1 | grep -E "error:|passed|failed"
```

Expected: compile error — `GeminiLiveClient.spawnBackgroundTaskToolDeclaration` not found.

- [ ] **Step 3: Add the tool declaration to `GeminiLiveClient.swift`**

In `TipTour/GeminiLiveClient.swift`, find the block where `pointAtElementTool` and `submitWorkflowPlanTool` are defined as local constants inside `connect()`. Extract them to static lets so the test can access them, and add the third tool.

Inside the class (not inside `connect()`), add three static computed properties:

```swift
// MARK: - Tool declarations (static so they can be verified in tests)

static var pointAtElementToolDeclaration: [String: Any] {
    [
        "name": "point_at_element",
        "description": "Fly the cursor to a single visible UI element on the user's screen. Use for simple 'where is X' / 'point at X' questions where ONE element is all that's needed and it's visible right now.",
        "parameters": [
            "type": "object",
            "properties": [
                "label": [
                    "type": "string",
                    "description": "The literal visible text of the element — e.g. 'Save', 'File', 'Source Control'. Use the actual text on screen, not a description."
                ],
                "box_2d": [
                    "type": "array",
                    "description": "Optional bounding box for the element in normalized [y1, x1, y2, x2] form, each value in [0, 1000] relative to the screenshot. RECOMMENDED for apps without accessibility (Blender, games, canvas tools) and for ambiguous labels. Origin is top-left, y comes first.",
                    "items": ["type": "integer"],
                    "minItems": 4,
                    "maxItems": 4
                ]
            ],
            "required": ["label"]
        ]
    ]
}

static var submitWorkflowPlanToolDeclaration: [String: Any] {
    [
        "name": "submit_workflow_plan",
        "description": "For any multi-step walkthrough (opening a menu then picking an item, 'how do I X', 'walk me through Y', 'teach me Z'). Emit the FULL plan of steps as a structured argument. Gemini narrates each step after the tool returns, while the cursor flies through them in order.",
        "parameters": [
            "type": "object",
            "properties": [
                "goal": [
                    "type": "string",
                    "description": "Short natural-language summary of what the user wants to accomplish."
                ],
                "app": [
                    "type": "string",
                    "description": "EXACT name of the foreground application visible in the screenshot — e.g. 'Blender', 'Xcode', 'GarageBand'. Used to target the right accessibility tree. Do NOT guess 'macOS' or 'unknown'."
                ],
                "steps": [
                    "type": "array",
                    "description": "Ordered list of steps. First step MUST be visible on the current screen; later steps describe the path to take after clicking step 1.",
                    "items": [
                        "type": "object",
                        "properties": [
                            "label": [
                                "type": "string",
                                "description": "Literal visible text of the element, or nearest label for an icon."
                            ],
                            "hint": [
                                "type": "string",
                                "description": "Short sentence describing this step — e.g. 'Open the File menu'."
                            ],
                            "box_2d": [
                                "type": "array",
                                "description": "Optional bounding box for the element in normalized [y1, x1, y2, x2] form, each value in [0, 1000] relative to the current screenshot.",
                                "items": ["type": "integer"],
                                "minItems": 4,
                                "maxItems": 4
                            ]
                        ],
                        "required": ["label"]
                    ]
                ]
            ],
            "required": ["goal", "app", "steps"]
        ]
    ]
}

static var spawnBackgroundTaskToolDeclaration: [String: Any] {
    [
        "name": "spawn_background_task",
        "description": "Start a background AI agent to handle a task that runs independently while the user continues the conversation. Use for tasks that take more than a few seconds, require tool use (shell, web search, file I/O), or need to run autonomously without voice narration. Do NOT use for quick lookups or things point_at_element/submit_workflow_plan already handle.",
        "parameters": [
            "type": "object",
            "properties": [
                "task": [
                    "type": "string",
                    "description": "A clear, complete description of what the background agent should do. Include any context needed — the agent has no memory of this voice conversation."
                ],
                "task_type": [
                    "type": "string",
                    "description": "Category of the task, used to route to the right model and tools.",
                    "enum": ["coding", "browserResearch", "imageGeneration", "videoGeneration",
                             "fileManagement", "generalMac", "analysis", "writing"]
                ]
            ],
            "required": ["task", "task_type"]
        ]
    ]
}
```

Then in `connect()`, replace the inline local constants with the static properties:

```swift
// Replace:
let pointAtElementTool: [String: Any] = [ ... long block ... ]
let submitWorkflowPlanTool: [String: Any] = [ ... long block ... ]
// And the tools line:
["functionDeclarations": [pointAtElementTool, submitWorkflowPlanTool]]

// With:
["functionDeclarations": [
    Self.pointAtElementToolDeclaration,
    Self.submitWorkflowPlanToolDeclaration,
    Self.spawnBackgroundTaskToolDeclaration
]]
```

- [ ] **Step 4: Run test to verify it passes**

```bash
xcodebuild test -scheme TipTour \
  -only-testing:TipTourTests/IntegrationPolishTests/IntegrationPolishTests/geminiLiveClientDecloresSpawnBackgroundTaskTool \
  2>&1 | grep -E "passed|failed|error:"
```

Expected: 1 passed.

- [ ] **Step 5: Commit**

```bash
git add TipTour/GeminiLiveClient.swift TipTourTests/IntegrationPolishTests.swift
git commit -m "feat: declare spawn_background_task tool in GeminiLiveClient setup"
```

---

## Task 2: Route `spawn_background_task` in `GeminiLiveSession`

**Files:**
- Modify: `TipTour/GeminiLiveSession.swift`

`GeminiLiveSession.handleToolCall(id:name:args:)` has a `switch name` block with cases for `"point_at_element"` and `"submit_workflow_plan"`. Add a `"spawn_background_task"` case and a new `onSpawnBackgroundTask` callback property.

- [ ] **Step 1: Write the failing test**

Add to `TipTourTests/IntegrationPolishTests.swift`:

```swift
@Test @MainActor func geminiLiveSessionFiresSpawnCallbackOnSpawnTool() async {
    let session = GeminiLiveSession(
        apiKeyURL: "https://example.com/fake-key",
        systemPrompt: "test"
    )

    var capturedTask: String?
    var capturedTaskType: String?
    session.onSpawnBackgroundTask = { task, taskType in
        capturedTask = task
        capturedTaskType = taskType
        return ["ok": true, "message": "spawned"]
    }

    // Simulate the tool call being received — call the internal handler directly.
    session.simulateToolCall(
        id: "call-1",
        name: "spawn_background_task",
        args: ["task": "search for trending Swift libraries", "task_type": "browserResearch"]
    )

    // Give the Task { } inside handleToolCall time to run.
    try? await Task.sleep(nanoseconds: 50_000_000)

    #expect(capturedTask == "search for trending Swift libraries")
    #expect(capturedTaskType == "browserResearch")
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
xcodebuild test -scheme TipTour \
  -only-testing:TipTourTests/IntegrationPolishTests/IntegrationPolishTests/geminiLiveSessionFiresSpawnCallbackOnSpawnTool \
  2>&1 | grep -E "error:|passed|failed"
```

Expected: compile error — `onSpawnBackgroundTask` and `simulateToolCall` not found.

- [ ] **Step 3: Update `GeminiLiveSession.swift`**

1. Add the callback property (near the other `var on...` callbacks):

```swift
/// Fired when Gemini calls `spawn_background_task(task, task_type)`.
/// The handler should spawn a background agent and return an acknowledgement.
var onSpawnBackgroundTask: ((_ task: String, _ taskType: String) async -> [String: Any])?
```

2. In `handleToolCall(id:name:args:)`, inside the `switch name` block, add before `default`:

```swift
case "spawn_background_task":
    let task = (args["task"] as? String) ?? ""
    let taskType = (args["task_type"] as? String) ?? "generalMac"
    if !task.isEmpty, let handler = onSpawnBackgroundTask {
        response = await handler(task, taskType)
    } else {
        print("[GeminiLiveSession] spawn_background_task called with no handler or empty task")
    }
```

3. Add the test-only `simulateToolCall` method at the bottom of the class (inside `#if DEBUG` is fine, but since the test imports `@testable import TipTour` it will be visible either way — put it outside `#if DEBUG` so tests always work):

```swift
// MARK: - Test support

/// Directly invokes handleToolCall without a live WebSocket. Used in unit tests.
func simulateToolCall(id: String, name: String, args: [String: Any]) {
    handleToolCall(id: id, name: name, args: args)
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
xcodebuild test -scheme TipTour \
  -only-testing:TipTourTests/IntegrationPolishTests/IntegrationPolishTests/geminiLiveSessionFiresSpawnCallbackOnSpawnTool \
  2>&1 | grep -E "passed|failed|error:"
```

Expected: 1 passed.

- [ ] **Step 5: Commit**

```bash
git add TipTour/GeminiLiveSession.swift TipTourTests/IntegrationPolishTests.swift
git commit -m "feat: route spawn_background_task tool call through GeminiLiveSession callback"
```

---

## Task 3: Wire callback in `CompanionManager`

**Files:**
- Modify: `TipTour/CompanionManager.swift`

`CompanionManager.wireCallbacks(on:)` already wires `onPointAtElement` and `onSubmitWorkflowPlan`. Add `onSpawnBackgroundTask` so voice commands actually spawn agents. The callback calls the existing `spawnBackgroundAgent(taskDescription:taskTypeRaw:)` method.

- [ ] **Step 1: Write the failing test**

Add to `TipTourTests/IntegrationPolishTests.swift`:

```swift
@Test @MainActor func companionManagerWiresSpawnCallbackToSwarmManager() async throws {
    // This test verifies that after wireCallbacks, a spawn_background_task tool
    // call routed through GeminiLiveSession reaches AgentSwarmManager.
    // We check indirectly: the overlay state publisher should emit one agent
    // after the callback fires.
    let manager = CompanionManager()
    let session = manager.voiceBackend  // triggers wireCallbacks

    var publishedStatuses: [[AgentStatus]] = []
    let cancellable = AgentSwarmManager.shared.overlayStatePublisher.sink { statuses in
        publishedStatuses.append(statuses)
    }
    defer { cancellable.cancel() }

    session.simulateToolCall(
        id: "call-2",
        name: "spawn_background_task",
        args: ["task": "list files in home directory", "task_type": "fileManagement"]
    )

    try await Task.sleep(nanoseconds: 200_000_000)  // 200ms — let the Task inside handleToolCall complete

    // At least one overlay update should have arrived with ≥1 agent
    let hadAgent = publishedStatuses.contains { !$0.isEmpty }
    #expect(hadAgent)

    // Clean up: terminate all spawned agents
    await AgentSwarmManager.shared.terminateAll()
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
xcodebuild test -scheme TipTour \
  -only-testing:TipTourTests/IntegrationPolishTests/IntegrationPolishTests/companionManagerWiresSpawnCallbackToSwarmManager \
  2>&1 | grep -E "error:|passed|failed"
```

Expected: fail — the callback isn't wired yet so no agent is spawned.

- [ ] **Step 3: Add callback wiring in `CompanionManager.wireCallbacks(on:)`**

In `TipTour/CompanionManager.swift`, inside `wireCallbacks(on:)`, after the `backend.onSubmitWorkflowPlan = { ... }` block, add:

```swift
backend.onSpawnBackgroundTask = { [weak self] task, taskType in
    await self?.spawnBackgroundAgent(taskDescription: task, taskTypeRaw: taskType)
    return ["ok": true, "message": "Background task started. I'll let you know when it's done."]
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
xcodebuild test -scheme TipTour \
  -only-testing:TipTourTests/IntegrationPolishTests/IntegrationPolishTests/companionManagerWiresSpawnCallbackToSwarmManager \
  2>&1 | grep -E "passed|failed|error:"
```

Expected: 1 passed.

- [ ] **Step 5: Commit**

```bash
git add TipTour/CompanionManager.swift TipTourTests/IntegrationPolishTests.swift
git commit -m "feat: wire spawn_background_task callback in CompanionManager"
```

---

## Task 4: Update the companion system prompt

**Files:**
- Modify: `TipTour/CompanionManager.swift` (the `companionVoiceResponseSystemPrompt` static property around line 970)

The existing prompt says "you have exactly TWO tools." Update it to say three, and add a description of when to use `spawn_background_task` vs the other two tools.

- [ ] **Step 1: Find the system prompt**

```bash
grep -n "TWO tools\|exactly.*tools\|point_at_element\|submit_workflow_plan" \
  /Users/omkar/Desktop/TipTour-macOS/repo/TipTour/CompanionManager.swift | head -10
```

Note the line numbers of the system prompt constant.

- [ ] **Step 2: Update the prompt**

Find the line that reads (approximately):

```
you have exactly TWO tools. call AT MOST ONE tool per turn.
```

Replace that sentence and the tool description block. The new version:

```
you have exactly THREE tools. call AT MOST ONE tool per turn. do NOT narrate before the tool call. call it silently, wait for the response, THEN speak ONCE.

TOOL: point_at_element(label, box_2d?)
→ use for: "where is X", "show me X", "point at X" — single visible element, answer is immediate
→ do NOT use for multi-step tasks

TOOL: submit_workflow_plan(goal, app, steps)
→ use for: "how do I X", "walk me through Y", "teach me Z" — multi-step walkthroughs
→ gemini produces the full step list; cursor follows in sync with your narration

TOOL: spawn_background_task(task, task_type)
→ use for: tasks that take time, use tools (shell/web/files), or run autonomously
→ examples: "search for X and summarize", "generate an image of X", "write a script that does Y"
→ do NOT use for pointing or walkthroughs — use the other tools for those
→ task_type must be one of: coding, browserResearch, imageGeneration, videoGeneration, fileManagement, generalMac, analysis, writing
→ after calling this tool, briefly confirm to the user that the task has started
```

Also update the instruction about tool count where it's referenced elsewhere in the prompt. Use `grep` to find all occurrences of "TWO" in the prompt and replace with "THREE".

- [ ] **Step 3: Build and verify no compile errors**

```bash
xcodebuild build -scheme TipTour 2>&1 | grep -E "error:|Build succeeded|Build FAILED"
```

Expected: `Build succeeded`.

- [ ] **Step 4: Commit**

```bash
git add TipTour/CompanionManager.swift
git commit -m "feat: update companion system prompt to include spawn_background_task tool"
```

---

## Task 5: Prune expired memories on app launch

**Files:**
- Modify: `TipTour/CompanionManager.swift`

`AgentMemoryStore` prunes expired entries in its `init()`, but that init runs synchronously before the first async call. This is correct for removing stale entries from the loaded JSON, but a belt-and-suspenders async prune on launch ensures any entries that expired during the current session are also cleaned up. Call `AgentMemoryStore.shared.pruneExpired()` during `CompanionManager.start()`.

- [ ] **Step 1: Write the failing test**

Add to `TipTourTests/IntegrationPolishTests.swift`:

```swift
@Test func agentMemoryStorePrunesExpiredOnExplicitCall() async throws {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let fileURL = tempDir.appendingPathComponent("memory.json")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let store = AgentMemoryStore(fileURL: fileURL)

    // Write one already-expired entry and one permanent entry.
    let expiredEntry = AgentMemoryEntry.makeTaskResult(content: "old result", taskTypes: [.generalMac])
    // Force expiry in the past by writing a raw entry with a past expiresAt.
    let pastExpiry = Calendar.current.date(byAdding: .day, value: -10, to: Date())!
    var mutableExpired = expiredEntry
    // AgentMemoryEntry uses a struct — create via the internal init if available,
    // otherwise use writeRawEntry with a manually constructed entry.
    // Since AgentMemoryEntry is Codable, build a JSON-round-tripped copy with adjusted expiry:
    var encodedEntry = try JSONEncoder().encode(expiredEntry)
    var dict = try JSONSerialization.jsonObject(with: encodedEntry) as! [String: Any]
    dict["expiresAt"] = ISO8601DateFormatter().string(from: pastExpiry)
    encodedEntry = try JSONSerialization.data(withJSONObject: dict)
    let expiredWithPast = try JSONDecoder().decode(AgentMemoryEntry.self, from: encodedEntry)

    await store.writeRawEntry(expiredWithPast)
    await store.write(content: "permanent fact", entryType: .fact,
                      taskTypes: [.generalMac], permanent: true)

    // Before prune: both entries present.
    let beforePrune = await store.query(taskDescription: "result", taskTypes: [.generalMac], limit: 50)
    // After prune: only permanent remains.
    await store.pruneExpired()
    let afterPrune = await store.query(taskDescription: "permanent", taskTypes: [.generalMac], limit: 50)
    #expect(afterPrune.count == 1)
    #expect(afterPrune[0].isPermanent)
}
```

- [ ] **Step 2: Run test to verify it fails or passes**

```bash
xcodebuild test -scheme TipTour \
  -only-testing:TipTourTests/IntegrationPolishTests/IntegrationPolishTests/agentMemoryStorePrunesExpiredOnExplicitCall \
  2>&1 | grep -E "error:|passed|failed"
```

`AgentMemoryStore.pruneExpired()` already exists — this test may pass as-is. If it passes, move on. If it fails due to a missing `AgentMemoryEntry` struct field, fix the test to match the actual struct shape.

- [ ] **Step 3: Call `pruneExpired()` in `CompanionManager.start()`**

In `TipTour/CompanionManager.swift`, find the `start()` method (or wherever `bootstrapFromKeychain()` is called at launch). After `await LLMProviderRegistry.shared.bootstrapFromKeychain()`, add:

```swift
// Prune any entries that expired since the last launch.
Task { await AgentMemoryStore.shared.pruneExpired() }
```

The `Task { }` wrapper ensures this doesn't block the main-thread start sequence.

- [ ] **Step 4: Build and verify no compile errors**

```bash
xcodebuild build -scheme TipTour 2>&1 | grep -E "error:|Build succeeded|Build FAILED"
```

Expected: `Build succeeded`.

- [ ] **Step 5: Commit**

```bash
git add TipTour/CompanionManager.swift TipTourTests/IntegrationPolishTests.swift
git commit -m "feat: prune expired memory entries on app launch"
```

---

## Task 6: Full test suite run + CLAUDE.md update

- [ ] **Step 1: Run all integration tests**

```bash
xcodebuild test -scheme TipTour -only-testing:TipTourTests/IntegrationPolishTests 2>&1 | grep -E "Test.*passed|Test.*failed|error:" | head -20
```

Expected: All tests pass (exact count depends on how many passed in earlier steps).

- [ ] **Step 2: Run the full test suite**

```bash
xcodebuild test -scheme TipTour 2>&1 | grep -E "Test Suite.*passed|Test Suite.*failed|error:" | tail -5
```

Expected: Suite passes with no regressions.

- [ ] **Step 3: Update CLAUDE.md**

In the Architecture section, update the Voice Mode paragraph to mention the third tool:

> **Voice Mode**: Gemini Live only. [...] Three tools exposed: `point_at_element(label, box_2d?)` for single-click asks, `submit_workflow_plan(goal, app, steps)` for multi-step walkthroughs, and `spawn_background_task(task, task_type)` for autonomous background agents.

In the Key Files table:
- Update `GeminiLiveClient.swift` (~643) note to mention spawn_background_task and the extraction of tool declarations to static lets
- Update `GeminiLiveSession.swift` (~900) note to mention `onSpawnBackgroundTask` callback
- Update `CompanionManager.swift` (~1000) note to mention `onSpawnBackgroundTask` wiring and launch-time memory prune
- Add new row: `TipTourTests/IntegrationPolishTests.swift | ~120 | Integration tests: spawn_background_task tool routing through GeminiLive → CompanionManager → AgentSwarmManager, and memory prune on launch.`

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: update CLAUDE.md for Phase 5C integration and polish"
```
