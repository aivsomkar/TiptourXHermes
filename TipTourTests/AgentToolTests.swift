// TipTourTests/AgentToolTests.swift

import Foundation
import Testing
@testable import TipTour

// MARK: - ToolBox tests

@Suite("ToolBox")
struct ToolBoxTests {

    @Test func buildReturnsNonEmptyToolsForAllTaskTypes() {
        for taskType in TaskType.allCases {
            let toolBox = ToolBox.build(for: taskType)
            #expect(!toolBox.definitions.isEmpty, "Expected tools for task type \(taskType.rawValue)")
        }
    }

    @Test func definitionsHaveNonEmptyFields() {
        let toolBox = ToolBox.build(for: .coding)
        for definition in toolBox.definitions {
            #expect(!definition.name.isEmpty)
            #expect(!definition.description.isEmpty)
            #expect(!definition.parametersJSON.isEmpty)
        }
    }

    @Test func returnsErrorStringForUnknownToolCall() async {
        let toolBox = ToolBox.build(for: .coding)
        let fakeCall = LLMToolCall(id: "x", name: "nonexistent_tool", argumentsJSON: "{}")
        let result = await toolBox.execute(toolCall: fakeCall)
        #expect(result.contains("Error"))
        #expect(result.contains("nonexistent_tool"))
    }

    @Test func parametersJSONIsValidForAllTools() {
        for taskType in TaskType.allCases {
            let toolBox = ToolBox.build(for: taskType)
            for definition in toolBox.definitions {
                guard let data = definition.parametersJSON.data(using: .utf8),
                      (try? JSONSerialization.jsonObject(with: data)) != nil else {
                    Issue.record("Invalid parametersJSON for tool '\(definition.name)' in task type '\(taskType.rawValue)'")
                    return
                }
            }
        }
    }
}

// MARK: - RunShellCommandTool tests

@Suite("RunShellCommandTool")
struct RunShellCommandToolTests {

    @Test func echoCommandReturnsOutput() async {
        let tool = RunShellCommandTool()
        let result = await tool.execute(argumentsJSON: #"{"command": "echo hello"}"#)
        #expect(result.trimmingCharacters(in: .whitespacesAndNewlines) == "hello")
    }

    @Test func nonZeroExitCodeIncludesExitCodeInOutput() async {
        let tool = RunShellCommandTool()
        let result = await tool.execute(argumentsJSON: #"{"command": "exit 42"}"#)
        #expect(result.contains("42"))
    }

    @Test func missingCommandFieldReturnsError() async {
        let tool = RunShellCommandTool()
        let result = await tool.execute(argumentsJSON: #"{}"#)
        #expect(result.contains("Error"))
    }

    @Test func malformedJSONReturnsError() async {
        let tool = RunShellCommandTool()
        let result = await tool.execute(argumentsJSON: "not json")
        #expect(result.contains("Error"))
    }
}

// MARK: - FileTools tests

@Suite("FileTools")
struct FileToolsTests {

    @Test func readFileToolReadsExistingFile() async throws {
        let tmp = NSTemporaryDirectory() + "tiptour_test_read_\(UUID()).txt"
        let content = "Hello from read file test"
        try content.write(toFile: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let tool = ReadFileTool()
        let result = await tool.execute(argumentsJSON: #"{"path": "\#(tmp)"}"#)
        #expect(result == content)
    }

    @Test func readFileToolReturnsErrorForMissingFile() async {
        let tool = ReadFileTool()
        let result = await tool.execute(argumentsJSON: #"{"path": "/nonexistent/path/file.txt"}"#)
        #expect(result.contains("Error"))
    }

    @Test func writeFileThenReadRoundTrips() async throws {
        let tmp = NSTemporaryDirectory() + "tiptour_test_write_\(UUID()).txt"
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let content = "Round trip test content"
        let writeTool = WriteFileTool()
        let writeResult = await writeTool.execute(
            argumentsJSON: #"{"path": "\#(tmp)", "content": "\#(content)"}"#
        )
        #expect(writeResult.contains("Successfully"))

        let readTool = ReadFileTool()
        let readResult = await readTool.execute(argumentsJSON: #"{"path": "\#(tmp)"}"#)
        #expect(readResult == content)
    }

    @Test func listDirectoryToolListsContents() async {
        let tool = ListDirectoryTool()
        let result = await tool.execute(argumentsJSON: #"{"path": "/tmp"}"#)
        #expect(!result.contains("Error"))
    }

    @Test func listDirectoryToolReturnsErrorForMissingDirectory() async {
        let tool = ListDirectoryTool()
        let result = await tool.execute(argumentsJSON: #"{"path": "/nonexistent/dir"}"#)
        #expect(result.contains("Error"))
    }
}

// MARK: - WebTools tests (offline — validates structure only)

@Suite("WebTools")
struct WebToolsTests {

    @Test func webFetchToolParametersJSONIsValidJSON() {
        let tool = WebFetchTool()
        guard let data = tool.parametersJSON.data(using: .utf8) else {
            Issue.record("parametersJSON is not UTF-8")
            return
        }
        #expect((try? JSONSerialization.jsonObject(with: data)) != nil)
    }

    @Test func webSearchToolParametersJSONIsValidJSON() {
        let tool = WebSearchTool()
        guard let data = tool.parametersJSON.data(using: .utf8) else {
            Issue.record("parametersJSON is not UTF-8")
            return
        }
        #expect((try? JSONSerialization.jsonObject(with: data)) != nil)
    }

    @Test func webFetchToolReturnsErrorForInvalidURL() async {
        let tool = WebFetchTool()
        let result = await tool.execute(argumentsJSON: #"{"url": "not-a-url"}"#)
        #expect(result.contains("Error"))
    }

    @Test func webFetchToolReturnsErrorForMissingURLField() async {
        let tool = WebFetchTool()
        let result = await tool.execute(argumentsJSON: #"{}"#)
        #expect(result.contains("Error"))
    }
}

// MARK: - MacControlTools tests (structure only)

@Suite("MacControlTools")
struct MacControlToolsTests {

    @Test func readAXTreeToolParametersJSONIsValidJSON() {
        let tool = ReadAXTreeTool()
        guard let data = tool.parametersJSON.data(using: .utf8) else {
            Issue.record("parametersJSON is not UTF-8")
            return
        }
        #expect((try? JSONSerialization.jsonObject(with: data)) != nil)
    }

    @Test func clickElementToolReturnsErrorForMissingLabel() async {
        let tool = ClickElementTool()
        let result = await tool.execute(argumentsJSON: #"{}"#)
        #expect(result.contains("Error"))
    }

    @Test func clickElementToolReturnsErrorForMalformedJSON() async {
        let tool = ClickElementTool()
        let result = await tool.execute(argumentsJSON: "bad json")
        #expect(result.contains("Error"))
    }
}

// MARK: - SpawnClaudeCodeTool tests

@Suite("SpawnClaudeCodeTool")
struct SpawnClaudeCodeToolTests {

    @Test func parametersJSONIsValidJSON() {
        let tool = SpawnClaudeCodeTool()
        guard let data = tool.parametersJSON.data(using: .utf8) else {
            Issue.record("parametersJSON is not UTF-8")
            return
        }
        #expect((try? JSONSerialization.jsonObject(with: data)) != nil)
    }

    @Test func returnsErrorForMissingTaskField() async {
        let tool = SpawnClaudeCodeTool()
        let result = await tool.execute(argumentsJSON: #"{}"#)
        #expect(result.contains("Error"))
    }
}

// MARK: - TaskAgent + ToolBox integration

@Suite("TaskAgentToolIntegration")
struct TaskAgentToolIntegrationTests {

    @Test func taskAgentWithToolBoxDispatchesToolCallSuccessfully() async {
        let swarm = AgentSwarmManager()
        let mockProvider = MockLLMProvider(id: "tool-integration-test")

        var callCount = 0
        mockProvider.responseFactory = {
            callCount += 1
            if callCount == 1 {
                return .toolCalls([
                    LLMToolCall(id: "call-1", name: "run_shell_command", argumentsJSON: #"{"command":"echo success"}"#)
                ])
            }
            return .text("Task complete.")
        }

        let agent = TaskAgent(
            taskDescription: "Echo a test string",
            taskType: .fileManagement,
            provider: mockProvider,
            swarmManager: swarm
        )

        await agent.run()

        let status = await agent.currentStatus
        #expect(status.state == .completed)
        #expect(status.stepHistory.count >= 2)
    }
}
