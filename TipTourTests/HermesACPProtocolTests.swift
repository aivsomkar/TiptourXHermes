import XCTest
@testable import TipTour

final class HermesACPProtocolTests: XCTestCase {

    // MARK: - JSONValue

    func testJSONValueEncodesAllScalarKinds() throws {
        let encoder = JSONEncoder()
        XCTAssertEqual(try String(data: encoder.encode(JSONValue.null), encoding: .utf8), "null")
        XCTAssertEqual(try String(data: encoder.encode(JSONValue.bool(true)), encoding: .utf8), "true")
        XCTAssertEqual(try String(data: encoder.encode(JSONValue.number(42)), encoding: .utf8), "42")
        XCTAssertEqual(try String(data: encoder.encode(JSONValue.string("hi")), encoding: .utf8), "\"hi\"")
    }

    func testJSONValueRoundTripsNestedStructure() throws {
        let raw = #"{"a":1,"b":[true,null,"x"],"c":{"nested":3.5}}"#
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8))
        guard case .object(let dict) = value else { XCTFail("expected object"); return }
        XCTAssertEqual(dict.count, 3)
    }

    // MARK: - JSON-RPC envelope

    func testJSONRPCRequestEncodesExpectedShape() throws {
        struct Empty: Encodable {}
        let req = JSONRPCRequest(id: "abc", method: "initialize", params: Empty())
        let json = try String(data: JSONEncoder().encode(req), encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains(#""jsonrpc":"2.0""#))
        XCTAssertTrue(json.contains(#""id":"abc""#))
        XCTAssertTrue(json.contains(#""method":"initialize""#))
    }

    func testJSONRPCResponseDecodesResultAndError() throws {
        struct DummyResult: Decodable { let ok: Bool }

        let okJSON = #"{"jsonrpc":"2.0","id":"x","result":{"ok":true}}"#.data(using: .utf8)!
        let okResp = try JSONDecoder().decode(JSONRPCResponse<DummyResult>.self, from: okJSON)
        XCTAssertEqual(okResp.result?.ok, true)
        XCTAssertNil(okResp.error)

        let errJSON = #"{"jsonrpc":"2.0","id":"y","error":{"code":-32603,"message":"boom"}}"#.data(using: .utf8)!
        let errResp = try JSONDecoder().decode(JSONRPCResponse<DummyResult>.self, from: errJSON)
        XCTAssertNil(errResp.result)
        XCTAssertEqual(errResp.error?.code, -32603)
        XCTAssertEqual(errResp.error?.message, "boom")
    }

    // MARK: - ACP requests

    func testInitializeRequestEncodesShape() throws {
        let req = InitializeRequest(
            clientCapabilities: ClientCapabilities(
                fs: FSCapabilities(readTextFile: false, writeTextFile: false),
                terminal: false
            )
        )
        let json = try String(data: JSONEncoder().encode(req), encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains(#""protocolVersion":1"#))
        XCTAssertTrue(json.contains(#""terminal":false"#))
        XCTAssertTrue(json.contains(#""readTextFile":false"#))
    }

    func testNewSessionResultDecodes() throws {
        let raw = #"{"sessionId":"abc-123","models":null}"#.data(using: .utf8)!
        let result = try JSONDecoder().decode(NewSessionResult.self, from: raw)
        XCTAssertEqual(result.sessionId, "abc-123")
    }

    func testPromptResultDecodesWithUsage() throws {
        let raw = #"""
        {"stopReason":"end_turn","usage":{"inputTokens":100,"outputTokens":5,"totalTokens":105}}
        """#.data(using: .utf8)!
        let result = try JSONDecoder().decode(PromptResult.self, from: raw)
        XCTAssertEqual(result.stopReason, "end_turn")
        XCTAssertEqual(result.usage?.totalTokens, 105)
    }

    // MARK: - SessionUpdate

    func testSessionUpdateDecodesAgentMessageChunk() throws {
        let raw = #"""
        {"sessionId":"s","update":{"sessionUpdate":"agent_message_chunk","content":{"text":"hi","type":"text"}}}
        """#.data(using: .utf8)!
        let n = try JSONDecoder().decode(SessionUpdateNotification.self, from: raw)
        guard case .agentMessageChunk(let text) = n.update else {
            XCTFail("expected agentMessageChunk, got \(n.update)")
            return
        }
        XCTAssertEqual(text, "hi")
    }

    func testSessionUpdateDecodesUnknownDiscriminator() throws {
        let raw = #"""
        {"sessionId":"s","update":{"sessionUpdate":"some_future_kind","extra":42}}
        """#.data(using: .utf8)!
        let n = try JSONDecoder().decode(SessionUpdateNotification.self, from: raw)
        guard case .unknown(let raw) = n.update else { XCTFail("expected .unknown"); return }
        // The wrapping JSONValue should be an object with at least the
        // sessionUpdate key.
        guard case .object(let dict) = raw else { XCTFail("expected object"); return }
        XCTAssertEqual(dict["sessionUpdate"], .string("some_future_kind"))
    }
}
