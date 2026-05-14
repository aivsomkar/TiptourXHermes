// TipTour/Hermes/HermesConfigBootstrapper.swift
//
// Writes a minimum-viable ~/.hermes/config.yaml so the bundled Hermes
// runtime can complete session/new without `hermes setup`. Provider
// names + default models match Hermes's models_dev_cache.json
// (verified 2026-05-14): anthropic, openai, google.

import Foundation

struct HermesConfigBootstrapper {

    enum Provider: String, CaseIterable, Identifiable {
        case anthropic
        case openai
        case google

        var id: String { rawValue }

        /// Display label for UI (sentence case).
        var displayName: String {
            switch self {
            case .anthropic: return "Anthropic"
            case .openai:    return "OpenAI"
            case .google:    return "Google (Gemini)"
            }
        }

        /// Env var Hermes reads at session/new time. Note: Google's is
        /// GEMINI_API_KEY by convention even though the provider key in
        /// config.yaml is "google".
        var environmentVariable: String {
            switch self {
            case .anthropic: return "ANTHROPIC_API_KEY"
            case .openai:    return "OPENAI_API_KEY"
            case .google:    return "GEMINI_API_KEY"
            }
        }

        /// KeychainStore key used to persist the API key for this provider.
        var keychainKey: String {
            switch self {
            case .anthropic: return "anthropicAPIKey"
            case .openai:    return "openAIAPIKey"
            case .google:    return "googleAPIKey"
            }
        }

        /// "<provider>/<model>" string written into config.yaml's
        /// model.default field. Chosen as fast + cheap defaults; user
        /// can edit ~/.hermes/config.yaml directly to override.
        fileprivate var defaultModel: String {
            switch self {
            case .anthropic: return "anthropic/claude-haiku-4-5"
            case .openai:    return "openai/gpt-4o-mini"
            case .google:    return "google/gemini-flash-lite-latest"
            }
        }
    }

    /// The directory we treat as $HERMES_HOME. Defaults to ~/.hermes.
    /// Tests inject a temp dir; HermesClient injects the same path it
    /// passes to the subprocess as HERMES_HOME env var.
    let hermesHome: URL

    init(hermesHome: URL? = nil) {
        self.hermesHome = hermesHome
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".hermes", isDirectory: true)
    }

    var configPath: URL {
        hermesHome.appendingPathComponent("config.yaml")
    }

    /// True iff config.yaml exists and contains a `model:` key. Looks
    /// for the literal substring "model:" (a top-level key with that
    /// name) so we don't pull in a YAML library for one check.
    var hasValidConfig: Bool {
        guard FileManager.default.fileExists(atPath: configPath.path) else { return false }
        guard let text = try? String(contentsOf: configPath, encoding: .utf8) else { return false }
        // Match a top-level `model:` (start of line or start of file).
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("model:") { return true }
        }
        return false
    }

    /// Writes the minimum config.yaml for the given provider. Creates
    /// the parent directory if missing. Idempotent: the same provider
    /// produces byte-identical output.
    func writeMinimalConfig(provider: Provider) throws {
        try FileManager.default.createDirectory(
            at: hermesHome, withIntermediateDirectories: true
        )
        let body = """
        # ~/.hermes/config.yaml
        # Written by HermesForNoobs on first-run setup. Edit freely —
        # Hermes reads this directly. To change provider via the UI,
        # use Settings → Provider in the menu bar panel.
        model:
          default: "\(provider.defaultModel)"
          provider: "\(provider.rawValue)"

        """
        try body.write(to: configPath, atomically: true, encoding: .utf8)
    }
}
