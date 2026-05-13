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
