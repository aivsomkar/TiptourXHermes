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
        // Use a background queue so the state callback is not blocked by the
        // semaphore wait below (which runs on @MainActor / the main thread).
        listener.start(queue: netQueue)

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
    /// Dedicated background queue for all NWListener / NWConnection callbacks.
    /// Using a background queue prevents the semaphore wait in `start()` (which
    /// runs on @MainActor) from deadlocking the state-update handlers.
    private let netQueue = DispatchQueue(label: "mcp-server-net", qos: .userInitiated)

    // MARK: - Connection lifecycle

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: netQueue)
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
                let blocks = try await tool.call(arguments)
                let contentJSON: [[String: Any]] = blocks.map { block in
                    switch block {
                    case .text(let s):
                        return ["type": "text", "text": s]
                    case .image(let b64, let mime):
                        return ["type": "image", "data": b64, "mimeType": mime]
                    }
                }
                let result: [String: Any] = [
                    "content": contentJSON,
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
