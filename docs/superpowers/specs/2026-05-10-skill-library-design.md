# SkillLibrary Design

## Goal

Give TipTour's background agents a persistent, shared library of reusable skills — recorded sequences of tool calls from past successful runs — so agents can learn how to accomplish tasks rather than rediscovering procedures from scratch.

## Scope

This spec covers SkillLibrary only (Phase 4B). AgentMemory (Phase 4A) is already implemented. DemonstrationRecorder and EfficiencyMonitor are separate specs.

---

## Data Model

Each skill is a single `.md` file stored at:

```
~/Library/Application Support/TipTour/skills/<slug>.md
```

### File Format

```markdown
---
name: install-pnpm-dependencies
description: Install dependencies in a pnpm-based Node.js project
taskTypes: [coding]
keywords: [pnpm, install, dependencies, node]
createdAt: 2026-05-10
---

# Install pnpm dependencies

## Steps

1. **run_shell_command** `pnpm install`
   → Done. 42 packages installed.

2. **run_shell_command** `pnpm build`
   → Build successful.

## Result

Dependencies installed and project built successfully.
```

- **Frontmatter** — YAML with `name`, `description`, `taskTypes`, `keywords`, `createdAt`. Parsed at load time to build the in-memory index.
- **Body** — Markdown procedure. Auto-generated from the agent's tool call history at task completion. Human-editable after the fact.
- **Slug** — filename without `.md`. Derived from `name` by lowercasing and replacing spaces/special characters with hyphens. Truncated to 60 characters if needed.

### `RecordedToolCall`

Represents one step in a skill's tool call history:

```swift
struct RecordedToolCall: Codable, Sendable {
    let toolName: String
    let argumentsJSON: String
    let result: String
}
```

### `SkillEntry`

In-memory index metadata (not the full body):

```swift
struct SkillEntry: Identifiable, Sendable {
    let id: UUID
    let slug: String
    let name: String
    let description: String
    let taskTypes: [TaskType]
    let keywords: [String]
    let createdAt: Date
}
```

The full `.md` body is read from disk only when a specific skill is fetched via `fetchBody(slug:)`.

---

## Storage Layer — `SkillLibraryStore`

A Swift `actor` singleton (`static let shared`). Manages the skills directory and an in-memory `[SkillEntry]` index.

**Directory:** `~/Library/Application Support/TipTour/skills/` — created at `init` if it doesn't exist.

**At init:** Scans the directory, parses YAML frontmatter from each `.md` file, builds the index. Files with unparseable frontmatter are skipped with no crash.

### Methods

**`write(slug:name:description:taskTypes:body:) async`**
- Writes the `.md` file to disk (overwrites if slug already exists)
- Parses keywords from `name + " " + description` using `AgentMemoryEntry.extractKeywords(from:)`
- Updates the in-memory index

**`query(taskDescription:taskTypes:limit:) async -> [SkillEntry]`**
- Scores each index entry: +2 if task-type overlaps with `taskTypes`, +1 per keyword overlap with `taskDescription`
- Returns up to `limit` (default 10) highest-scoring entries
- Entries with score 0 are excluded

**`fetchBody(slug:) async -> String?`**
- Reads and returns the full `.md` file contents for the given slug
- Returns `nil` if the file doesn't exist

**`delete(slug:) async`**
- Removes the `.md` file from disk
- Removes the entry from the in-memory index

**`static func generateSlug(from name: String) -> String`**
- Pure static helper implementing the slug algorithm above
- Called by `TaskAgent.autoSaveSkill` before passing the slug to `write`
- Deduplication (-2, -3 suffix) is handled inside `write`, not here

### Slug Generation

```
1. Lowercase the name
2. Replace all non-alphanumeric characters with hyphens
3. Collapse consecutive hyphens to one
4. Strip leading/trailing hyphens
5. Truncate to 60 characters
6. If slug already exists in the store, append -2, -3, etc.
```

### Body Generation

Given a task description, result text, and `[RecordedToolCall]`, `SkillBodyBuilder.build(name:taskDescription:toolCalls:resultSummary:)` produces the `.md` body:

```swift
enum SkillBodyBuilder {
    static func build(
        name: String,
        taskDescription: String,
        toolCalls: [RecordedToolCall],
        resultSummary: String
    ) -> String
}
```

Output format:
```markdown
# <name>

## Steps

1. **<toolName>** `<argumentsJSON>`
   → <result (first 200 chars)>

2. ...

## Result

<resultSummary (first 300 chars)>
```

If `toolCalls` is empty (agent completed without using any tools), the Steps section is omitted.

---

## New Tools — `SkillTools.swift`

Two new tools added to `ToolBox.build(for:)` for **all task types**.

### `SaveSkillTool` (`save_skill`)

```json
{
  "type": "object",
  "properties": {
    "name": {
      "type": "string",
      "description": "Short kebab-case name for this skill (e.g. 'install-pnpm-deps')."
    },
    "description": {
      "type": "string",
      "description": "One sentence describing when to use this skill."
    }
  },
  "required": ["name", "description"]
}
```

- Snapshots the agent's current tool call history via an injected `() -> [RecordedToolCall]` closure
- Generates the body using `SkillBodyBuilder.build`
- Calls `SkillLibraryStore.shared.write(...)` with `taskTypes: [currentTaskType]`
- Returns `"Skill saved: <name>"` on success, `"Error: <message>"` on failure

### `RecallSkillTool` (`recall_skill`)

```json
{
  "type": "object",
  "properties": {
    "query": {
      "type": "string",
      "description": "Describe what you're trying to do. E.g. 'install node dependencies' or 'build xcode project'."
    }
  },
  "required": ["query"]
}
```

- Calls `SkillLibraryStore.shared.query(taskDescription:query, taskTypes:[currentTaskType], limit:1)`
- Fetches the full `.md` body of the top result via `fetchBody(slug:)`
- Returns the full body string on success, `"No matching skill found."` if empty

Both tools receive `taskType` at construction time via `ToolBox.build(for:)`:
```swift
SaveSkillTool(taskType: taskType, historyProvider: { await agent.toolCallHistory }),
RecallSkillTool(taskType: taskType)
```

`historyProvider` has type `@Sendable () async -> [RecordedToolCall]`. The async closure hops back to the `TaskAgent` actor to read its `toolCallHistory` property safely.

---

## TaskAgent Integration

### New stored property

```swift
private var toolCallHistory: [RecordedToolCall] = []
```

Appended in `dispatchToolCall(_:)` after each successful tool execution:

```swift
private func dispatchToolCall(_ toolCall: LLMToolCall) async -> String {
    let result = await toolBox.execute(toolCall: toolCall)
    toolCallHistory.append(RecordedToolCall(
        toolName: toolCall.name,
        argumentsJSON: toolCall.argumentsJSON,
        result: result
    ))
    return result
}
```

### Tool construction

`SaveSkillTool` is constructed with a closure capturing `toolCallHistory`:

```swift
SaveSkillTool(taskType: taskType, historyProvider: { [self] in self.toolCallHistory })
```

Because `TaskAgent` is an actor, `self.toolCallHistory` is actor-isolated and safe to access from within the actor's own methods.

### At Startup (before first LLM call)

Query the store for relevant skills and prepend to the system prompt:

```swift
let skills = await SkillLibraryStore.shared.query(
    taskDescription: taskDescription,
    taskTypes: [taskType]
)
```

If non-empty, inject a block listing skill names + descriptions (not full bodies):

```
--- Relevant skills ---
1. install-pnpm-deps: Install dependencies in a pnpm-based project
2. run-xcode-tests: Run the TipTour test suite in Xcode
---
```

If empty, omit the block entirely.

### At Completion (after final `.text` response)

Auto-write a skill using the task description as the name and the tool call history as steps:

```swift
await autoSaveSkill(taskResult: text)
```

```swift
private func autoSaveSkill(taskResult: String) async {
    guard !toolCallHistory.isEmpty else { return }
    let slug = SkillLibraryStore.generateSlug(from: taskDescription)
    let body = SkillBodyBuilder.build(
        name: taskDescription,
        taskDescription: taskDescription,
        toolCalls: toolCallHistory,
        resultSummary: taskResult
    )
    await SkillLibraryStore.shared.write(
        slug: slug,
        name: taskDescription,
        description: String(taskResult.prefix(120)),
        taskTypes: [taskType],
        body: body
    )
}
```

Auto-save is skipped when `toolCallHistory` is empty (agent responded immediately without using any tools — not useful as a skill). Error paths and terminated agents do not auto-save.

---

## New Files

| File | Purpose |
|------|---------|
| `TipTour/Agents/Skills/SkillEntry.swift` | `SkillEntry`, `RecordedToolCall`, `SkillBodyBuilder` |
| `TipTour/Agents/Skills/SkillLibraryStore.swift` | Actor singleton — directory scan, write/query/fetchBody/delete |
| `TipTour/Agents/Tools/SkillTools.swift` | `SaveSkillTool`, `RecallSkillTool` |

## Modified Files

| File | Change |
|------|--------|
| `TipTour/Agents/Swarm/AgentTypes.swift` | Add `RecordedToolCall` (or put in `SkillEntry.swift` — see below) |
| `TipTour/Agents/Swarm/TaskAgent.swift` | Add `toolCallHistory`, update `dispatchToolCall`, inject skills at startup, auto-save at completion |
| `TipTour/Agents/Tools/AgentTool.swift` | Add `save_skill` and `recall_skill` to `ToolBox.build(for:)` for all task types |

> Note: `RecordedToolCall` is placed in `SkillEntry.swift` (not `AgentTypes.swift`) since it is only used by the SkillLibrary subsystem.

---

## Testing

- `SkillBodyBuilder`: known `RecordedToolCall` inputs → expected markdown output
- `SkillLibraryStore` write + query: write entries, query by task type and keyword, verify scoring
- `SkillLibraryStore` slug generation: name with spaces/special chars → expected slug; duplicate slug → slug-2
- `SkillLibraryStore` fetchBody: written body is returned verbatim
- `SkillLibraryStore` delete: entry removed from index and file deleted from disk
- `SaveSkillTool` execute: valid JSON + non-empty history → file written, confirmation returned
- `SaveSkillTool` execute: empty history → skill still written (no guard on empty history in the tool itself — auto-save has the guard, not the manual tool)
- `RecallSkillTool` execute: query matches → full body returned; no match → "No matching skill found."
- `TaskAgent` integration: mock store, verify skill injected into first system message; verify auto-save fires on completion with tool calls; verify auto-save skipped when history empty
