# Plan 3c — Voice Loop (Gemini Live + `ask_hermes`) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire Gemini Live to delegate to Hermes via a new `ask_hermes(task)` tool, share one Hermes session between the voice loop and the Talk-to-Hermes chat window, and remove the dead `submit_workflow_plan` / `spawn_background_task` paths plus the 15 `TODO(plan-2)` markers.

**Architecture:** Gemini Live remains the front-line voice agent for basic asks (kept `point_at_element`); it gains a single new tool `ask_hermes(task)` that routes to a shared `HermesClient` owned by `CompanionManager`. The MCP server is started at app launch (still hosting `speak` / `take_screenshot` / `get_a11y_tree` / `point_at`). The 1000-line companion system prompt is reshaped around 2 tools and the autopilot toggle / workflow checklist / agents-skills-learning settings tabs are deleted.

**Tech Stack:** Swift / SwiftUI / AppKit on macOS, Network.framework `NWListener` for MCP, Gemini Live WebSocket API, Hermes (Python subprocess via ACP), XCTest.

**Spec:** [docs/superpowers/specs/2026-05-14-plan-3c-voice-loop-design.md](../specs/2026-05-14-plan-3c-voice-loop-design.md)

---

## File map

**Modified:**

- `TipTour/CompanionManager.swift` — gains shared `hermesClient` + `mcpServer` properties; MCP server start moves here; `handleToolAskHermes` added; all 15 `TODO(plan-2)` paths deleted; autopilot flag + system-prompt branching removed; system prompt rewritten for 2-tool surface.
- `TipTour/Hermes/HermesDebugMenuController.swift` — takes `HermesClient` + `MCPServer` references via init; no longer creates them or starts the MCP server; `windowWillClose` no longer terminates the subprocess.
- `TipTour/Hermes/HermesClient.swift` — new computed property `lastAgentReplyText: String?`.
- `TipTour/GeminiLiveClient.swift` — new static `askHermesToolDeclaration`; `setupMessage.tools` registers `point_at_element` + `ask_hermes` only.
- `TipTour/GeminiLiveSession.swift` — new `onAskHermes` callback; `handleToolCall` routes `ask_hermes`; `onSubmitWorkflowPlan` + `onSpawnBackgroundTask` callbacks + dispatch branches removed; stale "skip screenshot while plan in flight" guard removed.
- `TipTour/CompanionPanelView.swift` — autopilot toggle row, workflow-checklist UI, save-skill sheet, skill-recording controls, Settings sheet button all removed.
- `TipTour/TipTourApp.swift` — `CompanionAppDelegate.applicationDidFinishLaunching` reorders: `companionManager.start()` runs before `HermesDebugMenuController` is constructed, and the controller now receives `hermesClient` + `mcpServer` references.

**Created:**

- `TipTourTests/GeminiLiveSessionTests.swift` — unit tests for the `ask_hermes` tool declaration shape and `simulateToolCall` routing.

**Deleted:**

- `TipTour/ClickDetector.swift` — only consumer was the deleted `WorkflowRunner`.
- `TipTour/Agents/UI/SettingsView.swift` — references deleted agents/skills/learning stores.
- `TipTour/Agents/UI/` and `TipTour/Agents/` — empty after `SettingsView.swift` is gone.

---

## Build / test conventions

This is an Xcode project. **Do NOT run `xcodebuild`** from the terminal — it invalidates TCC permissions per `CLAUDE.md`. Each task that has a build or test verification step uses Xcode directly:

- **Build:** in Xcode, select the `TipTour` scheme, then ⌘B (or Product → Build). Expected: green build, no errors. Existing Swift-6 / `onChange` warnings are pre-existing and stay.
- **Run tests:** in Xcode, ⌘U (or Product → Test). The test you want runs along with the rest of the suite. Expected: all green except live tests that need `~/.hermes/config.yaml` (those skip via `try XCTSkipUnless`).
- **Run the app:** ⌘R. The app appears in the menu bar (no dock icon). Permissions prompts may appear on first run.

---

## Task 1: Move HermesClient + MCPServer ownership to CompanionManager

**Why first:** every other task (especially Task 4 — the `ask_hermes` handler) assumes the shared client exists on `CompanionManager`. Pure refactor — no behavior change visible to the user. After this task, Hermes still launches lazily, the chat window still works, the MCP server still hosts the four tools, but the lifecycle is owned by the long-lived `CompanionManager` singleton instead of `HermesDebugMenuController`.

**Files:**

- Modify: `TipTour/CompanionManager.swift` — add stored properties + MCP setup in `start()`
- Modify: `TipTour/Hermes/HermesDebugMenuController.swift` — accept references, drop MCP setup, drop teardown
- Modify: `TipTour/TipTourApp.swift` — pass references and reorder

- [ ] **Step 1.1: Add the shared properties to `CompanionManager`.**

Open `TipTour/CompanionManager.swift`. Find the existing property block near the top of the class (around the `private var voiceStateSoundPlayer: AVAudioPlayer?` declaration, ~line 79). Add the following two properties just after it:

```swift
/// The single Hermes client shared by the voice loop (ask_hermes tool)
/// and the Talk-to-Hermes chat window. Launches a Python subprocess
/// lazily on first send; stays alive for the app's lifetime.
let hermesClient = HermesClient()

/// In-process MCP server exposing speak / take_screenshot / get_a11y_tree
/// / point_at to Hermes. Started in `start()`; the URL is set on
/// hermesClient before the first send so Hermes registers the MCP
/// server during session/new.
let mcpServer = MCPServer(name: "tiptour-tools")
```

- [ ] **Step 1.2: Register MCP tools and start the server in `CompanionManager.start()`.**

In the same file find `func start()` (search for `func start(`). At the very top of the body — before any other setup — insert this block:

```swift
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
```

- [ ] **Step 1.3: Stop and terminate Hermes on `CompanionManager.stop()`.**

Find `func stop()`. Add these two lines at the very top of the body (before any other teardown):

```swift
hermesClient.stop()
mcpServer.stop()
```

- [ ] **Step 1.4: Rewrite `HermesDebugMenuController` to receive references.**

Open `TipTour/Hermes/HermesDebugMenuController.swift`. Replace the entire class body with the version below. Three things change vs. the current file: the stored `client` / `mcpServer` are now `let`s assigned via init, `install` no longer registers tools or starts the server, and `windowWillClose` no longer terminates the subprocess.

```swift
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
```

- [ ] **Step 1.5: Wire the new ownership in `CompanionAppDelegate`.**

Open `TipTour/TipTourApp.swift`. Find `applicationDidFinishLaunching`. Replace the existing four-line block:

```swift
menuBarPanelManager = MenuBarPanelManager(companionManager: companionManager)
hermesDebugMenu = HermesDebugMenuController()
hermesDebugMenu?.install(companionManager: companionManager)
// AgentOverlayWindowController.shared removed with Overlay/ strip
companionManager.start()
```

with:

```swift
menuBarPanelManager = MenuBarPanelManager(companionManager: companionManager)
companionManager.start()  // starts MCP server + sets hermesClient.mcpServerURL
hermesDebugMenu = HermesDebugMenuController(
    client: companionManager.hermesClient,
    mcpServer: companionManager.mcpServer
)
hermesDebugMenu?.install(companionManager: companionManager)
```

- [ ] **Step 1.6: Build in Xcode.**

Open the project in Xcode, ⌘B. Expected: green build. Any error here means a path was missed — re-check Steps 1.1–1.5 before continuing.

- [ ] **Step 1.7: Smoke-run the app.**

⌘R. Expected:
- Console prints `[CompanionManager] MCP server up at http://127.0.0.1:NNNNN`
- The 🛠 Hermes status item appears in the menu bar
- ⌥⇧H opens the chat window
- Sending a message works (assuming `~/.hermes/config.yaml` is set up)
- Closing the chat window keeps the menu item alive
- Re-opening with ⌥⇧H shows the chat window with the SAME transcript still there (proves the subprocess was not torn down)

- [ ] **Step 1.8: Commit.**

```bash
git add TipTour/CompanionManager.swift \
        TipTour/Hermes/HermesDebugMenuController.swift \
        TipTour/TipTourApp.swift
git commit -m "refactor(hermes): own HermesClient + MCPServer in CompanionManager"
```

---

## Task 2: Add `lastAgentReplyText` accessor on HermesClient

**Why:** Task 4's `handleToolAskHermes` needs to pull Hermes's final reply text out of the transcript after `send()` returns. The accessor is trivial — three lines — but two unit tests pin the contract.

**Files:**

- Modify: `TipTour/Hermes/HermesClient.swift`
- Modify: `TipTourTests/HermesClientTests.swift`

- [ ] **Step 2.1: Write the failing tests.**

Open `TipTourTests/HermesClientTests.swift`. Add these two test methods at the bottom of the `HermesClientTests` class (before the last closing `}`):

```swift
@MainActor
func testLastAgentReplyTextReturnsMostRecentAgentTurn() {
    let client = HermesClient()
    // Build a transcript: user → agent("A") → user → agent("B"). The
    // accessor must return "B" (the most recent agent turn), not "A".
    client._setTranscriptForTesting([
        .user(id: UUID(), text: "first"),
        .agent(id: UUID(), text: "A", toolCalls: []),
        .user(id: UUID(), text: "second"),
        .agent(id: UUID(), text: "B", toolCalls: [])
    ])
    XCTAssertEqual(client.lastAgentReplyText, "B")
}

@MainActor
func testLastAgentReplyTextReturnsNilWhenNoAgentTurns() {
    let client = HermesClient()
    XCTAssertNil(client.lastAgentReplyText)
    client._setTranscriptForTesting([.user(id: UUID(), text: "hi")])
    XCTAssertNil(client.lastAgentReplyText)
}
```

- [ ] **Step 2.2: Run the tests, watch them fail.**

In Xcode, click the diamond next to each new test (or run the whole `HermesClientTests` class). Expected: both fail because `lastAgentReplyText` and `_setTranscriptForTesting` don't exist yet.

- [ ] **Step 2.3: Add the accessor and the test-only setter to `HermesClient`.**

Open `TipTour/Hermes/HermesClient.swift`. Find the `@Published private(set) var transcript: [ChatTurn] = []` declaration (around line 10). Just below the three `@Published` declarations (still inside the `// MARK: Published state` block), add:

```swift
/// The text of the most recent `.agent` turn in `transcript`, or `nil`
/// if no agent has spoken yet. Used by CompanionManager.handleToolAskHermes
/// to extract Hermes's final answer for Gemini to speak.
var lastAgentReplyText: String? {
    for turn in transcript.reversed() {
        if case .agent(_, let text, _) = turn { return text }
    }
    return nil
}

/// Test-only escape hatch for seeding transcript state without running a
/// real Hermes subprocess. Underscore-prefixed to flag it as private API.
func _setTranscriptForTesting(_ turns: [ChatTurn]) {
    transcript = turns
}
```

- [ ] **Step 2.4: Re-run the tests, watch them pass.**

In Xcode, ⌘U on the two new tests. Expected: both pass.

- [ ] **Step 2.5: Commit.**

```bash
git add TipTour/Hermes/HermesClient.swift TipTourTests/HermesClientTests.swift
git commit -m "feat(hermes): HermesClient.lastAgentReplyText accessor"
```

---

## Task 3: Add `ask_hermes` tool declaration + callback plumbing

**Why:** This lays the wire-level plumbing — the tool declaration goes into the Gemini setup message, the `onAskHermes` callback exists on `GeminiLiveSession`, and `handleToolCall` routes `ask_hermes` to it. No handler yet (that's Task 4) — when Gemini calls the tool with no handler set, the existing fallback returns `["ok": false, "error": "tool_unavailable"]`.

**Files:**

- Modify: `TipTour/GeminiLiveClient.swift`
- Modify: `TipTour/GeminiLiveSession.swift`
- Create: `TipTourTests/GeminiLiveSessionTests.swift`

- [ ] **Step 3.1: Write the failing tests.**

Create `TipTourTests/GeminiLiveSessionTests.swift` with this content:

```swift
import XCTest
@testable import TipTour

final class GeminiLiveSessionTests: XCTestCase {

    @MainActor
    func testAskHermesToolDeclarationShape() {
        let decl = GeminiLiveClient.askHermesToolDeclaration
        XCTAssertEqual(decl["name"] as? String, "ask_hermes")
        guard let params = decl["parameters"] as? [String: Any],
              let props = params["properties"] as? [String: Any],
              let task = props["task"] as? [String: Any] else {
            return XCTFail("ask_hermes declaration missing parameters.properties.task")
        }
        XCTAssertEqual(task["type"] as? String, "string")
        XCTAssertEqual(params["required"] as? [String], ["task"])
    }

    @MainActor
    func testSimulateAskHermesRoutesToCallback() async {
        let session = GeminiLiveSession(
            apiKeyURL: "http://localhost:0/unused",
            systemPrompt: "test"
        )

        // Bypass the "user has not spoken yet" gate so the dispatcher
        // actually runs the switch case for ask_hermes.
        session._setHasReceivedUserSpeechForTesting(true)

        var capturedID: String?
        var capturedTask: String?
        let waited = expectation(description: "callback ran")
        session.onAskHermes = { id, task in
            capturedID = id
            capturedTask = task
            waited.fulfill()
            return ["ok": true, "text": "hello back"]
        }

        session.simulateToolCall(
            id: "tc-1",
            name: "ask_hermes",
            args: ["task": "say hello"]
        )

        await fulfillment(of: [waited], timeout: 2.0)
        XCTAssertEqual(capturedID, "tc-1")
        XCTAssertEqual(capturedTask, "say hello")
    }
}
```

- [ ] **Step 3.2: Run the tests, watch them fail.**

In Xcode, ⌘U on `GeminiLiveSessionTests`. Expected: both fail (compile errors — `askHermesToolDeclaration`, `onAskHermes`, `_setHasReceivedUserSpeechForTesting` don't exist).

- [ ] **Step 3.3: Add `askHermesToolDeclaration` to `GeminiLiveClient`.**

Open `TipTour/GeminiLiveClient.swift`. Find `static var spawnBackgroundTaskToolDeclaration: [String: Any]` (around line 160). Immediately AFTER its closing `}`, add:

```swift
static var askHermesToolDeclaration: [String: Any] {
    [
        "name": "ask_hermes",
        "description": "Delegate to Hermes — a deeper-reasoning sub-agent with shell, file, web, and screen tools. Use for coding questions, multi-step research, tasks that need running commands or reading files, and anything that benefits from longer, more careful thought. Don't use for 'where is X' on screen (use point_at_element) or quick chit-chat. Hermes returns its final answer as text in the toolResponse; you then paraphrase it aloud for voice. Speak ONE short acknowledgement BEFORE the call ('on it, let me check') so the user isn't left in silence while Hermes works.",
        "parameters": [
            "type": "object",
            "properties": [
                "task": [
                    "type": "string",
                    "description": "Complete, self-contained description of the work. Hermes has no memory of this voice conversation — include all the context it needs."
                ]
            ],
            "required": ["task"]
        ]
    ]
}
```

- [ ] **Step 3.4: Register the new declaration in the setup message.**

In the same file, find the `tools` array inside `setupMessage` (around line 311–316). Update the `functionDeclarations` to include `askHermesToolDeclaration`:

```swift
"tools": [
    ["functionDeclarations": [
        Self.pointAtElementToolDeclaration,
        Self.submitWorkflowPlanToolDeclaration,
        Self.spawnBackgroundTaskToolDeclaration,
        Self.askHermesToolDeclaration
    ]]
]
```

(The two dead declarations will come out in Task 5 — leaving them here for now keeps Task 3 a clean additive change.)

- [ ] **Step 3.5: Add `onAskHermes` callback to `GeminiLiveSession`.**

Open `TipTour/GeminiLiveSession.swift`. Find `var onSpawnBackgroundTask` (around line 93). Immediately AFTER its declaration, add:

```swift
/// Fired when Gemini calls `ask_hermes(task)`. The handler delegates to
/// HermesClient.send(task), waits for Hermes's reply, and returns
/// `{ok: true, text: <hermes reply>}` so Gemini speaks the answer.
var onAskHermes: ((_ id: String, _ task: String) async -> [String: Any])?
```

- [ ] **Step 3.6: Route `ask_hermes` in `handleToolCall`.**

In the same file, find the `switch name` in `handleToolCall` (around line 947). After the `case "spawn_background_task"` block and BEFORE `default:`, insert:

```swift
case "ask_hermes":
    let task = (args["task"] as? String) ?? ""
    if !task.isEmpty, let handler = onAskHermes {
        response = await handler(id, task)
    } else {
        print("[GeminiLiveSession] ask_hermes called with no handler or empty task")
    }
```

- [ ] **Step 3.7: Add the test-only speech-gate setter on `GeminiLiveSession`.**

In the same file, find the `// MARK: - Test support` section near the bottom (around line 986). Add this method just after `simulateToolCall`:

```swift
/// Test-only escape hatch to bypass the "no tool calls before user
/// speech" gate that handleToolCall enforces. Lets unit tests exercise
/// the tool-dispatch switch without a live mic.
func _setHasReceivedUserSpeechForTesting(_ value: Bool) {
    hasReceivedUserSpeechThisSession = value
}
```

- [ ] **Step 3.8: Run the tests, watch them pass.**

In Xcode, ⌘U on `GeminiLiveSessionTests`. Expected: both pass.

- [ ] **Step 3.9: Commit.**

```bash
git add TipTour/GeminiLiveClient.swift \
        TipTour/GeminiLiveSession.swift \
        TipTourTests/GeminiLiveSessionTests.swift
git commit -m "feat(gemini): ask_hermes tool declaration + onAskHermes callback"
```

---

## Task 4: Implement the `ask_hermes` handler in CompanionManager

**Why:** Closes the loop — Gemini calls the tool, CompanionManager routes the task to the shared HermesClient, awaits the reply, returns the text in the toolResponse, Gemini speaks it.

**Files:**

- Modify: `TipTour/CompanionManager.swift`

- [ ] **Step 4.1: Add the handler method.**

Open `TipTour/CompanionManager.swift`. Find the existing `private func handleToolPointAtElement` method (around line 237). Just AFTER its closing `}` (before any next `// MARK:` section), add:

```swift
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
```

- [ ] **Step 4.2: Wire the callback in `wireCallbacks(on:)`.**

In the same file, find `private func wireCallbacks(on backend: GeminiLiveSession)` (around line 109). Just BEFORE the `backend.onInputTranscriptUpdate = ...` line (still inside the function), add:

```swift
backend.onAskHermes = { [weak self] id, task in
    await self?.handleToolAskHermes(id: id, task: task) ?? ["ok": false, "error": "manager_gone"]
}
```

- [ ] **Step 4.3: Build in Xcode.**

⌘B. Expected: green build.

- [ ] **Step 4.4: Smoke-run the app.**

⌘R. Press Ctrl+Option, say *"write me a haiku about coffee"*. Expected:
- Console: `[Tool] 🔧 ask_hermes(task="write me a haiku about coffee")`
- Console: Hermes streams `session/update` chunks
- Console: `[Tool] ✅ ask_hermes returning text.count=NN`
- Gemini speaks the haiku aloud

If Hermes returns an error (no API key, etc.) the toolResponse is `{ok: true, text: ""}` — Gemini speaks nothing or stalls. That's expected for misconfigured environments; the user's local setup has `~/.hermes/.env` and `config.yaml` ready.

- [ ] **Step 4.5: Commit.**

```bash
git add TipTour/CompanionManager.swift
git commit -m "feat(hermes): wire ask_hermes tool through HermesClient"
```

---

## Task 5: Drop dead tool declarations + autopilot + reshape system prompt

**Why:** With `ask_hermes` working, Gemini still sees the broken `submit_workflow_plan` / `spawn_background_task` stubs in its toolkit and the 1000-line prompt still tells it to use them. Remove the dead surface so Gemini's choice is clean: `point_at_element` for on-screen pointing, `ask_hermes` for everything that needs reasoning. Autopilot flag and its prompt branching go too — there's no ActionExecutor wired to consume it.

**Files:**

- Modify: `TipTour/GeminiLiveClient.swift`
- Modify: `TipTour/GeminiLiveSession.swift`
- Modify: `TipTour/CompanionManager.swift`

- [ ] **Step 5.1: Remove the two dead static declarations from `GeminiLiveClient`.**

Open `TipTour/GeminiLiveClient.swift`. Delete the entire `static var submitWorkflowPlanToolDeclaration: [String: Any] { ... }` block (lines 114–158) and the entire `static var spawnBackgroundTaskToolDeclaration: [String: Any] { ... }` block (lines 160–181). The `// MARK: - Tool declarations` comment stays.

- [ ] **Step 5.2: Update the `setupMessage.tools` registry.**

In the same file, find the `tools` array (around line 311). Replace it with:

```swift
"tools": [
    ["functionDeclarations": [
        Self.pointAtElementToolDeclaration,
        Self.askHermesToolDeclaration
    ]]
]
```

- [ ] **Step 5.3: Update the doc comment above `setupMessage`.**

In the same file, find the comment block above `let setupMessage:` (around line 260–270). Replace it with:

```swift
// Send the setup message. This configures the session — model, voice,
// response modalities (audio + text transcriptions), system instruction,
// automatic voice activity detection, AND the tools Gemini can call.
//
// Two tools are declared:
//   - point_at_element(label, box_2d?): single-element pointing
//   - ask_hermes(task): delegate to Hermes for deeper reasoning
//
// Multi-step walkthroughs (the previous submit_workflow_plan) and
// autonomous background work (spawn_background_task) were removed in
// Plan 3c — see the spec for the new architecture.
```

- [ ] **Step 5.4: Remove the dead callbacks from `GeminiLiveSession`.**

Open `TipTour/GeminiLiveSession.swift`. Delete both:
- The doc comment + declaration of `onSubmitWorkflowPlan` (around lines 85–89)
- The doc comment + declaration of `onSpawnBackgroundTask` (around lines 91–93)

- [ ] **Step 5.5: Remove the dead switch branches in `handleToolCall`.**

In the same file, find the `switch name` inside `handleToolCall`. Delete both:
- The entire `case "submit_workflow_plan":` block (around lines 957–965)
- The entire `case "spawn_background_task":` block (around lines 967–974)

The switch should now have three branches: `case "point_at_element"`, `case "ask_hermes"`, `default`.

- [ ] **Step 5.6: Remove the stale "skip screenshot while plan in flight" guard.**

In the same file, find the comment `// TODO(plan-2): re-add the "skip screenshot push while a plan is` (around line 492). Delete that comment block — it refers to a feature that no longer exists.

- [ ] **Step 5.7: Remove the autopilot flag and its prompt branching from `CompanionManager`.**

Open `TipTour/CompanionManager.swift`. Find the `isAutopilotEnabled` property (search for `isAutopilotEnabled`). Delete:
- The `@Published var isAutopilotEnabled: Bool` declaration and its UserDefaults read/persist logic
- Any `didSet` that calls `companionVoiceResponseSystemPrompt(autopilotEnabled:)`
- The toggle-handler TODO comment at line 471

If you find a method like `setAutopilotEnabled(_ value: Bool)` or similar, delete it.

- [ ] **Step 5.8: Replace the system prompt entirely.**

In the same file, find `private static func companionVoiceResponseSystemPrompt(autopilotEnabled: Bool) -> String` (around line 747). Replace the entire method — signature included — with:

```swift
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
  → respond conversationally; do NOT auto-fill credentials. you can point at the username field, but stop there and let them type their password themselves.
"""
}
```

- [ ] **Step 5.9: Update the call site in `voiceBackend`.**

In the same file, find the line `systemPrompt: Self.companionVoiceResponseSystemPrompt(autopilotEnabled: isAutopilotEnabled)` inside `var voiceBackend: GeminiLiveSession` (around line 100). Replace it with:

```swift
systemPrompt: Self.companionVoiceResponseSystemPrompt()
```

- [ ] **Step 5.10: Build in Xcode.**

⌘B. Expected: green build. Any reference-to-deleted-symbol error means an autopilot or workflow / spawn callback usage was missed — search the file for `isAutopilotEnabled`, `onSubmitWorkflowPlan`, `onSpawnBackgroundTask`, `autopilotEnabled` and remove each remaining reference.

- [ ] **Step 5.11: Smoke-run.**

⌘R. Press Ctrl+Option, say *"what's two plus two"*. Expected: Gemini answers directly, no tool call (console shows no `[Tool] 🔧 …`). Then say *"write a haiku about rain"*. Expected: console shows `[Tool] 🔧 ask_hermes(...)` and Gemini speaks the haiku.

- [ ] **Step 5.12: Commit.**

```bash
git add TipTour/GeminiLiveClient.swift \
        TipTour/GeminiLiveSession.swift \
        TipTour/CompanionManager.swift
git commit -m "feat(gemini): drop dead tools, reshape system prompt for ask_hermes"
```

---

## Task 6: Delete dead `TODO(plan-2)` code in CompanionManager

**Why:** Now that ask_hermes works and the autopilot / workflow paths are gone from the prompt, the inline comments and stub bodies that reference them are just noise.

**Files:**

- Modify: `TipTour/CompanionManager.swift`

- [ ] **Step 6.1: Delete the `pendingAgentCompletionNotices` infrastructure.**

In `TipTour/CompanionManager.swift`, find `private var pendingAgentCompletionNotices: [String]` (~line 82). Delete:
- The property itself + its `TODO(plan-2)` comment immediately above it
- Anywhere it's appended to or read from in the file (search `pendingAgentCompletionNotices`)
- The surrounding `if !pendingAgentCompletionNotices.isEmpty { ... }` block at the bottom of `startVoiceSession()` / agent-context injection (~line 1002 region)

- [ ] **Step 6.2: Delete the two stub callbacks in `wireCallbacks(on:)`.**

In the same file, find the two stub callbacks `backend.onSubmitWorkflowPlan = ...` and `backend.onSpawnBackgroundTask = ...` (~lines 118–127, including their `TODO(plan-2)` comments). Delete both — the underlying callbacks were removed from `GeminiLiveSession` in Task 5 and the compiler will already be warning about these dead assignments.

- [ ] **Step 6.3: Delete the workflow short-circuit comment.**

Find the `// TODO(plan-2): re-implement workflow short-circuit via HermesClient session state.` comment inside `handleToolPointAtElement` (~line 250). Delete the comment line — the surrounding logic stays.

- [ ] **Step 6.4: Delete dead comments at lines 471, 517, 978, 1002, 1033, 1057.**

Walk those line ranges in `CompanionManager.swift`. For each `TODO(plan-2)` comment block referencing background-agent / workflow / autopilot / "abandon plan" features:
- If the block is just a comment with no surrounding logic, delete the comment.
- If the block has dead-stub code under it (e.g. the line 1057 path that previously called a removed method), delete the entire block — both comment and stubs.

After this step, the only `TODO(plan-2)` markers left in `CompanionManager.swift` should be the two "future" markers at lines 53 and 627 (skill capture and demonstration shortcut). Verify with:

```bash
grep -n "TODO(plan-2)" TipTour/CompanionManager.swift
```

Expected: exactly two matches.

- [ ] **Step 6.5: Rephrase the two surviving markers.**

In `TipTour/CompanionManager.swift`:
- Line ~53: Replace `// TODO(plan-2): re-introduce demonstration recording via HermesClient if needed.` with `// future: skill capture / demonstration recording — not in Plan 3c scope`.
- Line ~627: Replace `// TODO(plan-2): re-wire demonstration shortcut once the` (and any continuation) with `// future: demonstration shortcut (Ctrl+Option+W) publisher exists with no consumer`.

Then verify zero plan-2 markers remain:

```bash
grep -n "TODO(plan-2)" TipTour/CompanionManager.swift
```

Expected: no matches.

- [ ] **Step 6.6: Build in Xcode.**

⌘B. Expected: green build. If you get "unused variable" warnings on something like `_ = (id, goal, app, steps)`, those should have been deleted with the stub callbacks in Step 6.2 — go back and check.

- [ ] **Step 6.7: Commit.**

```bash
git add TipTour/CompanionManager.swift
git commit -m "chore(plan-3c): delete TODO(plan-2) markers and dead callbacks"
```

---

## Task 7: Clean up dead UI in CompanionPanelView

**Why:** The panel still renders an autopilot toggle row, workflow checklist UI, skill-recording controls, save-skill sheet, and a Settings sheet button — all wired to deleted infrastructure.

**Files:**

- Modify: `TipTour/CompanionPanelView.swift`

- [ ] **Step 7.1: Identify the dead UI sections.**

In `TipTour/CompanionPanelView.swift`, locate the following landmarks via search:
- Line ~15: `// TODO(plan-2): re-introduce active-plan checklist driven by HermesClient.` — the active-plan struct / state
- Line ~28: `// TODO(plan-2): show workflow checklist when HermesClient` — the if-let wrapping the checklist row
- Line ~67: `// TODO(plan-2): re-introduce the Save Skill sheet once skill` — sheet presenter
- Line ~532: `// TODO(plan-2): re-introduce workflow checklist UI once HermesClient` — `autopilotToggleRow` and the checklist view body
- Line ~733: `// TODO(plan-2): re-introduce SKILL RECORDING controls once the` — the skill-recording row

Also find the Settings button in the panel footer (search for `SettingsView()` or `presentSettings`) — it presents `TipTour/Agents/UI/SettingsView.swift` which we delete in Task 8.

- [ ] **Step 7.2: Delete the autopilot toggle row.**

In the same file, find the `autopilotToggleRow` view (a SwiftUI view body or computed property), its associated `Toggle(isOn: ...)`, and any callers. Delete the row and any spacing/divider lines that surround it.

- [ ] **Step 7.3: Delete the workflow-checklist state and view.**

Find the state struct or `@State` variable that represents the active workflow plan (likely named `activePlan`, `currentWorkflow`, or similar — anchored at line ~15 by the `TODO(plan-2)` comment). Delete:
- The state property + its `TODO(plan-2)` comment
- The `if let plan = ... { ChecklistView(...) }` block (~line 28)
- Any helper views (`ChecklistView`, `WorkflowStepRow`, `WorkflowGoalHeader`, etc.) declared only for this panel (~line 532 region)

- [ ] **Step 7.4: Delete the save-skill sheet.**

Find the `.sheet(isPresented: ...) { SaveSkillSheet(...) }` modifier and the associated `@State var isSaveSkillSheetPresented` (or similar). Delete both.

- [ ] **Step 7.5: Delete the skill-recording controls.**

Find the skill-recording row (around line 733 — the `TODO(plan-2)` mentions "SKILL RECORDING controls"). Delete the row, any `Button("Record skill")` or "Stop recording" UI it contains, and any associated `@State` variables that only this row reads.

- [ ] **Step 7.6: Delete the Settings sheet button.**

Find the footer `Button` that opens `SettingsView()` (likely a small ⚙ icon or "Settings…" label). Delete the button, the `@State var isSettingsPresented`, and the `.sheet { SettingsView() }` modifier. If `import` lines for the `SettingsView` symbol exist at the top of the file, leave them — Task 8 will delete the file so the import becomes a hard error if not removed; remove the import here too.

- [ ] **Step 7.7: Remove now-unused @State variables.**

After Steps 7.2–7.6, search the file for any `@State` declaration that no longer has readers. Delete each.

- [ ] **Step 7.8: Build in Xcode.**

⌘B. Expected: green build. Compile errors are most likely "use of undeclared identifier" — that means a leftover reference to something deleted; find and remove it. There should be ZERO `TODO(plan-2)` markers in `CompanionPanelView.swift` after this step:

```bash
grep -n "TODO(plan-2)" TipTour/CompanionPanelView.swift
```

Expected: no matches.

- [ ] **Step 7.9: Smoke-run.**

⌘R. Open the panel from the menu bar icon. Expected: status header, permissions section (if any unresolved), neko-mode toggle, footer with no Settings button. No autopilot row, no checklist, no skill recording.

- [ ] **Step 7.10: Commit.**

```bash
git add TipTour/CompanionPanelView.swift
git commit -m "chore(plan-3c): strip dead UI from companion panel"
```

---

## Task 8: Delete ClickDetector + SettingsView + empty Agents/ directory

**Why:** `ClickDetector.swift` only existed to feed the deleted `WorkflowRunner`. `SettingsView.swift` reads from deleted agents/skills/learning stores. With both gone, `TipTour/Agents/` is empty and can be removed.

**Files:**

- Delete: `TipTour/ClickDetector.swift`
- Delete: `TipTour/Agents/UI/SettingsView.swift`
- Delete: `TipTour/Agents/UI/`
- Delete: `TipTour/Agents/`

- [ ] **Step 8.1: Verify no remaining callers of ClickDetector.**

```bash
grep -rn "ClickDetector" TipTour/ TipTourTests/ 2>/dev/null
```

Expected: only matches inside `TipTour/ClickDetector.swift` itself. If anything else matches, stop and remove those references first.

- [ ] **Step 8.2: Delete the file.**

```bash
rm "TipTour/ClickDetector.swift"
```

- [ ] **Step 8.3: Verify no remaining callers of SettingsView.**

```bash
grep -rn "SettingsView\|AgentsSettingsView\|SkillsSettingsView\|LearningSettingsView" TipTour/ TipTourTests/ 2>/dev/null
```

Expected: only matches inside `TipTour/Agents/UI/SettingsView.swift` itself. The Settings button was removed in Task 7 — if anything still references it, fix that before proceeding.

- [ ] **Step 8.4: Delete the file and the directory tree.**

```bash
rm "TipTour/Agents/UI/SettingsView.swift"
rmdir "TipTour/Agents/UI"
rmdir "TipTour/Agents"
```

If `rmdir` complains the directory is not empty, list contents (`ls TipTour/Agents/UI`) and investigate before forcing.

- [ ] **Step 8.5: Build in Xcode.**

⌘B. Expected: green build. Xcode's `PBXFileSystemSynchronizedRootGroup` auto-discovers files, so deleted files drop out without project-file edits.

- [ ] **Step 8.6: Commit.**

```bash
git add -A TipTour/ClickDetector.swift TipTour/Agents
git commit -m "chore(plan-3c): delete ClickDetector and the empty Agents/ tree"
```

(The `git add -A` form picks up the deletions correctly.)

---

## Task 9: Manual end-to-end verification

**Why:** Plans 2 / 3a / 3b all closed with the same manual smoke-test pass — Gemini Live + microphone access + bundled Python runtime is unmockable from XCTest, so the final contract is run-it-and-watch-it-work.

- [ ] **Step 9.1: Run the app fresh.**

In Xcode, ⌘R. Wait for the launch sound and the 🛠 Hermes menu-bar item.

- [ ] **Step 9.2: Basic path stays basic.**

Press Ctrl+Option, say *"what's two plus two"*. Expected: Gemini answers directly in its own voice. Console output should show NO `[Tool] 🔧 ask_hermes` call.

- [ ] **Step 9.3: Escalation works.**

Press Ctrl+Option again, say *"write me a haiku about coffee"*. Expected:
- Gemini speaks a short acknowledgement ("on it" / "let me write that")
- Console: `[Tool] 🔧 ask_hermes(task="write me a haiku about coffee")`
- Console: Hermes streams `session/update` chunks
- Console: `[Tool] ✅ ask_hermes returning text.count=NN`
- Gemini speaks the haiku

- [ ] **Step 9.4: Shared session — voice → text continuity.**

Press Ctrl+Option, say *"remember the number forty-two"*. Press Ctrl+Option again to close the session. Open the chat window with ⌥⇧H, type *"what number did I just give you?"*. Expected: Hermes replies with forty-two — proves the chat window and the voice path share one Hermes session.

- [ ] **Step 9.5: Chat-window close doesn't kill Hermes.**

Open the chat window with ⌥⇧H (it should still show the previous turns). Press Ctrl+Option and ask a fresh `ask_hermes`-worthy question. While Hermes is thinking, close the chat window. Expected: Gemini still speaks the answer when Hermes returns. Re-open the chat window — the new turn appears in the transcript.

- [ ] **Step 9.6: Interrupt during ask_hermes.**

Press Ctrl+Option, say *"explain the entire history of the Roman empire in detail"* (anything that produces a long Hermes reply). While Gemini is mid-speech, press Ctrl+Option again. Expected: audio cuts immediately, Hermes finishes its work silently in the background, and a fresh press starts a new utterance.

- [ ] **Step 9.7: MCP tools from Hermes still work.**

Press Ctrl+Option, say *"point at the File menu in Xcode"* (with Xcode in the foreground). Expected: Gemini handles directly with `point_at_element` — cursor flies. Console: `[Tool] 🔧 point_at_element(...)` only, no `ask_hermes`.

Then press Ctrl+Option, say *"read the names of all the buttons on screen"*. Expected: Gemini calls `ask_hermes`, Hermes calls the `get_a11y_tree` MCP tool, returns the list, Gemini speaks it. Console: `[Tool] 🔧 ask_hermes(...)` and Hermes's session/update chunks reference `get_a11y_tree` in a tool_call.

- [ ] **Step 9.8: Confirm no stragglers.**

```bash
grep -rn "TODO(plan-2)\|isAutopilotEnabled\|onSubmitWorkflowPlan\|onSpawnBackgroundTask\|submit_workflow_plan\|spawn_background_task" TipTour/ 2>/dev/null
```

Expected: no matches (the `TipTour/CompanionManager.swift:53` and `:627` "future:" markers are rephrased, not plan-2 markers).

- [ ] **Step 9.9: All-tests sanity check.**

In Xcode, ⌘U. Expected: all green except live tests gated by `try XCTSkipUnless` (those skip in environments without `~/.hermes/config.yaml`).

- [ ] **Step 9.10: Final commit (if any cleanup was applied during verification).**

```bash
git status
```

If anything was modified during the smoke tests (e.g. a comment fix), commit it as `chore(plan-3c): final cleanup`. Otherwise no commit needed.

---

## Self-review notes

- Type consistency: `HermesClient.ChatTurn` uses `.user(id, text)`, `.agent(id, text, toolCalls)`, `.system(id, text)` — Task 2 `_setTranscriptForTesting` and the `lastAgentReplyText` accessor both use this exact shape (verified against `TipTour/Hermes/HermesClient.swift:110-120`).
- Task ordering: Task 1 must run before Tasks 4 / 6 / 7 because those reference `companionManager.hermesClient` / `companionManager.mcpServer`. Task 3 can run before Task 1 in theory but the smoke test in Step 4.4 needs the shared client to actually work end-to-end.
- Task 5 removes `companionVoiceResponseSystemPrompt(autopilotEnabled:)` — the only call site is `voiceBackend` in `CompanionManager`. Confirmed via `grep companionVoiceResponseSystemPrompt TipTour/` — only one match.
- Task 8 uses `rmdir` rather than `rm -rf` so the safety check fails loudly if anything else gets dropped into `Agents/` between Task 7 and Task 8 — preferred to a recursive force-delete.
