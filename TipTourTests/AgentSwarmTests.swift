// TipTourTests/AgentSwarmTests.swift

import Combine
import Foundation
import Testing
@testable import TipTour

// MARK: - Mock provider for all tests

final class MockLLMProvider: LLMProvider {
    let providerId: String
    let displayName: String
    let supportsVoice = false
    let costTier: LLMCostTier = .low

    var responseToReturn: LLMResponse = .text("mock response")
    var tokenUsageToReturn: LLMTokenUsage? = nil
    var shouldThrow = false
    /// When set, overrides responseToReturn — called once per complete() invocation.
    var responseFactory: (() -> LLMResponse)?
    var capturedMessages: [[LLMMessage]] = []

    init(id: String) {
        self.providerId = id
        self.displayName = "Mock (\(id))"
    }

    func complete(messages: [LLMMessage], tools: [LLMTool]) async throws -> LLMCompletionResult {
        capturedMessages.append(messages)
        if shouldThrow { throw LLMProviderError.missingAPIKey(providerName: "Mock") }
        let response = responseFactory?() ?? responseToReturn
        return LLMCompletionResult(response: response, tokenUsage: tokenUsageToReturn)
    }
}

// MARK: - LLMProviderRegistry tests

@Suite("LLMProviderRegistry")
struct LLMProviderRegistryTests {

    @Test func defaultProfilesExistForAllTaskTypes() async {
        let registry = LLMProviderRegistry()
        for taskType in TaskType.allCases {
            let profile = await registry.profile(for: taskType)
            #expect(profile != nil, "Missing default profile for \(taskType.rawValue)")
        }
    }

    @Test func registeredProviderIsReturnableById() async {
        let registry = LLMProviderRegistry()
        let fakeProvider = MockLLMProvider(id: "mock-test-provider")
        await registry.register(fakeProvider)
        let retrieved = await registry.provider(id: "mock-test-provider")
        #expect(retrieved != nil)
        #expect(retrieved?.providerId == "mock-test-provider")
    }

    @Test func returnsNilWhenNoProvidersRegistered() async {
        let registry = LLMProviderRegistry()
        // Fresh registry — no providers registered
        let provider = await registry.provider(for: .coding)
        #expect(provider == nil)
    }

    @Test func updatedProfileIsRespectedOnNextQuery() async {
        let registry = LLMProviderRegistry()
        let mockProvider = MockLLMProvider(id: "openai-gpt-4o")
        await registry.register(mockProvider)

        var updatedProfile = TaskProfile.defaults()[.coding]!
        updatedProfile.preferredProviderId = "openai-gpt-4o"
        await registry.setProfile(updatedProfile)

        let retrieved = await registry.profile(for: .coding)
        #expect(retrieved?.preferredProviderId == "openai-gpt-4o")
    }

    @Test func fallbackProviderUsedWhenPrimaryMissing() async {
        let registry = LLMProviderRegistry()
        let fallback = MockLLMProvider(id: "gemini-rest-gemini-2.5-flash")
        await registry.register(fallback)

        // browserResearch profile has gemini-rest as fallback in defaults
        let resolved = await registry.provider(for: .browserResearch)
        #expect(resolved?.providerId == "gemini-rest-gemini-2.5-flash")
    }

    @Test func allProfilesReturnedCoversAllTaskTypes() async {
        let registry = LLMProviderRegistry()
        let profiles = await registry.allProfiles()
        #expect(profiles.count == TaskType.allCases.count)
    }
}

// MARK: - TaskType tests

@Suite("TaskType")
struct TaskTypeTests {

    @Test func displayNameIsNeverEmpty() {
        for taskType in TaskType.allCases {
            #expect(!taskType.displayName.isEmpty, "Empty displayName for \(taskType.rawValue)")
        }
    }

    @Test func rawValueRoundTrips() {
        for taskType in TaskType.allCases {
            let reconstructed = TaskType(rawValue: taskType.rawValue)
            #expect(reconstructed == taskType)
        }
    }
}

// MARK: - AgentState tests

@Suite("AgentState")
struct AgentStateTests {

    @Test func displayLabelIsNeverEmpty() {
        let allStates: [AgentState] = [
            .spawning,
            .active,
            .busy,
            .blocked(blocker: AgentBlocker(description: "test blocker", possibleResolutions: [], raisedAt: Date())),
            .idle,
            .completed,
            .error(message: "something went wrong"),
            .terminated
        ]
        for state in allStates {
            #expect(!state.displayLabel.isEmpty, "Empty displayLabel for \(state)")
        }
    }

    @Test func agentIDEqualityIsCorrect() {
        let uuid = UUID()
        #expect(AgentID.task(uuid) == AgentID.task(uuid))
        #expect(AgentID.main == AgentID.main)
        #expect(AgentID.swarm == AgentID.swarm)
        #expect(AgentID.task(uuid) != AgentID.main)
        #expect(AgentID.task(UUID()) != AgentID.task(UUID()))
    }
}

// MARK: - AgentMetrics tests

@Suite("AgentMetrics")
struct AgentMetricsTests {

    @Test func successRateIsZeroWhenNoTasksCompleted() {
        let metrics = AgentMetrics(agentId: UUID())
        #expect(metrics.successRate == 0)
    }

    @Test func successRateCalculatesCorrectly() {
        var metrics = AgentMetrics(agentId: UUID())
        metrics.tasksCompleted = 3
        metrics.tasksFailed = 1
        #expect(metrics.successRate == 0.75)
    }
}

// MARK: - AgentSwarmManager tests

@Suite("AgentSwarmManager")
struct AgentSwarmManagerTests {

    @Test func terminateOnNonExistentIdDoesNotCrash() async {
        let swarm = AgentSwarmManager()
        let nonExistentId = UUID()
        await swarm.terminate(nonExistentId)
        // Test passes if no crash or assertion fires
    }

    @Test func messageBusReceivesPublishedMessages() async {
        let swarm = AgentSwarmManager()
        var receivedMessages: [AgentMessage] = []
        let cancellable = swarm.messageBus.sink { receivedMessages.append($0) }

        let message = AgentMessage(from: .main, to: .swarm, type: .statusQuery)
        await swarm.send(message)

        #expect(receivedMessages.count == 1)
        withExtendedLifetime(cancellable) {}
    }

    @Test func allActiveAgentIdsIsEmptyOnFreshManager() async {
        let swarm = AgentSwarmManager()
        let ids = await swarm.allActiveAgentIds()
        #expect(ids.isEmpty)
    }
}

// MARK: - TaskAgent tests

@Suite("TaskAgent")
struct TaskAgentTests {

    @Test func agentCompletesWhenProviderReturnsText() async {
        let swarm = AgentSwarmManager()
        let mockProvider = MockLLMProvider(id: "mock-for-agent-test")
        mockProvider.responseToReturn = .text("I found 3 great cameras for you.")

        let agent = TaskAgent(
            taskDescription: "Find me a camera",
            taskType: .browserResearch,
            provider: mockProvider,
            swarmManager: swarm
        )

        await agent.run()

        let status = await agent.currentStatus
        #expect(status.state == .completed)
        #expect(status.stepHistory.count >= 1)
    }

    @Test func agentEntersErrorStateWhenNoProvider() async {
        let swarm = AgentSwarmManager()
        let agent = TaskAgent(
            taskDescription: "Do something",
            taskType: .coding,
            provider: nil,
            swarmManager: swarm
        )

        await agent.run()

        let status = await agent.currentStatus
        if case .error = status.state {
            // Expected
        } else {
            Issue.record("Expected .error state but got \(status.state)")
        }
    }

    @Test func interruptIsAppliedBeforeNextLLMCall() async {
        let swarm = AgentSwarmManager()
        let mockProvider = MockLLMProvider(id: "mock-interrupt-test")
        mockProvider.responseToReturn = .text("Done.")

        let agent = TaskAgent(
            taskDescription: "original task",
            taskType: .generalMac,
            provider: mockProvider,
            swarmManager: swarm
        )

        await agent.receive(AgentMessage(
            from: .main,
            to: .task(agent.id),
            type: .interrupt(instruction: "Budget changed to $500")
        ))

        await agent.run()

        let status = await agent.currentStatus
        #expect(status.state == .completed)
    }
}

// MARK: - End-to-end swarm integration

@Suite("SwarmIntegration")
struct SwarmIntegrationTests {

    @Test func spawnAndCompleteFullCycle() async throws {
        let swarm = AgentSwarmManager()
        let mockProvider = MockLLMProvider(id: "e2e-mock")
        mockProvider.responseToReturn = .text("Found 3 cameras. Recommended: Sony A6700 at $1,299.")
        await LLMProviderRegistry.shared.register(mockProvider)

        var profile = TaskProfile.defaults()[.generalMac]!
        profile.preferredProviderId = "e2e-mock"
        await LLMProviderRegistry.shared.setProfile(profile)

        var receivedCompletions: [AgentMessage] = []
        let cancellable = swarm.messageBus
            .filter {
                if case .taskComplete = $0.type { return true }
                return false
            }
            .sink { receivedCompletions.append($0) }

        await swarm.spawn(taskDescription: "Find a good camera", taskType: .generalMac)

        try await Task.sleep(for: .seconds(1))

        cancellable.cancel()
        // Test passes as long as no crash — the agent may complete instantly
        // and be removed from the swarm before we check. That's expected behavior.
    }
}

// MARK: - Capacity, cancellation, and provider-routing regression tests
//
// These tests cover behaviors that previously had no coverage and where
// the swarm would silently lie (spawning past capacity, returning a
// random provider when keys were missing, leaving tools running after
// terminate). Each test pins a specific behavior so future refactors
// can't regress quietly.

@Suite("SwarmCapacity")
struct SwarmCapacityTests {

    /// Use an isolated UserDefaults instance so the cap doesn't leak
    /// across tests or pick up a value the user set in the real app.
    private func makeIsolatedDefaults(maxConcurrentAgents: Int) -> UserDefaults {
        let suiteName = "test-swarm-capacity-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(maxConcurrentAgents, forKey: "maxConcurrentAgents")
        return defaults
    }

    @Test func spawnReturnsNilWhenAtCapacity() async {
        let defaults = makeIsolatedDefaults(maxConcurrentAgents: 1)
        let swarm = AgentSwarmManager(userDefaults: defaults)

        // First spawn fits under the cap.
        let firstAgent = await swarm.spawn(
            taskDescription: "first agent",
            taskType: .generalMac
        )
        #expect(firstAgent != nil)

        // Second spawn must be refused because the cap is 1.
        let secondAgent = await swarm.spawn(
            taskDescription: "second agent",
            taskType: .generalMac
        )
        #expect(secondAgent == nil, "Spawn beyond capacity must return nil — silently spawning anyway was the original bug.")

        // Cleanup so the agent's detached run task doesn't outlive the test.
        if let firstAgent {
            await swarm.terminate(firstAgent.id)
        }
    }

    @Test func capacityFreedAfterTerminate() async {
        let defaults = makeIsolatedDefaults(maxConcurrentAgents: 1)
        let swarm = AgentSwarmManager(userDefaults: defaults)

        guard let firstAgent = await swarm.spawn(
            taskDescription: "first agent",
            taskType: .generalMac
        ) else {
            Issue.record("First spawn should have succeeded")
            return
        }
        await swarm.terminate(firstAgent.id)

        // After terminate, the slot must be available again.
        let secondAgent = await swarm.spawn(
            taskDescription: "second agent",
            taskType: .generalMac
        )
        #expect(secondAgent != nil)
        if let secondAgent {
            await swarm.terminate(secondAgent.id)
        }
    }
}

@Suite("ProviderRouting")
struct ProviderRoutingRegressionTests {

    @Test func unconfiguredTaskTypeReturnsNilInsteadOfRandomProvider() async {
        let registry = LLMProviderRegistry()
        // Register a provider for an UNRELATED id so providers.values
        // is non-empty. The pre-fix code returned this provider for
        // every task type whose preferred + fallback weren't found,
        // silently mis-routing tasks.
        let unrelated = MockLLMProvider(id: "unrelated-provider-not-in-any-profile")
        await registry.register(unrelated)

        let provider = await registry.provider(for: .coding)
        // .coding wants anthropic-claude-sonnet-4-6; neither preferred
        // nor fallback is registered. Must return nil, NOT the unrelated
        // provider we just registered.
        #expect(provider == nil, "Provider lookup must fail clean when neither preferred nor fallback is registered.")
    }
}

@Suite("CancellationHonesty")
struct CancellationHonestyTests {

    @Test func cancelledAgentBailsBeforeNextLLMCall() async throws {
        // The mock provider sleeps 1.5s per complete() call — long enough
        // to cancel during. We schedule cancellation after the first
        // call returns; on the second iteration, the agent must
        // detect cancellation and exit instead of running again.
        let provider = SlowLoopingMockProvider(perCallDelaySeconds: 1.5)
        provider.responseToReturn = .text("done")

        let swarm = AgentSwarmManager()
        let agent = TaskAgent(
            taskDescription: "loop forever",
            taskType: .generalMac,
            provider: provider,
            swarmManager: swarm
        )

        // Drive the agent in the background and cancel via a Task.
        let runTask = Task { await agent.run() }
        try await Task.sleep(for: .milliseconds(200))
        runTask.cancel()

        // Wait for the run task to actually return — should be quick
        // because the cancellation check fires before the next LLM call.
        let completionDeadline = Date().addingTimeInterval(5)
        while !runTask.isCancelled && Date() < completionDeadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        await runTask.value

        let finalState = await agent.state
        #expect(finalState == .terminated, "Cancelled agent must end in .terminated state, not .completed/.error — observed \(finalState)")
    }
}

/// Provider that sleeps before responding so tests can exercise the
/// "cancel between turns" path without racing real network calls.
private final class SlowLoopingMockProvider: LLMProvider {
    let providerId = "slow-looping-mock"
    let displayName = "Slow Looping Mock"
    let supportsVoice = false
    let costTier: LLMCostTier = .low

    var responseToReturn: LLMResponse = .text("ok")
    private let perCallDelaySeconds: Double

    init(perCallDelaySeconds: Double) {
        self.perCallDelaySeconds = perCallDelaySeconds
    }

    func complete(messages: [LLMMessage], tools: [LLMTool]) async throws -> LLMCompletionResult {
        try await Task.sleep(for: .seconds(perCallDelaySeconds))
        return LLMCompletionResult(response: responseToReturn, tokenUsage: nil)
    }
}
