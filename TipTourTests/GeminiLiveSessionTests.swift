import XCTest
@testable import TipTour

final class GeminiLiveSessionTests: XCTestCase {

    @MainActor
    func testAskHermesToolDeclarationShape() {
        let decl = GeminiLiveClient.askHermesToolDeclaration
        XCTAssertEqual(decl["name"] as? String, "ask_hermes")
        guard let params = decl["parameters"] as? [String: Any],
              let props = params["properties"] as? [String: Any],
              let task = props["task"] as? [String: Any] else {
            return XCTFail("ask_hermes declaration missing parameters.properties.task")
        }
        XCTAssertEqual(task["type"] as? String, "string")
        XCTAssertEqual(params["required"] as? [String], ["task"])
    }

    @MainActor
    func testSimulateAskHermesRoutesToCallback() async {
        let session = GeminiLiveSession(
            apiKeyURL: "http://localhost:0/unused",
            systemPrompt: "test"
        )

        // Bypass the "user has not spoken yet" gate so the dispatcher
        // actually runs the switch case for ask_hermes.
        session._setHasReceivedUserSpeechForTesting(true)

        var capturedID: String?
        var capturedTask: String?
        let waited = expectation(description: "callback ran")
        session.onAskHermes = { id, task in
            capturedID = id
            capturedTask = task
            waited.fulfill()
            return ["ok": true, "text": "hello back"]
        }

        session.simulateToolCall(
            id: "tc-1",
            name: "ask_hermes",
            args: ["task": "say hello"]
        )

        await fulfillment(of: [waited], timeout: 2.0)
        XCTAssertEqual(capturedID, "tc-1")
        XCTAssertEqual(capturedTask, "say hello")
    }
}
