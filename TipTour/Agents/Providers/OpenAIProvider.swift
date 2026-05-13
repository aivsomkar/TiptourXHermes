// TipTour/Agents/Providers/OpenAIProvider.swift

import Foundation

/// Calls the OpenAI Chat Completions API to run GPT-4o, GPT-4o-mini, o3, and future models.
/// Use this for background task agents — not for the voice main agent.
final class OpenAIProvider: LLMProvider {

    let providerId: String
    let displayName: String
    let supportsVoice = false
    /// Indicates relative cost. Used by LLMProviderRegistry for routing hints and Settings UI display.
    let costTier: LLMCostTier

    private let modelId: String
    private let apiKey: String
    private let maxTokens: Int
    private let urlSession: URLSession

    init(modelId: String, apiKey: String, maxTokens: Int = 4096) {
        self.modelId = modelId
        self.apiKey = apiKey
        self.maxTokens = maxTokens
        self.providerId = "openai-\(modelId)"
        self.displayName = "OpenAI (\(modelId))"
        self.urlSession = URLSession(configuration: .default)

        if modelId.contains("mini") {
            self.costTier = .low
        } else if modelId.contains("o3") {
            self.costTier = .high
        } else {
            self.costTier = .medium
        }
    }

    func complete(messages: [LLMMessage], tools: [LLMTool]) async throws -> LLMCompletionResult {
        guard !apiKey.isEmpty else {
            throw LLMProviderError.missingAPIKey(providerName: "OpenAI")
        }

        let requestBody = try buildRequestBody(messages: messages, tools: tools)
        let httpRequest = try buildHTTPRequest(body: requestBody)
        let (data, response) = try await urlSession.data(for: httpRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMProviderError.decodingError("No HTTP response from OpenAI")
        }

        guard httpResponse.statusCode == 200 else {
            let bodyString = String(data: data, encoding: .utf8) ?? "(unreadable body)"
            throw LLMProviderError.httpError(statusCode: httpResponse.statusCode, body: bodyString)
        }

        return try parseResponse(data: data)
    }

    func parseTokenUsage(from json: [String: Any]) -> LLMTokenUsage? {
        guard let usage = json["usage"] as? [String: Any],
              let input = usage["prompt_tokens"] as? Int,
              let output = usage["completion_tokens"] as? Int,
              let total = usage["total_tokens"] as? Int else { return nil }
        return LLMTokenUsage(inputTokens: input, outputTokens: output, totalTokens: total)
    }

    // MARK: - Private helpers

    private func buildRequestBody(messages: [LLMMessage], tools: [LLMTool]) throws -> Data {
        var bodyDict: [String: Any] = [
            "model": modelId,
            "max_tokens": maxTokens,
            "messages": messages.map { convertMessageToOpenAIDict($0) }
        ]

        if !tools.isEmpty {
            bodyDict["tools"] = tools.map { convertToolToOpenAIDict($0) }
            bodyDict["tool_choice"] = "auto"
        }

        return try JSONSerialization.data(withJSONObject: bodyDict)
    }

    private func convertMessageToOpenAIDict(_ message: LLMMessage) -> [String: Any] {
        switch message.role {
        case .tool:
            // OpenAI tool results use role="tool" with tool_call_id
            return [
                "role": "tool",
                "tool_call_id": message.toolCallId ?? "",
                "content": message.content
            ]
        case .system:
            return ["role": "system", "content": message.content]
        case .assistant:
            // When the assistant turn carried tool calls, OpenAI
            // requires them on a `tool_calls` array so the
            // subsequent role="tool" messages with matching
            // tool_call_id are valid. Without this, OpenAI rejects
            // the request as malformed.
            if let toolCalls = message.toolCalls, !toolCalls.isEmpty {
                let toolCallsArray: [[String: Any]] = toolCalls.map { call in
                    [
                        "id": call.id,
                        "type": "function",
                        "function": [
                            "name": call.name,
                            // OpenAI expects arguments as a JSON string,
                            // NOT a JSON object (unlike Anthropic).
                            "arguments": call.argumentsJSON
                        ] as [String: Any]
                    ]
                }
                var dict: [String: Any] = [
                    "role": "assistant",
                    "tool_calls": toolCallsArray
                ]
                // OpenAI allows content to be null on tool-calling turns
                // but accepts an empty string too; only include text
                // content when the model produced a non-empty preamble.
                if !message.content.isEmpty {
                    dict["content"] = message.content
                }
                return dict
            }
            return ["role": "assistant", "content": message.content]
        case .user:
            return ["role": "user", "content": message.content]
        }
    }

    private func convertToolToOpenAIDict(_ tool: LLMTool) -> [String: Any] {
        let parametersObject = (try? JSONSerialization.jsonObject(with: Data(tool.parametersJSON.utf8))) as? [String: Any] ?? [:]
        return [
            "type": "function",
            "function": [
                "name": tool.name,
                "description": tool.description,
                "parameters": parametersObject
            ]
        ]
    }

    private func buildHTTPRequest(body: Data) throws -> URLRequest {
        guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else {
            throw LLMProviderError.decodingError("Could not construct OpenAI API URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return request
    }

    private func parseResponse(data: Data) throws -> LLMCompletionResult {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any] else {
            throw LLMProviderError.decodingError("Missing 'choices[0].message' in OpenAI response")
        }

        let textContent = message["content"] as? String ?? ""
        var toolCalls: [LLMToolCall] = []

        if let rawToolCalls = message["tool_calls"] as? [[String: Any]] {
            for rawCall in rawToolCalls {
                guard let callId = rawCall["id"] as? String,
                      let function = rawCall["function"] as? [String: Any],
                      let name = function["name"] as? String,
                      !name.isEmpty else { continue }
                let argumentsJSON = function["arguments"] as? String ?? "{}"
                toolCalls.append(LLMToolCall(id: callId, name: name, argumentsJSON: argumentsJSON))
            }
        }

        let llmResponse: LLMResponse
        if toolCalls.isEmpty {
            llmResponse = .text(textContent)
        } else if textContent.isEmpty {
            llmResponse = .toolCalls(toolCalls)
        } else {
            llmResponse = .textAndToolCalls(textContent, toolCalls)
        }

        return LLMCompletionResult(response: llmResponse, tokenUsage: parseTokenUsage(from: json))
    }
}
