# Plan 3c — Voice Loop Integration (Gemini Live + Hermes via `ask_hermes`)

**Date:** 2026-05-14
**Status:** Design

## Goal

Connect the existing push-to-talk Gemini Live voice loop to the Hermes ACP brain so that complex / agentic requests are delegated to Hermes while Gemini Live remains the front-line voice agent for basic on-screen asks. The two modes coexist in one WebSocket connection driven by a new `ask_hermes(task)` tool. Voice and the Talk-to-Hermes chat window share one Hermes session.

## Big picture

```
mic ─┬───audio (PCM16)───▶ Gemini Live ─┬─inputAudioTranscription──▶ Swift
     │                                  └──[Hermes's reply text]────▶ Gemini speaks
     │                                                      ▲
     │                                                      │ clientContent text turns
     │                                                      │
     ▼                                                      │
push-to-talk ──hotkey──▶ CompanionManager ──.send(text)──▶ HermesClient ──ACP──▶ Hermes (Python)
                              ▲                                │            tools via MCP
                              │                                │            ▲
                              └── overlay + chat window ◀──agent_message_chunk
                                                                            │
                                                              speak / point_at / screenshot
                                                              get_a11y_tree (MCP, in-process)
```

| Concern | Today | After 3c |
|---|---|---|
| LLM reasoning (basic) | Gemini Live | Gemini Live (unchanged) |
| LLM reasoning (deeper) | Gemini Live | Hermes (Claude via ACP) |
| User STT | Gemini Live | Gemini Live (unchanged) |
| Reply TTS | Gemini Live | Gemini Live (unchanged — speaks its own answers AND Hermes's returned text) |
| Tool calling | `point_at_element` + 2 broken stubs (`submit_workflow_plan`, `spawn_background_task`) | `point_at_element` + new `ask_hermes`; stubs deleted |
| Chat window | Text-only, separate brain | Same brain — voice + text share one Hermes session |

One Hermes subprocess, one session, one ACP loop drives both the voice path and the Talk-to-Hermes window.

## Section 1 — Gemini Live: mostly preserved, one new tool added

Gemini Live keeps everything it does today — same WebSocket setup, same audio out, same streaming screenshots, same TipTour-personality system prompt. Three changes inside `GeminiLiveClient` / `GeminiLiveSession`:

### 1.1 New tool: `ask_hermes(task)`

Declared alongside `point_at_element` in the WebSocket setup. Tool description tells Gemini when to use it:

```
ask_hermes(task: string)
  Delegate to Hermes — a deeper-reasoning sub-agent with shell, file, web,
  and screen tools. Use for:
    - coding questions, code review, refactoring
    - multi-step research that needs the web
    - tasks that need running commands or reading files
    - anything that benefits from longer, more careful thought
  Don't use for:
    - "where is X" on screen (use point_at_element)
    - quick chit-chat or knowledge you can answer in one breath
  Hermes returns its final answer as text. You then speak that answer to
  the user — paraphrase it for voice if needed (shorter, conversational).

  Before calling: speak ONE short acknowledgement ("on it, let me check"),
  THEN call the tool, THEN speak the result. Don't go silent while Hermes
  is working.
```

A new callback on `GeminiLiveSession`:

```swift
var onAskHermes: ((_ id: String, _ task: String) async -> [String: Any])?
```

`handleToolCall` routes the `ask_hermes` discriminator to this callback the same shape it uses for `point_at_element`. The return dict — shape `{ok: Bool, text: String}` — becomes the `toolResponse` Gemini sees.

The tool declaration is exposed as a static computed property `askHermesToolDeclaration` — the same pattern `pointAtElementToolDeclaration` already uses — so unit tests can verify its shape.

### 1.2 Two dead tools removed

`submit_workflow_plan` and `spawn_background_task` are removed from the WebSocket setup AND from the system prompt entirely. Both have stubbed callbacks (`return ["ok": false]`) and their consumers (WorkflowRunner, TaskAgent) were deleted in the rebrand — they only confuse Gemini today. Bringing back the auto-advancing-cursor walkthrough is its own future plan.

### 1.3 System-prompt surgery

The ~1000-line companion prompt has whole sections dedicated to the dropped tools:
- "TOOL: submit_workflow_plan" and the entire step-types / autopilot-routing block
- "TOOL: spawn_background_task" and its task_type taxonomy
- The autopilot ON/OFF imperative-route branching at the top

Those sections come out. A new shorter section is added describing `ask_hermes` (the text in §1.1 above). The TipTour personality, LANGUAGE RULE, set-of-marks rule, NO-TOOL-CALLS-BEFORE-USER-SPEECH rule, GREETING-ONLY rule, and point_at rules all stay.

Net effect: Gemini's tool surface goes from 3 (one working, two broken stubs) to 2 (`point_at_element`, `ask_hermes`), both working. Streaming screenshots, mic capture, server VAD, audio out, all unchanged.

## Section 2 — The Hermes side: ownership, lifecycle, and what `ask_hermes` does

### 2.1 Ownership reshuffle

Today `HermesClient` and `MCPServer` are both owned by `HermesDebugMenuController` (which also owns the chat window and the menu bar item). After 3c they need to be alive whenever Gemini might want to `ask_hermes`, which is always — so ownership moves up to `CompanionManager` (the app-wide singleton). `HermesDebugMenuController` is restructured to receive a `HermesClient` reference rather than create one.

```swift
// CompanionManager (new properties)
let hermesClient = HermesClient()
let mcpServer = MCPServer(name: "tiptour-tools")

// In init / install:
let resolver = AccessibilityTreeResolver()
mcpServer.register(SpeakTool())
mcpServer.register(ScreenshotTool())
mcpServer.register(A11yTreeTool(resolver: resolver))
mcpServer.register(PointAtTool(resolver: resolver, companionManager: self))

// HermesDebugMenuController.install(...) now takes the shared client:
hermesDebugMenu.install(client: hermesClient, mcpServer: mcpServer, companionManager: self)
```

The previous teardown in `HermesDebugMenuController.windowWillClose` (which terminated the subprocess) goes away — closing the chat window must NOT kill Hermes anymore. The subprocess lives for the app's lifetime; cleanup happens on app quit via `CompanionManager`'s deinit-equivalent path.

### 2.2 Lifecycle

Same lazy-launch pattern, just driven by a different first caller:
- First `ask_hermes` from Gemini OR first send from the chat window → `HermesClient.send` triggers `launchSubprocessIfNeeded` → `initialize` → `session/new` (with the MCP server URL) → ready.
- Subsequent calls reuse the running subprocess and the same session, so context flows across voice and text turns.
- MCP server starts the moment the subprocess does (it needs a URL to register with `session/new`).

### 2.3 The `ask_hermes` handler

A new private method on `CompanionManager`:

```swift
@MainActor
private func handleToolAskHermes(id: String, task: String) async -> [String: Any] {
    voiceState = .processing                   // play jarvisworking cue
    await hermesClient.send(task)
    voiceState = .responding
    let replyText = hermesClient.lastAgentReplyText ?? ""
    return ["ok": true, "text": replyText]
}
```

It awaits `hermesClient.send(task)`, then pulls the final agent reply text out of the transcript. `HermesClient` needs one small addition — a convenience accessor:

```swift
var lastAgentReplyText: String? {
    for turn in transcript.reversed() {
        if case .agent(_, let text, _) = turn { return text }
    }
    return nil
}
```

It reads the most recent `.agent` ChatTurn's text (everything streamed via `agent_message_chunk` during the last prompt). The chat window already shows the streaming transcript live; this is just exposing what's already there.

### 2.4 MCP tools during the `ask_hermes` window

Plan 3b already wired the four MCP tools to side-effect the existing UI surface. They keep working unchanged:

- `speak(text)` plays via AVSpeechSynthesizer
- `take_screenshot()` returns a JPEG of the main display
- `get_a11y_tree()` returns the marks for the user's target app
- `point_at(label)` writes to `CompanionManager.detectedElementScreenLocation` / `detectedElementBubbleText` / `detectedElementDisplayFrame`, which the overlay already watches

All of those side effects happen *while* Gemini is silently waiting on the `ask_hermes` toolResponse. By the time Hermes returns, the cursor may already be pointing somewhere and a screenshot may have been spoken about — and then Gemini delivers its final spoken summary.

### 2.5 Interrupt during `ask_hermes`

If the user presses Ctrl+Option mid-call (while Hermes is thinking or while Gemini is reading Hermes's reply), the existing toggle-the-session path kicks in: `stopVoiceSession()` closes the Gemini WebSocket. Hermes keeps running in the background and finishes its prompt; the final reply is recorded in the chat transcript but never spoken. ACP 0.9.0 has no `cancel` verb, so this is the cleanest we can do without protocol changes — and it matches the "Gemini gets dropped, Hermes finishes silently" model the user is already used to with background work.

## Section 3 — Cleanup of the 15 `TODO(plan-2)` markers

Most markers point to features that were already deleted in the rebrand (TaskAgent swarm, WorkflowRunner, skill recording, model routing). They survive only as inline comments + stub callbacks + vestigial UI rows. Plan 3c is the natural moment to delete the dead code.

### 3.1 Delete outright

| File / lines | What | Why |
|---|---|---|
| `CompanionManager.swift:81` | `pendingAgentCompletionNotices` array + its injection logic | TaskAgent infrastructure is gone forever |
| `CompanionManager.swift:118-127` | `onSubmitWorkflowPlan` + `onSpawnBackgroundTask` stub callbacks | Both tools dropped in §1.2 |
| `CompanionManager.swift:250` | Workflow short-circuit check inside `handleToolPointAtElement` | No workflows |
| `CompanionManager.swift:471` | Autopilot toggle handler + `isAutopilotEnabled` flag + UserDefaults entry | No ActionExecutor wiring; the toggle today only mutates Gemini's prompt and doesn't actually enable autopilot |
| `CompanionManager.swift:517` | Stale comment block about background-agent spawn | Dead |
| `CompanionManager.swift:978, 1002, 1033, 1057` | Workflow / agent injection paths | Dead |
| `GeminiLiveSession.swift:87` | `onSubmitWorkflowPlan` doc comment + callback declaration | Tool removed |
| `GeminiLiveSession.swift:492` | "skip screenshot push while a plan is in flight" guard | No plans |
| `ClickDetector.swift` (entire file) | Global click-tap that auto-advanced WorkflowRunner steps | Only WorkflowRunner used it |
| `CompanionPanelView.swift:15, 28, 67, 532, 733` | Active-plan checklist UI + Save-Skill sheet + autopilot toggle row + skill-recording controls | All consumers deleted |
| `TipTour/Agents/UI/SettingsView.swift` (whole file) + the Settings button in panel footer | Agents/Skills/Learning tabs | They all read from deleted stores; the file is the last survivor in `TipTour/Agents/`, so the directory goes too |

### 3.2 Rephrase, don't delete

These comments point to genuinely-future work, not Plan 2 debt:

| File / lines | New phrasing |
|---|---|
| `CompanionManager.swift:53` | `// future: skill capture / demonstration recording` |
| `CompanionManager.swift:627` | `// future: demonstration shortcut (Ctrl+Option+W) — publisher exists, no consumer yet` |

### 3.3 What stays

- Arc Reactor cursor, response-text bubble in `CompanionResponseOverlay`, cursor flight in `OverlayWindow` — all still driven by `detectedElementScreenLocation` / `detectedElementBubbleText`, which both the `point_at_element` callback (Gemini path) and the `PointAtTool` MCP tool (Hermes path) write to.
- The ironman-repulsors / jarvislistening / jarvisworking sound effects, gated by `voiceState`.
- The push-to-talk hotkey + `bindShortcutTransitions` logic.
- The streaming screenshot loop into Gemini.
- The whole Permissions section in the panel.
- The "Talk to Hermes…" menu item + chat window (now opened by `HermesDebugMenuController`, but the client it talks to is the shared one from `CompanionManager`).

After this pass, `CompanionManager.swift` drops from ~1100 lines to roughly ~750. `CompanionPanelView.swift` drops similarly. No tests reference the deleted code (the rebrand already cleared those out).

## Section 4 — Testing & verification

### 4.1 Unit tests (XCTest, in `TipTourTests/`)

| Test | What it asserts |
|---|---|
| `GeminiLiveClient.askHermesToolDeclarationIsRegistered` | `Self.askHermesToolDeclaration` exists, has name `"ask_hermes"`, has a `task: string` parameter, and appears in the `setupMessage.tools` array (alongside `point_at_element`, with no `submit_workflow_plan` / `spawn_background_task`) |
| `GeminiLiveSession.simulateAskHermesCallRoutesToCallback` | Set `onAskHermes` to a fake that returns `["ok": true, "text": "hi"]`, then `simulateToolCall(id: "x", name: "ask_hermes", args: ["task": "test"])`. Assert the callback ran with the right args |
| `HermesClient.lastAgentReplyTextReturnsMostRecentAgentTurn` | Mutate the transcript to contain `[.user, .agent(text: "A"), .user, .agent(text: "B")]`. Assert `lastAgentReplyText == "B"` |
| `HermesClient.lastAgentReplyTextReturnsNilWhenNoAgentTurns` | Empty / user-only transcript → returns `nil` |

These are all small, fast, no subprocess needed.

### 4.2 Manual end-to-end checks

The irreplaceable ones — same approach as Plans 2 / 3a / 3b:

1. **Basic path stays basic.** Press Ctrl+Option, say *"what's two plus two"*. Gemini should answer directly in its own voice. No `ask_hermes` call. Console: no `[Tool] 🔧 ask_hermes`.
2. **Escalation works.** Press Ctrl+Option, say *"write me a haiku about coffee"*. Gemini should speak a one-second acknowledgement ("on it"), then `ask_hermes` fires, Hermes returns text, Gemini speaks the haiku. Console: `[Tool] 🔧 ask_hermes(task="…")` then Hermes's `session/update` chunks streaming.
3. **Shared session.** Voice ask: *"remember the number forty-two"*. Then open ⌥⇧H chat window, type *"what number did I just give you"*. Hermes should say forty-two — proves the chat window and the voice path share one Hermes session.
4. **Chat window close doesn't kill Hermes.** Send something via voice that triggers `ask_hermes`. While Hermes is thinking, close the chat window. Hermes's reply should still come back and Gemini should still speak it.
5. **Interrupt during `ask_hermes`.** Trigger a long `ask_hermes` call. Mid-reply, press Ctrl+Option. Gemini's audio cuts (existing toggle behavior), Hermes finishes silently in the background, the next press starts fresh.
6. **MCP tools from Hermes still work.** Voice ask: *"point at the File menu in Xcode"* — Gemini should handle this with `point_at_element` directly (basic path). Voice ask: *"read the names of all the buttons on screen"* — Gemini should `ask_hermes`, Hermes calls `get_a11y_tree` MCP tool, returns the names, Gemini speaks.

No automated end-to-end test for the voice loop — same as Plans 2/3a/3b, Gemini Live + microphone access + bundled Python runtime is unmockable from XCTest. The smoke tests above are the contract.

## Out of scope

- Bringing back `submit_workflow_plan` / auto-advancing cursor walkthroughs — its own future plan.
- Bringing back autopilot click-execution via `ActionExecutor` — its own future plan.
- Skill capture / demonstration recording (the Ctrl+Option+W shortcut publisher exists with no consumer).
- Cancel verb in ACP — out of scope until Hermes's ACP version supports it.
- Per-mode Hermes system prompts — one shared system prompt (from `~/.hermes/config.yaml`) covers both voice and chat. The voice-vs-text adaptation is left to Hermes's own judgment based on phrasing.
- Approval UI for Hermes's MCP tool calls — auto-allow stays for Plan 3c; Plan 4 introduces real approval.
