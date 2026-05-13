// TipTour/Agents/Tools/WebTools.swift

import Foundation

// MARK: - Web Fetch

/// Fetches the raw content of a URL via GET request and returns up to 10,000
/// characters of the response body as plain text (HTML tags stripped).
struct WebFetchTool: AgentTool {

    let name = "web_fetch"

    let description = """
        Fetch the content of a URL. Returns the first 10,000 characters of \
        the response body with HTML tags stripped. Use for reading web pages, \
        API responses, or any publicly accessible URL.
        """

    let parametersJSON = """
        {
            "type": "object",
            "properties": {
                "url": {
                    "type": "string",
                    "description": "The URL to fetch (must be http:// or https://)."
                }
            },
            "required": ["url"]
        }
        """

    private let characterLimit = 10_000

    func execute(argumentsJSON: String) async -> String {
        do {
            let urlString = try parseURL(from: argumentsJSON)
            guard let url = URL(string: urlString),
                  url.scheme == "http" || url.scheme == "https" else {
                return "Error: '\(urlString)' is not a valid http/https URL."
            }

            var request = URLRequest(url: url, timeoutInterval: 20)
            request.setValue(
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) TipTourAgent/1.0",
                forHTTPHeaderField: "User-Agent"
            )

            let (data, response) = try await URLSession.shared.data(for: request)

            if let httpResponse = response as? HTTPURLResponse,
               httpResponse.statusCode >= 400 {
                return "Error: HTTP \(httpResponse.statusCode) for \(urlString)"
            }

            let rawText = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
                ?? "(non-text response)"

            let plainText = stripHTMLTags(from: rawText)
            let trimmed = plainText
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")

            if trimmed.count > characterLimit {
                return String(trimmed.prefix(characterLimit))
                    + "\n\n[Truncated — showing first \(characterLimit) of \(trimmed.count) characters]"
            }
            return trimmed.isEmpty ? "(empty response)" : trimmed

        } catch {
            return "Error fetching URL: \(error.localizedDescription)"
        }
    }

    private func parseURL(from json: String) throws -> String {
        guard let data = json.data(using: .utf8),
              let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let urlString = dict["url"] as? String, !urlString.isEmpty else {
            throw ToolArgumentError.missingRequiredField("url")
        }
        return urlString
    }

    /// Removes HTML/XML tags using a regex. Not a full HTML parser — good enough
    /// for extracting readable text from web pages.
    private func stripHTMLTags(from html: String) -> String {
        html.replacingOccurrences(
            of: "<[^>]+>",
            with: "",
            options: .regularExpression
        )
    }
}

// MARK: - Web Search (DuckDuckGo Instant Answer API)

/// Queries the DuckDuckGo Instant Answer API (no API key required).
/// Returns a summary and up to 5 related topics with titles and URLs.
struct WebSearchTool: AgentTool {

    let name = "web_search"

    let description = """
        Search the web using DuckDuckGo. Returns an abstract summary and \
        up to 5 related results with titles and URLs. For detailed page \
        content, follow up with web_fetch on a specific URL.
        """

    let parametersJSON = """
        {
            "type": "object",
            "properties": {
                "query": {
                    "type": "string",
                    "description": "The search query."
                }
            },
            "required": ["query"]
        }
        """

    func execute(argumentsJSON: String) async -> String {
        do {
            let query = try parseQuery(from: argumentsJSON)
            return await performSearch(query: query)
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }

    private func parseQuery(from json: String) throws -> String {
        guard let data = json.data(using: .utf8),
              let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let query = dict["query"] as? String, !query.isEmpty else {
            throw ToolArgumentError.missingRequiredField("query")
        }
        return query
    }

    private func performSearch(query: String) async -> String {
        let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let urlString = "https://api.duckduckgo.com/?q=\(encodedQuery)&format=json&no_html=1&skip_disambig=1"
        guard let url = URL(string: urlString) else {
            return "Error: could not construct search URL."
        }

        do {
            var request = URLRequest(url: url, timeoutInterval: 15)
            request.setValue("TipTourAgent/1.0", forHTTPHeaderField: "User-Agent")
            let (data, _) = try await URLSession.shared.data(for: request)

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return "Error: unexpected search API response format."
            }

            var output: [String] = []

            if let abstract = json["AbstractText"] as? String, !abstract.isEmpty {
                output.append("Summary: \(abstract)")
                if let source = json["AbstractURL"] as? String, !source.isEmpty {
                    output.append("Source: \(source)")
                }
            }

            if let topics = json["RelatedTopics"] as? [[String: Any]] {
                let topResults = topics.prefix(5).compactMap { topic -> String? in
                    guard let text = topic["Text"] as? String, !text.isEmpty else { return nil }
                    let firstURL = topic["FirstURL"] as? String ?? ""
                    return "• \(text)" + (firstURL.isEmpty ? "" : "\n  \(firstURL)")
                }
                if !topResults.isEmpty {
                    output.append("\nRelated results:")
                    output.append(contentsOf: topResults)
                }
            }

            return output.isEmpty
                ? "No results found for '\(query)'. Try rephrasing or use web_fetch with a specific URL."
                : output.joined(separator: "\n")

        } catch {
            return "Error searching: \(error.localizedDescription)"
        }
    }
}
