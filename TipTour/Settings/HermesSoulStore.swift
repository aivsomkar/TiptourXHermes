// TipTour/Settings/HermesSoulStore.swift
//
// Owns ~/.hermes/SOUL.md — Hermes's system prompt. Plain text. Same
// atomic-rename pattern as HermesMemoryStore but separate type because
// the semantics differ (replace, not accumulate; per-runtime, not
// per-user).

import Foundation

struct HermesSoulStore {

    let hermesHome: URL

    init(hermesHome: URL? = nil) {
        self.hermesHome = hermesHome
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".hermes", isDirectory: true)
    }

    var filePath: URL {
        hermesHome.appendingPathComponent("SOUL.md")
    }

    func read() -> String {
        guard let data = try? Data(contentsOf: filePath),
              let text = String(data: data, encoding: .utf8) else {
            return ""
        }
        return text
    }

    func write(_ text: String) throws {
        try FileManager.default.createDirectory(at: hermesHome, withIntermediateDirectories: true)
        let tmp = hermesHome.appendingPathComponent(".SOUL.md.\(UUID().uuidString).tmp")
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
            try FileManager.default.moveItem(at: tmp, to: filePath)
        }
    }
}
