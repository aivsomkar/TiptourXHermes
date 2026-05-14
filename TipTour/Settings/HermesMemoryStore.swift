// TipTour/Settings/HermesMemoryStore.swift
//
// Owns ~/.hermes/memories/USER.md — Hermes's user-facts memory file.
// Plain text. Reads return "" when missing. Writes are atomic via
// write-tmp + atomic rename, so Hermes never sees a partial file
// (even if it has its own writer racing ours). We ignore the
// USER.md.lock sentinel Hermes creates — empirically it's a 0-byte
// marker, not a real flock, and atomic-rename is safe enough for
// a user-driven editing UI.

import Foundation

struct HermesMemoryStore {

    let hermesHome: URL

    init(hermesHome: URL? = nil) {
        self.hermesHome = hermesHome
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".hermes", isDirectory: true)
    }

    var filePath: URL {
        hermesHome
            .appendingPathComponent("memories", isDirectory: true)
            .appendingPathComponent("USER.md")
    }

    /// Returns the file's UTF-8 contents, or "" if the file or parent
    /// directory doesn't exist. Never throws — missing/unreadable file
    /// is treated as empty so the UI can render a clean blank state.
    func read() -> String {
        guard let data = try? Data(contentsOf: filePath),
              let text = String(data: data, encoding: .utf8) else {
            return ""
        }
        return text
    }

    /// Atomically writes `text` to filePath. Creates the parent
    /// directory if missing. Empty input writes an empty file (not
    /// a delete) — matches the "this file always exists once the
    /// user has touched it" expectation Hermes appears to share.
    func write(_ text: String) throws {
        let dir = filePath.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(".USER.md.\(UUID().uuidString).tmp")
        try text.write(to: tmp, atomically: false, encoding: .utf8)
        do {
            try FileManager.default.replaceItem(
                at: filePath,
                withItemAt: tmp,
                backupItemName: nil,
                options: [],
                resultingItemURL: nil
            )
        } catch CocoaError.fileNoSuchFile {
            // Destination didn't exist — just move tmp into place.
            try FileManager.default.moveItem(at: tmp, to: filePath)
        }
    }
}
