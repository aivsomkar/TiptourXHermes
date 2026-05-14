// TipTour/Settings/SettingsSheetView.swift
//
// Root of the Settings sheet opened from the panel footer. Hosts the
// per-area tabs. New tabs (Skills, Guardrails, Gateways, Schedule)
// drop in as additional .tabItem children — adding one is intentionally
// a one-line change so future plans don't need to touch this file's
// structure.

import SwiftUI

struct SettingsSheetView: View {

    @Binding var isPresented: Bool

    private enum Tab: String, Hashable {
        case models, memory, soul
    }
    @State private var selectedTab: Tab = .models

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            TabView(selection: $selectedTab) {
                ModelsTabView()
                    .tabItem { Label("Models", systemImage: "cpu") }
                    .tag(Tab.models)
                MemoryTabView()
                    .tabItem { Label("Memory", systemImage: "brain") }
                    .tag(Tab.memory)
                SoulTabView()
                    .tabItem { Label("Soul", systemImage: "sparkles") }
                    .tag(Tab.soul)
            }
            .padding(.top, 8)
        }
        .frame(width: 560, height: 480)
    }

    private var header: some View {
        HStack {
            Text("Settings")
                .font(.title3.bold())
            Spacer()
            Button("Done") { isPresented = false }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
