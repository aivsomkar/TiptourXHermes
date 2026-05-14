// TipTour/Settings/SoulTabView.swift
//
// JARVIS-restyled editor for ~/.hermes/SOUL.md.

import SwiftUI

struct SoulTabView: View {

    @State private var text: String = ""
    @State private var status: String = ""
    @State private var hasUnsavedChanges: Bool = false

    private let store = HermesSoulStore()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            JarvisSectionHeader(title: "SOUL // SYSTEM PROMPT")
            Text("EDITS APPLY ON NEXT SESSION. CLOSE + REOPEN THE CHAT WINDOW AFTER SAVING.")
                .font(.system(size: 9, weight: .regular, design: .monospaced))
                .tracking(0.6)
                .foregroundColor(DS.Colors.textTertiary)

            TextEditor(text: $text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(DS.Colors.textPrimary)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(
                    ZStack {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(DS.Colors.surface1)
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(DS.Colors.jarvisBorder, lineWidth: 1)
                    }
                )
                .frame(minHeight: 240)
                .onChange(of: text) { _, _ in
                    hasUnsavedChanges = true
                    status = ""
                }

            HStack {
                JarvisButton(title: "REFRESH", enabled: true) { reload() }
                Spacer()
                if !status.isEmpty {
                    Text("> \(status.uppercased())")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .tracking(0.8)
                        .foregroundColor(DS.Colors.jarvisAccentDim)
                }
                JarvisButton(title: "SAVE", enabled: hasUnsavedChanges) { save() }
            }

            Text("STORED AT ~/.hermes/SOUL.md. DELETE THE FILE TO REGENERATE HERMES'S DEFAULT.")
                .font(.system(size: 9, weight: .regular, design: .monospaced))
                .tracking(0.6)
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .onAppear { reload() }
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
            status = "Save failed: \(error.localizedDescription.prefix(30))"
        }
    }
}
