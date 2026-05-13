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
}
