// TipTour/Settings/MemoryTabView.swift
//
// JARVIS-restyled editor for ~/.hermes/memories/USER.md.

import SwiftUI

struct MemoryTabView: View {

    @State private var text: String = ""
    @State private var status: String = ""
    @State private var hasUnsavedChanges: Bool = false

    private let store = HermesMemoryStore()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            JarvisSectionHeader(title: "USER MEMORY")
            Text("FREE-FORM FACTS HERMES WILL RECALL ACROSS SESSIONS.")
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
                .frame(minHeight: 220)
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

            Text("STORED AT ~/.hermes/memories/USER.md. HERMES MAY ALSO APPEND DURING NORMAL USE — REFRESH BEFORE EDITING IF YOU'VE HAD A RECENT CONVERSATION.")
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
            status = "Saved"
        } catch {
            status = "Save failed: \(error.localizedDescription.prefix(30))"
        }
    }
}
