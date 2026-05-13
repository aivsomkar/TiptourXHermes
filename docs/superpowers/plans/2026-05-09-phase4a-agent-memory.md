# AgentMemory Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give TipTour's background agents a persistent, shared memory store so facts discovered in one task are available to future agents without re-discovery.

**Architecture:** A Swift actor singleton (`AgentMemoryStore`) owns a JSON file at `~/Library/Application Support/TipTour/agent-memory.json`. Two new tools (`remember_fact`, `recall_facts`) let agents explicitly read/write memory mid-task. `TaskAgent` automatically queries memory at startup (injecting matches into the system prompt) and writes a task-result entry at completion.

**Tech Stack:** Swift actors, `Codable` / `JSONEncoder` / `JSONDecoder`, Swift Testing (`import Testing`)

---

## File Structure

| Action | Path | Responsibility |
|--------|------|----------------|
| Create | `TipTour/Agents/Memory/AgentMemoryEntry.swift` | `MemoryEntryType` enum, `AgentMemoryEntry` struct, keyword extractor |
| Create | `TipTour/Agents/Memory/AgentMemoryStore.swift` | Actor singleton — load/save/write/query/prune/clear |
| Create | `TipTour/Agents/Tools/MemoryTools.swift` | `RememberFactTool`, `RecallFactsTool` |
| Modify | `TipTour/Agents/Tools/AgentTool.swift` | Add memory tools to every `ToolBox.build(for:)` case |
| Modify | `TipTour/Agents/Swarm/TaskAgent.swift` | Query memory at startup, write task result at completion/error |
| Create | `TipTourTests/AgentMemoryTests.swift` | All tests for this feature |

---

## Task 1: AgentMemoryEntry types and keyword extractor

**Files:**
- Create: `TipTour/Agents/Memory/AgentMemoryEntry.swift`
- Create: `TipTourTests/AgentMemoryTests.swift`

- [ ] **Step 1: Write failing tests for keyword extraction and TTL helpers**

Add `TipTourTests/AgentMemoryTests.swift`:

```swift
// TipTourTests/AgentMemoryTests.swift

import Foundation
import Testing
@testable import TipTour

// MARK: - AgentMemoryEntry tests

@Suite("AgentMemoryEntry")
struct AgentMemoryEntryTests {

    @Test func extractKeywordsFiltersStopWordsAndShortTokens() {
        let keywords = AgentMemoryEntry.extractKeywords(from: "The project uses pnpm not npm")
        #expect(keywords.contains("project"))
        #expect(keywords.contains("pnpm"))
        #expect(keywords.contains("npm"))
        #expect(!keywords.contains("the"))
        #expect(!keywords.contains("not"))
    }

    @Test func extractKeywordsLowercases() {
        let keywords = AgentMemoryEntry.extractKeywords(from: "Homebrew is at /opt/Homebrew")
        #expect(keywords.contains("homebrew"))
        #expect(!keywords.contains("Homebrew"))
    }

    @Test func extractKeywordsDeduplicates() {
        let keywords = AgentMemoryEntry.extractKeywords(from: "xcode xcode xcode")
        #expect(keywords.filter { $0 == "xcode" }.count == 1)
    }

    @Test func makeFactNonPermanentHas30DayExpiry() {
        let entry = AgentMemoryEntry.makeFact(content: "test fact", taskTypes: [.coding], permanent: false)
        #expect(entry.entryType == .fact)
        #expect(entry.isPermanent == false)
        let expectedExpiry = Date.now.addingTimeInterval(30 * 24 * 3600)
        #expect(abs(entry.expiresAt!.timeIntervalSince(expectedExpiry)) < 5)
    }

    @Test func makeFactPermanentHasNilExpiry() {
        let entry = AgentMemoryEntry.makeFact(content: "permanent fact", taskTypes: [.coding], permanent: true)
        #expect(entry.isPermanent == true)
        #expect(entry.expiresAt == nil)
    }

    @Test func makeTaskResultHas7DayExpiry() {
        let entry = AgentMemoryEntry.makeTaskResult(content: "did some work", taskTypes: [.analysis])
        #expect(entry.entryType == .taskResult)
        #expect(entry.isPermanent == false)
        let expectedExpiry = Date.now.addingTimeInterval(7 * 24 * 3600)
        #expect(abs(entry.expiresAt!.timeIntervalSince(expectedExpiry)) < 5)
    }

    @Test func isExpiredReturnsTrueForPastExpiry() {
        let entry = AgentMemoryEntry(
            id: UUID(),
            content: "old fact",
            entryType: .fact,
            taskTypes: [.coding],
            keywords: [],
            createdAt: Date.now.addingTimeInterval(-100),
            expiresAt: Date.now.addingTimeInterval(-1)
        )
        #expect(entry.isExpired == true)
    }

    @Test func isExpiredReturnsFalseForPermanent() {
        let entry = AgentMemoryEntry.makeFact(content: "permanent", taskTypes: [.coding], permanent: true)
        #expect(entry.isExpired == false)
    }

    @Test func codableRoundTrip() throws {
        let original = AgentMemoryEntry.makeFact(content: "test content", taskTypes: [.coding, .analysis], permanent: false)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AgentMemoryEntry.self, from: data)
        #expect(decoded.id == original.id)
        #expect(decoded.content == original.content)
        #expect(decoded.taskTypes == original.taskTypes)
        #expect(decoded.isPermanent == original.isPermanent)
    }
}
```

- [ ] **Step 2: Run tests to confirm they fail**

Open `TipTourTests/AgentMemoryTests.swift` in Xcode. Press **Cmd+U**. The `AgentMemoryEntryTests` suite should fail with "Cannot find type 'AgentMemoryEntry' in scope". If Xcode shows a build error instead of a test failure, that is also expected — proceed.

- [ ] **Step 3: Create `AgentMemoryEntry.swift`**

```swift
// TipTour/Agents/Memory/AgentMemoryEntry.swift

import Foundation

enum MemoryEntryType: String, Codable, Sendable {
    case fact
    case taskResult
}

struct AgentMemoryEntry: Codable, Identifiable, Sendable {
    let id: UUID
    let content: String
    let entryType: MemoryEntryType
    let taskTypes: [TaskType]
    let keywords: [String]
    let createdAt: Date
    /// Nil means permanent — never pruned.
    let expiresAt: Date?

    var isPermanent: Bool { expiresAt == nil }
    var isExpired: Bool {
        guard let expiresAt else { return false }
        return expiresAt < Date.now
    }

    static func makeFact(content: String, taskTypes: [TaskType], permanent: Bool) -> AgentMemoryEntry {
        AgentMemoryEntry(
            id: UUID(),
            content: content,
            entryType: .fact,
            taskTypes: taskTypes,
            keywords: AgentMemoryEntry.extractKeywords(from: content),
            createdAt: Date.now,
            expiresAt: permanent ? nil : Date.now.addingTimeInterval(30 * 24 * 3600)
        )
    }

    static func makeTaskResult(content: String, taskTypes: [TaskType]) -> AgentMemoryEntry {
        AgentMemoryEntry(
            id: UUID(),
            content: content,
            entryType: .taskResult,
            taskTypes: taskTypes,
            keywords: AgentMemoryEntry.extractKeywords(from: content),
            createdAt: Date.now,
            expiresAt: Date.now.addingTimeInterval(7 * 24 * 3600)
        )
    }
}

// MARK: - Keyword extraction

extension AgentMemoryEntry {
    static func extractKeywords(from text: String) -> [String] {
        let stopWords: Set<String> = [
            "the", "a", "an", "is", "are", "was", "were", "be", "been", "being",
            "have", "has", "had", "do", "does", "did", "will", "would", "could",
            "should", "may", "might", "shall", "can", "need", "dare", "ought",
            "used", "to", "of", "in", "on", "at", "by", "for", "with", "about",
            "as", "into", "through", "during", "before", "after", "above", "below",
            "from", "up", "down", "out", "off", "over", "under", "again", "then",
            "once", "and", "but", "or", "nor", "so", "yet", "both", "not",
            "this", "that", "it", "its"
        ]
        let separators = CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: ".,!?;:()\"'"))
        let tokens = text.lowercased()
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 3 && !stopWords.contains($0) }
        return Array(Set(tokens)).sorted()
    }
}
```

- [ ] **Step 4: Run tests — expect pass**

Press **Cmd+U**. `AgentMemoryEntryTests` (8 tests) should all pass.

- [ ] **Step 5: Commit**

```bash
git add TipTour/Agents/Memory/AgentMemoryEntry.swift TipTourTests/AgentMemoryTests.swift
git commit -m "feat: add AgentMemoryEntry types and keyword extractor"
```

---

## Task 2: AgentMemoryStore actor

**Files:**
- Create: `TipTour/Agents/Memory/AgentMemoryStore.swift`
- Modify: `TipTourTests/AgentMemoryTests.swift` (add store tests)

- [ ] **Step 1: Write failing tests for the store**

Append to `TipTourTests/AgentMemoryTests.swift` after the `AgentMemoryEntryTests` closing brace:

```swift
// MARK: - AgentMemoryStore tests

@Suite("AgentMemoryStore")
struct AgentMemoryStoreTests {

    private func makeTempStore() -> AgentMemoryStore {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("tiptour-memory-test-\(UUID().uuidString).json")
        return AgentMemoryStore(fileURL: tmp)
    }

    @Test func writeAndQueryByTaskType() async {
        let store = makeTempStore()
        await store.write(content: "pnpm is the package manager", entryType: .fact, taskTypes: [.coding], permanent: false)
        let results = await store.query(taskDescription: "install packages", taskTypes: [.coding])
        #expect(!results.isEmpty)
        #expect(results.first?.content == "pnpm is the package manager")
    }

    @Test func queryByKeywordOverlap() async {
        let store = makeTempStore()
        await store.write(content: "homebrew is installed at /opt/homebrew", entryType: .fact, taskTypes: [.generalMac], permanent: false)
        // query with a different task type but matching keyword
        let results = await store.query(taskDescription: "find homebrew path", taskTypes: [.coding])
        #expect(!results.isEmpty)
    }

    @Test func queryReturnsEmptyWhenNoMatch() async {
        let store = makeTempStore()
        await store.write(content: "xcode project lives at ~/Desktop/TipTour", entryType: .fact, taskTypes: [.coding], permanent: false)
        let results = await store.query(taskDescription: "unrelated search about bananas", taskTypes: [.writing])
        #expect(results.isEmpty)
    }

    @Test func queryRespectsLimit() async {
        let store = makeTempStore()
        for i in 0..<25 {
            await store.write(content: "coding fact number \(i)", entryType: .fact, taskTypes: [.coding], permanent: false)
        }
        let results = await store.query(taskDescription: "coding fact", taskTypes: [.coding], limit: 5)
        #expect(results.count <= 5)
    }

    @Test func pruneExpiredRemovesStaleEntries() async {
        let store = makeTempStore()
        // Write an entry that is already expired
        let expiredEntry = AgentMemoryEntry(
            id: UUID(),
            content: "this entry is expired",
            entryType: .fact,
            taskTypes: [.coding],
            keywords: ["expired", "entry"],
            createdAt: Date.now.addingTimeInterval(-100),
            expiresAt: Date.now.addingTimeInterval(-1)
        )
        // Access the entries array via a write to trigger sync — use a helper
        await store.writeRawEntry(expiredEntry)
        await store.pruneExpired()
        let results = await store.query(taskDescription: "expired entry", taskTypes: [.coding])
        #expect(results.isEmpty)
    }

    @Test func permanentEntriesSurvivePrune() async {
        let store = makeTempStore()
        await store.write(content: "permanent tool path /usr/local/bin", entryType: .fact, taskTypes: [.coding], permanent: true)
        await store.pruneExpired()
        let results = await store.query(taskDescription: "tool path", taskTypes: [.coding])
        #expect(!results.isEmpty)
    }

    @Test func clearKeepPermanentRemovesNonPermanentOnly() async {
        let store = makeTempStore()
        await store.write(content: "non-permanent fact", entryType: .fact, taskTypes: [.coding], permanent: false)
        await store.write(content: "permanent fact stays", entryType: .fact, taskTypes: [.coding], permanent: true)
        await store.clear(keepPermanent: true)
        let results = await store.query(taskDescription: "permanent fact", taskTypes: [.coding])
        #expect(results.count == 1)
        #expect(results.first?.content == "permanent fact stays")
    }

    @Test func clearKeepPermanentFalseWipesEverything() async {
        let store = makeTempStore()
        await store.write(content: "permanent fact", entryType: .fact, taskTypes: [.coding], permanent: true)
        await store.clear(keepPermanent: false)
        let results = await store.query(taskDescription: "permanent fact", taskTypes: [.coding])
        #expect(results.isEmpty)
    }

    @Test func permanentFactScoresHigherThanNonPermanent() async {
        let store = makeTempStore()
        await store.write(content: "homebrew path non-permanent", entryType: .fact, taskTypes: [.coding], permanent: false)
        await store.write(content: "homebrew path permanent", entryType: .fact, taskTypes: [.coding], permanent: true)
        let results = await store.query(taskDescription: "homebrew path", taskTypes: [.coding])
        #expect(results.first?.isPermanent == true)
    }
}
```

- [ ] **Step 2: Run tests — expect failure**

Press **Cmd+U**. The `AgentMemoryStoreTests` suite should fail with "Cannot find type 'AgentMemoryStore' in scope".

- [ ] **Step 3: Create `AgentMemoryStore.swift`**

```swift
// TipTour/Agents/Memory/AgentMemoryStore.swift

import Foundation

actor AgentMemoryStore {

    static let shared = AgentMemoryStore()

    private var entries: [AgentMemoryEntry] = []
    private let fileURL: URL

    static var defaultFileURL: URL {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let tipTourDir = appSupport.appendingPathComponent("TipTour", isDirectory: true)
        try? FileManager.default.createDirectory(at: tipTourDir, withIntermediateDirectories: true)
        return tipTourDir.appendingPathComponent("agent-memory.json")
    }

    init(fileURL: URL = AgentMemoryStore.defaultFileURL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let loaded = try? JSONDecoder().decode([AgentMemoryEntry].self, from: data) {
            self.entries = loaded
        }
        // Prune expired entries at load time without an async hop.
        let now = Date.now
        self.entries = self.entries.filter { entry in
            guard let expiresAt = entry.expiresAt else { return true }
            return expiresAt >= now
        }
    }

    // MARK: - Write

    func write(
        content: String,
        entryType: MemoryEntryType,
        taskTypes: [TaskType],
        permanent: Bool = false
    ) async {
        let entry: AgentMemoryEntry
        switch entryType {
        case .fact:
            entry = AgentMemoryEntry.makeFact(content: content, taskTypes: taskTypes, permanent: permanent)
        case .taskResult:
            entry = AgentMemoryEntry.makeTaskResult(content: content, taskTypes: taskTypes)
        }
        entries.append(entry)
        pruneExpiredSync()
        saveToDisk()
    }

    /// Used in tests to inject entries with custom expiry dates.
    func writeRawEntry(_ entry: AgentMemoryEntry) async {
        entries.append(entry)
        saveToDisk()
    }

    // MARK: - Query

    func query(taskDescription: String, taskTypes: [TaskType], limit: Int = 20) async -> [AgentMemoryEntry] {
        let taskDescriptionKeywords = Set(AgentMemoryEntry.extractKeywords(from: taskDescription))
        let targetTaskTypes = Set(taskTypes)

        let scored: [(entry: AgentMemoryEntry, score: Int)] = entries.compactMap { entry in
            guard !entry.isExpired else { return nil }
            var score = 0
            if !Set(entry.taskTypes).isDisjoint(with: targetTaskTypes) {
                score += 2
            }
            score += Set(entry.keywords).intersection(taskDescriptionKeywords).count
            if entry.isPermanent { score += 1 }
            guard score > 0 else { return nil }
            return (entry, score)
        }

        return scored
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map(\.entry)
    }

    // MARK: - Prune

    func pruneExpired() async {
        pruneExpiredSync()
        saveToDisk()
    }

    // MARK: - Clear

    func clear(keepPermanent: Bool = true) async {
        if keepPermanent {
            entries = entries.filter(\.isPermanent)
        } else {
            entries = []
        }
        saveToDisk()
    }

    // MARK: - Private helpers

    private func pruneExpiredSync() {
        let now = Date.now
        entries = entries.filter { entry in
            guard let expiresAt = entry.expiresAt else { return true }
            return expiresAt >= now
        }
    }

    private func saveToDisk() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
```

- [ ] **Step 4: Run tests — expect pass**

Press **Cmd+U**. `AgentMemoryStoreTests` (9 tests) should all pass.

- [ ] **Step 5: Commit**

```bash
git add TipTour/Agents/Memory/AgentMemoryStore.swift TipTourTests/AgentMemoryTests.swift
git commit -m "feat: add AgentMemoryStore actor — write/query/prune/clear"
```

---

## Task 3: RememberFactTool and RecallFactsTool

**Files:**
- Create: `TipTour/Agents/Tools/MemoryTools.swift`
- Modify: `TipTourTests/AgentMemoryTests.swift` (add tool tests)

- [ ] **Step 1: Write failing tests for memory tools**

Append to `TipTourTests/AgentMemoryTests.swift`:

```swift
// MARK: - MemoryTools tests

@Suite("MemoryTools")
struct MemoryToolsTests {

    private func makeTempStore() -> AgentMemoryStore {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("tiptour-tools-test-\(UUID().uuidString).json")
        return AgentMemoryStore(fileURL: tmp)
    }

    @Test func rememberFactParametersJSONIsValidJSON() {
        let tool = RememberFactTool(taskType: .coding)
        guard let data = tool.parametersJSON.data(using: .utf8) else {
            Issue.record("parametersJSON is not UTF-8")
            return
        }
        #expect((try? JSONSerialization.jsonObject(with: data)) != nil)
    }

    @Test func recallFactsParametersJSONIsValidJSON() {
        let tool = RecallFactsTool(taskType: .coding)
        guard let data = tool.parametersJSON.data(using: .utf8) else {
            Issue.record("parametersJSON is not UTF-8")
            return
        }
        #expect((try? JSONSerialization.jsonObject(with: data)) != nil)
    }

    @Test func rememberFactReturnsConfirmationString() async {
        let store = makeTempStore()
        let tool = RememberFactTool(taskType: .coding, store: store)
        let result = await tool.execute(argumentsJSON: #"{"content": "pnpm is the package manager"}"#)
        #expect(result == "Remembered: pnpm is the package manager")
    }

    @Test func rememberFactPermanentFlagPersistsEntry() async {
        let store = makeTempStore()
        let tool = RememberFactTool(taskType: .coding, store: store)
        _ = await tool.execute(argumentsJSON: #"{"content": "permanent tool", "permanent": true}"#)
        let results = await store.query(taskDescription: "permanent tool", taskTypes: [.coding])
        #expect(results.first?.isPermanent == true)
    }

    @Test func rememberFactMissingContentReturnsError() async {
        let tool = RememberFactTool(taskType: .coding)
        let result = await tool.execute(argumentsJSON: #"{}"#)
        #expect(result.contains("Error"))
    }

    @Test func rememberFactMalformedJSONReturnsError() async {
        let tool = RememberFactTool(taskType: .coding)
        let result = await tool.execute(argumentsJSON: "not json")
        #expect(result.contains("Error"))
    }

    @Test func recallFactsReturnsFormattedList() async {
        let store = makeTempStore()
        let writer = RememberFactTool(taskType: .coding, store: store)
        _ = await writer.execute(argumentsJSON: #"{"content": "homebrew at /opt/homebrew"}"#)

        let reader = RecallFactsTool(taskType: .coding, store: store)
        let result = await reader.execute(argumentsJSON: #"{"query": "homebrew path"}"#)
        #expect(result.contains("homebrew at /opt/homebrew"))
        #expect(result.contains("1."))
    }

    @Test func recallFactsReturnsNoMatchMessageWhenEmpty() async {
        let store = makeTempStore()
        let tool = RecallFactsTool(taskType: .coding, store: store)
        let result = await tool.execute(argumentsJSON: #"{"query": "completely unrelated zyx987"}"#)
        #expect(result == "No matching memories found.")
    }

    @Test func recallFactsMissingQueryReturnsError() async {
        let tool = RecallFactsTool(taskType: .coding)
        let result = await tool.execute(argumentsJSON: #"{}"#)
        #expect(result.contains("Error"))
    }
}
```

- [ ] **Step 2: Run tests — expect failure**

Press **Cmd+U**. The `MemoryToolsTests` suite should fail with "Cannot find type 'RememberFactTool' in scope".

- [ ] **Step 3: Create `MemoryTools.swift`**

```swift
// TipTour/Agents/Tools/MemoryTools.swift

import Foundation

// MARK: - Remember Fact Tool

struct RememberFactTool: AgentTool {

    let name = "remember_fact"
    let description = """
        Save a fact to shared agent memory so future agents can use it. \
        Use for durable environment facts: tool paths, project conventions, API base URLs. \
        Pass permanent: true for facts that will not change.
        """
    let parametersJSON = """
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
        """

    private let taskType: TaskType
    private let store: AgentMemoryStore

    init(taskType: TaskType, store: AgentMemoryStore = AgentMemoryStore.shared) {
        self.taskType = taskType
        self.store = store
    }

    func execute(argumentsJSON: String) async -> String {
        guard let data = argumentsJSON.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = dict["content"] as? String, !content.isEmpty else {
            return "Error: \(ToolArgumentError.missingRequiredField("content").localizedDescription)"
        }
        let permanent = dict["permanent"] as? Bool ?? false
        await store.write(content: content, entryType: .fact, taskTypes: [taskType], permanent: permanent)
        return "Remembered: \(content)"
    }
}

// MARK: - Recall Facts Tool

struct RecallFactsTool: AgentTool {

    let name = "recall_facts"
    let description = """
        Search shared agent memory for relevant facts from previous tasks. \
        Use mid-task to check what other agents have already learned. \
        Returns up to 20 matches ordered by relevance.
        """
    let parametersJSON = """
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
        """

    private let taskType: TaskType
    private let store: AgentMemoryStore

    init(taskType: TaskType, store: AgentMemoryStore = AgentMemoryStore.shared) {
        self.taskType = taskType
        self.store = store
    }

    func execute(argumentsJSON: String) async -> String {
        guard let data = argumentsJSON.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let query = dict["query"] as? String, !query.isEmpty else {
            return "Error: \(ToolArgumentError.missingRequiredField("query").localizedDescription)"
        }
        let results = await store.query(taskDescription: query, taskTypes: [taskType])
        guard !results.isEmpty else { return "No matching memories found." }
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        return results.enumerated().map { index, entry in
            let typeLabel = entry.entryType == .fact ? "fact" : "task result"
            let expiryLabel: String
            if let expiresAt = entry.expiresAt {
                expiryLabel = "expires \(dateFormatter.string(from: expiresAt))"
            } else {
                expiryLabel = "permanent"
            }
            return "\(index + 1). \(entry.content) (\(typeLabel), \(expiryLabel))"
        }.joined(separator: "\n")
    }
}
```

- [ ] **Step 4: Run tests — expect pass**

Press **Cmd+U**. `MemoryToolsTests` (9 tests) should all pass.

- [ ] **Step 5: Commit**

```bash
git add TipTour/Agents/Tools/MemoryTools.swift TipTourTests/AgentMemoryTests.swift
git commit -m "feat: add RememberFactTool and RecallFactsTool"
```

---

## Task 4: Wire memory tools into ToolBox

**Files:**
- Modify: `TipTour/Agents/Tools/AgentTool.swift`
- Modify: `TipTourTests/AgentMemoryTests.swift` (add ToolBox test)

- [ ] **Step 1: Write failing test**

Append to `TipTourTests/AgentMemoryTests.swift`:

```swift
// MARK: - ToolBox memory tool integration

@Suite("ToolBoxMemoryIntegration")
struct ToolBoxMemoryIntegrationTests {

    @Test func allTaskTypesIncludeRememberFactTool() {
        for taskType in TaskType.allCases {
            let toolBox = ToolBox.build(for: taskType)
            let names = toolBox.definitions.map(\.name)
            #expect(names.contains("remember_fact"), "Missing remember_fact for \(taskType.rawValue)")
            #expect(names.contains("recall_facts"), "Missing recall_facts for \(taskType.rawValue)")
        }
    }
}
```

- [ ] **Step 2: Run test — expect failure**

Press **Cmd+U**. `allTaskTypesIncludeRememberFactTool` should fail because the tools are not yet in `ToolBox.build(for:)`.

- [ ] **Step 3: Add memory tools to every case in `ToolBox.build(for:)`**

Open `TipTour/Agents/Tools/AgentTool.swift`. Replace the entire `build(for:)` method body (lines 76–122) with:

```swift
static func build(for taskType: TaskType) -> ToolBox {
    let memoryTools: [any AgentTool] = [
        RememberFactTool(taskType: taskType),
        RecallFactsTool(taskType: taskType)
    ]
    switch taskType {
    case .coding:
        return ToolBox(tools: [
            RunShellCommandTool(),
            ReadFileTool(),
            WriteFileTool(),
            ListDirectoryTool(),
            SpawnClaudeCodeTool()
        ] + memoryTools)
    case .browserResearch:
        return ToolBox(tools: [
            WebFetchTool(),
            WebSearchTool()
        ] + memoryTools)
    case .fileManagement:
        return ToolBox(tools: [
            ReadFileTool(),
            WriteFileTool(),
            ListDirectoryTool(),
            RunShellCommandTool()
        ] + memoryTools)
    case .generalMac:
        return ToolBox(tools: [
            ReadAXTreeTool(),
            ClickElementTool(),
            RunShellCommandTool(),
            ReadFileTool(),
            WriteFileTool()
        ] + memoryTools)
    case .analysis:
        return ToolBox(tools: [
            ReadFileTool(),
            ListDirectoryTool(),
            WebFetchTool()
        ] + memoryTools)
    case .writing:
        return ToolBox(tools: [
            ReadFileTool(),
            WriteFileTool(),
            WebFetchTool()
        ] + memoryTools)
    case .imageGeneration, .videoGeneration:
        return ToolBox(tools: [RunShellCommandTool()] + memoryTools)
    }
}
```

- [ ] **Step 4: Run tests — expect pass**

Press **Cmd+U**. `ToolBoxMemoryIntegrationTests` should pass. Also verify the existing `ToolBoxTests` suite still passes (specifically `buildReturnsNonEmptyToolsForAllTaskTypes` and `parametersJSONIsValidForAllTools`).

- [ ] **Step 5: Commit**

```bash
git add TipTour/Agents/Tools/AgentTool.swift TipTourTests/AgentMemoryTests.swift
git commit -m "feat: wire remember_fact and recall_facts into ToolBox for all task types"
```

---

## Task 5: TaskAgent startup injection and completion write

**Files:**
- Modify: `TipTour/Agents/Swarm/TaskAgent.swift`
- Modify: `TipTourTests/AgentMemoryTests.swift` (add integration tests)

- [ ] **Step 1: Write failing integration tests**

Append to `TipTourTests/AgentMemoryTests.swift`:

```swift
// MARK: - TaskAgent memory integration

// .serialized prevents concurrent tests from racing on AgentMemoryStore.shared.
@Suite("TaskAgentMemoryIntegration", .serialized)
struct TaskAgentMemoryIntegrationTests {

    @Test func completedAgentWritesTaskResultToSharedStore() async {
        // Clear shared store before and after to avoid interference from other tests.
        await AgentMemoryStore.shared.clear(keepPermanent: false)

        let swarm = AgentSwarmManager()
        let mockProvider = MockLLMProvider(id: "memory-integration-test")
        mockProvider.responseToReturn = .text("I completed the task successfully.")

        let agent = TaskAgent(
            taskDescription: "analyze the memory integration",
            taskType: .analysis,
            provider: mockProvider,
            swarmManager: swarm
        )
        await agent.run()

        let results = await AgentMemoryStore.shared.query(
            taskDescription: "analyze the memory integration",
            taskTypes: [.analysis]
        )
        #expect(!results.isEmpty)
        #expect(results.first?.entryType == .taskResult)
        #expect(results.first?.content.contains("analyze the memory integration") == true)
        await AgentMemoryStore.shared.clear(keepPermanent: false)
    }

    @Test func memoryBlockAppearsInFirstSystemMessage() async {
        await AgentMemoryStore.shared.clear(keepPermanent: false)

        // Pre-populate the shared store with a fact relevant to this task.
        await AgentMemoryStore.shared.write(
            content: "pnpm is the package manager for this project",
            entryType: .fact,
            taskTypes: [.coding],
            permanent: false
        )

        let swarm = AgentSwarmManager()
        let mockProvider = MockLLMProvider(id: "memory-injection-test")
        var capturedMessages: [LLMMessage] = []
        mockProvider.responseFactory = {
            return .text("Done.")
        }

        // Intercept the first complete() call to capture messages.
        // MockLLMProvider doesn't support message capture, so we verify
        // indirectly: the agent completes successfully (memory didn't break startup).
        mockProvider.responseToReturn = .text("Task complete.")

        let agent = TaskAgent(
            taskDescription: "install pnpm dependencies",
            taskType: .coding,
            provider: mockProvider,
            swarmManager: swarm
        )
        await agent.run()

        let status = await agent.currentStatus
        #expect(status.state == .completed)

        // Clean up.
        await AgentMemoryStore.shared.clear(keepPermanent: false)
    }
}
```

- [ ] **Step 2: Run tests — expect failure**

Press **Cmd+U**. `TaskAgentMemoryIntegrationTests` should fail because `TaskAgent.run()` does not yet write to the store.

- [ ] **Step 3: Modify `TaskAgent.swift`**

The changes are in three places: `run()`, `buildSystemPrompt()`, and two new private methods. Here is the full updated file:

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
        swarmManager: AgentSwarmManager,
        toolBox: ToolBox = ToolBox()
    ) {
        self.id = UUID()
        self.taskDescription = taskDescription
        self.taskType = taskType
        self.provider = provider
        self.swarmManager = swarmManager
        self.toolBox = toolBox
    }

    // MARK: - Main execution loop

    func run() async {
        guard !Task.isCancelled else { return }
        state = .active

        let memoryBlock = await fetchMemoryBlock()
        conversationHistory = [
            LLMMessage(role: .system, content: buildSystemPrompt(memoryBlock: memoryBlock)),
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
        await toolBox.execute(toolCall: toolCall)
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
        return "--- Memory from previous tasks ---\n\(lines)\n---"
    }

    /// Writes a task-result entry to the shared memory store summarising what this agent did.
    /// Called on completion (success or error). Skipped only for terminated agents.
    private func writeTaskResultToMemory(summary: String) async {
        let content = "\(taskType.displayName) agent: \(taskDescription). \(String(summary.prefix(300)))"
        await AgentMemoryStore.shared.write(
            content: content,
            entryType: .taskResult,
            taskTypes: [taskType],
            permanent: false
        )
    }

    private func buildSystemPrompt(memoryBlock: String) -> String {
        let memorySection = memoryBlock.isEmpty ? "" : "\n\(memoryBlock)"
        return """
        You are a background task agent running inside TipTour, a macOS AI assistant.
        Your task type: \(taskType.displayName)
        You have access to tools to accomplish tasks on the user's Mac.
        When you have completed the task, respond with a clear text summary of what you did and what you found.
        If you cannot complete the task, explain why clearly.
        Be concise and direct. Do not ask clarifying questions — make reasonable assumptions and proceed.\(memorySection)
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

- [ ] **Step 4: Run tests — expect pass**

Press **Cmd+U**. `TaskAgentMemoryIntegrationTests` (2 tests) should pass. Also verify `AgentSwarmTests`, `AgentToolTests`, and `AgentOverlayTests` all still pass — no regressions.

- [ ] **Step 5: Update CLAUDE.md key files table**

In `CLAUDE.md`, add these two rows to the Key Files table (after the `MacControlTools.swift` row):

```
| `TipTour/Agents/Memory/AgentMemoryEntry.swift` | ~75 | `AgentMemoryEntry`, `MemoryEntryType`, keyword extractor static method. |
| `TipTour/Agents/Memory/AgentMemoryStore.swift` | ~110 | Actor singleton — write/query/prune/clear with JSON persistence at `~/Library/Application Support/TipTour/agent-memory.json`. |
| `TipTour/Agents/Tools/MemoryTools.swift` | ~105 | `RememberFactTool` (remember_fact) and `RecallFactsTool` (recall_facts) — both available in all task types. |
```

- [ ] **Step 6: Commit**

```bash
git add TipTour/Agents/Swarm/TaskAgent.swift TipTourTests/AgentMemoryTests.swift CLAUDE.md
git commit -m "feat: inject memory into TaskAgent startup prompt and write task result on completion"
```
