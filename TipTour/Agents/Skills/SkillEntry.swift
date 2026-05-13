// TipTour/Agents/Skills/SkillEntry.swift

import Foundation

// MARK: - One tool call captured during agent execution

struct RecordedToolCall: Codable, Sendable {
    let toolName: String
    let argumentsJSON: String
    let result: String
}

// MARK: - Thread-safe buffer the agent writes to as it executes tools

/// Holds the ordered list of tool calls made during a task run.
/// Using a lock instead of an actor so it can be read synchronously from SaveSkillTool.execute.
final class ToolCallHistoryBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [RecordedToolCall] = []

    func append(_ call: RecordedToolCall) {
        lock.withLock { _calls.append(call) }
    }

    var calls: [RecordedToolCall] {
        lock.withLock { _calls }
    }
}

// MARK: - In-memory index entry for one skill .md file

struct SkillEntry: Identifiable, Sendable {
    let id: UUID
    let slug: String
    let name: String
    let description: String
    let taskTypes: [TaskType]
    let keywords: [String]
    let createdAt: Date
    /// Optional agentskills.io spec fields. Persisted in frontmatter
    /// only when non-nil so existing skills without these fields
    /// round-trip cleanly.
    let license: String?
    let compatibility: String?
    let allowedTools: String?

    init(
        id: UUID,
        slug: String,
        name: String,
        description: String,
        taskTypes: [TaskType],
        keywords: [String],
        createdAt: Date,
        license: String? = nil,
        compatibility: String? = nil,
        allowedTools: String? = nil
    ) {
        self.id = id
        self.slug = slug
        self.name = name
        self.description = description
        self.taskTypes = taskTypes
        self.keywords = keywords
        self.createdAt = createdAt
        self.license = license
        self.compatibility = compatibility
        self.allowedTools = allowedTools
    }

    /// Parses a SkillEntry from the frontmatter block of a `.md` file.
    /// Returns nil if the `---` opening marker is absent or the `name`
    /// field is missing.
    ///
    /// Three on-disk formats coexist and must all decode here:
    ///   1. **Spec-compliant TipTour-saved skills** (post-metadata-move):
    ///      `id`, `taskTypes`, `keywords`, `createdAt` live under a
    ///      top-level `metadata:` map as agentskills.io recommends for
    ///      client-specific fields. Spec fields (`name`, `description`,
    ///      `license`, `compatibility`, `allowed-tools`) stay at root.
    ///   2. **Legacy TipTour-saved skills** (pre-metadata-move): all
    ///      fields at the frontmatter root. We still read these so
    ///      users don't lose work on upgrade — the next `write`
    ///      organically rewrites them in the new format.
    ///   3. **Spec-only upstream skills** (RuFlo, OpenWork, etc.):
    ///      `name` + `description` only. We recover TipTour routing
    ///      metadata (`taskTypes`, `keywords`) via the inferrers below.
    static func parse(from fileContent: String, slug: String) -> SkillEntry? {
        let split = SkillFrontmatterParser.split(fileContent)

        guard let name = split.frontmatter["name"], !name.isEmpty else { return nil }

        let description = split.frontmatter["description"] ?? ""

        // Prefer the metadata-nested value (spec-compliant, format #1),
        // fall back to top-level (legacy, format #2), then to inference
        // (upstream, format #3). The three-tier lookup keeps us
        // compatible with every on-disk skill the user might have.
        let taskTypesRaw = split.metadata["taskTypes"] ?? split.frontmatter["taskTypes"]
        let taskTypes: [TaskType] = taskTypesRaw
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "[]")) }?
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .compactMap { TaskType(rawValue: $0) }
            ?? SkillFrontmatterParser.inferTaskTypes(slug: slug, name: name, description: description)

        let keywordsRaw = split.metadata["keywords"] ?? split.frontmatter["keywords"]
        let keywords: [String] = keywordsRaw
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "[]")) }?
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            ?? SkillFrontmatterParser.inferKeywords(slug: slug, name: name, description: description)

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        let createdAtRaw = split.metadata["createdAt"] ?? split.frontmatter["createdAt"]
        let createdAt = createdAtRaw.flatMap { dateFormatter.date(from: $0) } ?? Date.now

        let idRaw = split.metadata["id"] ?? split.frontmatter["id"]
        let id: UUID = idRaw.flatMap { UUID(uuidString: $0) } ?? UUID()

        return SkillEntry(
            id: id,
            slug: slug,
            name: name,
            description: description,
            taskTypes: taskTypes,
            keywords: keywords,
            createdAt: createdAt,
            license: split.frontmatter["license"],
            compatibility: split.frontmatter["compatibility"],
            allowedTools: split.frontmatter["allowed-tools"]
        )
    }

    /// Generates the YAML frontmatter block for writing to disk.
    ///
    /// Layout follows the agentskills.io spec: only spec-defined keys
    /// (`name`, `description`, `license`, `compatibility`,
    /// `allowed-tools`) live at the frontmatter root. TipTour-specific
    /// fields (`id`, `taskTypes`, `keywords`, `createdAt`) live under
    /// the spec's `metadata:` map so a stricter validator like
    /// `skills-ref validate` accepts our files. `SkillEntry.parse`
    /// reads both this new format and the legacy format where these
    /// fields lived at the root, so existing on-disk skills keep
    /// working until the next write rewrites them.
    var frontmatter: String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        let taskTypesStr = taskTypes.map(\.rawValue).joined(separator: ", ")
        let keywordsStr = keywords.joined(separator: ", ")
        var lines = "---\n"
            + "name: \(name)\n"
            + "description: \(description)\n"
        if let license { lines += "license: \(license)\n" }
        if let compatibility { lines += "compatibility: \(compatibility)\n" }
        if let allowedTools { lines += "allowed-tools: \(allowedTools)\n" }
        lines += "metadata:\n"
            + "  id: \(id.uuidString)\n"
            + "  taskTypes: [\(taskTypesStr)]\n"
            + "  keywords: [\(keywordsStr)]\n"
            + "  createdAt: \(dateFormatter.string(from: createdAt))\n"
        lines += "---"
        return lines
    }
}

// MARK: - Generates the markdown body of a skill file from tool call history

enum SkillBodyBuilder {
    static func build(
        name: String,
        toolCalls: [RecordedToolCall],
        resultSummary: String
    ) -> String {
        var lines: [String] = ["# \(name)", ""]

        if !toolCalls.isEmpty {
            lines.append("## Steps")
            lines.append("")
            for (index, call) in toolCalls.enumerated() {
                let resultPreview = String(call.result.prefix(200))
                lines.append("\(index + 1). **\(call.toolName)** `\(call.argumentsJSON)`")
                lines.append("   → \(resultPreview)")
                lines.append("")
            }
        }

        lines.append("## Result")
        lines.append("")
        lines.append(String(resultSummary.prefix(300)))

        return lines.joined(separator: "\n")
    }
}
