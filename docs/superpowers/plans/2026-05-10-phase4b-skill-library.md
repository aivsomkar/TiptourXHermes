# SkillLibrary Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give TipTour's background agents a persistent, shared library of reusable skills — recorded sequences of tool calls from past successful runs stored as `.md` files — so agents can recall how to accomplish tasks without re-discovery.

**Architecture:** A `SkillLibraryStore` actor singleton manages a directory of `.md` skill files with YAML frontmatter. `SaveSkillTool` snapshots the agent's `ToolCallHistoryBuffer` and writes a new file; `RecallSkillTool` queries the index and returns the full `.md` body. `TaskAgent` injects matching skill names at startup and auto-saves a skill on completion when tool calls were made.

**Tech Stack:** Swift actors, `FileManager` / `String(contentsOf:)` / `write(to:atomically:encoding:)`, YAML frontmatter parsed in-process (no external dependency), Swift Testing (`import Testing`).

---

## File Structure

| Action | Path | Responsibility |
|--------|------|----------------|
| Create | `TipTour/Agents/Skills/SkillEntry.swift` | `RecordedToolCall`, `ToolCallHistoryBuffer`, `SkillEntry` (with frontmatter parser), `SkillBodyBuilder` |
| Create | `TipTour/Agents/Skills/SkillLibraryStore.swift` | Actor singleton — directory scan, write/query/fetchBody/delete/clear |
| Create | `TipTour/Agents/Tools/SkillTools.swift` | `SaveSkillTool`, `RecallSkillTool` |
| Modify | `TipTour/Agents/Tools/AgentTool.swift` | Add `domainTools(for:)` private helper; add `RecallSkillTool` to `build(for:)`; add `build(for:historyBuffer:)` overload |
| Modify | `TipTour/Agents/Swarm/TaskAgent.swift` | Remove `toolBox` init param (built internally); add `skillHistoryBuffer`; update `dispatchToolCall`; inject skills at startup; auto-save at completion |
| Modify | `TipTour/Agents/Swarm/AgentSwarmManager.swift` | Remove explicit `ToolBox.build` + `toolBox:` argument from `spawn` |
| Create | `TipTourTests/SkillLibraryTests.swift` | All tests for this feature |

---

## Task 1: SkillEntry types, ToolCallHistoryBuffer, and SkillBodyBuilder

**Files:**
- Create: `TipTour/Agents/Skills/SkillEntry.swift`
- Create: `TipTourTests/SkillLibraryTests.swift`

- [ ] **Step 1: Write failing tests**

Create `TipTourTests/SkillLibraryTests.swift`:

```swift
// TipTourTests/SkillLibraryTests.swift

import Foundation
import Testing
@testable import TipTour

// MARK: - SkillEntry tests

@Suite("SkillEntry")
struct SkillEntryTests {

    @Test func parseFrontmatterExtractsAllFields() {
        let content = """
        ---
        id: 550E8400-E29B-41D4-A716-446655440000
        name: install-pnpm-deps
        description: Install pnpm dependencies
        taskTypes: [coding]
        keywords: [install, pnpm]
        createdAt: 2026-05-10
        ---

        # install-pnpm-deps
        """
        let entry = SkillEntry.parse(from: content, slug: "install-pnpm-deps")
        #expect(entry != nil)
        #expect(entry?.name == "install-pnpm-deps")
        #expect(entry?.description == "Install pnpm dependencies")
        #expect(entry?.taskTypes == [.coding])
        #expect(entry?.keywords.contains("pnpm") == true)
        #expect(entry?.slug == "install-pnpm-deps")
    }

    @Test func parseFrontmatterReturnsNilWhenNameMissing() {
        let content = """
        ---
        description: No name here
        taskTypes: [coding]
        ---
        """
        #expect(SkillEntry.parse(from: content, slug: "no-name") == nil)
    }

    @Test func parseFrontmatterReturnsNilWhenNoFrontmatter() {
        let content = "# Just a markdown file\n\nNo frontmatter."
        #expect(SkillEntry.parse(from: content, slug: "no-fm") == nil)
    }

    @Test func frontmatterRoundTrip() {
        let original = SkillEntry(
            id: UUID(uuidString: "550E8400-E29B-41D4-A716-446655440000")!,
            slug: "test-skill",
            name: "test skill",
            description: "A test skill",
            taskTypes: [.coding, .analysis],
            keywords: ["test", "skill"],
            createdAt: Date(timeIntervalSince1970: 1_746_835_200)
        )
        let fileContent = original.frontmatter + "\n\n## Steps\n\n1. do something"
        let reparsed = SkillEntry.parse(from: fileContent, slug: original.slug)
        #expect(reparsed?.id == original.id)
        #expect(reparsed?.name == original.name)
        #expect(reparsed?.taskTypes == original.taskTypes)
    }

    @Test func skillBodyBuilderWithToolCallsProducesStepsSection() {
        let toolCalls = [
            RecordedToolCall(toolName: "run_shell_command", argumentsJSON: #"{"command":"pnpm install"}"#, result: "Done."),
            RecordedToolCall(toolName: "run_shell_command", argumentsJSON: #"{"command":"pnpm build"}"#, result: "Build OK.")
        ]
        let body = SkillBodyBuilder.build(name: "install", toolCalls: toolCalls, resultSummary: "All done.")
        #expect(body.contains("## Steps"))
        #expect(body.contains("run_shell_command"))
        #expect(body.contains("pnpm install"))
        #expect(body.contains("## Result"))
        #expect(body.contains("All done."))
    }

    @Test func skillBodyBuilderWithNoToolCallsOmitsStepsSection() {
        let body = SkillBodyBuilder.build(name: "no-tools", toolCalls: [], resultSummary: "Answered directly.")
        #expect(!body.contains("## Steps"))
        #expect(body.contains("## Result"))
        #expect(body.contains("Answered directly."))
    }

    @Test func skillBodyBuilderTruncatesLongResultSummary() {
        let longResult = String(repeating: "x", count: 500)
        let body = SkillBodyBuilder.build(name: "truncate-test", toolCalls: [], resultSummary: longResult)
        let resultSection = body.components(separatedBy: "## Result\n\n").last ?? ""
        #expect(resultSection.count <= 300)
    }

    @Test func toolCallHistoryBufferAppendsAndReads() {
        let buffer = ToolCallHistoryBuffer()
        buffer.append(RecordedToolCall(toolName: "read_file", argumentsJSON: "{}", result: "content"))
        buffer.append(RecordedToolCall(toolName: "write_file", argumentsJSON: "{}", result: "ok"))
        #expect(buffer.calls.count == 2)
        #expect(buffer.calls.first?.toolName == "read_file")
    }
}
```

- [ ] **Step 2: Run tests — expect failure**

Press **Cmd+U** in Xcode. `SkillEntryTests` should fail with "Cannot find type 'SkillEntry' in scope".

- [ ] **Step 3: Create `SkillEntry.swift`**

Create `TipTour/Agents/Skills/SkillEntry.swift`:

```swift
// TipTour/Agents/Skills/SkillEntry.swift

import Foundation

// MARK: - One tool call captured during agent execution

struct RecordedToolCall: Codable, Sendable {
    let toolName: String
    let argumentsJSON: String
    let result: String
}

// MARK: - Thread-safe buffer the agent writes to as it executes tools

/// Holds the ordered list of tool calls made during a task run.
/// Using a lock instead of an actor so it can be read synchronously from SaveSkillTool.execute.
final class ToolCallHistoryBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [RecordedToolCall] = []

    func append(_ call: RecordedToolCall) {
        lock.withLock { _calls.append(call) }
    }

    var calls: [RecordedToolCall] {
        lock.withLock { _calls }
    }
}

// MARK: - In-memory index entry for one skill .md file

struct SkillEntry: Identifiable, Sendable {
    let id: UUID
    let slug: String
    let name: String
    let description: String
    let taskTypes: [TaskType]
    let keywords: [String]
    let createdAt: Date

    /// Parses a SkillEntry from the frontmatter block of a `.md` file.
    /// Returns nil if the `---` opening marker is absent or the `name` field is missing.
    static func parse(from fileContent: String, slug: String) -> SkillEntry? {
        let lines = fileContent.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return nil }

        var frontmatterLines: [String] = []
        for line in lines.dropFirst() {
            if line.trimmingCharacters(in: .whitespaces) == "---" { break }
            frontmatterLines.append(line)
        }

        var dict: [String: String] = [:]
        for line in frontmatterLines {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 { dict[String(parts[0])] = String(parts[1]) }
        }

        guard let name = dict["name"], !name.isEmpty else { return nil }

        let description = dict["description"] ?? ""

        let taskTypes: [TaskType] = dict["taskTypes"]
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "[]")) }?
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .compactMap { TaskType(rawValue: $0) } ?? []

        let keywords: [String] = dict["keywords"]
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "[]")) }?
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty } ?? []

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let createdAt = dict["createdAt"].flatMap { dateFormatter.date(from: $0) } ?? Date.now
        let id = dict["id"].flatMap { UUID(uuidString: $0) } ?? UUID()

        return SkillEntry(
            id: id,
            slug: slug,
            name: name,
            description: description,
            taskTypes: taskTypes,
            keywords: keywords,
            createdAt: createdAt
        )
    }

    /// Generates the YAML frontmatter block for writing to disk.
    var frontmatter: String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let taskTypesStr = taskTypes.map(\.rawValue).joined(separator: ", ")
        let keywordsStr = keywords.joined(separator: ", ")
        return "---\n"
            + "id: \(id.uuidString)\n"
            + "name: \(name)\n"
            + "description: \(description)\n"
            + "taskTypes: [\(taskTypesStr)]\n"
            + "keywords: [\(keywordsStr)]\n"
            + "createdAt: \(dateFormatter.string(from: createdAt))\n"
            + "---"
    }
}

// MARK: - Generates the markdown body of a skill file from tool call history

enum SkillBodyBuilder {
    static func build(
        name: String,
        toolCalls: [RecordedToolCall],
        resultSummary: String
    ) -> String {
        var lines: [String] = ["# \(name)", ""]

        if !toolCalls.isEmpty {
            lines.append("## Steps")
            lines.append("")
            for (index, call) in toolCalls.enumerated() {
                let resultPreview = String(call.result.prefix(200))
                lines.append("\(index + 1). **\(call.toolName)** `\(call.argumentsJSON)`")
                lines.append("   → \(resultPreview)")
                lines.append("")
            }
        }

        lines.append("## Result")
        lines.append("")
        lines.append(String(resultSummary.prefix(300)))

        return lines.joined(separator: "\n")
    }
}
```

- [ ] **Step 4: Run tests — expect pass**

Press **Cmd+U**. `SkillEntryTests` (8 tests) should all pass.

- [ ] **Step 5: Commit**

```bash
git add TipTour/Agents/Skills/SkillEntry.swift TipTourTests/SkillLibraryTests.swift
git commit -m "feat: add SkillEntry types, ToolCallHistoryBuffer, and SkillBodyBuilder"
```

---

## Task 2: SkillLibraryStore actor

**Files:**
- Create: `TipTour/Agents/Skills/SkillLibraryStore.swift`
- Modify: `TipTourTests/SkillLibraryTests.swift` (append store tests)

- [ ] **Step 1: Write failing tests**

Append to `TipTourTests/SkillLibraryTests.swift` after the `SkillEntryTests` closing brace:

```swift
// MARK: - SkillLibraryStore tests

@Suite("SkillLibraryStore")
struct SkillLibraryStoreTests {

    private func makeTempStore() -> SkillLibraryStore {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("tiptour-skills-test-\(UUID().uuidString)", isDirectory: true)
        return SkillLibraryStore(directoryURL: tmp)
    }

    @Test func writeAndQueryByTaskType() async {
        let store = makeTempStore()
        let body = SkillBodyBuilder.build(name: "pnpm install", toolCalls: [], resultSummary: "Done.")
        await store.write(slug: "pnpm-install", name: "pnpm install", description: "Install pnpm deps", taskTypes: [.coding], body: body)
        let results = await store.query(taskDescription: "install pnpm dependencies", taskTypes: [.coding])
        #expect(!results.isEmpty)
        #expect(results.first?.slug == "pnpm-install")
    }

    @Test func queryByKeywordOverlap() async {
        let store = makeTempStore()
        let body = SkillBodyBuilder.build(name: "homebrew setup", toolCalls: [], resultSummary: "Installed.")
        await store.write(slug: "homebrew-setup", name: "homebrew setup", description: "Install homebrew package manager", taskTypes: [.generalMac], body: body)
        // Different task type but keyword overlap on "homebrew"
        let results = await store.query(taskDescription: "find homebrew path", taskTypes: [.coding])
        #expect(!results.isEmpty)
    }

    @Test func queryReturnsEmptyWhenNoMatch() async {
        let store = makeTempStore()
        let body = SkillBodyBuilder.build(name: "xcode build", toolCalls: [], resultSummary: "Built.")
        await store.write(slug: "xcode-build", name: "xcode build", description: "Build xcode project", taskTypes: [.coding], body: body)
        let results = await store.query(taskDescription: "unrelated bananas query zyx987", taskTypes: [.writing])
        #expect(results.isEmpty)
    }

    @Test func fetchBodyReturnsWrittenContent() async {
        let store = makeTempStore()
        let body = SkillBodyBuilder.build(name: "test skill", toolCalls: [], resultSummary: "Result here.")
        await store.write(slug: "test-skill", name: "test skill", description: "A test skill", taskTypes: [.coding], body: body)
        let fetched = await store.fetchBody(slug: "test-skill")
        #expect(fetched != nil)
        #expect(fetched?.contains("## Result") == true)
        #expect(fetched?.contains("Result here.") == true)
    }

    @Test func fetchBodyReturnsNilForMissingSlug() async {
        let store = makeTempStore()
        #expect(await store.fetchBody(slug: "nonexistent") == nil)
    }

    @Test func deleteRemovesFromIndexAndDisk() async {
        let store = makeTempStore()
        let body = SkillBodyBuilder.build(name: "temp skill", toolCalls: [], resultSummary: "Done.")
        await store.write(slug: "temp-skill", name: "temp skill", description: "Temporary", taskTypes: [.coding], body: body)
        await store.delete(slug: "temp-skill")
        let results = await store.query(taskDescription: "temp skill", taskTypes: [.coding])
        #expect(results.isEmpty)
        #expect(await store.fetchBody(slug: "temp-skill") == nil)
    }

    @Test func generateSlugLowercasesAndReplacesSpecialChars() {
        #expect(SkillLibraryStore.generateSlug(from: "Install Pnpm Deps") == "install-pnpm-deps")
        #expect(SkillLibraryStore.generateSlug(from: "fix!!bug") == "fix-bug")
    }

    @Test func generateSlugTruncatesTo60Characters() {
        let longName = String(repeating: "a", count: 100)
        #expect(SkillLibraryStore.generateSlug(from: longName).count <= 60)
    }

    @Test func writeDeduplicatesSlugOnConflict() async {
        let store = makeTempStore()
        let body = SkillBodyBuilder.build(name: "same skill", toolCalls: [], resultSummary: "Done.")
        await store.write(slug: "same-skill", name: "same skill", description: "First", taskTypes: [.coding], body: body)
        await store.write(slug: "same-skill", name: "same skill", description: "Second", taskTypes: [.coding], body: body)
        let results = await store.query(taskDescription: "same skill", taskTypes: [.coding])
        #expect(results.count == 2)
        let slugs = Set(results.map(\.slug))
        #expect(slugs.contains("same-skill"))
        #expect(slugs.contains("same-skill-2"))
    }

    @Test func clearRemovesAllEntries() async {
        let store = makeTempStore()
        let body = SkillBodyBuilder.build(name: "skill one", toolCalls: [], resultSummary: "Done.")
        await store.write(slug: "skill-one", name: "skill one", description: "First", taskTypes: [.coding], body: body)
        await store.clear()
        let results = await store.query(taskDescription: "skill one", taskTypes: [.coding])
        #expect(results.isEmpty)
    }
}
```

- [ ] **Step 2: Run tests — expect failure**

Press **Cmd+U**. `SkillLibraryStoreTests` should fail with "Cannot find type 'SkillLibraryStore' in scope".

- [ ] **Step 3: Create `SkillLibraryStore.swift`**

Create `TipTour/Agents/Skills/SkillLibraryStore.swift`:

```swift
// TipTour/Agents/Skills/SkillLibraryStore.swift

import Foundation

actor SkillLibraryStore {

    static let shared = SkillLibraryStore()

    private var index: [SkillEntry] = []
    private let directoryURL: URL

    static var defaultDirectoryURL: URL {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("TipTour", isDirectory: true)
            .appendingPathComponent("skills", isDirectory: true)
    }

    init(directoryURL: URL = SkillLibraryStore.defaultDirectoryURL) {
        self.directoryURL = directoryURL
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let mdFiles = (try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        ))?.filter { $0.pathExtension == "md" } ?? []
        self.index = mdFiles.compactMap { url in
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return SkillEntry.parse(from: content, slug: url.deletingPathExtension().lastPathComponent)
        }
    }

    // MARK: - Write

    func write(
        slug: String,
        name: String,
        description: String,
        taskTypes: [TaskType],
        body: String
    ) async {
        let finalSlug = deduplicatedSlug(for: slug)
        let keywords = AgentMemoryEntry.extractKeywords(from: name + " " + description)
        let entry = SkillEntry(
            id: UUID(),
            slug: finalSlug,
            name: name,
            description: description,
            taskTypes: taskTypes,
            keywords: keywords,
            createdAt: Date.now
        )
        let fileContent = entry.frontmatter + "\n\n" + body
        let fileURL = directoryURL.appendingPathComponent("\(finalSlug).md")
        try? fileContent.write(to: fileURL, atomically: true, encoding: .utf8)
        if let existing = index.firstIndex(where: { $0.slug == finalSlug }) {
            index[existing] = entry
        } else {
            index.append(entry)
        }
    }

    // MARK: - Query

    func query(taskDescription: String, taskTypes: [TaskType], limit: Int = 10) async -> [SkillEntry] {
        let descriptionKeywords = Set(AgentMemoryEntry.extractKeywords(from: taskDescription))
        let targetTaskTypes = Set(taskTypes)

        let scored: [(entry: SkillEntry, score: Int)] = index.compactMap { entry in
            var score = 0
            if !Set(entry.taskTypes).isDisjoint(with: targetTaskTypes) { score += 2 }
            score += Set(entry.keywords).intersection(descriptionKeywords).count
            guard score > 0 else { return nil }
            return (entry, score)
        }

        return scored.sorted { $0.score > $1.score }.prefix(limit).map(\.entry)
    }

    // MARK: - Fetch body

    func fetchBody(slug: String) async -> String? {
        let fileURL = directoryURL.appendingPathComponent("\(slug).md")
        return try? String(contentsOf: fileURL, encoding: .utf8)
    }

    // MARK: - Delete

    func delete(slug: String) async {
        let fileURL = directoryURL.appendingPathComponent("\(slug).md")
        try? FileManager.default.removeItem(at: fileURL)
        index.removeAll { $0.slug == slug }
    }

    // MARK: - Clear (used in tests and future settings UI)

    func clear() async {
        let mdFiles = (try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        ))?.filter { $0.pathExtension == "md" } ?? []
        for url in mdFiles { try? FileManager.default.removeItem(at: url) }
        index = []
    }

    // MARK: - Slug generation

    /// Converts a name to a URL-safe, lowercase, hyphen-separated slug (max 60 chars).
    static func generateSlug(from name: String) -> String {
        let raw = name.lowercased().unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? String($0) : "-" }
            .joined()
        let collapsed = raw.components(separatedBy: "-").filter { !$0.isEmpty }.joined(separator: "-")
        let trimmed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return String(trimmed.prefix(60))
    }

    // MARK: - Private helpers

    private func deduplicatedSlug(for base: String) -> String {
        let existing = Set(index.map(\.slug))
        guard existing.contains(base) else { return base }
        var counter = 2
        while existing.contains("\(base)-\(counter)") { counter += 1 }
        return "\(base)-\(counter)"
    }
}
```

- [ ] **Step 4: Run tests — expect pass**

Press **Cmd+U**. `SkillLibraryStoreTests` (10 tests) should all pass.

- [ ] **Step 5: Commit**

```bash
git add TipTour/Agents/Skills/SkillLibraryStore.swift TipTourTests/SkillLibraryTests.swift
git commit -m "feat: add SkillLibraryStore actor — write/query/fetchBody/delete/clear"
```

---

## Task 3: SaveSkillTool and RecallSkillTool

**Files:**
- Create: `TipTour/Agents/Tools/SkillTools.swift`
- Modify: `TipTourTests/SkillLibraryTests.swift` (append tool tests)

- [ ] **Step 1: Write failing tests**

Append to `TipTourTests/SkillLibraryTests.swift`:

```swift
// MARK: - SkillTools tests

@Suite("SkillTools")
struct SkillToolsTests {

    private func makeTempStore() -> SkillLibraryStore {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("tiptour-skilltool-test-\(UUID().uuidString)", isDirectory: true)
        return SkillLibraryStore(directoryURL: tmp)
    }

    @Test func saveSkillParametersJSONIsValidJSON() {
        let tool = SaveSkillTool(taskType: .coding, historyBuffer: ToolCallHistoryBuffer())
        guard let data = tool.parametersJSON.data(using: .utf8) else {
            Issue.record("parametersJSON is not UTF-8"); return
        }
        #expect((try? JSONSerialization.jsonObject(with: data)) != nil)
    }

    @Test func recallSkillParametersJSONIsValidJSON() {
        let tool = RecallSkillTool(taskType: .coding)
        guard let data = tool.parametersJSON.data(using: .utf8) else {
            Issue.record("parametersJSON is not UTF-8"); return
        }
        #expect((try? JSONSerialization.jsonObject(with: data)) != nil)
    }

    @Test func saveSkillWritesEntryToStore() async {
        let store = makeTempStore()
        let buffer = ToolCallHistoryBuffer()
        buffer.append(RecordedToolCall(toolName: "run_shell_command", argumentsJSON: #"{"command":"pnpm install"}"#, result: "Done."))
        let tool = SaveSkillTool(taskType: .coding, historyBuffer: buffer, store: store)
        let result = await tool.execute(argumentsJSON: #"{"name": "pnpm-install", "description": "Install pnpm deps"}"#)
        #expect(result == "Skill saved: pnpm-install")
        let found = await store.query(taskDescription: "pnpm install deps", taskTypes: [.coding])
        #expect(!found.isEmpty)
    }

    @Test func saveSkillWithEmptyHistoryStillSaves() async {
        let store = makeTempStore()
        let tool = SaveSkillTool(taskType: .coding, historyBuffer: ToolCallHistoryBuffer(), store: store)
        let result = await tool.execute(argumentsJSON: #"{"name": "no-tools-skill", "description": "No tool calls"}"#)
        #expect(result == "Skill saved: no-tools-skill")
    }

    @Test func saveSkillMissingNameReturnsError() async {
        let tool = SaveSkillTool(taskType: .coding, historyBuffer: ToolCallHistoryBuffer(), store: makeTempStore())
        let result = await tool.execute(argumentsJSON: #"{"description": "no name"}"#)
        #expect(result.contains("Error"))
    }

    @Test func saveSkillMalformedJSONReturnsError() async {
        let tool = SaveSkillTool(taskType: .coding, historyBuffer: ToolCallHistoryBuffer(), store: makeTempStore())
        let result = await tool.execute(argumentsJSON: "not json")
        #expect(result.contains("Error"))
    }

    @Test func recallSkillReturnsFullBodyForMatch() async {
        let store = makeTempStore()
        let writer = SaveSkillTool(taskType: .coding, historyBuffer: ToolCallHistoryBuffer(), store: store)
        _ = await writer.execute(argumentsJSON: #"{"name": "test-recall-skill", "description": "A test skill for recall"}"#)
        let reader = RecallSkillTool(taskType: .coding, store: store)
        let result = await reader.execute(argumentsJSON: #"{"query": "test recall skill"}"#)
        #expect(result.contains("# test-recall-skill"))
    }

    @Test func recallSkillReturnsNoMatchWhenEmpty() async {
        let store = makeTempStore()
        let tool = RecallSkillTool(taskType: .coding, store: store)
        let result = await tool.execute(argumentsJSON: #"{"query": "completely unrelated xyz987"}"#)
        #expect(result == "No matching skill found.")
    }

    @Test func recallSkillMissingQueryReturnsError() async {
        let tool = RecallSkillTool(taskType: .coding, store: makeTempStore())
        let result = await tool.execute(argumentsJSON: #"{}"#)
        #expect(result.contains("Error"))
    }
}
```

- [ ] **Step 2: Run tests — expect failure**

Press **Cmd+U**. `SkillToolsTests` should fail with "Cannot find type 'SaveSkillTool' in scope".

- [ ] **Step 3: Create `SkillTools.swift`**

Create `TipTour/Agents/Tools/SkillTools.swift`:

```swift
// TipTour/Agents/Tools/SkillTools.swift

import Foundation

// MARK: - Save Skill Tool

struct SaveSkillTool: AgentTool {

    let name = "save_skill"
    let description = """
        Save the current task's tool call sequence as a reusable skill in the shared library. \
        Use when you've found a reliable procedure worth reusing. \
        Future agents can find it with recall_skill.
        """
    let parametersJSON = """
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
        """

    private let taskType: TaskType
    private let historyBuffer: ToolCallHistoryBuffer
    private let store: SkillLibraryStore

    init(taskType: TaskType, historyBuffer: ToolCallHistoryBuffer, store: SkillLibraryStore = SkillLibraryStore.shared) {
        self.taskType = taskType
        self.historyBuffer = historyBuffer
        self.store = store
    }

    func execute(argumentsJSON: String) async -> String {
        guard let data = argumentsJSON.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let skillName = dict["name"] as? String, !skillName.isEmpty,
              let skillDescription = dict["description"] as? String, !skillDescription.isEmpty else {
            return "Error: \(ToolArgumentError.missingRequiredField("name or description").localizedDescription)"
        }
        let slug = SkillLibraryStore.generateSlug(from: skillName)
        let body = SkillBodyBuilder.build(
            name: skillName,
            toolCalls: historyBuffer.calls,
            resultSummary: skillDescription
        )
        await store.write(slug: slug, name: skillName, description: skillDescription, taskTypes: [taskType], body: body)
        return "Skill saved: \(skillName)"
    }
}

// MARK: - Recall Skill Tool

struct RecallSkillTool: AgentTool {

    let name = "recall_skill"
    let description = """
        Search the shared skill library for a procedure matching your goal. \
        Returns the full step-by-step skill document for the best match.
        """
    let parametersJSON = """
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
        """

    private let taskType: TaskType
    private let store: SkillLibraryStore

    init(taskType: TaskType, store: SkillLibraryStore = SkillLibraryStore.shared) {
        self.taskType = taskType
        self.store = store
    }

    func execute(argumentsJSON: String) async -> String {
        guard let data = argumentsJSON.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let query = dict["query"] as? String, !query.isEmpty else {
            return "Error: \(ToolArgumentError.missingRequiredField("query").localizedDescription)"
        }
        let results = await store.query(taskDescription: query, taskTypes: [taskType], limit: 1)
        guard let top = results.first else { return "No matching skill found." }
        return await store.fetchBody(slug: top.slug) ?? "No matching skill found."
    }
}
```

- [ ] **Step 4: Run tests — expect pass**

Press **Cmd+U**. `SkillToolsTests` (9 tests) should all pass.

- [ ] **Step 5: Commit**

```bash
git add TipTour/Agents/Tools/SkillTools.swift TipTourTests/SkillLibraryTests.swift
git commit -m "feat: add SaveSkillTool and RecallSkillTool"
```

---

## Task 4: Wire skill tools into ToolBox

**Files:**
- Modify: `TipTour/Agents/Tools/AgentTool.swift`
- Modify: `TipTourTests/SkillLibraryTests.swift` (append ToolBox test)

- [ ] **Step 1: Write failing test**

Append to `TipTourTests/SkillLibraryTests.swift`:

```swift
// MARK: - ToolBox skill tool integration

@Suite("ToolBoxSkillIntegration")
struct ToolBoxSkillIntegrationTests {

    @Test func allTaskTypesIncludeRecallSkillTool() {
        for taskType in TaskType.allCases {
            let toolBox = ToolBox.build(for: taskType)
            let names = toolBox.definitions.map(\.name)
            #expect(names.contains("recall_skill"), "Missing recall_skill for \(taskType.rawValue)")
        }
    }

    @Test func toolBoxWithHistoryBufferIncludesBothSkillTools() {
        for taskType in TaskType.allCases {
            let buffer = ToolCallHistoryBuffer()
            let toolBox = ToolBox.build(for: taskType, historyBuffer: buffer)
            let names = toolBox.definitions.map(\.name)
            #expect(names.contains("save_skill"), "Missing save_skill for \(taskType.rawValue)")
            #expect(names.contains("recall_skill"), "Missing recall_skill for \(taskType.rawValue)")
        }
    }
}
```

- [ ] **Step 2: Run test — expect failure**

Press **Cmd+U**. Both tests should fail: `ToolBox.build(for:)` doesn't include `recall_skill` yet, and `ToolBox.build(for:historyBuffer:)` doesn't exist.

- [ ] **Step 3: Refactor `ToolBox.build` in `AgentTool.swift`**

Replace the entire `build(for:)` method (currently lines 75–127) with the following three additions — a `domainTools` private helper, an updated `build(for:)` that includes `RecallSkillTool`, and a new `build(for:historyBuffer:)` overload:

```swift
// MARK: - Factory: builds the right tool set for each task type

static func build(for taskType: TaskType) -> ToolBox {
    let sharedTools: [any AgentTool] = [
        RememberFactTool(taskType: taskType),
        RecallFactsTool(taskType: taskType),
        RecallSkillTool(taskType: taskType)
    ]
    return ToolBox(tools: domainTools(for: taskType) + sharedTools)
}

/// Builds the full toolbox including SaveSkillTool wired to the given history buffer.
/// TaskAgent calls this overload so save_skill can snapshot the agent's live tool call history.
static func build(for taskType: TaskType, historyBuffer: ToolCallHistoryBuffer) -> ToolBox {
    let sharedTools: [any AgentTool] = [
        RememberFactTool(taskType: taskType),
        RecallFactsTool(taskType: taskType),
        SaveSkillTool(taskType: taskType, historyBuffer: historyBuffer),
        RecallSkillTool(taskType: taskType)
    ]
    return ToolBox(tools: domainTools(for: taskType) + sharedTools)
}

private static func domainTools(for taskType: TaskType) -> [any AgentTool] {
    switch taskType {
    case .coding:
        return [RunShellCommandTool(), ReadFileTool(), WriteFileTool(), ListDirectoryTool(), SpawnClaudeCodeTool()]
    case .browserResearch:
        return [WebFetchTool(), WebSearchTool()]
    case .fileManagement:
        return [ReadFileTool(), WriteFileTool(), ListDirectoryTool(), RunShellCommandTool()]
    case .generalMac:
        return [ReadAXTreeTool(), ClickElementTool(), RunShellCommandTool(), ReadFileTool(), WriteFileTool()]
    case .analysis:
        return [ReadFileTool(), ListDirectoryTool(), WebFetchTool()]
    case .writing:
        return [ReadFileTool(), WriteFileTool(), WebFetchTool()]
    case .imageGeneration, .videoGeneration:
        // Image/video tasks pass the prompt inline via CLI and receive a file path as output.
        // Shell is sufficient; file I/O is handled by the generation CLI itself.
        return [RunShellCommandTool()]
    }
}
```

- [ ] **Step 4: Run tests — expect pass**

Press **Cmd+U**. `ToolBoxSkillIntegrationTests` (2 tests) should pass. Also verify `ToolBoxMemoryIntegration` still passes — `allTaskTypesIncludeMemoryTools` should still find `remember_fact` and `recall_facts`.

- [ ] **Step 5: Commit**

```bash
git add TipTour/Agents/Tools/AgentTool.swift TipTourTests/SkillLibraryTests.swift
git commit -m "feat: add RecallSkillTool to ToolBox and build(for:historyBuffer:) overload with SaveSkillTool"
```

---

## Task 5: TaskAgent startup injection and auto-save on completion

**Files:**
- Modify: `TipTour/Agents/Swarm/TaskAgent.swift`
- Modify: `TipTour/Agents/Swarm/AgentSwarmManager.swift`
- Modify: `TipTourTests/SkillLibraryTests.swift` (append integration tests)
- Modify: `AGENTS.md` (line count + description for TaskAgent.swift)

- [ ] **Step 1: Write failing integration tests**

Append to `TipTourTests/SkillLibraryTests.swift`:

```swift
// MARK: - TaskAgent skill integration

// .serialized prevents concurrent tests from racing on SkillLibraryStore.shared.
@Suite("TaskAgentSkillIntegration", .serialized)
struct TaskAgentSkillIntegrationTests {

    @Test func agentWithToolCallsAutoSavesSkillOnCompletion() async {
        await SkillLibraryStore.shared.clear()

        let swarm = AgentSwarmManager()
        let mockProvider = MockLLMProvider(id: "skill-auto-save-test")
        var callCount = 0
        mockProvider.responseFactory = {
            callCount += 1
            if callCount == 1 {
                // First call: return a recall_facts tool call (harmless, always in toolbox)
                return .toolCalls([LLMToolCall(
                    id: "t1",
                    name: "recall_facts",
                    argumentsJSON: #"{"query": "pnpm"}"#
                )])
            }
            return .text("Task complete.")
        }

        let agent = TaskAgent(
            taskDescription: "install pnpm skill auto save test",
            taskType: .coding,
            provider: mockProvider,
            swarmManager: swarm
        )
        await agent.run()

        let results = await SkillLibraryStore.shared.query(
            taskDescription: "install pnpm skill auto save test",
            taskTypes: [.coding]
        )
        #expect(!results.isEmpty)
        #expect(results.first?.taskTypes.contains(.coding) == true)

        await SkillLibraryStore.shared.clear()
    }

    @Test func agentWithNoToolCallsSkipsAutoSave() async {
        await SkillLibraryStore.shared.clear()

        let swarm = AgentSwarmManager()
        let mockProvider = MockLLMProvider(id: "skill-no-tools-test")
        mockProvider.responseToReturn = .text("Done without tools.")

        let agent = TaskAgent(
            taskDescription: "no tools auto save skip test xyz987",
            taskType: .analysis,
            provider: mockProvider,
            swarmManager: swarm
        )
        await agent.run()

        let results = await SkillLibraryStore.shared.query(
            taskDescription: "no tools auto save skip test xyz987",
            taskTypes: [.analysis]
        )
        #expect(results.isEmpty)

        await SkillLibraryStore.shared.clear()
    }

    @Test func relevantSkillsInjectedIntoSystemMessage() async {
        await SkillLibraryStore.shared.clear()

        // Pre-load a skill relevant to the task
        let body = SkillBodyBuilder.build(name: "pnpm-install", toolCalls: [], resultSummary: "Run pnpm install.")
        await SkillLibraryStore.shared.write(
            slug: "pnpm-install",
            name: "pnpm install",
            description: "Install pnpm dependencies in this project",
            taskTypes: [.coding],
            body: body
        )

        let swarm = AgentSwarmManager()
        let mockProvider = MockLLMProvider(id: "skill-injection-test")
        mockProvider.responseToReturn = .text("Task complete.")

        let agent = TaskAgent(
            taskDescription: "install pnpm dependencies for the project",
            taskType: .coding,
            provider: mockProvider,
            swarmManager: swarm
        )
        await agent.run()

        let systemMessage = mockProvider.capturedMessages.first?.first
        #expect(systemMessage?.role == .system)
        #expect(systemMessage?.content.contains("--- Relevant skills ---") == true)
        #expect(systemMessage?.content.contains("pnpm-install") == true)

        await SkillLibraryStore.shared.clear()
    }
}
```

- [ ] **Step 2: Run tests — expect failure**

Press **Cmd+U**. `TaskAgentSkillIntegrationTests` should fail because `TaskAgent` doesn't yet record tool calls or auto-save skills.

- [ ] **Step 3: Update `TaskAgent.swift`**

Here is the complete updated file. Key changes from the current version:
1. Remove `toolBox: ToolBox = ToolBox()` parameter from `init` — toolbox is now built internally using `skillHistoryBuffer`
2. Add `private let skillHistoryBuffer: ToolCallHistoryBuffer` stored property
3. Update `dispatchToolCall` to append to `skillHistoryBuffer`
4. In `run()`: call `fetchSkillsBlock()` at startup, pass to `buildSystemPrompt`; call `autoSaveSkill` on text completion
5. Add private methods `fetchSkillsBlock()`, `autoSaveSkill(taskResult:)`, update `buildSystemPrompt(memoryBlock:skillsBlock:)`

```swift
// TipTour/Agents/Swarm/TaskAgent.swift

import Foundation

/// A single background agent. Owns its LLM conversation history and runs
/// an agentic loop: call LLM → execute tool → check interrupts → repeat.
actor TaskAgent: Identifiable {

    let id: UUID
    let taskDescription: String
    let taskType: TaskType
    let provider: (any LLMProvider)?
    let swarmManager: AgentSwarmManager
    let toolBox: ToolBox
    private let skillHistoryBuffer: ToolCallHistoryBuffer

    private var conversationHistory: [LLMMessage] = []
    private var interruptQueue: [String] = []
    private(set) var state: AgentState = .spawning
    private(set) var currentStep: String = "Preparing..."
    private(set) var stepHistory: [AgentStep] = []
    private(set) var tokensUsed: Int = 0
    private let startedAt: Date = Date()
    private var chatHistory: [AgentChatMessage] = []

    var currentStatus: AgentStatus {
        AgentStatus(
            id: id,
            agentName: taskType.displayName,
            taskSummary: taskDescription,
            state: state,
            currentStep: currentStep,
            stepHistory: stepHistory,
            tokensUsed: tokensUsed,
            elapsedSeconds: Date().timeIntervalSince(startedAt),
            blocker: state.currentBlocker,
            result: nil,
            isExpanded: false,
            isMinimised: false,
            chatHistory: chatHistory
        )
    }

    init(
        taskDescription: String,
        taskType: TaskType,
        provider: (any LLMProvider)?,
        swarmManager: AgentSwarmManager
    ) {
        self.id = UUID()
        self.taskDescription = taskDescription
        self.taskType = taskType
        self.provider = provider
        self.swarmManager = swarmManager
        let buffer = ToolCallHistoryBuffer()
        self.skillHistoryBuffer = buffer
        self.toolBox = ToolBox.build(for: taskType, historyBuffer: buffer)
    }

    // MARK: - Main execution loop

    func run() async {
        guard !Task.isCancelled else { return }
        state = .active

        let memoryBlock = await fetchMemoryBlock()
        let skillsBlock = await fetchSkillsBlock()
        conversationHistory = [
            LLMMessage(role: .system, content: buildSystemPrompt(memoryBlock: memoryBlock, skillsBlock: skillsBlock)),
            LLMMessage(role: .user, content: taskDescription)
        ]

        var loopCount = 0
        let maximumLoopCount = 50

        while !Task.isCancelled && loopCount < maximumLoopCount {
            loopCount += 1
            await checkAndApplyInterrupts()
            state = .busy

            guard let activeProvider = provider else {
                await handleNoProvider()
                return
            }

            do {
                let response = try await activeProvider.complete(
                    messages: conversationHistory,
                    tools: availableToolDefinitions()
                )

                switch response {
                case .text(let text):
                    await recordStep(text, succeeded: true)
                    state = .completed
                    await writeTaskResultToMemory(summary: text)
                    await autoSaveSkill(taskResult: text)
                    await notifyMainAgentOfCompletion(summary: text)
                    return

                case .toolCalls(let calls):
                    conversationHistory.append(LLMMessage(role: .assistant, content: "[tool calls]"))
                    for toolCall in calls {
                        await recordStep("Calling tool: \(toolCall.name)", succeeded: true)
                        let toolResult = await dispatchToolCall(toolCall)
                        conversationHistory.append(LLMMessage(
                            role: .tool,
                            content: toolResult,
                            toolCallId: toolCall.id,
                            toolName: toolCall.name
                        ))
                    }

                case .textAndToolCalls(let text, let calls):
                    if !text.isEmpty {
                        conversationHistory.append(LLMMessage(role: .assistant, content: text))
                        await recordStep(text, succeeded: true)
                    }
                    for toolCall in calls {
                        await recordStep("Calling tool: \(toolCall.name)", succeeded: true)
                        let toolResult = await dispatchToolCall(toolCall)
                        conversationHistory.append(LLMMessage(
                            role: .tool,
                            content: toolResult,
                            toolCallId: toolCall.id,
                            toolName: toolCall.name
                        ))
                    }
                }

            } catch {
                await handleError(error)
                return
            }
        }

        if loopCount >= maximumLoopCount {
            await handleError(AgentError.maximumLoopCountExceeded)
        }
    }

    // MARK: - Receiving messages from SwarmManager

    func receive(_ message: AgentMessage) {
        switch message.type {
        case .interrupt(let instruction):
            interruptQueue.append(instruction)
        case .blockerResolved(let response):
            interruptQueue.append("[Blocker resolved]: \(response)")
            if case .blocked = state { state = .active }
        case .chatMessage(let text):
            chatHistory.append(AgentChatMessage(sender: .user, text: text, timestamp: Date()))
            interruptQueue.append("[User message]: \(text)")
        default:
            break
        }
    }

    func markTerminated() {
        state = .terminated
    }

    // MARK: - Private helpers

    private func checkAndApplyInterrupts() async {
        guard !interruptQueue.isEmpty else { return }
        let pendingInstructions = interruptQueue
        interruptQueue.removeAll()
        for instruction in pendingInstructions {
            conversationHistory.append(LLMMessage(role: .user, content: instruction))
        }
        await notifyProgressUpdate("Updating plan based on new instructions...")
    }

    private func recordStep(_ description: String, succeeded: Bool) async {
        currentStep = description
        stepHistory.append(AgentStep(description: description, completedAt: Date(), succeeded: succeeded))
        await notifyProgressUpdate(description)
    }

    private func notifyProgressUpdate(_ stepDescription: String) async {
        await swarmManager.send(AgentMessage(
            from: .task(id),
            to: .main,
            type: .progressUpdate(stepDescription: stepDescription, progressFraction: nil)
        ))
    }

    private func notifyMainAgentOfCompletion(summary: String) async {
        await swarmManager.send(AgentMessage(
            from: .task(id),
            to: .main,
            type: .taskComplete(result: .success(summary: summary, detailJSON: nil))
        ))
    }

    private func handleNoProvider() async {
        let reason = "No LLM provider configured for task type '\(taskType.displayName)'. Add an API key in Settings → Agents."
        await writeTaskResultToMemory(summary: "Failed: \(reason)")
        state = .error(message: reason)
        await swarmManager.send(AgentMessage(from: .task(id), to: .main, type: .taskFailed(reason: reason)))
    }

    private func handleError(_ error: Error) async {
        let reason = error.localizedDescription
        await recordStep("Error: \(reason)", succeeded: false)
        await writeTaskResultToMemory(summary: "Failed: \(reason)")
        state = .error(message: reason)
        await swarmManager.send(AgentMessage(from: .task(id), to: .main, type: .taskFailed(reason: reason)))
    }

    private func availableToolDefinitions() -> [LLMTool] {
        toolBox.definitions
    }

    private func dispatchToolCall(_ toolCall: LLMToolCall) async -> String {
        let result = await toolBox.execute(toolCall: toolCall)
        skillHistoryBuffer.append(RecordedToolCall(
            toolName: toolCall.name,
            argumentsJSON: toolCall.argumentsJSON,
            result: result
        ))
        return result
    }

    /// Queries the shared memory store for entries relevant to this task,
    /// returning a formatted block to prepend to the system prompt.
    /// Returns an empty string when no relevant memories exist.
    private func fetchMemoryBlock() async -> String {
        let memories = await AgentMemoryStore.shared.query(
            taskDescription: taskDescription,
            taskTypes: [taskType]
        )
        guard !memories.isEmpty else { return "" }
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let lines = memories.enumerated().map { index, entry in
            let typeLabel = entry.entryType == .fact ? "fact" : "task result"
            let expiryLabel: String
            if let expiresAt = entry.expiresAt {
                expiryLabel = "expires \(dateFormatter.string(from: expiresAt))"
            } else {
                expiryLabel = "permanent"
            }
            return "\(index + 1). \(entry.content) (\(typeLabel), \(expiryLabel))"
        }.joined(separator: "\n")
        return "--- Relevant memory ---\n\(lines)\n---"
    }

    /// Queries the skill library for procedures relevant to this task,
    /// returning a block listing matching skill names + descriptions.
    /// Returns an empty string when no relevant skills exist.
    private func fetchSkillsBlock() async -> String {
        let skills = await SkillLibraryStore.shared.query(
            taskDescription: taskDescription,
            taskTypes: [taskType]
        )
        guard !skills.isEmpty else { return "" }
        let lines = skills.enumerated().map { index, entry in
            "\(index + 1). \(entry.slug): \(entry.description)"
        }.joined(separator: "\n")
        return "--- Relevant skills ---\n\(lines)\n---"
    }

    /// Writes a task-result entry to the shared memory store summarising what this agent did.
    /// Called on completion (success or error). Skipped only for terminated agents.
    private func writeTaskResultToMemory(summary: String) async {
        let content = "\(taskType.displayName): \(taskDescription). \(String(summary.prefix(300)))"
        await AgentMemoryStore.shared.write(
            content: content,
            entryType: .taskResult,
            taskTypes: [taskType],
            permanent: false
        )
    }

    /// Auto-saves a skill when the agent made tool calls and completed successfully.
    /// Skipped when history is empty (agent answered directly without tools — not useful as a skill).
    private func autoSaveSkill(taskResult: String) async {
        let toolCalls = skillHistoryBuffer.calls
        guard !toolCalls.isEmpty else { return }
        let slug = SkillLibraryStore.generateSlug(from: taskDescription)
        let body = SkillBodyBuilder.build(
            name: taskDescription,
            toolCalls: toolCalls,
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

    private func buildSystemPrompt(memoryBlock: String, skillsBlock: String) -> String {
        var extras = ""
        if !memoryBlock.isEmpty { extras += "\n\(memoryBlock)" }
        if !skillsBlock.isEmpty { extras += "\n\(skillsBlock)" }
        return """
        You are a background task agent running inside TipTour, a macOS AI assistant.
        Your task type: \(taskType.displayName)
        You have access to tools to accomplish tasks on the user's Mac.
        When you have completed the task, respond with a clear text summary of what you did and what you found.
        If you cannot complete the task, explain why clearly.
        Be concise and direct. Do not ask clarifying questions — make reasonable assumptions and proceed.\(extras)
        """
    }
}

// MARK: - AgentState helper

extension AgentState {
    var currentBlocker: AgentBlocker? {
        if case .blocked(let blocker) = self { return blocker }
        return nil
    }
}

// MARK: - Internal errors

private enum AgentError: Error, LocalizedError {
    case maximumLoopCountExceeded

    var errorDescription: String? {
        "Agent exceeded the maximum number of reasoning steps (50). This likely indicates a loop or an unsolvable task."
    }
}
```

- [ ] **Step 4: Update `AgentSwarmManager.swift`**

In `AgentSwarmManager.swift`, the `spawn` method currently creates a `ToolBox` and passes it to `TaskAgent`. Since `TaskAgent` now builds its own toolbox internally, remove those two lines.

Replace lines 33–40 in `spawn`:

```swift
// BEFORE:
let toolBox = ToolBox.build(for: taskType)
let newAgent = TaskAgent(
    taskDescription: taskDescription,
    taskType: taskType,
    provider: provider,
    swarmManager: self,
    toolBox: toolBox
)

// AFTER:
let newAgent = TaskAgent(
    taskDescription: taskDescription,
    taskType: taskType,
    provider: provider,
    swarmManager: self
)
```

- [ ] **Step 5: Run tests — expect pass**

Press **Cmd+U**. `TaskAgentSkillIntegrationTests` (3 tests) should pass. Also verify `AgentSwarmTests`, `AgentMemoryTests`, `AgentToolTests`, and `AgentOverlayTests` all still pass — no regressions.

- [ ] **Step 6: Update `AGENTS.md` key files table**

In `AGENTS.md`, add these rows after the `MacControlTools.swift` row (after `MemoryTools.swift`):

```
| `TipTour/Agents/Skills/SkillEntry.swift` | ~110 | `RecordedToolCall`, `ToolCallHistoryBuffer`, `SkillEntry` (frontmatter parser + writer), `SkillBodyBuilder`. |
| `TipTour/Agents/Skills/SkillLibraryStore.swift` | ~120 | Actor singleton. Persists skills as `.md` files at `~/Library/Application Support/TipTour/skills/`. Write/query/fetchBody/delete/clear with task-type + keyword scoring. |
| `TipTour/Agents/Tools/SkillTools.swift` | ~105 | `SaveSkillTool` (save_skill) and `RecallSkillTool` (recall_skill). Available in all task types via ToolBox. |
```

Also update the `TaskAgent.swift` row (currently ~285 lines) — it will grow to ~320 lines:

```
| `TipTour/Agents/Swarm/TaskAgent.swift` | ~320 | Individual background agent. Runs agentic LLM loop; injects relevant memory and skills at startup; writes task result to memory and auto-saves skill on completion. |
```

- [ ] **Step 7: Commit**

```bash
git add TipTour/Agents/Swarm/TaskAgent.swift TipTour/Agents/Swarm/AgentSwarmManager.swift TipTourTests/SkillLibraryTests.swift AGENTS.md
git commit -m "feat: wire SkillLibrary into TaskAgent — inject skills at startup, auto-save on completion"
```
