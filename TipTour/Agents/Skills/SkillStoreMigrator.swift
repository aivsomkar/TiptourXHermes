// TipTour/Agents/Skills/SkillStoreMigrator.swift

import Foundation

/// One-shot upgrade step: moves any flat `<slug>.md` files at the top
/// of the skill store directory into spec-compliant `<slug>/SKILL.md`
/// folders. Idempotent and gated by a UserDefaults flag so it runs at
/// most once per install.
///
/// Why a migration: TipTour's pre-v2 skill store wrote each skill as a
/// single `.md` file. The agentskills.io spec mandates a folder per
/// skill so supporting `references/`, `templates/`, `scripts/`, and
/// `assets/` can ride along. This migrator preserves every user-saved
/// flat file so first launch after upgrade doesn't drop work.
///
/// **Run before `BundledSkillSeeder`.** If the seeder ran first it would
/// write folder-format files that the migrator would ignore (folder, not
/// `.md`), while still leaving pre-existing flat files in a confused
/// state.
enum SkillStoreMigrator {

    /// UserDefaults key. Set to true after the migration loop returns,
    /// regardless of whether any individual file failed — failed
    /// files stay on disk as flat .md, are invisible to the new
    /// folder-only `SkillLibraryStore.init`, and can be deleted by
    /// hand if needed.
    private static let migrationCompletedKey = "skillStoreSpecMigrationV1Complete"

    /// Entry point. Idempotent.
    static func runIfNeeded(directoryURL: URL = SkillLibraryStore.defaultDirectoryURL) async {
        if UserDefaults.standard.bool(forKey: migrationCompletedKey) { return }
        await migrate(directoryURL: directoryURL)
        UserDefaults.standard.set(true, forKey: migrationCompletedKey)
    }

    /// Internal workhorse. Exposed for tests so we can drive specific
    /// directory states without the UserDefaults gate.
    static func migrate(directoryURL: URL) async {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey]
        )) ?? []

        let flatFiles = contents.filter {
            $0.pathExtension == "md" &&
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }

        var existingSlugs = Set(
            contents
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                .map { $0.lastPathComponent }
        )

        var migrated = 0
        for fileURL in flatFiles {
            let rawStem = fileURL.deletingPathExtension().lastPathComponent

            // Spec rule: parent folder name = skill name. Coerce
            // legacy/imported stems that don't already match the
            // spec into a compliant form.
            let baseSlug = SkillNameValidator.isValid(rawStem)
                ? rawStem
                : SkillNameValidator.sanitize(rawStem)

            // Sanitizer can return "" for inputs like "---" or "$$$".
            // Skip those rather than colliding under a generic
            // fallback slug — the user can delete those .md files
            // by hand from ~/Library/Application Support/TipTour/skills/
            // if they care.
            guard !baseSlug.isEmpty else {
                print("[SkillStoreMigrator] skipping '\(rawStem)': empty after sanitization")
                continue
            }

            let finalSlug = deduplicate(baseSlug, against: existingSlugs)
            existingSlugs.insert(finalSlug)

            let folderURL = directoryURL.appendingPathComponent(finalSlug, isDirectory: true)
            let destinationURL = folderURL.appendingPathComponent("SKILL.md")

            do {
                try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: fileURL, to: destinationURL)
                migrated += 1
            } catch {
                print("[SkillStoreMigrator] failed for '\(rawStem)': \(error.localizedDescription)")
            }
        }

        if migrated > 0 {
            print("[SkillStoreMigrator] migrated \(migrated) flat skill file(s) to folder format")
        }
    }

    /// Suffix `-2`, `-3`, etc. when the base slug collides with an
    /// existing folder. Mirrors `SkillLibraryStore.deduplicatedSlug`.
    private static func deduplicate(_ base: String, against existing: Set<String>) -> String {
        if !existing.contains(base) { return base }
        var counter = 2
        while existing.contains("\(base)-\(counter)") { counter += 1 }
        return "\(base)-\(counter)"
    }
}
