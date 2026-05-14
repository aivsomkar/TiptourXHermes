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
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // JARVIS-style chat window header — fixed band at the top
            // with monospaced uppercase title + a thin cyan baseline.
            HStack {
                Text("HERMES // CHAT")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .tracking(1.6)
                    .foregroundColor(DS.Colors.jarvisAccent)
                Spacer()
                Text(client.isWorking ? "►  WORKING" : "◌  IDLE")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(1.0)
                    .foregroundColor(client.isWorking ? DS.Colors.jarvisAccent : DS.Colors.textTertiary)
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 6)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(DS.Colors.jarvisBorder)
                    .frame(height: 1)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(client.transcript) { turn in
                            ChatTurnRow(turn: turn)
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
                Text(">")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(DS.Colors.jarvisAccent)
                TextField("message hermes…", text: $draft, axis: .vertical)
                    .lineLimit(1...6)
                    .focused($inputFocused)
                    .onSubmit(send)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(DS.Colors.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        ZStack {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(DS.Colors.surface1)
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .strokeBorder(
                                    inputFocused ? DS.Colors.jarvisAccent : DS.Colors.jarvisBorder,
                                    lineWidth: 1
                                )
                        }
                    )
                Button(action: send) {
                    Text("SEND")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .tracking(1.6)
                        .foregroundColor(DS.Colors.jarvisAccent)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .strokeBorder(DS.Colors.jarvisAccent, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: [])
                .disabled(draft.isEmpty || client.isWorking)
                .opacity(draft.isEmpty || client.isWorking ? 0.4 : 1.0)
            }
            .padding(12)
        }
        .frame(minWidth: 480, minHeight: 360)
        .onAppear { inputFocused = true }
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

    var body: some View {
        switch turn {
        case .user(_, let text):
            HStack {
                Spacer(minLength: 40)
                Text(text)
                    .font(.system(size: 13, weight: .regular, design: .default))
                    .foregroundColor(DS.Colors.textPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        ZStack {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(DS.Colors.jarvisAccentDim.opacity(0.12))
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .strokeBorder(DS.Colors.jarvisBorder, lineWidth: 1)
                        }
                    )
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        case .agent(_, let text, let toolCalls):
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 6) {
                    Text(">")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundColor(DS.Colors.jarvisAccent)
                        .padding(.top, 9)
                    Text(text)
                        .font(.system(size: 13, weight: .regular, design: .default))
                        .foregroundColor(DS.Colors.textPrimary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(DS.Colors.surface2)
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !toolCalls.isEmpty {
                    ForEach(toolCalls) { record in
                        ToolCallRow(record: record)
                            .padding(.leading, 18)
                    }
                }
            }
        case .system(_, let text):
            // System rows surface setup-error transcripts in a yellow-
            // warning style. The user reads the message and opens the
            // Dev section in the menu bar panel to pick a provider and
            // paste a key — no inline button needed.
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(DS.Colors.warning)
                Text(text.uppercased())
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundColor(DS.Colors.warningText)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(DS.Colors.warning.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(DS.Colors.warning.opacity(0.3), lineWidth: 1)
            )
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
                    .foregroundColor(DS.Colors.jarvisAccent)
                Text(record.argsPreview)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(DS.Colors.textSecondary)
                Spacer()
                Text(record.status.rawValue.uppercased())
                    .font(.system(.caption2, design: .monospaced))
                    .tracking(0.8)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(statusBackground)
                    .clipShape(Capsule())
            }
        }
        .font(.caption)
    }

    private var statusBackground: Color {
        switch record.status {
        case .pending:   return DS.Colors.warning.opacity(0.25)
        case .completed: return DS.Colors.jarvisAccent.opacity(0.25)
        case .failed:    return DS.Colors.destructive.opacity(0.25)
        }
    }
}
