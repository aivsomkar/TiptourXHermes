// TipTour/Hermes/MCPTools.swift
//
// MCP tool protocol and the Plan-3a `speak` implementation. New tools
// (Plan 3b: take_screenshot, get_a11y_tree, point_at) are added by
// conforming to MCPTool and registering with MCPServer.

import Foundation
import AVFoundation

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

    func call(_ arguments: JSONValue) async throws -> [MCPToolContent] {
        guard case .object(let dict) = arguments,
              case .string(let text) = dict["text"] ?? .null,
              !text.isEmpty
        else {
            throw MCPToolError.invalidArguments("speak requires a non-empty `text` string")
        }

        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synth.speak(utterance)
        return [.text("Speaking: \(text)")]
    }
}
