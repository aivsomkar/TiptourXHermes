// TipTour/Agents/Swarm/AgentTypes.swift

import Foundation

// MARK: - Agent identity

enum AgentID: Equatable, Sendable {
    case main
    case swarm
    case task(UUID)
}

// MARK: - Lifecycle states

enum AgentState: Equatable, Sendable {
    case spawning
    case active
    case busy
    case blocked(blocker: AgentBlocker)
    case idle
    case completed
    case error(message: String)
    case terminated

    var displayLabel: String {
        switch self {
        case .spawning:                     return "Starting..."
        case .active:                       return "Active"
        case .busy:                         return "Working..."
        case .blocked:                      return "Needs input"
        case .idle:                         return "Idle"
        case .completed:                    return "Done"
        case .error(let message):           return "Error: \(message)"
        case .terminated:                   return "Stopped"
        }
    }
}

// MARK: - Blockers

struct AgentBlocker: Equatable, Sendable {
    let description: String
    let possibleResolutions: [String]
    let raisedAt: Date

    static func == (lhs: AgentBlocker, rhs: AgentBlocker) -> Bool {
        lhs.description == rhs.description && lhs.raisedAt == rhs.raisedAt
    }
}

// MARK: - Task results

enum TaskResult: Sendable {
    case success(summary: String, detailJSON: String?)
    case failure(reason: String)
    case partial(completedSummary: String, remainingDescription: String)
}

// MARK: - Messages on the swarm bus

struct AgentMessage: Sendable {
    let id: UUID
    let from: AgentID
    let to: AgentID
    let type: AgentMessageType
    let timestamp: Date

    nonisolated init(from: AgentID, to: AgentID, type: AgentMessageType) {
        self.id = UUID()
        self.from = from
        self.to = to
        self.type = type
        self.timestamp = Date()
    }
}

enum AgentMessageType: Sendable {
    case taskComplete(result: TaskResult)
    case taskFailed(reason: String)
    case blockerRaised(blocker: AgentBlocker)
    case blockerResolved(response: String)
    case progressUpdate(stepDescription: String, progressFraction: Double?)
    case spawnRequest(taskDescription: String, taskType: TaskType, profile: TaskProfile?)
    case interrupt(instruction: String)
    case statusQuery
    case statusResponse(status: AgentStatus)
    case chatMessage(text: String)
}

// MARK: - Per-agent UI state

struct AgentStatus: Identifiable, Sendable {
    let id: UUID
    let agentName: String
    let taskSummary: String
    var state: AgentState
    var currentStep: String
    var stepHistory: [AgentStep]
    var tokensUsed: Int
    var elapsedSeconds: Double
    var blocker: AgentBlocker?
    var result: TaskResult?
    var isExpanded: Bool
    var isMinimised: Bool
    var chatHistory: [AgentChatMessage]
}

struct AgentStep: Sendable {
    let description: String
    let completedAt: Date
    let succeeded: Bool
}

struct AgentChatMessage: Sendable {
    enum Sender: Sendable { case user, agent }
    let sender: Sender
    let text: String
    let timestamp: Date
}

// MARK: - Metrics

struct AgentMetrics: Sendable {
    let agentId: UUID
    var tasksCompleted: Int = 0
    var tasksFailed: Int = 0
    var totalTokensUsed: Int = 0
    var totalDurationSeconds: Double = 0
    var successRate: Double {
        let totalTasks = tasksCompleted + tasksFailed
        guard totalTasks > 0 else { return 0 }
        return Double(tasksCompleted) / Double(totalTasks)
    }
    var lastActive: Date = Date()
}

extension AgentState {
    var isBlocked: Bool {
        if case .blocked = self { return true }
        return false
    }
}
