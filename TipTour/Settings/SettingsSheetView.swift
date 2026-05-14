// TipTour/Settings/SettingsSheetView.swift
//
// Root of the tabbed Settings sheet opened from the panel footer.
// JARVIS-restyled: dark background, cyan border + glow, monospaced
// uppercase tab header, cyan-outlined Done button. Uses a custom
// JARVIS tab bar instead of SwiftUI's native tab container — its
// macOS chrome fights the aesthetic.

import SwiftUI

struct SettingsSheetView: View {

    @Binding var isPresented: Bool

    private enum Tab: String, Hashable {
        case models, memory, soul
    }
    @State private var selectedTab: Tab = .models

    var body: some View {
        ZStack {
            background

            VStack(spacing: 0) {
                header
                tabBar
                Divider()
                    .background(DS.Colors.jarvisBorder)

                Group {
                    switch selectedTab {
                    case .models: ModelsTabView()
                    case .memory: MemoryTabView()
                    case .soul:   SoulTabView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 580, height: 520)
    }

    // MARK: - Background

    private var background: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(DS.Colors.background)
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(DS.Colors.jarvisBorder, lineWidth: 1)
        }
        .shadow(color: DS.Colors.jarvisGlow, radius: 24, x: 0, y: 0)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            HStack(spacing: 10) {
                Rectangle()
                    .fill(DS.Colors.jarvisAccent)
                    .frame(width: 8, height: 1)
                Text("SETTINGS // CONTROL")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .tracking(2.0)
                    .foregroundColor(DS.Colors.jarvisAccent)
            }
            Spacer()
            Button(action: { isPresented = false }) {
                Text("DONE")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(1.6)
                    .foregroundColor(DS.Colors.jarvisAccent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(DS.Colors.jarvisAccent, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    // MARK: - Custom tab bar

    private var tabBar: some View {
        HStack(spacing: 0) {
            tabButton("MODELS", systemImage: "cpu", tab: .models)
            tabButton("MEMORY", systemImage: "brain", tab: .memory)
            tabButton("SOUL",   systemImage: "sparkles", tab: .soul)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 4)
    }

    private func tabButton(_ title: String, systemImage: String, tab: Tab) -> some View {
        let active = (selectedTab == tab)
        return Button(action: { selectedTab = tab }) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .semibold))
                Text(title)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(1.4)
            }
            .foregroundColor(active ? DS.Colors.jarvisAccent : DS.Colors.textTertiary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(active ? DS.Colors.jarvisAccent : Color.clear)
                    .frame(height: 1)
            }
        }
        .buttonStyle(.plain)
    }
}
