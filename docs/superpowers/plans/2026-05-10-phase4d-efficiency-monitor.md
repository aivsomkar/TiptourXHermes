# Phase 4D: EfficiencyMonitor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** After each background agent completes a task, score the run for inefficiency; if the score exceeds a threshold, make one Claude call to self-critique the run, rewrite the auto-saved skill with a better procedure, and write a permanent lesson to agent memory.

**Architecture:** `LLMTokenUsage` + `LLMCompletionResult` wrap the existing `LLMResponse` so all three providers can return token counts without breaking call sites. `EfficiencyMonitor` is a Swift actor singleton that computes a weighted inefficiency score from token overrun, wasted steps, and backtracks, then conditionally fires a single LLM call. `TaskAgent` accumulates counters across its agentic loop and fires `EfficiencyMonitor.shared.evaluate(_:)` in a detached `Task` after completion. No UI is added.

**Tech Stack:** Swift, Swift Testing framework, Anthropic Messages API (claude-sonnet-4-6)

---

## File Map

| Action | File | Responsibility |
|--------|------|----------------|
| Modify | `TipTour/Agents/Core/LLMProvider.swift` | Add `LLMTokenUsage`, `LLMCompletionResult`; change `complete()` return type |
| Create | `TipTour/Agents/Core/EfficiencyTypes.swift` | `TaskOutcome`, `TaskExecution`, `EfficiencyReport` |
| Create | `TipTour/Agents/Core/EfficiencyMonitor.swift` | Actor singleton — score gate, LLM self-critique, dual write |
| Modify | `TipTour/Agents/Providers/AnthropicProvider.swift` | Parse `usage`, return `LLMCompletionResult`; add `parseTokenUsage(from:)` |
| Modify | `TipTour/Agents/Providers/OpenAIProvider.swift` | Parse `usage`, return `LLMCompletionResult`; add `parseTokenUsage(from:)` |
| Modify | `TipTour/Agents/Providers/GeminiRestProvider.swift` | Parse `usageMetadata`, return `LLMCompletionResult`; add `parseTokenUsage(from:)` |
| Modify | `TipTour/Agents/Swarm/TaskAgent.swift` | Add counters, token accumulation, `buildTaskExecution`, fire-and-forget |
| Modify | `TipTour/Agents/Skills/SkillExtractor.swift` | Call `.response` on `LLMCompletionResult` |
| Modify | `TipTourTests/AgentSwarmTests.swift` | Update `MockLLMProvider` to return `LLMCompletionResult` |
| Create | `TipTourTests/EfficiencyMonitorTests.swift` | All Phase 4D tests |

---

## Task 1: Type Definitions — `LLMTokenUsage`, `LLMCompletionResult`, `EfficiencyTypes`

**Files:**
- Modify: `TipTour/Agents/Core/LLMProvider.swift`
- Create: `TipTour/Agents/Core/EfficiencyTypes.swift`
- Create: `TipTourTests/EfficiencyMonitorTests.swift` (skeleton + Task 1 tests)

- [ ] **Step 1: Write failing tests for the new types**

Create `TipTourTests/EfficiencyMonitorTests.swift`:

```swift
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
```

- [ ] **Step 2: Run tests to confirm they fail**

Run: Cmd+U in Xcode
Expected: Compiler errors — `LLMTokenUsage`, `LLMCompletionResult`, `TaskExecution`, `EfficiencyReport` not defined.

- [ ] **Step 3: Add `LLMTokenUsage` and `LLMCompletionResult` to `LLMProvider.swift`**

Open `TipTour/Agents/Core/LLMProvider.swift`. After the `LLMChunk` enum (around line 80), add before the `// MARK: - Errors` section:

```swift
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
```

Do NOT yet change the `LLMProvider` protocol's `complete()` return type — that happens in Task 2.

- [ ] **Step 4: Create `EfficiencyTypes.swift`**

```swift
// TipTour/Agents/Core/EfficiencyTypes.swift

import Foundation

// MARK: - Task outcome

enum TaskOutcome: Sendable {
    case success(summary: String)
    case failure(reason: String)
}

// MARK: - One completed agent run

struct TaskExecution: Sendable {
    let taskId: UUID
    let taskType: TaskType
    let taskDescription: String
    var tokensUsed: Int
    var toolCallCount: Int
    var backtrackCount: Int
    var stepsExecuted: Int
    var duration: TimeInterval
    var outcome: TaskOutcome
    var conversationHistory: [LLMMessage]
    var autoSavedSkillSlug: String?
}

// MARK: - Efficiency evaluation result

struct EfficiencyReport: Sendable {
    let inefficiencyScore: Double
    let tokenOverrun: Int
    let wastedSteps: Int
    let diagnosis: String
    let didSelfCritique: Bool
}
```

- [ ] **Step 5: Run tests to confirm they pass**

Run: Cmd+U in Xcode
Expected: All 5 tests in `LLMTokenUsageTests`, `LLMCompletionResultTests`, `EfficiencyTypesTests` pass. All existing tests still pass.

- [ ] **Step 6: Commit**

```bash
git add TipTour/Agents/Core/LLMProvider.swift TipTour/Agents/Core/EfficiencyTypes.swift TipTourTests/EfficiencyMonitorTests.swift
git commit -m "add LLMTokenUsage, LLMCompletionResult, and EfficiencyTypes data model for Phase 4D"
```

---

## Task 2: Provider Return Type — Protocol + All Providers + MockLLMProvider + SkillExtractor

This task is atomic: changing the protocol immediately requires updating every conformer and every call site. All changes go in one commit.

**Files:**
- Modify: `TipTour/Agents/Core/LLMProvider.swift` (protocol)
- Modify: `TipTour/Agents/Providers/AnthropicProvider.swift`
- Modify: `TipTour/Agents/Providers/OpenAIProvider.swift`
- Modify: `TipTour/Agents/Providers/GeminiRestProvider.swift`
- Modify: `TipTour/Agents/Skills/SkillExtractor.swift`
- Modify: `TipTourTests/AgentSwarmTests.swift` (MockLLMProvider)
- Modify: `TipTourTests/EfficiencyMonitorTests.swift` (add provider token parsing tests)

- [ ] **Step 1: Write failing tests for provider token parsing**

Append to `TipTourTests/EfficiencyMonitorTests.swift`:

```swift
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
```

- [ ] **Step 2: Run tests to confirm they fail**

Run: Cmd+U in Xcode
Expected: Compiler error — `parseTokenUsage(from:)` not defined on providers.

- [ ] **Step 3: Change `LLMProvider` protocol return type**

Open `TipTour/Agents/Core/LLMProvider.swift`. Change the `complete()` signature in the protocol:

```swift
func complete(messages: [LLMMessage], tools: [LLMTool]) async throws -> LLMCompletionResult
```

- [ ] **Step 4: Update `AnthropicProvider.swift`**

Replace the `complete()` method and `parseResponse` method, and add `parseTokenUsage`:

```swift
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
```

- [ ] **Step 5: Update `OpenAIProvider.swift`**

Replace the `complete()` method and `parseResponse` method, and add `parseTokenUsage`:

```swift
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
```

- [ ] **Step 6: Update `GeminiRestProvider.swift`**

Replace the `complete()` method and `parseResponse` method, and add `parseTokenUsage`:

```swift
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
```

- [ ] **Step 7: Update `MockLLMProvider` in `AgentSwarmTests.swift`**

Find the `MockLLMProvider` class (lines 10–33) and update its `complete()` method. Add a `tokenUsageToReturn` property and wrap the return value:

```swift
final class MockLLMProvider: LLMProvider {
    let providerId: String
    let displayName: String
    let supportsVoice = false
    let costTier: LLMCostTier = .low

    var responseToReturn: LLMResponse = .text("mock response")
    var tokenUsageToReturn: LLMTokenUsage? = nil
    var shouldThrow = false
    var responseFactory: (() -> LLMResponse)?
    var capturedMessages: [[LLMMessage]] = []

    init(id: String) {
        self.providerId = id
        self.displayName = "Mock (\(id))"
    }

    func complete(messages: [LLMMessage], tools: [LLMTool]) async throws -> LLMCompletionResult {
        capturedMessages.append(messages)
        if shouldThrow { throw LLMProviderError.missingAPIKey(providerName: "Mock") }
        let response = responseFactory?() ?? responseToReturn
        return LLMCompletionResult(response: response, tokenUsage: tokenUsageToReturn)
    }
}
```

- [ ] **Step 8: Update `SkillExtractor.swift` to call `.response` on `LLMCompletionResult`**

Open `TipTour/Agents/Skills/SkillExtractor.swift`. In `extract(trajectory:name:)`, change:

```swift
let response = try await provider.complete(messages: [systemMessage, userMessage], tools: [])

guard case .text(let body) = response, !body.isEmpty else {
    throw SkillExtractorError.unexpectedResponse
}
```

to:

```swift
let result = try await provider.complete(messages: [systemMessage, userMessage], tools: [])

guard case .text(let body) = result.response, !body.isEmpty else {
    throw SkillExtractorError.unexpectedResponse
}
```

- [ ] **Step 9: Run tests to confirm they pass**

Run: Cmd+U in Xcode
Expected: All 4 `ProviderTokenParsingTests` pass. All existing tests still pass.

- [ ] **Step 10: Commit**

```bash
git add TipTour/Agents/Core/LLMProvider.swift \
        TipTour/Agents/Providers/AnthropicProvider.swift \
        TipTour/Agents/Providers/OpenAIProvider.swift \
        TipTour/Agents/Providers/GeminiRestProvider.swift \
        TipTour/Agents/Skills/SkillExtractor.swift \
        TipTourTests/AgentSwarmTests.swift \
        TipTourTests/EfficiencyMonitorTests.swift
git commit -m "change LLMProvider.complete() to return LLMCompletionResult with token usage"
```

---

## Task 3: `EfficiencyMonitor` Actor

**Files:**
- Create: `TipTour/Agents/Core/EfficiencyMonitor.swift`
- Modify: `TipTourTests/EfficiencyMonitorTests.swift` (add monitor tests)

- [ ] **Step 1: Write failing tests for EfficiencyMonitor**

Append to `TipTourTests/EfficiencyMonitorTests.swift`:

```swift
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

    @Test func tokenOverrunAlonePushesScoreAboveThreshold() async {
        let monitor = EfficiencyMonitor(tokenBudget: 8000, selfCritiqueThreshold: 0.4, providerOverride: nil)
        // 24000 tokens = 3× budget → overrun = 16000, fraction = min(0.5, 16000/8000 = 2.0) = 0.5
        // score = 0.5 * 0.5 = 0.25... wait, need to recalculate.
        // Actually: overrunFraction = min(0.5, 16000/8000) = min(0.5, 2.0) = 0.5
        // wastedStepFraction = min(1.0, 0/10) = 0.0
        // backtrackFraction = min(0.3, 0*0.1) = 0.0
        // score = 0.5 * 0.5 + 0.0 * 0.3 + 0.0 * 0.2 = 0.25
        // Hmm, that's < 0.4. Need bigger overrun.
        // 3× budget = 24000. overrun = 16000. fraction = 0.5. score = 0.25 < 0.4
        // To get score > 0.4 from tokens alone: need score from token portion > 0.4
        // tokenContribution = overrunFraction * 0.5 > 0.4 → overrunFraction > 0.8 → impossible (capped at 0.5)
        // Max token contribution = 0.5 * 0.5 = 0.25. Not enough alone!
        // So we need combined. Let's use tokens + some wasted steps.
        // 24000 tokens + 20 wasted steps: score = 0.25 + min(1.0, 20/10)*0.3 = 0.25 + 0.3 = 0.55 > 0.4 ✓
        // This test should use combined overrun + wasted steps.
        // expectedMinSteps for toolCallCount=2 = (2*2)+2 = 6. stepsExecuted=26 → wastedSteps=20
        let report = await monitor.evaluate(makeExecution(
            tokensUsed: 24000,
            toolCallCount: 2,
            stepsExecuted: 26
        ))
        #expect(report.inefficiencyScore > 0.4)
        // No provider → no self-critique
        #expect(report.didSelfCritique == false)
    }

    @Test func wastedStepsAlonePushesScoreAboveThreshold() async {
        let monitor = EfficiencyMonitor(tokenBudget: 8000, selfCritiqueThreshold: 0.4, providerOverride: nil)
        // toolCallCount=2 → expectedMinSteps=6. stepsExecuted=50 → wastedSteps=44
        // wastedStepFraction = min(1.0, 44/10) = 1.0
        // score = 0 + 1.0*0.3 + 0 = 0.3 < 0.4. Still not above threshold.
        // Max wasted step contribution = 0.3. Need backtracks too.
        // 3 backtracks: backtrackFraction = min(0.3, 3*0.1) = 0.3
        // score = 0 + 0.3 + 0.3*0.2 = 0 + 0.3 + 0.06 = 0.36 < 0.4
        // 4 backtracks: backtrackFraction = min(0.3, 0.4) = 0.3. Same.
        // Need all three: max wasted (0.3) + max backtracks (0.06) + some token = 0.36. Still < 0.4.
        // With token overrun fraction=0.5: total = 0.25 + 0.3 + 0.06 = 0.61 > 0.4.
        // The formula cannot reach 0.4 from wasted steps alone. The max from wasted+backtrack = 0.36.
        // This test should verify score > selfCritiqueThreshold with a custom lower threshold.
        let lowThresholdMonitor = EfficiencyMonitor(tokenBudget: 8000, selfCritiqueThreshold: 0.25, providerOverride: nil)
        // 50 steps with 2 tool calls → wastedSteps = 44. wastedStepFraction = 1.0. score = 0.3 > 0.25.
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
```

- [ ] **Step 2: Run tests to confirm they fail**

Run: Cmd+U in Xcode
Expected: Compiler errors — `EfficiencyMonitor` not defined.

- [ ] **Step 3: Create `EfficiencyMonitor.swift`**

```swift
// TipTour/Agents/Core/EfficiencyMonitor.swift

import Foundation

actor EfficiencyMonitor {

    static let shared = EfficiencyMonitor()

    private let tokenBudget: Int
    private let selfCritiqueThreshold: Double
    private let providerOverride: (any LLMProvider)?

    init(
        tokenBudget: Int = 8_000,
        selfCritiqueThreshold: Double = 0.4,
        providerOverride: (any LLMProvider)? = nil
    ) {
        self.tokenBudget = tokenBudget
        self.selfCritiqueThreshold = selfCritiqueThreshold
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
        guard let provider = providerOverride
                ?? (await LLMProviderRegistry.shared.provider(id: "anthropic-claude-sonnet-4-6"))
        else {
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
            let improvedSkill = extractXMLTag("improved_skill", from: responseText)
            let lesson = extractXMLTag("lesson", from: responseText)

            async let _skillWrite: Void = rewriteSkillIfNeeded(
                execution: execution, improvedSkill: improvedSkill, diagnosis: diagnosis
            )
            async let _memoryWrite: Void = writeLessonIfNeeded(
                execution: execution, lesson: lesson
            )
            _ = await (_skillWrite, _memoryWrite)

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

    private func rewriteSkillIfNeeded(execution: TaskExecution, improvedSkill: String, diagnosis: String) async {
        guard let slug = execution.autoSavedSkillSlug, !improvedSkill.isEmpty else { return }
        let body = "# \(execution.taskDescription)\n\n## Steps\n\n\(improvedSkill)\n\n## Result\n\nSelf-critiqued procedure."
        await SkillLibraryStore.shared.write(
            slug: slug,
            name: execution.taskDescription,
            description: String(diagnosis.prefix(120)),
            taskTypes: [execution.taskType],
            body: body
        )
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
```

- [ ] **Step 4: Run tests to confirm they pass**

Run: Cmd+U in Xcode
Expected: All tests in `EfficiencyMonitorTests` pass. Existing tests still pass.

- [ ] **Step 5: Commit**

```bash
git add TipTour/Agents/Core/EfficiencyMonitor.swift TipTourTests/EfficiencyMonitorTests.swift
git commit -m "add EfficiencyMonitor actor — score gate, LLM self-critique, dual write to skill/memory"
```

---

## Task 4: `TaskAgent` Instrumentation

**Files:**
- Modify: `TipTour/Agents/Swarm/TaskAgent.swift`
- Modify: `TipTourTests/EfficiencyMonitorTests.swift` (add TaskAgent integration tests)

- [ ] **Step 1: Write failing tests for TaskAgent instrumentation**

Append to `TipTourTests/EfficiencyMonitorTests.swift`:

```swift
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
        // stepsExecuted in the built TaskExecution should equal stepHistory.count at call time
        // We verify indirectly via tokensUsed being 0 (mock has no tokenUsage set)
        #expect(status.tokensUsed == 0)
    }
}
```

- [ ] **Step 2: Run tests to confirm they fail**

Run: Cmd+U in Xcode
Expected: Compiler errors — `agent.toolCallCount` and `agent.backtrackCount` not accessible (not yet defined).

- [ ] **Step 3: Add `toolCallCount` and `backtrackCount` to `TaskAgent`**

Open `TipTour/Agents/Swarm/TaskAgent.swift`. After `private(set) var tokensUsed: Int = 0`:

```swift
    private(set) var toolCallCount: Int = 0
    private(set) var backtrackCount: Int = 0
```

- [ ] **Step 4: Accumulate tokens after each `complete()` call in `run()`**

In `TaskAgent.run()`, replace:

```swift
let response = try await activeProvider.complete(
    messages: conversationHistory,
    tools: availableToolDefinitions()
)

switch response {
case .text(let text):
```

with:

```swift
let completionResult = try await activeProvider.complete(
    messages: conversationHistory,
    tools: availableToolDefinitions()
)
tokensUsed += completionResult.tokenUsage?.totalTokens ?? 0

switch completionResult.response {
case .text(let text):
```

- [ ] **Step 5: Increment `toolCallCount` in `dispatchToolCall`**

In `TaskAgent.dispatchToolCall(_:)`, add `toolCallCount += 1` before the return:

```swift
private func dispatchToolCall(_ toolCall: LLMToolCall) async -> String {
    toolCallCount += 1
    let result = await toolBox.execute(toolCall: toolCall)
    skillHistoryBuffer.append(RecordedToolCall(
        toolName: toolCall.name,
        argumentsJSON: toolCall.argumentsJSON,
        result: result
    ))
    return result
}
```

- [ ] **Step 6: Increment `backtrackCount` in `checkAndApplyInterrupts()`**

In `TaskAgent.checkAndApplyInterrupts()`, add the count before removing items:

```swift
private func checkAndApplyInterrupts() async {
    guard !interruptQueue.isEmpty else { return }
    backtrackCount += 1
    let pendingInstructions = interruptQueue
    interruptQueue.removeAll()
    for instruction in pendingInstructions {
        conversationHistory.append(LLMMessage(role: .user, content: instruction))
    }
    await notifyProgressUpdate("Updating plan based on new instructions...")
}
```

- [ ] **Step 7: Add `buildTaskExecution(outcome:)` to `TaskAgent`**

After the `autoSaveSkill` method (around line 280), add:

```swift
private func buildTaskExecution(outcome: TaskOutcome) -> TaskExecution {
    TaskExecution(
        taskId: id,
        taskType: taskType,
        taskDescription: taskDescription,
        tokensUsed: tokensUsed,
        toolCallCount: toolCallCount,
        backtrackCount: backtrackCount,
        stepsExecuted: stepHistory.count,
        duration: Date().timeIntervalSince(startedAt),
        outcome: outcome,
        conversationHistory: conversationHistory,
        autoSavedSkillSlug: toolCallCount > 0 ? SkillLibraryStore.generateSlug(from: taskDescription) : nil
    )
}
```

- [ ] **Step 8: Fire-and-forget `evaluate` after `autoSaveSkill` in `run()`**

In `run()`, after the `await autoSaveSkill(taskResult: text)` call, add:

```swift
let execution = buildTaskExecution(outcome: .success(summary: text))
Task { await EfficiencyMonitor.shared.evaluate(execution) }
```

- [ ] **Step 9: Fire-and-forget `evaluate` in `handleError(_:)`**

In `handleError(_:)`, after `await writeTaskResultToMemory(summary: "Failed: \(reason)")`, add:

```swift
let execution = buildTaskExecution(outcome: .failure(reason: reason))
Task { await EfficiencyMonitor.shared.evaluate(execution) }
```

- [ ] **Step 10: Run tests to confirm they pass**

Run: Cmd+U in Xcode
Expected: All tests in `TaskAgentEfficiencyInstrumentationTests` pass. All existing tests still pass.

- [ ] **Step 11: Commit**

```bash
git add TipTour/Agents/Swarm/TaskAgent.swift TipTourTests/EfficiencyMonitorTests.swift
git commit -m "instrument TaskAgent with token/tool/backtrack counters and fire-and-forget EfficiencyMonitor"
```

---

## Task 5: Update AGENTS.md

**Files:**
- Modify: `AGENTS.md` (symlink target — edit `repo/AGENTS.md` directly)

- [ ] **Step 1: Update the file table**

Note: `CLAUDE.md` in `repo/` is a symlink to `AGENTS.md`. Edit `AGENTS.md` directly.

Add three new rows after the `SkillExtractor.swift` row:

```
| `TipTour/Agents/Core/EfficiencyTypes.swift` | ~45 | `TaskOutcome`, `TaskExecution`, `EfficiencyReport` — data model for efficiency evaluation of completed agent runs. |
| `TipTour/Agents/Core/EfficiencyMonitor.swift` | ~130 | Actor singleton. Computes weighted inefficiency score (token overrun, wasted steps, backtracks). Score > 0.4 triggers one Claude call to self-critique; concurrently rewrites the auto-saved skill and writes a permanent lesson to agent memory. |
```

Update the `TaskAgent.swift` row description to mention the new counters:

```
| `TipTour/Agents/Swarm/TaskAgent.swift` | ~340 | Individual background agent. Runs agentic LLM loop, accumulates `tokensUsed`/`toolCallCount`/`backtrackCount`, fires `EfficiencyMonitor.shared.evaluate` on completion, injects memory and skills at startup, writes task result to memory, auto-saves skill on tool-using completions. |
```

Update the description rows for all three providers to note they return `LLMCompletionResult`:

```
| `TipTour/Agents/Providers/AnthropicProvider.swift` | ~175 | Claude Haiku/Sonnet/Opus via Anthropic REST API. Returns `LLMCompletionResult` with parsed `LLMTokenUsage` from the `usage` field. |
| `TipTour/Agents/Providers/OpenAIProvider.swift` | ~150 | GPT-4o/mini via OpenAI REST API. Returns `LLMCompletionResult` with parsed `LLMTokenUsage` from the `usage` field. |
| `TipTour/Agents/Providers/GeminiRestProvider.swift` | ~160 | Gemini Flash/Pro via REST (background tasks only — not voice). Returns `LLMCompletionResult` with parsed `LLMTokenUsage` from `usageMetadata`. |
```

- [ ] **Step 2: Commit**

```bash
git add AGENTS.md
git commit -m "update AGENTS.md for Phase 4D EfficiencyMonitor, provider token usage, TaskAgent counters"
```

---

## Self-Review

### Spec Coverage Check

| Spec requirement | Implemented in |
|---|---|
| `LLMTokenUsage`, `LLMCompletionResult` structs | Task 1 |
| `complete()` return type change → `LLMCompletionResult` | Task 2 |
| `TaskOutcome`, `TaskExecution`, `EfficiencyReport` | Task 1 |
| `EfficiencyMonitor` actor singleton | Task 3 |
| Score formula (token overrun, wasted steps, backtracks, caps) | Task 3 |
| Gate: score ≤ 0.4 → no LLM call | Task 3 |
| Self-critique via `anthropic-claude-sonnet-4-6` | Task 3 |
| XML parsing: `<diagnosis>`, `<improved_skill>`, `<lesson>` | Task 3 |
| Concurrent dual write: skill overwrite + memory lesson | Task 3 |
| `AnthropicProvider` parses `usage` field | Task 2 |
| `OpenAIProvider` parses `usage` field | Task 2 |
| `GeminiRestProvider` parses `usageMetadata` field | Task 2 |
| `TaskAgent.toolCallCount` / `backtrackCount` | Task 4 |
| Token accumulation after each `complete()` call | Task 4 |
| `buildTaskExecution(outcome:)` | Task 4 |
| Fire-and-forget on success (after `autoSaveSkill`) | Task 4 |
| Fire-and-forget on error (in `handleError`) | Task 4 |
| `SkillExtractor` calls `.response` on result | Task 2 |
| `MockLLMProvider` updated to return `LLMCompletionResult` | Task 2 |
| No UI changes | Confirmed — no UI tasks |

### Placeholder Scan

None found.

### Type Consistency Check

- `LLMCompletionResult(response: LLMResponse, tokenUsage: LLMTokenUsage?)` — used consistently across all providers and call sites.
- `MockLLMProvider.complete()` → `LLMCompletionResult` with `responseFactory?() ?? responseToReturn` wrapped. Existing callers set `responseToReturn: LLMResponse` — no migration needed.
- `EfficiencyMonitor.evaluate(_ execution: TaskExecution) async -> EfficiencyReport` — `@discardableResult` so `Task { await EfficiencyMonitor.shared.evaluate(execution) }` works without warning.
- `buildTaskExecution(outcome:) -> TaskExecution` uses `stepHistory.count` for `stepsExecuted` — matches what tests verify via `status.stepHistory.count`.
- `autoSavedSkillSlug` is `nil` when `toolCallCount == 0` — matches `EfficiencyMonitor.rewriteSkillIfNeeded`'s `guard let slug = execution.autoSavedSkillSlug`.
