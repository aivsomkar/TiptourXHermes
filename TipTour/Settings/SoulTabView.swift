// TipTour/Settings/SoulTabView.swift
//
// Editor for ~/.hermes/SOUL.md — Hermes's system prompt. Same shape as
// MemoryTabView but with a louder caveat: SOUL changes only take effect
// when Hermes loads a new session, so the user may need to restart
// chat after editing.

import SwiftUI

struct SoulTabView: View {

    @State private var text: String = ""
    @State private var status: String = ""
    @State private var hasUnsavedChanges: Bool = false

    private let store = HermesSoulStore()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 220)
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
                    Text(status).font(.caption).foregroundColor(.secondary)
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
            Text("Soul (system prompt)")
                .font(.callout.bold())
            Text("The system prompt Hermes loads at session start. Edits take effect on the next chat session — close + reopen the chat window after saving.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        Text("Stored at ~/.hermes/SOUL.md. Hermes creates a default on first launch — edit freely or delete the file to regenerate the default.")
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
            status = "Saved — restart chat to apply"
        } catch {
            status = "Save failed: \(error.localizedDescription)"
        }
    }
}
