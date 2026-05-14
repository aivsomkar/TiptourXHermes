// TipTour/Hermes/MCPTools.swift
//
// MCP tool protocol shared by all Plan 3b tools (take_screenshot,
// get_a11y_tree, point_at) and any future MCP tools. New tools
// conform to MCPTool and register with MCPServer.

import Foundation

// MARK: - Tool protocol

// A single piece of content returned by a tool call. Mirrors the MCP
// spec's content-block shape so MCPServer can serialise it directly.
enum MCPToolContent {
    case text(String)
    case image(base64: String, mimeType: String)
}

protocol MCPTool: Sendable {
    /// Tool identifier passed to MCP tools/list and tools/call.
    var name: String { get }
    /// Human-readable description shown to Hermes for tool selection.
    var description: String { get }
    /// JSON Schema describing the expected `arguments` object.
    var inputSchema: JSONValue { get }
    /// Run the tool. Return one or more content blocks (text, image, or
    /// both). Throw `MCPToolError` to indicate a tool failure.
    @MainActor func call(_ arguments: JSONValue) async throws -> [MCPToolContent]
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
