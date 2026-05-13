// TipTour/Agents/Core/LLMProvider.swift

import Foundation

// MARK: - Cost tier for UI display and routing hints

enum LLMCostTier: Sendable, Equatable {
    case free, low, medium, high
}

// MARK: - Messages sent to / received from the LLM

struct LLMMessage: Codable, Sendable {
    enum Role: String, Codable, Sendable {
        case system, user, assistant, tool
    }

    let role: Role
    let content: String
    // Only set when role == .tool (the result of a tool call)
    let toolCallId: String?
    // Only set when role == .tool (which tool produced this result)
    let toolName: String?
    // JPEG screenshots to attach as vision content blocks (user messages only)
    let imagesJPEG: [Data]?
    /// Only set when role == .assistant AND the model returned tool
    /// calls on this turn. Carries the (id, name, argumentsJSON) tuples
    /// from `LLMResponse.toolCalls` / `.textAndToolCalls` so the
    /// provider can re-emit them as proper `tool_use` content blocks
    /// on the next request.
    ///
    /// Why this matters: Anthropic strictly validates that every
    /// `tool_result` in a user turn has a matching `tool_use` id in
    /// the immediately preceding assistant turn. Before this field
    /// existed, the assistant turn for a tool-call response was
    /// serialised as plain text "[tool calls]" with no tool_use
    /// blocks, and the subsequent request failed with:
    ///   "unexpected tool_use_id found in tool_result blocks. Each
    ///    tool_result block must have a corresponding tool_use block
    ///    in the previous message."
    /// Storing the calls here lets `AnthropicProvider` reconstruct the
    /// `tool_use` blocks faithfully.
    let toolCalls: [LLMToolCall]?

    init(
        role: Role,
        content: String,
        toolCallId: String? = nil,
        toolName: String? = nil,
        imagesJPEG: [Data]? = nil,
        toolCalls: [LLMToolCall]? = nil
    ) {
        self.role = role
        self.content = content
        self.toolCallId = toolCallId
        self.toolName = toolName
        self.imagesJPEG = imagesJPEG
        self.toolCalls = toolCalls
    }
}

// MARK: - Tool definitions given to the LLM

struct LLMTool: Sendable {
    /// The function name the LLM will use when calling this tool.
    let name: String
    /// Human-readable description injected into the system prompt.
    let description: String
    /// Raw JSON string representing the JSON Schema for this tool's parameters.
    /// Example: "{\"type\":\"object\",\"properties\":{\"url\":{\"type\":\"string\"}}}"
    let parametersJSON: String
}

// MARK: - A tool call the LLM wants to make

struct LLMToolCall: Sendable, Codable {
    let id: String
    let name: String
    /// Raw JSON string of the arguments. Parse with JSONSerialization.
    let argumentsJSON: String
}

extension LLMToolCall {
    /// Convenience for decoding the raw JSON arguments string into a dictionary.
    /// Call sites should use this instead of calling JSONSerialization directly.
    func decodedArguments() throws -> [String: Any] {
        guard let data = argumentsJSON.data(using: .utf8),
              let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMProviderError.decodingError("Could not decode tool call arguments as JSON object for tool '\(name)'")
        }
        return dict
    }
}

// MARK: - What the LLM sends back

enum LLMResponse: Sendable {
    case text(String)
    case toolCalls([LLMToolCall])
    case textAndToolCalls(String, [LLMToolCall])
}

// MARK: - Streaming chunk (for future streaming support)

enum LLMChunk: Sendable {
    case textDelta(String)
    case toolCallDelta(id: String, name: String, argumentsDelta: String)
    case finished
}

// MARK: - Token usage and completion result

struct LLMTokenUsage: Sendable {
    let inputTokens: Int
    let outputTokens: Int
    let totalTokens: Int
}

struct LLMCompletionResult: Sendable {
    let response: LLMResponse
    let tokenUsage: LLMTokenUsage?
}

// MARK: - Errors

enum LLMProviderError: Error, LocalizedError {
    case missingAPIKey(providerName: String)
    case httpError(statusCode: Int, body: String)
    case decodingError(String)
    case unsupportedOperation(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let name): return "\(name) API key not configured. Add it in TipTour Settings → Agents."
        case .httpError(let code, let body): return "HTTP \(code): \(body)"
        case .decodingError(let detail): return "Response parsing failed: \(detail)"
        case .unsupportedOperation(let detail): return "Unsupported: \(detail)"
        }
    }
}

// MARK: - The protocol every provider implements

protocol LLMProvider: Sendable {
    /// Stable identifier used in TaskProfile and settings persistence.
    var providerId: String { get }
    /// Human-readable name for display in Settings UI.
    var displayName: String { get }
    /// True only for real-time voice-capable providers (Gemini Live, OpenAI Realtime).
    var supportsVoice: Bool { get }
    /// Indicates relative cost. Used by LLMProviderRegistry for routing hints and Settings UI display.
    var costTier: LLMCostTier { get }

    /// Single-shot completion. Returns the full response once the model finishes.
    func complete(messages: [LLMMessage], tools: [LLMTool]) async throws -> LLMCompletionResult
}
