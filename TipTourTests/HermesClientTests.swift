import XCTest
import Combine
@testable import TipTour

final class HermesClientTests: XCTestCase {

    @MainActor
    func testNewClientHasEmptyState() async {
        let client = HermesClient()
        XCTAssertTrue(client.transcript.isEmpty)
        XCTAssertFalse(client.isWorking)
        XCTAssertNil(client.lastError)
    }

    /// First send with HERMES_HOME pointing at an empty temp dir
    /// should surface Hermes's "No LLM provider configured" error as
    /// a .system turn rather than hanging.
    @MainActor
    func testFirstSendWithMissingConfigSurfacesSystemTurn() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("hermes-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let client = HermesClient(hermesHome: tmp)
        await client.send("hello")
        // After send returns we expect exactly:
        //   transcript[0] = .user("hello")
        //   transcript[1] = .system("Hermes error: …")
        XCTAssertEqual(client.transcript.count, 2)
        if case .user(_, let t) = client.transcript[0] {
            XCTAssertEqual(t, "hello")
        } else { XCTFail("expected .user at index 0") }
        if case .system(_, let text) = client.transcript[1] {
            XCTAssertTrue(text.lowercased().contains("hermes error"))
            XCTAssertTrue(text.lowercased().contains("provider") || text.lowercased().contains("config"))
        } else { XCTFail("expected .system at index 1") }
        client.stop()
    }

    /// Helper: returns true iff Hermes is configured locally —
    /// ~/.hermes/config.yaml exists AND a provider key is in env.
    /// Matches Tests/Python/smoke_test_acp.py's gate.
    private func hermesConfiguredLocally() -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let configExists = FileManager.default.fileExists(
            atPath: home.appendingPathComponent(".hermes/config.yaml").path
        )
        let keys = ["GEMINI_API_KEY", "OPENAI_API_KEY", "ANTHROPIC_API_KEY"]
        let hasKey = keys.contains { ProcessInfo.processInfo.environment[$0] != nil }
        return configExists && hasKey
    }

    @MainActor
    func testLiveAgentRoundTripProducesAgentTurn() async throws {
        try XCTSkipUnless(hermesConfiguredLocally(),
                          "Hermes not configured locally (no ~/.hermes/config.yaml or no provider key in env)")
        let client = HermesClient()
        await client.send("Reply with the single word 'pong'.")
        // Find at least one .agent turn.
        let agentTurn = client.transcript.first { turn in
            if case .agent = turn { return true } else { return false }
        }
        XCTAssertNotNil(agentTurn, "no agent turn appeared in transcript")
        if case .agent(_, let text, _) = agentTurn {
            XCTAssertFalse(text.isEmpty)
        }
        XCTAssertFalse(client.isWorking)
        client.stop()
    }

    @MainActor
    func testLiveToolUsingPromptPopulatesToolCalls() async throws {
        try XCTSkipUnless(hermesConfiguredLocally(),
                          "Hermes not configured locally")
        let client = HermesClient()
        await client.send("Use the shell tool to print 'plan2 ok'. Do not summarise.")
        let agent = client.transcript.first { if case .agent = $0 { return true } else { return false } }
        XCTAssertNotNil(agent)
        if case .agent(_, _, let toolCalls) = agent {
            XCTAssertFalse(toolCalls.isEmpty,
                           "expected at least one tool call when prompted to use a tool")
        }
        client.stop()
    }

    @MainActor
    func testStopIsIdempotentAndKillsTheProcess() async throws {
        let client = HermesClient()
        // Trigger subprocess launch even in the missing-config case —
        // the failure path still leaves no process running; the happy
        // path leaves one we then stop.
        await client.send("any text")
        let beforeStop = countHermesProcesses()
        client.stop()
        // After stop, wait briefly for the OS to reap.
        try await Task.sleep(nanoseconds: 500_000_000)
        let afterStop = countHermesProcesses()
        XCTAssertLessThanOrEqual(afterStop, beforeStop,
            "stop() did not reduce hermes-runtime process count (was \(beforeStop), now \(afterStop))")
        // Calling stop() again should be a no-op.
        client.stop()
        client.stop()
    }

    private func countHermesProcesses() -> Int {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "ps ax | grep -v grep | grep -c 'hermes-runtime' || true"]
        let out = Pipe()
        task.standardOutput = out
        try? task.run()
        task.waitUntilExit()
        let data = out.fileHandleForReading.availableData
        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "0"
        return Int(text) ?? 0
    }

    @MainActor
    func testLastAgentReplyTextReturnsMostRecentAgentTurn() {
        let client = HermesClient()
        // Build a transcript: user → agent("A") → user → agent("B"). The
        // accessor must return "B" (the most recent agent turn), not "A".
        client._setTranscriptForTesting([
            .user(id: UUID(), text: "first"),
            .agent(id: UUID(), text: "A", toolCalls: []),
            .user(id: UUID(), text: "second"),
            .agent(id: UUID(), text: "B", toolCalls: [])
        ])
        XCTAssertEqual(client.lastAgentReplyText, "B")
    }

    @MainActor
    func testLastAgentReplyTextReturnsNilWhenNoAgentTurns() {
        let client = HermesClient()
        XCTAssertNil(client.lastAgentReplyText)
        client._setTranscriptForTesting([.user(id: UUID(), text: "hi")])
        XCTAssertNil(client.lastAgentReplyText)
    }
}
