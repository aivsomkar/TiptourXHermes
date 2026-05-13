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
