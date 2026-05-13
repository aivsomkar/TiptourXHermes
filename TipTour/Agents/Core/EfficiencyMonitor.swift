// TipTour/Agents/Core/EfficiencyMonitor.swift

import Foundation

actor EfficiencyMonitor {

    static let shared = EfficiencyMonitor()

    private let tokenBudget: Int
    private let providerOverride: (any LLMProvider)?
    private let selfCritiqueThresholdOverride: Double?

    init(
        tokenBudget: Int = 8_000,
        selfCritiqueThreshold: Double? = nil,
        providerOverride: (any LLMProvider)? = nil
    ) {
        self.tokenBudget = tokenBudget
        self.selfCritiqueThresholdOverride = selfCritiqueThreshold
        self.providerOverride = providerOverride
    }

    // MARK: - Public API

    @discardableResult
    func evaluate(_ execution: TaskExecution) async -> EfficiencyReport {
        let tokenOverrun = max(0, execution.tokensUsed - tokenBudget)
        let tokenOverrunFraction = min(0.5, Double(tokenOverrun) / Double(tokenBudget))

        let expectedMinSteps = (execution.toolCallCount * 2) + 2
        let wastedSteps = max(0, execution.stepsExecuted - expectedMinSteps)
        let wastedStepFraction = min(1.0, Double(wastedSteps) / 10.0)

        let backtrackFraction = min(0.3, Double(execution.backtrackCount) * 0.1)

        let inefficiencyScore = min(1.0,
            tokenOverrunFraction * 0.5
            + wastedStepFraction  * 0.3
            + backtrackFraction   * 0.2
        )

        let selfCritiqueThreshold = selfCritiqueThresholdOverride
            ?? (UserDefaults.standard.object(forKey: "selfCritiqueThreshold") as? Double)
            ?? 0.4
        guard inefficiencyScore > selfCritiqueThreshold else {
            return EfficiencyReport(
                inefficiencyScore: inefficiencyScore,
                tokenOverrun: tokenOverrun,
                wastedSteps: wastedSteps,
                diagnosis: "",
                didSelfCritique: false
            )
        }

        return await selfCritique(
            execution: execution,
            inefficiencyScore: inefficiencyScore,
            tokenOverrun: tokenOverrun,
            wastedSteps: wastedSteps
        )
    }

    // MARK: - Private

    private func selfCritique(
        execution: TaskExecution,
        inefficiencyScore: Double,
        tokenOverrun: Int,
        wastedSteps: Int
    ) async -> EfficiencyReport {
        let resolvedProvider: (any LLMProvider)?
        if let override = providerOverride {
            resolvedProvider = override
        } else {
            resolvedProvider = await LLMProviderRegistry.shared.provider(id: "anthropic-claude-sonnet-4-6")
        }
        guard let provider = resolvedProvider else {
            return EfficiencyReport(
                inefficiencyScore: inefficiencyScore,
                tokenOverrun: tokenOverrun,
                wastedSteps: wastedSteps,
                diagnosis: "",
                didSelfCritique: false
            )
        }

        let messages = buildSelfCritiqueMessages(execution: execution)

        do {
            let result = try await provider.complete(messages: messages, tools: [])
            guard case .text(let responseText) = result.response else {
                return EfficiencyReport(
                    inefficiencyScore: inefficiencyScore,
                    tokenOverrun: tokenOverrun,
                    wastedSteps: wastedSteps,
                    diagnosis: "",
                    didSelfCritique: true
                )
            }

            let diagnosis = extractXMLTag("diagnosis", from: responseText)
            let lesson = extractXMLTag("lesson", from: responseText)

            await writeLessonIfNeeded(execution: execution, lesson: lesson)

            return EfficiencyReport(
                inefficiencyScore: inefficiencyScore,
                tokenOverrun: tokenOverrun,
                wastedSteps: wastedSteps,
                diagnosis: diagnosis,
                didSelfCritique: true
            )
        } catch {
            return EfficiencyReport(
                inefficiencyScore: inefficiencyScore,
                tokenOverrun: tokenOverrun,
                wastedSteps: wastedSteps,
                diagnosis: "",
                didSelfCritique: false
            )
        }
    }

    private func writeLessonIfNeeded(execution: TaskExecution, lesson: String) async {
        guard !lesson.isEmpty else { return }
        await AgentMemoryStore.shared.write(
            content: "\(execution.taskType.displayName): \(lesson)",
            entryType: .fact,
            taskTypes: [execution.taskType],
            permanent: true
        )
    }

    private func buildSelfCritiqueMessages(execution: TaskExecution) -> [LLMMessage] {
        let outcomeText: String
        switch execution.outcome {
        case .success: outcomeText = "success"
        case .failure: outcomeText = "failure"
        }

        let condensedHistory = execution.conversationHistory
            .suffix(20)
            .map { "\($0.role.rawValue): \(String($0.content.prefix(200)))" }
            .joined(separator: "\n")

        let userContent = """
        Task: \(execution.taskDescription)
        Tokens used: \(execution.tokensUsed) (budget: \(tokenBudget))
        Tool calls: \(execution.toolCallCount)
        Steps recorded: \(execution.stepsExecuted)
        Backtracks (user course corrections): \(execution.backtrackCount)
        Duration: \(String(format: "%.1f", execution.duration))s
        Outcome: \(outcomeText)

        Conversation history (condensed):
        \(condensedHistory)
        """

        return [
            LLMMessage(role: .system, content: Self.selfCritiqueSystemPrompt),
            LLMMessage(role: .user, content: userContent)
        ]
    }

    private func extractXMLTag(_ tag: String, from text: String) -> String {
        let open = "<\(tag)>"
        let close = "</\(tag)>"
        guard let openRange = text.range(of: open),
              let closeRange = text.range(of: close),
              openRange.upperBound <= closeRange.lowerBound else { return "" }
        return String(text[openRange.upperBound..<closeRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let selfCritiqueSystemPrompt = """
    You are reviewing a background agent's execution for efficiency.
    The agent completed the task but the run showed signs of inefficiency.
    Produce a structured self-critique in this exact XML format:

    <diagnosis>One sentence explaining the primary source of waste.</diagnosis>
    <improved_skill>A revised step-by-step procedure that would complete this task more efficiently. Write it as a numbered list of human-readable instructions.</improved_skill>
    <lesson>One sentence stating what the agent should remember for next time.</lesson>
    """
}
