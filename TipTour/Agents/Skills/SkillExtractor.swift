// TipTour/Agents/Skills/SkillExtractor.swift

import Foundation

// MARK: - Errors

enum SkillExtractorError: Error, Equatable {
    case missingProvider
    case unexpectedResponse
}

// MARK: - Actor singleton

actor SkillExtractor {

    static let shared = SkillExtractor()

    // Injected in tests to avoid hitting LLMProviderRegistry or the network.
    private let providerOverride: (any LLMProvider)?

    init(providerOverride: (any LLMProvider)? = nil) {
        self.providerOverride = providerOverride
    }

    // MARK: - Public API

    /// Formats `trajectory` into text + screenshots, calls Claude, and returns
    /// the raw skill-body markdown string.
    func extract(trajectory: ActionTrajectory, name: String) async throws -> String {
        let provider = try await resolvedProvider()
        let (trajectoryText, screenshotImages) = DemonstrationRecorder.formatForLLM(trajectory)

        let systemMessage = LLMMessage(role: .system, content: Self.skillExtractionSystemPrompt)
        let userContent = "Skill name: \(name)\n\n\(trajectoryText)"
        let userMessage = LLMMessage(
            role: .user,
            content: userContent,
            imagesJPEG: screenshotImages.isEmpty ? nil : screenshotImages
        )

        let result = try await provider.complete(messages: [systemMessage, userMessage], tools: [])

        guard case .text(let body) = result.response, !body.isEmpty else {
            throw SkillExtractorError.unexpectedResponse
        }

        return body
    }

    // MARK: - Private helpers

    private func resolvedProvider() async throws -> any LLMProvider {
        if let override = providerOverride { return override }
        guard let provider = await LLMProviderRegistry.shared.provider(id: "anthropic-claude-sonnet-4-6") else {
            throw SkillExtractorError.missingProvider
        }
        return provider
    }

    // MARK: - System prompt

    private static let skillExtractionSystemPrompt = """
    You are extracting a reusable skill from a user's screen recording.
    The user performed a task step by step. Your job is to write a clear,
    numbered procedure that a future agent can follow to repeat this task.

    Format your response as:

    ## Steps

    1. [action description]
    2. [action description]
    ...

    ## Result

    [one sentence describing what the procedure accomplishes]

    Be concise. Write each step as a human-readable instruction, not code.
    Do not include timestamps or coordinates. Focus on the intent of each action.
    """
}
