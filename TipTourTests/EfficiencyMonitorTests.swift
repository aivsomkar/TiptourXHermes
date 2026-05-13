// TipTourTests/EfficiencyMonitorTests.swift

import Foundation
import Testing
@testable import TipTour

// MARK: - LLMTokenUsage tests

@Suite("LLMTokenUsage")
struct LLMTokenUsageTests {

    @Test func totalTokensMatchesSumOfInputAndOutput() {
        let usage = LLMTokenUsage(inputTokens: 100, outputTokens: 50, totalTokens: 150)
        #expect(usage.totalTokens == usage.inputTokens + usage.outputTokens)
    }
}

// MARK: - LLMCompletionResult tests

@Suite("LLMCompletionResult")
struct LLMCompletionResultTests {

    @Test func completionResultCarriesResponseAndOptionalTokenUsage() {
        let usage = LLMTokenUsage(inputTokens: 200, outputTokens: 80, totalTokens: 280)
        let result = LLMCompletionResult(response: .text("hello"), tokenUsage: usage)
        if case .text(let text) = result.response {
            #expect(text == "hello")
        } else {
            Issue.record("Expected .text response")
        }
        #expect(result.tokenUsage?.totalTokens == 280)
    }

    @Test func completionResultAllowsNilTokenUsage() {
        let result = LLMCompletionResult(response: .text("hi"), tokenUsage: nil)
        #expect(result.tokenUsage == nil)
    }
}

// MARK: - EfficiencyTypes tests

@Suite("EfficiencyTypes")
struct EfficiencyTypesTests {

    @Test func taskExecutionStoresAllFields() {
        let id = UUID()
        let history = [LLMMessage(role: .user, content: "do it")]
        let execution = TaskExecution(
            taskId: id,
            taskType: .generalMac,
            taskDescription: "Test task",
            tokensUsed: 4000,
            toolCallCount: 3,
            backtrackCount: 1,
            stepsExecuted: 10,
            duration: 12.5,
            outcome: .success(summary: "Done"),
            conversationHistory: history,
            autoSavedSkillSlug: "test-task"
        )
        #expect(execution.taskId == id)
        #expect(execution.tokensUsed == 4000)
        #expect(execution.toolCallCount == 3)
        #expect(execution.backtrackCount == 1)
        #expect(execution.autoSavedSkillSlug == "test-task")
        #expect(execution.conversationHistory.count == 1)
    }

    @Test func efficiencyReportStoresAllFields() {
        let report = EfficiencyReport(
            inefficiencyScore: 0.75,
            tokenOverrun: 2000,
            wastedSteps: 5,
            diagnosis: "Too many retries",
            didSelfCritique: true
        )
        #expect(report.inefficiencyScore == 0.75)
        #expect(report.tokenOverrun == 2000)
        #expect(report.wastedSteps == 5)
        #expect(report.didSelfCritique == true)
    }
}

// MARK: - Provider token parsing tests

@Suite("ProviderTokenParsing")
struct ProviderTokenParsingTests {

    @Test func anthropicProviderParsesTokenUsageWhenPresent() {
        let provider = AnthropicProvider(modelId: "claude-sonnet-4-6", apiKey: "test")
        let json: [String: Any] = [
            "usage": ["input_tokens": 123, "output_tokens": 456]
        ]
        let usage = provider.parseTokenUsage(from: json)
        #expect(usage?.inputTokens == 123)
        #expect(usage?.outputTokens == 456)
        #expect(usage?.totalTokens == 579)
    }

    @Test func anthropicProviderReturnsNilTokenUsageWhenUsageAbsent() {
        let provider = AnthropicProvider(modelId: "claude-sonnet-4-6", apiKey: "test")
        let usage = provider.parseTokenUsage(from: [:])
        #expect(usage == nil)
    }

    @Test func openAIProviderParsesTokenUsageWhenPresent() {
        let provider = OpenAIProvider(modelId: "gpt-4o", apiKey: "test")
        let json: [String: Any] = [
            "usage": ["prompt_tokens": 200, "completion_tokens": 100, "total_tokens": 300]
        ]
        let usage = provider.parseTokenUsage(from: json)
        #expect(usage?.inputTokens == 200)
        #expect(usage?.outputTokens == 100)
        #expect(usage?.totalTokens == 300)
    }

    @Test func geminiRestProviderParsesTokenUsageWhenPresent() {
        let provider = GeminiRestProvider(modelId: "gemini-2.5-flash", apiKey: "test")
        let json: [String: Any] = [
            "usageMetadata": ["promptTokenCount": 80, "candidatesTokenCount": 40]
        ]
        let usage = provider.parseTokenUsage(from: json)
        #expect(usage?.inputTokens == 80)
        #expect(usage?.outputTokens == 40)
        #expect(usage?.totalTokens == 120)
    }
}

// MARK: - EfficiencyMonitor tests

@Suite("EfficiencyMonitor", .serialized)
struct EfficiencyMonitorTests {

    // MARK: Helpers

    private func makeExecution(
        tokensUsed: Int = 1000,
        toolCallCount: Int = 2,
        backtrackCount: Int = 0,
        stepsExecuted: Int = 6,
        duration: TimeInterval = 10,
        autoSavedSkillSlug: String? = nil,
        conversationHistory: [LLMMessage] = []
    ) -> TaskExecution {
        TaskExecution(
            taskId: UUID(),
            taskType: .generalMac,
            taskDescription: "Find files matching *.swift",
            tokensUsed: tokensUsed,
            toolCallCount: toolCallCount,
            backtrackCount: backtrackCount,
            stepsExecuted: stepsExecuted,
            duration: duration,
            outcome: .success(summary: "Found 12 files"),
            conversationHistory: conversationHistory,
            autoSavedSkillSlug: autoSavedSkillSlug
        )
    }

    // MARK: Score formula

    @Test func scoreIsZeroForEfficientRun() async {
        let monitor = EfficiencyMonitor(tokenBudget: 8000, selfCritiqueThreshold: 0.4)
        // 1000 tokens (well within 8000 budget), 2 tool calls → expected min = 6 steps, stepsExecuted = 6
        let report = await monitor.evaluate(makeExecution(tokensUsed: 1000, toolCallCount: 2, stepsExecuted: 6))
        #expect(report.inefficiencyScore == 0.0)
        #expect(report.didSelfCritique == false)
    }

    @Test func tokenOverrunAndWastedStepsCombinedPushScoreAboveThreshold() async {
        let monitor = EfficiencyMonitor(tokenBudget: 8000, selfCritiqueThreshold: 0.4, providerOverride: nil)
        // 24000 tokens + 26 steps with toolCallCount=2 (expectedMin=6) → wastedSteps=20
        // overrunFraction = min(0.5, 16000/8000) = 0.5 → token contribution = 0.25
        // wastedStepFraction = min(1.0, 20/10) = 1.0 → step contribution = 0.3
        // total = 0.55 > 0.4
        let report = await monitor.evaluate(makeExecution(
            tokensUsed: 24000,
            toolCallCount: 2,
            stepsExecuted: 26
        ))
        #expect(report.inefficiencyScore > 0.4)
        // No provider → no self-critique
        #expect(report.didSelfCritique == false)
    }

    @Test func wastedStepsAlonePushesScoreAboveCustomThreshold() async {
        // Score from wasted steps alone: wastedStepFraction=1.0 → contribution=0.3
        // Use a custom threshold of 0.25 to verify wasted steps alone exceed it
        let lowThresholdMonitor = EfficiencyMonitor(tokenBudget: 8000, selfCritiqueThreshold: 0.25, providerOverride: nil)
        // toolCallCount=2 → expectedMinSteps=6. stepsExecuted=50 → wastedSteps=44
        // wastedStepFraction = min(1.0, 44/10) = 1.0. score contribution = 0.3 > 0.25.
        let report = await lowThresholdMonitor.evaluate(makeExecution(
            tokensUsed: 1000,
            toolCallCount: 2,
            stepsExecuted: 50
        ))
        #expect(report.inefficiencyScore > 0.25)
        #expect(report.wastedSteps == 44)
    }

    @Test func combinedOverrunAndWastedStepsProduceHigherScore() async {
        let monitor = EfficiencyMonitor(tokenBudget: 8000, selfCritiqueThreshold: 0.4, providerOverride: nil)
        let efficientReport = await monitor.evaluate(makeExecution(tokensUsed: 1000, toolCallCount: 2, stepsExecuted: 6))
        let inefficientReport = await monitor.evaluate(makeExecution(tokensUsed: 24000, toolCallCount: 2, stepsExecuted: 26))
        #expect(inefficientReport.inefficiencyScore > efficientReport.inefficiencyScore)
    }

    @Test func backtrackFractionCappedAt0point3() async {
        let monitor = EfficiencyMonitor(tokenBudget: 8000, selfCritiqueThreshold: 0.4, providerOverride: nil)
        // 100 backtracks → min(0.3, 100*0.1) = 0.3. Same as 3 backtracks.
        let report3 = await monitor.evaluate(makeExecution(backtrackCount: 3))
        let report100 = await monitor.evaluate(makeExecution(backtrackCount: 100))
        #expect(report3.inefficiencyScore == report100.inefficiencyScore)
    }

    @Test func inefficiencyScoreCappedAt1point0() async {
        let monitor = EfficiencyMonitor(tokenBudget: 8000, selfCritiqueThreshold: 0.4, providerOverride: nil)
        let report = await monitor.evaluate(makeExecution(
            tokensUsed: 1_000_000,
            toolCallCount: 0,
            backtrackCount: 1000,
            stepsExecuted: 10000
        ))
        #expect(report.inefficiencyScore <= 1.0)
    }

    // MARK: Gate test

    @Test func scoreBelowThresholdSkipsSelfCritique() async {
        let mockProvider = MockLLMProvider(id: "efficiency-gate-test")
        mockProvider.responseToReturn = .text("should not be called")
        let monitor = EfficiencyMonitor(tokenBudget: 8000, selfCritiqueThreshold: 0.4, providerOverride: mockProvider)

        // Efficient run: score will be 0.0
        let report = await monitor.evaluate(makeExecution(tokensUsed: 1000, toolCallCount: 2, stepsExecuted: 6))

        #expect(report.didSelfCritique == false)
        // Provider should not have been called
        #expect(mockProvider.capturedMessages.isEmpty)
    }

    // MARK: Self-critique output tests

    @Test func validXMLResponseProducesDiagnosis() async {
        let mockProvider = MockLLMProvider(id: "efficiency-valid-xml")
        mockProvider.responseToReturn = .text("""
        <diagnosis>The agent made redundant tool calls by re-reading the same files multiple times.</diagnosis>
        <improved_skill>1. Read directory once\n2. Process all matching files in a single pass\n3. Report results</improved_skill>
        <lesson>Cache file listings instead of re-querying the same directory.</lesson>
        """)
        let monitor = EfficiencyMonitor(tokenBudget: 8000, selfCritiqueThreshold: 0.4, providerOverride: mockProvider)

        // Run that scores above threshold (24000 tokens + 26 steps)
        let report = await monitor.evaluate(makeExecution(
            tokensUsed: 24000,
            toolCallCount: 2,
            stepsExecuted: 26,
            autoSavedSkillSlug: "find-swift-files"
        ))

        #expect(report.didSelfCritique == true)
        #expect(!report.diagnosis.isEmpty)
        #expect(report.diagnosis.contains("redundant"))
    }

    @Test func malformedXMLResponseProducesEmptyDiagnosis() async {
        let mockProvider = MockLLMProvider(id: "efficiency-malformed-xml")
        mockProvider.responseToReturn = .text("This is not XML at all.")
        let monitor = EfficiencyMonitor(tokenBudget: 8000, selfCritiqueThreshold: 0.4, providerOverride: mockProvider)

        let report = await monitor.evaluate(makeExecution(
            tokensUsed: 24000, toolCallCount: 2, stepsExecuted: 26
        ))

        #expect(report.didSelfCritique == true)
        #expect(report.diagnosis.isEmpty)
    }

    @Test func noAutoSavedSkillSlugSkipsSkillWrite() async {
        let mockProvider = MockLLMProvider(id: "efficiency-no-slug")
        mockProvider.responseToReturn = .text("""
        <diagnosis>Too slow.</diagnosis>
        <improved_skill>1. Do it faster</improved_skill>
        <lesson>Be faster next time.</lesson>
        """)
        let monitor = EfficiencyMonitor(tokenBudget: 8000, selfCritiqueThreshold: 0.4, providerOverride: mockProvider)

        // autoSavedSkillSlug is nil — skill write must be skipped, no crash
        let report = await monitor.evaluate(makeExecution(
            tokensUsed: 24000, toolCallCount: 2, stepsExecuted: 26,
            autoSavedSkillSlug: nil
        ))

        #expect(report.didSelfCritique == true)
    }

    @Test func providerThrowCausesNonCritiquedReport() async {
        let mockProvider = MockLLMProvider(id: "efficiency-throw")
        mockProvider.shouldThrow = true
        let monitor = EfficiencyMonitor(tokenBudget: 8000, selfCritiqueThreshold: 0.4, providerOverride: mockProvider)

        let report = await monitor.evaluate(makeExecution(
            tokensUsed: 24000, toolCallCount: 2, stepsExecuted: 26
        ))

        #expect(report.didSelfCritique == false)
    }
}

// MARK: - TaskAgent instrumentation tests

@Suite("TaskAgentEfficiencyInstrumentation", .serialized)
struct TaskAgentEfficiencyInstrumentationTests {

    @Test func tokensUsedAccumulatesAcrossMultipleCompleteCalls() async {
        let swarm = AgentSwarmManager()
        let mockProvider = MockLLMProvider(id: "token-accumulate-test")
        mockProvider.tokenUsageToReturn = LLMTokenUsage(inputTokens: 100, outputTokens: 50, totalTokens: 150)

        // Return tool calls first (to force a second loop iteration), then text
        var callCount = 0
        mockProvider.responseFactory = {
            callCount += 1
            if callCount == 1 {
                return .toolCalls([LLMToolCall(id: "tc1", name: "run_shell_command", argumentsJSON: "{\"command\":\"ls\"}")])
            }
            return .text("Done.")
        }

        let agent = TaskAgent(
            taskDescription: "list files",
            taskType: .generalMac,
            provider: mockProvider,
            swarmManager: swarm
        )

        await agent.run()

        // Two complete() calls: each adds 150 tokens → total = 300
        let status = await agent.currentStatus
        #expect(status.tokensUsed == 300)
    }

    @Test func toolCallCountIncrementsOncePerDispatch() async {
        let swarm = AgentSwarmManager()
        let mockProvider = MockLLMProvider(id: "tool-count-test")

        var callCount = 0
        mockProvider.responseFactory = {
            callCount += 1
            if callCount == 1 {
                // Return 2 tool calls in one response
                return .toolCalls([
                    LLMToolCall(id: "tc1", name: "run_shell_command", argumentsJSON: "{\"command\":\"ls\"}"),
                    LLMToolCall(id: "tc2", name: "run_shell_command", argumentsJSON: "{\"command\":\"pwd\"}")
                ])
            }
            return .text("Done with two tool calls.")
        }

        let agent = TaskAgent(
            taskDescription: "run two commands",
            taskType: .generalMac,
            provider: mockProvider,
            swarmManager: swarm
        )

        await agent.run()

        let toolCallCount = await agent.toolCallCount
        #expect(toolCallCount == 2)
    }

    @Test func backtrackCountIncrementsOncePerInterruptBatch() async {
        let swarm = AgentSwarmManager()
        let mockProvider = MockLLMProvider(id: "backtrack-count-test")
        mockProvider.responseToReturn = .text("Done.")

        let agent = TaskAgent(
            taskDescription: "do something",
            taskType: .generalMac,
            provider: mockProvider,
            swarmManager: swarm
        )

        // Queue two interrupts in one batch before run() is called
        await agent.receive(AgentMessage(
            from: .main,
            to: .task(agent.id),
            type: .interrupt(instruction: "First correction")
        ))
        await agent.receive(AgentMessage(
            from: .main,
            to: .task(agent.id),
            type: .interrupt(instruction: "Second correction in same batch")
        ))

        await agent.run()

        // Both interrupts arrive in one non-empty batch → backtrackCount == 1
        let backtrackCount = await agent.backtrackCount
        #expect(backtrackCount == 1)
    }

    @Test func buildTaskExecutionCapturesCorrectStepsExecuted() async {
        let swarm = AgentSwarmManager()
        let mockProvider = MockLLMProvider(id: "steps-test")
        mockProvider.responseToReturn = .text("Done in one step.")

        let agent = TaskAgent(
            taskDescription: "simple task",
            taskType: .generalMac,
            provider: mockProvider,
            swarmManager: swarm
        )

        await agent.run()

        let status = await agent.currentStatus
        #expect(status.stepHistory.count >= 1)
        // Verify tokensUsed is 0 since mock has no tokenUsage set
        #expect(status.tokensUsed == 0)
    }
}
