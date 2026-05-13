// TipTour/Agents/Swarm/SwarmStubs.swift
// Temporary stubs for types deleted with Core/, Memory/, Providers/.
// This entire Swarm/ directory is removed in the next rebrand task.

import Foundation

// MARK: - TaskType (was Core/LLMProvider.swift)

enum TaskType: String, CaseIterable, Sendable {
    case browserResearch
    case generalMac
    case fileManagement
    case coding
    case imageGeneration
    case videoGeneration
    case analysis
    case writing

    var displayName: String { rawValue }
}

// MARK: - TaskProfile (was Core/LLMProvider.swift)

struct TaskProfile: Sendable {}

// MARK: - LLM types (was Core/LLMProvider.swift)

protocol LLMProvider: AnyObject, Sendable {
    var providerId: String { get }
    func complete(messages: [LLMMessage], tools: [LLMTool]) async throws -> LLMCompletionResult
}

struct LLMMessage: Sendable {
    enum Role: Sendable { case system, user, assistant, tool }
    let role: Role
    let content: String
    var toolCallId: String?
    var toolName: String?
    var imagesJPEG: [Data]?
    var toolCalls: [LLMToolCall]?
    init(role: Role, content: String, toolCallId: String? = nil, toolName: String? = nil, imagesJPEG: [Data]? = nil, toolCalls: [LLMToolCall]? = nil) {
        self.role = role; self.content = content
        self.toolCallId = toolCallId; self.toolName = toolName
        self.imagesJPEG = imagesJPEG; self.toolCalls = toolCalls
    }
}

struct LLMTool: Sendable {
    let name: String
    let description: String
    let parametersJSON: String
}

struct LLMToolCall: Sendable {
    let id: String
    let name: String
    let argumentsJSON: String
}

enum LLMResponse: Sendable {
    case text(String)
    case toolCalls([LLMToolCall])
    case textAndToolCalls(String, [LLMToolCall])
}

struct LLMTokenUsage: Sendable {
    let totalTokens: Int
}

struct LLMCompletionResult: Sendable {
    let response: LLMResponse
    let tokenUsage: LLMTokenUsage?
}

enum LLMProviderError: Error, Sendable {
    case missingAPIKey(String)
    case httpError(Int, String)
    case decodingError(String)
    case unsupportedOperation(String)
}

// MARK: - LLMProviderRegistry (was Core/LLMProviderRegistry.swift)

actor LLMProviderRegistry {
    static let shared = LLMProviderRegistry()
    func provider(for taskType: TaskType) async -> (any LLMProvider)? { nil }
}

// MARK: - EfficiencyMonitor stubs (was Core/EfficiencyMonitor.swift)

enum TaskOutcome: Sendable {
    case success(summary: String)
    case failure(reason: String)
}

struct TaskExecution: Sendable {
    let taskId: UUID
    let taskType: TaskType
    let taskDescription: String
    let tokensUsed: Int
    let toolCallCount: Int
    let backtrackCount: Int
    let stepsExecuted: Int
    let duration: TimeInterval
    let outcome: TaskOutcome
    let conversationHistory: [LLMMessage]
}

struct EfficiencyReport: Sendable {
    let inefficiencyScore: Double
    let didSelfCritique: Bool
}

actor EfficiencyMonitor {
    static let shared = EfficiencyMonitor()
    func evaluate(_ execution: TaskExecution) async -> EfficiencyReport {
        EfficiencyReport(inefficiencyScore: 0, didSelfCritique: false)
    }
}

// MARK: - AgentMemoryStore stubs (was Memory/AgentMemoryStore.swift)

struct AgentMemoryEntry: Sendable {
    enum EntryType: Sendable { case fact, taskResult }
    let content: String
    let entryType: EntryType
    let expiresAt: Date?
}

actor AgentMemoryStore {
    static let shared = AgentMemoryStore()
    func query(taskDescription: String, taskTypes: [TaskType]) async -> [AgentMemoryEntry] { [] }
    func write(content: String, entryType: AgentMemoryEntry.EntryType, taskTypes: [TaskType], permanent: Bool) async {}
}
