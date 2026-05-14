// TipTour/Settings/ModelsTabView.swift
//
// ModelsTabView is the user-facing provider/key management surface.
// It replaces the inline picker + key rows that lived in the Dev
// panel during the Plan 4 cleanup, and adds:
//   1. Test Connection probe against the live /v1/models endpoint
//   2. Bundled Hermes runtime version display
//   3. A consistent place for new provider-related settings later

import SwiftUI

struct ModelsTabView: View {

    @State private var selectedProvider: HermesConfigBootstrapper.Provider = .anthropic
    @State private var anthropicKey: String = ""
    @State private var openAIKey: String = ""
    // Google's Keychain key is shared with GeminiLiveSession's WebSocket
    // consumer — both use `geminiAPIKey` per Plan 4's consolidation.
    // Always go through Provider.keychainKey to read/write so this stays
    // robust to future renames.
    @State private var googleKey: String = ""
    @State private var probeStatus: [HermesConfigBootstrapper.Provider: ProbeStatus] = [:]
    @State private var configError: String?

    private enum ProbeStatus: Equatable {
        case idle
        case probing
        case ok
        case failed(String)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                providerSection
                Divider()
                keysSection
                Divider()
                runtimeSection
                if let err = configError {
                    Text(err)
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }
            .padding(20)
        }
        .onAppear(perform: loadState)
    }

    // MARK: Sections

    private var providerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Active provider")
                .font(.callout.bold())
            Picker("", selection: $selectedProvider) {
                ForEach(HermesConfigBootstrapper.Provider.allCases) { p in
                    Text(p.displayName).tag(p)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: selectedProvider) { _, newValue in
                applyProviderChange(newValue)
            }
            Text("Switching provider rewrites ~/.hermes/config.yaml's `model.provider` field. Your saved keys are kept; the active provider's key is what Hermes uses at session/new time.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var keysSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("API keys")
                .font(.callout.bold())
            keyRow(provider: .anthropic, value: $anthropicKey)
            keyRow(provider: .openai,    value: $openAIKey)
            keyRow(provider: .google,    value: $googleKey)
        }
    }

    private var runtimeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Runtime")
                .font(.callout.bold())
            if let url = HermesRuntimeVersion.bundledURL,
               let v = try? HermesRuntimeVersion.read(from: url) {
                Text(v.shortDisplayString)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
            } else {
                Text("Hermes runtime version file missing — did the build phase run?")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
        }
    }

    // MARK: Per-provider row

    private func keyRow(
        provider: HermesConfigBootstrapper.Provider,
        value: Binding<String>
    ) -> some View {
        let status = probeStatus[provider] ?? .idle
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(provider.displayName)
                    .font(.callout)
                Spacer()
                statusBadge(for: status)
            }
            HStack(spacing: 8) {
                SecureField("paste \(provider.displayName) API key", text: value)
                    .textFieldStyle(.roundedBorder)
                Button("Save") {
                    saveKey(provider: provider, value: value.wrappedValue)
                }
                .disabled(value.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Test") {
                    Task { await testConnection(provider: provider, key: value.wrappedValue) }
                }
                .disabled(value.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || status == .probing)
            }
        }
    }

    @ViewBuilder
    private func statusBadge(for status: ProbeStatus) -> some View {
        switch status {
        case .idle:
            EmptyView()
        case .probing:
            ProgressView().scaleEffect(0.6).frame(width: 16, height: 16)
        case .ok:
            Label("OK", systemImage: "checkmark.circle.fill")
                .labelStyle(.iconOnly).foregroundColor(.green)
        case .failed(let why):
            Label(why, systemImage: "xmark.circle.fill")
                .foregroundColor(.red)
                .font(.caption)
        }
    }

    // MARK: Actions

    private func loadState() {
        let coord = HermesSetupCoordinator()
        selectedProvider = coord.configuredProvider ?? .anthropic
        anthropicKey = KeychainStore.get(forKey: HermesConfigBootstrapper.Provider.anthropic.keychainKey) ?? ""
        openAIKey    = KeychainStore.get(forKey: HermesConfigBootstrapper.Provider.openai.keychainKey)    ?? ""
        googleKey    = KeychainStore.get(forKey: HermesConfigBootstrapper.Provider.google.keychainKey)    ?? ""
    }

    private func applyProviderChange(_ provider: HermesConfigBootstrapper.Provider) {
        configError = nil
        do {
            try HermesConfigBootstrapper().writeMinimalConfig(provider: provider)
        } catch {
            configError = "Couldn't update config.yaml: \(error.localizedDescription)"
        }
    }

    private func saveKey(provider: HermesConfigBootstrapper.Provider, value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        KeychainStore.set(trimmed, forKey: provider.keychainKey)
    }

    private func testConnection(provider: HermesConfigBootstrapper.Provider, key: String) async {
        probeStatus[provider] = .probing
        let checker = ProviderHealthCheckerFactory.make(for: provider)
        let result = await checker.probe(apiKey: key)
        await MainActor.run {
            switch result {
            case .ok:           probeStatus[provider] = .ok
            case .emptyKey:     probeStatus[provider] = .failed("empty")
            case .authFailed:   probeStatus[provider] = .failed("auth failed")
            case .serverError(let s): probeStatus[provider] = .failed("HTTP \(s)")
            case .networkError(let m): probeStatus[provider] = .failed("network: \(m.prefix(40))")
            }
        }
    }
}
