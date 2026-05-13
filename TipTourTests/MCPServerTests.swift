import XCTest
@testable import TipTour

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
}
