// TipTour/Agents/Memory/AgentMemoryEntry.swift

import Foundation

enum MemoryEntryType: String, Codable, Sendable {
    case fact
    case taskResult
}

struct AgentMemoryEntry: Codable, Identifiable, Sendable {
    let id: UUID
    let content: String
    let entryType: MemoryEntryType
    let taskTypes: [TaskType]
    let keywords: [String]
    let createdAt: Date
    /// Nil means permanent — never pruned.
    let expiresAt: Date?

    var isPermanent: Bool { expiresAt == nil }
    var isExpired: Bool {
        guard let expiresAt else { return false }
        return expiresAt < Date.now
    }

    static func makeFact(content: String, taskTypes: [TaskType], permanent: Bool) -> AgentMemoryEntry {
        AgentMemoryEntry(
            id: UUID(),
            content: content,
            entryType: .fact,
            taskTypes: taskTypes,
            keywords: AgentMemoryEntry.extractKeywords(from: content),
            createdAt: Date.now,
            expiresAt: permanent ? nil : Date.now.addingTimeInterval(30 * 24 * 3600)
        )
    }

    static func makeTaskResult(content: String, taskTypes: [TaskType]) -> AgentMemoryEntry {
        AgentMemoryEntry(
            id: UUID(),
            content: content,
            entryType: .taskResult,
            taskTypes: taskTypes,
            keywords: AgentMemoryEntry.extractKeywords(from: content),
            createdAt: Date.now,
            expiresAt: Date.now.addingTimeInterval(7 * 24 * 3600)
        )
    }
}

// MARK: - Keyword extraction

extension AgentMemoryEntry {
    static func extractKeywords(from text: String) -> [String] {
        let stopWords: Set<String> = [
            "the", "a", "an", "is", "are", "was", "were", "be", "been", "being",
            "have", "has", "had", "do", "does", "did", "will", "would", "could",
            "should", "may", "might", "shall", "can", "need", "dare", "ought",
            "used", "to", "of", "in", "on", "at", "by", "for", "with", "about",
            "as", "into", "through", "during", "before", "after", "above", "below",
            "from", "up", "down", "out", "off", "over", "under", "again", "then",
            "once", "and", "but", "or", "nor", "so", "yet", "both", "not",
            "this", "that", "it", "its"
        ]
        let separators = CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: ".,!?;:()\"'/-_"))
        let tokens = text.lowercased()
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 3 && !stopWords.contains($0) }
        return Array(Set(tokens)).sorted()
    }
}
