// TipTour/Agents/Core/EfficiencyTypes.swift

import Foundation

// MARK: - Task outcome

enum TaskOutcome: Sendable {
    case success(summary: String)
    case failure(reason: String)
}

// MARK: - One completed agent run

struct TaskExecution: Sendable {
    let taskId: UUID
    let taskType: TaskType
    let taskDescription: String
    var tokensUsed: Int
    var toolCallCount: Int
    var backtrackCount: Int
    var stepsExecuted: Int
    var duration: TimeInterval
    var outcome: TaskOutcome
    var conversationHistory: [LLMMessage]
    var autoSavedSkillSlug: String?
}

// MARK: - Efficiency evaluation result

struct EfficiencyReport: Sendable {
    let inefficiencyScore: Double
    let tokenOverrun: Int
    let wastedSteps: Int
    let diagnosis: String
    let didSelfCritique: Bool
}
