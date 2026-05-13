// TipTour/Agents/Swarm/AgentSwarmManager.swift

import Combine
import Foundation

/// Coordinates all background task agents. Owns spawn/terminate lifecycle,
/// the Combine message bus, and the overlay state publisher consumed by SwiftUI.
/// Agents never reference each other directly — all communication goes through this coordinator.
actor AgentSwarmManager {

    static let shared = AgentSwarmManager()

    nonisolated let overlayStatePublisher = CurrentValueSubject<[AgentStatus], Never>([])
    nonisolated let messageBus = PassthroughSubject<AgentMessage, Never>()

    private var agents: [UUID: TaskAgent] = [:]
    private var agentMetrics: [UUID: AgentMetrics] = [:]
    private var agentTasks: [UUID: Task<Void, Never>] = [:]
    /// Long-running side-task per agent (currently: efficiency monitor's
    /// self-critique LLM call). Registered by TaskAgent after a run
    /// completes; cancelled in `terminate` so a dismissed agent's
    /// post-mortem LLM call stops burning tokens.
    private var sideTasksByAgent: [UUID: [Task<Void, Never>]] = [:]
    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    // MARK: - Spawn

    @discardableResult
    func spawn(
        taskDescription: String,
        taskType: TaskType,
        profile: TaskProfile? = nil
    ) async -> TaskAgent? {
        let maxConcurrent = userDefaults.object(forKey: "maxConcurrentAgents") as? Int ?? 5
        guard agents.count < maxConcurrent else {
            print("[AgentSwarmManager] Rejecting spawn — at max capacity (\(maxConcurrent) agents)")
            return nil
        }

        let registry = LLMProviderRegistry.shared
        let provider = await registry.provider(for: taskType)

        let newAgent = TaskAgent(
            taskDescription: taskDescription,
            taskType: taskType,
            provider: provider,
            swarmManager: self
        )

        agents[newAgent.id] = newAgent
        agentMetrics[newAgent.id] = AgentMetrics(agentId: newAgent.id)
        publishOverlayState()

        let agentId = newAgent.id
        let runTask = Task.detached(priority: .userInitiated) { [weak self] in
            await newAgent.run()
            // Natural completion — drop the task handle so we don't
            // hold a reference forever. The agent + metrics stay in
            // the swarm so the overlay can display the final state
            // and the auto-dismiss timer can fire normally.
            await self?.releaseRunTaskHandle(agentId: agentId)
        }
        agentTasks[agentId] = runTask

        return newAgent
    }

    /// Called from the spawn-task continuation when an agent's run loop
    /// returns. Clears the `agentTasks` slot so the swarm doesn't keep
    /// a strong reference to a completed Task forever.
    private func releaseRunTaskHandle(agentId: UUID) {
        agentTasks.removeValue(forKey: agentId)
    }

    /// Register a long-running side task (efficiency self-critique,
    /// future evaluators) so `terminate` can cancel it when the user
    /// dismisses the agent. Side tasks not registered here keep
    /// running independently — that's appropriate for fast-fire-and-
    /// forget bookkeeping but wasteful for anything that calls the LLM.
    func registerSideTask(_ task: Task<Void, Never>, forAgent agentId: UUID) {
        // Skip registration if the agent has already been terminated
        // (rare race) — cancel the task immediately instead so we
        // don't leak it through this dict.
        guard agents[agentId] != nil else {
            task.cancel()
            return
        }
        sideTasksByAgent[agentId, default: []].append(task)
    }

    // MARK: - Terminate

    func terminate(_ agentId: UUID) async {
        agentTasks[agentId]?.cancel()
        agentTasks.removeValue(forKey: agentId)
        // Cancel any registered side tasks (efficiency self-critique LLM
        // calls, etc.) so dismissing a completed agent stops paying for
        // post-mortem inference the user won't see.
        if let sideTasks = sideTasksByAgent.removeValue(forKey: agentId) {
            for task in sideTasks { task.cancel() }
        }
        await agents[agentId]?.markTerminated()
        agents.removeValue(forKey: agentId)
        // Metrics live alongside the agent — clear them when the agent
        // itself is gone, otherwise `agentMetrics` grows for every
        // dismissed agent over the app's lifetime.
        agentMetrics.removeValue(forKey: agentId)
        publishOverlayState()
    }

    func terminateAll() async {
        for agentId in Array(agents.keys) {
            await terminate(agentId)
        }
    }

    // MARK: - Messaging

    /// Routes a message to its destination on the swarm bus.
    /// .main → CompanionManager handles via messageBus subscription.
    /// .task(uuid) → delivered directly to that TaskAgent.
    /// .swarm → handled internally (e.g. spawn requests).
    ///
    /// Ordering rule: state mutations + overlay publish happen BEFORE
    /// we send the event on `messageBus`. Otherwise a subscriber that
    /// reacts to `taskComplete` could query `allStatuses` and see the
    /// agent still listed as `.busy` because the overlay snapshot was
    /// captured in the previous tick. Publishing first guarantees
    /// consumers see a consistent (state, event) pair.
    func send(_ message: AgentMessage) async {
        // Route to direct recipients first — they need the message
        // delivered before any state-derived broadcast goes out.
        switch message.to {
        case .task(let targetId):
            await agents[targetId]?.receive(message)
        case .swarm:
            await handleSwarmDirectedMessage(message)
        case .main:
            break
        }

        if case .task(let sourceId) = message.from {
            updateMetricsForMessage(agentId: sourceId, message: message)
        }

        // Publish overlay state BEFORE messageBus emits — this fixes
        // the race where overlay subscribers and messageBus subscribers
        // saw events in inconsistent orders. We use the awaiting
        // variant so the overlay subscriber actually receives the
        // snapshot before the messageBus subscriber sees the event.
        await publishOverlayStateAwaiting()
        messageBus.send(message)
    }

    // MARK: - Queries

    func status(of agentId: UUID) async -> AgentStatus? {
        await agents[agentId]?.currentStatus
    }

    func allStatuses() async -> [AgentStatus] {
        var statuses: [AgentStatus] = []
        for agent in agents.values {
            statuses.append(await agent.currentStatus)
        }
        return statuses
    }

    func allActiveAgentIds() -> [UUID] {
        Array(agents.keys)
    }

    // MARK: - Private

    private func handleSwarmDirectedMessage(_ message: AgentMessage) async {
        guard case .spawnRequest(let description, let taskType, let profile) = message.type else { return }
        let spawned = await spawn(taskDescription: description, taskType: taskType, profile: profile)
        if spawned == nil {
            // Swarm at capacity — surface a taskFailed back to the
            // original requester so the parent agent / voice session
            // can react instead of waiting for a reply that never comes.
            messageBus.send(AgentMessage(
                from: .swarm,
                to: message.from,
                type: .taskFailed(reason: "Swarm at capacity — could not spawn '\(description)'")
            ))
        }
    }

    private func updateMetricsForMessage(agentId: UUID, message: AgentMessage) {
        guard agentMetrics[agentId] != nil else { return }
        switch message.type {
        case .taskComplete:
            agentMetrics[agentId]?.tasksCompleted += 1
            agentMetrics[agentId]?.lastActive = Date()
        case .taskFailed:
            agentMetrics[agentId]?.tasksFailed += 1
            agentMetrics[agentId]?.lastActive = Date()
        default:
            agentMetrics[agentId]?.lastActive = Date()
        }
    }

    /// Fire-and-forget publish. Used by code paths that don't need the
    /// overlay update to be observable before they continue. The
    /// detached Task may race messageBus emissions; use
    /// `publishOverlayStateAwaiting()` when ordering matters.
    private func publishOverlayState() {
        let agentValues = Array(agents.values)
        Task { @MainActor in
            var statuses: [AgentStatus] = []
            for agent in agentValues {
                statuses.append(await agent.currentStatus)
            }
            self.overlayStatePublisher.send(statuses)
        }
    }

    /// Awaitable publish — the overlay subscriber sees the new state
    /// before this returns, so callers can safely emit messageBus
    /// events afterwards knowing overlay consumers won't observe a
    /// state that contradicts the message they're about to receive.
    private func publishOverlayStateAwaiting() async {
        let agentValues = Array(agents.values)
        let publisher = overlayStatePublisher
        await MainActor.run { /* hop */ }
        var statuses: [AgentStatus] = []
        for agent in agentValues {
            statuses.append(await agent.currentStatus)
        }
        await MainActor.run {
            publisher.send(statuses)
        }
    }
}
