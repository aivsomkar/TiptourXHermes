// TipTour/Settings/JarvisSectionHeader.swift
//
// Monospaced uppercase cyan section header with a leading bar marker
// and trailing fading hairline. Used in the Settings tab views to
// match the companion panel's section-header style.

import SwiftUI

struct JarvisSectionHeader: View {
    let title: String

    var body: some View {
        HStack(spacing: 6) {
            Rectangle()
                .fill(DS.Colors.jarvisAccent)
                .frame(width: 8, height: 1)
            Text(title)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(1.4)
                .foregroundColor(DS.Colors.jarvisAccent)
            Rectangle()
                .fill(DS.Colors.jarvisAccent.opacity(0.25))
                .frame(height: 1)
        }
    }
}

/// JARVIS-style outlined action button used in Settings tabs.
/// Monospaced uppercase label with cyan border.
struct JarvisButton: View {
    let title: String
    var enabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .tracking(1.4)
                .foregroundColor(enabled ? DS.Colors.jarvisAccent : DS.Colors.textTertiary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(enabled ? DS.Colors.jarvisAccent : DS.Colors.jarvisBorder, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}
