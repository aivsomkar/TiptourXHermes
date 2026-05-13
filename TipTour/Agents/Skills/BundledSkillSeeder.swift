// TipTour/Agents/Skills/BundledSkillSeeder.swift

import Foundation

/// Loads the bundled `.md` files under `BundledSkills/ruflo/` and
/// `BundledSkills/openwork/` and writes them into the user's
/// `SkillLibraryStore` if not already present.
///
/// Two source upstreams:
///   - **RuFlo** (https://github.com/ruvnet/ruflo) — 100+ `.agents/skills/*/SKILL.md`
///     describing methodology-flavored agent prompts (SPARC, DDD, GitHub
///     workflow, security audit, etc.). These are the foundation of
///     RuFlo's multi-framework subagent system.
///   - **OpenWork** (https://github.com/different-ai/openwork) —
///     `.opencode/skills/*/SKILL.md`, `.opencode/agent/*.md`, and
///     `.opencode/commands/*.md`. OpenCode's plain-english behavior
///     patterns plus its built-in agents and slash commands.
///
/// Each upstream skill has a YAML frontmatter with `name` + `description`
/// and free-form body. We re-emit them in TipTour's `SkillEntry`
/// frontmatter format (id, slug, name, description, taskTypes, keywords,
/// createdAt) and write to `~/Library/Application Support/TipTour/skills/`.
///
/// **Idempotency rule:** skipping any slug already on disk. That means
/// the seed runs on every app launch (cheap — 153 file existence checks)
/// and only creates files that don't exist yet. User customizations to
/// existing skills are never clobbered.
enum BundledSkillSeeder {

    /// One-shot flag for forcing a re-seed of all bundled skills.
    /// Bumped whenever an on-disk format / parser change requires
    /// rewriting bundled skills that were installed under the
    /// previous version. Currently set for the v1 block-scalar parser
    /// fix — pre-fix installs stored block-scalar descriptions as the
    /// literal `>` or `|` characters, which the new parser would
    /// otherwise read back as empty strings.
    private static let bundledSkillFormatVersionKey = "bundledSkillFormatVersion"
    private static let currentBundledSkillFormatVersion = 1

    /// Seed bundled skills if missing. Safe to call repeatedly.
    /// Each bundled skill is a spec-format folder under
    /// `BundledSkills/ruflo/<slug>/SKILL.md`; we install the whole
    /// folder via `SkillLibraryStore.installSkillFolder` so any
    /// `references/`/`templates/`/`scripts/`/`assets/` subdirectories
    /// upstream RuFlo provides ride along with `SKILL.md`.
    ///
    /// When `bundledSkillFormatVersion` in `UserDefaults` is below
    /// `currentBundledSkillFormatVersion`, every bundled slug is
    /// re-installed with `overrideExisting: true` to repair entries
    /// written by a prior buggy code path (e.g. v0 stored
    /// `description: >` literally because the parser didn't understand
    /// YAML block scalars).
    static func seedBundledSkillsIfNeeded() async {
        let store = SkillLibraryStore.shared
        let existingSlugs = await store.existingSlugs()

        let skillFolders = enumerateBundledSkillFolders()
        guard !skillFolders.isEmpty else {
            print("[BundledSkillSeeder] no bundled skill folders found in app bundle")
            return
        }

        let storedVersion = UserDefaults.standard.integer(forKey: bundledSkillFormatVersionKey)
        let forceRescan = storedVersion < currentBundledSkillFormatVersion

        var seededCount = 0
        var repairedCount = 0
        var skippedCount = 0
        for folderURL in skillFolders {
            let slug = folderURL.lastPathComponent
            let isAlreadyInstalled = existingSlugs.contains(slug)
            if isAlreadyInstalled, !forceRescan {
                skippedCount += 1
                continue
            }
            // overrideExisting is only true during a rescan, so under
            // normal operation user customizations to bundled-slug
            // bodies still survive.
            let installed = await store.installSkillFolder(
                slug: slug,
                source: folderURL,
                overrideExisting: forceRescan
            )
            guard installed != nil else { continue }
            if isAlreadyInstalled {
                repairedCount += 1
            } else {
                seededCount += 1
            }
        }
        if forceRescan {
            UserDefaults.standard.set(currentBundledSkillFormatVersion, forKey: bundledSkillFormatVersionKey)
        }
        print("[BundledSkillSeeder] seeded \(seededCount), repaired \(repairedCount), \(skippedCount) already present")
    }

    // MARK: - Bundle enumeration

    /// Walk every direct subdirectory of `BundledSkills/ruflo/` that
    /// contains a `SKILL.md` and return the folder URLs. Each match
    /// represents one bundled skill in spec-compliant format.
    /// OpenWork was dropped from the bundled set in the spec migration
    /// phase — users who want OpenWork can re-import it at runtime via
    /// the spec-aware importer.
    private static func enumerateBundledSkillFolders() -> [URL] {
        guard let resourcePath = Bundle.main.resourcePath else { return [] }
        let resourceURL = URL(fileURLWithPath: resourcePath)
        let rufloRoot = resourceURL
            .appendingPathComponent("BundledSkills", isDirectory: true)
            .appendingPathComponent("ruflo", isDirectory: true)
        guard FileManager.default.fileExists(atPath: rufloRoot.path) else { return [] }
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: rufloRoot,
            includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []
        return entries.filter { folderURL in
            guard (try? folderURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return false }
            let skillMd = folderURL.appendingPathComponent("SKILL.md")
            return FileManager.default.fileExists(atPath: skillMd.path)
        }
    }

}
