# Plan 3a — MCP Framework + `speak` Tool — Design

**Date:** 2026-05-13
**Status:** Approved (brainstorming session)
**Builds on:**
- [`2026-05-13-plan-1-bundling-and-acp-smoke-test.md`](../plans/2026-05-13-plan-1-bundling-and-acp-smoke-test.md) — bundled Hermes runtime (complete).
- [`2026-05-13-tiptour-hermes-rebrand-design.md`](2026-05-13-tiptour-hermes-rebrand-design.md) — TipTour → TipTour_Hermes rebrand (complete).
- [`2026-05-13-plan-2-acp-bridge-and-dev-textbox-design.md`](2026-05-13-plan-2-acp-bridge-and-dev-textbox-design.md) — Swift `HermesClient` + dev chat window (complete).

## Decomposition of Plan 3

Plan 3 as originally scoped (Mac-side MCP server + voice-loop rewire + Arc Reactor overlay integration) is too large for a single spec. It is split into three sub-plans, each producing standalone, testable software:

| | Sub-plan | What ships |
|---|---|---|
| **3a** | **MCP framework + `speak` tool** (this spec) | Swift in-process MCP server, one tool (`speak`), registered with Hermes. End state: type "say hello via the speak tool" in the Plan-2 dev chat → audible Mac speech. |
| 3b | Remaining Mac tools | `take_screenshot`, `get_a11y_tree`, `point_at` registered on the framework 3a built. End state: "what's on screen?" → screenshot + a11y tree summary. "Point at the Save button" → Arc Reactor cursor flies. |
| 3c | Voice-loop integration | Push-to-talk → Gemini Live STT → `HermesClient.send` → reply → `AVSpeechSynthesizer` TTS. Replaces the 15 `TODO(plan-2)` markers in `CompanionManager` / `GeminiLiveSession` / `CompanionPanelView`. |

3b and 3c each get their own spec when we start them. This spec covers 3a only.

## Purpose

Plan 2 proved Hermes can chat through the bundled runtime. To make Hermes useful as the "brain" driving the existing TipTour body (Arc Reactor cursor, voice, screen capture, a11y tree), Hermes needs callable tools that reach back into the macOS app. The standard ACP-native path for that is an MCP server registered via `session/new`'s `mcpServers` parameter.

Plan 3a builds the MCP server framework end-to-end with the simplest possible tool — `speak(text)` — so that every layer of the Hermes → MCP → Mac plumbing is exercised and provable. Plan 3b then adds tools on top without rebuilding scaffolding.

## Non-Goals

- `take_screenshot`, `get_a11y_tree`, `point_at` — Plan 3b.
- Voice-loop rewire (push-to-talk → Hermes; replies → TTS) — Plan 3c.
- SSE streaming, HTTP keep-alive, chunked transfer.
- MCP `resources/*`, `prompts/*`, `logging/*` capabilities.
- Authentication on the MCP HTTP endpoint (loopback-only binding is the security boundary).
- Blocking `speak` semantics (fire-and-forget only; deferred to a `speak_and_wait` tool if ever needed).
- Voice/language selection for `AVSpeechSynthesizer` (system default).

## Decisions captured during brainstorming

| Question | Answer |
|---|---|
| Split Plan 3 or ship as one? | Split into 3a / 3b / 3c. Each produces working, testable software. |
| Transport for the MCP server? | In-process HTTP via `Network.framework`'s `NWListener`, bound to `127.0.0.1` on a random port. The chosen path because (a) Plan 3b's `point_at` needs the same process as the app's overlay window — stdio (subprocess) can't reach it; (b) zero dependencies vs. embedding Hummingbird/Vapor. |
| `speak(text)` blocking or fire-and-forget? | Fire-and-forget. `AVSpeechSynthesizer.speak()` is called, the tool returns immediately. A future `speak_and_wait` tool can be added if Hermes ever needs to sequence speech-then-action. |

## Section 1 — File layout

**New files:**

```
TipTour/Hermes/
├── MCPServer.swift    — NWListener-backed HTTP/1.1 server, JSON-RPC routing, MCP handshake
├── MCPTools.swift     — MCPTool protocol + SpeakTool implementation
```

**Modified files:**

- `TipTour/Hermes/HermesACPProtocol.swift` — add `HttpMcpServerEntry` + `HttpHeader` Encodable types; change `NewSessionRequest.mcpServers` from `[JSONValue]` to `[HttpMcpServerEntry]`.
- `TipTour/Hermes/HermesClient.swift` — add `var mcpServerURL: URL?`; `openSession()` builds a one-entry `mcpServers` array when the URL is set.
- `TipTour/Hermes/HermesDebugMenuController.swift` — own a `MCPServer` instance; register `SpeakTool` in `install()`; start the server in `openChat()` and stop it in `windowWillClose()`.

**New tests:**

- `TipTourTests/MCPServerTests.swift` — 4 cases (start/stop, initialize, tools/list, tools/call).

**Deliberately NOT modified:**

- `Tests/Python/smoke_test_acp.py` — Plan 1 canary stays unchanged.
- `HermesBundleTests.swift`, `HermesACPProtocolTests.swift`, `HermesClientTests.swift` — Plan 1+2 canaries stay unchanged.
- The 15 `TODO(plan-2)` markers — Plan 3c.

## Section 2 — `MCPServer` API + protocol slice

### Public API

```swift
@MainActor
final class MCPServer {
    init(name: String)                          // human-readable; shows up in HttpMcpServerEntry.name
    func register(_ tool: MCPTool)               // add a tool before start()
    func start() throws -> URL                   // binds a random localhost port; returns http://127.0.0.1:<port>/mcp
    func stop()                                  // idempotent
    var serverURL: URL? { get }                  // nil when stopped
}
```

### MCP protocol slice

The server implements the minimum subset of MCP that Hermes's bundled `mcp==1.26.0` client uses during a chat session:

| Method | Direction | Behavior |
|---|---|---|
| `initialize` | client → server | Returns `{ protocolVersion: "2024-11-05", capabilities: { tools: {} }, serverInfo: { name, version: "0.1.0" } }`. |
| `notifications/initialized` | client → server (notification) | No-op; respond with HTTP 204 No Content. |
| `tools/list` | client → server | Returns `{ tools: [{ name, description, inputSchema }] }` for every registered tool. |
| `tools/call` | client → server | Validates `params.name`, dispatches to the named `MCPTool.call(arguments:)`, wraps the result in `{ content: [{ type: "text", text: <result> }], isError: false }`. Errors return the same shape with `isError: true`. |

Anything else returns JSON-RPC error `-32601 method not found`. We do NOT implement `resources/*`, `prompts/*`, or `logging/*` — they're optional MCP capabilities and Hermes does not require them for tool calling.

### `MCPTool` protocol

```swift
protocol MCPTool: Sendable {
    var name: String { get }                    // e.g. "speak"
    var description: String { get }              // shown to Hermes for tool selection
    var inputSchema: JSONValue { get }           // JSON Schema for arguments

    /// Called on @MainActor with the validated arguments. Return a
    /// human-readable result string. Throw `MCPToolError` to indicate failure.
    @MainActor func call(_ arguments: JSONValue) async throws -> String
}

enum MCPToolError: Error, CustomStringConvertible {
    case invalidArguments(String)
    case toolFailed(String)
    var description: String { /* … */ }
}
```

### `SpeakTool`

```swift
@MainActor
final class SpeakTool: MCPTool {
    let name = "speak"
    let description = "Speak the given text aloud through the user's Mac using the system voice."
    let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "text": .object([
                "type": .string("string"),
                "description": .string("The text to speak aloud.")
            ])
        ]),
        "required": .array([.string("text")])
    ])

    private let synth = AVSpeechSynthesizer()

    func call(_ arguments: JSONValue) async throws -> String {
        guard case .object(let dict) = arguments,
              case .string(let text) = dict["text"] ?? .null,
              !text.isEmpty
        else { throw MCPToolError.invalidArguments("speak requires a non-empty `text` string") }

        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synth.speak(utterance)        // fire-and-forget; AVSpeechSynthesizer queues internally
        return "Speaking: \(text)"
    }
}
```

`synth` is a stored property so the synthesizer doesn't deallocate mid-playback. Multiple rapid `speak` calls queue naturally because `AVSpeechSynthesizer.speak()`'s default behavior is to enqueue utterances.

## Section 3 — HTTP/1.1 + JSON-RPC plumbing

Hand-roll just enough HTTP/1.1 to handle a single `POST /mcp` endpoint. No Content-Length tricks, no chunked encoding, no compression, no keep-alive.

Key invariants:

- **`NWParameters.tcp` + `requiredInterfaceType = .loopback`** — listener binds to `127.0.0.1` only. Nothing reaches it from the network.
- **One request per connection** with `Connection: close`. Plan 3a's tool calls are infrequent; keep-alive complexity isn't worth it.
- **Content-Length is mandatory** for `POST /mcp` requests. Chunked transfer is not supported. Hermes's `mcp` client uses Content-Length so this is fine.
- **All tool execution on `@MainActor`** — required for `AVSpeechSynthesizer` and Plan 3b's `point_at`. JSON parsing happens on the main queue too; tools are quick so this isn't a throughput concern.
- **JSON-RPC `id` is preserved verbatim** in responses (clients are strict about matching string/number/null). A custom `JSONRPCID` enum handles all three shapes.

The connection handler is structured as a single recursive `readRequest(on:buffer:)` that accumulates bytes until both the headers AND `Content-Length` bytes of body are present, then dispatches once. This avoids any framing edge cases.

The full implementation lives in the Plan 3a implementation plan. It is approximately 200 LOC, fits in `MCPServer.swift`, and depends only on `Foundation` + `Network`. The invariants above (loopback-only, one-shot connections, Content-Length-required, MainActor handlers, JSONRPCID enum preserving id shape) are the load-bearing parts; the rest of the file is straightforward HTTP/1.1 + JSON-RPC parsing.

## Section 4 — HermesClient + DebugMenuController integration

### `HermesACPProtocol.swift` additions

```swift
struct HttpMcpServerEntry: Encodable {
    let type = "http"
    let name: String
    let url: String
    let headers: [HttpHeader]
}

struct HttpHeader: Encodable {
    let name: String
    let value: String
}
```

### `HermesClient.swift` change

```swift
@MainActor
final class HermesClient: ObservableObject {
    // …
    /// MCP server URL to register on session/new. Set BEFORE the first
    /// send() call; subsequent changes take effect when stop() + send()
    /// recycles the session.
    var mcpServerURL: URL?

    private func openSession() async throws {
        let cwd = FileManager.default.currentDirectoryPath
        let mcpServers: [HttpMcpServerEntry] = mcpServerURL.map { url in
            [HttpMcpServerEntry(name: "tiptour-tools", url: url.absoluteString, headers: [])]
        } ?? []
        let req = NewSessionRequest(cwd: cwd, mcpServers: mcpServers)
        let result: NewSessionResult = try await sendRequest(method: "session/new", params: req)
        self.sessionId = result.sessionId
    }
}
```

`NewSessionRequest.mcpServers` changes type from `[JSONValue]` (Plan 2 default empty) to `[HttpMcpServerEntry]`. Plan 2's existing call sites pass `[]` which works the same way.

### `HermesDebugMenuController.swift` change

```swift
@MainActor
final class HermesDebugMenuController: NSObject, NSWindowDelegate {
    private var statusItem: NSStatusItem?
    private var window: NSWindow?
    private let client = HermesClient()
    private let mcpServer = MCPServer(name: "tiptour-tools")

    func install() {
        mcpServer.register(SpeakTool())
        // … existing status item + menu setup
    }

    @objc private func openChat() {
        if window == nil {
            do {
                let url = try mcpServer.start()
                client.mcpServerURL = url
                NSLog("[Hermes] MCP server up at %@", url.absoluteString)
            } catch {
                NSLog("[Hermes] MCP server failed to start: %@", "\(error)")
                // The chat still opens; Hermes just won't have our tools.
            }
            let w = makeHermesChatWindow(client: client)
            w.delegate = self
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === window else { return }
        NSLog("[HermesDebugMenuController] windowWillClose — terminating Hermes + MCP server")
        client.stop()
        mcpServer.stop()
        client.mcpServerURL = nil
        window = nil
    }
}
```

### Lifecycle

| Event | What happens |
|---|---|
| App launches | `install()` creates `MCPServer` and registers `SpeakTool`. No port bound. |
| User opens chat (⌘⇧H) | `mcpServer.start()` binds to a random loopback port; `client.mcpServerURL` is set; floating window opens. |
| User sends first message | `HermesClient` launches Python; `initialize` + `session/new` (with `mcpServers: [{type:"http", name:"tiptour-tools", url:"http://127.0.0.1:<port>/mcp", headers:[]}]`); then `session/prompt`. Hermes establishes its MCP client connection to our server. |
| Hermes invokes `speak` | Hermes posts `tools/call` to `http://127.0.0.1:<port>/mcp`. `MCPServer` dispatches to `SpeakTool.call(arguments:)`, which calls `AVSpeechSynthesizer.speak()` and returns. The HTTP response carries `isError: false, content: [text: "Speaking: …"]`. Hermes continues the turn. |
| User closes chat window | `windowWillClose` fires. `client.stop()` terminates Python. `mcpServer.stop()` cancels the NWListener. State is reset. |
| User reopens chat | Fresh `start()` binds a different random port. Fresh chat transcript. |

## Section 5 — Tests + acceptance + risks

### Tests

`TipTourTests/MCPServerTests.swift`, plain `import XCTest` (no `@testable`):

1. **`testServerStartsAndStops`** — `start()` returns a `http://127.0.0.1:<port>/mcp` URL; `serverURL` becomes non-nil; `stop()` clears it.
2. **`testInitializeRoundTrip`** — POST `initialize` to the running server, verify the response has `result.protocolVersion == "2024-11-05"` and `result.serverInfo.name == "test"`.
3. **`testToolsListIncludesRegisteredTool`** — register `SpeakTool()`, POST `tools/list`, verify `result.tools[0].name == "speak"` and `inputSchema` is non-nil.
4. **`testToolsCallSpeakReturnsSuccess`** — register `SpeakTool()`, POST `tools/call` with `{name: "speak", arguments: {text: "test"}}`, verify `result.isError == false` and `result.content[0].text` contains `"test"`. The test machine will briefly say "test" out loud — acceptable for a dev tool.

`postJSON(to:body:)` is a private helper using `URLSession.shared.data(for:)`.

### Acceptance criteria

Plan 3a is done when ALL of these are true:

1. `xcodebuild build` exits 0 with `** BUILD SUCCEEDED **`.
2. `xcodebuild test -only-testing:tiptour-macosTests/MCPServerTests` — all 4 cases pass.
3. Plan 1 + Plan 2 regression gate green: `HermesBundleTests`, `HermesACPProtocolTests`, `HermesClientTests` all pass; `./Tests/Python/smoke_test_acp.py` still passes at minimum phase 1.
4. Launching `TipTour_Hermes.app`, opening "Talk to Hermes…", typing **`Say "hello from plan 3a" out loud using the speak tool.`** produces:
   - An agent turn in the chat showing a `▸ speak(text="hello from plan 3a") [completed]` collapsible row.
   - Audible Mac speech saying "hello from plan 3a".
5. Closing the chat window terminates both subprocesses AND the MCP listener. Verify with `lsof -iTCP:LISTEN -P | grep 127.0.0.1` showing no entries owned by `TipTour_Hermes`.
6. Reopening the chat window starts a fresh MCP server on a different random port (visible in `lsof` output).

### Risks

| Risk | Mitigation |
|---|---|
| MCP `initialize` `protocolVersion` mismatch — Hermes's `mcp==1.26.0` client may want a different version string than `"2024-11-05"`. | Acceptance criterion 4 catches it: if Hermes rejects our `initialize`, no tool calls fire. Diagnostic: log the raw `initialize` request body during Task 3's BUILD-CHECK, align our reply. |
| `tools/call` argument shape differs from what we modeled (e.g. arguments may be a string blob in some MCP client versions). | Same diagnostic pattern as Plan 2 Task 7's `tool_call` discriminator fix — log the raw request body, patch the dispatcher. Acceptance criterion 4 will surface mismatch as a "speak failed: invalid arguments" tool-call row. |
| `NWListener.start()` blocks waiting for `.ready` state and the 1-second semaphore times out. | `start()` throws `MCPServerError.failedToBind` if `port` is nil. Test 1 (`testServerStartsAndStops`) catches it. Fallback: tighten the deadline to 250 ms; loopback bind should be near-instant. |
| `AVSpeechSynthesizer` requires an Info.plist usage description on macOS 26+. | TipTour's Info.plist already declares mic + speech permissions. If `speak()` errors at runtime with a permissions complaint, add `NSSpeechSynthesisUsageDescription` to `TipTour/Info.plist`. macOS 14/15 documentation does not require this for `AVSpeechSynthesizer` (only for `SFSpeechRecognizer`). |
| Hermes makes parallel MCP requests during a turn. | Each request is a separate connection (`Connection: close`); the `NWListener` queues them on `.main` and handlers run serially on `@MainActor`. `AVSpeechSynthesizer` queues utterances internally so two rapid `speak` calls don't conflict. |
| Test 4 ("the test machine actually says 'test' out loud") gets annoying in CI / dev. | Live test is opt-out via `XCTSkipIf(ProcessInfo.processInfo.environment["MCP_SILENT_TESTS"] == "1")` — add only if it actually becomes a problem. Plan 3a ships without the skip. |

## Section 6 — What comes after Plan 3a

**Plan 3b — Remaining Mac tools.** Adds `take_screenshot` (via `ScreenRecorder`), `get_a11y_tree` (via `AccessibilityTreeResolver`), and `point_at(rect_or_label, message)` (via `OverlayWindow` + `NekoCursorView`'s Arc Reactor cursor). All three register on the same `MCPServer` Plan 3a built. Dev-chat verification: "what's on screen?", "point at the Save button".

**Plan 3c — Voice-loop integration.** Push-to-talk → Gemini Live STT → `HermesClient.send` → reply → `AVSpeechSynthesizer` TTS. Replaces the 15 `TODO(plan-2)` markers in `CompanionManager` / `GeminiLiveSession` / `CompanionPanelView`. The voice-first UX returns, powered by Hermes the brain rather than the deleted TipTour swarm.

Both 3b and 3c assume Plan 3a has landed cleanly: a working MCP server, the `mcpServers` registration path, and the lifecycle wiring in `HermesDebugMenuController`.
