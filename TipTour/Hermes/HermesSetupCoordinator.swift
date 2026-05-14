// TipTour/Hermes/HermesSetupCoordinator.swift
//
// Single source of truth for "is the Hermes runtime ready to take a
// prompt?". Cross-references config.yaml (via HermesConfigBootstrapper)
// against the Keychain (via the injected HermesProviderKeyReader).
// HermesClient consults this before launching the subprocess; the panel
// UI consults it to decide whether to show the "Set up Hermes" button.

import Foundation

/// Read-only abstraction over the Keychain so tests can inject fakes
/// without touching the real macOS Keychain.
protocol HermesProviderKeyReader {
    func value(forKey key: String) -> String?
}

struct KeychainProviderKeyReader: HermesProviderKeyReader {
    func value(forKey key: String) -> String? {
        KeychainStore.get(forKey: key)
    }
}

@MainActor
struct HermesSetupCoordinator {
    let hermesHome: URL
    let keyReader: HermesProviderKeyReader

    init(
        hermesHome: URL? = nil,
        keyReader: HermesProviderKeyReader = KeychainProviderKeyReader()
    ) {
        self.hermesHome = hermesHome
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".hermes", isDirectory: true)
        self.keyReader = keyReader
    }

    var bootstrapper: HermesConfigBootstrapper {
        HermesConfigBootstrapper(hermesHome: hermesHome)
    }

    /// True iff we should ask the user to complete setup before letting
    /// HermesClient launch the subprocess.
    var needsSetup: Bool {
        guard bootstrapper.hasValidConfig else { return true }
        guard let provider = configuredProvider else { return true }
        let key = keyReader.value(forKey: provider.keychainKey)
        return key == nil
    }

    /// The provider currently named in config.yaml's model.provider
    /// field, if any. Parsed via a tiny ad-hoc scan — we don't need a
    /// YAML library for one line.
    var configuredProvider: HermesConfigBootstrapper.Provider? {
        guard FileManager.default.fileExists(atPath: bootstrapper.configPath.path),
              let text = try? String(contentsOf: bootstrapper.configPath, encoding: .utf8)
        else { return nil }
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            // Look for `provider: "<name>"` (indented under model:).
            guard line.hasPrefix("provider:") else { continue }
            let after = line.dropFirst("provider:".count)
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: #""'"#))
            if let p = HermesConfigBootstrapper.Provider(rawValue: after) {
                return p
            }
        }
        return nil
    }

    /// Env vars to merge into ProcessInfo.processInfo.environment before
    /// launching the Hermes subprocess. Returns an empty dict when
    /// needsSetup is true.
    func environmentVariablesForSubprocess() -> [String: String] {
        guard !needsSetup,
              let provider = configuredProvider,
              let key = keyReader.value(forKey: provider.keychainKey)
        else { return [:] }
        return [provider.environmentVariable: key]
    }
}
