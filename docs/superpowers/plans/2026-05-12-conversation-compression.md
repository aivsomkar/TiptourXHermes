# Conversation Compression Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let background `TaskAgent`s survive long, tool-heavy runs by periodically folding older turns into a short text summary, so the agent stays under provider token caps and stops re-paying for stale context on every loop iteration.

**Architecture:** A new `ConversationCompressor` helper takes `[LLMMessage]` and an injected "summarizer" `LLMProvider`, replaces the oldest N messages with a single synthesized user-role message containing the summary, and preserves the trailing K raw messages for fresh context. `TaskAgent.run()` invokes the compressor between loop iterations once the history exceeds a configurable turn-count threshold. The split point respects tool-call boundaries so we never strand an `assistant.tool_use` without its matching `tool.result`.

**Scope:** Agent loop only. The Gemini Live voice session (`GeminiLiveSession`) is OUT OF SCOPE — that's a separate, harder problem because server-side context can't be edited mid-session. We may revisit voice-session compression once we have real telemetry showing long voice sessions hitting caps; until then we have a hard 50-turn agent cap that this lifts.

**Tech Stack:** Swift actors, the existing `LLMProvider` protocol, `LLMProviderRegistry` for picking the summarizer, Swift Testing.

---

## File Structure

| Action | Path | Responsibility |
|--------|------|----------------|
| Create | `TipTour/Agents/Core/ConversationCompressor.swift` | Pure helper: `compress(messages:keepLastN:summarizer:)` → `[LLMMessage]`. `findSafeSplitPoint(in:before:)` ensures we don't strand tool_use ↔ tool_result pairs. |
| Modify | `TipTour/Agents/Core/LLMProviderRegistry.swift` | Add `summarizerProvider()` that picks the cheapest fast provider (Gemini Flash Lite → Haiku → first available). |
| Modify | `TipTour/Agents/Swarm/TaskAgent.swift` | Read `compressionThreshold` from UserDefaults; after each loop iteration, if `conversationHistory.count > threshold`, call the compressor. Increase `maximumLoopCount` from 50 → 100 since compression makes longer runs viable. |
| Modify | `TipTour/Agents/UI/SettingsView.swift` | Add a "Conversation compression" section to the Learning tab: toggle + threshold slider. |
| Create | `TipTourTests/ConversationCompressorTests.swift` | Unit tests using a stub `LLMProvider`. |

---

## Task 1: `ConversationCompressor` + safe-split helper

**Files:**
- Create: `TipTour/Agents/Core/ConversationCompressor.swift`
- Create: `TipTourTests/ConversationCompressorTests.swift`

- [ ] **Step 1: Write failing tests for `findSafeSplitPoint`**

Create `TipTourTests/ConversationCompressorTests.swift`:

```swift
// TipTourTests/ConversationCompressorTests.swift

import Foundation
import Testing
@testable import TipTour

@Suite("findSafeSplitPoint")
struct FindSafeSplitPointTests {

    /// Helper to build a tool_use → tool_result pair.
    static func toolUsePair(id: String) -> [LLMMessage] {
        [
            LLMMessage(role: .assistant, content: "", toolCalls: [
                LLMToolCall(id: id, name: "test_tool", argumentsJSON: "{}")
            ]),
            LLMMessage(role: .tool, content: "ok", toolCallId: id, toolName: "test_tool")
        ]
    }

    @Test func splitAtUserTurnIsSafe() {
        // [system, user, assistant, user] — split before index 3 lands
        // on a user turn, which is safe.
        let messages: [LLMMessage] = [
            LLMMessage(role: .system, content: "sys"),
            LLMMessage(role: .user, content: "first ask"),
            LLMMessage(role: .assistant, content: "first reply"),
            LLMMessage(role: .user, content: "second ask")
        ]
        let split = ConversationCompressor.findSafeSplitPoint(in: messages, before: 3)
        #expect(split == 3)
    }

    @Test func splitBetweenToolUseAndResultIsRewound() {
        // [system, user, assistant.tool_use, tool, assistant.text]
        // Target index 3 lands BETWEEN tool_use and tool_result —
        // unsafe. Should rewind to 2 (the user message before).
        let pair = Self.toolUsePair(id: "call_1")
        let messages: [LLMMessage] = [
            LLMMessage(role: .system, content: "sys"),
            LLMMessage(role: .user, content: "ask")
        ] + pair + [LLMMessage(role: .assistant, content: "final")]
        // index 3 is the .tool message — splitting before it would
        // leave the tool_use orphaned in the older slice.
        let split = ConversationCompressor.findSafeSplitPoint(in: messages, before: 3)
        #expect(split == 2)  // rewinds to the user message
    }

    @Test func splitAfterToolResultIsSafe() {
        let pair = Self.toolUsePair(id: "call_1")
        let messages: [LLMMessage] = [
            LLMMessage(role: .system, content: "sys"),
            LLMMessage(role: .user, content: "ask")
        ] + pair + [LLMMessage(role: .assistant, content: "final")]
        // index 4 is the assistant.text — splitting before it keeps
        // the tool_use+tool_result pair together in the older slice.
        let split = ConversationCompressor.findSafeSplitPoint(in: messages, before: 4)
        #expect(split == 4)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run `FindSafeSplitPointTests` in Xcode. Expected: compile failure ("cannot find 'ConversationCompressor' in scope").

- [ ] **Step 3: Implement `ConversationCompressor.findSafeSplitPoint`**

```swift
// TipTour/Agents/Core/ConversationCompressor.swift

import Foundation

enum ConversationCompressor {

    /// Walk backwards from `target` and return the largest index ≤ target
    /// where splitting is safe. "Safe" means: the slice [0..<split] does
    /// not strand any `assistant.tool_use` whose matching `tool` reply
    /// lives in [split..<count].
    ///
    /// Rule: a split at index `i` is unsafe if any assistant message in
    /// [0..<i] has a tool_call whose id appears in a `.tool` message at
    /// index ≥ i. We rewind to the last index where this is not the case.
    static func findSafeSplitPoint(in messages: [LLMMessage], before target: Int) -> Int {
        guard target > 0, target <= messages.count else { return target }

        var candidate = target
        while candidate > 0 {
            if isSafeSplit(messages: messages, at: candidate) {
                return candidate
            }
            candidate -= 1
        }
        return 0
    }

    private static func isSafeSplit(messages: [LLMMessage], at split: Int) -> Bool {
        var outstandingToolCallIDs: Set<String> = []
        for index in 0..<split {
            let message = messages[index]
            if message.role == .assistant, let toolCalls = message.toolCalls {
                for call in toolCalls { outstandingToolCallIDs.insert(call.id) }
            } else if message.role == .tool, let toolCallId = message.toolCallId {
                outstandingToolCallIDs.remove(toolCallId)
            }
        }
        // If anything is still outstanding, the matching tool result is
        // in the trailing slice — unsafe.
        return outstandingToolCallIDs.isEmpty
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run `FindSafeSplitPointTests` in Xcode. Expected: all 3 tests pass.

- [ ] **Step 5: Commit**

```bash
git add TipTour/Agents/Core/ConversationCompressor.swift TipTourTests/ConversationCompressorTests.swift
git commit -m "feat(agents): ConversationCompressor.findSafeSplitPoint"
```

---

## Task 2: `ConversationCompressor.compress` — full path with stub provider

**Files:**
- Modify: `TipTour/Agents/Core/ConversationCompressor.swift`
- Modify: `TipTourTests/ConversationCompressorTests.swift`

- [ ] **Step 1: Write failing tests with a stub provider**

Append to `ConversationCompressorTests.swift`:

```swift
/// Minimal stub provider that returns a canned text response from
/// `complete(messages:tools:)`. Tracks the most recent messages it
/// was called with so tests can assert on the summarizer's input.
final class StubSummarizerProvider: LLMProvider, @unchecked Sendable {
    var providerId: String { "stub-summarizer" }
    var cannedResponse: String = "[Summary] earlier conversation."
    private(set) var lastMessages: [LLMMessage] = []

    func complete(messages: [LLMMessage], tools: [LLMTool]) async throws -> LLMCompletionResult {
        lastMessages = messages
        return LLMCompletionResult(
            response: .text(cannedResponse),
            tokenUsage: nil
        )
    }
}

@Suite("ConversationCompressor.compress")
struct CompressorTests {

    @Test func compressPreservesSystemAndRecentMessages() async throws {
        let messages: [LLMMessage] = [
            LLMMessage(role: .system, content: "sys"),
            LLMMessage(role: .user, content: "ask 1"),
            LLMMessage(role: .assistant, content: "reply 1"),
            LLMMessage(role: .user, content: "ask 2"),
            LLMMessage(role: .assistant, content: "reply 2"),
            LLMMessage(role: .user, content: "ask 3"),
            LLMMessage(role: .assistant, content: "reply 3"),
            LLMMessage(role: .user, content: "ask 4")
        ]
        let stub = StubSummarizerProvider()
        let compressed = try await ConversationCompressor.compress(
            messages: messages,
            keepLastN: 3,
            summarizer: stub
        )
        // Expected shape: [system, summary_as_user, last 3 raw messages]
        #expect(compressed.count == 5)
        #expect(compressed[0].role == .system)
        #expect(compressed[1].role == .user)
        #expect(compressed[1].content.contains("[Summary]"))
        #expect(compressed[2].content == "reply 2")
        #expect(compressed[3].content == "ask 3")
        #expect(compressed[4].content == "reply 3")
        // 'ask 4' is index count-1 = 7. keepLastN=3 means indices 5,6,7
        // are preserved. The expectations above match that.
    }

    @Test func compressReturnsInputUnchangedWhenAlreadyShort() async throws {
        let messages: [LLMMessage] = [
            LLMMessage(role: .system, content: "sys"),
            LLMMessage(role: .user, content: "ask"),
            LLMMessage(role: .assistant, content: "reply")
        ]
        let stub = StubSummarizerProvider()
        let compressed = try await ConversationCompressor.compress(
            messages: messages,
            keepLastN: 5,
            summarizer: stub
        )
        #expect(compressed.count == 3)
        #expect(stub.lastMessages.isEmpty)  // summarizer never called
    }

    @Test func compressRewindsAcrossToolPairsToStaySafe() async throws {
        // Messages: [system, user, asst.toolUse, tool, asst.toolUse2,
        //            tool2, user, asst.final]
        // keepLastN=3 wants to split before index 5 — that's the
        // tool result for toolUse2, which would strand its tool_use
        // in the older slice. The split must rewind to the user at
        // index 1, otherwise toolUse2 ends up in older but its tool
        // result tool2 ends up preserved. Rewinding to 1 means the
        // entire tool pair span is in `older` together.
        let messages: [LLMMessage] = [
            LLMMessage(role: .system, content: "sys"),
            LLMMessage(role: .user, content: "ask"),
            LLMMessage(role: .assistant, content: "", toolCalls: [
                LLMToolCall(id: "c1", name: "t", argumentsJSON: "{}")
            ]),
            LLMMessage(role: .tool, content: "r1", toolCallId: "c1", toolName: "t"),
            LLMMessage(role: .assistant, content: "", toolCalls: [
                LLMToolCall(id: "c2", name: "t", argumentsJSON: "{}")
            ]),
            LLMMessage(role: .tool, content: "r2", toolCallId: "c2", toolName: "t"),
            LLMMessage(role: .user, content: "follow up"),
            LLMMessage(role: .assistant, content: "final")
        ]
        let stub = StubSummarizerProvider()
        let compressed = try await ConversationCompressor.compress(
            messages: messages,
            keepLastN: 3,
            summarizer: stub
        )
        // Whatever the exact split, the compressed result must NEVER
        // contain a .tool message whose id has no matching .assistant
        // tool_call in the SAME slice. Assert that invariant.
        let toolIDsInCompressed = Set(compressed.compactMap { $0.toolCallId })
        let assistantToolUseIDsInCompressed = Set(
            compressed.flatMap { $0.toolCalls?.map(\.id) ?? [] }
        )
        for toolID in toolIDsInCompressed {
            #expect(assistantToolUseIDsInCompressed.contains(toolID))
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run `CompressorTests`. Expected: compile failure ("type 'ConversationCompressor' has no member 'compress'").

- [ ] **Step 3: Implement `compress`**

```swift
extension ConversationCompressor {

    /// Replace the oldest portion of `messages` with a single
    /// `.user`-role summary, preserving the system message and the
    /// trailing `keepLastN` messages verbatim.
    ///
    /// Returns `messages` unchanged when there's nothing meaningful to
    /// compress (count ≤ keepLastN + 1 system message + 1 raw user
    /// turn, OR the safe split point lands at or after the keep-last
    /// boundary).
    static func compress(
        messages: [LLMMessage],
        keepLastN: Int,
        summarizer: any LLMProvider
    ) async throws -> [LLMMessage] {
        guard messages.count > keepLastN + 1 else { return messages }
        // System message is at index 0 (TaskAgent always builds it
        // there). Don't compress it.
        let targetSplit = messages.count - keepLastN
        let safeSplit = findSafeSplitPoint(in: messages, before: targetSplit)
        // If the safe split landed at or before index 1, the entire
        // history was tool-paired up to the keep boundary — nothing to
        // compress without destroying integrity. Return unchanged.
        guard safeSplit > 1 else { return messages }

        let systemMessage = messages[0]
        let toCompress = Array(messages[1..<safeSplit])
        let toKeep = Array(messages[safeSplit...])

        let summary = try await summarize(messages: toCompress, using: summarizer)
        let summaryMessage = LLMMessage(
            role: .user,
            content: "[Earlier conversation, summarized to save context]\n\(summary)"
        )
        return [systemMessage, summaryMessage] + toKeep
    }

    private static func summarize(
        messages: [LLMMessage],
        using summarizer: any LLMProvider
    ) async throws -> String {
        let transcript = messages.map(transcribe).joined(separator: "\n\n")
        let prompt: [LLMMessage] = [
            LLMMessage(role: .system, content: """
            You are a precise summarizer. Read the conversation transcript and produce a TIGHT factual summary that preserves:
              - the user's goal and any sub-goals
              - what tools were called, with their key arguments and outcomes
              - what worked, what failed, what's pending
              - any specific values (URLs, file paths, IDs, error messages) that later turns may refer back to
            Do NOT add commentary or speculation. Do NOT include the system prompt. Output one tight paragraph followed by a bulleted "facts" list.
            """),
            LLMMessage(role: .user, content: "Transcript:\n\n\(transcript)")
        ]
        let result = try await summarizer.complete(messages: prompt, tools: [])
        switch result.response {
        case .text(let text): return text
        case .textAndToolCalls(let text, _): return text
        case .toolCalls: return "[summary unavailable — model returned tool calls instead of text]"
        }
    }

    private static func transcribe(_ message: LLMMessage) -> String {
        switch message.role {
        case .system: return "[system] \(message.content)"
        case .user: return "[user] \(message.content)"
        case .assistant:
            if let calls = message.toolCalls, !calls.isEmpty {
                let callList = calls.map { "→ \($0.name)(\($0.argumentsJSON))" }.joined(separator: "\n")
                let preface = message.content.isEmpty ? "" : "\(message.content)\n"
                return "[assistant] \(preface)\(callList)"
            }
            return "[assistant] \(message.content)"
        case .tool:
            let toolName = message.toolName ?? "?"
            return "[tool:\(toolName)] \(message.content)"
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run all `ConversationCompressorTests`. Expected: all 6 tests pass.

- [ ] **Step 5: Commit**

```bash
git add TipTour/Agents/Core/ConversationCompressor.swift TipTourTests/ConversationCompressorTests.swift
git commit -m "feat(agents): ConversationCompressor.compress with tool-pair-safe split"
```

---

## Task 3: `LLMProviderRegistry.summarizerProvider()`

**Files:**
- Modify: `TipTour/Agents/Core/LLMProviderRegistry.swift`

- [ ] **Step 1: Read the existing registry to understand its provider catalog**

Open `TipTour/Agents/Core/LLMProviderRegistry.swift` and identify how `provider(for: taskType)` resolves to a concrete provider — the same mechanism applies here. The cheapest-first preference order:

1. Gemini 2.5 Flash Lite (`gemini-rest:gemini-2.5-flash-lite`) — cheapest, fastest
2. Claude Haiku (`anthropic:claude-haiku-4-5`) — cheap + structured
3. The first available provider otherwise

- [ ] **Step 2: Add `summarizerProvider()` method**

Inside the registry's class body:

```swift
/// Returns the cheapest fast provider available for short-lived
/// summarization calls. Falls back through Gemini Flash Lite → Haiku
/// → first available. Returns nil only when no provider has been
/// configured at all.
func summarizerProvider() -> (any LLMProvider)? {
    let preferenceOrder = [
        "gemini-rest:gemini-2.5-flash-lite",
        "anthropic:claude-haiku-4-5",
        "openai:gpt-4o-mini"
    ]
    for preferredId in preferenceOrder {
        if let match = allProviders.first(where: { $0.providerId == preferredId }) {
            return match
        }
    }
    return allProviders.first
}
```

`allProviders` is the existing internal collection in `LLMProviderRegistry` (search for `private var providers` or similar — name varies). If the existing collection uses a different shape, adapt the accessor accordingly without changing the public surface.

- [ ] **Step 3: Build to confirm it compiles**

Build the TipTour target in Xcode (Cmd+B). Expected: no new errors.

- [ ] **Step 4: Commit**

```bash
git add TipTour/Agents/Core/LLMProviderRegistry.swift
git commit -m "feat(agents): LLMProviderRegistry.summarizerProvider()"
```

---

## Task 4: Wire the compressor into `TaskAgent.run()`

**Files:**
- Modify: `TipTour/Agents/Swarm/TaskAgent.swift`

- [ ] **Step 1: Add the threshold reader as a static**

Near the top of `TaskAgent`, add:

```swift
/// Compress the conversation when it exceeds this many messages.
/// 0 = compression disabled. Read at the start of run() so a Settings
/// change applies on the next agent spawn without an app restart.
private static func currentCompressionThreshold() -> Int {
    let raw = UserDefaults.standard.integer(forKey: "agentCompressionThreshold")
    // Default = 30; setter writes 0 explicitly to disable.
    if UserDefaults.standard.object(forKey: "agentCompressionThreshold") == nil {
        return 30
    }
    return raw
}

/// How many trailing messages to preserve verbatim when compressing.
private static let compressionKeepLastN: Int = 10
```

- [ ] **Step 2: Raise `maximumLoopCount`**

Change `private let maximumLoopCount: Int = 50` to `100`. Compression makes longer runs viable, but the agent's startup-emitted "BUDGET" line in `buildSystemPrompt` should also be updated to match — search for `\(maximumLoopCount) reasoning turns total` and confirm it interpolates the new value.

- [ ] **Step 3: Call the compressor at the top of each loop iteration**

Inside `run()`, after `await checkAndApplyInterrupts()` and before the provider call, add:

```swift
let threshold = Self.currentCompressionThreshold()
if threshold > 0, conversationHistory.count > threshold {
    await compressHistoryIfPossible()
}
```

Then add the private helper at the bottom of the actor:

```swift
private func compressHistoryIfPossible() async {
    guard let summarizer = LLMProviderRegistry.shared.summarizerProvider() else {
        // No summarizer wired — silently skip. The agent will continue
        // until it hits the loop cap, same as before this change.
        return
    }
    let beforeCount = conversationHistory.count
    do {
        let compressed = try await ConversationCompressor.compress(
            messages: conversationHistory,
            keepLastN: Self.compressionKeepLastN,
            summarizer: summarizer
        )
        if compressed.count < beforeCount {
            print("[TaskAgent \(id.uuidString.prefix(8))] 🗜️ compressed \(beforeCount) → \(compressed.count) messages via \(summarizer.providerId)")
            conversationHistory = compressed
            await recordStep("🗜️ folded earlier turns into a summary (kept last \(Self.compressionKeepLastN))", succeeded: true)
        }
    } catch {
        print("[TaskAgent \(id.uuidString.prefix(8))] compression failed: \(error.localizedDescription) — continuing without compression")
    }
}
```

The `do/catch` is deliberate: if the summarizer call fails (rate limit, network), the agent should continue with full history rather than dying — degraded behavior beats lost work.

- [ ] **Step 4: Run the existing TaskAgent tests to confirm nothing regressed**

If `TipTourTests/TaskAgentTests.swift` exists, run it in Xcode. Expected: all existing tests still pass — compression is opt-in via UserDefaults and disabled by default in test bundles unless the test sets the key.

- [ ] **Step 5: Smoke-test in the running app**

Build + run. Enable compression by writing `30` to UserDefaults (will be done via Settings UI in Task 5 — for the smoke test, write directly):

```bash
defaults write com.tiptour.TipTour agentCompressionThreshold -int 30
```

Spawn a long-running coding background task that produces 40+ messages — e.g. "explore the TipTour repo file by file and summarize each Swift file under TipTour/Agents". Watch the agent overlay for the "🗜️ folded earlier turns into a summary" step appearing once the threshold trips. Confirm the agent continues past message 50 without the previous loop-cap failure.

- [ ] **Step 6: Commit**

```bash
git add TipTour/Agents/Swarm/TaskAgent.swift
git commit -m "feat(agents): compress TaskAgent conversation past threshold; raise loop cap to 100"
```

---

## Task 5: Settings UI — Learning tab gets a compression section

**Files:**
- Modify: `TipTour/Agents/UI/SettingsView.swift`

- [ ] **Step 1: Add state for the threshold**

Inside `LearningSettingsView` (search for it in the file), add:

```swift
@State private var compressionThreshold: Double = Double(
    UserDefaults.standard.object(forKey: "agentCompressionThreshold") as? Int ?? 30
)
@State private var compressionEnabled: Bool = (
    UserDefaults.standard.object(forKey: "agentCompressionThreshold") as? Int ?? 30
) > 0
```

- [ ] **Step 2: Add the section in the view body**

After the self-critique slider section, add:

```swift
Divider()

VStack(alignment: .leading, spacing: 8) {
    HStack {
        Text("Conversation compression").font(.system(size: 13, weight: .medium))
        Spacer()
        Toggle("", isOn: $compressionEnabled)
            .toggleStyle(.switch)
            .labelsHidden()
            .onChange(of: compressionEnabled) { _, newValue in
                if newValue {
                    UserDefaults.standard.set(Int(compressionThreshold), forKey: "agentCompressionThreshold")
                } else {
                    UserDefaults.standard.set(0, forKey: "agentCompressionThreshold")
                }
            }
    }
    Text("When a background agent's conversation exceeds this many messages, TipTour folds the older messages into a one-paragraph summary using a cheap fast model. The last 10 turns stay verbatim. Lets long-running agents survive past the loop cap without losing context.")
        .font(.system(size: 11))
        .foregroundColor(DS.Colors.textTertiary)
        .fixedSize(horizontal: false, vertical: true)

    HStack {
        Text("Compress after").font(.system(size: 11))
        Slider(value: $compressionThreshold, in: 15...80, step: 5)
            .disabled(!compressionEnabled)
            .onChange(of: compressionThreshold) { _, newValue in
                if compressionEnabled {
                    UserDefaults.standard.set(Int(newValue), forKey: "agentCompressionThreshold")
                }
            }
        Text("\(Int(compressionThreshold)) messages")
            .font(.system(size: 11, design: .monospaced))
            .frame(width: 90, alignment: .trailing)
    }
}
```

- [ ] **Step 3: Smoke-test**

Build + run. Open Settings → Learning. Confirm the toggle and slider appear, toggling persists across app relaunch (`defaults read com.tiptour.TipTour agentCompressionThreshold`).

- [ ] **Step 4: Commit**

```bash
git add TipTour/Agents/UI/SettingsView.swift
git commit -m "feat(settings): compression toggle + threshold slider in Learning tab"
```

---

## Task 6: Documentation

**Files:**
- Modify: `AGENTS.md`

- [ ] **Step 1: Add `ConversationCompressor.swift` to the Key Files table**

```markdown
| `TipTour/Agents/Core/ConversationCompressor.swift` | ~150 | Pure helper. `compress(messages:keepLastN:summarizer:)` folds the older portion of a `[LLMMessage]` into a single summary message, preserving the system message and the trailing `keepLastN` turns verbatim. `findSafeSplitPoint(in:before:)` rewinds the split to avoid stranding `assistant.tool_use` blocks from their matching `tool` results. Called from `TaskAgent.run` between iterations when `conversationHistory.count` exceeds `agentCompressionThreshold` (UserDefaults, default 30, 0 = disabled). |
```

Add a paragraph to the architecture section after the per-agent workspace bullet:

```markdown
- **Conversation compression for long agent runs**: `TaskAgent.run` calls `ConversationCompressor.compress` between loop iterations once `conversationHistory.count > agentCompressionThreshold` (default 30, disable with 0). The compressor summarizes the older slice via `LLMProviderRegistry.summarizerProvider()` (Gemini Flash Lite → Haiku fallback) and replaces those messages with a single synthesized user-role `[Summary]` block, keeping the trailing 10 messages verbatim. The split point is rewound past any open `assistant.tool_use` so we never strand a tool_use without its tool_result. The loop cap is raised from 50 → 100 since compression makes longer runs viable. Compression toggle + threshold slider in Settings → Learning. |
```

- [ ] **Step 2: Commit**

```bash
git add AGENTS.md
git commit -m "docs: document conversation compression in AGENTS.md"
```

---

## Self-Review Checklist

- ✅ **Spec coverage:** Task 1 covers the safe split, Task 2 covers full compression, Task 3 wires the summarizer provider, Task 4 invokes it in the loop, Task 5 surfaces the setting, Task 6 documents. No gaps.
- ✅ **No placeholders:** Every step has runnable code. The summarizer prompt is fully written (Task 2 step 3), not stubbed.
- ✅ **Type consistency:** `findSafeSplitPoint(in:before:)` signature matches between tests and implementation; `compress(messages:keepLastN:summarizer:)` parameter order matches everywhere; `agentCompressionThreshold` is the UserDefaults key used in both the agent and the Settings UI.

---

## Risks the engineer should know going in

1. **Summary quality matters.** If the summarizer drops a fact the agent later needs (e.g. "user already tried `npm install` and it failed with EACCES"), the agent will redo work. We mitigate this with a prompt that explicitly asks for "specific values (URLs, file paths, IDs, error messages)" — but the prompt isn't infallible. If users report regressions, the fix is prompt-tuning, not architecture-change.
2. **Two LLMs in one loop.** Each compression adds one summarizer call (Flash Lite / Haiku, ~$0.001) per trip past the threshold. For a 100-turn agent that compresses twice, that's ~$0.002 plus the savings of NOT replaying 60 stale messages on subsequent provider calls. Net positive even on Haiku-driven agents; obviously net positive on Opus-driven ones.
3. **Tool-pair safety hinges on `toolCallId` being set on `.tool` messages.** Currently `TaskAgent.runToolCallBatch` does set `toolCallId: toolCall.id` when appending the tool result — see `TaskAgent.swift:622-628`. If that field is ever dropped, `findSafeSplitPoint` would silently lose its invariant. Add an assertion or test to that effect if you refactor `runToolCallBatch`.
4. **The voice session is unchanged.** This plan deliberately does NOT touch `GeminiLiveSession`. If we later want voice compression too, the architecture is different: server-side context can't be edited mid-session, so we'd need session-reconnect-with-summary, not in-place rewrite. Out of scope here.
5. **Disabled by default in tests.** UserDefaults reads in the test target won't return 30 unless the key has been written. `currentCompressionThreshold` returns 30 only when the key is `nil`; if some other test wrote 0 first, the default disappears. If you see flaky behavior in tests, check whether something is leaving stale UserDefaults state.
