import Testing
import Foundation
@testable import TipTour

@Suite struct IntegrationPolishTests {

    // MARK: - Task 1: GeminiLiveClient declares spawn_background_task tool

    @Test func geminiLiveClientDecloresSpawnBackgroundTaskTool() {
        let tool = GeminiLiveClient.spawnBackgroundTaskToolDeclaration
        #expect((tool["name"] as? String) == "spawn_background_task")
        let params = tool["parameters"] as? [String: Any]
        let props = params?["properties"] as? [String: Any]
        #expect(props?["task"] != nil)
        #expect(props?["task_type"] != nil)
        let required = params?["required"] as? [String]
        #expect(required?.contains("task") == true)
        #expect(required?.contains("task_type") == true)
    }

    // MARK: - Task 2: GeminiLiveSession routes spawn_background_task

    @Test @MainActor func geminiLiveSessionFiresSpawnCallbackOnSpawnTool() async {
        let session = GeminiLiveSession(
            apiKeyURL: "https://example.com/fake-key",
            systemPrompt: "test"
        )

        var capturedTask: String?
        var capturedTaskType: String?
        session.onSpawnBackgroundTask = { task, taskType in
            capturedTask = task
            capturedTaskType = taskType
            return ["ok": true, "message": "spawned"]
        }

        session.simulateToolCall(
            id: "call-1",
            name: "spawn_background_task",
            args: ["task": "search for trending Swift libraries", "task_type": "browserResearch"]
        )

        // Give the Task { } inside handleToolCall time to run.
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(capturedTask == "search for trending Swift libraries")
        #expect(capturedTaskType == "browserResearch")
    }

    // MARK: - Task 5: AgentMemoryStore.pruneExpired()

    @Test func agentMemoryStorePrunesExpiredOnExplicitCall() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = tempDir.appendingPathComponent("memory.json")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = AgentMemoryStore(fileURL: fileURL)

        // Write an already-expired entry via JSON round-trip to set a past expiresAt.
        let baseEntry = AgentMemoryEntry.makeTaskResult(content: "old result", taskTypes: [.generalMac])
        let pastExpiry = Calendar.current.date(byAdding: .day, value: -10, to: Date())!
        var encodedEntry = try JSONEncoder().encode(baseEntry)
        var dict = try JSONSerialization.jsonObject(with: encodedEntry) as! [String: Any]
        dict["expiresAt"] = ISO8601DateFormatter().string(from: pastExpiry)
        encodedEntry = try JSONSerialization.data(withJSONObject: dict)
        let expiredEntry = try JSONDecoder().decode(AgentMemoryEntry.self, from: encodedEntry)

        await store.writeRawEntry(expiredEntry)
        await store.write(content: "permanent fact", entryType: .fact,
                          taskTypes: [.generalMac], permanent: true)

        // After prune: only permanent remains.
        await store.pruneExpired()
        let afterPrune = await store.query(taskDescription: "permanent", taskTypes: [.generalMac], limit: 50)
        #expect(afterPrune.count == 1)
        #expect(afterPrune[0].isPermanent)
    }
}
