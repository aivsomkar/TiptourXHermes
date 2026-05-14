import XCTest
@testable import TipTour

final class ProviderHealthCheckerTests: XCTestCase {

    // MARK: - Anthropic

    func testAnthropicSuccessOn200WithModelsArray() async throws {
        let fetch: ProviderHealthChecker.Fetch = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/v1/models")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "sk-ant-test")
            XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
            let data = Data(#"{"data": [{"id": "claude-haiku-4-5"}]}"#.utf8)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil
            )!
            return (data, response)
        }
        let checker = AnthropicHealthChecker(fetch: fetch)
        let result = await checker.probe(apiKey: "sk-ant-test")
        guard case .ok = result else {
            return XCTFail("expected .ok, got \(result)")
        }
    }

    func testAnthropicAuthFailureOn401() async throws {
        let fetch: ProviderHealthChecker.Fetch = { request in
            let data = Data(#"{"error": {"message": "invalid key"}}"#.utf8)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 401,
                httpVersion: nil, headerFields: nil
            )!
            return (data, response)
        }
        let checker = AnthropicHealthChecker(fetch: fetch)
        let result = await checker.probe(apiKey: "sk-ant-bogus")
        guard case .authFailed = result else {
            return XCTFail("expected .authFailed, got \(result)")
        }
    }

    func testAnthropicNetworkErrorPropagates() async throws {
        struct LocalError: Error {}
        let fetch: ProviderHealthChecker.Fetch = { _ in
            throw LocalError()
        }
        let checker = AnthropicHealthChecker(fetch: fetch)
        let result = await checker.probe(apiKey: "sk-ant-test")
        guard case .networkError = result else {
            return XCTFail("expected .networkError, got \(result)")
        }
    }

    func testAnthropicOther5xxFailsWithStatusCode() async throws {
        let fetch: ProviderHealthChecker.Fetch = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 503,
                httpVersion: nil, headerFields: nil
            )!
            return (Data(), response)
        }
        let checker = AnthropicHealthChecker(fetch: fetch)
        let result = await checker.probe(apiKey: "sk-ant-test")
        guard case .serverError(let status) = result, status == 503 else {
            return XCTFail("expected .serverError(503), got \(result)")
        }
    }

    func testAnthropicEmptyKeyTreatedAsFailureWithoutRequest() async throws {
        var fetchCalled = false
        let fetch: ProviderHealthChecker.Fetch = { _ in
            fetchCalled = true
            throw NSError(domain: "should-not-call", code: 0)
        }
        let checker = AnthropicHealthChecker(fetch: fetch)
        let result = await checker.probe(apiKey: "")
        guard case .emptyKey = result else {
            return XCTFail("expected .emptyKey, got \(result)")
        }
        XCTAssertFalse(fetchCalled, "fetcher should not have been called for empty key")
    }
}

extension ProviderHealthCheckerTests {

    // MARK: - OpenAI

    func testOpenAISuccessOn200() async throws {
        let fetch: ProviderHealthChecker.Fetch = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/models")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
            let data = Data(#"{"data": [{"id": "gpt-4o-mini"}]}"#.utf8)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil
            )!
            return (data, response)
        }
        let checker = OpenAIHealthChecker(fetch: fetch)
        let result = await checker.probe(apiKey: "sk-test")
        XCTAssertEqual(result, .ok)
    }

    func testOpenAI401IsAuthFailed() async throws {
        let fetch: ProviderHealthChecker.Fetch = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 401,
                httpVersion: nil, headerFields: nil
            )!
            return (Data(), response)
        }
        let checker = OpenAIHealthChecker(fetch: fetch)
        let result = await checker.probe(apiKey: "sk-bogus")
        XCTAssertEqual(result, .authFailed)
    }

    // MARK: - Google

    func testGoogleSuccessOn200WithKeyInQueryString() async throws {
        let fetch: ProviderHealthChecker.Fetch = { request in
            // Key goes in ?key=… per Google's REST convention. We must
            // not include any "x-api-key" or "Authorization" header.
            let url = request.url!
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            XCTAssertEqual(components.host, "generativelanguage.googleapis.com")
            XCTAssertEqual(components.path, "/v1beta/models")
            XCTAssertEqual(components.queryItems?.first { $0.name == "key" }?.value, "AIza-test")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            let data = Data(#"{"models": [{"name": "models/gemini-flash-lite-latest"}]}"#.utf8)
            let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (data, response)
        }
        let checker = GoogleHealthChecker(fetch: fetch)
        let result = await checker.probe(apiKey: "AIza-test")
        XCTAssertEqual(result, .ok)
    }

    func testGoogle403IsAuthFailed() async throws {
        let fetch: ProviderHealthChecker.Fetch = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 403,
                httpVersion: nil, headerFields: nil
            )!
            return (Data(), response)
        }
        let checker = GoogleHealthChecker(fetch: fetch)
        let result = await checker.probe(apiKey: "AIza-bogus")
        XCTAssertEqual(result, .authFailed)
    }

    // MARK: - Factory

    func testHealthCheckerFactoryReturnsCorrectImplementation() {
        XCTAssertTrue(ProviderHealthCheckerFactory.make(for: .anthropic) is AnthropicHealthChecker)
        XCTAssertTrue(ProviderHealthCheckerFactory.make(for: .openai) is OpenAIHealthChecker)
        XCTAssertTrue(ProviderHealthCheckerFactory.make(for: .google) is GoogleHealthChecker)
    }
}
