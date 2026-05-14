// TipTour/Settings/ModelsTabView.swift
//
// JARVIS-restyled provider/key management. Provider segmented picker,
// per-provider key row (monospaced label + secure field + SAVE + TEST),
// and bundled Hermes runtime version readout.

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
        case idle, probing, ok
        case failed(String)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                providerSection
                keysSection
                runtimeSection
                if let err = configError {
                    Text("✗ \(err.uppercased())")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .tracking(0.8)
                        .foregroundColor(DS.Colors.destructive)
                }
            }
            .padding(20)
        }
        .onAppear(perform: loadState)
    }

    // MARK: Sections

    private var providerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            JarvisSectionHeader(title: "ACTIVE PROVIDER")
            Picker("", selection: $selectedProvider) {
                ForEach(HermesConfigBootstrapper.Provider.allCases) { p in
                    Text(p.displayName).tag(p)
                }
            }
            .pickerStyle(.segmented)
            .tint(DS.Colors.jarvisAccent)
            .labelsHidden()
            .onChange(of: selectedProvider) { _, newValue in
                applyProviderChange(newValue)
            }
            Text("SWITCHING PROVIDER REWRITES ~/.hermes/config.yaml. SAVED KEYS PERSIST; THE ACTIVE PROVIDER'S KEY IS WHAT HERMES USES.")
                .font(.system(size: 9, weight: .regular, design: .monospaced))
                .tracking(0.6)
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var keysSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            JarvisSectionHeader(title: "API KEYS")
            keyRow(provider: .anthropic, value: $anthropicKey)
            keyRow(provider: .openai,    value: $openAIKey)
            keyRow(provider: .google,    value: $googleKey)
        }
    }

    private var runtimeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            JarvisSectionHeader(title: "RUNTIME")
            if let url = HermesRuntimeVersion.bundledURL,
               let v = try? HermesRuntimeVersion.read(from: url) {
                Text(v.shortDisplayString)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(DS.Colors.textSecondary)
            } else {
                Text("HERMES VERSION FILE MISSING — DID THE BUILD PHASE RUN?")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundColor(DS.Colors.warning)
            }
        }
    }

    // MARK: Per-provider row

    private func keyRow(
        provider: HermesConfigBootstrapper.Provider,
        value: Binding<String>
    ) -> some View {
        let status = probeStatus[provider] ?? .idle
        let trimmed = value.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(provider.displayName.uppercased())
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(1.2)
                    .foregroundColor(DS.Colors.textPrimary)
                Spacer()
                statusBadge(for: status)
            }
            HStack(spacing: 8) {
                SecureField("paste \(provider.displayName) API key", text: value)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(DS.Colors.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        ZStack {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(DS.Colors.surface1)
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .strokeBorder(DS.Colors.jarvisBorder, lineWidth: 1)
                        }
                    )
                JarvisButton(title: "SAVE", enabled: !trimmed.isEmpty) {
                    saveKey(provider: provider, value: trimmed)
                }
                JarvisButton(title: "TEST", enabled: !trimmed.isEmpty && status != .probing) {
                    Task { await testConnection(provider: provider, key: trimmed) }
                }
            }
        }
    }

    @ViewBuilder
    private func statusBadge(for status: ProbeStatus) -> some View {
        switch status {
        case .idle:
            EmptyView()
        case .probing:
            ProgressView().scaleEffect(0.5).frame(width: 14, height: 14)
        case .ok:
            HStack(spacing: 4) {
                Circle()
                    .fill(DS.Colors.jarvisAccent)
                    .frame(width: 5, height: 5)
                    .shadow(color: DS.Colors.jarvisAccent.opacity(0.7), radius: 3)
                Text("OK")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(1.0)
                    .foregroundColor(DS.Colors.jarvisAccent)
            }
        case .failed(let why):
            HStack(spacing: 4) {
                Circle()
                    .fill(DS.Colors.destructive)
                    .frame(width: 5, height: 5)
                Text(why.uppercased())
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .tracking(0.6)
                    .foregroundColor(DS.Colors.destructive)
            }
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
        KeychainStore.set(value, forKey: provider.keychainKey)
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
            case .networkError(let m): probeStatus[provider] = .failed("network: \(m.prefix(20))")
            }
        }
    }
}
