// TipTour/Agents/Providers/AnthropicProvider.swift

import Foundation

/// Calls the Anthropic Messages API to run Claude models (Haiku, Sonnet, Opus).
/// Use this for background task agents — not for the voice main agent (which uses GeminiLiveSession).
final class AnthropicProvider: LLMProvider {

    let providerId: String
    let displayName: String
    let supportsVoice = false
    /// Indicates relative cost. Used by LLMProviderRegistry for routing hints and Settings UI display.
    let costTier: LLMCostTier

    private let modelId: String
    private let apiKey: String
    private let maxTokens: Int
    private let urlSession: URLSession

    init(modelId: String, apiKey: String, maxTokens: Int = 8192) {
        self.modelId = modelId
        self.apiKey = apiKey
        self.maxTokens = maxTokens
        self.providerId = "anthropic-\(modelId)"
        self.displayName = "Claude (\(modelId))"
        self.urlSession = URLSession(configuration: .default)

        if modelId.contains("haiku") {
            self.costTier = .low
        } else if modelId.contains("opus") {
            self.costTier = .high
        } else {
            self.costTier = .medium
        }
    }

    func complete(messages: [LLMMessage], tools: [LLMTool]) async throws -> LLMCompletionResult {
        guard !apiKey.isEmpty else {
            throw LLMProviderError.missingAPIKey(providerName: "Anthropic")
        }

        let requestBody = try buildRequestBody(messages: messages, tools: tools)
        let httpRequest = buildHTTPRequest(body: requestBody)
        let (data, response) = try await urlSession.data(for: httpRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMProviderError.decodingError("No HTTP response received from Anthropic")
        }

        guard httpResponse.statusCode == 200 else {
            let bodyString = String(data: data, encoding: .utf8) ?? "(unreadable body)"
            throw LLMProviderError.httpError(statusCode: httpResponse.statusCode, body: bodyString)
        }

        return try parseResponse(data: data)
    }

    func parseTokenUsage(from json: [String: Any]) -> LLMTokenUsage? {
        guard let usage = json["usage"] as? [String: Any],
              let input = usage["input_tokens"] as? Int,
              let output = usage["output_tokens"] as? Int else { return nil }
        return LLMTokenUsage(inputTokens: input, outputTokens: output, totalTokens: input + output)
    }

    // MARK: - Private helpers

    private func buildRequestBody(messages: [LLMMessage], tools: [LLMTool]) throws -> Data {
        // Anthropic takes the system message as a top-level field, not inside the messages array
        let systemContent = messages.first(where: { $0.role == .system })?.content
        let nonSystemMessages = messages.filter { $0.role != .system }

        var bodyDict: [String: Any] = [
            "model": modelId,
            "max_tokens": maxTokens,
            "messages": nonSystemMessages.map { convertMessageToAnthropicDict($0) }
        ]

        if let systemContent {
            bodyDict["system"] = systemContent
        }

        if !tools.isEmpty {
            bodyDict["tools"] = tools.map { convertToolToAnthropicDict($0) }
        }

        return try JSONSerialization.data(withJSONObject: bodyDict)
    }

    private func convertMessageToAnthropicDict(_ message: LLMMessage) -> [String: Any] {
        switch message.role {
        case .tool:
            // Anthropic tool results must be wrapped in a user-role message with content blocks
            return [
                "role": "user",
                "content": [[
                    "type": "tool_result",
                    "tool_use_id": message.toolCallId ?? "",
                    "content": message.content
                ]]
            ]
        case .assistant:
            // Anthropic strictly requires that any `tool_result` block in
            // a user turn references a `tool_use` id from the preceding
            // assistant turn. When the assistant turn carried tool calls
            // we MUST re-emit them as `tool_use` content blocks here —
            // otherwise the API rejects the next request with:
            //   "unexpected tool_use_id found in tool_result blocks.
            //    Each tool_result block must have a corresponding
            //    tool_use block in the previous message."
            if let toolCalls = message.toolCalls, !toolCalls.isEmpty {
                var contentBlocks: [[String: Any]] = []
                // Anthropic allows mixed content: optional preamble
                // text block, followed by one tool_use block per call.
                if !message.content.isEmpty {
                    contentBlocks.append([
                        "type": "text",
                        "text": message.content
                    ])
                }
                for call in toolCalls {
                    // Parse the argumentsJSON into a dict so we can
                    // embed it as a real object — Anthropic wants
                    // input as a JSON object, NOT a JSON string.
                    let inputDict: [String: Any]
                    if let argsData = call.argumentsJSON.data(using: .utf8),
                       let parsed = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any] {
                        inputDict = parsed
                    } else {
                        inputDict = [:]
                    }
                    contentBlocks.append([
                        "type": "tool_use",
                        "id": call.id,
                        "name": call.name,
                        "input": inputDict
                    ])
                }
                return ["role": "assistant", "content": contentBlocks]
            }
            return ["role": "assistant", "content": message.content]
        default:
            // When images are attached, send a content-block array (images first, then text).
            // The Anthropic Messages API requires base64 JPEG in the "source.data" field.
            if let images = message.imagesJPEG, !images.isEmpty {
                var contentBlocks: [[String: Any]] = images.map { imageData in
                    [
                        "type": "image",
                        "source": [
                            "type": "base64",
                            "media_type": "image/jpeg",
                            "data": imageData.base64EncodedString()
                        ] as [String: Any]
                    ] as [String: Any]
                }
                contentBlocks.append(["type": "text", "text": message.content])
                return ["role": "user", "content": contentBlocks]
            }
            return ["role": "user", "content": message.content]
        }
    }

    private func convertToolToAnthropicDict(_ tool: LLMTool) -> [String: Any] {
        // Anthropic uses "input_schema" for the JSON Schema definition
        let parametersObject = (try? JSONSerialization.jsonObject(with: Data(tool.parametersJSON.utf8))) as? [String: Any] ?? [:]
        return [
            "name": tool.name,
            "description": tool.description,
            "input_schema": parametersObject
        ]
    }

    private func buildHTTPRequest(body: Data) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = body
        return request
    }

    private func parseResponse(data: Data) throws -> LLMCompletionResult {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let contentArray = json["content"] as? [[String: Any]] else {
            throw LLMProviderError.decodingError("Missing 'content' array in Anthropic response")
        }

        var textParts: [String] = []
        var toolCalls: [LLMToolCall] = []

        for block in contentArray {
            guard let blockType = block["type"] as? String else { continue }

            switch blockType {
            case "text":
                if let text = block["text"] as? String {
                    textParts.append(text)
                }
            case "tool_use":
                let callId = block["id"] as? String ?? UUID().uuidString
                let name = block["name"] as? String ?? ""
                let input = block["input"] as? [String: Any] ?? [:]
                let argumentsJSON = (try? JSONSerialization.data(withJSONObject: input))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                toolCalls.append(LLMToolCall(id: callId, name: name, argumentsJSON: argumentsJSON))
            default:
                break
            }
        }

        let combinedText = textParts.joined(separator: "\n")
        let llmResponse: LLMResponse
        if toolCalls.isEmpty {
            llmResponse = .text(combinedText)
        } else if combinedText.isEmpty {
            llmResponse = .toolCalls(toolCalls)
        } else {
            llmResponse = .textAndToolCalls(combinedText, toolCalls)
        }

        return LLMCompletionResult(response: llmResponse, tokenUsage: parseTokenUsage(from: json))
    }
}
