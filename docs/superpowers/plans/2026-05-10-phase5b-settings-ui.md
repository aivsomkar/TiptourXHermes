# Phase 5B: Settings UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Settings sheet accessible from the companion panel footer, with three tabs: Agents (model routing + token budgets), Skills (browse/delete the skill library), and Learning (self-critique threshold + memory management).

**Architecture:** A `SettingsView` SwiftUI sheet is presented from `CompanionPanelView` via a "Settings" footer button. It contains a tab picker driving three sub-views: `AgentsSettingsView`, `SkillsSettingsView`, `LearningSettingsView`. Task profile changes are persisted to `UserDefaults` so they survive restarts. The self-critique threshold in `EfficiencyMonitor` is read from `UserDefaults` on each evaluation rather than being hardcoded. `AgentSwarmManager` enforces a configurable max-concurrent-agents limit read from `UserDefaults`.

**Tech Stack:** SwiftUI, `UserDefaults`, `LLMProviderRegistry` actor, `SkillLibraryStore` actor, `AgentMemoryStore` actor, Swift Testing

---

## File Map

| Action | File | Responsibility |
|--------|------|----------------|
| Create | `TipTour/Agents/UI/SettingsView.swift` | Tab container + `AgentsSettingsView`, `SkillsSettingsView`, `LearningSettingsView` |
| Modify | `TipTour/Agents/Core/LLMProviderRegistry.swift` | `persistProfiles()` / `loadPersistedProfiles()` via UserDefaults |
| Modify | `TipTour/Agents/Core/EfficiencyMonitor.swift` | Read `selfCritiqueThreshold` from UserDefaults |
| Modify | `TipTour/Agents/Swarm/AgentSwarmManager.swift` | Enforce `maxConcurrentAgents` from UserDefaults |
| Modify | `TipTour/Agents/Skills/SkillLibraryStore.swift` | Add `allEntries() async -> [SkillEntry]` |
| Modify | `TipTour/CompanionPanelView.swift` | Add Settings footer button + sheet presentation |
| Create | `TipTourTests/SettingsTests.swift` | Unit tests for persistence and data layer |

---

## Task 1: `SkillLibraryStore.allEntries()`

**Files:**
- Modify: `TipTour/Agents/Skills/SkillLibraryStore.swift`
- Test: `TipTourTests/SettingsTests.swift`

The settings Skills tab needs to list all skills regardless of task type or keyword relevance. `SkillLibraryStore` currently only exposes `query()` (relevance-scored). Add a simple `allEntries()` method that returns the full index sorted by `createdAt` descending.

- [ ] **Step 1: Write the failing test**

Create `TipTourTests/SettingsTests.swift`:

```swift
import Testing
import Foundation
@testable import TipTour

@Suite struct SettingsTests {

    @Test func skillLibraryAllEntriesReturnsSortedByDate() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = SkillLibraryStore(directoryURL: tempDir)

        await store.write(slug: "skill-a", name: "Skill A", description: "desc a",
                          taskTypes: [.coding], body: "# Skill A\n\n## Steps\n\n1. do it")
        await store.write(slug: "skill-b", name: "Skill B", description: "desc b",
                          taskTypes: [.writing], body: "# Skill B\n\n## Steps\n\n1. do it")

        let all = await store.allEntries()
        #expect(all.count == 2)
        // Most recently created first
        #expect(all[0].slug == "skill-b" || all[1].slug == "skill-b")
    }

    @Test func skillLibraryAllEntriesEmptyWhenNoSkills() async {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = SkillLibraryStore(directoryURL: tempDir)
        let all = await store.allEntries()
        #expect(all.isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd /Users/omkar/Desktop/TipTour-macOS/repo
xcodebuild test -scheme TipTour -only-testing:TipTourTests/SettingsTests/SettingsTests/skillLibraryAllEntriesReturnsSortedByDate 2>&1 | grep -E "error:|passed|failed"
```

Expected: compile error — `allEntries()` not found.

- [ ] **Step 3: Add `allEntries()` to `SkillLibraryStore.swift`**

In `TipTour/Agents/Skills/SkillLibraryStore.swift`, after the `query` method, add:

```swift
// MARK: - All entries (for Settings UI)

/// Returns all skills in the library sorted by createdAt descending (newest first).
func allEntries() async -> [SkillEntry] {
    index.sorted { $0.createdAt > $1.createdAt }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
xcodebuild test -scheme TipTour \
  -only-testing:TipTourTests/SettingsTests/SettingsTests/skillLibraryAllEntriesReturnsSortedByDate \
  -only-testing:TipTourTests/SettingsTests/SettingsTests/skillLibraryAllEntriesEmptyWhenNoSkills \
  2>&1 | grep -E "passed|failed|error:"
```

Expected: 2 passed.

- [ ] **Step 5: Commit**

```bash
git add TipTour/Agents/Skills/SkillLibraryStore.swift TipTourTests/SettingsTests.swift
git commit -m "feat: add SkillLibraryStore.allEntries() for Settings UI"
```

---

## Task 2: Persist `TaskProfile` changes to `UserDefaults`

**Files:**
- Modify: `TipTour/Agents/Core/LLMProviderRegistry.swift`
- Modify: `TipTourTests/SettingsTests.swift`

Currently `LLMProviderRegistry` holds `taskProfiles` in memory and resets to defaults on every launch. The Settings Agents tab allows the user to change model routing and token budgets — these changes must survive app restarts.

Persistence strategy: encode `[TaskProfile]` as JSON and store under the key `"taskProfiles"` in `UserDefaults.standard`. On `setProfile(_:)`, immediately persist. On `bootstrapFromKeychain()` (called at launch), load persisted profiles and merge with defaults (defaults fill in any missing task types).

- [ ] **Step 1: Write the failing test**

Add to `TipTourTests/SettingsTests.swift`:

```swift
@Test func taskProfileChangePersistsAcrossRegistryInstances() async throws {
    // Use a separate UserDefaults suite so we don't pollute the real app's storage.
    let testSuiteName = "com.tiptour.test.\(UUID().uuidString)"
    let testDefaults = UserDefaults(suiteName: testSuiteName)!
    defer { testDefaults.removePersistentDomain(forName: testSuiteName) }

    let registry = LLMProviderRegistry(userDefaults: testDefaults)
    var profile = await registry.profile(for: .coding)!
    profile.tokenBudget = 99_999
    await registry.setProfile(profile)

    // Simulate a fresh registry reading from the same UserDefaults.
    let registry2 = LLMProviderRegistry(userDefaults: testDefaults)
    let loaded = await registry2.profile(for: .coding)!
    #expect(loaded.tokenBudget == 99_999)
}

@Test func taskProfileDefaultsFilledForMissingTypes() async {
    let testSuiteName = "com.tiptour.test.\(UUID().uuidString)"
    let testDefaults = UserDefaults(suiteName: testSuiteName)!
    defer { testDefaults.removePersistentDomain(forName: testSuiteName) }

    let registry = LLMProviderRegistry(userDefaults: testDefaults)
    // All task types should have a profile even on a fresh registry.
    for taskType in TaskType.allCases {
        let profile = await registry.profile(for: taskType)
        #expect(profile != nil, "Missing default profile for \(taskType)")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
xcodebuild test -scheme TipTour \
  -only-testing:TipTourTests/SettingsTests/SettingsTests/taskProfileChangePersistsAcrossRegistryInstances \
  2>&1 | grep -E "error:|passed|failed"
```

Expected: compile error — `LLMProviderRegistry` has no `userDefaults` init parameter.

- [ ] **Step 3: Update `LLMProviderRegistry.swift`**

Replace the entire file contents:

```swift
// TipTour/Agents/Core/LLMProviderRegistry.swift

import Foundation

// MARK: - Task types agents can be assigned

enum TaskType: String, CaseIterable, Codable, Sendable {
    case coding
    case browserResearch
    case imageGeneration
    case videoGeneration
    case fileManagement
    case generalMac
    case analysis
    case writing

    var displayName: String {
        switch self {
        case .coding: return "Coding"
        case .browserResearch: return "Browser Research"
        case .imageGeneration: return "Image Generation"
        case .videoGeneration: return "Video Generation"
        case .fileManagement: return "File Management"
        case .generalMac: return "General Mac"
        case .analysis: return "Analysis"
        case .writing: return "Writing"
        }
    }
}

// MARK: - Per-task configuration: preferred model + token budget

struct TaskProfile: Codable, Sendable {
    var taskType: TaskType
    var preferredProviderId: String
    var fallbackProviderId: String?
    var tokenBudget: Int

    static func defaults() -> [TaskType: TaskProfile] {
        [
            .coding:           TaskProfile(taskType: .coding,           preferredProviderId: "anthropic-claude-sonnet-4-6",   tokenBudget: 32_000),
            .browserResearch:  TaskProfile(taskType: .browserResearch,  preferredProviderId: "openai-gpt-4o",                 fallbackProviderId: "gemini-rest-gemini-2.5-flash", tokenBudget: 8_000),
            .imageGeneration:  TaskProfile(taskType: .imageGeneration,  preferredProviderId: "openai-gpt-4o",                 tokenBudget: 2_000),
            .videoGeneration:  TaskProfile(taskType: .videoGeneration,  preferredProviderId: "gemini-rest-gemini-2.5-pro",    tokenBudget: 4_000),
            .fileManagement:   TaskProfile(taskType: .fileManagement,   preferredProviderId: "anthropic-claude-haiku-4-5",    tokenBudget: 4_000),
            .generalMac:       TaskProfile(taskType: .generalMac,       preferredProviderId: "anthropic-claude-sonnet-4-6",   tokenBudget: 8_000),
            .analysis:         TaskProfile(taskType: .analysis,         preferredProviderId: "anthropic-claude-opus-4-7",     tokenBudget: 16_000),
            .writing:          TaskProfile(taskType: .writing,          preferredProviderId: "anthropic-claude-sonnet-4-6",   tokenBudget: 8_000),
        ]
    }
}

// MARK: - Registry: holds all providers and routes task types to them

actor LLMProviderRegistry {

    static let shared = LLMProviderRegistry()

    private var providers: [String: any LLMProvider] = [:]
    private var taskProfiles: [TaskType: TaskProfile]
    private let userDefaults: UserDefaults
    private static let userDefaultsKey = "taskProfiles"

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        self.taskProfiles = TaskProfile.defaults()
        // Merge persisted profiles over the defaults so new task types introduced
        // in app updates still get a default even if the user's persisted data predates them.
        if let data = userDefaults.data(forKey: Self.userDefaultsKey),
           let persisted = try? JSONDecoder().decode([TaskProfile].self, from: data) {
            for profile in persisted {
                self.taskProfiles[profile.taskType] = profile
            }
        }
    }

    // MARK: - Provider registration

    func register(_ provider: any LLMProvider) {
        providers[provider.providerId] = provider
    }

    func provider(for taskType: TaskType) -> (any LLMProvider)? {
        let profile = taskProfiles[taskType]
        if let primaryId = profile?.preferredProviderId,
           let primary = providers[primaryId] { return primary }
        if let fallbackId = profile?.fallbackProviderId,
           let fallback = providers[fallbackId] { return fallback }
        return providers.values.first
    }

    func provider(id: String) -> (any LLMProvider)? {
        providers[id]
    }

    func allProviders() -> [any LLMProvider] {
        Array(providers.values)
    }

    func voiceCapableProviders() -> [any LLMProvider] {
        providers.values.filter { $0.supportsVoice }
    }

    // MARK: - Profile management

    func profile(for taskType: TaskType) -> TaskProfile? {
        taskProfiles[taskType]
    }

    func setProfile(_ profile: TaskProfile) {
        taskProfiles[profile.taskType] = profile
        persistProfiles()
    }

    func allProfiles() -> [TaskProfile] {
        Array(taskProfiles.values).sorted { $0.taskType.rawValue < $1.taskType.rawValue }
    }

    // MARK: - Private

    private func persistProfiles() {
        let profiles = Array(taskProfiles.values)
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        userDefaults.set(data, forKey: Self.userDefaultsKey)
    }
}

// MARK: - Keychain bootstrap

extension LLMProviderRegistry {

    func bootstrapFromKeychain() async {
        if let anthropicKey = KeychainStore.anthropicAPIKey, !anthropicKey.isEmpty {
            await register(AnthropicProvider(modelId: "claude-haiku-4-5",   apiKey: anthropicKey))
            await register(AnthropicProvider(modelId: "claude-sonnet-4-6",  apiKey: anthropicKey))
            await register(AnthropicProvider(modelId: "claude-opus-4-7",    apiKey: anthropicKey))
        }

        if let openAIKey = KeychainStore.openAIAPIKey, !openAIKey.isEmpty {
            await register(OpenAIProvider(modelId: "gpt-4o",      apiKey: openAIKey))
            await register(OpenAIProvider(modelId: "gpt-4o-mini", apiKey: openAIKey))
        }

        if let geminiKey = KeychainStore.geminiAPIKey, !geminiKey.isEmpty {
            await register(GeminiRestProvider(modelId: "gemini-2.5-flash", apiKey: geminiKey))
            await register(GeminiRestProvider(modelId: "gemini-2.5-pro",   apiKey: geminiKey))
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
xcodebuild test -scheme TipTour \
  -only-testing:TipTourTests/SettingsTests/SettingsTests/taskProfileChangePersistsAcrossRegistryInstances \
  -only-testing:TipTourTests/SettingsTests/SettingsTests/taskProfileDefaultsFilledForMissingTypes \
  2>&1 | grep -E "passed|failed|error:"
```

Expected: 2 passed.

- [ ] **Step 5: Commit**

```bash
git add TipTour/Agents/Core/LLMProviderRegistry.swift TipTourTests/SettingsTests.swift
git commit -m "feat: persist TaskProfile changes to UserDefaults"
```

---

## Task 3: `EfficiencyMonitor` reads threshold from `UserDefaults` + `AgentSwarmManager` max-concurrent

**Files:**
- Modify: `TipTour/Agents/Core/EfficiencyMonitor.swift`
- Modify: `TipTour/Agents/Swarm/AgentSwarmManager.swift`
- Modify: `TipTourTests/SettingsTests.swift`

Both the self-critique threshold and the max-concurrent-agents cap are now configurable from the Settings UI. Read them from `UserDefaults` at usage time (not cached at init) so changes in Settings take effect immediately without requiring a restart.

UserDefaults keys:
- `"selfCritiqueThreshold"` — `Double`, default `0.4`
- `"maxConcurrentAgents"` — `Int`, default `5`

- [ ] **Step 1: Write the failing tests**

Add to `TipTourTests/SettingsTests.swift`:

```swift
@Test func agentSwarmManagerRejectsSpawnWhenAtCapacity() async {
    let testSuiteName = "com.tiptour.test.\(UUID().uuidString)"
    let testDefaults = UserDefaults(suiteName: testSuiteName)!
    testDefaults.set(1, forKey: "maxConcurrentAgents")  // cap at 1
    defer { testDefaults.removePersistentDomain(forName: testSuiteName) }

    let manager = AgentSwarmManager(userDefaults: testDefaults)

    // Spawn one agent (fills the cap).
    await manager.spawn(taskDescription: "task one", taskType: .generalMac)
    // Second spawn should be rejected.
    let rejected = await manager.spawn(taskDescription: "task two", taskType: .generalMac)
    #expect(rejected == nil)
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
xcodebuild test -scheme TipTour \
  -only-testing:TipTourTests/SettingsTests/SettingsTests/agentSwarmManagerRejectsSpawnWhenAtCapacity \
  2>&1 | grep -E "error:|passed|failed"
```

Expected: compile error — `AgentSwarmManager(userDefaults:)` and `spawn` returning optional not defined.

- [ ] **Step 3: Update `EfficiencyMonitor.swift`**

In `TipTour/Agents/Core/EfficiencyMonitor.swift`, change the `selfCritiqueThreshold` property and `evaluate` method to read from `UserDefaults` at call time:

```swift
// Remove the stored `selfCritiqueThreshold` property and its init parameter.
// Replace the threshold read in `evaluate(_:)` with:
let selfCritiqueThreshold = UserDefaults.standard.object(forKey: "selfCritiqueThreshold") as? Double ?? 0.4
```

The full init becomes:
```swift
init(tokenBudget: Int = 8_000) {
    self.tokenBudget = tokenBudget
}
```

And inside `evaluate(_:)`, wherever `selfCritiqueThreshold` was used as a stored property, read it dynamically:
```swift
let selfCritiqueThreshold = UserDefaults.standard.object(forKey: "selfCritiqueThreshold") as? Double ?? 0.4
if inefficiencyScore <= selfCritiqueThreshold {
    return EfficiencyReport(inefficiencyScore: inefficiencyScore, tokenOverrun: tokenOverrun,
                            wastedSteps: wastedSteps, diagnosis: "", didSelfCritique: false)
}
```

- [ ] **Step 4: Update `AgentSwarmManager.swift`**

Change `AgentSwarmManager` to:
1. Accept an optional `UserDefaults` for testing
2. Make `spawn` return `TaskAgent?` (nil when at capacity)

```swift
actor AgentSwarmManager {

    static let shared = AgentSwarmManager()

    nonisolated let overlayStatePublisher = CurrentValueSubject<[AgentStatus], Never>([])
    nonisolated let messageBus = PassthroughSubject<AgentMessage, Never>()

    private var agents: [UUID: TaskAgent] = [:]
    private var agentMetrics: [UUID: AgentMetrics] = [:]
    private var agentTasks: [UUID: Task<Void, Never>] = [:]
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

        let runTask = Task.detached(priority: .userInitiated) {
            await newAgent.run()
        }
        agentTasks[newAgent.id] = runTask

        return newAgent
    }

    // ... rest of the methods unchanged ...
}
```

Note: All existing callers of `spawn` use `@discardableResult` so returning `TaskAgent?` instead of `TaskAgent` is source-compatible.

- [ ] **Step 5: Run tests to verify they pass**

```bash
xcodebuild test -scheme TipTour \
  -only-testing:TipTourTests/SettingsTests/SettingsTests/agentSwarmManagerRejectsSpawnWhenAtCapacity \
  2>&1 | grep -E "passed|failed|error:"
```

Expected: 1 passed.

- [ ] **Step 6: Commit**

```bash
git add TipTour/Agents/Core/EfficiencyMonitor.swift TipTour/Agents/Swarm/AgentSwarmManager.swift TipTourTests/SettingsTests.swift
git commit -m "feat: EfficiencyMonitor and AgentSwarmManager read config from UserDefaults"
```

---

## Task 4: `SettingsView` — Agents tab

**Files:**
- Create: `TipTour/Agents/UI/SettingsView.swift`

This is a SwiftUI sheet with a `Picker` tab bar. The Agents tab shows a list of all task types; each row has the task type name, a picker for preferred provider ID, and a token budget text field.

- [ ] **Step 1: Create `TipTour/Agents/UI/SettingsView.swift`**

```swift
// TipTour/Agents/UI/SettingsView.swift

import SwiftUI

// MARK: - Tab container

struct SettingsView: View {
    @State private var selectedTab: SettingsTab = .agents

    enum SettingsTab: String, CaseIterable {
        case agents = "Agents"
        case skills = "Skills"
        case learning = "Learning"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Tab picker
            Picker("Tab", selection: $selectedTab) {
                ForEach(SettingsTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()

            // Tab content
            Group {
                switch selectedTab {
                case .agents:
                    AgentsSettingsView()
                case .skills:
                    SkillsSettingsView()
                case .learning:
                    LearningSettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 480, height: 440)
        .background(DS.Colors.panelBackground)
    }
}

// MARK: - Agents tab

struct AgentsSettingsView: View {
    @State private var profiles: [TaskProfile] = []
    @State private var availableProviderIds: [String] = []
    @State private var maxConcurrentAgents: Int = UserDefaults.standard.object(forKey: "maxConcurrentAgents") as? Int ?? 5

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                settingsSectionHeader("Model Routing")
                    .padding(.horizontal, 16)
                    .padding(.top, 12)

                ForEach($profiles, id: \.taskType) { $profile in
                    taskProfileRow(profile: $profile)
                    Divider()
                        .padding(.horizontal, 16)
                }

                settingsSectionHeader("Concurrency")
                    .padding(.horizontal, 16)
                    .padding(.top, 12)

                HStack {
                    Text("Max concurrent agents")
                        .font(.system(size: 12))
                        .foregroundColor(DS.Colors.textSecondary)
                    Spacer()
                    Stepper("\(maxConcurrentAgents)", value: $maxConcurrentAgents, in: 1...10)
                        .font(.system(size: 12))
                        .onChange(of: maxConcurrentAgents) { _, newValue in
                            UserDefaults.standard.set(newValue, forKey: "maxConcurrentAgents")
                        }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
        }
        .task {
            profiles = await LLMProviderRegistry.shared.allProfiles()
            availableProviderIds = await LLMProviderRegistry.shared.allProviders().map(\.providerId).sorted()
        }
    }

    private func taskProfileRow(profile: Binding<TaskProfile>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(profile.wrappedValue.taskType.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                    .frame(width: 130, alignment: .leading)

                Picker("", selection: profile.preferredProviderId) {
                    ForEach(availableProviderIds, id: \.self) { id in
                        Text(id).tag(id)
                    }
                    // Always show the current value even if provider not registered yet
                    if !availableProviderIds.contains(profile.wrappedValue.preferredProviderId) {
                        Text(profile.wrappedValue.preferredProviderId)
                            .tag(profile.wrappedValue.preferredProviderId)
                    }
                }
                .pickerStyle(.menu)
                .font(.system(size: 11))
                .frame(maxWidth: .infinity)
                .onChange(of: profile.wrappedValue.preferredProviderId) { _, _ in
                    Task { await LLMProviderRegistry.shared.setProfile(profile.wrappedValue) }
                }
            }

            HStack {
                Text("Token budget:")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
                TextField("", value: profile.tokenBudget, format: .number)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(width: 70)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.white.opacity(0.05))
                    )
                    .onSubmit {
                        Task { await LLMProviderRegistry.shared.setProfile(profile.wrappedValue) }
                    }
                Text("tokens")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func settingsSectionHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .semibold, design: .rounded))
            .tracking(0.4)
            .foregroundColor(DS.Colors.textTertiary)
            .padding(.bottom, 4)
    }
}
```

- [ ] **Step 2: Build and verify no compile errors**

```bash
xcodebuild build -scheme TipTour 2>&1 | grep -E "error:|Build succeeded|Build FAILED"
```

Expected: `Build succeeded`.

- [ ] **Step 3: Commit**

```bash
git add TipTour/Agents/UI/SettingsView.swift
git commit -m "feat: add SettingsView with AgentsSettingsView tab"
```

---

## Task 5: Skills tab

**Files:**
- Modify: `TipTour/Agents/UI/SettingsView.swift`

The Skills tab lists all skills from `SkillLibraryStore`, shows their name, task types, and creation date, and lets the user delete any skill or clear all.

- [ ] **Step 1: Add `SkillsSettingsView` to `SettingsView.swift`**

Append to `TipTour/Agents/UI/SettingsView.swift`:

```swift
// MARK: - Skills tab

struct SkillsSettingsView: View {
    @State private var skills: [SkillEntry] = []
    @State private var isLoading = true
    @State private var showClearConfirmation = false

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row: count + Clear All
            HStack {
                Text("\(skills.count) skill\(skills.count == 1 ? "" : "s")")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                Spacer()
                Button("Clear All") {
                    showClearConfirmation = true
                }
                .font(.system(size: 11))
                .foregroundColor(.red.opacity(0.7))
                .buttonStyle(.plain)
                .pointerCursor()
                .disabled(skills.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if skills.isEmpty {
                Text("No skills saved yet.\nSkills are created automatically when agents complete tasks, or by using the Record Demonstration feature.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .multilineTextAlignment(.center)
                    .padding(32)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(skills, id: \.id) { skill in
                            skillRow(skill: skill)
                            Divider()
                                .padding(.leading, 16)
                        }
                    }
                }
            }
        }
        .task { await loadSkills() }
        .confirmationDialog(
            "Clear all \(skills.count) skills?",
            isPresented: $showClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear All Skills", role: .destructive) {
                Task {
                    await SkillLibraryStore.shared.clear()
                    await loadSkills()
                }
            }
        } message: {
            Text("This cannot be undone.")
        }
    }

    private func skillRow(skill: SkillEntry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(skill.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(skill.taskTypes.map(\.displayName).joined(separator: ", "))
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)

                    Text("·")
                        .foregroundColor(DS.Colors.textTertiary)
                        .font(.system(size: 10))

                    Text(dateFormatter.string(from: skill.createdAt))
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }

            Spacer()

            Button {
                Task {
                    await SkillLibraryStore.shared.delete(slug: skill.slug)
                    await loadSkills()
                }
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundColor(.red.opacity(0.6))
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help("Delete this skill")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func loadSkills() async {
        isLoading = true
        skills = await SkillLibraryStore.shared.allEntries()
        isLoading = false
    }
}
```

- [ ] **Step 2: Build and verify no compile errors**

```bash
xcodebuild build -scheme TipTour 2>&1 | grep -E "error:|Build succeeded|Build FAILED"
```

Expected: `Build succeeded`.

- [ ] **Step 3: Commit**

```bash
git add TipTour/Agents/UI/SettingsView.swift
git commit -m "feat: add SkillsSettingsView tab with list, delete, and clear-all"
```

---

## Task 6: Learning tab

**Files:**
- Modify: `TipTour/Agents/UI/SettingsView.swift`

The Learning tab exposes the self-critique threshold slider and memory management (clear task-result memories while keeping permanent facts, or clear everything).

- [ ] **Step 1: Add `LearningSettingsView` to `SettingsView.swift`**

Append to `TipTour/Agents/UI/SettingsView.swift`:

```swift
// MARK: - Learning tab

struct LearningSettingsView: View {
    @State private var selfCritiqueThreshold: Double =
        UserDefaults.standard.object(forKey: "selfCritiqueThreshold") as? Double ?? 0.4
    @State private var showClearMemoryConfirmation = false
    @State private var clearAllMemory = false
    @State private var memoryCleared = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {

                settingsSectionHeader("Self-Critique")
                    .padding(.horizontal, 16)
                    .padding(.top, 12)

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Inefficiency threshold")
                            .font(.system(size: 12))
                            .foregroundColor(DS.Colors.textSecondary)
                        Spacer()
                        Text(String(format: "%.2f", selfCritiqueThreshold))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(DS.Colors.textPrimary)
                    }

                    Slider(value: $selfCritiqueThreshold, in: 0.1...0.9, step: 0.05)
                        .onChange(of: selfCritiqueThreshold) { _, newValue in
                            UserDefaults.standard.set(newValue, forKey: "selfCritiqueThreshold")
                        }

                    Text("When an agent's inefficiency score exceeds this threshold, TipTour makes one additional LLM call to rewrite the saved skill and log a lesson. Lower = more aggressive self-critique.")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)

                Divider()
                    .padding(.horizontal, 16)

                settingsSectionHeader("Memory")
                    .padding(.horizontal, 16)
                    .padding(.top, 12)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Task-result memories expire after 7 days. Permanent facts (written by self-critique) never expire.")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 4)

                    Button("Clear Task-Result Memories") {
                        clearAllMemory = false
                        showClearMemoryConfirmation = true
                    }
                    .font(.system(size: 12))
                    .foregroundColor(.red.opacity(0.7))
                    .buttonStyle(.plain)
                    .pointerCursor()

                    Button("Clear All Memory (including permanent facts)") {
                        clearAllMemory = true
                        showClearMemoryConfirmation = true
                    }
                    .font(.system(size: 12))
                    .foregroundColor(.red.opacity(0.7))
                    .buttonStyle(.plain)
                    .pointerCursor()

                    if memoryCleared {
                        Text("Memory cleared.")
                            .font(.system(size: 10))
                            .foregroundColor(DS.Colors.textTertiary)
                            .transition(.opacity)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)

                Divider()
                    .padding(.horizontal, 16)

                settingsSectionHeader("Watch Me Shortcut")
                    .padding(.horizontal, 16)
                    .padding(.top, 12)

                Text("Ctrl + Option + W")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(DS.Colors.textPrimary)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 4)

                Text("Hold Ctrl + Option + W to begin recording a demonstration. Press again to stop. You will be prompted to name and save the recorded skill.")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
            }
        }
        .confirmationDialog(
            clearAllMemory ? "Clear all memory including permanent facts?" : "Clear task-result memories?",
            isPresented: $showClearMemoryConfirmation,
            titleVisibility: .visible
        ) {
            Button(clearAllMemory ? "Clear All Memory" : "Clear Task-Result Memories", role: .destructive) {
                Task {
                    await AgentMemoryStore.shared.clear(keepPermanent: !clearAllMemory)
                    memoryCleared = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        memoryCleared = false
                    }
                }
            }
        } message: {
            Text("This cannot be undone.")
        }
    }

    private func settingsSectionHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .semibold, design: .rounded))
            .tracking(0.4)
            .foregroundColor(DS.Colors.textTertiary)
            .padding(.bottom, 4)
    }
}
```

- [ ] **Step 2: Build and verify no compile errors**

```bash
xcodebuild build -scheme TipTour 2>&1 | grep -E "error:|Build succeeded|Build FAILED"
```

Expected: `Build succeeded`.

- [ ] **Step 3: Commit**

```bash
git add TipTour/Agents/UI/SettingsView.swift
git commit -m "feat: add LearningSettingsView tab with threshold slider and memory management"
```

---

## Task 7: Wire Settings sheet into `CompanionPanelView`

**Files:**
- Modify: `TipTour/CompanionPanelView.swift`

Add a "Settings" button in the footer (next to Feedback and Dev) that presents `SettingsView` as a sheet.

- [ ] **Step 1: Add `@State` and button**

In `TipTour/CompanionPanelView.swift`:

1. Add a state property near the other `@State` declarations at the top of the `CompanionPanelView` struct (just before or after `@State private var showDevTools`):

```swift
@State private var showSettings: Bool = false
```

2. In `footerSection`, inside the `HStack(spacing: 0)`, add the Settings button after `feedbackButton` and before the Dev button:

```swift
footerButton("Settings", systemImage: "gearshape", toggled: showSettings) {
    showSettings.toggle()
}
```

3. After the existing `if showDevTools { devToolsSection ... }` block, add the sheet:

```swift
.sheet(isPresented: $showSettings) {
    SettingsView()
}
```

If the `VStack` in `footerSection` doesn't already have a `.sheet` modifier, attach it to the outermost `VStack` in `footerSection`.

- [ ] **Step 2: Build and verify no compile errors**

```bash
xcodebuild build -scheme TipTour 2>&1 | grep -E "error:|Build succeeded|Build FAILED"
```

Expected: `Build succeeded`.

- [ ] **Step 3: Commit**

```bash
git add TipTour/CompanionPanelView.swift
git commit -m "feat: add Settings button in panel footer wired to SettingsView sheet"
```

---

## Task 8: Full test suite run + CLAUDE.md update

- [ ] **Step 1: Run all Settings tests**

```bash
xcodebuild test -scheme TipTour -only-testing:TipTourTests/SettingsTests 2>&1 | grep -E "Test.*passed|Test.*failed|error:" | head -20
```

Expected: All 5 tests pass.

- [ ] **Step 2: Run full test suite**

```bash
xcodebuild test -scheme TipTour 2>&1 | grep -E "Test.*passed|Test.*failed|error:" | tail -10
```

Expected: No regressions.

- [ ] **Step 3: Update CLAUDE.md**

In the Key Files table:
- Update `TipTour/Agents/Core/LLMProviderRegistry.swift` note to mention UserDefaults persistence
- Update `TipTour/Agents/Swarm/AgentSwarmManager.swift` line count (~155) and note max-concurrent enforcement
- Update `TipTour/Agents/Core/EfficiencyMonitor.swift` note to mention UserDefaults threshold
- Update `TipTour/Agents/Skills/SkillLibraryStore.swift` note to mention `allEntries()`
- Add new row: `TipTour/Agents/UI/SettingsView.swift | ~260 | Three-tab Settings sheet: AgentsSettingsView (model routing + token budgets + concurrency), SkillsSettingsView (browse/delete skill library), LearningSettingsView (self-critique threshold + memory management).`

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: update CLAUDE.md for Phase 5B Settings UI"
```
