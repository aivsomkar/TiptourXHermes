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
