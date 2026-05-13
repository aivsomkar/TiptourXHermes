// TipTour/Agents/Skills/SkillLibraryStore.swift

import Foundation

actor SkillLibraryStore {

    static let shared = SkillLibraryStore()

    private var index: [SkillEntry] = []
    private let directoryURL: URL
    /// Maximum number of skills retained on disk + in memory. Beyond
    /// this we LRU-evict the oldest entries on `write`. The cap was 200
    /// before we started shipping 153 bundled RuFlo+OpenWork skills;
    /// raised to 1000 so the bundled set never gets evicted by
    /// user-saved skills accumulating over time. If a bundled skill IS
    /// somehow evicted, `BundledSkillSeeder` re-adds it on next launch
    /// (the seeder runs every launch, idempotently).
    private let maximumRetainedSkillCount: Int = 1000

    static var defaultDirectoryURL: URL {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("TipTour", isDirectory: true)
            .appendingPathComponent("skills", isDirectory: true)
    }

    init(directoryURL: URL = SkillLibraryStore.defaultDirectoryURL) {
        self.directoryURL = directoryURL
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        // Spec-compliant skills live as `<slug>/SKILL.md`. Enumerate
        // subdirectories and parse each one's SKILL.md. Folders without a
        // SKILL.md (or with malformed frontmatter) are silently ignored —
        // they may be in-flight from a partial copy or migration.
        let topLevelEntries = (try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []

        let skillFolders = topLevelEntries.filter { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }

        self.index = skillFolders.compactMap { folderURL in
            let skillMarkdownURL = folderURL.appendingPathComponent("SKILL.md")
            guard FileManager.default.fileExists(atPath: skillMarkdownURL.path),
                  let content = try? String(contentsOf: skillMarkdownURL, encoding: .utf8) else {
                return nil
            }
            return SkillEntry.parse(from: content, slug: folderURL.lastPathComponent)
        }
    }

    // MARK: - Path resolution

    private func skillFolderURL(slug: String) -> URL {
        directoryURL.appendingPathComponent(slug, isDirectory: true)
    }

    private func skillMarkdownURL(slug: String) -> URL {
        skillFolderURL(slug: slug).appendingPathComponent("SKILL.md")
    }

    /// Returns the current set of slugs on disk. Used by
    /// `BundledSkillSeeder` to decide which bundled skills are missing
    /// and need to be installed for the user.
    func existingSlugs() -> Set<String> {
        Set(index.map(\.slug))
    }

    /// Write a bundled (upstream) skill with caller-supplied taskTypes,
    /// keywords, and body. Unlike `write`, this does NOT run dedup
    /// suffixing — the seeder is responsible for not calling it with
    /// a slug that's already present (and the contract is enforced by
    /// the seeder's `existingSlugs` precheck). Skipping dedup keeps the
    /// bundled slug stable across launches so the user can rely on
    /// `recall_skill("agent-coder")` always meaning the same skill.
    /// Returns the slug on success, nil on disk-write failure.
    @discardableResult
    func writeBundledSkill(
        slug: String,
        name: String,
        description: String,
        taskTypes: [TaskType],
        keywords: [String],
        body: String
    ) -> String? {
        let entry = SkillEntry(
            id: UUID(),
            slug: slug,
            name: name,
            description: SkillSpecValidator.clampedDescription(description, skillSlug: slug),
            taskTypes: taskTypes,
            keywords: keywords,
            createdAt: Date.now
        )
        let folderURL = skillFolderURL(slug: slug)
        let fileURL = skillMarkdownURL(slug: slug)
        let fileContent = entry.frontmatter + "\n\n" + body
        do {
            try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
            try fileContent.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            print("[SkillLibraryStore] bundled write failed for '\(slug)': \(error.localizedDescription)")
            return nil
        }
        if let existing = index.firstIndex(where: { $0.slug == slug }) {
            index[existing] = entry
        } else {
            index.append(entry)
            evictOldestIfOverCapacity()
        }
        return slug
    }

    /// Drop the oldest entries when the library exceeds its size cap.
    /// Called from `write` after appending a new entry; deletes both
    /// the in-memory record and the on-disk skill folder so storage
    /// stays bounded for users who run many agent tasks.
    private func evictOldestIfOverCapacity() {
        guard index.count > maximumRetainedSkillCount else { return }
        let sorted = index.sorted { $0.createdAt < $1.createdAt }
        let overage = index.count - maximumRetainedSkillCount
        let toEvict = sorted.prefix(overage)
        for victim in toEvict {
            try? FileManager.default.removeItem(at: skillFolderURL(slug: victim.slug))
            index.removeAll { $0.slug == victim.slug }
        }
        print("[SkillLibraryStore] evicted \(toEvict.count) oldest skill(s) to stay under \(maximumRetainedSkillCount)")
    }

    // MARK: - Write

    /// Writes a skill to disk and updates the in-memory index. Returns
    /// the final on-disk slug (which may differ from `slug` if a sibling
    /// already owned it — we append `-2`, `-3`, etc.). Returns nil when
    /// the disk write failed, in which case the index is NOT updated —
    /// otherwise we'd advertise a skill that callers can't `fetchBody`.
    ///
    /// Callers that need the post-rewrite slug (e.g. EfficiencyMonitor
    /// when re-saving an "improved" version of an auto-saved skill)
    /// MUST capture this return value rather than re-deriving the base
    /// slug from the task description.
    @discardableResult
    func write(
        slug: String,
        name: String,
        description: String,
        taskTypes: [TaskType],
        body: String
    ) async -> String? {
        // Validate or coerce the slug into spec-compliant form before
        // dedup so two callers passing equivalent-but-invalid slugs
        // don't both succeed under different sanitized names.
        let normalized = SkillNameValidator.isValid(slug) ? slug : SkillNameValidator.sanitize(slug)
        guard !normalized.isEmpty else {
            print("[SkillLibraryStore] write rejected: slug '\(slug)' sanitized to empty")
            return nil
        }
        let finalSlug = deduplicatedSlug(for: normalized)
        let clampedDescription = SkillSpecValidator.clampedDescription(description, skillSlug: finalSlug)
        let keywords = AgentMemoryEntry.extractKeywords(from: name + " " + clampedDescription)
        let entry = SkillEntry(
            id: UUID(),
            slug: finalSlug,
            name: name,
            description: clampedDescription,
            taskTypes: taskTypes,
            keywords: keywords,
            createdAt: Date.now
        )
        let folderURL = skillFolderURL(slug: finalSlug)
        let fileURL = skillMarkdownURL(slug: finalSlug)
        let fileContent = entry.frontmatter + "\n\n" + body
        do {
            try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
            try fileContent.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            // Disk write failed (full disk, permissions, sandbox).
            // Leave the index alone — a phantom entry pointing at a
            // missing file is strictly worse than a missing entry.
            print("[SkillLibraryStore] write failed for '\(finalSlug)': \(error.localizedDescription)")
            return nil
        }
        if let existing = index.firstIndex(where: { $0.slug == finalSlug }) {
            index[existing] = entry
        } else {
            index.append(entry)
            evictOldestIfOverCapacity()
        }
        return finalSlug
    }

    /// Update an existing skill's body in place (slug, name, taskTypes,
    /// keywords preserved). Returns true when the on-disk file was
    /// rewritten successfully. Used by EfficiencyMonitor's self-critique
    /// pass to improve an auto-saved skill without creating a sibling
    /// entry under a different deduped slug.
    @discardableResult
    func updateBody(slug: String, body: String) async -> Bool {
        guard let entry = index.first(where: { $0.slug == slug }) else {
            print("[SkillLibraryStore] updateBody: no entry for slug '\(slug)' — skipping")
            return false
        }
        let fileContent = entry.frontmatter + "\n\n" + body
        let fileURL = skillMarkdownURL(slug: slug)
        do {
            try fileContent.write(to: fileURL, atomically: true, encoding: .utf8)
            return true
        } catch {
            print("[SkillLibraryStore] updateBody failed for '\(slug)': \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - All entries (for Settings UI)

    func allEntries() async -> [SkillEntry] {
        index.sorted { $0.createdAt > $1.createdAt }
    }

    // MARK: - Query

    func query(taskDescription: String, taskTypes: [TaskType], limit: Int = 10) async -> [SkillEntry] {
        let descriptionKeywords = Set(AgentMemoryEntry.extractKeywords(from: taskDescription))
        let targetTaskTypes = Set(taskTypes)

        let scored: [(entry: SkillEntry, score: Int)] = index.compactMap { entry in
            var score = 0
            if !Set(entry.taskTypes).isDisjoint(with: targetTaskTypes) { score += 2 }
            score += Set(entry.keywords).intersection(descriptionKeywords).count
            guard score > 0 else { return nil }
            return (entry, score)
        }

        return scored.sorted { $0.score > $1.score }.prefix(limit).map(\.entry)
    }

    // MARK: - Fetch body

    func fetchBody(slug: String) async -> String? {
        let fileURL = skillMarkdownURL(slug: slug)
        return try? String(contentsOf: fileURL, encoding: .utf8)
    }

    // MARK: - Delete

    func delete(slug: String) async {
        try? FileManager.default.removeItem(at: skillFolderURL(slug: slug))
        index.removeAll { $0.slug == slug }
    }

    // MARK: - Clear (used in tests and future settings UI)

    func clear() async {
        let allEntries = (try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        )) ?? []
        for url in allEntries {
            try? FileManager.default.removeItem(at: url)
        }
        index = []
    }

    // MARK: - Slug generation

    /// Converts a name to a URL-safe, lowercase, hyphen-separated slug (max 60 chars).
    static func generateSlug(from name: String) -> String {
        let raw = name.lowercased().unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? String($0) : "-" }
            .joined()
        let collapsed = raw.components(separatedBy: "-").filter { !$0.isEmpty }.joined(separator: "-")
        let trimmed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return String(trimmed.prefix(60))
    }

    // MARK: - Private helpers

    private func deduplicatedSlug(for base: String) -> String {
        let existing = Set(index.map(\.slug))
        guard existing.contains(base) else { return base }
        var counter = 2
        while existing.contains("\(base)-\(counter)") { counter += 1 }
        return "\(base)-\(counter)"
    }
}

// MARK: - Resource enumeration (Phase C — progressive disclosure)

extension SkillLibraryStore {

    /// List every non-SKILL.md file inside a skill's folder, as paths
    /// relative to the folder root. Used by `RecallSkillTool` to
    /// advertise the resources available for progressive disclosure
    /// per the agentskills.io spec.
    func listResources(slug: String) async -> [String] {
        let folder = skillFolderURL(slug: slug)
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var results: [String] = []
        let folderPath = folder.path
        for case let fileURL as URL in enumerator
        where (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            if fileURL.lastPathComponent == "SKILL.md" { continue }
            let absolutePath = fileURL.path
            guard absolutePath.hasPrefix(folderPath + "/") else { continue }
            let relativePath = String(absolutePath.dropFirst(folderPath.count + 1))
            results.append(relativePath)
        }
        return results.sorted()
    }

    /// Read a single file inside a skill's folder by relative path.
    /// Rejects absolute paths and any path containing `..` to prevent
    /// agents from escaping the skill folder via path traversal.
    func fetchResource(slug: String, relativePath: String) async -> String? {
        guard !relativePath.hasPrefix("/"),
              !relativePath.contains("..") else { return nil }
        let folder = skillFolderURL(slug: slug)
        let target = folder.appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: target.path) else { return nil }
        return try? String(contentsOf: target, encoding: .utf8)
    }
}

// MARK: - Folder install (Phase B)

extension SkillLibraryStore {

    /// Install a spec-format skill folder (containing `SKILL.md` plus
    /// optional `references/`/`templates/`/`scripts/`/`assets/`) into
    /// the store. The slug is sanitized through `SkillNameValidator`,
    /// and the SKILL.md frontmatter is parsed via
    /// `SkillFrontmatterParser` (a fresh UUID is generated since
    /// upstream spec-format files don't carry an `id:` field). Returns
    /// the final on-disk slug on success or nil on failure.
    ///
    /// - Parameter slug: the desired slug. Usually the source folder's
    ///   last path component. Sanitized via `SkillNameValidator.sanitize`
    ///   if it doesn't already match the spec.
    /// - Parameter source: a directory URL containing at least
    ///   `SKILL.md` and any optional resource subfolders.
    /// - Parameter overrideExisting: when true, replaces an existing
    ///   skill with the same slug. Default false — caller gets nil
    ///   on collision so the import flow can route to `skipped`
    ///   instead of clobbering bundled skills.
    @discardableResult
    func installSkillFolder(
        slug rawSlug: String,
        source sourceFolderURL: URL,
        overrideExisting: Bool = false
    ) async -> String? {
        // Validate or coerce the slug.
        let slug = SkillNameValidator.isValid(rawSlug) ? rawSlug : SkillNameValidator.sanitize(rawSlug)
        guard !slug.isEmpty else {
            print("[SkillLibraryStore] installSkillFolder: slug '\(rawSlug)' sanitized to empty")
            return nil
        }

        // Read + parse SKILL.md from the source. Spec-format files
        // (RuFlo, Hermes, Anthropic-spec) ship with `name:` /
        // `description:` only — no `id:` field — so we use the shared
        // frontmatter splitter and build the SkillEntry ourselves with
        // a fresh UUID. Same pattern `BundledSkillSeeder.parse(...)`
        // and `SkillImporter` use.
        let sourceSkillMd = sourceFolderURL.appendingPathComponent("SKILL.md")
        guard let rawContent = try? String(contentsOf: sourceSkillMd, encoding: .utf8) else {
            print("[SkillLibraryStore] installSkillFolder: no SKILL.md in \(sourceFolderURL.path)")
            return nil
        }
        let split = SkillFrontmatterParser.split(rawContent)
        guard let skillName = split.frontmatter["name"], !skillName.isEmpty else {
            print("[SkillLibraryStore] installSkillFolder: SKILL.md in '\(slug)' missing name frontmatter")
            return nil
        }
        let skillDescription = split.frontmatter["description"] ?? "Imported skill"
        let inferredTaskTypes = SkillFrontmatterParser.inferTaskTypes(
            slug: slug, name: skillName, description: skillDescription
        )
        let inferredKeywords = SkillFrontmatterParser.inferKeywords(
            slug: slug, name: skillName, description: skillDescription
        )
        let entry = SkillEntry(
            id: UUID(),
            slug: slug,
            name: skillName,
            description: SkillSpecValidator.clampedDescription(skillDescription, skillSlug: slug),
            taskTypes: inferredTaskTypes,
            keywords: inferredKeywords,
            createdAt: Date.now,
            license: split.frontmatter["license"],
            compatibility: SkillSpecValidator.clampedCompatibility(split.frontmatter["compatibility"], skillSlug: slug),
            allowedTools: split.frontmatter["allowed-tools"]
        )

        // Resolve destination, handling collision.
        let destination = skillFolderURL(slug: slug)
        if FileManager.default.fileExists(atPath: destination.path) {
            guard overrideExisting else {
                return nil
            }
            try? FileManager.default.removeItem(at: destination)
        }

        // Copy the whole source folder verbatim. This is the
        // load-bearing line of the spec-importer effort: every file
        // alongside SKILL.md (references/, templates/, scripts/,
        // assets/) rides along.
        do {
            try FileManager.default.copyItem(at: sourceFolderURL, to: destination)
        } catch {
            print("[SkillLibraryStore] installSkillFolder: copy failed for '\(slug)': \(error.localizedDescription)")
            return nil
        }

        // Update the in-memory index.
        if let existing = index.firstIndex(where: { $0.slug == slug }) {
            index[existing] = entry
        } else {
            index.append(entry)
            evictOldestIfOverCapacity()
        }
        return slug
    }
}
