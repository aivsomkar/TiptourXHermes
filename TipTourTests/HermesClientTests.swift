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
}
