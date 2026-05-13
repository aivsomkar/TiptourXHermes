# Plan 2 — ACP Bridge + Dev "Talk to Hermes" Textbox — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Swift `HermesClient` that speaks ACP over stdio to the already-bundled `hermes-runtime` Python subprocess, plus a dev-only floating chat window opened from a new menu-bar status item. Proves end-to-end text chat works through the bundle, without touching the existing voice loop, overlay, or `CompanionManager`.

**Architecture:** A single `@MainActor`-isolated `HermesClient` class wraps `Process` + `Pipe`s with newline-delimited JSON-RPC framing, exposes `@Published` chat state (`transcript`, `isWorking`, `lastError`), and lazy-starts the subprocess on first `send`. A second standalone `NSStatusItem` (independent of the existing companion status item) carries an `NSMenu` with a "Talk to Hermes…" entry that opens a floating `NSWindow` hosting a SwiftUI chat view. The 15 `TODO(plan-2)` markers left in `CompanionManager` / `GeminiLiveSession` / `CompanionPanelView` from the rebrand are NOT touched.

**Tech Stack:** Swift 5, SwiftUI, AppKit (`NSStatusItem`, `NSMenu`, `NSWindow`), `Foundation.Process` + `Pipe` for stdio, `JSONEncoder`/`JSONDecoder` for ACP frames. Tests in XCTest.

**Spec:** [docs/superpowers/specs/2026-05-13-plan-2-acp-bridge-and-dev-textbox-design.md](../specs/2026-05-13-plan-2-acp-bridge-and-dev-textbox-design.md)

---

## File-structure summary

**New Swift source files (all in `TipTour/Hermes/`):**

- `TipTour/Hermes/HermesACPProtocol.swift` — Codable types for ACP frames; `JSONValue` recursive enum; JSON-RPC envelope helpers.
- `TipTour/Hermes/HermesClient.swift` — `@MainActor final class HermesClient: ObservableObject` with `@Published` state, async `send`, idempotent `stop`. Owns the `Process` + `Pipe` plumbing.
- `TipTour/Hermes/HermesChatWindow.swift` — `NSWindow` factory + SwiftUI `HermesChatView` + `ChatTurnRow` + `ToolCallRow`.
- `TipTour/Hermes/HermesDebugMenuController.swift` — Owns a standalone `NSStatusItem` whose menu has "Talk to Hermes…". Owns the chat window and the HermesClient instance.

**Modified Swift source files:**

- `TipTour/TipTourApp.swift` — Add `hermesDebugMenu: HermesDebugMenuController?` property to `CompanionAppDelegate`; instantiate in `applicationDidFinishLaunching`.

**New test files:**

- `TipTourTests/HermesACPProtocolTests.swift` — encode/decode round-trips for the Codable types.
- `TipTourTests/HermesClientTests.swift` — three test methods per spec section 5.

**Deliberately NOT modified:**

- `TipTour/MenuBarPanelManager.swift` — spec said add `attachDebugItems(_:)`; reality is the existing status item uses a custom `NSPanel` (not an `NSMenu`), so menu-item injection doesn't fit. The standalone second status item in `HermesDebugMenuController` sidesteps the issue entirely.
- The 15 `TODO(plan-2)` markers in `CompanionManager.swift` / `GeminiLiveSession.swift` / `CompanionPanelView.swift` — Plan 3.
- `Tests/Python/smoke_test_acp.py` — Plan 1's canary stays as-is.
- `HermesBundleTests.swift` — Plan 1's canary stays as-is.

**Public vs internal access:** `TipTourTests/HermesBundleTests.swift` uses plain `import XCTest` (no `@testable import TipTour`). To follow the same pattern, every type the new `HermesClientTests` touches (`HermesClient`, `HermesClient.ChatTurn`, `HermesClient.ToolCallRecord`) must be declared `public`. The internal protocol helpers in `HermesACPProtocol.swift` can stay `internal` because tests reach the wire via `HermesClient`, not by encoding frames directly. **Exception:** `HermesACPProtocolTests` exercises the Codable types directly, so it uses `@testable import TipTour` for access to internal types. Both patterns coexist — one test file per access style.

---

## Verification commands used throughout

**BUILD-CHECK:**
```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  xcodebuild -project tiptour-macos.xcodeproj -scheme tiptour-macos \
             -configuration Debug build 2>&1 | tail -5
```
Expected: last line is `** BUILD SUCCEEDED **`.

**TEST-CHECK (HermesBundleTests — Plan 1 canary):**
```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  xcodebuild -project tiptour-macos.xcodeproj -scheme tiptour-macos \
             -configuration Debug test \
             -only-testing:tiptour-macosTests/HermesBundleTests 2>&1 | \
  grep -E '^\*\* (TEST|BUILD) (SUCCEEDED|FAILED)|Test Case.*(passed|failed)'
```
Expected: three `Test Case ... passed` lines, then `** TEST SUCCEEDED **`.

**ACP-PROTOCOL-TESTS-CHECK:**
```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  xcodebuild -project tiptour-macos.xcodeproj -scheme tiptour-macos \
             -configuration Debug test \
             -only-testing:tiptour-macosTests/HermesACPProtocolTests 2>&1 | \
  grep -E '^\*\* (TEST|BUILD) (SUCCEEDED|FAILED)|Test Case.*(passed|failed)'
```

**CLIENT-TESTS-CHECK:**
```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  xcodebuild -project tiptour-macos.xcodeproj -scheme tiptour-macos \
             -configuration Debug test \
             -only-testing:tiptour-macosTests/HermesClientTests 2>&1 | \
  grep -E '^\*\* (TEST|BUILD) (SUCCEEDED|FAILED)|Test Case.*(passed|failed|Skipped)'
```

**SMOKE-CHECK (Python — Plan 1 canary):**
```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  PYTHONUNBUFFERED=1 ./Tests/Python/smoke_test_acp.py
```

---

## Task 1: Pre-flight tag

**Files:** none (git only).

- [ ] **Step 1: Confirm clean working tree.**

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && git status --short
```
Expected: empty (or only `.claude/` untracked). Stop and resolve anything else first.

- [ ] **Step 2: Tag the current `main` head as `pre-plan-2`.**

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  git tag pre-plan-2 && \
  git tag --list 'pre-*'
```
Expected: prints `pre-plan-2` (and `pre-rebrand` from earlier work).

---

## Task 2: Create `HermesACPProtocol.swift` with JSON-RPC envelopes and `JSONValue`

**Files:**
- Create: `TipTour/Hermes/HermesACPProtocol.swift`
- Create: `TipTourTests/HermesACPProtocolTests.swift`

The Codable type surface lands in two tasks (this one + Task 3) to keep each task bite-sized. This task adds the envelopes plus `JSONValue`; Task 3 adds the ACP-specific request/result types.

- [ ] **Step 1: Create the `Hermes/` directory.**

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  mkdir -p TipTour/Hermes && ls TipTour/Hermes/
```
Expected: empty listing (directory exists, no files yet).

- [ ] **Step 2: Write the failing test file `TipTourTests/HermesACPProtocolTests.swift`.**

```swift
import XCTest
@testable import TipTour

final class HermesACPProtocolTests: XCTestCase {

    // MARK: - JSONValue

    func testJSONValueEncodesAllScalarKinds() throws {
        let encoder = JSONEncoder()
        XCTAssertEqual(try String(data: encoder.encode(JSONValue.null), encoding: .utf8), "null")
        XCTAssertEqual(try String(data: encoder.encode(JSONValue.bool(true)), encoding: .utf8), "true")
        XCTAssertEqual(try String(data: encoder.encode(JSONValue.number(42)), encoding: .utf8), "42")
        XCTAssertEqual(try String(data: encoder.encode(JSONValue.string("hi")), encoding: .utf8), "\"hi\"")
    }

    func testJSONValueRoundTripsNestedStructure() throws {
        let raw = #"{"a":1,"b":[true,null,"x"],"c":{"nested":3.5}}"#
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8))
        guard case .object(let dict) = value else { XCTFail("expected object"); return }
        XCTAssertEqual(dict.count, 3)
    }

    // MARK: - JSON-RPC envelope

    func testJSONRPCRequestEncodesExpectedShape() throws {
        struct Empty: Encodable {}
        let req = JSONRPCRequest(id: "abc", method: "initialize", params: Empty())
        let json = try String(data: JSONEncoder().encode(req), encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains(#""jsonrpc":"2.0""#))
        XCTAssertTrue(json.contains(#""id":"abc""#))
        XCTAssertTrue(json.contains(#""method":"initialize""#))
    }

    func testJSONRPCResponseDecodesResultAndError() throws {
        struct DummyResult: Decodable { let ok: Bool }

        let okJSON = #"{"jsonrpc":"2.0","id":"x","result":{"ok":true}}"#.data(using: .utf8)!
        let okResp = try JSONDecoder().decode(JSONRPCResponse<DummyResult>.self, from: okJSON)
        XCTAssertEqual(okResp.result?.ok, true)
        XCTAssertNil(okResp.error)

        let errJSON = #"{"jsonrpc":"2.0","id":"y","error":{"code":-32603,"message":"boom"}}"#.data(using: .utf8)!
        let errResp = try JSONDecoder().decode(JSONRPCResponse<DummyResult>.self, from: errJSON)
        XCTAssertNil(errResp.result)
        XCTAssertEqual(errResp.error?.code, -32603)
        XCTAssertEqual(errResp.error?.message, "boom")
    }
}
```

- [ ] **Step 3: Run the tests to confirm they fail with "no such module" / "use of unresolved identifier".**

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  xcodebuild -project tiptour-macos.xcodeproj -scheme tiptour-macos \
             -configuration Debug build 2>&1 | tail -10
```
Expected: build fails with errors about missing `JSONValue`, `JSONRPCRequest`, `JSONRPCResponse`, `JSONRPCError`. This is expected — we haven't written them yet.

- [ ] **Step 4: Create `TipTour/Hermes/HermesACPProtocol.swift` with envelopes + `JSONValue`.**

```swift
// TipTour/Hermes/HermesACPProtocol.swift
//
// Codable types for the slice of the Agent Client Protocol we speak.
// Wire framing is newline-delimited JSON over the bundled Python
// subprocess's stdio — see HermesClient for the reader/writer.

import Foundation

// MARK: - JSONValue (forward-compat fallback)

/// A recursive JSON value used wherever the spec is loose enough that we
/// don't want to crash on unfamiliar fields. Lets us decode arbitrary
/// payloads (e.g. `agentCapabilities`, MCP server entries, `models`)
/// without modeling every variant.
indirect enum JSONValue: Codable, Equatable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let n = try? c.decode(Double.self) { self = .number(n); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unrecognised JSON value")
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null:           try c.encodeNil()
        case .bool(let b):    try c.encode(b)
        case .number(let n):  try c.encode(n)
        case .string(let s):  try c.encode(s)
        case .array(let a):   try c.encode(a)
        case .object(let o):  try c.encode(o)
        }
    }
}

// MARK: - JSON-RPC envelopes

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

struct JSONRPCError: Decodable, Error, Equatable {
    let code: Int
    let message: String
    let data: JSONValue?
}
```

- [ ] **Step 5: Re-run the tests; they should pass.**

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  xcodebuild -project tiptour-macos.xcodeproj -scheme tiptour-macos \
             -configuration Debug test \
             -only-testing:tiptour-macosTests/HermesACPProtocolTests 2>&1 | \
  grep -E '^\*\* (TEST|BUILD) (SUCCEEDED|FAILED)|Test Case.*(passed|failed)'
```
Expected: four `Test Case ... passed` lines, then `** TEST SUCCEEDED **`.

- [ ] **Step 6: Commit.**

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  git add TipTour/Hermes/HermesACPProtocol.swift TipTourTests/HermesACPProtocolTests.swift && \
  git commit -m "feat(hermes): JSON-RPC envelopes and JSONValue for ACP wire format"
```

---

## Task 3: Add ACP request/result types and `SessionUpdate`

**Files:**
- Modify: `TipTour/Hermes/HermesACPProtocol.swift`
- Modify: `TipTourTests/HermesACPProtocolTests.swift`

- [ ] **Step 1: Append failing tests to `HermesACPProtocolTests.swift`.**

```swift
    // MARK: - ACP requests

    func testInitializeRequestEncodesShape() throws {
        let req = InitializeRequest(
            clientCapabilities: ClientCapabilities(
                fs: FSCapabilities(readTextFile: false, writeTextFile: false),
                terminal: false
            )
        )
        let json = try String(data: JSONEncoder().encode(req), encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains(#""protocolVersion":1"#))
        XCTAssertTrue(json.contains(#""terminal":false"#))
        XCTAssertTrue(json.contains(#""readTextFile":false"#))
    }

    func testNewSessionResultDecodes() throws {
        let raw = #"{"sessionId":"abc-123","models":null}"#.data(using: .utf8)!
        let result = try JSONDecoder().decode(NewSessionResult.self, from: raw)
        XCTAssertEqual(result.sessionId, "abc-123")
    }

    func testPromptResultDecodesWithUsage() throws {
        let raw = #"""
        {"stopReason":"end_turn","usage":{"inputTokens":100,"outputTokens":5,"totalTokens":105}}
        """#.data(using: .utf8)!
        let result = try JSONDecoder().decode(PromptResult.self, from: raw)
        XCTAssertEqual(result.stopReason, "end_turn")
        XCTAssertEqual(result.usage?.totalTokens, 105)
    }

    // MARK: - SessionUpdate

    func testSessionUpdateDecodesAgentMessageChunk() throws {
        let raw = #"""
        {"sessionId":"s","update":{"sessionUpdate":"agent_message_chunk","content":{"text":"hi","type":"text"}}}
        """#.data(using: .utf8)!
        let n = try JSONDecoder().decode(SessionUpdateNotification.self, from: raw)
        guard case .agentMessageChunk(let text) = n.update else {
            XCTFail("expected agentMessageChunk, got \(n.update)")
            return
        }
        XCTAssertEqual(text, "hi")
    }

    func testSessionUpdateDecodesUnknownDiscriminator() throws {
        let raw = #"""
        {"sessionId":"s","update":{"sessionUpdate":"some_future_kind","extra":42}}
        """#.data(using: .utf8)!
        let n = try JSONDecoder().decode(SessionUpdateNotification.self, from: raw)
        guard case .unknown(let raw) = n.update else { XCTFail("expected .unknown"); return }
        // The wrapping JSONValue should be an object with at least the
        // sessionUpdate key.
        guard case .object(let dict) = raw else { XCTFail("expected object"); return }
        XCTAssertEqual(dict["sessionUpdate"], .string("some_future_kind"))
    }
}
```

- [ ] **Step 2: Run the tests to confirm new ones fail (existing 4 still pass).**

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  xcodebuild -project tiptour-macos.xcodeproj -scheme tiptour-macos \
             -configuration Debug test \
             -only-testing:tiptour-macosTests/HermesACPProtocolTests 2>&1 | tail -10
```
Expected: build fails (missing types) or tests fail with "Cannot find 'InitializeRequest'". Either is fine.

- [ ] **Step 3: Append the ACP types to `HermesACPProtocol.swift`.**

```swift
// MARK: - ACP requests (Client → Agent)

struct InitializeRequest: Encodable {
    let protocolVersion: Int = 1
    let clientCapabilities: ClientCapabilities
}

struct ClientCapabilities: Encodable {
    let fs: FSCapabilities
    let terminal: Bool
}

struct FSCapabilities: Encodable {
    let readTextFile: Bool
    let writeTextFile: Bool
}

struct NewSessionRequest: Encodable {
    let cwd: String
    let mcpServers: [JSONValue]   // empty for Plan 2
}

struct PromptRequest: Encodable {
    let sessionId: String
    let prompt: [TextBlock]
}

struct TextBlock: Encodable {
    let type: String = "text"
    let text: String
}

// MARK: - Agent → Client: server-initiated request (session/request_permission)

struct PermissionResponse: Encodable {
    let outcome: PermissionOutcome
}

struct PermissionOutcome: Encodable {
    let outcome: String     // "selected"
    let optionId: String    // "allow"
}

// MARK: - ACP results (Agent → Client responses)

struct InitializeResult: Decodable {
    let protocolVersion: Int
    let agentCapabilities: JSONValue
    let agentInfo: AgentInfo?
    let authMethods: [JSONValue]?
}

struct AgentInfo: Decodable {
    let name: String
    let version: String
}

struct NewSessionResult: Decodable {
    let sessionId: String
    let models: JSONValue?
}

struct PromptResult: Decodable {
    let stopReason: String
    let usage: UsageInfo?
}

struct UsageInfo: Decodable {
    let inputTokens: Int
    let outputTokens: Int
    let totalTokens: Int
    let cachedReadTokens: Int?
    let thoughtTokens: Int?
}

// MARK: - Notifications (Agent → Client, no response expected)

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
    case unknown(raw: JSONValue)

    init(from decoder: Decoder) throws {
        // We decode through JSONValue first so we can inspect the
        // discriminator and fall back to .unknown(raw:) on anything we
        // don't recognise. This makes the client tolerant to new ACP
        // sessionUpdate variants the spec adds in the future.
        let raw = try JSONValue(from: decoder)
        guard case .object(let dict) = raw,
              case .string(let kind) = dict["sessionUpdate"] ?? .null
        else {
            self = .unknown(raw: raw)
            return
        }

        switch kind {
        case "agent_message_chunk":
            if case .object(let content) = dict["content"] ?? .null,
               case .string(let text) = content["text"] ?? .null {
                self = .agentMessageChunk(text: text)
            } else {
                self = .unknown(raw: raw)
            }
        case "user_message_chunk":
            if case .object(let content) = dict["content"] ?? .null,
               case .string(let text) = content["text"] ?? .null {
                self = .userMessageChunk(text: text)
            } else {
                self = .unknown(raw: raw)
            }
        case "tool_call_start":
            if case .string(let id) = dict["toolCallId"] ?? .null,
               case .string(let name) = dict["name"] ?? .null {
                self = .toolCallStart(
                    id: id,
                    name: name,
                    args: dict["args"] ?? .null,
                    location: dict["location"]
                )
            } else {
                self = .unknown(raw: raw)
            }
        case "tool_call_progress":
            if case .string(let id) = dict["toolCallId"] ?? .null,
               case .string(let status) = dict["status"] ?? .null {
                self = .toolCallProgress(id: id, status: status, output: dict["output"])
            } else {
                self = .unknown(raw: raw)
            }
        case "tool_call_end":
            if case .string(let id) = dict["toolCallId"] ?? .null,
               case .string(let status) = dict["status"] ?? .null {
                self = .toolCallEnd(id: id, status: status)
            } else {
                self = .unknown(raw: raw)
            }
        case "available_commands_update":
            if case .array(let cmds) = dict["availableCommands"] ?? .null {
                self = .availableCommandsUpdate(commands: cmds)
            } else if case .array(let cmds) = dict["commands"] ?? .null {
                self = .availableCommandsUpdate(commands: cmds)
            } else {
                self = .unknown(raw: raw)
            }
        case "usage_update":
            let size: Int? = {
                if case .number(let n) = dict["size"] ?? .null { return Int(n) }
                return nil
            }()
            if case .number(let used) = dict["used"] ?? .null {
                self = .usageUpdate(size: size, used: Int(used))
            } else {
                self = .unknown(raw: raw)
            }
        default:
            self = .unknown(raw: raw)
        }
    }
}
```

> **Note on discriminator strings:** Spec section 6's risks note that the exact `sessionUpdate` strings (`tool_call_start`, etc.) for `agent-client-protocol` 0.9.0 are unverified. Plan 1's smoke test confirmed `agent_message_chunk`, `available_commands_update`, `usage_update`. The tool-call discriminators above are best-guesses. If Task 7 (live tool-call test) reveals different strings, update the `switch` arms here — the `.unknown(raw:)` fallback ensures no crash in the meantime.

- [ ] **Step 4: Re-run the tests.**

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  xcodebuild -project tiptour-macos.xcodeproj -scheme tiptour-macos \
             -configuration Debug test \
             -only-testing:tiptour-macosTests/HermesACPProtocolTests 2>&1 | \
  grep -E '^\*\* (TEST|BUILD) (SUCCEEDED|FAILED)|Test Case.*(passed|failed)'
```
Expected: nine `Test Case ... passed` lines (4 original + 5 new), then `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit.**

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  git add TipTour/Hermes/HermesACPProtocol.swift TipTourTests/HermesACPProtocolTests.swift && \
  git commit -m "feat(hermes): ACP request/result types and SessionUpdate decoder"
```

---

## Task 4: Scaffold `HermesClient` skeleton (no IO yet)

**Files:**
- Create: `TipTour/Hermes/HermesClient.swift`
- Create: `TipTourTests/HermesClientTests.swift`

This task lands the public type surface and confirms it compiles. No subprocess, no IO — just types and empty state.

- [ ] **Step 1: Create `TipTourTests/HermesClientTests.swift` with the empty-state test.**

```swift
import XCTest
import Combine
@testable import TipTour

final class HermesClientTests: XCTestCase {

    @MainActor
    func testNewClientHasEmptyState() async {
        let client = HermesClient()
        XCTAssertTrue(client.transcript.isEmpty)
        XCTAssertFalse(client.isWorking)
        XCTAssertNil(client.lastError)
    }
}
```

- [ ] **Step 2: Run the test — expected to fail (no `HermesClient`).**

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  xcodebuild -project tiptour-macos.xcodeproj -scheme tiptour-macos \
             -configuration Debug test \
             -only-testing:tiptour-macosTests/HermesClientTests 2>&1 | tail -10
```
Expected: compile error "Cannot find 'HermesClient' in scope".

- [ ] **Step 3: Create `TipTour/Hermes/HermesClient.swift` with the skeleton.**

```swift
// TipTour/Hermes/HermesClient.swift
//
// Swift ACP client for the bundled hermes-runtime Python subprocess.
// Owns: subprocess lifecycle, JSON-RPC framing, and the @Published
// transcript state consumed by HermesChatView. SwiftUI-friendly because
// every published mutation happens on @MainActor.

import Foundation
import Combine

@MainActor
final class HermesClient: ObservableObject {

    // MARK: Published state
    @Published private(set) var transcript: [ChatTurn] = []
    @Published private(set) var isWorking: Bool = false
    @Published private(set) var lastError: String?

    // MARK: Init
    /// - Parameter hermesHome: Test-only override for the `HERMES_HOME` env
    ///   var passed to the subprocess. Production callers should leave this
    ///   `nil` so Hermes uses its default (`~/.hermes/`).
    init(hermesHome: URL? = nil) {
        self.hermesHomeOverride = hermesHome
    }

    // MARK: Public API
    func send(_ userText: String) async {
        // Implemented in Tasks 5–7.
        _ = userText
    }

    func stop() {
        // Implemented in Task 8.
    }

    // MARK: Types

    enum ChatTurn: Identifiable {
        case user(id: UUID, text: String)
        case agent(id: UUID, text: String, toolCalls: [ToolCallRecord])
        case system(id: UUID, text: String)

        var id: UUID {
            switch self {
            case .user(let i, _),
                 .agent(let i, _, _),
                 .system(let i, _):
                return i
            }
        }
    }

    struct ToolCallRecord: Identifiable, Equatable {
        let id: String
        let name: String
        let argsPreview: String
        let argsFull: String
        var status: Status

        enum Status: String, Equatable { case pending, completed, failed }
    }

    // MARK: Internal state (impl tasks 5–8)
    private let hermesHomeOverride: URL?
}
```

- [ ] **Step 4: Run the test — should now pass.**

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  xcodebuild -project tiptour-macos.xcodeproj -scheme tiptour-macos \
             -configuration Debug test \
             -only-testing:tiptour-macosTests/HermesClientTests 2>&1 | \
  grep -E '^\*\* (TEST|BUILD) (SUCCEEDED|FAILED)|Test Case.*(passed|failed)'
```
Expected: one `Test Case ... passed` line, then `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit.**

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  git add TipTour/Hermes/HermesClient.swift TipTourTests/HermesClientTests.swift && \
  git commit -m "feat(hermes): HermesClient skeleton with @Published state"
```

---

## Task 5: HermesClient subprocess launch + `initialize` + `session/new` + missing-config error surfacing

**Files:**
- Modify: `TipTour/Hermes/HermesClient.swift`
- Modify: `TipTourTests/HermesClientTests.swift`

Implements: lazy subprocess launch on first `send`, the `initialize` + `session/new` handshake, and surfacing Hermes errors as `.system` chat turns. NO `session/prompt` yet — that's Task 6.

- [ ] **Step 1: Append the missing-config test to `HermesClientTests.swift`.**

```swift
    /// First send with HERMES_HOME pointing at an empty temp dir
    /// should surface Hermes's "No LLM provider configured" error as
    /// a .system turn rather than hanging.
    @MainActor
    func testFirstSendWithMissingConfigSurfacesSystemTurn() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("hermes-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let client = HermesClient(hermesHome: tmp)
        await client.send("hello")
        // After send returns we expect exactly:
        //   transcript[0] = .user("hello")
        //   transcript[1] = .system("Hermes error: …")
        XCTAssertEqual(client.transcript.count, 2)
        if case .user(_, let t) = client.transcript[0] {
            XCTAssertEqual(t, "hello")
        } else { XCTFail("expected .user at index 0") }
        if case .system(_, let text) = client.transcript[1] {
            XCTAssertTrue(text.lowercased().contains("hermes error"))
            XCTAssertTrue(text.lowercased().contains("provider") || text.lowercased().contains("config"))
        } else { XCTFail("expected .system at index 1") }
        client.stop()
    }
```

- [ ] **Step 2: Run the test — should fail or hang.**

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  xcodebuild -project tiptour-macos.xcodeproj -scheme tiptour-macos \
             -configuration Debug test \
             -only-testing:tiptour-macosTests/HermesClientTests/testFirstSendWithMissingConfigSurfacesSystemTurn 2>&1 | tail -10
```
Expected: test fails (`transcript.count == 1` not `2`). The current `send` body is a no-op so only the user turn appears once we add it — we haven't added it yet, so count is `0`.

- [ ] **Step 3: Replace the body of `HermesClient.swift` with the full subprocess + handshake implementation.**

```swift
// TipTour/Hermes/HermesClient.swift

import Foundation
import Combine

@MainActor
final class HermesClient: ObservableObject {

    // MARK: Published state
    @Published private(set) var transcript: [ChatTurn] = []
    @Published private(set) var isWorking: Bool = false
    @Published private(set) var lastError: String?

    // MARK: Init
    init(hermesHome: URL? = nil) {
        self.hermesHomeOverride = hermesHome
    }

    deinit {
        // Synchronous best-effort cleanup. stop() is @MainActor so we
        // can't await it from deinit; terminate directly instead.
        process?.terminate()
    }

    // MARK: Public API

    func send(_ userText: String) async {
        transcript.append(.user(id: UUID(), text: userText))

        // First send launches the subprocess and runs initialize + new_session.
        if sessionId == nil {
            isWorking = true
            defer { isWorking = false }
            do {
                try await launchSubprocessIfNeeded()
                try await initializeHandshake()
                try await openSession()
            } catch {
                appendSystemError(error)
                return
            }
        }
        // Task 6 fills in session/prompt here. For Task 5 we stop after the handshake.
    }

    func stop() {
        guard let proc = process, proc.isRunning else {
            process = nil
            sessionId = nil
            return
        }
        proc.terminate()
        // 2-second SIGTERM grace; SIGKILL escalation lives in Task 8.
        let deadline = Date().addingTimeInterval(2)
        while proc.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        process = nil
        sessionId = nil
    }

    // MARK: Types (unchanged)

    enum ChatTurn: Identifiable {
        case user(id: UUID, text: String)
        case agent(id: UUID, text: String, toolCalls: [ToolCallRecord])
        case system(id: UUID, text: String)

        var id: UUID {
            switch self {
            case .user(let i, _), .agent(let i, _, _), .system(let i, _): return i
            }
        }
    }

    struct ToolCallRecord: Identifiable, Equatable {
        let id: String
        let name: String
        let argsPreview: String
        let argsFull: String
        var status: Status
        enum Status: String, Equatable { case pending, completed, failed }
    }

    // MARK: Internal state
    private let hermesHomeOverride: URL?
    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stdinPipe: Pipe?
    private var stderrPipe: Pipe?
    private var sessionId: String?

    /// Map from JSON-RPC request id → continuation that resumes when the
    /// matching response arrives on stdout.
    private var pendingResponses: [String: CheckedContinuation<Data, Error>] = [:]
    /// stderr ring buffer (≤8 KB) so error messages can include the Python tail.
    private var stderrTail: Data = Data()
    private var nextRequestSeq: Int = 0

    // MARK: Subprocess launch

    private func launchSubprocessIfNeeded() async throws {
        guard process == nil else { return }
        guard let runtimeURL = Self.runtimeURL else {
            throw HermesClientError.runtimeMissing
        }
        let p = Process()
        p.executableURL = runtimeURL

        var env = ProcessInfo.processInfo.environment
        if let override = hermesHomeOverride {
            env["HERMES_HOME"] = override.path
        }
        p.environment = env

        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = stderr

        // stdout reader: line-buffered. We capture the FileHandle and
        // dispatch each newline-delimited frame back to @MainActor for
        // continuation lookup + notification handling.
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in
                self?.ingestStdout(data)
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in
                self?.appendStderr(data)
            }
        }

        try p.run()
        self.process = p
        self.stdoutPipe = stdout
        self.stdinPipe = stdin
        self.stderrPipe = stderr
    }

    private static var runtimeURL: URL? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let url = resources
            .appendingPathComponent("hermes-runtime", isDirectory: true)
            .appendingPathComponent("hermes-runtime")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    // MARK: ACP handshake

    private func initializeHandshake() async throws {
        let req = InitializeRequest(
            clientCapabilities: ClientCapabilities(
                fs: FSCapabilities(readTextFile: false, writeTextFile: false),
                terminal: false
            )
        )
        let _: InitializeResult = try await sendRequest(method: "initialize", params: req)
    }

    private func openSession() async throws {
        let cwd = FileManager.default.currentDirectoryPath
        let req = NewSessionRequest(cwd: cwd, mcpServers: [])
        let result: NewSessionResult = try await sendRequest(method: "session/new", params: req)
        self.sessionId = result.sessionId
    }

    // MARK: Wire-level send + receive

    private func nextID() -> String {
        nextRequestSeq += 1
        return "req-\(nextRequestSeq)"
    }

    private func sendRequest<P: Encodable, R: Decodable>(
        method: String, params: P
    ) async throws -> R {
        let id = nextID()
        let envelope = JSONRPCRequest(id: id, method: method, params: params)
        let data = try JSONEncoder().encode(envelope) + Data("\n".utf8)
        guard let stdin = stdinPipe?.fileHandleForWriting else {
            throw HermesClientError.subprocessGone
        }
        try stdin.write(contentsOf: data)

        let responseData: Data = try await withCheckedThrowingContinuation { cont in
            pendingResponses[id] = cont
        }
        let response = try JSONDecoder().decode(JSONRPCResponse<R>.self, from: responseData)
        if let error = response.error {
            throw error
        }
        guard let result = response.result else {
            throw HermesClientError.malformedResponse("no result/error field")
        }
        return result
    }

    private var stdoutBuffer = Data()

    private func ingestStdout(_ chunk: Data) {
        stdoutBuffer.append(chunk)
        while let nl = stdoutBuffer.firstIndex(of: 0x0A) {  // '\n'
            let lineData = stdoutBuffer.subdata(in: 0..<nl)
            stdoutBuffer.removeSubrange(0...nl)
            guard !lineData.isEmpty else { continue }
            handleFrame(lineData)
        }
    }

    private func handleFrame(_ line: Data) {
        // Peek at the JSON to figure out whether it's a response (has
        // "id" and no "method") or a notification/request (has "method").
        guard let envelope = try? JSONDecoder().decode(FrameEnvelope.self, from: line) else {
            return
        }
        if envelope.method == nil, let id = envelope.id {
            // Response to a request we made.
            if let cont = pendingResponses.removeValue(forKey: id) {
                cont.resume(returning: line)
            }
            return
        }
        // Task 6+ handle methods (notifications and server-initiated requests).
        // For Task 5 we ignore them — the handshake never produces any.
    }

    private struct FrameEnvelope: Decodable {
        let id: String?
        let method: String?
    }

    // MARK: stderr buffering

    private func appendStderr(_ chunk: Data) {
        stderrTail.append(chunk)
        if stderrTail.count > 8 * 1024 {
            stderrTail.removeFirst(stderrTail.count - 8 * 1024)
        }
    }

    // MARK: Error reporting

    private func appendSystemError(_ error: Error) {
        let detail: String
        if let rpc = error as? JSONRPCError {
            // Hermes's "No LLM provider configured" comes wrapped in
            // `data.details` for the session/new -32603 internal-error path.
            if case .object(let dict) = rpc.data ?? .null,
               case .string(let d) = dict["details"] ?? .null {
                detail = "\(rpc.message): \(d)"
            } else {
                detail = rpc.message
            }
        } else if let h = error as? HermesClientError {
            detail = h.description
        } else {
            detail = "\(error)"
        }
        lastError = detail
        transcript.append(.system(id: UUID(), text: "Hermes error: \(detail)"))
    }
}

// MARK: - Client-internal error type

enum HermesClientError: Error, CustomStringConvertible {
    case runtimeMissing
    case subprocessGone
    case malformedResponse(String)

    var description: String {
        switch self {
        case .runtimeMissing:
            return "hermes-runtime executable not found inside the app bundle"
        case .subprocessGone:
            return "hermes-runtime subprocess is not running"
        case .malformedResponse(let why):
            return "malformed ACP response: \(why)"
        }
    }
}
```

- [ ] **Step 4: Run the missing-config test.**

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  xcodebuild -project tiptour-macos.xcodeproj -scheme tiptour-macos \
             -configuration Debug test \
             -only-testing:tiptour-macosTests/HermesClientTests/testFirstSendWithMissingConfigSurfacesSystemTurn 2>&1 | \
  grep -E '^\*\* (TEST|BUILD) (SUCCEEDED|FAILED)|Test Case.*(passed|failed)'
```
Expected: one `Test Case ... passed` line. The test runs the bundled Python (which always launches and answers `initialize` regardless of config), then tries `session/new` which errors out because `HERMES_HOME` points at an empty dir. The error surfaces as a `.system` turn.

- [ ] **Step 5: Also run BUILD-CHECK to confirm the rest of the app still compiles.**

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  xcodebuild -project tiptour-macos.xcodeproj -scheme tiptour-macos \
             -configuration Debug build 2>&1 | tail -3
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit.**

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  git add TipTour/Hermes/HermesClient.swift TipTourTests/HermesClientTests.swift && \
  git commit -m "feat(hermes): subprocess launch + initialize + session/new

First HermesClient.send call lazy-launches the bundled Python
runtime, runs the ACP handshake, captures a sessionId. Hermes
errors during the handshake surface as a .system chat turn rather
than throwing. session/prompt arrives in the next task."
```

---

## Task 6: `session/prompt` + agent reply text

**Files:**
- Modify: `TipTour/Hermes/HermesClient.swift`
- Modify: `TipTourTests/HermesClientTests.swift`

- [ ] **Step 1: Append the round-trip test to `HermesClientTests.swift`.**

```swift
    /// Helper: returns true iff Hermes is configured locally —
    /// ~/.hermes/config.yaml exists AND a provider key is in env.
    /// Matches Tests/Python/smoke_test_acp.py's gate.
    private func hermesConfiguredLocally() -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let configExists = FileManager.default.fileExists(
            atPath: home.appendingPathComponent(".hermes/config.yaml").path
        )
        let keys = ["GEMINI_API_KEY", "OPENAI_API_KEY", "ANTHROPIC_API_KEY"]
        let hasKey = keys.contains { ProcessInfo.processInfo.environment[$0] != nil }
        return configExists && hasKey
    }

    @MainActor
    func testLiveAgentRoundTripProducesAgentTurn() async throws {
        try XCTSkipUnless(hermesConfiguredLocally(),
                          "Hermes not configured locally (no ~/.hermes/config.yaml or no provider key in env)")
        let client = HermesClient()
        await client.send("Reply with the single word 'pong'.")
        // Find at least one .agent turn.
        let agentTurn = client.transcript.first { turn in
            if case .agent = turn { return true } else { return false }
        }
        XCTAssertNotNil(agentTurn, "no agent turn appeared in transcript")
        if case .agent(_, let text, _) = agentTurn {
            XCTAssertFalse(text.isEmpty)
        }
        XCTAssertFalse(client.isWorking)
        client.stop()
    }
```

- [ ] **Step 2: Run the new test — should fail because `send` returns after handshake without sending a prompt.**

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  xcodebuild -project tiptour-macos.xcodeproj -scheme tiptour-macos \
             -configuration Debug test \
             -only-testing:tiptour-macosTests/HermesClientTests/testLiveAgentRoundTripProducesAgentTurn 2>&1 | tail -5
```
Expected: `Test Case ... failed` with `no agent turn appeared in transcript`, OR `XCTSkipUnless` triggers (if you haven't configured Hermes yet — that's also OK, just means the test is correctly gated).

- [ ] **Step 3: Replace `send` and `handleFrame` in `HermesClient.swift` to add prompt handling.**

Update the body of `send`:

```swift
    func send(_ userText: String) async {
        transcript.append(.user(id: UUID(), text: userText))

        if sessionId == nil {
            isWorking = true
            do {
                try await launchSubprocessIfNeeded()
                try await initializeHandshake()
                try await openSession()
            } catch {
                isWorking = false
                appendSystemError(error)
                return
            }
        }

        // Set up the in-progress agent turn buffer before sending the prompt.
        currentAgentTurn = (id: UUID(), text: "", toolCalls: [])
        isWorking = true

        guard let sid = sessionId else {
            // Should be unreachable: the handshake above either populated
            // sessionId or threw and returned. Defensive guard for the
            // case where session reuse logic gets added later.
            isWorking = false
            appendSystemError(HermesClientError.subprocessGone)
            return
        }

        let req = PromptRequest(sessionId: sid, prompt: [TextBlock(text: userText)])
        do {
            let _: PromptResult = try await sendRequest(method: "session/prompt", params: req)
            commitCurrentAgentTurn()
            isWorking = false
        } catch {
            currentAgentTurn = nil
            isWorking = false
            appendSystemError(error)
        }
    }
```

Add the in-progress agent turn state and the commit helper. Insert these into the "Internal state" section:

```swift
    /// Buffer for the agent turn currently being assembled from
    /// session/update notifications. Pushed into `transcript` when the
    /// session/prompt response arrives.
    private var currentAgentTurn: (id: UUID, text: String, toolCalls: [ToolCallRecord])?

    private func commitCurrentAgentTurn() {
        guard let t = currentAgentTurn else { return }
        transcript.append(.agent(id: t.id, text: t.text, toolCalls: t.toolCalls))
        currentAgentTurn = nil
    }
```

Update `handleFrame` to dispatch notifications:

```swift
    private func handleFrame(_ line: Data) {
        guard let envelope = try? JSONDecoder().decode(FrameEnvelope.self, from: line) else {
            return
        }
        if let method = envelope.method, envelope.id == nil {
            // Server-to-client notification — typically session/update.
            handleNotification(method: method, line: line)
        } else if envelope.method == nil, let id = envelope.id {
            // Response to a request we made.
            if let cont = pendingResponses.removeValue(forKey: id) {
                cont.resume(returning: line)
            }
        } else if envelope.method != nil, envelope.id != nil {
            // Server-to-client REQUEST (e.g. session/request_permission).
            // Task 7 implements the auto-allow response.
        }
    }

    private func handleNotification(method: String, line: Data) {
        guard method == "session/update" else { return }
        struct NotifEnvelope: Decodable { let params: SessionUpdateNotification }
        guard let notif = try? JSONDecoder().decode(NotifEnvelope.self, from: line) else {
            return
        }
        applySessionUpdate(notif.params.update)
    }

    private func applySessionUpdate(_ update: SessionUpdate) {
        guard currentAgentTurn != nil else { return }
        switch update {
        case .agentMessageChunk(let text):
            currentAgentTurn?.text.append(text)
        case .userMessageChunk:
            break       // echoes of the user's own input; nothing to do
        case .toolCallStart, .toolCallProgress, .toolCallEnd:
            break       // Task 7
        case .availableCommandsUpdate, .usageUpdate, .unknown:
            break
        }
    }
```

- [ ] **Step 4: Run the live round-trip test.**

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  xcodebuild -project tiptour-macos.xcodeproj -scheme tiptour-macos \
             -configuration Debug test \
             -only-testing:tiptour-macosTests/HermesClientTests/testLiveAgentRoundTripProducesAgentTurn 2>&1 | \
  grep -E '^\*\* (TEST|BUILD) (SUCCEEDED|FAILED)|Test Case.*(passed|failed|Skipped)'
```
Expected: one `Test Case ... passed` if Hermes is configured + an env var is set. If `Skipped`, that's also acceptable for this commit — re-run after configuring Hermes to confirm.

- [ ] **Step 5: Re-run the older tests so we know we didn't regress.**

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  xcodebuild -project tiptour-macos.xcodeproj -scheme tiptour-macos \
             -configuration Debug test \
             -only-testing:tiptour-macosTests/HermesClientTests 2>&1 | \
  grep -E '^\*\* (TEST|BUILD) (SUCCEEDED|FAILED)|Test Case.*(passed|failed|Skipped)'
```
Expected: `testNewClientHasEmptyState` + `testFirstSendWithMissingConfigSurfacesSystemTurn` pass; round-trip test passes or skipped depending on env.

- [ ] **Step 6: Commit.**

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  git add TipTour/Hermes/HermesClient.swift TipTourTests/HermesClientTests.swift && \
  git commit -m "feat(hermes): session/prompt round-trip with text-only agent reply"
```

---

## Task 7: Tool-call notification handling + auto-allow permission requests

**Files:**
- Modify: `TipTour/Hermes/HermesClient.swift`
- Modify: `TipTourTests/HermesClientTests.swift`

Adds two pieces:
1. Maintain `ToolCallRecord` entries on the in-progress agent turn as `tool_call_start/progress/end` notifications arrive.
2. Respond `allow` to every `session/request_permission` server-initiated request.

- [ ] **Step 1: Append the tool-using test.**

```swift
    @MainActor
    func testLiveToolUsingPromptPopulatesToolCalls() async throws {
        try XCTSkipUnless(hermesConfiguredLocally(),
                          "Hermes not configured locally")
        let client = HermesClient()
        await client.send("Use the shell tool to print 'plan2 ok'. Do not summarise.")
        let agent = client.transcript.first { if case .agent = $0 { return true } else { return false } }
        XCTAssertNotNil(agent)
        if case .agent(_, _, let toolCalls) = agent {
            XCTAssertFalse(toolCalls.isEmpty,
                           "expected at least one tool call when prompted to use a tool")
        }
        client.stop()
    }
```

- [ ] **Step 2: Run it — should fail (empty toolCalls).**

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  xcodebuild -project tiptour-macos.xcodeproj -scheme tiptour-macos \
             -configuration Debug test \
             -only-testing:tiptour-macosTests/HermesClientTests/testLiveToolUsingPromptPopulatesToolCalls 2>&1 | tail -5
```
Expected: `Test Case ... failed` with "expected at least one tool call" (or `Skipped` without local config).

- [ ] **Step 3: Implement tool-call accumulation and the auto-allow handler.**

Replace `applySessionUpdate` and the `handleFrame` server-request branch:

```swift
    private func applySessionUpdate(_ update: SessionUpdate) {
        guard currentAgentTurn != nil else { return }
        switch update {
        case .agentMessageChunk(let text):
            currentAgentTurn?.text.append(text)

        case .userMessageChunk:
            break

        case .toolCallStart(let id, let name, let args, _):
            let preview = Self.makeArgsPreview(name: name, args: args)
            let full = Self.makeArgsFull(args: args)
            let record = ToolCallRecord(
                id: id, name: name,
                argsPreview: preview, argsFull: full,
                status: .pending
            )
            currentAgentTurn?.toolCalls.append(record)

        case .toolCallProgress(let id, let status, _):
            updateToolCallStatus(id: id, hermesStatus: status)

        case .toolCallEnd(let id, let status):
            updateToolCallStatus(id: id, hermesStatus: status)

        case .availableCommandsUpdate, .usageUpdate, .unknown:
            break
        }
    }

    private func updateToolCallStatus(id: String, hermesStatus: String) {
        guard var turn = currentAgentTurn,
              let idx = turn.toolCalls.firstIndex(where: { $0.id == id }) else { return }
        let mapped: ToolCallRecord.Status
        switch hermesStatus.lowercased() {
        case "completed", "success", "ok": mapped = .completed
        case "failed", "error":            mapped = .failed
        default:                           mapped = .pending
        }
        turn.toolCalls[idx].status = mapped
        currentAgentTurn = turn
    }

    private static func makeArgsPreview(name: String, args: JSONValue) -> String {
        // Compact `name(key=val, …)` summary. Keep it short — full args
        // are available in argsFull.
        guard case .object(let dict) = args else { return "\(name)(…)" }
        let parts = dict.prefix(2).map { key, value -> String in
            let v = preview(of: value)
            return "\(key)=\(v)"
        }
        let suffix = dict.count > 2 ? ", …" : ""
        return "\(name)(\(parts.joined(separator: ", "))\(suffix))"
    }

    private static func preview(of value: JSONValue) -> String {
        switch value {
        case .string(let s):
            let trimmed = s.count > 40 ? String(s.prefix(40)) + "…" : s
            return "\"\(trimmed)\""
        case .number(let n):  return "\(n)"
        case .bool(let b):    return "\(b)"
        case .null:           return "null"
        case .array(let a):   return "[…\(a.count) items]"
        case .object:         return "{…}"
        }
    }

    private static func makeArgsFull(args: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(args),
              let text = String(data: data, encoding: .utf8)
        else { return "(unrepresentable)" }
        return text
    }
```

Update `handleFrame`'s server-request branch to respond to `session/request_permission`:

```swift
    private func handleFrame(_ line: Data) {
        guard let envelope = try? JSONDecoder().decode(FrameEnvelope.self, from: line) else {
            return
        }
        if let method = envelope.method, envelope.id == nil {
            handleNotification(method: method, line: line)
        } else if envelope.method == nil, let id = envelope.id {
            if let cont = pendingResponses.removeValue(forKey: id) {
                cont.resume(returning: line)
            }
        } else if let method = envelope.method, let id = envelope.id {
            // Server-initiated request. The only one we expect today is
            // session/request_permission. Auto-allow for Plan 2; Plan 4
            // replaces this with real approval UI.
            handleServerRequest(id: id, method: method, line: line)
        }
    }

    private func handleServerRequest(id: String, method: String, line: Data) {
        guard method == "session/request_permission" else {
            // Unknown server-initiated request — reply with method_not_found
            // so Hermes doesn't hang waiting.
            writeMethodNotFound(id: id, method: method)
            return
        }
        // Parse the tool name (best-effort) for logging.
        var toolName = "<unknown>"
        if let any = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
           let params = any["params"] as? [String: Any],
           let tc = params["toolCall"] as? [String: Any],
           let name = tc["name"] as? String {
            toolName = name
        }
        NSLog("⚠️ auto-allowed: %@", toolName)
        let resp = PermissionResponse(outcome: PermissionOutcome(outcome: "selected", optionId: "allow"))
        writeResponse(id: id, result: resp)
    }

    private func writeResponse<R: Encodable>(id: String, result: R) {
        struct Envelope<R: Encodable>: Encodable {
            let jsonrpc = "2.0"
            let id: String
            let result: R
        }
        let env = Envelope(id: id, result: result)
        if let data = try? JSONEncoder().encode(env),
           let stdin = stdinPipe?.fileHandleForWriting {
            try? stdin.write(contentsOf: data + Data("\n".utf8))
        }
    }

    private func writeMethodNotFound(id: String, method: String) {
        struct Err: Encodable { let code = -32601; let message: String }
        struct Envelope: Encodable {
            let jsonrpc = "2.0"
            let id: String
            let error: Err
        }
        let env = Envelope(id: id, error: Err(message: "method_not_found: \(method)"))
        if let data = try? JSONEncoder().encode(env),
           let stdin = stdinPipe?.fileHandleForWriting {
            try? stdin.write(contentsOf: data + Data("\n".utf8))
        }
    }
```

- [ ] **Step 4: Run the tool-using test.**

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  xcodebuild -project tiptour-macos.xcodeproj -scheme tiptour-macos \
             -configuration Debug test \
             -only-testing:tiptour-macosTests/HermesClientTests/testLiveToolUsingPromptPopulatesToolCalls 2>&1 | \
  grep -E '^\*\* (TEST|BUILD) (SUCCEEDED|FAILED)|Test Case.*(passed|failed|Skipped)'
```
Expected: one `Test Case ... passed` (or `Skipped` without local config).

- [ ] **Step 5: If the test passes but `toolCalls` is empty, the live tool-call `sessionUpdate` discriminator strings differ from our guesses. Diagnose by adding a one-shot logging line in `applySessionUpdate`'s `.unknown(raw:)` case:**

```swift
        case .unknown(let raw):
            NSLog("[HermesClient] unknown sessionUpdate: %@", String(describing: raw))
```

Re-run the test, watch the test target's console output (`xcrun simctl spawn booted log stream` or just run from Xcode UI) for the `unknown sessionUpdate:` lines, then update the `switch kind` arms in `HermesACPProtocol.swift`'s `SessionUpdate.init(from:)` to match the real discriminator strings. Re-run; remove the `NSLog`. Commit any spec updates alongside the fix.

- [ ] **Step 6: Re-run all `HermesClientTests`.**

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  xcodebuild -project tiptour-macos.xcodeproj -scheme tiptour-macos \
             -configuration Debug test \
             -only-testing:tiptour-macosTests/HermesClientTests 2>&1 | \
  grep -E '^\*\* (TEST|BUILD) (SUCCEEDED|FAILED)|Test Case.*(passed|failed|Skipped)'
```
Expected: 4 tests, all pass or appropriately skipped.

- [ ] **Step 7: Commit.**

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  git add TipTour/Hermes/HermesClient.swift TipTourTests/HermesClientTests.swift && \
  test -n "$(git status --porcelain TipTour/Hermes/HermesACPProtocol.swift)" && \
    git add TipTour/Hermes/HermesACPProtocol.swift
  git commit -m "feat(hermes): tool-call records on agent turns + auto-allow permissions

session/update notifications with tool_call_{start,progress,end}
populate ToolCallRecord entries on the in-progress agent turn.
session/request_permission auto-responds with allow and logs
'⚠️ auto-allowed: <tool>' to NSLog — Plan 4 replaces this."
```

---

## Task 8: Idempotent `stop()` with SIGTERM → SIGINT → SIGKILL escalation

**Files:**
- Modify: `TipTour/Hermes/HermesClient.swift`
- Modify: `TipTourTests/HermesClientTests.swift`

- [ ] **Step 1: Append the idempotency + cleanup test.**

```swift
    @MainActor
    func testStopIsIdempotentAndKillsTheProcess() async throws {
        let client = HermesClient()
        // Trigger subprocess launch even in the missing-config case —
        // the failure path still leaves no process running; the happy
        // path leaves one we then stop.
        await client.send("any text")
        let beforeStop = countHermesProcesses()
        client.stop()
        // After stop, wait briefly for the OS to reap.
        try await Task.sleep(nanoseconds: 500_000_000)
        let afterStop = countHermesProcesses()
        XCTAssertLessThanOrEqual(afterStop, beforeStop,
            "stop() did not reduce hermes-runtime process count (was \(beforeStop), now \(afterStop))")
        // Calling stop() again should be a no-op.
        client.stop()
        client.stop()
    }

    private func countHermesProcesses() -> Int {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "ps ax | grep -v grep | grep -c 'hermes-runtime' || true"]
        let out = Pipe()
        task.standardOutput = out
        try? task.run()
        task.waitUntilExit()
        let data = out.fileHandleForReading.availableData
        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "0"
        return Int(text) ?? 0
    }
```

- [ ] **Step 2: Run the test — it may pass already if Task 5's stop() worked, but the SIGTERM-only escalation could miss tougher orphans.**

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  xcodebuild -project tiptour-macos.xcodeproj -scheme tiptour-macos \
             -configuration Debug test \
             -only-testing:tiptour-macosTests/HermesClientTests/testStopIsIdempotentAndKillsTheProcess 2>&1 | \
  grep -E '^\*\* (TEST|BUILD) (SUCCEEDED|FAILED)|Test Case.*(passed|failed)'
```
Expected: pass. If it fails because afterStop > 0, Task 5's `terminate() + 2s sleep` wasn't enough — Step 3 below adds the escalation.

- [ ] **Step 3: Replace `stop()` in `HermesClient.swift` with the SIGTERM → SIGINT → SIGKILL escalation.**

```swift
    func stop() {
        guard let proc = process else {
            sessionId = nil
            currentAgentTurn = nil
            return
        }
        defer {
            process = nil
            stdinPipe = nil
            stdoutPipe = nil
            stderrPipe = nil
            sessionId = nil
            currentAgentTurn = nil
            pendingResponses.values.forEach {
                $0.resume(throwing: HermesClientError.subprocessGone)
            }
            pendingResponses.removeAll()
        }
        if !proc.isRunning { return }
        proc.terminate()               // SIGTERM
        if waitForExit(proc, seconds: 2) { return }
        proc.interrupt()               // SIGINT
        if waitForExit(proc, seconds: 1) { return }
        kill(proc.processIdentifier, SIGKILL)   // last resort
        _ = waitForExit(proc, seconds: 1)
    }

    private func waitForExit(_ proc: Process, seconds: Double) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while proc.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        return !proc.isRunning
    }
```

- [ ] **Step 4: Run the idempotency test again.**

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  xcodebuild -project tiptour-macos.xcodeproj -scheme tiptour-macos \
             -configuration Debug test \
             -only-testing:tiptour-macosTests/HermesClientTests/testStopIsIdempotentAndKillsTheProcess 2>&1 | \
  grep -E '^\*\* (TEST|BUILD) (SUCCEEDED|FAILED)|Test Case.*(passed|failed)'
```
Expected: pass.

- [ ] **Step 5: Run ALL HermesClientTests + HermesBundleTests as a regression gate.**

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  xcodebuild -project tiptour-macos.xcodeproj -scheme tiptour-macos \
             -configuration Debug test \
             -only-testing:tiptour-macosTests/HermesClientTests \
             -only-testing:tiptour-macosTests/HermesBundleTests 2>&1 | \
  grep -E '^\*\* (TEST|BUILD) (SUCCEEDED|FAILED)|Test Case.*(passed|failed|Skipped)'
```
Expected: all 7 tests (4 HermesClient + 3 HermesBundle) pass or appropriately skipped.

- [ ] **Step 6: Commit.**

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  git add TipTour/Hermes/HermesClient.swift TipTourTests/HermesClientTests.swift && \
  git commit -m "feat(hermes): stop() idempotent with SIGTERM→SIGINT→SIGKILL escalation"
```

---

## Task 9: SwiftUI chat view (`HermesChatWindow.swift`)

**Files:**
- Create: `TipTour/Hermes/HermesChatWindow.swift`

No XCTest for this — the SwiftUI view is hand-verified in the .app at Task 12. Build-only gate.

- [ ] **Step 1: Create `TipTour/Hermes/HermesChatWindow.swift`.**

```swift
// TipTour/Hermes/HermesChatWindow.swift
//
// Floating NSWindow + SwiftUI view that hosts the Plan-2 dev chat.
// Closing the window terminates the bundled Python subprocess via
// HermesClient.stop().

import AppKit
import SwiftUI

@MainActor
func makeHermesChatWindow(client: HermesClient, onClose: @escaping () -> Void) -> NSWindow {
    let hosting = NSHostingController(rootView: HermesChatView(client: client))
    let window = HermesChatWindow(contentViewController: hosting)
    window.title = "Hermes Debug"
    window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
    window.setContentSize(NSSize(width: 480, height: 360))
    window.level = .floating
    window.isReleasedWhenClosed = false
    window.closeHandler = onClose
    return window
}

final class HermesChatWindow: NSWindow {
    var closeHandler: (() -> Void)?

    override func close() {
        closeHandler?()
        super.close()
    }
}

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
                    .textFieldStyle(.roundedBorder)
                Button("Send", action: send)
                    .keyboardShortcut(.return, modifiers: [])
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

struct ChatTurnRow: View {
    let turn: HermesClient.ChatTurn

    var body: some View {
        switch turn {
        case .user(_, let text):
            HStack {
                Spacer(minLength: 40)
                Text(text)
                    .padding(10)
                    .background(Color.accentColor.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        case .agent(_, let text, let toolCalls):
            VStack(alignment: .leading, spacing: 6) {
                Text(text)
                    .padding(10)
                    .background(Color.secondary.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !toolCalls.isEmpty {
                    ForEach(toolCalls) { record in
                        ToolCallRow(record: record)
                            .padding(.leading, 12)
                    }
                }
            }
        case .system(_, let text):
            Text(text)
                .italic()
                .font(.callout)
                .foregroundStyle(text.hasPrefix("Hermes error:") ? Color.red : Color.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}

struct ToolCallRow: View {
    let record: HermesClient.ToolCallRecord
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ScrollView(.horizontal) {
                Text(record.argsFull)
                    .font(.system(.caption, design: .monospaced))
                    .padding(8)
            }
            .background(Color.secondary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        } label: {
            HStack(spacing: 6) {
                Text("▸")
                Text(record.argsPreview)
                    .font(.system(.caption, design: .monospaced))
                Spacer()
                Text(record.status.rawValue)
                    .font(.caption2)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(statusBackground)
                    .clipShape(Capsule())
            }
        }
        .font(.caption)
    }

    private var statusBackground: Color {
        switch record.status {
        case .pending:   return Color.yellow.opacity(0.25)
        case .completed: return Color.green.opacity(0.25)
        case .failed:    return Color.red.opacity(0.25)
        }
    }
}
```

- [ ] **Step 2: BUILD-CHECK.**

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  xcodebuild -project tiptour-macos.xcodeproj -scheme tiptour-macos \
             -configuration Debug build 2>&1 | tail -3
```
Expected: `** BUILD SUCCEEDED **`. If a SwiftUI API is unavailable on the macOS target, adapt the smallest piece — the file uses standard SwiftUI APIs available on macOS 12+.

- [ ] **Step 3: Commit.**

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  git add TipTour/Hermes/HermesChatWindow.swift && \
  git commit -m "feat(hermes): floating chat window + SwiftUI HermesChatView"
```

---

## Task 10: `HermesDebugMenuController` — standalone status item + chat window owner

**Files:**
- Create: `TipTour/Hermes/HermesDebugMenuController.swift`

- [ ] **Step 1: Create the controller.**

```swift
// TipTour/Hermes/HermesDebugMenuController.swift
//
// Owns the second menu-bar status item ("Hermes" with a debug menu)
// plus the chat window and a single HermesClient instance. Standalone
// from MenuBarPanelManager so it can be removed cleanly when Plan 3
// folds Hermes into the user-facing surface.

import AppKit

@MainActor
final class HermesDebugMenuController: NSObject {
    private var statusItem: NSStatusItem?
    private var window: NSWindow?
    private let client = HermesClient()

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "🛠 Hermes"
        item.button?.toolTip = "Hermes Debug"

        let menu = NSMenu()

        let header = NSMenuItem(title: "Hermes Debug", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let talk = NSMenuItem(title: "Talk to Hermes…", action: #selector(openChat), keyEquivalent: "h")
        talk.keyEquivalentModifierMask = [.command, .shift]
        talk.target = self
        menu.addItem(talk)

        item.menu = menu
        self.statusItem = item
    }

    @objc private func openChat() {
        if window == nil {
            window = makeHermesChatWindow(client: client) { [weak self] in
                // windowWillClose: terminate subprocess so closing the
                // window actually frees ~400 MB of Python runtime.
                self?.client.stop()
                self?.window = nil
            }
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
```

- [ ] **Step 2: BUILD-CHECK.**

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  xcodebuild -project tiptour-macos.xcodeproj -scheme tiptour-macos \
             -configuration Debug build 2>&1 | tail -3
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit.**

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  git add TipTour/Hermes/HermesDebugMenuController.swift && \
  git commit -m "feat(hermes): standalone status item + Hermes Debug menu"
```

---

## Task 11: Wire `HermesDebugMenuController` into `TipTourApp`

**Files:**
- Modify: `TipTour/TipTourApp.swift`

- [ ] **Step 1: View the current launch site.**

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  sed -n '28,70p' TipTour/TipTourApp.swift
```
Locate the `CompanionAppDelegate` class and `applicationDidFinishLaunching` method.

- [ ] **Step 2: Add the controller property + initialization.**

Edit `TipTour/TipTourApp.swift`:

In the `CompanionAppDelegate` class, after `private var menuBarPanelManager: MenuBarPanelManager?`, add:

```swift
    private var hermesDebugMenu: HermesDebugMenuController?
```

In `applicationDidFinishLaunching(_:)`, after `menuBarPanelManager = MenuBarPanelManager(companionManager: companionManager)`, add:

```swift
        hermesDebugMenu = HermesDebugMenuController()
        hermesDebugMenu?.install()
```

- [ ] **Step 3: BUILD-CHECK.**

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  xcodebuild -project tiptour-macos.xcodeproj -scheme tiptour-macos \
             -configuration Debug build 2>&1 | tail -3
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Run the full app test suite as a regression gate.**

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  xcodebuild -project tiptour-macos.xcodeproj -scheme tiptour-macos \
             -configuration Debug test \
             -only-testing:tiptour-macosTests/HermesBundleTests \
             -only-testing:tiptour-macosTests/HermesACPProtocolTests \
             -only-testing:tiptour-macosTests/HermesClientTests 2>&1 | \
  grep -E '^\*\* (TEST|BUILD) (SUCCEEDED|FAILED)|Test Case.*(passed|failed|Skipped)' | head -20
```
Expected: all green or appropriately skipped.

- [ ] **Step 5: Commit.**

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  git add TipTour/TipTourApp.swift && \
  git commit -m "feat(hermes): install Hermes Debug status item from app delegate"
```

---

## Task 12: Manual end-to-end verification + acceptance gate

This task introduces no edits. It runs the acceptance criteria from spec section 5.

- [ ] **Step 1: BUILD-CHECK.** Expected `** BUILD SUCCEEDED **`.

- [ ] **Step 2: Full test run.**

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  xcodebuild -project tiptour-macos.xcodeproj -scheme tiptour-macos \
             -configuration Debug test 2>&1 | \
  grep -E '^\*\* (TEST|BUILD) (SUCCEEDED|FAILED)|Test Case.*(passed|failed|Skipped)' | head -30
```
Expected: all `HermesBundleTests`, `HermesACPProtocolTests`, and `HermesClientTests` pass or are appropriately skipped.

- [ ] **Step 3: SMOKE-CHECK.** Plan 1's Python canary must still pass.

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  PYTHONUNBUFFERED=1 ./Tests/Python/smoke_test_acp.py | head -8
```
Expected: `PASS (phase 1)`, exit 0. (If you have Hermes configured locally + an API key in env, expect `PASS` with the full prompt cycle.)

- [ ] **Step 4: Launch the .app and visually verify the menu and chat.**

```bash
APP=$(find ~/Library/Developer/Xcode/DerivedData -name 'TipTour_Hermes.app' -path '*/Debug/*' 2>/dev/null | head -1) && \
  echo "App: $APP" && \
  open "$APP"
```

Then in the running app:
- [ ] Confirm the second status-bar item with "🛠 Hermes" label appears.
- [ ] Click it. The "Hermes Debug" menu shows "Talk to Hermes…" with ⌘⇧H shortcut.
- [ ] Click "Talk to Hermes…" (or press ⌘⇧H). A floating window opens with empty transcript and a text input row.
- [ ] Type `Reply with the single word 'pong'.` and press Enter. Within ≈3s a user bubble and an agent bubble appear; agent bubble contains `pong`.
- [ ] Type `Use a shell tool to print 'plan2 ok'. Do not summarise.` and press Enter. Within ≈10s, an agent turn appears that includes at least one collapsible tool-call row. Click the row's disclosure triangle to expand args.
- [ ] Close the chat window.
- [ ] Run `ps ax | grep -v grep | grep hermes-runtime` in a terminal. Expected: zero matches.

- [ ] **Step 5: Verify acceptance criterion 7 (missing-config UX) manually.**

```bash
APP=$(find ~/Library/Developer/Xcode/DerivedData -name 'TipTour_Hermes.app' -path '*/Debug/*' 2>/dev/null | head -1) && \
  HERMES_HOME=/tmp/empty-hermes-home-$$ && mkdir -p "$HERMES_HOME" && \
  env -i PATH=$PATH HERMES_HOME="$HERMES_HOME" open -a "$APP" --args
```

In the relaunched app:
- [ ] Open the chat window, type `hi`, press Enter.
- [ ] Expect a red `.system` turn appearing within ≈2s with `Hermes error: …provider…` text.
- [ ] Window remains usable (you can type a second message).

Quit the app afterwards.

- [ ] **Step 6: No additional commit needed.** Plan 2 is complete when all 5 verification steps pass.

---

## Rollback procedure

If a task breaks something irrecoverably, restore the Plan-2-start state:

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  git status --short && \
  git reset --hard pre-plan-2
```

Per-task rollback: each task's commit is independently revertable via `git revert <sha>`.

---

## Acceptance criteria

Plan 2 is done when ALL of these are true:

1. `xcodebuild build` exits 0 with `** BUILD SUCCEEDED **`.
2. `xcodebuild test -only-testing:tiptour-macosTests/HermesBundleTests` reports `** TEST SUCCEEDED **`.
3. `xcodebuild test -only-testing:tiptour-macosTests/HermesACPProtocolTests` reports `** TEST SUCCEEDED **` with 9 passing test cases.
4. `xcodebuild test -only-testing:tiptour-macosTests/HermesClientTests` reports `** TEST SUCCEEDED **` with 4 passing (or up to 2 appropriately skipped) test cases.
5. `./Tests/Python/smoke_test_acp.py` exits 0 with `PASS (phase 1)` minimum.
6. Launching `TipTour_Hermes.app` shows a second menu-bar status item labeled "🛠 Hermes". Clicking it reveals "Talk to Hermes…" with ⌘⇧H shortcut. Selecting the item opens a floating window.
7. In the chat window, sending "Reply with 'pong'." produces an agent bubble containing "pong" within ≈3s on Claude Haiku 4.5 (assumes the user's existing `~/.hermes/config.yaml` + `ANTHROPIC_API_KEY`).
8. Sending a tool-using prompt produces an agent turn with at least one collapsible tool-call row.
9. Closing the chat window terminates the bundled Python subprocess. `ps ax | grep hermes-runtime` shows zero matches afterwards.
10. With `HERMES_HOME` pointing at an empty dir, the first send produces a red `.system` turn with Hermes's verbatim error rather than hanging.

Once green, the next plan is **Plan 3 — Mac-side MCP server + voice/overlay integration**, which fills in the 15 `TODO(plan-2)` markers left in `CompanionManager.swift` / `GeminiLiveSession.swift` / `CompanionPanelView.swift`.
