// TipTour/Agents/Memory/AgentMemoryStore.swift

import Foundation

actor AgentMemoryStore {

    static let shared = AgentMemoryStore()

    private var entries: [AgentMemoryEntry] = []
    private let fileURL: URL

    static var defaultFileURL: URL {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let tipTourDir = appSupport.appendingPathComponent("TipTour", isDirectory: true)
        return tipTourDir.appendingPathComponent("agent-memory.json")
    }

    init(fileURL: URL = AgentMemoryStore.defaultFileURL) {
        self.fileURL = fileURL
        // Ensure the parent directory exists before reading or writing.
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if let data = try? Data(contentsOf: fileURL),
           let loaded = try? JSONDecoder().decode([AgentMemoryEntry].self, from: data) {
            self.entries = loaded
        }
        // Prune expired entries at load time without an async hop.
        let now = Date.now
        self.entries = self.entries.filter { entry in
            guard let expiresAt = entry.expiresAt else { return true }
            return expiresAt >= now
        }
    }

    // MARK: - Write

    func write(
        content: String,
        entryType: MemoryEntryType,
        taskTypes: [TaskType],
        permanent: Bool = false  // only applies to .fact entries; .taskResult always expires in 7 days
    ) async {
        let entry: AgentMemoryEntry
        switch entryType {
        case .fact:
            entry = AgentMemoryEntry.makeFact(content: content, taskTypes: taskTypes, permanent: permanent)
        case .taskResult:
            entry = AgentMemoryEntry.makeTaskResult(content: content, taskTypes: taskTypes)
        }
        entries.append(entry)
        pruneExpiredSync()
        saveToDisk()
    }

    /// Inserts an entry verbatim — used in tests to inject entries with custom expiry dates.
    func writeRawEntry(_ entry: AgentMemoryEntry) async {
        entries.append(entry)
        saveToDisk()
    }

    // MARK: - Query

    func query(taskDescription: String, taskTypes: [TaskType], limit: Int = 20) async -> [AgentMemoryEntry] {
        let taskDescriptionKeywords = Set(AgentMemoryEntry.extractKeywords(from: taskDescription))
        let targetTaskTypes = Set(taskTypes)

        let scored: [(entry: AgentMemoryEntry, score: Int)] = entries.compactMap { entry in
            guard !entry.isExpired else { return nil }
            var score = 0
            if !Set(entry.taskTypes).isDisjoint(with: targetTaskTypes) {
                score += 2
            }
            score += Set(entry.keywords).intersection(taskDescriptionKeywords).count
            if entry.isPermanent { score += 1 }
            guard score > 0 else { return nil }
            return (entry, score)
        }

        return scored
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map(\.entry)
    }

    // MARK: - Prune

    func pruneExpired() async {
        pruneExpiredSync()
        saveToDisk()
    }

    // MARK: - Clear

    func clear(keepPermanent: Bool = true) async {
        if keepPermanent {
            entries = entries.filter(\.isPermanent)
        } else {
            entries = []
        }
        saveToDisk()
    }

    // MARK: - Private helpers

    private func pruneExpiredSync() {
        let now = Date.now
        entries = entries.filter { entry in
            guard let expiresAt = entry.expiresAt else { return true }
            return expiresAt >= now
        }
    }

    private func saveToDisk() {
        let data: Data
        do {
            data = try JSONEncoder().encode(entries)
        } catch {
            // Codable encoding shouldn't fail for AgentMemoryEntry, but
            // surface it loudly if it ever does — silently dropping
            // facts is worse than a noisy log we can audit.
            print("[AgentMemoryStore] encode failed: \(error.localizedDescription)")
            return
        }
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Disk full, sandbox denial, etc. The in-memory store has
            // already been mutated by the caller; we just can't
            // persist. Log so users hitting "my memory keeps
            // disappearing across launches" have a breadcrumb.
            print("[AgentMemoryStore] write failed for \(fileURL.path): \(error.localizedDescription)")
        }
    }
}
