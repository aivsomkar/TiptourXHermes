# Plan 3a — MCP Framework + `speak` Tool — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a Swift in-process MCP server inside `TipTour_Hermes.app` and expose a single `speak(text)` tool to Hermes via `session/new`'s `mcpServers` parameter. End state: typing "say hello via the speak tool" in the Plan-2 dev chat produces an audible Mac speech response and a `▸ speak(text="hello") [completed]` row in the transcript.

**Architecture:** A new `MCPServer` class wraps `Network.framework`'s `NWListener` to expose `POST /mcp` on a random loopback port. A minimal JSON-RPC dispatcher handles `initialize`, `notifications/initialized`, `tools/list`, and `tools/call`. Tool implementations conform to a small `MCPTool` protocol; `SpeakTool` uses `AVSpeechSynthesizer` for fire-and-forget speech. `HermesDebugMenuController` owns the server, starts it when the chat window opens, and tears it down on close.

**Tech Stack:** Swift 5, Foundation, Network.framework (`NWListener`/`NWConnection`), AVFoundation (`AVSpeechSynthesizer`), AppKit. Tests in XCTest. Zero new external dependencies.

**Spec:** [docs/superpowers/specs/2026-05-13-plan-3a-mcp-framework-and-speak-tool-design.md](../specs/2026-05-13-plan-3a-mcp-framework-and-speak-tool-design.md)

---

## File-structure summary

**New Swift source files (all in `TipTour/Hermes/`):**

- `MCPTools.swift` — `MCPTool` protocol + `MCPToolError` enum + `SpeakTool` implementation.
- `MCPServer.swift` — `MCPServer` class with `NWListener`, HTTP/1.1 parser, JSON-RPC dispatcher, and tool registry.

**Modified Swift source files:**

- `TipTour/Hermes/HermesACPProtocol.swift` — add `HttpMcpServerEntry` + `HttpHeader` Encodable types; change `NewSessionRequest.mcpServers` from `[JSONValue]` to `[HttpMcpServerEntry]`.
- `TipTour/Hermes/HermesClient.swift` — add `var mcpServerURL: URL?`; `openSession()` builds the one-entry array when the URL is set.
- `TipTour/Hermes/HermesDebugMenuController.swift` — own a `MCPServer` instance; register `SpeakTool` in `install()`; start the server in `openChat()`; stop it in `windowWillClose()`.

**New test files:**

- `TipTourTests/MCPToolsTests.swift` — unit tests for `SpeakTool.call()` with valid + invalid arguments.
- `TipTourTests/MCPServerTests.swift` — 4 end-to-end tests (start/stop, initialize, tools/list, tools/call) against a live `MCPServer` over loopback HTTP.

**Files this plan deliberately does NOT modify:**

- `Tests/Python/smoke_test_acp.py` — Plan 1 canary stays as-is.
- `HermesBundleTests.swift`, `HermesACPProtocolTests.swift`, `HermesClientTests.swift` — Plan 1/2 canaries stay as-is.
- The 15 `TODO(plan-2)` markers in `CompanionManager` / `GeminiLiveSession` / `CompanionPanelView` — Plan 3c.

## Verification commands used throughout

**BUILD-CHECK:**
```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  xcodebuild -project tiptour-macos.xcodeproj -scheme tiptour-macos \
             -configuration Debug build 2>&1 | tail -3
```
Expected: last line is `** BUILD SUCCEEDED **`.

**MCP-TOOL-TESTS-CHECK:**
```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  xcodebuild -project tiptour-macos.xcodeproj -scheme tiptour-macos \
             -configuration Debug test \
             -only-testing:tiptour-macosTests/MCPToolsTests 2>&1 | \
  grep -E '^\*\* (TEST|BUILD) (SUCCEEDED|FAILED)'
```

**MCP-SERVER-TESTS-CHECK:**
```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  xcodebuild -project tiptour-macos.xcodeproj -scheme tiptour-macos \
             -configuration Debug test \
             -only-testing:tiptour-macosTests/MCPServerTests 2>&1 | \
  grep -E '^\*\* (TEST|BUILD) (SUCCEEDED|FAILED)'
```

**REGRESSION-GATE (Plan 1+2 canaries):**
```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  xcodebuild -project tiptour-macos.xcodeproj -scheme tiptour-macos \
             -configuration Debug test \
             -only-testing:tiptour-macosTests/HermesBundleTests \
             -only-testing:tiptour-macosTests/HermesACPProtocolTests \
             -only-testing:tiptour-macosTests/HermesClientTests 2>&1 | \
  grep -E '^\*\* (TEST|BUILD) (SUCCEEDED|FAILED)'
```
Expected: `** TEST SUCCEEDED **`.

---

## Task 1: Pre-flight rollback tag

**Files:** none (git only).

- [ ] **Step 1: Confirm clean working tree.**

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && git status --short
```
Expected: empty (or only `.claude/` untracked). Stop and resolve anything else first.

- [ ] **Step 2: Tag the current `main` head as `pre-plan-3a`.**

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  git tag pre-plan-3a && \
  git tag --list 'pre-*'
```
Expected: prints `pre-plan-2`, `pre-plan-3a`, `pre-rebrand` (and any earlier tags).

---

## Task 2: `MCPTool` protocol + `SpeakTool`

**Files:**
- Create: `TipTour/Hermes/MCPTools.swift`
- Create: `TipTourTests/MCPToolsTests.swift`

Pure-Swift types — no networking, no server. We can fully unit-test `SpeakTool.call()` without standing up the HTTP server. The speech test calls `AVSpeechSynthesizer` for real (the test machine briefly says "ok"); acceptable for a dev tool per the spec.

- [ ] **Step 1: Create the failing test file `TipTourTests/MCPToolsTests.swift`.**

```swift
import XCTest
@testable import TipTour

final class MCPToolsTests: XCTestCase {

    @MainActor
    func testSpeakToolHasExpectedMetadata() {
        let tool = SpeakTool()
        XCTAssertEqual(tool.name, "speak")
        XCTAssertFalse(tool.description.isEmpty)
        // inputSchema must declare a `text` string property and require it.
        guard case .object(let schema) = tool.inputSchema,
              case .string(let kind) = schema["type"] ?? .null,
              kind == "object",
              case .array(let required) = schema["required"] ?? .null,
              required.contains(.string("text"))
        else {
            XCTFail("speak inputSchema does not require a `text` string")
            return
        }
    }

    @MainActor
    func testSpeakToolCallReturnsSuccessForValidText() async throws {
        let tool = SpeakTool()
        let result = try await tool.call(.object(["text": .string("ok")]))
        XCTAssertTrue(result.contains("ok"))
        // No way to assert audio actually played from a unit test — the
        // success contract is that call() returns without throwing.
    }

    @MainActor
    func testSpeakToolCallRejectsMissingText() async {
        let tool = SpeakTool()
        do {
            _ = try await tool.call(.object([:]))
            XCTFail("expected throw for missing `text`")
        } catch let error as MCPToolError {
            guard case .invalidArguments = error else {
                XCTFail("expected .invalidArguments, got \(error)")
                return
            }
        } catch {
            XCTFail("expected MCPToolError, got \(error)")
        }
    }

    @MainActor
    func testSpeakToolCallRejectsEmptyText() async {
        let tool = SpeakTool()
        do {
            _ = try await tool.call(.object(["text": .string("")]))
            XCTFail("expected throw for empty `text`")
        } catch let error as MCPToolError {
            guard case .invalidArguments = error else {
                XCTFail("expected .invalidArguments, got \(error)")
                return
            }
        } catch {
            XCTFail("expected MCPToolError, got \(error)")
        }
    }
}
```

- [ ] **Step 2: Run the tests; expect a compile failure.**

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  xcodebuild -project tiptour-macos.xcodeproj -scheme tiptour-macos \
             -configuration Debug test \
             -only-testing:tiptour-macosTests/MCPToolsTests 2>&1 | tail -5
```
Expected: build fails with "Cannot find 'SpeakTool' / 'MCPToolError' in scope".

- [ ] **Step 3: Create `TipTour/Hermes/MCPTools.swift` with the protocol, error type, and `SpeakTool`.**

```swift
// TipTour/Hermes/MCPTools.swift
//
// MCP tool protocol and the Plan-3a `speak` implementation. New tools
// (Plan 3b: take_screenshot, get_a11y_tree, point_at) are added by
// conforming to MCPTool and registering with MCPServer.

import Foundation
import AVFoundation

// MARK: - Tool protocol

protocol MCPTool: Sendable {
    /// Tool identifier passed to MCP tools/list and tools/call.
    var name: String { get }
    /// Human-readable description shown to Hermes for tool selection.
    var description: String { get }
    /// JSON Schema describing the expected `arguments` object.
    var inputSchema: JSONValue { get }
    /// Run the tool. Returns a human-readable result string. Throw
    /// `MCPToolError` to indicate a tool failure; the server wraps the
    /// thrown error into `{ isError: true, content: [...] }`.
    @MainActor func call(_ arguments: JSONValue) async throws -> String
}

enum MCPToolError: Error, CustomStringConvertible {
    case invalidArguments(String)
    case toolFailed(String)

    var description: String {
        switch self {
        case .invalidArguments(let why): return "invalid arguments: \(why)"
        case .toolFailed(let why):       return "tool failed: \(why)"
        }
    }
}

// MARK: - SpeakTool

/// Speaks text aloud via AVSpeechSynthesizer using the system voice.
/// Fire-and-forget: `call()` queues the utterance and returns immediately.
@MainActor
final class SpeakTool: MCPTool {
    let name = "speak"
    let description = "Speak the given text aloud through the user's Mac using the system voice."
    let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "text": .object([
                "type": .string("string"),
                "description": .string("The text to speak aloud."),
            ])
        ]),
        "required": .array([.string("text")]),
    ])

    /// Held as a stored property so the synthesizer isn't deallocated
    /// mid-playback. AVSpeechSynthesizer queues utterances internally so
    /// rapid back-to-back calls do not conflict.
    private let synth = AVSpeechSynthesizer()

    func call(_ arguments: JSONValue) async throws -> String {
        guard case .object(let dict) = arguments,
              case .string(let text) = dict["text"] ?? .null,
              !text.isEmpty
        else {
            throw MCPToolError.invalidArguments("speak requires a non-empty `text` string")
        }

        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synth.speak(utterance)
        return "Speaking: \(text)"
    }
}
```

- [ ] **Step 4: Run the tests; expect all four to pass.**

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  xcodebuild -project tiptour-macos.xcodeproj -scheme tiptour-macos \
             -configuration Debug test \
             -only-testing:tiptour-macosTests/MCPToolsTests 2>&1 | \
  grep -E '^\*\* (TEST|BUILD) (SUCCEEDED|FAILED)'
```
Expected: `** TEST SUCCEEDED **`. (The third test causes the machine to briefly say "ok"; ignore.)

- [ ] **Step 5: Commit.**

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  git add TipTour/Hermes/MCPTools.swift TipTourTests/MCPToolsTests.swift && \
  git commit -m "feat(mcp): MCPTool protocol + SpeakTool"
```

---

## Task 3: `MCPServer` scaffold + `initialize` handler

**Files:**
- Create: `TipTour/Hermes/MCPServer.swift`
- Create: `TipTourTests/MCPServerTests.swift`

This is the heaviest task. It lands the full HTTP/1.1 + JSON-RPC + response-writer scaffold, but only routes the `initialize` method (and `notifications/initialized`). `tools/list` and `tools/call` come in Tasks 4 and 5 as small additions.

- [ ] **Step 1: Create the failing test file `TipTourTests/MCPServerTests.swift`.**

```swift
import XCTest
@testable import TipTour

final class MCPServerTests: XCTestCase {

    // MARK: - Helpers

    private func postJSON(to url: URL, body: [String: Any]) async throws -> [String: Any] {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "MCPServerTests", code: 0,
                          userInfo: [NSLocalizedDescriptionKey: "non-JSON response"])
        }
        return obj
    }

    // MARK: - Tests

    @MainActor
    func testServerStartsAndStops() throws {
        let server = MCPServer(name: "test")
        let url = try server.start()
        XCTAssertEqual(url.host, "127.0.0.1")
        XCTAssertEqual(url.path, "/mcp")
        XCTAssertNotNil(server.serverURL)
        XCTAssertGreaterThan(url.port ?? 0, 0)
        server.stop()
        XCTAssertNil(server.serverURL)
    }

    @MainActor
    func testInitializeRoundTrip() async throws {
        let server = MCPServer(name: "test")
        let url = try server.start()
        defer { server.stop() }
        let resp = try await postJSON(to: url, body: [
            "jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [:]
        ])
        XCTAssertEqual(resp["jsonrpc"] as? String, "2.0")
        XCTAssertNotNil(resp["result"])
        let result = resp["result"] as? [String: Any]
        XCTAssertEqual(result?["protocolVersion"] as? String, "2024-11-05")
        let info = result?["serverInfo"] as? [String: Any]
        XCTAssertEqual(info?["name"] as? String, "test")
    }
}
```

- [ ] **Step 2: Run the tests; expect a compile failure.**

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  xcodebuild -project tiptour-macos.xcodeproj -scheme tiptour-macos \
             -configuration Debug test \
             -only-testing:tiptour-macosTests/MCPServerTests 2>&1 | tail -5
```
Expected: build fails with "Cannot find 'MCPServer' in scope".

- [ ] **Step 3: Create `TipTour/Hermes/MCPServer.swift` with the full scaffold + `initialize` handler.**

```swift
// TipTour/Hermes/MCPServer.swift
//
// In-process MCP server bound to 127.0.0.1 on a random port. Implements
// the minimum slice of the Model Context Protocol (initialize +
// notifications/initialized + tools/list + tools/call) needed for
// Hermes's bundled `mcp==1.26.0` client to discover and invoke tools.
//
// Wire format: HTTP/1.1 with one JSON-RPC request per connection (no
// keep-alive, no SSE, no chunked transfer). All tool handlers run on
// @MainActor — required for AVSpeechSynthesizer and Plan 3b's point_at.

import Foundation
import Network

@MainActor
final class MCPServer {

    // MARK: - Public API

    init(name: String) {
        self.serverName = name
    }

    func register(_ tool: MCPTool) {
        tools[tool.name] = tool
    }

    /// Binds a random loopback port and returns the resulting MCP URL.
    /// Idempotent: returns the existing URL if already running.
    func start() throws -> URL {
        if let existing = serverURL { return existing }

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredInterfaceType = .loopback   // never exposes outside the box

        let listener = try NWListener(using: params, on: .any)
        self.listener = listener

        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.handleConnection(connection) }
        }

        let started = DispatchSemaphore(value: 0)
        var boundPort: NWEndpoint.Port?
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                boundPort = listener.port
                started.signal()
            case .failed:
                started.signal()
            default:
                break
            }
        }
        listener.start(queue: .main)

        _ = started.wait(timeout: .now() + 1)

        guard let port = boundPort else {
            listener.cancel()
            self.listener = nil
            throw MCPServerError.failedToBind
        }
        let url = URL(string: "http://127.0.0.1:\(port.rawValue)/mcp")!
        self.serverURL = url
        return url
    }

    func stop() {
        listener?.cancel()
        listener = nil
        serverURL = nil
    }

    private(set) var serverURL: URL?

    // MARK: - State

    private let serverName: String
    private let serverVersion: String = "0.1.0"
    private var tools: [String: MCPTool] = [:]
    private var listener: NWListener?

    // MARK: - Connection lifecycle

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .main)
        readRequest(on: connection, buffer: Data())
    }

    private func readRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            Task { @MainActor in
                var buffer = buffer
                if let data, !data.isEmpty { buffer.append(data) }
                if error != nil {
                    connection.cancel()
                    return
                }
                guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                    if isComplete { connection.cancel(); return }
                    self.readRequest(on: connection, buffer: buffer)
                    return
                }
                let headerBytes = buffer.subdata(in: 0..<headerEnd.lowerBound)
                let bodyStart = headerEnd.upperBound
                guard let headerText = String(data: headerBytes, encoding: .utf8) else {
                    self.respond404(on: connection); return
                }
                let (method, path, contentLength) = Self.parseRequestLine(headerText)
                let alreadyHaveBody = buffer.count - bodyStart
                if alreadyHaveBody < contentLength {
                    self.readRequest(on: connection, buffer: buffer)
                    return
                }
                let body = buffer.subdata(in: bodyStart..<(bodyStart + contentLength))

                if method == "POST", path == "/mcp" {
                    await self.dispatchRPC(body: body, on: connection)
                } else {
                    self.respond404(on: connection)
                }
            }
        }
    }

    private static func parseRequestLine(_ headerText: String) -> (method: String, path: String, contentLength: Int) {
        var method = "", path = "", contentLength = 0
        let lines = headerText.components(separatedBy: "\r\n")
        if let first = lines.first {
            let parts = first.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
            if parts.count >= 2 {
                method = String(parts[0])
                path = String(parts[1])
            }
        }
        for line in lines.dropFirst() {
            if line.lowercased().hasPrefix("content-length:") {
                let value = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
                contentLength = Int(value) ?? 0
            }
        }
        return (method, path, contentLength)
    }

    // MARK: - JSON-RPC dispatch

    private struct Envelope: Decodable {
        let jsonrpc: String?
        let id: JSONRPCID?
        let method: String?
        let params: JSONValue?
    }

    /// JSON-RPC `id` can be a string, a number, or null. Preserve the
    /// shape so responses match what the client sent.
    enum JSONRPCID: Decodable {
        case string(String)
        case number(Int)
        case null

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() { self = .null; return }
            if let s = try? c.decode(String.self) { self = .string(s); return }
            if let n = try? c.decode(Int.self) { self = .number(n); return }
            self = .null
        }

        var asJSONObject: Any {
            switch self {
            case .string(let s): return s
            case .number(let n): return n
            case .null:          return NSNull()
            }
        }
    }

    private func dispatchRPC(body: Data, on connection: NWConnection) async {
        guard let env = try? JSONDecoder().decode(Envelope.self, from: body),
              let method = env.method else {
            respondEmpty(on: connection); return
        }

        switch method {
        case "initialize":
            let result: [String: Any] = [
                "protocolVersion": "2024-11-05",
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": serverName, "version": serverVersion],
            ]
            respond(envelope: env, result: result, on: connection)

        case "notifications/initialized":
            respondEmpty(on: connection)

        default:
            respondError(envelope: env, code: -32601, message: "method not found: \(method)", on: connection)
        }
    }

    // MARK: - Response writers

    private func respond(envelope: Envelope, result: Any, on connection: NWConnection) {
        var obj: [String: Any] = ["jsonrpc": "2.0", "result": result]
        if let id = envelope.id { obj["id"] = id.asJSONObject }
        writeJSONResponse(obj, on: connection)
    }

    private func respondError(envelope: Envelope, code: Int, message: String, on connection: NWConnection) {
        var obj: [String: Any] = ["jsonrpc": "2.0", "error": ["code": code, "message": message]]
        if let id = envelope.id { obj["id"] = id.asJSONObject }
        writeJSONResponse(obj, on: connection)
    }

    private func respondEmpty(on connection: NWConnection) {
        writeStatus(204, headers: [:], body: Data(), on: connection)
    }

    private func respond404(on connection: NWConnection) {
        writeStatus(404, headers: ["Content-Type": "text/plain"],
                    body: Data("not found".utf8), on: connection)
    }

    private func writeJSONResponse(_ obj: [String: Any], on connection: NWConnection) {
        guard let body = try? JSONSerialization.data(withJSONObject: obj) else {
            respond404(on: connection); return
        }
        writeStatus(200, headers: ["Content-Type": "application/json"], body: body, on: connection)
    }

    private func writeStatus(_ status: Int, headers: [String: String], body: Data, on connection: NWConnection) {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        var headers = headers
        headers["Content-Length"] = "\(body.count)"
        headers["Connection"] = "close"
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        var packet = Data(head.utf8)
        packet.append(body)
        connection.send(content: packet, completion: .contentProcessed { _ in connection.cancel() })
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 204: return "No Content"
        case 404: return "Not Found"
        default:  return "Status"
        }
    }
}

enum MCPServerError: Error, CustomStringConvertible {
    case failedToBind

    var description: String {
        switch self {
        case .failedToBind: return "MCP server could not bind to a loopback port"
        }
    }
}
```

- [ ] **Step 4: Run the tests; expect both to pass.**

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  xcodebuild -project tiptour-macos.xcodeproj -scheme tiptour-macos \
             -configuration Debug test \
             -only-testing:tiptour-macosTests/MCPServerTests 2>&1 | \
  grep -E '^\*\* (TEST|BUILD) (SUCCEEDED|FAILED)'
```
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit.**

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  git add TipTour/Hermes/MCPServer.swift TipTourTests/MCPServerTests.swift && \
  git commit -m "feat(mcp): MCPServer scaffold + initialize handler

Loopback-only NWListener on a random port. HTTP/1.1 parser routes
POST /mcp to a JSON-RPC dispatcher. Implements initialize and
notifications/initialized; tools/list and tools/call arrive in
subsequent tasks."
```

---

## Task 4: `tools/list` handler

**Files:**
- Modify: `TipTour/Hermes/MCPServer.swift`
- Modify: `TipTourTests/MCPServerTests.swift`

Small addition — one case in the dispatcher.

- [ ] **Step 1: Append a failing test to `MCPServerTests.swift` (before the closing brace of the class).**

```swift
    @MainActor
    func testToolsListIncludesRegisteredTool() async throws {
        let server = MCPServer(name: "test")
        server.register(SpeakTool())
        let url = try server.start()
        defer { server.stop() }
        let resp = try await postJSON(to: url, body: [
            "jsonrpc": "2.0", "id": 2, "method": "tools/list"
        ])
        let result = resp["result"] as? [String: Any]
        let tools = result?["tools"] as? [[String: Any]] ?? []
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools.first?["name"] as? String, "speak")
        XCTAssertNotNil(tools.first?["description"])
        XCTAssertNotNil(tools.first?["inputSchema"])
    }
```

- [ ] **Step 2: Run the test; expect failure (method not found).**

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  xcodebuild -project tiptour-macos.xcodeproj -scheme tiptour-macos \
             -configuration Debug test \
             -only-testing:tiptour-macosTests/MCPServerTests/testToolsListIncludesRegisteredTool 2>&1 | tail -5
```
Expected: test fails because the server replies with `error: method not found: tools/list`.

- [ ] **Step 3: Add the `tools/list` case to `MCPServer.dispatchRPC` (right after the `notifications/initialized` case, before `default`).**

```swift
        case "tools/list":
            let list: [[String: Any]] = tools.values.map { tool -> [String: Any] in
                let schemaData = (try? JSONEncoder().encode(tool.inputSchema)) ?? Data()
                let schemaObject = (try? JSONSerialization.jsonObject(with: schemaData)) ?? [String: Any]()
                return [
                    "name": tool.name,
                    "description": tool.description,
                    "inputSchema": schemaObject,
                ]
            }
            respond(envelope: env, result: ["tools": list], on: connection)
```

- [ ] **Step 4: Run the test; expect pass.**

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  xcodebuild -project tiptour-macos.xcodeproj -scheme tiptour-macos \
             -configuration Debug test \
             -only-testing:tiptour-macosTests/MCPServerTests 2>&1 | \
  grep -E '^\*\* (TEST|BUILD) (SUCCEEDED|FAILED)'
```
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit.**

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  git add TipTour/Hermes/MCPServer.swift TipTourTests/MCPServerTests.swift && \
  git commit -m "feat(mcp): tools/list handler"
```

---

## Task 5: `tools/call` handler

**Files:**
- Modify: `TipTour/Hermes/MCPServer.swift`
- Modify: `TipTourTests/MCPServerTests.swift`

- [ ] **Step 1: Append a failing test to `MCPServerTests.swift`.**

```swift
    @MainActor
    func testToolsCallSpeakReturnsSuccess() async throws {
        let server = MCPServer(name: "test")
        server.register(SpeakTool())
        let url = try server.start()
        defer { server.stop() }
        let resp = try await postJSON(to: url, body: [
            "jsonrpc": "2.0", "id": 3, "method": "tools/call",
            "params": ["name": "speak", "arguments": ["text": "test"]]
        ])
        let result = resp["result"] as? [String: Any]
        XCTAssertEqual(result?["isError"] as? Bool, false)
        let content = (result?["content"] as? [[String: Any]])?.first
        XCTAssertEqual(content?["type"] as? String, "text")
        XCTAssertTrue((content?["text"] as? String ?? "").contains("test"))
    }

    @MainActor
    func testToolsCallUnknownToolReturnsError() async throws {
        let server = MCPServer(name: "test")
        let url = try server.start()
        defer { server.stop() }
        let resp = try await postJSON(to: url, body: [
            "jsonrpc": "2.0", "id": 4, "method": "tools/call",
            "params": ["name": "nope", "arguments": [:]]
        ])
        XCTAssertNotNil(resp["error"])
        let error = resp["error"] as? [String: Any]
        XCTAssertEqual(error?["code"] as? Int, -32601)
    }
```

- [ ] **Step 2: Run the tests; expect failure (method not found).**

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  xcodebuild -project tiptour-macos.xcodeproj -scheme tiptour-macos \
             -configuration Debug test \
             -only-testing:tiptour-macosTests/MCPServerTests/testToolsCallSpeakReturnsSuccess 2>&1 | tail -5
```
Expected: test fails because the server replies with `error: method not found: tools/call`.

- [ ] **Step 3: Add the `tools/call` case to `MCPServer.dispatchRPC` (right after the `tools/list` case, before `default`).**

```swift
        case "tools/call":
            guard case .object(let params) = env.params ?? .null,
                  case .string(let toolName) = params["name"] ?? .null,
                  let tool = tools[toolName]
            else {
                respondError(envelope: env, code: -32601,
                             message: "tool not found", on: connection)
                return
            }
            let arguments = params["arguments"] ?? .object([:])
            do {
                let text = try await tool.call(arguments)
                let result: [String: Any] = [
                    "content": [["type": "text", "text": text]],
                    "isError": false,
                ]
                respond(envelope: env, result: result, on: connection)
            } catch {
                let result: [String: Any] = [
                    "content": [["type": "text", "text": "\(error)"]],
                    "isError": true,
                ]
                respond(envelope: env, result: result, on: connection)
            }
```

- [ ] **Step 4: Run all `MCPServerTests`; expect pass.**

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  xcodebuild -project tiptour-macos.xcodeproj -scheme tiptour-macos \
             -configuration Debug test \
             -only-testing:tiptour-macosTests/MCPServerTests 2>&1 | \
  grep -E '^\*\* (TEST|BUILD) (SUCCEEDED|FAILED)'
```
Expected: `** TEST SUCCEEDED **`. (The test machine briefly says "test" out loud — acceptable.)

- [ ] **Step 5: Commit.**

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  git add TipTour/Hermes/MCPServer.swift TipTourTests/MCPServerTests.swift && \
  git commit -m "feat(mcp): tools/call handler"
```

---

## Task 6: `HttpMcpServerEntry` + `HermesClient.mcpServerURL` wiring

**Files:**
- Modify: `TipTour/Hermes/HermesACPProtocol.swift`
- Modify: `TipTour/Hermes/HermesClient.swift`

No new tests here — the integration becomes observable in Task 8's manual end-to-end run, and the Plan 1 + 2 regression gate guards against breaking the rest.

- [ ] **Step 1: Add `HttpMcpServerEntry` and `HttpHeader` to `HermesACPProtocol.swift`.**

Find the existing `struct NewSessionRequest` (~line 92) and insert these two struct definitions BEFORE it:

```swift
// MARK: - MCP server registration (for NewSessionRequest.mcpServers)

struct HttpHeader: Encodable {
    let name: String
    let value: String
}

struct HttpMcpServerEntry: Encodable {
    let type: String = "http"
    let name: String
    let url: String
    let headers: [HttpHeader]
}
```

Then change `NewSessionRequest.mcpServers`'s type from `[JSONValue]` to `[HttpMcpServerEntry]`:

```swift
struct NewSessionRequest: Encodable {
    let cwd: String
    let mcpServers: [HttpMcpServerEntry]
}
```

- [ ] **Step 2: Add `mcpServerURL` and update `openSession()` in `HermesClient.swift`.**

Find the property block near the top of `HermesClient` (where `@Published private(set) var lastError: String?` lives). Add this PUBLIC property just below it:

```swift
    /// MCP server URL to register with Hermes on `session/new`. Set this
    /// BEFORE the first `send()` call. Subsequent changes only take
    /// effect after `stop()` + a fresh `send()` (which recycles the
    /// session). When `nil`, no MCP servers are registered.
    var mcpServerURL: URL?
```

Then find `private func openSession()` (~line 217) and replace its body:

```swift
    private func openSession() async throws {
        let cwd = FileManager.default.currentDirectoryPath
        let mcpServers: [HttpMcpServerEntry]
        if let url = mcpServerURL {
            mcpServers = [HttpMcpServerEntry(
                name: "tiptour-tools",
                url: url.absoluteString,
                headers: []
            )]
        } else {
            mcpServers = []
        }
        let req = NewSessionRequest(cwd: cwd, mcpServers: mcpServers)
        let result: NewSessionResult = try await sendRequest(method: "session/new", params: req)
        self.sessionId = result.sessionId
    }
```

- [ ] **Step 3: BUILD-CHECK.**

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  xcodebuild -project tiptour-macos.xcodeproj -scheme tiptour-macos \
             -configuration Debug build 2>&1 | tail -3
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Run the regression gate (Plan 1+2 canaries) to confirm nothing regressed.**

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  xcodebuild -project tiptour-macos.xcodeproj -scheme tiptour-macos \
             -configuration Debug test \
             -only-testing:tiptour-macosTests/HermesBundleTests \
             -only-testing:tiptour-macosTests/HermesACPProtocolTests \
             -only-testing:tiptour-macosTests/HermesClientTests 2>&1 | \
  grep -E '^\*\* (TEST|BUILD) (SUCCEEDED|FAILED)'
```
Expected: `** TEST SUCCEEDED **`. `HermesClientTests.testFirstSendWithMissingConfigSurfacesSystemTurn` (Task 5 from Plan 2) must still pass because `mcpServers: []` is what it has always sent in practice.

- [ ] **Step 5: Commit.**

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  git add TipTour/Hermes/HermesACPProtocol.swift TipTour/Hermes/HermesClient.swift && \
  git commit -m "feat(hermes): HermesClient.mcpServerURL registers an HTTP MCP server

NewSessionRequest.mcpServers changes type from [JSONValue] to
[HttpMcpServerEntry]. When HermesClient.mcpServerURL is non-nil,
openSession() builds a one-entry array pointing to that URL. When
nil, an empty array is sent (current Plan 2 behaviour). Plan 3a's
DebugMenuController will set the URL before the chat opens."
```

---

## Task 7: `HermesDebugMenuController` integration

**Files:**
- Modify: `TipTour/Hermes/HermesDebugMenuController.swift`

- [ ] **Step 1: Replace the file with the integrated version.**

Open `TipTour/Hermes/HermesDebugMenuController.swift` and replace the entire body of the file with:

```swift
// TipTour/Hermes/HermesDebugMenuController.swift
//
// Owns the second menu-bar status item ("Hermes" with a debug menu),
// the floating chat window, a single HermesClient instance, and the
// in-process MCPServer that exposes Mac-side tools (Plan 3a: speak;
// Plan 3b adds take_screenshot / get_a11y_tree / point_at).

import AppKit

@MainActor
final class HermesDebugMenuController: NSObject, NSWindowDelegate {
    private var statusItem: NSStatusItem?
    private var window: NSWindow?
    private let client = HermesClient()
    private let mcpServer = MCPServer(name: "tiptour-tools")

    func install() {
        // Register tools once. The server doesn't bind a port until
        // openChat() — we want the loopback port allocated on demand
        // and freed when the chat window closes.
        mcpServer.register(SpeakTool())

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
            do {
                let url = try mcpServer.start()
                client.mcpServerURL = url
                NSLog("[Hermes] MCP server up at %@", url.absoluteString)
            } catch {
                NSLog("[Hermes] MCP server failed to start: %@; chat opens without tools", "\(error)")
                client.mcpServerURL = nil
            }
            let w = makeHermesChatWindow(client: client)
            w.delegate = self
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - NSWindowDelegate

    /// Fires for every close path (red X, ⌘W, programmatic `close()`,
    /// `orderOut:`-on-close, etc).
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

- [ ] **Step 2: BUILD-CHECK.**

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  xcodebuild -project tiptour-macos.xcodeproj -scheme tiptour-macos \
             -configuration Debug build 2>&1 | tail -3
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Run the full test gate (all Plan 1+2+3a tests).**

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  xcodebuild -project tiptour-macos.xcodeproj -scheme tiptour-macos \
             -configuration Debug test \
             -only-testing:tiptour-macosTests/HermesBundleTests \
             -only-testing:tiptour-macosTests/HermesACPProtocolTests \
             -only-testing:tiptour-macosTests/HermesClientTests \
             -only-testing:tiptour-macosTests/MCPToolsTests \
             -only-testing:tiptour-macosTests/MCPServerTests 2>&1 | \
  grep -E '^\*\* (TEST|BUILD) (SUCCEEDED|FAILED)'
```
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 4: Commit.**

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  git add TipTour/Hermes/HermesDebugMenuController.swift && \
  git commit -m "feat(hermes): HermesDebugMenuController hosts the MCP server

install() registers SpeakTool. openChat() lazy-starts the loopback
listener and sets client.mcpServerURL so Hermes registers it on
session/new. windowWillClose() tears down both subprocess and listener."
```

---

## Task 8: Manual end-to-end verification + acceptance gate

No edits. Runs acceptance criteria from the spec.

- [ ] **Step 1: BUILD-CHECK.** Expected `** BUILD SUCCEEDED **`.

- [ ] **Step 2: Full automated test gate.**

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  xcodebuild -project tiptour-macos.xcodeproj -scheme tiptour-macos \
             -configuration Debug test 2>&1 | \
  grep -E '^\*\* (TEST|BUILD) (SUCCEEDED|FAILED)'
```
Expected: `** TEST SUCCEEDED **`. All of `HermesBundleTests`, `HermesACPProtocolTests`, `HermesClientTests`, `MCPToolsTests`, `MCPServerTests` pass.

- [ ] **Step 3: Plan 1 Python canary still green.**

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  PYTHONUNBUFFERED=1 ./Tests/Python/smoke_test_acp.py | tail -3
```
Expected: `PASS (phase 1)` minimum. If the user's `~/.hermes/.env` carries `ANTHROPIC_API_KEY`, expect `PASS` with the full prompt cycle.

- [ ] **Step 4: Kill any leftover app + subprocess; relaunch.**

```bash
pkill -x TipTour_Hermes 2>/dev/null
pkill -f 'hermes-runtime.*acp_adapter' 2>/dev/null
sleep 1
APP=$(find ~/Library/Developer/Xcode/DerivedData -name 'TipTour_Hermes.app' -path '*/Debug/*' 2>/dev/null | head -1)
echo "Opening: $APP"
open "$APP"
```

- [ ] **Step 5: Visual + audio verification.**

In the running app:
- [ ] Confirm "🛠 Hermes" status item appears (alongside the existing TipTour_Hermes menu-bar item).
- [ ] Click it → "Talk to Hermes…" → window opens with empty transcript and text input focused.
- [ ] In the Console.app (or `log stream --predicate 'eventMessage CONTAINS "[Hermes]"'`), see `[Hermes] MCP server up at http://127.0.0.1:<port>/mcp`.
- [ ] Type `Say "hello from plan 3a" out loud using the speak tool.` and press Enter.
- [ ] Within ~5s: a user bubble appears immediately; an agent bubble follows; under the agent bubble, one collapsible row `▸ speak(text="hello from plan 3a") [completed]`. Audio: the Mac says "hello from plan 3a".
- [ ] Click the disclosure triangle on the tool-call row. Args JSON shows the speak text in pretty-printed form.

- [ ] **Step 6: Verify lifecycle cleanup.**

- [ ] Close the chat window (red X).
- [ ] In Console.app, see `[HermesDebugMenuController] windowWillClose — terminating Hermes + MCP server`.
- [ ] In terminal:

```bash
ps ax | grep -v grep | grep hermes-runtime
lsof -iTCP:LISTEN -P 2>/dev/null | grep TipTour_Hermes
```

Both should be empty (no Python subprocess, no listening HTTP server owned by the app).

- [ ] **Step 7: Verify a re-opened chat starts a fresh server.**

- [ ] Reopen "Talk to Hermes…" (⌘⇧H).
- [ ] In Console, see another `MCP server up at http://127.0.0.1:<port>/mcp` — port number should differ from the first one.
- [ ] Send another speak prompt; confirm tool-call row + audio.
- [ ] Close the window.

- [ ] **Step 8: No commit — Task 7's commit is the final state.**

Plan 3a is complete when all 6 acceptance criteria from the spec are met:

1. `xcodebuild build` exits 0. ✓ (Step 1)
2. `MCPServerTests` — all 5 cases pass (start/stop, initialize, tools/list, tools/call success, tools/call unknown). ✓ (Step 2)
3. Plan 1+2 regression gate green. ✓ (Step 2 + Step 3)
4. Live tool-call in the dev chat produces a `▸ speak(...) [completed]` row AND audible speech. ✓ (Step 5)
5. Close terminates both subprocess AND listener. ✓ (Step 6)
6. Reopen binds a fresh random port. ✓ (Step 7)

---

## Rollback procedure

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  git status --short && \
  git reset --hard pre-plan-3a
```

Each task's commit is independently revertable via `git revert <sha>`.

---

## What comes after Plan 3a

**Plan 3b — Remaining Mac tools.** Adds `take_screenshot`, `get_a11y_tree`, and `point_at` as additional `MCPTool` implementations registered alongside `SpeakTool`. No changes to `MCPServer` itself.

**Plan 3c — Voice-loop integration.** Wires push-to-talk → Gemini Live STT → `HermesClient.send` → reply → `AVSpeechSynthesizer` TTS, replacing the 15 `TODO(plan-2)` markers in `CompanionManager` / `GeminiLiveSession` / `CompanionPanelView`.

Both 3b and 3c assume Plan 3a has landed cleanly.
