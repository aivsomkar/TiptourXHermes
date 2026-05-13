// TipTour/Agents/Providers/GeminiRestProvider.swift

import Foundation

/// Calls the Gemini generateContent REST API for background task agents.
/// Distinct from GeminiLiveSession (which uses a persistent WebSocket for voice).
/// Supports gemini-2.5-flash, gemini-2.5-pro, gemini-2.5-flash-lite, etc.
final class GeminiRestProvider: LLMProvider {

    let providerId: String
    let displayName: String
    let supportsVoice = false
    /// Indicates relative cost. Used by LLMProviderRegistry for routing hints and Settings UI display.
    let costTier: LLMCostTier

    private let modelId: String
    private let apiKey: String
    private let urlSession: URLSession

    init(modelId: String, apiKey: String) {
        self.modelId = modelId
        self.apiKey = apiKey
        self.providerId = "gemini-rest-\(modelId)"
        self.displayName = "Gemini (\(modelId))"
        self.urlSession = URLSession(configuration: .default)

        if modelId.contains("lite") || modelId.contains("flash") {
            self.costTier = .low
        } else {
            self.costTier = .medium
        }
    }

    func complete(messages: [LLMMessage], tools: [LLMTool]) async throws -> LLMCompletionResult {
        guard !apiKey.isEmpty else {
            throw LLMProviderError.missingAPIKey(providerName: "Gemini")
        }

        let requestBody = try buildRequestBody(messages: messages, tools: tools)
        let httpRequest = try buildHTTPRequest(body: requestBody)
        let (data, response) = try await urlSession.data(for: httpRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMProviderError.decodingError("No HTTP response from Gemini")
        }

        guard httpResponse.statusCode == 200 else {
            let bodyString = String(data: data, encoding: .utf8) ?? "(unreadable body)"
            throw LLMProviderError.httpError(statusCode: httpResponse.statusCode, body: bodyString)
        }

        return try parseResponse(data: data)
    }

    func parseTokenUsage(from json: [String: Any]) -> LLMTokenUsage? {
        guard let meta = json["usageMetadata"] as? [String: Any],
              let input = meta["promptTokenCount"] as? Int,
              let output = meta["candidatesTokenCount"] as? Int else { return nil }
        return LLMTokenUsage(inputTokens: input, outputTokens: output, totalTokens: input + output)
    }

    // MARK: - Private helpers

    private func buildRequestBody(messages: [LLMMessage], tools: [LLMTool]) throws -> Data {
        // Gemini separates the system instruction from conversation contents
        let systemContent = messages.first(where: { $0.role == .system })?.content
        let conversationMessages = messages.filter { $0.role != .system }

        var bodyDict: [String: Any] = [
            "contents": conversationMessages.map { convertMessageToGeminiDict($0) }
        ]

        if let systemContent {
            bodyDict["system_instruction"] = ["parts": [["text": systemContent]]]
        }

        if !tools.isEmpty {
            bodyDict["tools"] = [["function_declarations": tools.map { convertToolToGeminiDict($0) }]]
        }

        return try JSONSerialization.data(withJSONObject: bodyDict)
    }

    private func convertMessageToGeminiDict(_ message: LLMMessage) -> [String: Any] {
        // Gemini uses "user" and "model" roles; tool results go as "user" function_response parts
        switch message.role {
        case .tool:
            return [
                "role": "user",
                "parts": [[
                    "function_response": [
                        "name": message.toolName ?? "",
                        "response": ["result": message.content]
                    ]
                ]]
            ]
        case .assistant:
            // When the assistant turn carried tool calls, Gemini
            // requires `function_call` parts on the corresponding
            // model turn so it can match the subsequent
            // function_response back to the original call. Without
            // these the next request fails Gemini's content-block
            // validation.
            if let toolCalls = message.toolCalls, !toolCalls.isEmpty {
                var parts: [[String: Any]] = []
                if !message.content.isEmpty {
                    parts.append(["text": message.content])
                }
                for call in toolCalls {
                    let argsDict: [String: Any]
                    if let argsData = call.argumentsJSON.data(using: .utf8),
                       let parsed = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any] {
                        argsDict = parsed
                    } else {
                        argsDict = [:]
                    }
                    parts.append([
                        "function_call": [
                            "name": call.name,
                            "args": argsDict
                        ] as [String: Any]
                    ])
                }
                return ["role": "model", "parts": parts]
            }
            return ["role": "model", "parts": [["text": message.content]]]
        default:
            return ["role": "user", "parts": [["text": message.content]]]
        }
    }

    private func convertToolToGeminiDict(_ tool: LLMTool) -> [String: Any] {
        let parametersObject = (try? JSONSerialization.jsonObject(with: Data(tool.parametersJSON.utf8))) as? [String: Any] ?? [:]
        return [
            "name": tool.name,
            "description": tool.description,
            "parameters": parametersObject
        ]
    }

    private func buildHTTPRequest(body: Data) throws -> URLRequest {
        let urlString = "https://generativelanguage.googleapis.com/v1beta/models/\(modelId):generateContent?key=\(apiKey)"
        guard let url = URL(string: urlString) else {
            throw LLMProviderError.decodingError("Could not construct Gemini API URL for model '\(modelId)'")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return request
    }

    private func parseResponse(data: Data) throws -> LLMCompletionResult {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let firstCandidate = candidates.first,
              let content = firstCandidate["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            throw LLMProviderError.decodingError("Unexpected Gemini response structure — missing candidates[0].content.parts")
        }

        var textParts: [String] = []
        var toolCalls: [LLMToolCall] = []

        for part in parts {
            if let text = part["text"] as? String {
                textParts.append(text)
            } else if let functionCall = part["function_call"] as? [String: Any],
                      let name = functionCall["name"] as? String,
                      !name.isEmpty {
                let args = functionCall["args"] as? [String: Any] ?? [:]
                let argumentsJSON = (try? JSONSerialization.data(withJSONObject: args))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                toolCalls.append(LLMToolCall(id: UUID().uuidString, name: name, argumentsJSON: argumentsJSON))
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
