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

    @Test func extractKeywordsSplitsOnSlashAndHyphen() {
        let keywords = AgentMemoryEntry.extractKeywords(from: "/opt/homebrew and xcode-cloud")
        #expect(keywords.contains("opt"))
        #expect(keywords.contains("homebrew"))
        #expect(keywords.contains("xcode"))
        #expect(keywords.contains("cloud"))
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
        #expect(results.count == 5)
    }

    @Test func pruneExpiredRemovesStaleEntries() async {
        let store = makeTempStore()
        let expiredEntry = AgentMemoryEntry(
            id: UUID(),
            content: "this entry is expired",
            entryType: .fact,
            taskTypes: [.coding],
            keywords: ["expired", "entry"],
            createdAt: Date.now.addingTimeInterval(-100),
            expiresAt: Date.now.addingTimeInterval(-1)
        )
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
        let tool = RememberFactTool(taskType: .coding, store: makeTempStore())
        let result = await tool.execute(argumentsJSON: #"{}"#)
        #expect(result.contains("Error"))
    }

    @Test func rememberFactMalformedJSONReturnsError() async {
        let tool = RememberFactTool(taskType: .coding, store: makeTempStore())
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
        let tool = RecallFactsTool(taskType: .coding, store: makeTempStore())
        let result = await tool.execute(argumentsJSON: #"{}"#)
        #expect(result.contains("Error"))
    }
}

// MARK: - ToolBox memory tool integration

@Suite("ToolBoxMemoryIntegration")
struct ToolBoxMemoryIntegrationTests {

    @Test func allTaskTypesIncludeMemoryTools() {
        for taskType in TaskType.allCases {
            let toolBox = ToolBox.build(for: taskType)
            let names = toolBox.definitions.map(\.name)
            #expect(names.contains("remember_fact"), "Missing remember_fact for \(taskType.rawValue)")
            #expect(names.contains("recall_facts"), "Missing recall_facts for \(taskType.rawValue)")
        }
    }
}

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

        await AgentMemoryStore.shared.write(
            content: "pnpm is the package manager for this project",
            entryType: .fact,
            taskTypes: [.coding],
            permanent: false
        )

        let swarm = AgentSwarmManager()
        let mockProvider = MockLLMProvider(id: "memory-injection-test")
        mockProvider.responseToReturn = .text("Task complete.")

        let agent = TaskAgent(
            taskDescription: "install pnpm dependencies",
            taskType: .coding,
            provider: mockProvider,
            swarmManager: swarm
        )
        await agent.run()

        let systemMessage = mockProvider.capturedMessages.first?.first
        #expect(systemMessage?.role == .system)
        #expect(systemMessage?.content.contains("--- Relevant memory ---") == true)
        #expect(systemMessage?.content.contains("pnpm is the package manager for this project") == true)

        await AgentMemoryStore.shared.clear(keepPermanent: false)
    }
}
