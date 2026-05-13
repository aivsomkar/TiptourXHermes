# EfficiencyMonitor Design

## Goal

After each background agent completes a task, evaluate whether its execution was efficient. If a rule-based score indicates the run was wasteful (too many tokens, too many steps, too many course corrections), make one structured LLM call to self-critique the run, rewrite the auto-saved skill with a better procedure, and write a permanent lesson note to agent memory — so future runs of similar tasks cost less.

## Scope

This spec covers Phase 4D only: `LLMTokenUsage`, `LLMCompletionResult`, `EfficiencyTypes`, `EfficiencyMonitor`, `TaskAgent` instrumentation, and provider-level token parsing. `DemonstrationRecorder` (Phase 4C) is a separate spec.

---

## Data Model

### `LLMTokenUsage` and `LLMCompletionResult`

**File:** `TipTour/Agents/Core/LLMProvider.swift` (additions)

```swift
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

`LLMProvider.complete()` return type changes from `LLMResponse` → `LLMCompletionResult`. All call sites call `.response` to get the existing `LLMResponse`.

---

### `EfficiencyTypes`

**File:** `TipTour/Agents/Core/EfficiencyTypes.swift`

#### `TaskOutcome`

```swift
enum TaskOutcome: Sendable {
    case success(summary: String)
    case failure(reason: String)
}
```

#### `TaskExecution`

One completed agent run. Built by `TaskAgent` after the agentic loop exits and passed to `EfficiencyMonitor.shared.evaluate(_:)`.

```swift
struct TaskExecution: Sendable {
    let taskId: UUID
    let taskType: TaskType
    let taskDescription: String
    var tokensUsed: Int
    var toolCallCount: Int
    var backtrackCount: Int         // number of interrupt batches processed
    var stepsExecuted: Int
    var duration: TimeInterval
    var outcome: TaskOutcome
    var conversationHistory: [LLMMessage]
    var autoSavedSkillSlug: String?  // slug of the skill written by autoSaveSkill, if any
}
```

#### `EfficiencyReport`

Return value of `EfficiencyMonitor.evaluate(_:)`. Primarily for testing.

```swift
struct EfficiencyReport: Sendable {
    let inefficiencyScore: Double    // 0.0–1.0
    let tokenOverrun: Int            // tokens above budget (0 if within)
    let wastedSteps: Int             // steps above the expected minimum
    let diagnosis: String            // human-readable diagnosis (empty if no LLM call)
    let didSelfCritique: Bool        // true if LLM self-critique was triggered
}
```

---

## `EfficiencyMonitor`

**File:** `TipTour/Agents/Core/EfficiencyMonitor.swift`

A Swift `actor` singleton.

```swift
actor EfficiencyMonitor {
    static let shared = EfficiencyMonitor()
    private let tokenBudget: Int
    private let selfCritiqueThreshold: Double

    init(
        tokenBudget: Int = 8_000,
        selfCritiqueThreshold: Double = 0.4
    )
}
```

### `evaluate(_ execution: TaskExecution) async -> EfficiencyReport`

**Step 1 — Compute score:**

```
tokenOverrun = max(0, tokensUsed - tokenBudget)
tokenOverrunFraction = min(0.5, Double(tokenOverrun) / Double(tokenBudget))

expectedMinSteps = (toolCallCount * 2) + 2
wastedSteps = max(0, stepsExecuted - expectedMinSteps)
wastedStepFraction = min(1.0, Double(wastedSteps) / 10.0)

backtrackFraction = min(0.3, Double(backtrackCount) * 0.1)

inefficiencyScore = min(1.0,
    tokenOverrunFraction * 0.5 +
    wastedStepFraction  * 0.3 +
    backtrackFraction   * 0.2
)
```

**Step 2 — Gate:**

If `inefficiencyScore ≤ selfCritiqueThreshold` (default 0.4):
- Return `EfficiencyReport(inefficiencyScore: score, tokenOverrun: 0, wastedSteps: 0, diagnosis: "", didSelfCritique: false)`

**Step 3 — Self-critique (score > 0.4):**

Fetch the provider via `LLMProviderRegistry.shared.provider(id: "anthropic-claude-sonnet-4-6")`. If unavailable, return the report with `didSelfCritique: false`.

Construct `[LLMMessage]`:

- **System message:**
```
You are reviewing a background agent's execution for efficiency.
The agent completed the task but the run showed signs of inefficiency.
Produce a structured self-critique in this exact XML format:

<diagnosis>One sentence explaining the primary source of waste.</diagnosis>
<improved_skill>A revised step-by-step procedure that would complete this task more efficiently. Write it as a numbered list of human-readable instructions.</improved_skill>
<lesson>One sentence stating what the agent should remember for next time.</lesson>
```

- **User message:** Compact execution summary:
```
Task: <taskDescription>
Tokens used: <tokensUsed> (budget: <tokenBudget>)
Tool calls: <toolCallCount>
Steps recorded: <stepsExecuted>
Backtracks (user course corrections): <backtrackCount>
Duration: <duration>s
Outcome: <success|failure>

Conversation history (condensed):
<last 20 messages from conversationHistory, formatted as role: content>
```

Call `provider.complete(messages:tools:)` with no tools. Extract `.response` text. Parse the three XML tags. Any parse failure leaves the corresponding field empty.

**Step 4 — Dual write (concurrent):**

```swift
async let skillWrite: () = {
    guard let slug = execution.autoSavedSkillSlug,
          !improvedSkill.isEmpty else { return }
    let frontmatter = ... // same as autoSaveSkill's frontmatter for this slug
    let body = "# \(execution.taskDescription)\n\n## Steps\n\n\(improvedSkill)\n\n## Result\n\nSelf-critiqued procedure."
    await SkillLibraryStore.shared.write(
        slug: slug,
        name: execution.taskDescription,
        description: String(diagnosis.prefix(120)),
        taskTypes: [execution.taskType],
        body: body
    )
}()

async let memoryWrite: () = {
    guard !lesson.isEmpty else { return }
    await AgentMemoryStore.shared.write(
        content: "\(execution.taskType.displayName): \(lesson)",
        entryType: .fact,
        taskTypes: [execution.taskType],
        permanent: true
    )
}()

_ = await (skillWrite, memoryWrite)
```

**Step 5 — Return:**

```swift
return EfficiencyReport(
    inefficiencyScore: inefficiencyScore,
    tokenOverrun: tokenOverrun,
    wastedSteps: wastedSteps,
    diagnosis: diagnosis,
    didSelfCritique: true
)
```

---

## `TaskAgent` Changes

**File:** `TipTour/Agents/Swarm/TaskAgent.swift`

### New stored properties

```swift
private var toolCallCount: Int = 0
private var backtrackCount: Int = 0
```

### Token accumulation

After each `provider.complete(messages:tools:)` call:
```swift
let result = try await activeProvider.complete(messages: conversationHistory, tools: availableToolDefinitions())
tokensUsed += result.tokenUsage?.totalTokens ?? 0
switch result.response { ... }
```

### Tool call counting

In `dispatchToolCall(_:)`:
```swift
toolCallCount += 1
```

### Backtrack counting

In `checkAndApplyInterrupts()`, before removing items:
```swift
if !interruptQueue.isEmpty {
    backtrackCount += 1
}
```

### Fire-and-forget evaluation

In `run()`, after `autoSaveSkill(taskResult:)`:
```swift
let execution = buildTaskExecution(outcome: .success(summary: text))
Task { await EfficiencyMonitor.shared.evaluate(execution) }
```

In `handleError(_:)`, after `writeTaskResultToMemory`:
```swift
let execution = buildTaskExecution(outcome: .failure(reason: reason))
Task { await EfficiencyMonitor.shared.evaluate(execution) }
```

### `buildTaskExecution(outcome:) -> TaskExecution`

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

`autoSavedSkillSlug` is `nil` when `toolCallCount == 0` because `autoSaveSkill` only writes a skill when tool calls were made. This ensures `EfficiencyMonitor`'s skill-overwrite guard (`guard let slug = execution.autoSavedSkillSlug`) correctly skips the write when no skill was saved.

---

## Provider Changes

### Return type

All three providers change `complete()` to return `LLMCompletionResult` instead of `LLMResponse`.

### `AnthropicProvider.swift`

Parse the top-level `"usage"` field from the API response JSON:
```json
"usage": { "input_tokens": 123, "output_tokens": 456 }
```
Build `LLMTokenUsage(inputTokens:, outputTokens:, totalTokens: input + output)`. Return `tokenUsage: nil` if the field is absent or malformed.

### `OpenAIProvider.swift`

Parse `"usage"` from the API response JSON:
```json
"usage": { "prompt_tokens": 123, "completion_tokens": 456, "total_tokens": 579 }
```
Build `LLMTokenUsage` from those fields.

### `GeminiRestProvider.swift`

Parse `"usageMetadata"` from the API response JSON:
```json
"usageMetadata": { "promptTokenCount": 123, "candidatesTokenCount": 456 }
```
Build `LLMTokenUsage(inputTokens: promptTokenCount, outputTokens: candidatesTokenCount, totalTokens: sum)`.

---

## `SkillExtractor` Change

**File:** `TipTour/Agents/Skills/SkillExtractor.swift`

`SkillExtractor.extract(trajectory:name:)` calls `provider.complete()` internally. Update to call `.response` on the returned `LLMCompletionResult`. Token usage is discarded — `SkillExtractor` is a single short call, not an agentic loop.

---

## UI

No new UI. `EfficiencyMonitor` is entirely background. `EfficiencyReport` is not surfaced to the user.

---

## New Files

| File | Purpose |
|------|---------|
| `TipTour/Agents/Core/EfficiencyTypes.swift` | `TaskOutcome`, `TaskExecution`, `EfficiencyReport` |
| `TipTour/Agents/Core/EfficiencyMonitor.swift` | Actor singleton — score gate, self-critique, dual write |

## Modified Files

| File | Change |
|------|--------|
| `TipTour/Agents/Core/LLMProvider.swift` | Add `LLMTokenUsage`, `LLMCompletionResult`; change `complete()` return type |
| `TipTour/Agents/Providers/AnthropicProvider.swift` | Parse `usage` field, return `LLMCompletionResult` |
| `TipTour/Agents/Providers/OpenAIProvider.swift` | Parse `usage` field, return `LLMCompletionResult` |
| `TipTour/Agents/Providers/GeminiRestProvider.swift` | Parse `usageMetadata` field, return `LLMCompletionResult` |
| `TipTour/Agents/Swarm/TaskAgent.swift` | Add `toolCallCount`, `backtrackCount`; accumulate tokens; fire-and-forget evaluate |
| `TipTour/Agents/Skills/SkillExtractor.swift` | Call `.response` on `LLMCompletionResult` |

---

## Testing

**File:** `TipTourTests/EfficiencyMonitorTests.swift`

### Score formula tests (no LLM, no provider)

- `inefficiencyScore` is 0.0 for a run within budget with minimal steps and no backtracks
- Token overrun alone pushes score above 0.4 when tokens are 3× the budget
- Wasted steps alone push score above 0.4 when step count is 15+ above expected minimum
- Both overrun + wasted steps together produce a higher score than either alone
- `backtrackFraction` is capped at 0.3 regardless of backtrack count
- `inefficiencyScore` is capped at 1.0

### Gate test

- Score ≤ 0.4 → `evaluate` returns `didSelfCritique: false` and makes no provider call

### Self-critique output tests (mock `AnthropicProvider`)

- Score > 0.4 + provider returns valid XML → `EfficiencyReport.didSelfCritique == true`, `diagnosis` is non-empty
- Score > 0.4 + provider returns malformed XML → `didSelfCritique: true` but `diagnosis` is empty (graceful degradation)
- Score > 0.4 + no `autoSavedSkillSlug` → no skill write attempted, memory write still fires
- Score > 0.4 + provider throws → `evaluate` catches and returns `didSelfCritique: false`

### Token accumulation tests (`TaskAgent` integration)

- `tokensUsed` accumulates across multiple `complete()` calls in the agentic loop
- `toolCallCount` increments once per `dispatchToolCall`
- `backtrackCount` increments once per interrupt batch (not per message in the batch)
- `buildTaskExecution` captures the correct `stepsExecuted` count from `stepHistory.count`

### Provider unit tests

- `AnthropicProvider` returns non-nil `LLMTokenUsage` when `usage` field is present
- `AnthropicProvider` returns `tokenUsage: nil` when `usage` field is absent
- `OpenAIProvider` returns non-nil `LLMTokenUsage` when `usage` field is present
- `GeminiRestProvider` returns non-nil `LLMTokenUsage` when `usageMetadata` field is present
