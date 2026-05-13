# MCP Client Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let TipTour's background agents call tools exposed by user-installed MCP servers (filesystem, github, postgres, brave-search, …), so the swarm gains an entire ecosystem of capabilities without per-tool Swift code.

**Architecture:** TipTour spawns each configured MCP server as a long-lived stdio subprocess and speaks JSON-RPC 2.0 over newline-delimited JSON. Each server is managed by an `MCPClient` actor; a singleton `MCPServerRegistry` owns the set of clients and exposes the union of their remote tools as `MCPRemoteTool` instances. `ToolBox.build(for:)` appends those remote tools to relevant task-type toolboxes. Servers are configured via a JSON file plus a Settings UI; we ship with zero servers preinstalled.

**Scope:** Stdio transport only. Tools only (no resources, prompts, or sampling). Tool list pulled once per session — no `notifications/tools/list_changed` subscription. v1 supports public, user-trusted servers — there is no per-server sandbox beyond the macOS user account.

**Tech Stack:** Swift actors, `Process` + `Pipe` for stdio, JSON-RPC 2.0 codec (in-process — no SDK dependency), `JSONSerialization`, the existing `AgentTool` protocol, SwiftUI for the settings UI, Swift Testing.

---

## File Structure

| Action | Path | Responsibility |
|--------|------|----------------|
| Create | `TipTour/Agents/MCP/MCPServerConfig.swift` | `MCPServerConfig` (name, command, args, env), `MCPConfigStore` (load/save `~/Library/Application Support/TipTour/mcp-servers.json`) |
| Create | `TipTour/Agents/MCP/MCPMessage.swift` | JSON-RPC 2.0 message types (`Request`, `Response`, `Notification`, `Error`); newline-JSON encode/decode |
| Create | `TipTour/Agents/MCP/MCPClient.swift` | Per-server actor: spawn subprocess, perform `initialize` handshake, send `tools/list`, dispatch `tools/call`, surface tool list to the registry |
| Create | `TipTour/Agents/MCP/MCPServerRegistry.swift` | Singleton actor: owns all clients, starts them at app launch, exposes `allRemoteTools()` |
| Create | `TipTour/Agents/MCP/MCPRemoteTool.swift` | `AgentTool` wrapper that proxies `execute` to `MCPClient.callTool` |
| Modify | `TipTour/Agents/Tools/AgentTool.swift` | `ToolBox.build(for:)` appends `MCPServerRegistry.shared.toolsAvailable(for: taskType)` |
| Modify | `TipTour/CompanionManager.swift` | Kick off `MCPServerRegistry.shared.startAll()` after the bundled-skill seeder runs at app launch |
| Modify | `TipTour/Agents/UI/SettingsView.swift` | New "MCP Servers" tab with add/remove/restart controls |
| Create | `TipTourTests/MCPClientTests.swift` | Unit tests for JSON-RPC codec + integration test using a stub server |
| Create | `TipTourTests/Fixtures/echo-mcp-server.sh` | Tiny shell-based stub MCP server used by integration tests |

---

## Task 1: Config types + on-disk persistence

**Files:**
- Create: `TipTour/Agents/MCP/MCPServerConfig.swift`
- Create: `TipTourTests/MCPClientTests.swift`

- [ ] **Step 1: Write failing tests for round-tripping a config file**

Create `TipTourTests/MCPClientTests.swift`:

```swift
// TipTourTests/MCPClientTests.swift

import Foundation
import Testing
@testable import TipTour

@Suite("MCPConfigStore")
struct MCPConfigStoreTests {

    @Test func roundtripWritesAndReadsConfigs() async throws {
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-config-\(UUID().uuidString).json")
        let store = MCPConfigStore(fileURL: tmpURL)
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        let configs = [
            MCPServerConfig(
                id: UUID(),
                name: "filesystem",
                command: "/usr/bin/npx",
                args: ["-y", "@modelcontextprotocol/server-filesystem", "/Users/me/Notes"],
                env: ["NODE_ENV": "production"],
                enabledTaskTypes: [.fileManagement, .coding]
            )
        ]
        try await store.save(configs)
        let loaded = try await store.load()
        #expect(loaded.count == 1)
        #expect(loaded[0].name == "filesystem")
        #expect(loaded[0].args == ["-y", "@modelcontextprotocol/server-filesystem", "/Users/me/Notes"])
        #expect(loaded[0].env == ["NODE_ENV": "production"])
        #expect(loaded[0].enabledTaskTypes.contains(.fileManagement))
    }

    @Test func loadReturnsEmptyWhenFileMissing() async throws {
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString).json")
        let store = MCPConfigStore(fileURL: tmpURL)
        let loaded = try await store.load()
        #expect(loaded.isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run `MCPConfigStoreTests` in Xcode. Expected: compile failure ("cannot find 'MCPServerConfig' / 'MCPConfigStore' in scope").

- [ ] **Step 3: Implement `MCPServerConfig` + `MCPConfigStore`**

```swift
// TipTour/Agents/MCP/MCPServerConfig.swift

import Foundation

/// One configured MCP server. The user provides `command` + `args` —
/// e.g. `("npx", ["-y", "@modelcontextprotocol/server-filesystem", "/Users/me/Notes"])`.
/// `enabledTaskTypes` controls which agent task types see this
/// server's tools; an empty set means "all task types".
struct MCPServerConfig: Codable, Sendable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var command: String
    var args: [String]
    var env: [String: String]
    var enabledTaskTypes: Set<TaskType>
}

/// Persists the user's MCP server list to JSON. Atomic writes; tolerant
/// of a missing file (treated as empty).
actor MCPConfigStore {

    static let shared = MCPConfigStore()

    private let fileURL: URL

    static var defaultFileURL: URL {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("TipTour", isDirectory: true)
            .appendingPathComponent("mcp-servers.json")
    }

    init(fileURL: URL = MCPConfigStore.defaultFileURL) {
        self.fileURL = fileURL
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    func load() async throws -> [MCPServerConfig] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode([MCPServerConfig].self, from: data)
    }

    func save(_ configs: [MCPServerConfig]) async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(configs)
        try data.write(to: fileURL, options: [.atomic])
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run `MCPConfigStoreTests` in Xcode. Expected: both tests pass.

- [ ] **Step 5: Commit**

```bash
git add TipTour/Agents/MCP/MCPServerConfig.swift TipTourTests/MCPClientTests.swift
git commit -m "feat(mcp): MCPServerConfig types + on-disk config store"
```

---

## Task 2: JSON-RPC message types and codec

**Files:**
- Create: `TipTour/Agents/MCP/MCPMessage.swift`
- Modify: `TipTourTests/MCPClientTests.swift`

- [ ] **Step 1: Write failing tests for encode/decode**

Append:

```swift
@Suite("MCPMessage codec")
struct MCPMessageCodecTests {

    @Test func encodesRequestAsNewlineJSON() throws {
        let request = MCPMessage.request(
            id: .int(1),
            method: "tools/list",
            params: nil
        )
        let encoded = try MCPMessageCodec.encode(request)
        let asString = String(data: encoded, encoding: .utf8)!
        #expect(asString.hasSuffix("\n"))
        let trimmed = asString.trimmingCharacters(in: .whitespacesAndNewlines)
        let json = try JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as! [String: Any]
        #expect(json["jsonrpc"] as? String == "2.0")
        #expect(json["method"] as? String == "tools/list")
        #expect(json["id"] as? Int == 1)
    }

    @Test func decodesResponseFromJSON() throws {
        let json = #"{"jsonrpc":"2.0","id":42,"result":{"tools":[]}}"#
        let message = try MCPMessageCodec.decode(Data(json.utf8))
        if case .response(let id, let result, _) = message {
            #expect(id == .int(42))
            #expect(result != nil)
        } else {
            Issue.record("Expected .response, got \(message)")
        }
    }

    @Test func decodesErrorResponse() throws {
        let json = #"{"jsonrpc":"2.0","id":7,"error":{"code":-32601,"message":"Method not found"}}"#
        let message = try MCPMessageCodec.decode(Data(json.utf8))
        if case .response(_, _, let error) = message {
            #expect(error?.code == -32601)
            #expect(error?.message == "Method not found")
        } else {
            Issue.record("Expected error response")
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run `MCPMessageCodecTests`. Expected: compile failure.

- [ ] **Step 3: Implement `MCPMessage` + `MCPMessageCodec`**

```swift
// TipTour/Agents/MCP/MCPMessage.swift

import Foundation

/// JSON-RPC 2.0 message variants used by the MCP stdio protocol.
/// We model only what we send/receive (Request, Response,
/// Notification) — server-to-client requests (sampling) are NOT
/// supported in v1 so we never need to reply to a server request.
enum MCPMessage {
    case request(id: MCPMessageID, method: String, params: Any?)
    case notification(method: String, params: Any?)
    case response(id: MCPMessageID, result: Any?, error: MCPResponseError?)

    struct MCPResponseError {
        let code: Int
        let message: String
        let data: Any?
    }
}

/// JSON-RPC ids can be int OR string per spec. We use `Int` for our
/// outbound requests and accept either inbound.
enum MCPMessageID: Hashable {
    case int(Int)
    case string(String)
}

enum MCPCodecError: Error, LocalizedError {
    case malformedJSON
    case missingJsonRpcField
    case unrecognizedShape

    var errorDescription: String? {
        switch self {
        case .malformedJSON: return "Message is not valid JSON"
        case .missingJsonRpcField: return "Message is missing the jsonrpc field"
        case .unrecognizedShape: return "Message matched none of request/response/notification"
        }
    }
}

enum MCPMessageCodec {

    /// Encode a single message as JSON + trailing `\n`.
    static func encode(_ message: MCPMessage) throws -> Data {
        var dict: [String: Any] = ["jsonrpc": "2.0"]
        switch message {
        case .request(let id, let method, let params):
            dict["method"] = method
            dict["id"] = encodeID(id)
            if let params { dict["params"] = params }
        case .notification(let method, let params):
            dict["method"] = method
            if let params { dict["params"] = params }
        case .response(let id, let result, let error):
            dict["id"] = encodeID(id)
            if let result { dict["result"] = result }
            if let error {
                var errDict: [String: Any] = ["code": error.code, "message": error.message]
                if let data = error.data { errDict["data"] = data }
                dict["error"] = errDict
            }
        }
        let data = try JSONSerialization.data(withJSONObject: dict, options: [])
        var out = data
        out.append(0x0A)  // '\n'
        return out
    }

    /// Decode a single line of JSON into an MCPMessage.
    static func decode(_ data: Data) throws -> MCPMessage {
        let obj: Any
        do {
            obj = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw MCPCodecError.malformedJSON
        }
        guard let dict = obj as? [String: Any] else {
            throw MCPCodecError.malformedJSON
        }
        guard dict["jsonrpc"] as? String == "2.0" else {
            throw MCPCodecError.missingJsonRpcField
        }

        let id = decodeID(dict["id"])
        let method = dict["method"] as? String

        if let method, id == nil {
            return .notification(method: method, params: dict["params"])
        }
        if let method, let id {
            return .request(id: id, method: method, params: dict["params"])
        }
        if let id {
            let error = (dict["error"] as? [String: Any]).map { errDict -> MCPMessage.MCPResponseError in
                MCPMessage.MCPResponseError(
                    code: errDict["code"] as? Int ?? -1,
                    message: errDict["message"] as? String ?? "",
                    data: errDict["data"]
                )
            }
            return .response(id: id, result: dict["result"], error: error)
        }
        throw MCPCodecError.unrecognizedShape
    }

    private static func encodeID(_ id: MCPMessageID) -> Any {
        switch id {
        case .int(let n): return n
        case .string(let s): return s
        }
    }

    private static func decodeID(_ raw: Any?) -> MCPMessageID? {
        if let n = raw as? Int { return .int(n) }
        if let s = raw as? String { return .string(s) }
        return nil
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run `MCPMessageCodecTests`. Expected: all 3 tests pass.

- [ ] **Step 5: Commit**

```bash
git add TipTour/Agents/MCP/MCPMessage.swift TipTourTests/MCPClientTests.swift
git commit -m "feat(mcp): JSON-RPC 2.0 message codec"
```

---

## Task 3: `MCPClient` — spawn subprocess, handshake, `tools/list`

**Files:**
- Create: `TipTour/Agents/MCP/MCPClient.swift`
- Create: `TipTourTests/Fixtures/echo-mcp-server.sh`
- Modify: `TipTourTests/MCPClientTests.swift`

- [ ] **Step 1: Create the stub server fixture**

Create `TipTourTests/Fixtures/echo-mcp-server.sh`:

```bash
#!/bin/bash
# Tiny stub MCP server for unit tests. Speaks just enough JSON-RPC to
# pass MCPClient's handshake + tools/list + a fake echo tool.

while IFS= read -r line; do
    method=$(echo "$line" | python3 -c "import sys, json; print(json.load(sys.stdin).get('method',''))")
    id=$(echo "$line" | python3 -c "import sys, json; print(json.load(sys.stdin).get('id',''))")
    case "$method" in
        initialize)
            echo "{\"jsonrpc\":\"2.0\",\"id\":${id},\"result\":{\"protocolVersion\":\"2024-11-05\",\"serverInfo\":{\"name\":\"echo\",\"version\":\"0.0.1\"},\"capabilities\":{\"tools\":{}}}}"
            ;;
        notifications/initialized)
            # Notification — no reply.
            ;;
        tools/list)
            echo "{\"jsonrpc\":\"2.0\",\"id\":${id},\"result\":{\"tools\":[{\"name\":\"echo\",\"description\":\"Echoes back its input\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"text\":{\"type\":\"string\"}},\"required\":[\"text\"]}}]}}"
            ;;
        tools/call)
            text=$(echo "$line" | python3 -c "import sys, json; print(json.load(sys.stdin)['params']['arguments']['text'])")
            echo "{\"jsonrpc\":\"2.0\",\"id\":${id},\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"echo: ${text}\"}]}}"
            ;;
    esac
done
```

Make it executable: `chmod +x TipTourTests/Fixtures/echo-mcp-server.sh`. Add to the test target as a resource.

- [ ] **Step 2: Write failing integration test**

Append:

```swift
@Suite("MCPClient integration")
struct MCPClientIntegrationTests {

    @Test func handshakeAndToolsListReturnsEchoTool() async throws {
        let bundle = Bundle(for: TipTourTestsAnchor.self)
        let serverPath = bundle.path(forResource: "echo-mcp-server", ofType: "sh")!

        let config = MCPServerConfig(
            id: UUID(),
            name: "echo",
            command: "/bin/bash",
            args: [serverPath],
            env: [:],
            enabledTaskTypes: []
        )
        let client = MCPClient(config: config)
        try await client.start()
        defer { Task { await client.stop() } }

        let tools = await client.availableTools()
        #expect(tools.count == 1)
        #expect(tools.first?.name == "echo")
    }

    @Test func callToolReturnsEchoedText() async throws {
        let bundle = Bundle(for: TipTourTestsAnchor.self)
        let serverPath = bundle.path(forResource: "echo-mcp-server", ofType: "sh")!

        let config = MCPServerConfig(
            id: UUID(),
            name: "echo",
            command: "/bin/bash",
            args: [serverPath],
            env: [:],
            enabledTaskTypes: []
        )
        let client = MCPClient(config: config)
        try await client.start()
        defer { Task { await client.stop() } }

        let result = try await client.callTool(name: "echo", arguments: ["text": "hello"])
        #expect(result.contains("echo: hello"))
    }
}

private final class TipTourTestsAnchor {}
```

- [ ] **Step 3: Run tests to verify they fail**

Run `MCPClientIntegrationTests`. Expected: compile failure.

- [ ] **Step 4: Implement `MCPClient`**

```swift
// TipTour/Agents/MCP/MCPClient.swift

import Foundation

/// One running MCP server subprocess. Owns its `Process` + stdio pipes,
/// maintains an `(id → continuation)` table for pending requests, and
/// reads newline-delimited JSON in a background `Task`.
///
/// **One in-flight request at a time is fine for v1** — every method
/// awaits its own response before returning. Concurrent calls from the
/// agent are serialised by the actor.
actor MCPClient {

    struct RemoteToolDescription: Sendable {
        let name: String
        let description: String
        let inputSchema: [String: Any]
    }

    enum ClientError: Error, LocalizedError {
        case notRunning
        case spawnFailed(reason: String)
        case handshakeFailed(reason: String)
        case rpcError(code: Int, message: String)
        case decodeError(String)
        case timeout

        var errorDescription: String? {
            switch self {
            case .notRunning: return "MCP server is not running"
            case .spawnFailed(let r): return "Failed to spawn server: \(r)"
            case .handshakeFailed(let r): return "Handshake failed: \(r)"
            case .rpcError(let code, let msg): return "RPC error \(code): \(msg)"
            case .decodeError(let s): return "Decode error: \(s)"
            case .timeout: return "Request timed out"
            }
        }
    }

    let config: MCPServerConfig

    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutBuffer: Data = Data()
    private var nextRequestID: Int = 1
    private var pendingRequests: [Int: CheckedContinuation<Any?, Error>] = [:]
    private var availableToolsCached: [RemoteToolDescription] = []
    private var readerTask: Task<Void, Never>?

    init(config: MCPServerConfig) {
        self.config = config
    }

    func start() async throws {
        guard process == nil else { return }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: config.command)
        proc.arguments = config.args
        if !config.env.isEmpty {
            var combinedEnv = ProcessInfo.processInfo.environment
            for (k, v) in config.env { combinedEnv[k] = v }
            proc.environment = combinedEnv
        }
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr

        do {
            try proc.run()
        } catch {
            throw ClientError.spawnFailed(reason: error.localizedDescription)
        }
        self.process = proc
        self.stdinPipe = stdin

        let stdoutHandle = stdout.fileHandleForReading
        readerTask = Task { [weak self] in
            await self?.runReadLoop(handle: stdoutHandle)
        }

        // Drain stderr to the console so server crashes are visible.
        let stderrHandle = stderr.fileHandleForReading
        Task.detached {
            while let chunk = try? stderrHandle.read(upToCount: 4096), !chunk.isEmpty {
                if let s = String(data: chunk, encoding: .utf8) {
                    print("[MCPClient \(self.config.name) stderr] \(s)", terminator: "")
                }
            }
        }

        try await performHandshake()
        try await fetchToolList()
    }

    func stop() async {
        readerTask?.cancel()
        readerTask = nil
        process?.terminate()
        process = nil
        stdinPipe = nil
        for (_, continuation) in pendingRequests {
            continuation.resume(throwing: ClientError.notRunning)
        }
        pendingRequests.removeAll()
    }

    func availableTools() -> [RemoteToolDescription] {
        availableToolsCached
    }

    /// Call a remote tool. Returns the response result's textual content
    /// concatenated as a single string — the same shape `AgentTool.execute`
    /// expects.
    func callTool(name: String, arguments: [String: Any]) async throws -> String {
        let result = try await sendRequest(
            method: "tools/call",
            params: ["name": name, "arguments": arguments]
        )
        guard let dict = result as? [String: Any],
              let content = dict["content"] as? [[String: Any]] else {
            throw ClientError.decodeError("tools/call response missing content array")
        }
        let pieces = content.compactMap { block -> String? in
            guard block["type"] as? String == "text" else { return nil }
            return block["text"] as? String
        }
        return pieces.joined(separator: "\n")
    }

    // MARK: - Private

    private func performHandshake() async throws {
        let initResult = try await sendRequest(
            method: "initialize",
            params: [
                "protocolVersion": "2024-11-05",
                "clientInfo": ["name": "TipTour", "version": "1.0"],
                "capabilities": [:]
            ]
        )
        guard initResult != nil else {
            throw ClientError.handshakeFailed(reason: "initialize returned no result")
        }
        try await sendNotification(method: "notifications/initialized", params: nil)
    }

    private func fetchToolList() async throws {
        let result = try await sendRequest(method: "tools/list", params: nil)
        guard let dict = result as? [String: Any],
              let toolsArray = dict["tools"] as? [[String: Any]] else {
            throw ClientError.decodeError("tools/list response missing tools array")
        }
        availableToolsCached = toolsArray.compactMap { entry in
            guard let name = entry["name"] as? String else { return nil }
            let description = entry["description"] as? String ?? ""
            let schema = entry["inputSchema"] as? [String: Any] ?? [:]
            return RemoteToolDescription(name: name, description: description, inputSchema: schema)
        }
    }

    private func sendRequest(method: String, params: Any?) async throws -> Any? {
        guard let stdinPipe else { throw ClientError.notRunning }
        let id = nextRequestID
        nextRequestID += 1

        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[id] = continuation
            do {
                let data = try MCPMessageCodec.encode(
                    .request(id: .int(id), method: method, params: params)
                )
                try stdinPipe.fileHandleForWriting.write(contentsOf: data)
            } catch {
                pendingRequests.removeValue(forKey: id)
                continuation.resume(throwing: error)
            }
        }
    }

    private func sendNotification(method: String, params: Any?) async throws {
        guard let stdinPipe else { throw ClientError.notRunning }
        let data = try MCPMessageCodec.encode(.notification(method: method, params: params))
        try stdinPipe.fileHandleForWriting.write(contentsOf: data)
    }

    private func runReadLoop(handle: FileHandle) async {
        while !Task.isCancelled {
            do {
                guard let chunk = try handle.read(upToCount: 4096), !chunk.isEmpty else {
                    return  // EOF — process exited
                }
                stdoutBuffer.append(chunk)
                drainCompleteMessages()
            } catch {
                print("[MCPClient \(config.name)] read error: \(error.localizedDescription)")
                return
            }
        }
    }

    /// Pull complete `\n`-delimited messages out of `stdoutBuffer` and
    /// resolve their pending continuations.
    private func drainCompleteMessages() {
        while let newlineIndex = stdoutBuffer.firstIndex(of: 0x0A) {
            let line = stdoutBuffer[..<newlineIndex]
            stdoutBuffer.removeSubrange(...newlineIndex)
            guard !line.isEmpty else { continue }
            do {
                let message = try MCPMessageCodec.decode(Data(line))
                handle(message)
            } catch {
                print("[MCPClient \(config.name)] decode error: \(error.localizedDescription)")
            }
        }
    }

    private func handle(_ message: MCPMessage) {
        switch message {
        case .response(let id, let result, let error):
            guard case .int(let intID) = id, let continuation = pendingRequests.removeValue(forKey: intID) else {
                print("[MCPClient \(config.name)] response with unknown id: \(id)")
                return
            }
            if let error {
                continuation.resume(throwing: ClientError.rpcError(code: error.code, message: error.message))
            } else {
                continuation.resume(returning: result)
            }
        case .notification:
            // v1: ignore server notifications (logging, progress).
            break
        case .request:
            // v1: ignore server-to-client requests (sampling not supported).
            break
        }
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run `MCPClientIntegrationTests`. Expected: both tests pass; the echo server responds to handshake + tools/list + tools/call.

- [ ] **Step 6: Commit**

```bash
git add TipTour/Agents/MCP/MCPClient.swift TipTourTests/MCPClientTests.swift TipTourTests/Fixtures/echo-mcp-server.sh
git commit -m "feat(mcp): MCPClient with stdio handshake, tools/list, tools/call"
```

---

## Task 4: `MCPRemoteTool` — bridge MCP tools into `AgentTool`

**Files:**
- Create: `TipTour/Agents/MCP/MCPRemoteTool.swift`
- Modify: `TipTourTests/MCPClientTests.swift`

- [ ] **Step 1: Write failing test**

Append:

```swift
@Suite("MCPRemoteTool")
struct MCPRemoteToolTests {

    @Test func executesAgainstClient() async throws {
        let bundle = Bundle(for: TipTourTestsAnchor.self)
        let serverPath = bundle.path(forResource: "echo-mcp-server", ofType: "sh")!
        let config = MCPServerConfig(
            id: UUID(),
            name: "echo",
            command: "/bin/bash",
            args: [serverPath],
            env: [:],
            enabledTaskTypes: []
        )
        let client = MCPClient(config: config)
        try await client.start()
        defer { Task { await client.stop() } }

        let toolDescriptions = await client.availableTools()
        let tool = MCPRemoteTool(
            client: client,
            serverName: "echo",
            description: toolDescriptions[0]
        )
        let result = await tool.execute(argumentsJSON: #"{"text":"world"}"#)
        #expect(result.contains("echo: world"))
        #expect(tool.name == "mcp__echo__echo")
    }
}
```

The `mcp__<server>__<tool>` naming convention is important — it namespaces remote tools so two MCP servers with a `search` tool don't collide.

- [ ] **Step 2: Run test to verify it fails**

Run `MCPRemoteToolTests`. Expected: compile failure.

- [ ] **Step 3: Implement `MCPRemoteTool`**

```swift
// TipTour/Agents/MCP/MCPRemoteTool.swift

import Foundation

/// Wraps a single MCP remote tool so it conforms to TipTour's
/// `AgentTool` protocol and can be added to a `ToolBox`. The tool's
/// LLM-facing name is `mcp__<serverName>__<remoteName>` so multiple
/// servers exposing tools with the same remote name don't collide.
struct MCPRemoteTool: AgentTool {

    let client: MCPClient
    let serverName: String
    let remoteName: String
    let remoteDescription: String
    let inputSchema: [String: Any]

    init(client: MCPClient, serverName: String, description: MCPClient.RemoteToolDescription) {
        self.client = client
        self.serverName = serverName
        self.remoteName = description.name
        self.remoteDescription = description.description
        self.inputSchema = description.inputSchema
    }

    var name: String { "mcp__\(serverName)__\(remoteName)" }

    var description: String {
        "[MCP server '\(serverName)'] \(remoteDescription)"
    }

    var parametersJSON: String {
        // Re-serialize the server-supplied JSON Schema. Foundation
        // can't round-trip [String: Any] without losing ordering, but
        // the LLM doesn't care about field ordering — only the schema
        // shape matters.
        guard let data = try? JSONSerialization.data(withJSONObject: inputSchema, options: []),
              let str = String(data: data, encoding: .utf8) else {
            return #"{"type":"object","properties":{}}"#
        }
        return str
    }

    func execute(argumentsJSON: String) async -> String {
        guard let data = argumentsJSON.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "Error: MCP tool arguments must be a JSON object"
        }
        do {
            return try await client.callTool(name: remoteName, arguments: parsed)
        } catch {
            return "Error calling MCP tool '\(remoteName)': \(error.localizedDescription)"
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run `MCPRemoteToolTests`. Expected: passes.

- [ ] **Step 5: Commit**

```bash
git add TipTour/Agents/MCP/MCPRemoteTool.swift TipTourTests/MCPClientTests.swift
git commit -m "feat(mcp): MCPRemoteTool bridges remote tools into AgentTool"
```

---

## Task 5: `MCPServerRegistry` — lifecycle for the set of clients

**Files:**
- Create: `TipTour/Agents/MCP/MCPServerRegistry.swift`
- Modify: `TipTourTests/MCPClientTests.swift`

- [ ] **Step 1: Write failing test for the registry**

Append:

```swift
@Suite("MCPServerRegistry")
struct MCPServerRegistryTests {

    @Test func startAllSpawnsClientsAndExposesTools() async throws {
        let bundle = Bundle(for: TipTourTestsAnchor.self)
        let serverPath = bundle.path(forResource: "echo-mcp-server", ofType: "sh")!
        let configs = [
            MCPServerConfig(
                id: UUID(),
                name: "echo",
                command: "/bin/bash",
                args: [serverPath],
                env: [:],
                enabledTaskTypes: [.coding]
            )
        ]
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-config-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmpURL) }
        let configStore = MCPConfigStore(fileURL: tmpURL)
        try await configStore.save(configs)

        let registry = MCPServerRegistry(configStore: configStore)
        await registry.startAll()
        defer { Task { await registry.stopAll() } }

        let toolsForCoding = await registry.toolsAvailable(for: .coding)
        let toolsForAnalysis = await registry.toolsAvailable(for: .analysis)
        #expect(toolsForCoding.count == 1)
        #expect(toolsForCoding.first?.name == "mcp__echo__echo")
        #expect(toolsForAnalysis.isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run `MCPServerRegistryTests`. Expected: compile failure.

- [ ] **Step 3: Implement `MCPServerRegistry`**

```swift
// TipTour/Agents/MCP/MCPServerRegistry.swift

import Foundation

actor MCPServerRegistry {

    static let shared = MCPServerRegistry()

    private let configStore: MCPConfigStore
    private var clients: [UUID: MCPClient] = [:]
    private var configsByID: [UUID: MCPServerConfig] = [:]

    init(configStore: MCPConfigStore = .shared) {
        self.configStore = configStore
    }

    /// Load every configured server and spawn it. Failures are logged
    /// per-server but don't abort the rest — one bad config shouldn't
    /// disable every MCP server the user installed.
    func startAll() async {
        let configs = (try? await configStore.load()) ?? []
        for config in configs {
            await startOne(config)
        }
    }

    private func startOne(_ config: MCPServerConfig) async {
        let client = MCPClient(config: config)
        do {
            try await client.start()
            clients[config.id] = client
            configsByID[config.id] = config
            print("[MCPServerRegistry] started '\(config.name)' with \(await client.availableTools().count) tool(s)")
        } catch {
            print("[MCPServerRegistry] '\(config.name)' failed to start: \(error.localizedDescription)")
        }
    }

    func stopAll() async {
        for (_, client) in clients {
            await client.stop()
        }
        clients.removeAll()
        configsByID.removeAll()
    }

    func restart(serverID: UUID) async {
        if let client = clients[serverID] {
            await client.stop()
        }
        clients.removeValue(forKey: serverID)
        guard let config = configsByID[serverID] else { return }
        await startOne(config)
    }

    /// Return the remote tools that should be visible to a given task
    /// type. An empty `enabledTaskTypes` set means "all task types".
    func toolsAvailable(for taskType: TaskType) async -> [MCPRemoteTool] {
        var result: [MCPRemoteTool] = []
        for (id, client) in clients {
            guard let config = configsByID[id] else { continue }
            if !config.enabledTaskTypes.isEmpty,
               !config.enabledTaskTypes.contains(taskType) {
                continue
            }
            let descriptions = await client.availableTools()
            for description in descriptions {
                result.append(MCPRemoteTool(
                    client: client,
                    serverName: config.name,
                    description: description
                ))
            }
        }
        return result
    }

    /// Convenience for the Settings UI to enumerate live servers.
    func liveServers() async -> [(config: MCPServerConfig, toolCount: Int)] {
        var out: [(MCPServerConfig, Int)] = []
        for (id, client) in clients {
            guard let config = configsByID[id] else { continue }
            let count = await client.availableTools().count
            out.append((config, count))
        }
        return out
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run `MCPServerRegistryTests`. Expected: passes.

- [ ] **Step 5: Commit**

```bash
git add TipTour/Agents/MCP/MCPServerRegistry.swift TipTourTests/MCPClientTests.swift
git commit -m "feat(mcp): MCPServerRegistry — lifecycle + per-task-type tool exposure"
```

---

## Task 6: Wire MCP tools into `ToolBox` and start the registry at app launch

**Files:**
- Modify: `TipTour/Agents/Tools/AgentTool.swift`
- Modify: `TipTour/CompanionManager.swift`

- [ ] **Step 1: Append MCP tools to every `ToolBox.build` variant**

In `TipTour/Agents/Tools/AgentTool.swift`, change `ToolBox.build(for:)` and the two overloads to fetch MCP tools and append them. Because the registry is an actor, the build methods become `async`. Update call sites to `await ToolBox.build(...)`.

The simplest invasive-but-correct change:

```swift
static func build(for taskType: TaskType) async -> ToolBox {
    let sharedTools: [any AgentTool] = [
        RememberFactTool(taskType: taskType),
        RecallFactsTool(taskType: taskType),
        RecallSkillTool(taskType: taskType)
    ]
    let mcpTools = await MCPServerRegistry.shared.toolsAvailable(for: taskType)
    return ToolBox(tools: domainTools(for: taskType) + sharedTools + mcpTools)
}

static func build(for taskType: TaskType, historyBuffer: ToolCallHistoryBuffer) async -> ToolBox {
    let sharedTools: [any AgentTool] = [
        RememberFactTool(taskType: taskType),
        RecallFactsTool(taskType: taskType),
        SaveSkillTool(taskType: taskType, historyBuffer: historyBuffer),
        RecallSkillTool(taskType: taskType)
    ]
    let mcpTools = await MCPServerRegistry.shared.toolsAvailable(for: taskType)
    return ToolBox(tools: domainTools(for: taskType) + sharedTools + mcpTools)
}

static func build(
    for taskType: TaskType,
    historyBuffer: ToolCallHistoryBuffer,
    interactiveShellSession: InteractiveShellSession,
    workspaceURL: URL?
) async -> ToolBox {
    let sharedTools: [any AgentTool] = [
        RememberFactTool(taskType: taskType),
        RecallFactsTool(taskType: taskType),
        SaveSkillTool(taskType: taskType, historyBuffer: historyBuffer),
        RecallSkillTool(taskType: taskType)
    ]
    var domain = domainTools(for: taskType)
    switch taskType {
    case .coding, .fileManagement, .generalMac, .browserResearch:
        domain.append(InteractiveShellTool(session: interactiveShellSession))
    default:
        break
    }
    let mcpTools = await MCPServerRegistry.shared.toolsAvailable(for: taskType)
    return ToolBox(tools: domain + sharedTools + mcpTools)
}
```

- [ ] **Step 2: Update `TaskAgent.init` to call the async builder**

`TaskAgent.init` currently calls `ToolBox.build(...)` synchronously (see `TaskAgent.swift:96-101`). Since `init` can't be `async`, change `TaskAgent` to build its toolbox in `run()` instead of `init`:

In `TipTour/Agents/Swarm/TaskAgent.swift`, replace:

```swift
self.toolBox = ToolBox.build(
    for: taskType,
    historyBuffer: buffer,
    interactiveShellSession: shellSession,
    workspaceURL: workspaceURL
)
```

with a deferred initialization. Move toolbox construction into `run()`:

```swift
// In init: leave toolBox uninitialized via lazy or change to var
private var toolBox: ToolBox?

// At the top of run():
if toolBox == nil {
    toolBox = await ToolBox.build(
        for: taskType,
        historyBuffer: skillHistoryBuffer,
        interactiveShellSession: interactiveShellSession,
        workspaceURL: workspaceURL
    )
}
```

Update `availableToolDefinitions()` and `dispatchToolCall(...)` to use `toolBox?` and bail with an error if nil.

- [ ] **Step 3: Start the registry at app launch**

In `TipTour/CompanionManager.swift`, find where `BundledSkillSeeder.seedBundledSkillsIfNeeded()` is awaited (search for `seedBundledSkillsIfNeeded`). Add directly after it:

```swift
Task {
    await MCPServerRegistry.shared.startAll()
}
```

The Task wrapper is important — registry startup spawns subprocesses and waits on their handshakes, which can take seconds. We don't want to block app launch on it.

- [ ] **Step 4: Smoke-test in the running app**

Build (Cmd+B), run (Cmd+R). With no MCP servers configured, expected behavior: app launches normally, no errors. With one configured (manually edit `~/Library/Application Support/TipTour/mcp-servers.json` to add the echo server — see fixture above), launch, ask the voice agent to spawn a coding background task that calls `mcp__echo__echo`. Expected: tool call appears in the agent overlay with the echoed result.

- [ ] **Step 5: Commit**

```bash
git add TipTour/Agents/Tools/AgentTool.swift TipTour/Agents/Swarm/TaskAgent.swift TipTour/CompanionManager.swift
git commit -m "feat(mcp): wire MCP remote tools into agent toolboxes"
```

---

## Task 7: Settings UI — manage MCP servers

**Files:**
- Modify: `TipTour/Agents/UI/SettingsView.swift`

- [ ] **Step 1: Add a new tab to `SettingsView.SettingsTab`**

```swift
enum SettingsTab: String, CaseIterable {
    case agents = "Agents"
    case skills = "Skills"
    case mcp = "MCP"
    case learning = "Learning"
}
```

Add the corresponding switch case:

```swift
case .mcp:
    MCPSettingsView()
```

- [ ] **Step 2: Implement `MCPSettingsView`**

Append to `SettingsView.swift`:

```swift
// MARK: - MCP Servers tab

struct MCPSettingsView: View {
    @State private var configs: [MCPServerConfig] = []
    @State private var liveCounts: [UUID: Int] = [:]
    @State private var showAddSheet = false
    @State private var draftName = ""
    @State private var draftCommand = ""
    @State private var draftArgs = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(configs.count) server\(configs.count == 1 ? "" : "s")")
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textTertiary)
                Spacer()
                Button(action: { showAddSheet = true }) {
                    Label("Add…", systemImage: "plus.circle")
                }
                .buttonStyle(.borderless)
                .pointerCursor()
            }

            if configs.isEmpty {
                Text("No MCP servers configured. MCP (Model Context Protocol) lets background agents call tools from third-party servers — filesystem, github, postgres, brave-search, etc. Add a server with its command and arguments. The server runs as a subprocess on your machine.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(configs) { config in
                            serverRow(config: config)
                        }
                    }
                }
            }
        }
        .padding(16)
        .task { await reload() }
        .sheet(isPresented: $showAddSheet) {
            addServerSheet
        }
    }

    private func serverRow(config: MCPServerConfig) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(config.name).font(.system(size: 13, weight: .medium))
                Text("\(config.command) \(config.args.joined(separator: " "))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(DS.Colors.textTertiary)
                    .lineLimit(1)
                if let count = liveCounts[config.id] {
                    Text("\(count) tool\(count == 1 ? "" : "s")")
                        .font(.system(size: 10))
                        .foregroundColor(.green)
                } else {
                    Text("not started")
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                }
            }
            Spacer()
            Button("Restart") {
                Task {
                    await MCPServerRegistry.shared.restart(serverID: config.id)
                    await reload()
                }
            }
            .buttonStyle(.borderless)
            .pointerCursor()
            Button(role: .destructive, action: {
                Task { await delete(config) }
            }) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .pointerCursor()
        }
        .padding(8)
        .background(DS.Colors.surfaceCard)
        .cornerRadius(DS.CornerRadius.small)
    }

    private var addServerSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add an MCP server").font(.headline)
            TextField("Name (e.g. filesystem)", text: $draftName)
                .textFieldStyle(.roundedBorder)
            TextField("Command (e.g. /usr/bin/npx)", text: $draftCommand)
                .textFieldStyle(.roundedBorder)
            TextField("Args (space-separated)", text: $draftArgs)
                .textFieldStyle(.roundedBorder)
            Text("The server will run as a subprocess on your machine with your user permissions. Only add servers you trust.")
                .font(.system(size: 10))
                .foregroundColor(DS.Colors.textTertiary)
            HStack {
                Spacer()
                Button("Cancel") { showAddSheet = false }
                Button("Add") { Task { await addServer() } }
                    .keyboardShortcut(.return)
                    .disabled(draftName.isEmpty || draftCommand.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func reload() async {
        configs = (try? await MCPConfigStore.shared.load()) ?? []
        let live = await MCPServerRegistry.shared.liveServers()
        liveCounts = Dictionary(uniqueKeysWithValues: live.map { ($0.config.id, $0.toolCount) })
    }

    private func addServer() async {
        let new = MCPServerConfig(
            id: UUID(),
            name: draftName,
            command: draftCommand,
            args: draftArgs.split(separator: " ").map(String.init),
            env: [:],
            enabledTaskTypes: []  // empty = all task types
        )
        var all = configs
        all.append(new)
        try? await MCPConfigStore.shared.save(all)
        await MCPServerRegistry.shared.startAll()  // brings the new one up
        draftName = ""; draftCommand = ""; draftArgs = ""
        showAddSheet = false
        await reload()
    }

    private func delete(_ config: MCPServerConfig) async {
        configs.removeAll { $0.id == config.id }
        try? await MCPConfigStore.shared.save(configs)
        await MCPServerRegistry.shared.stopAll()
        await MCPServerRegistry.shared.startAll()
        await reload()
    }
}
```

- [ ] **Step 3: Smoke-test**

Build + run. Open Settings → MCP. Click Add…, enter `Name: filesystem`, `Command: /usr/bin/npx`, `Args: -y @modelcontextprotocol/server-filesystem /Users/you/Documents`. Click Add. Expected: the row appears with "n tools" once startup completes (~3s for npx cold start). Then ask a background agent to `mcp__filesystem__list_directory` and confirm output.

- [ ] **Step 4: Commit**

```bash
git add TipTour/Agents/UI/SettingsView.swift
git commit -m "feat(mcp): Settings tab for managing MCP servers"
```

---

## Task 8: Documentation

**Files:**
- Modify: `AGENTS.md`

- [ ] **Step 1: Add MCP files to the Key Files table**

Add five rows:

```markdown
| `TipTour/Agents/MCP/MCPServerConfig.swift` | ~70 | `MCPServerConfig` (name, command, args, env, enabledTaskTypes) + `MCPConfigStore` actor (load/save `~/Library/Application Support/TipTour/mcp-servers.json`). |
| `TipTour/Agents/MCP/MCPMessage.swift` | ~150 | JSON-RPC 2.0 message types (Request / Response / Notification) and `MCPMessageCodec` for newline-delimited JSON over stdio. |
| `TipTour/Agents/MCP/MCPClient.swift` | ~250 | Per-server actor. Spawns the subprocess, performs `initialize` + `notifications/initialized` handshake, fetches `tools/list`, dispatches `tools/call`. One in-flight request at a time. |
| `TipTour/Agents/MCP/MCPRemoteTool.swift` | ~70 | `AgentTool` wrapper. Names tools `mcp__<server>__<name>` to avoid collisions. Re-serializes the server-supplied JSON Schema as `parametersJSON`. |
| `TipTour/Agents/MCP/MCPServerRegistry.swift` | ~120 | Singleton actor. Owns all clients, starts/stops them, exposes `toolsAvailable(for: taskType)` so `ToolBox.build` can append remote tools alongside built-in ones. |
```

Also add a paragraph to the architecture section after the "Background-agent execution channels" bullet:

```markdown
- **MCP (Model Context Protocol) remote tools**: At app launch, `MCPServerRegistry` reads `~/Library/Application Support/TipTour/mcp-servers.json` and spawns each configured server as a stdio subprocess (JSON-RPC 2.0). Each server's tools become `mcp__<server>__<tool>` entries in the agent toolbox for the task types its config enables (empty `enabledTaskTypes` = all). Config + lifecycle managed from Settings → MCP. v1 supports tools only — not resources, prompts, or sampling.
```

- [ ] **Step 2: Commit**

```bash
git add AGENTS.md
git commit -m "docs: document MCP client integration in AGENTS.md"
```

---

## Self-Review Checklist

- ✅ **Spec coverage:** Task 1 covers config persistence, Task 2 covers codec, Task 3 covers client + handshake, Task 4 covers tool wrapping, Task 5 covers registry, Task 6 wires into toolbox + launch, Task 7 is the UI, Task 8 documents it. No gaps.
- ✅ **No placeholders:** Every step has runnable code and exact commands. The fixture `echo-mcp-server.sh` is fully specified.
- ✅ **Type consistency:** `MCPMessageID` is used everywhere request/response correlation happens (Task 2 → Task 3); `MCPClient.RemoteToolDescription` is passed unchanged from Task 3 into Task 4's `MCPRemoteTool.init`; `MCPServerConfig.enabledTaskTypes: Set<TaskType>` matches the empty-set semantics in Task 5's `toolsAvailable(for:)`.

---

## Risks the engineer should know going in

1. **Subprocess lifecycle.** `Process` in Swift doesn't auto-restart on crash. v1 logs the crash to stderr; the agent gets a `notRunning` error on next tool call. We do not auto-restart in v1 because some servers crash deterministically on bad config, and an infinite-restart loop would burn CPU.
2. **Initialize timeout.** `npx -y @modelcontextprotocol/server-filesystem` cold-start downloads from npm — first launch can take 10-30s. We do NOT add a handshake timeout in v1; relying on the app-launch `Task { startAll() }` being unblocked is enough.
3. **Tool schema fidelity.** Foundation JSON serialization drops field ordering. The LLM doesn't care, but `JSONSerialization`'s `[String: Any]` round-trip can re-order `properties` keys versus what the server emitted. If a server's schema relies on `oneOf` / `allOf`, we still pass it through correctly because we're encoding the whole subtree.
4. **No sandbox.** MCP servers are full-trust subprocesses. The Settings UI warns about this. Don't add server install commands that fetch from arbitrary URLs without user awareness.
5. **One-request-at-a-time per client.** Two concurrent agents calling the same MCP tool will serialise through the client's actor. For v1 that's acceptable; if we see contention in practice, the upgrade is to refactor `sendRequest` to batch multiple in-flight requests by their unique IDs.
