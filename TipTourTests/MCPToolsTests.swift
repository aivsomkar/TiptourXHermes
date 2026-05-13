import XCTest
@testable import TipTour

final class MCPToolsTests: XCTestCase {

    @MainActor
    func testSpeakToolHasExpectedMetadata() {
        let tool = SpeakTool()
        XCTAssertEqual(tool.name, "speak")
        XCTAssertFalse(tool.description.isEmpty)
        guard case .object(let schema) = tool.inputSchema,
              case .string(let kind) = schema["type"] ?? .null,
              kind == "object",
              case .array(let required) = schema["required"] ?? .null,
              required.contains(.string("text"))
        else {
            XCTFail("speak inputSchema does not require a `text` string")
            return
        }
    }

    @MainActor
    func testSpeakToolCallReturnsSuccessForValidText() async throws {
        let tool = SpeakTool()
        let result = try await tool.call(.object(["text": .string("ok")]))
        XCTAssertTrue(result.contains("ok"))
    }

    @MainActor
    func testSpeakToolCallRejectsMissingText() async {
        let tool = SpeakTool()
        do {
            _ = try await tool.call(.object([:]))
            XCTFail("expected throw for missing `text`")
        } catch let error as MCPToolError {
            guard case .invalidArguments = error else {
                XCTFail("expected .invalidArguments, got \(error)")
                return
            }
        } catch {
            XCTFail("expected MCPToolError, got \(error)")
        }
    }

    @MainActor
    func testSpeakToolCallRejectsEmptyText() async {
        let tool = SpeakTool()
        do {
            _ = try await tool.call(.object(["text": .string("")]))
            XCTFail("expected throw for empty `text`")
        } catch let error as MCPToolError {
            guard case .invalidArguments = error else {
                XCTFail("expected .invalidArguments, got \(error)")
                return
            }
        } catch {
            XCTFail("expected MCPToolError, got \(error)")
        }
    }
}
