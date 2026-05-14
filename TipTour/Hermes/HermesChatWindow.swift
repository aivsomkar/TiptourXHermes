// TipTour/Hermes/HermesChatWindow.swift
//
// Floating NSWindow + SwiftUI view that hosts the Plan-2 dev chat.
// Closing the window terminates the bundled Python subprocess via
// HermesClient.stop().

import AppKit
import SwiftUI

@MainActor
func makeHermesChatWindow(client: HermesClient) -> NSWindow {
    let hosting = NSHostingController(rootView: HermesChatView(client: client))
    let window = NSWindow(contentViewController: hosting)
    window.title = "Hermes Debug"
    window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
    window.setContentSize(NSSize(width: 480, height: 360))
    window.level = .floating
    window.isReleasedWhenClosed = false
    return window
}

struct HermesChatView: View {
    @ObservedObject var client: HermesClient
    @State private var draft: String = ""
    @State private var showSetupSheet: Bool = false
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(client.transcript) { turn in
                            ChatTurnRow(turn: turn, onOpenSetupSheet: { showSetupSheet = true })
                                .id(turn.id)
                        }
                    }
                    .padding(12)
                }
                .onChange(of: client.transcript.count) { _, _ in
                    if let last = client.transcript.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
            Divider()
            HStack(spacing: 8) {
                TextField("Message Hermes…", text: $draft, axis: .vertical)
                    .lineLimit(1...6)
                    .focused($inputFocused)
                    .onSubmit(send)
                    .textFieldStyle(.roundedBorder)
                Button("Send", action: send)
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled(draft.isEmpty || client.isWorking)
            }
            .padding(12)
        }
        .frame(minWidth: 480, minHeight: 360)
        .onAppear { inputFocused = true }
        .sheet(isPresented: $showSetupSheet) {
            FirstRunSetupView(
                isPresented: $showSetupSheet,
                onSetupComplete: { /* user can re-send from the chat window */ }
            )
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !client.isWorking else { return }
        draft = ""
        Task { await client.send(text) }
    }
}

struct ChatTurnRow: View {
    let turn: HermesClient.ChatTurn
    /// Called when the user clicks the inline "Set Up Hermes…" button
    /// on a setup-error system row. Owned by the parent `HermesChatView`
    /// because the sheet state lives there.
    var onOpenSetupSheet: () -> Void = {}

    var body: some View {
        switch turn {
        case .user(_, let text):
            HStack {
                Spacer(minLength: 40)
                Text(text)
                    .padding(10)
                    .background(Color.accentColor.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        case .agent(_, let text, let toolCalls):
            VStack(alignment: .leading, spacing: 6) {
                Text(text)
                    .padding(10)
                    .background(Color.secondary.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !toolCalls.isEmpty {
                    ForEach(toolCalls) { record in
                        ToolCallRow(record: record)
                            .padding(.leading, 12)
                    }
                }
            }
        case .system(_, let text):
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.yellow)
                VStack(alignment: .leading, spacing: 6) {
                    Text(text)
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if text.lowercased().contains("set up hermes") {
                        Button("Set Up Hermes…") {
                            onOpenSetupSheet()
                        }
                        .controlSize(.small)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
        }
    }
}

struct ToolCallRow: View {
    let record: HermesClient.ToolCallRecord
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ScrollView(.horizontal) {
                Text(record.argsFull)
                    .font(.system(.caption, design: .monospaced))
                    .padding(8)
            }
            .background(Color.secondary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        } label: {
            HStack(spacing: 6) {
                Text("▸")
                Text(record.argsPreview)
                    .font(.system(.caption, design: .monospaced))
                Spacer()
                Text(record.status.rawValue)
                    .font(.caption2)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(statusBackground)
                    .clipShape(Capsule())
            }
        }
        .font(.caption)
    }

    private var statusBackground: Color {
        switch record.status {
        case .pending:   return Color.yellow.opacity(0.25)
        case .completed: return Color.green.opacity(0.25)
        case .failed:    return Color.red.opacity(0.25)
        }
    }
}
