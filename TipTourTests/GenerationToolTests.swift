import Testing
import Foundation
@testable import TipTour

@Suite struct GenerationToolTests {

    @Test func generateImageReturnsSavedFilePath() async throws {
        MockURLProtocol.stubbedResponses = []
        let fakeImageData = Data([0xFF, 0xD8, 0xFF, 0xE0]) // minimal JPEG header

        // First call: OpenAI Images API → returns JSON with url
        MockURLProtocol.addResponse(
            for: "https://api.openai.com/v1/images/generations",
            data: """
            {"data":[{"url":"https://example.com/image.jpg"}]}
            """.data(using: .utf8)!,
            statusCode: 200
        )
        // Second call: download the image
        MockURLProtocol.addResponse(
            for: "https://example.com/image.jpg",
            data: fakeImageData,
            statusCode: 200
        )

        let tool = GenerateImageTool(
            apiKey: "test-key",
            outputDirectory: URL(fileURLWithPath: NSTemporaryDirectory()),
            urlSession: MockURLProtocol.makeSession()
        )
        let result = await tool.execute(argumentsJSON: """
            {"prompt":"a red apple on a white background"}
            """)
        #expect(result.hasPrefix("/") || result.hasPrefix("~/"))
        #expect(result.hasSuffix(".jpg"))
    }

    @Test func generateImageMissingAPIKeyReturnsError() async {
        let tool = GenerateImageTool(
            apiKey: "",
            outputDirectory: URL(fileURLWithPath: NSTemporaryDirectory()),
            urlSession: URLSession.shared
        )
        let result = await tool.execute(argumentsJSON: """{"prompt":"test"}""")
        #expect(result.hasPrefix("Error:"))
        #expect(result.contains("API key"))
    }

    @Test func generateImageMissingPromptReturnsError() async {
        let tool = GenerateImageTool(
            apiKey: "test-key",
            outputDirectory: URL(fileURLWithPath: NSTemporaryDirectory()),
            urlSession: URLSession.shared
        )
        let result = await tool.execute(argumentsJSON: "{}")
        #expect(result.hasPrefix("Error:"))
        #expect(result.contains("prompt"))
    }

    @Test func generateVideoReturnsSavedFilePath() async throws {
        MockURLProtocol.stubbedResponses = []
        let fakeVideoData = Data(repeating: 0x00, count: 100)

        // First call: POST to start generation → returns generation ID
        MockURLProtocol.addResponse(
            for: "https://api.lumaai.com/dream-machine/v1/generations",
            data: """
            {"id":"gen-abc123","state":"queued"}
            """.data(using: .utf8)!,
            statusCode: 201
        )
        // Second call: poll for status → returns completed with video URL
        MockURLProtocol.addResponse(
            for: "https://api.lumaai.com/dream-machine/v1/generations/gen-abc123",
            data: """
            {"id":"gen-abc123","state":"completed","assets":{"video":"https://example.com/video.mp4"}}
            """.data(using: .utf8)!,
            statusCode: 200
        )
        // Third call: download the video
        MockURLProtocol.addResponse(
            for: "https://example.com/video.mp4",
            data: fakeVideoData,
            statusCode: 200
        )

        let tool = GenerateVideoTool(
            apiKey: "test-key",
            outputDirectory: URL(fileURLWithPath: NSTemporaryDirectory()),
            urlSession: MockURLProtocol.makeSession(),
            pollIntervalSeconds: 0  // no sleep in tests
        )
        let result = await tool.execute(argumentsJSON: """
            {"prompt":"a golden retriever running on a beach"}
            """)
        #expect(result.hasSuffix(".mp4"))
    }

    @Test func generateVideoMissingAPIKeyReturnsError() async {
        let tool = GenerateVideoTool(
            apiKey: "",
            outputDirectory: URL(fileURLWithPath: NSTemporaryDirectory()),
            urlSession: URLSession.shared,
            pollIntervalSeconds: 0
        )
        let result = await tool.execute(argumentsJSON: """{"prompt":"test"}""")
        #expect(result.hasPrefix("Error:"))
        #expect(result.contains("Luma"))
    }

    @Test func toolBoxImageGenerationIncludesGenerateImageTool() {
        let toolBox = ToolBox.build(for: .imageGeneration)
        let toolNames = toolBox.definitions.map(\.name)
        #expect(toolNames.contains("generate_image"))
        #expect(!toolNames.contains("generate_video"))
    }

    @Test func toolBoxVideoGenerationIncludesGenerateVideoTool() {
        let toolBox = ToolBox.build(for: .videoGeneration)
        let toolNames = toolBox.definitions.map(\.name)
        #expect(toolNames.contains("generate_video"))
        #expect(!toolNames.contains("generate_image"))
    }

    @Test func keychainStoreExposesLumaAPIKey() {
        // Write, read, clear — verify the lumaAPIKey computed property works.
        KeychainStore.lumaAPIKey = "test-luma-key"
        #expect(KeychainStore.lumaAPIKey == "test-luma-key")
        KeychainStore.lumaAPIKey = nil
        #expect(KeychainStore.lumaAPIKey == nil)
    }
}

// MARK: - MockURLProtocol

// Intercepts URLSession requests and returns canned responses in order.
// Use makeSession() to get a URLSession wired to this protocol.
final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    // Each entry is consumed once (FIFO) when a matching request arrives.
    static var stubbedResponses: [(urlPrefix: String, data: Data, statusCode: Int)] = []

    static func addResponse(for urlPrefix: String, data: Data, statusCode: Int) {
        stubbedResponses.append((urlPrefix, data, statusCode))
    }

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let urlString = request.url?.absoluteString ?? ""
        guard let index = Self.stubbedResponses.firstIndex(where: { urlString.hasPrefix($0.urlPrefix) }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let stub = Self.stubbedResponses.remove(at: index)
        let response = HTTPURLResponse(url: request.url!, statusCode: stub.statusCode,
                                       httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
