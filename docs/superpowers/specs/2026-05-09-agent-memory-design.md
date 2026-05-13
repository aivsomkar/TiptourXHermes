# AgentMemory Design

## Goal

Give TipTour's background agents a persistent, shared memory store so that facts discovered in one task — environment details, project conventions, learned preferences — are available to future agents without re-discovery.

## Scope

This spec covers AgentMemory only (Phase 4A). SkillLibrary, DemonstrationRecorder, and EfficiencyMonitor are separate specs.

---

## Data Model

Each memory is an `AgentMemoryEntry`:

| Field | Type | Notes |
|-------|------|-------|
| `id` | `UUID` | Stable identifier |
| `content` | `String` | The fact or task summary in plain text |
| `entryType` | `MemoryEntryType` | `.fact` or `.taskResult` |
| `taskTypes` | `[TaskType]` | Task types this entry is relevant to |
| `keywords` | `[String]` | Lowercased tokens extracted at write time |
| `createdAt` | `Date` | Write timestamp |
| `expiresAt` | `Date?` | Nil = permanent (never pruned) |

```swift
enum MemoryEntryType: String, Codable {
    case fact        // Explicitly written by agent via remember_fact tool
    case taskResult  // Auto-written at task completion
}
```

**TTL rules:**
- `.fact` with `permanent: false` → expires 30 days after creation
- `.fact` with `permanent: true` → `expiresAt = nil`, never pruned
- `.taskResult` → always expires 7 days after creation, never permanent

**Persistence:** JSON array at `~/Library/Application Support/TipTour/agent-memory.json`. Loaded into memory at app launch, filtered in-process, written back on every mutation.

---

## Storage Layer — `AgentMemoryStore`

A Swift `actor` singleton (`static let shared`). Owns the in-memory array and the on-disk JSON file.

### Methods

**`write(content:entryType:taskTypes:permanent:) async`**
- Extracts keywords from `content`
- Appends a new `AgentMemoryEntry` to the array
- Calls `pruneExpired()` to remove stale entries
- Saves the updated array to disk

**`query(taskDescription:taskTypes:limit:) async -> [AgentMemoryEntry]`**
- Scores each entry: +2 if it shares a task type with `taskTypes`, +1 per keyword overlap with `taskDescription` (lowercased), +1 if permanent
- Returns up to `limit` (default 20) highest-scoring entries, deduplicated
- Entries with score 0 are excluded

**`pruneExpired() async`**
- Removes all entries where `expiresAt != nil && expiresAt < Date.now`
- Called after every `write` and once at app launch

**`clear(keepPermanent:) async`**
- When `keepPermanent: true` (default): removes all non-permanent entries
- When `keepPermanent: false`: wipes everything
- Used in tests and for a future settings UI

### Keyword Extraction

In-process, no external dependency:
1. Lowercase the content
2. Split on whitespace and common punctuation (`.,!?;:()"'`)
3. Filter tokens shorter than 3 characters
4. Filter a hardcoded stop-word list: `["the", "a", "an", "is", "are", "was", "were", "be", "been", "being", "have", "has", "had", "do", "does", "did", "will", "would", "could", "should", "may", "might", "shall", "can", "need", "dare", "ought", "used", "to", "of", "in", "on", "at", "by", "for", "with", "about", "as", "into", "through", "during", "before", "after", "above", "below", "from", "up", "down", "out", "off", "over", "under", "again", "then", "once", "and", "but", "or", "nor", "so", "yet", "both", "not", "this", "that", "it", "its"]`
5. Return unique remaining tokens

---

## New Tools — `MemoryTools.swift`

Two new tools added to `ToolBox.build(for:)` for **all task types**.

### `RememberFactTool` (`remember_fact`)

```json
{
  "type": "object",
  "properties": {
    "content": {
      "type": "string",
      "description": "The fact to remember. Be specific and self-contained — future agents will read this without your current context."
    },
    "permanent": {
      "type": "boolean",
      "description": "Set true for durable facts that won't change (tool paths, project conventions, env details). Defaults to false (expires in 30 days)."
    }
  },
  "required": ["content"]
}
```

Calls `AgentMemoryStore.shared.write(content:entryType:.fact, taskTypes:[currentTaskType], permanent:)`.
Returns: `"Remembered: <content>"` on success, `"Error: <message>"` on failure.

The current agent's `taskType` is passed in at tool construction time via a closure or stored property so the tool knows how to tag the entry.

### `RecallFactsTool` (`recall_facts`)

```json
{
  "type": "object",
  "properties": {
    "query": {
      "type": "string",
      "description": "Describe what you're trying to find. E.g. 'homebrew path' or 'project build command'."
    }
  },
  "required": ["query"]
}
```

Calls `AgentMemoryStore.shared.query(taskDescription:query, taskTypes:[currentTaskType])`.
Returns a numbered list:
```
1. [content] (fact, permanent)
2. [content] (task result, expires 2026-06-01)
```
Returns `"No matching memories found."` if the result is empty.

Both tools receive `taskType` at construction time. `ToolBox.build(for:)` passes it in:
```swift
RememberFactTool(taskType: taskType),
RecallFactsTool(taskType: taskType),
```

---

## TaskAgent Integration

### At Startup (before first LLM call)

Query the store using the task description and task type:

```swift
let memories = await AgentMemoryStore.shared.query(
    taskDescription: taskDescription,
    taskTypes: [taskType]
)
```

If `memories` is non-empty, prepend a block to the system prompt:

```
--- Memory from previous tasks ---
1. This machine has Homebrew at /opt/homebrew (fact, permanent)
2. TipTour uses pnpm, not npm (fact, expires 2026-06-08)
3. Last coding task: Fixed MacControlTools.swift async closure error. Build passed. (task result, expires 2026-05-16)
---
```

If empty, omit the block entirely — no noise for fresh agents.

### At Completion (after final LLM text response)

Auto-write a task result:

```swift
let summary = "\(agentName): \(taskDescription). \(String(finalResponse.prefix(300)))"
await AgentMemoryStore.shared.write(
    content: summary,
    entryType: .taskResult,
    taskTypes: [taskType],
    permanent: false
)
```

This runs even if the agent completes via error state — only `.terminated` agents skip the auto-write.

---

## New Files

| File | Purpose |
|------|---------|
| `TipTour/Agents/Memory/AgentMemoryEntry.swift` | `AgentMemoryEntry`, `MemoryEntryType`, keyword extractor |
| `TipTour/Agents/Memory/AgentMemoryStore.swift` | Actor singleton, load/save/query/prune logic |
| `TipTour/Agents/Tools/MemoryTools.swift` | `RememberFactTool`, `RecallFactsTool` |

## Modified Files

| File | Change |
|------|--------|
| `TipTour/Agents/Swarm/TaskAgent.swift` | Inject memories at startup; write task result at completion |
| `TipTour/Agents/Tools/AgentTool.swift` | Add memory tools to `ToolBox.build(for:)` for all task types |

---

## Testing

- `AgentMemoryEntry` keyword extraction: known inputs → expected token arrays
- `AgentMemoryStore` write + query: write entries, query by task type, query by keyword, verify scoring
- `AgentMemoryStore` TTL pruning: write entries with past `expiresAt`, prune, verify removal
- `AgentMemoryStore` permanent entries: verify permanent entries survive `pruneExpired()` and `clear(keepPermanent: true)`
- `RememberFactTool` execute: valid JSON → store write → confirmation string
- `RecallFactsTool` execute: query matches → formatted list; no matches → "No matching memories found."
- `TaskAgent` integration: mock store, verify memory injected into first message; verify task result written on completion
