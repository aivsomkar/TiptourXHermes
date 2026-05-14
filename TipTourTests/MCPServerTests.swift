import XCTest
@testable import TipTour

/// Minimal in-memory tool used as a stand-in for any registered tool
/// in tests. Keeps the MCPServer integration tests honest without
/// needing AVSpeechSynthesizer or any other real side effect.
private struct FakeMCPTool: MCPTool {
    let name = "fake"
    let description = "Returns a deterministic text block for tests."
    let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([:]),
    ])
    func call(_ arguments: JSONValue) async throws -> [MCPToolContent] {
        return [.text("fake-ok")]
    }
}

final class MCPServerTests: XCTestCase {

    // MARK: - Helpers

    private func postJSON(to url: URL, body: [String: Any]) async throws -> [String: Any] {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "MCPServerTests", code: 0,
                          userInfo: [NSLocalizedDescriptionKey: "non-JSON response"])
        }
        return obj
    }

    // MARK: - Tests

    @MainActor
    func testServerStartsAndStops() throws {
        let server = MCPServer(name: "test")
        let url = try server.start()
        XCTAssertEqual(url.host, "127.0.0.1")
        XCTAssertEqual(url.path, "/mcp")
        XCTAssertNotNil(server.serverURL)
        XCTAssertGreaterThan(url.port ?? 0, 0)
        server.stop()
        XCTAssertNil(server.serverURL)
    }

    @MainActor
    func testInitializeRoundTrip() async throws {
        let server = MCPServer(name: "test")
        let url = try server.start()
        defer { server.stop() }
        let resp = try await postJSON(to: url, body: [
            "jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [:]
        ])
        XCTAssertEqual(resp["jsonrpc"] as? String, "2.0")
        XCTAssertNotNil(resp["result"])
        let result = resp["result"] as? [String: Any]
        XCTAssertEqual(result?["protocolVersion"] as? String, "2024-11-05")
        let info = result?["serverInfo"] as? [String: Any]
        XCTAssertEqual(info?["name"] as? String, "test")
    }

    @MainActor
    func testToolsListIncludesRegisteredTool() async throws {
        let server = MCPServer(name: "test")
        server.register(FakeMCPTool())
        let url = try server.start()
        defer { server.stop() }
        let resp = try await postJSON(to: url, body: [
            "jsonrpc": "2.0", "id": 2, "method": "tools/list"
        ])
        let result = resp["result"] as? [String: Any]
        let tools = result?["tools"] as? [[String: Any]] ?? []
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools.first?["name"] as? String, "fake")
        XCTAssertNotNil(tools.first?["description"])
        XCTAssertNotNil(tools.first?["inputSchema"])
    }

    @MainActor
    func testToolsCallSpeakReturnsSuccess() async throws {
        let server = MCPServer(name: "test")
        server.register(FakeMCPTool())
        let url = try server.start()
        defer { server.stop() }
        let resp = try await postJSON(to: url, body: [
            "jsonrpc": "2.0", "id": 3, "method": "tools/call",
            "params": ["name": "fake", "arguments": [:]]
        ])
        let result = resp["result"] as? [String: Any]
        XCTAssertEqual(result?["isError"] as? Bool, false)
        let content = (result?["content"] as? [[String: Any]])?.first
        XCTAssertEqual(content?["type"] as? String, "text")
        XCTAssertEqual(content?["text"] as? String, "fake-ok")
    }

    @MainActor
    func testToolsCallUnknownToolReturnsError() async throws {
        let server = MCPServer(name: "test")
        let url = try server.start()
        defer { server.stop() }
        let resp = try await postJSON(to: url, body: [
            "jsonrpc": "2.0", "id": 4, "method": "tools/call",
            "params": ["name": "nope", "arguments": [:]]
        ])
        XCTAssertNotNil(resp["error"])
        let error = resp["error"] as? [String: Any]
        XCTAssertEqual(error?["code"] as? Int, -32601)
    }
}
