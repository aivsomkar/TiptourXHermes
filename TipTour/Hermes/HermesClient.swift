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
            // Defensive: handshake either set sessionId or returned. This
            // guard covers the case where session reuse logic gets added later.
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

    /// Buffer for the agent turn currently being assembled from
    /// session/update notifications. Pushed into `transcript` when the
    /// session/prompt response arrives.
    private var currentAgentTurn: (id: UUID, text: String, toolCalls: [ToolCallRecord])?

    private func commitCurrentAgentTurn() {
        guard let t = currentAgentTurn else { return }
        transcript.append(.agent(id: t.id, text: t.text, toolCalls: t.toolCalls))
        currentAgentTurn = nil
    }

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
        // Build a raw JSON object to avoid the "nested generic struct" restriction.
        guard let resultData = try? JSONEncoder().encode(result),
              let resultJSON = try? JSONSerialization.jsonObject(with: resultData) else { return }
        let envelope: [String: Any] = ["jsonrpc": "2.0", "id": id, "result": resultJSON]
        guard let data = try? JSONSerialization.data(withJSONObject: envelope),
              let stdin = stdinPipe?.fileHandleForWriting else { return }
        try? stdin.write(contentsOf: data + Data("\n".utf8))
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
            break

        case .toolCallStart(let id, let kind, let title, let content):
            // ACP 0.9.0 carries no `name`/`args` on tool_call — only `kind`,
            // `title`, and a content blob. Use `title` as the user-facing
            // preview ("terminal: echo 'plan2 ok'") and serialize `content`
            // for the expandable detail.
            let record = ToolCallRecord(
                id: id,
                name: kind,
                argsPreview: title,
                argsFull: Self.makeArgsFull(args: content),
                status: .pending
            )
            currentAgentTurn?.toolCalls.append(record)

        case .toolCallUpdate(let id, let status, _):
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
