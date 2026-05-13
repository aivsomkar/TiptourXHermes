// TipTour/Hermes/HermesClient.swift
//
// Swift ACP client for the bundled hermes-runtime Python subprocess.
// Owns: subprocess lifecycle, JSON-RPC framing, and the @Published
// transcript state consumed by HermesChatView. SwiftUI-friendly because
// every published mutation happens on @MainActor.

import Foundation
import Combine

@MainActor
final class HermesClient: ObservableObject {

    // MARK: Published state
    @Published private(set) var transcript: [ChatTurn] = []
    @Published private(set) var isWorking: Bool = false
    @Published private(set) var lastError: String?

    // MARK: Init
    /// - Parameter hermesHome: Test-only override for the `HERMES_HOME` env
    ///   var passed to the subprocess. Production callers should leave this
    ///   `nil` so Hermes uses its default (`~/.hermes/`).
    init(hermesHome: URL? = nil) {
        self.hermesHomeOverride = hermesHome
    }

    // MARK: Public API
    func send(_ userText: String) async {
        // Implemented in Tasks 5–7.
        _ = userText
    }

    func stop() {
        // Implemented in Task 8.
    }

    // MARK: Types

    enum ChatTurn: Identifiable {
        case user(id: UUID, text: String)
        case agent(id: UUID, text: String, toolCalls: [ToolCallRecord])
        case system(id: UUID, text: String)

        var id: UUID {
            switch self {
            case .user(let i, _),
                 .agent(let i, _, _),
                 .system(let i, _):
                return i
            }
        }
    }

    struct ToolCallRecord: Identifiable, Equatable {
        let id: String
        let name: String
        let argsPreview: String
        let argsFull: String
        var status: Status

        enum Status: String, Equatable { case pending, completed, failed }
    }

    // MARK: Internal state (impl tasks 5–8)
    private let hermesHomeOverride: URL?
}
