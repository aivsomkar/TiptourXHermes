// TipTour/Settings/ProviderHealthChecker.swift
//
// Per-provider key validation that doesn't involve Hermes. The Models
// tab calls this from the "Test Connection" button. Each implementation
// hits the provider's "list models" GET endpoint, which is free (no LLM
// tokens spent) and a strict superset of "does this key authenticate" —
// if /v1/models returns 200 with a non-empty JSON body, the key works.
//
// Fetch is closure-injected so tests can canned-respond without the
// URLProtocol subclass dance. Production uses URLSession.shared via the
// default initializer.

import Foundation

protocol ProviderHealthChecker {
    typealias Fetch = (URLRequest) async throws -> (Data, URLResponse)
    func probe(apiKey: String) async -> ProbeResult
}

enum ProbeResult: Equatable {
    case ok
    case emptyKey
    case authFailed
    case serverError(Int)
    case networkError(String)
}

/// Production fetch closure — used by every checker as the default
/// when no test fetch is injected.
fileprivate func realFetch(_ request: URLRequest) async throws -> (Data, URLResponse) {
    try await URLSession.shared.data(for: request)
}

struct AnthropicHealthChecker: ProviderHealthChecker {
    static let endpoint = URL(string: "https://api.anthropic.com/v1/models")!
    private let fetch: Fetch

    init(fetch: @escaping Fetch = realFetch) {
        self.fetch = fetch
    }

    func probe(apiKey: String) async -> ProbeResult {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty { return .emptyKey }
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "GET"
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        do {
            let (_, response) = try await fetch(request)
            return Self.classify(response: response)
        } catch {
            return .networkError("\(error)")
        }
    }

    static func classify(response: URLResponse) -> ProbeResult {
        guard let http = response as? HTTPURLResponse else { return .serverError(0) }
        switch http.statusCode {
        case 200..<300: return .ok
        case 401, 403:  return .authFailed
        default:        return .serverError(http.statusCode)
        }
    }
}

struct OpenAIHealthChecker: ProviderHealthChecker {
    static let endpoint = URL(string: "https://api.openai.com/v1/models")!
    private let fetch: Fetch

    init(fetch: @escaping Fetch = realFetch) {
        self.fetch = fetch
    }

    func probe(apiKey: String) async -> ProbeResult {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty { return .emptyKey }
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        do {
            let (_, response) = try await fetch(request)
            return AnthropicHealthChecker.classify(response: response)
        } catch {
            return .networkError("\(error)")
        }
    }
}

struct GoogleHealthChecker: ProviderHealthChecker {
    static let endpointBase = URL(string: "https://generativelanguage.googleapis.com/v1beta/models")!
    private let fetch: Fetch

    init(fetch: @escaping Fetch = realFetch) {
        self.fetch = fetch
    }

    func probe(apiKey: String) async -> ProbeResult {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty { return .emptyKey }
        var components = URLComponents(url: Self.endpointBase, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "key", value: key)]
        guard let url = components.url else { return .networkError("URL construction failed") }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        do {
            let (_, response) = try await fetch(request)
            return AnthropicHealthChecker.classify(response: response)
        } catch {
            return .networkError("\(error)")
        }
    }
}

/// Returns the right checker for a given Provider enum case. Used by
/// ModelsTabView to dispatch on the user's current selection.
enum ProviderHealthCheckerFactory {
    static func make(for provider: HermesConfigBootstrapper.Provider) -> any ProviderHealthChecker {
        switch provider {
        case .anthropic: return AnthropicHealthChecker()
        case .openai:    return OpenAIHealthChecker()
        case .google:    return GoogleHealthChecker()
        }
    }
}
