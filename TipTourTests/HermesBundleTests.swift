import XCTest

/// Verifies the Hermes runtime ships inside the .app and can hold a
/// JSON-RPC conversation over stdio. Does NOT exercise prompt/LLM paths —
/// those require Hermes to be configured (`hermes setup`) and are covered
/// by the Python smoke test at Tests/Python/smoke_test_acp.py.
final class HermesBundleTests: XCTestCase {

    private var runtimeURL: URL {
        Bundle.main.resourceURL!
            .appendingPathComponent("hermes-runtime")
            .appendingPathComponent("hermes-runtime")
    }

    // MARK: - Static checks (no API key needed)

    func testBundledRuntimeFileExists() throws {
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: runtimeURL.path),
            "Bundled hermes-runtime not found at \(runtimeURL.path). Did the 'Bundle Hermes runtime' build phase run?"
        )
    }

    func testBundledRuntimeIsExecutable() throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: runtimeURL.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
        XCTAssertNotEqual(
            permissions & 0o111, 0,
            "Bundled hermes-runtime is not executable (perms: \(String(permissions, radix: 8)))"
        )
    }

    // MARK: - Live ACP handshake

    /// Launches the runtime, sends an ACP `initialize` request, and
    /// asserts the agent responds with its capabilities within 30s.
    /// This is the minimum bar that proves the bundled Python +
    /// agent-client-protocol library are wired together correctly.
    /// `session/new` and `session/prompt` need Hermes to have a provider
    /// configured (`~/.hermes/config.yaml`) and are deliberately NOT
    /// covered here — see Tests/Python/smoke_test_acp.py for those.
    func testBundledRuntimeAcceptsACPInitialize() throws {
        let process = Process()
        process.executableURL = runtimeURL
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        defer {
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
        }

        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": "swift-init-1",
            "method": "initialize",
            "params": [
                "protocolVersion": 1,
                "clientCapabilities": [
                    "fs": ["readTextFile": false, "writeTextFile": false],
                    "terminal": false
                ]
            ]
        ]
        let payload = try JSONSerialization.data(withJSONObject: request) + Data("\n".utf8)
        try stdin.fileHandleForWriting.write(contentsOf: payload)

        // Newline-delimited JSON-RPC: read from stdout until we see a
        // line whose parsed JSON has id == "swift-init-1" and contains a
        // "result" field.
        let deadline = Date().addingTimeInterval(30)
        var buffer = Data()
        var response: [String: Any]?

        while Date() < deadline {
            let chunk = stdout.fileHandleForReading.availableData
            if chunk.isEmpty {
                Thread.sleep(forTimeInterval: 0.05)
                continue
            }
            buffer.append(chunk)
            while let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let lineData = buffer.subdata(in: 0..<newlineIndex)
                buffer.removeSubrange(0...newlineIndex)
                guard
                    let parsed = try? JSONSerialization.jsonObject(with: lineData),
                    let frame = parsed as? [String: Any]
                else { continue }
                if frame["id"] as? String == "swift-init-1", frame["result"] != nil {
                    response = frame
                    break
                }
                if frame["id"] as? String == "swift-init-1", let error = frame["error"] {
                    XCTFail("initialize errored: \(error)")
                    return
                }
            }
            if response != nil { break }
        }

        guard let result = response?["result"] as? [String: Any] else {
            let stderrData = stderr.fileHandleForReading.availableData
            let stderrText = String(data: stderrData, encoding: .utf8) ?? "<not utf8>"
            XCTFail("No initialize response within 30s. Runtime stderr:\n\(stderrText)")
            return
        }
        XCTAssertEqual(result["protocolVersion"] as? Int, 1,
                       "Agent must speak ACP protocol version 1")
        XCTAssertNotNil(result["agentCapabilities"],
                        "initialize result missing agentCapabilities")
    }
}
