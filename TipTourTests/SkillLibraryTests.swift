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

    @Test func parseFrontmatterHandlesColonInValue() {
        let content = """
        ---
        id: 550E8400-E29B-41D4-A716-446655440000
        name: fix-crash
        description: fix: crash on launch when no provider configured
        taskTypes: [coding]
        keywords: [crash, fix]
        createdAt: 2026-05-10
        ---
        """
        let entry = SkillEntry.parse(from: content, slug: "fix-crash")
        #expect(entry?.description == "fix: crash on launch when no provider configured")
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
        #expect(reparsed?.description == original.description)
        #expect(reparsed?.taskTypes == original.taskTypes)
        #expect(reparsed?.keywords == original.keywords)
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
