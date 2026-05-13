// TipTour/Agents/UI/SettingsView.swift

import SwiftUI

// MARK: - Tab container
//
// TODO(plan-2): the previous Agents/Skills/Learning tabs all read from
// the swarm/skill/memory subsystems that are being deleted in this
// rebrand. Re-introduce these surfaces once the equivalent state is
// exposed via HermesClient.

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Settings")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)

                Spacer()

                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(DS.Colors.textTertiary)
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()
                .background(DS.Colors.borderSubtle)

            Spacer()

            Text("Agent, skill, and learning controls are being reworked\nfor the Hermes backend. Check back soon.")
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textTertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            Spacer()
        }
        .frame(width: 480, height: 440)
        .background(DS.Colors.surface1)
        .preferredColorScheme(.dark)
    }
}
