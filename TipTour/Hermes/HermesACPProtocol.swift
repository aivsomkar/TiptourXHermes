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
    /// Tool invocation announced by Hermes. Real ACP shape (verified
    /// against agent-client-protocol 0.9.0 with hermes-agent 0.13.0):
    /// no `name`/`args` fields — instead `kind` (e.g. "execute"),
    /// `title` (human-readable summary), and `content` (array of
    /// content blocks describing what's being run).
    case toolCallStart(id: String, kind: String, title: String, content: JSONValue)
    /// Status / partial output update for an in-flight tool call. The
    /// terminal event arrives as another `tool_call_update` with
    /// `status: "completed"` (or "failed") — there is no separate
    /// `tool_call_end` discriminator in 0.9.0.
    case toolCallUpdate(id: String, status: String, content: JSONValue?)
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
        case "tool_call":
            if case .string(let id) = dict["toolCallId"] ?? .null {
                let kind: String = {
                    if case .string(let k) = dict["kind"] ?? .null { return k }
                    return "tool"
                }()
                let title: String = {
                    if case .string(let t) = dict["title"] ?? .null { return t }
                    return kind
                }()
                self = .toolCallStart(
                    id: id,
                    kind: kind,
                    title: title,
                    content: dict["content"] ?? .null
                )
            } else {
                self = .unknown(raw: raw)
            }
        case "tool_call_update":
            if case .string(let id) = dict["toolCallId"] ?? .null {
                let status: String = {
                    if case .string(let s) = dict["status"] ?? .null { return s }
                    return "pending"
                }()
                self = .toolCallUpdate(id: id, status: status, content: dict["content"])
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
