// TipTour/Settings/MemoryTabView.swift
//
// Editor for ~/.hermes/memories/USER.md. Plain TextEditor + Save
// + Refresh. Refresh re-reads from disk in case Hermes wrote to the
// file outside this UI; Save writes back atomically via HermesMemoryStore.

import SwiftUI

struct MemoryTabView: View {

    @State private var text: String = ""
    @State private var status: String = ""
    @State private var hasUnsavedChanges: Bool = false

    private let store = HermesMemoryStore()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 200)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                )
                .onChange(of: text) { _, _ in
                    hasUnsavedChanges = true
                    status = ""
                }
            HStack {
                Button("Refresh from disk") { reload() }
                Spacer()
                if !status.isEmpty {
                    Text(status)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Button("Save") { save() }
                    .disabled(!hasUnsavedChanges)
                    .keyboardShortcut("s")
            }
            footer
        }
        .padding(20)
        .onAppear { reload() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("User memory")
                .font(.callout.bold())
            Text("Free-form facts Hermes will recall across sessions. Stored at ~/.hermes/memories/USER.md.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        Text("Hermes may also append to this file during normal use — click Refresh from disk before editing if you've had a recent conversation.")
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func reload() {
        text = store.read()
        hasUnsavedChanges = false
        status = ""
    }

    private func save() {
        do {
            try store.write(text)
            hasUnsavedChanges = false
            status = "Saved"
        } catch {
            status = "Save failed: \(error.localizedDescription)"
        }
    }
}
