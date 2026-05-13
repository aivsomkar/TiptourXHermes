# Plan 2 — ACP bridge + dev "Talk to Hermes" textbox — Design

**Date:** 2026-05-13
**Status:** Approved (brainstorming session)
**Builds on:**
- [`2026-05-13-plan-1-bundling-and-acp-smoke-test.md`](../plans/2026-05-13-plan-1-bundling-and-acp-smoke-test.md) — bundled Python + Hermes runtime inside `TipTour_Hermes.app/Contents/Resources/hermes-runtime/` (complete on `main`).
- [`2026-05-13-tiptour-hermes-rebrand-design.md`](2026-05-13-tiptour-hermes-rebrand-design.md) and its [implementation plan](../plans/2026-05-13-tiptour-hermes-rebrand.md) — the in-place rebrand that stripped TipTour's swarm/skills/workflow engine and left 15 `TODO(plan-2)` markers in `CompanionManager.swift` / `GeminiLiveSession.swift` / `CompanionPanelView.swift` (complete on `main`).

## Purpose

Plan 1 proved a Python subprocess speaking ACP over stdio can run inside the `.app`. Plan 2 puts a Swift client in front of it and a dev-only chat surface in front of that, end-to-end: type text → Hermes answers → you see the answer (and any tool calls Hermes made along the way).

The dev textbox is the proof. It is NOT the user-facing UX — that's Plan 3+'s job, when the existing overlay/voice loop gets re-wired to Hermes. Plan 2 ships a parallel, isolated surface so we can iterate on `HermesClient` without disturbing the rebranded codebase. The 15 `TODO(plan-2)` stubs left in the kept "body" files are NOT touched in Plan 2.

## Non-Goals

- Wiring the existing voice loop, overlay, push-to-talk, or `CompanionManager` to Hermes. Plan 3.
- A Mac-side MCP server exposing `take_screenshot` / `get_a11y_tree` / `point_at` / `speak` tools. Plan 3.
- Real approval UI for `session/request_permission`. Plan 4. (Plan 2 auto-allows.)
- Streaming text into the chat as it arrives. Wait for `PromptResponse` and render the full agent turn at once. (Streaming is a small follow-up if perceived latency becomes a problem.)
- Persisting chat history across window opens.
- Surfacing anything in `CompanionPanelView`. The chat lives in its own floating window.
- Replacing or extending `Tests/Python/smoke_test_acp.py`.

## Decisions captured during brainstorming

| Question | Answer |
|---|---|
| UI surface for the dev textbox? | A separate floating window, opened from a `Hermes Debug → Talk to Hermes…` menu-bar submenu (⌘⇧H). Decoupled from `CompanionPanelView` so it's easy to hide later. |
| Subprocess lifecycle? | Lazy. Subprocess starts on the first `send`, reuses one ACP session across messages, terminates when the chat window closes (or `deinit`). |
| What does the transcript show besides plain text? | User text bubbles, agent text bubbles, **collapsed tool-call rows** when Hermes calls a tool. Each tool-call row is one line; click to expand args + result. No streaming, no token-usage footer, no inline approval prompts. |
| Missing config (no `~/.hermes/config.yaml` or no provider key)? | Show the error verbatim from Hermes as a `.system` turn in the chat. No upfront detection logic. |
| `session/request_permission` handling? | Auto-allow every request, log `print("⚠️ auto-allowed: <name>")`. Plan 4 builds the real approval gate. |
| HermesClient API shape? | `@MainActor final class HermesClient: ObservableObject` with `@Published` transcript / isWorking / lastError. Combine-native for SwiftUI binding. |
| File layout? | New `TipTour/Hermes/` subdirectory containing `HermesClient.swift`, `HermesACPProtocol.swift`, `HermesChatWindow.swift`, `HermesDebugMenuController.swift`. |

## Section 1 — File layout

New files:

```
TipTour/Hermes/
├── HermesClient.swift              — ACP subprocess lifecycle, JSON-RPC framing, public Combine API
├── HermesACPProtocol.swift         — Codable types for the ACP frames we send + receive
├── HermesChatWindow.swift          — NSWindow + SwiftUI HermesChatView (transcript, input row)
└── HermesDebugMenuController.swift — Builds the menu-bar Debug submenu, owns the window
```

Modified files (small edits only):

- `TipTour/TipTourApp.swift` — instantiate `HermesDebugMenuController` in `applicationDidFinishLaunching` and inject its menu items.
- `TipTour/MenuBarPanelManager.swift` — add one public method `attachDebugItems(_:)` (≈5 lines) that appends extra `NSMenuItem`s to the status item's menu.

New test file:

- `TipTourTests/HermesClientTests.swift` — three test methods (init+send, missing-config, clean-stop).

No other files are touched. The 15 `TODO(plan-2)` markers in `CompanionManager.swift` / `GeminiLiveSession.swift` / `CompanionPanelView.swift` stay as-is.

## Section 2 — HermesClient API + state model

`HermesClient` is the only Plan 2 public Swift type that other plans will depend on. Its shape needs to survive Plan 3+'s integration with the voice loop.

```swift
@MainActor
final class HermesClient: ObservableObject {

    // MARK: Published state (consumed by HermesChatWindow + future overlay)
    @Published private(set) var transcript: [ChatTurn] = []
    @Published private(set) var isWorking: Bool = false
    @Published private(set) var lastError: String?

    // MARK: Public API
    init(hermesHome: URL? = nil)           // hermesHome: test-only override for HERMES_HOME env
    func send(_ userText: String) async
    func stop()                            // idempotent; called on chat-window close & deinit

    // MARK: Model
    enum ChatTurn: Identifiable {
        case user(id: UUID, text: String)
        case agent(id: UUID, text: String, toolCalls: [ToolCallRecord])
        case system(id: UUID, text: String)   // for "Hermes error: …" and ⚠️ notices

        var id: UUID { switch self { case .user(let i, _), .agent(let i, _, _), .system(let i, _): return i } }
    }

    struct ToolCallRecord: Identifiable {
        let id: String            // ACP toolCallId, stable across start/progress/end updates
        let name: String
        let argsPreview: String   // 1-line summary, e.g. `run_shell_command(echo hi)`
        let argsFull: String      // pretty-printed JSON, shown on expand
        let status: Status
        enum Status { case pending, completed, failed }
    }
}
```

### Behavior contract

| Method / Trigger | Behavior |
|---|---|
| First `send(text)` call | Append `.user(text:)` turn. If subprocess not yet running, launch it via `Process` (executable = `Bundle.main.resourceURL!.appendingPathComponent("hermes-runtime/hermes-runtime")`). Send `initialize` + await response. Send `session/new` + capture `sessionId`. If anything fails, append `.system(error)` to transcript and return. |
| Subsequent `send` calls | Append `.user(text:)`, send `session/prompt` with the existing `sessionId`. Set `isWorking = true`. When `PromptResponse` arrives, append the accumulated `.agent(text, toolCalls)` turn and set `isWorking = false`. |
| Inbound `session/update` with `agent_message_chunk` | Append text to the in-progress agent turn's buffer (held in an internal `currentAgentTurn` cell — not yet appended to `transcript`). |
| Inbound `session/update` with `tool_call` / `tool_call_update` (or whatever the discriminator turns out to be in agent-client-protocol 0.9.0) | Add or update a `ToolCallRecord` in the in-progress agent turn's `toolCalls` array. |
| Inbound `session/request_permission` | Auto-respond `{ "outcome": { "outcome": "selected", "optionId": "allow" } }` (or whatever 0.9.0's allow shape is — confirm during impl). Log `print("⚠️ auto-allowed: \(toolName)")`. Plan 4 replaces this. |
| Inbound notification with unknown method or unknown `update.sessionUpdate` discriminator | Decode into the `.unknown(raw:)` JSONValue variant, log at debug level, do not crash. |
| `stop()` | `process.terminate()`. Wait up to 2s. If still running: `process.interrupt()` (SIGINT). Wait 1s. If still running: `process.kill()` (SIGKILL). Clear all `@Published` state. Idempotent — calling again does nothing. |
| `deinit` | Calls `stop()` synchronously. |

### Internal mechanics (not part of the public API)

- A single background `Task` reads stdout line-by-line via `FileHandle.bytes` (or a `Pipe.fileHandleForReading.readabilityHandler` if `bytes` isn't suitable for unbounded streams). Splits on `\n`, decodes each line as a JSON-RPC frame.
- A `[String: CheckedContinuation<Decodable, Error>]` map keys pending request IDs to their continuations. Responses unblock the corresponding `send`/`initialize`/`session/new` call.
- A `var currentAgentTurn: (id: UUID, text: String, toolCalls: [ToolCallRecord])?` cell holds the agent turn being assembled. Cleared and pushed into `transcript` on `PromptResponse`.
- All state mutation happens on `@MainActor` — the reader Task hops back to `@MainActor` before touching anything.
- stderr is read into a small ring buffer (≤8 KB) used in error messages so when `session/new` errors out the diagnostic includes the Python-side trace.

## Section 3 — ACP protocol types

`HermesACPProtocol.swift` models only the slice of ACP we use. The full schema has dozens of variants; we lean on a `JSONValue` recursive enum to stay forward-compatible.

### Requests we send

```swift
struct InitializeRequest: Codable {
    let protocolVersion: Int               // = 1
    let clientCapabilities: ClientCapabilities
}
struct ClientCapabilities: Codable {
    let fs: FSCapabilities
    let terminal: Bool
}
struct FSCapabilities: Codable {
    let readTextFile: Bool
    let writeTextFile: Bool
}
// We don't grant fs/terminal capabilities in Plan 2; pass `false`.

struct NewSessionRequest: Codable {
    let cwd: String                        // absolute path; pass the project's source root
    let mcpServers: [JSONValue]            // empty array for Plan 2
}

struct PromptRequest: Codable {
    let sessionId: String
    let prompt: [TextBlock]
}
struct TextBlock: Codable {
    let type = "text"
    let text: String
}

struct PermissionResponse: Codable {       // response to session/request_permission
    let outcome: PermissionOutcome
}
struct PermissionOutcome: Codable {
    let outcome: String                    // "selected"
    let optionId: String                   // "allow"
}
```

### Responses we decode

```swift
struct InitializeResult: Codable {
    let protocolVersion: Int
    let agentCapabilities: JSONValue
    let agentInfo: AgentInfo?
    let authMethods: [JSONValue]?
}
struct AgentInfo: Codable {
    let name: String
    let version: String
}

struct NewSessionResult: Codable {
    let sessionId: String
    let models: JSONValue?                 // ignored in Plan 2 — Plan 3 may use this for model-switching
}

struct PromptResult: Codable {
    let stopReason: String                 // "end_turn", "max_tokens", "refusal", "cancelled", …
    let usage: UsageInfo?
}
struct UsageInfo: Codable {
    let inputTokens: Int
    let outputTokens: Int
    let totalTokens: Int
    let cachedReadTokens: Int?
    let thoughtTokens: Int?
}
```

### Notifications we observe (Hermes → us)

```swift
struct SessionUpdateNotification: Decodable {
    let sessionId: String
    let update: SessionUpdate
}

enum SessionUpdate: Decodable {
    case agentMessageChunk(text: String)
    case userMessageChunk(text: String)
    case toolCallStart(id: String, name: String, args: JSONValue, location: JSONValue?)
    case toolCallProgress(id: String, status: String, output: JSONValue?)
    case toolCallEnd(id: String, status: String)
    case availableCommandsUpdate(commands: [JSONValue])
    case usageUpdate(size: Int?, used: Int)
    case unknown(raw: JSONValue)            // forward-compat: do not crash on unfamiliar sessionUpdate values

    // Custom decode: discriminator is `update.sessionUpdate` (snake_case string).
    // Exact discriminator values to confirm during implementation; the Plan 1
    // smoke test observed: "available_commands_update", "agent_message_chunk",
    // "usage_update". Tool-call discriminators will be confirmed when a
    // tool-using prompt is sent live.
}
```

### Outer JSON-RPC frame helpers

```swift
struct JSONRPCRequest<P: Encodable>: Encodable {
    let jsonrpc = "2.0"
    let id: String
    let method: String
    let params: P
}
struct JSONRPCNotification<P: Encodable>: Encodable {
    let jsonrpc = "2.0"
    let method: String
    let params: P
}
struct JSONRPCResponse<R: Decodable>: Decodable {
    let jsonrpc: String
    let id: String?
    let result: R?
    let error: JSONRPCError?
}
struct JSONRPCError: Decodable, Error {
    let code: Int
    let message: String
    let data: JSONValue?
}
```

### JSONValue

Standard recursive enum trick:

```swift
indirect enum JSONValue: Codable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    // init(from:) and encode(to:) implemented by trial-decoding each variant.
}
```

### Wire framing

Newline-delimited JSON over stdio. Confirmed in Plan 1's investigation: `acp/stdio.py` reads stdin with `readline()` and writes raw bytes to stdout. We follow the same convention:

- **Write**: `try encoder.encode(frame) + Data("\n".utf8)` → `stdin.write(_:)`.
- **Read**: split incoming bytes on `\n`; for each complete line, try decoding as `JSONRPCResponse` (if it has `result`/`error`) or as `JSONRPCNotification` (if it has `method`). Discard empty lines.

## Section 4 — Chat UI

### `HermesDebugMenuController`

Builds a small set of menu items that get attached to the existing status item via a new `MenuBarPanelManager.attachDebugItems(_:)` method:

```swift
@MainActor
final class HermesDebugMenuController {
    private var window: NSWindow?
    private let client = HermesClient()

    func buildMenuItems() -> [NSMenuItem] {
        let header = NSMenuItem(title: "Hermes Debug", action: nil, keyEquivalent: "")
        header.isEnabled = false
        let talk = NSMenuItem(title: "Talk to Hermes…", action: #selector(openChat), keyEquivalent: "h")
        talk.keyEquivalentModifierMask = [.command, .shift]
        talk.target = self
        return [NSMenuItem.separator(), header, talk]
    }

    @objc private func openChat() {
        if window == nil { window = makeChatWindow(client: client) }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
```

Hooked into `TipTourApp.applicationDidFinishLaunching`:

```swift
menuBarPanelManager = MenuBarPanelManager(companionManager: companionManager)
hermesDebugMenu = HermesDebugMenuController()
menuBarPanelManager?.attachDebugItems(hermesDebugMenu!.buildMenuItems())
```

### `HermesChatWindow` + `HermesChatView`

`HermesChatWindow` is an `NSWindow` subclass with:

- Title: `Hermes Debug`
- Style: titled + closable + miniaturizable + resizable
- Level: `.floating` (stays above other apps)
- Content: a `NSHostingView` hosting `HermesChatView(client:)`
- On `windowWillClose`: call `client.stop()` and nil out the controller's `window` reference so a re-open builds a fresh transcript.

`HermesChatView`:

```swift
struct HermesChatView: View {
    @ObservedObject var client: HermesClient
    @State private var draft: String = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(client.transcript) { turn in
                            ChatTurnRow(turn: turn).id(turn.id)
                        }
                    }
                    .padding(12)
                }
                .onChange(of: client.transcript.count) { _, _ in
                    if let last = client.transcript.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
            Divider()
            HStack(spacing: 8) {
                TextField("Message Hermes…", text: $draft, axis: .vertical)
                    .lineLimit(1...6)
                    .focused($inputFocused)
                    .onSubmit(send)
                Button("Send", action: send)
                    .disabled(draft.isEmpty || client.isWorking)
            }
            .padding(12)
        }
        .frame(minWidth: 480, minHeight: 360)
        .onAppear { inputFocused = true }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !client.isWorking else { return }
        draft = ""
        Task { await client.send(text) }
    }
}
```

### `ChatTurnRow`

Switches on the `ChatTurn` enum:

- `.user(_, text)` — right-aligned filled-bubble with `text`, accent-tinted.
- `.agent(_, text, toolCalls)` — left-aligned text bubble, dim-tinted. Below it, a vertical stack of `ToolCallRow`s, one per `ToolCallRecord`.
- `.system(_, text)` — center-aligned, italic, dim-red if `text` starts with `"Hermes error:"`, dim-gray otherwise.

`ToolCallRow`:

- Single line: `▸ <name>(<argsPreview>) → <status>` where `status` renders as `ok` / `…` / `failed` per `ToolCallRecord.Status`.
- A SwiftUI `DisclosureGroup` expands to a 2-column args/result preview: `<argsFull>` on the left, raw output on the right (or "(no output)" if the tool didn't return one).

No animations beyond `withAnimation { scrollTo(...) }`. No avatars. No timestamps.

## Section 5 — Tests + acceptance criteria

### `HermesClientTests.swift`

Three test methods, all `async throws`:

```swift
final class HermesClientTests: XCTestCase {

    /// Real ACP round-trip through the bundled runtime. Requires Hermes
    /// to be configured locally (~/.hermes/config.yaml + provider key).
    /// Skipped when not configured.
    func testClientInitializesAndCreatesSession() async throws { … }

    /// Forces a missing-config scenario by pointing HERMES_HOME at an
    /// empty temp dir. Expects the first send to produce a .system
    /// turn surfacing Hermes' error.
    func testClientSurfacesMissingConfigGracefully() async throws { … }

    /// Verifies stop() is idempotent and that the subprocess is gone
    /// afterwards.
    func testClientStopsCleanlyOnClose() async throws { … }
}
```

A small helper `waitFor<T>(_ publisher: Published<T>.Publisher, predicate:)` polls the publisher every 50 ms with a 60 s timeout, returning when `predicate(value)` is true.

A `hermesConfiguredLocally()` helper checks `~/.hermes/config.yaml` plus any of `GEMINI_API_KEY` / `OPENAI_API_KEY` / `ANTHROPIC_API_KEY` (same gate as `Tests/Python/smoke_test_acp.py`).

`HermesBundleTests.swift` (from Plan 1) is NOT modified — it tests at a different level (raw subprocess + initialize) and stays as the canary for the bundled runtime itself.

### Acceptance criteria

You're done with Plan 2 when ALL of these are true:

1. `xcodebuild build` succeeds with `** BUILD SUCCEEDED **`.
2. `xcodebuild test -only-testing:tiptour-macosTests/HermesBundleTests` AND `-only-testing:tiptour-macosTests/HermesClientTests` both report `** TEST SUCCEEDED **` (modulo the configured-locally skip on the first `HermesClientTests` method when no key is in env).
3. Launching `TipTour_Hermes.app` and choosing **Hermes Debug → Talk to Hermes…** (or ⌘⇧H) opens a floating chat window with the message-input row focused.
4. Typing `"Reply with the single word 'pong'."` and pressing Enter shows a user bubble immediately, an agent bubble with `pong` within ≈3s on Claude Haiku 4.5.
5. Asking Hermes to do something tool-using (e.g. `"List the files in /tmp."`) shows at least one collapsed tool-call row in the agent turn. Clicking it expands the args + result.
6. Closing the chat window terminates the bundled Python subprocess. Verify with `ps aux | grep hermes-runtime` showing zero matches.
7. With Hermes not configured (`HERMES_HOME=/tmp/empty` and all provider env vars unset), the chat window still opens, the first send produces a red `.system` turn with the verbatim error from Hermes, and the window remains usable for subsequent retries.
8. `Tests/Python/smoke_test_acp.py` continues to pass (Plan 1's canary).

## Section 6 — Risks and mitigations

| Risk | Mitigation |
|---|---|
| `agent-client-protocol` 0.9.0's tool-call `sessionUpdate` discriminator strings aren't what we guess (`tool_call_start`, `tool_call_progress`, `tool_call_end`). Tool-call rows wouldn't appear in the UI. | The `unknown(raw:)` fallback prevents a crash. During implementation, send a tool-using prompt once, log the raw `sessionUpdate` field values, and pin the discriminators based on what came back. Update the spec inline if reality differs. |
| Subprocess cleanup leaves orphans (pip/uv helpers, idle Python child workers). | `stop()` sends SIGTERM, waits 2 s, escalates to SIGINT, waits 1 s, escalates to SIGKILL. Test 3 (`testClientStopsCleanlyOnClose`) verifies the post-stop `ps` check. |
| Auto-allowing every `session/request_permission` would auto-run a destructive tool if Hermes asked to. | Plan 2 is dev-only; the chat is used exclusively by the developer testing benign prompts. Every auto-allow prints `⚠️ auto-allowed: <name>` to stderr/Console for visibility. Plan 4 replaces this with real approval gating. |
| No streaming means a multi-paragraph agent reply feels slow. | Accepted tradeoff per the brainstorming session. If it becomes annoying, the upgrade path is small: append to `currentAgentTurn.text` on each `agentMessageChunk`, publish the in-progress turn into `transcript` continuously instead of waiting for `PromptResponse`. |
| `@testable import TipTour` is needed for `HermesClientTests` to reach `HermesClient`. Test target already does `@testable import TipTour` (verified during the rebrand's PRODUCT_MODULE_NAME pin) — but `HermesClient.init(hermesHome:)`'s test-only parameter feels like an API smell. | The `hermesHome:` parameter is non-internal (default `nil`); production code never passes it. The alternative — a separate fileprivate test helper — is worse because tests can't reach `fileprivate`. Documented as a test affordance, scope-limited. |

## Section 7 — What comes after Plan 2

The natural sequence is unchanged from Plan 1's spec:

**Plan 3 — Mac-side MCP server + voice-loop integration.** Adds an in-process MCP server (`take_screenshot`, `get_a11y_tree`, `point_at(rect, label)`, `speak(text)`) and registers it in the `mcpServers` array of every `session/new` request. With those tools available, Plan 3 replaces the 15 `TODO(plan-2)` markers in `CompanionManager.swift` / `GeminiLiveSession.swift` / `CompanionPanelView.swift`: Gemini Live STT transcripts become `HermesClient.send` calls; Hermes's `speak` tool drives macOS `AVSpeechSynthesizer`; Hermes's `point_at` tool drives the Arc Reactor cursor overlay.

**Plan 4 — Guardrails Layer A + approvals.** Replaces Plan 2's auto-allow with real per-action approval prompts.

Plans 5–9 from the original Plan-1 doc remain as scoped there.
