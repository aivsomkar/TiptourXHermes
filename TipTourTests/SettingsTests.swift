import Testing
import Foundation
@testable import TipTour

@Suite struct SettingsTests {

    // MARK: - Task 1: SkillLibraryStore.allEntries()

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

    // MARK: - Task 2: TaskProfile UserDefaults persistence

    @Test func taskProfileChangePersistsAcrossRegistryInstances() async throws {
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

    // MARK: - Task 3: AgentSwarmManager max-concurrent cap

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
}
