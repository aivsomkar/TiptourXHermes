// TipTour/Hermes/FirstRunSetupView.swift
//
// Sheet shown the first time a user opens the menu bar panel without
// a configured Hermes runtime. Collects one provider + one API key,
// writes config.yaml via HermesConfigBootstrapper, and persists the
// key to Keychain. The sheet dismisses on success; the caller (the
// CompanionPanelView footer) re-evaluates needsSetup on dismissal.

import SwiftUI

struct FirstRunSetupView: View {

    /// Bound to the calling view's @State Bool — flipping to false
    /// dismisses the sheet.
    @Binding var isPresented: Bool

    /// Called on successful setup (config written + key stored), AFTER
    /// the sheet flips isPresented to false. Lets the caller refresh
    /// any cached needsSetup state.
    var onSetupComplete: () -> Void

    @State private var provider: HermesConfigBootstrapper.Provider = .anthropic
    @State private var apiKey: String = ""
    @State private var errorMessage: String?
    @State private var isSubmitting: Bool = false

    private var trimmedKey: String {
        apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Set up Hermes")
                .font(.title2.bold())
            Text("Hermes runs a small bundled Python agent under the hood. Pick a provider and paste your API key.")
                .font(.body)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Provider", selection: $provider) {
                ForEach(HermesConfigBootstrapper.Provider.allCases) { p in
                    Text(p.displayName).tag(p)
                }
            }
            .pickerStyle(.segmented)

            VStack(alignment: .leading, spacing: 6) {
                Text("API key")
                    .font(.callout.bold())
                SecureField("paste here", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                Text("Stored in macOS Keychain. Used only to launch Hermes.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if let error = errorMessage {
                Text(error)
                    .font(.callout)
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(isSubmitting ? "Saving…" : "Save") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedKey.isEmpty || isSubmitting)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func submit() {
        errorMessage = nil
        isSubmitting = true
        let key = trimmedKey
        let chosenProvider = provider

        // Run on a detached task so the UI doesn't hitch if the disk
        // write is slow. Writes are tiny but it costs nothing to be
        // good citizens.
        Task {
            do {
                let bootstrapper = HermesConfigBootstrapper()
                try bootstrapper.writeMinimalConfig(provider: chosenProvider)
                let stored = KeychainStore.set(key, forKey: chosenProvider.keychainKey)
                guard stored else {
                    await MainActor.run {
                        errorMessage = "Couldn't save the key to Keychain. Try again."
                        isSubmitting = false
                    }
                    return
                }
                await MainActor.run {
                    isSubmitting = false
                    isPresented = false
                    onSetupComplete()
                }
            } catch {
                await MainActor.run {
                    errorMessage = "Couldn't write config: \(error.localizedDescription)"
                    isSubmitting = false
                }
            }
        }
    }
}
