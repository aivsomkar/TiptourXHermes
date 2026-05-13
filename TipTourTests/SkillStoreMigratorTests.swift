// TipTourTests/SkillStoreMigratorTests.swift

import Foundation
import Testing
@testable import TipTour

@Suite("SkillStoreMigrator")
struct SkillStoreMigratorTests {

    private static func freshDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tiptour-migrator-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func writeFlatSkill(in dir: URL, slug: String, body: String = "body") {
        let url = dir.appendingPathComponent("\(slug).md")
        try? body.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func writeFolderSkill(in dir: URL, slug: String, body: String = "body") {
        let folder = dir.appendingPathComponent(slug, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? body.write(to: folder.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    }

    @Test func migratesEachFlatFileIntoSkillFolder() async {
        let dir = Self.freshDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        Self.writeFlatSkill(in: dir, slug: "agent-coder", body: "coder body")
        Self.writeFlatSkill(in: dir, slug: "dogfood", body: "dogfood body")

        await SkillStoreMigrator.migrate(directoryURL: dir)

        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("agent-coder/SKILL.md").path))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("dogfood/SKILL.md").path))
        // Flat files are gone (moved, not copied).
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("agent-coder.md").path))
    }

    @Test func noOpOnFolderOnlyInput() async {
        let dir = Self.freshDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        Self.writeFolderSkill(in: dir, slug: "already-spec", body: "body")
        await SkillStoreMigrator.migrate(directoryURL: dir)

        // Folder still there, SKILL.md inside intact.
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("already-spec/SKILL.md").path))
    }

    @Test func preservesFolderSkillsAlongsideMigratingFlats() async {
        let dir = Self.freshDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        Self.writeFolderSkill(in: dir, slug: "existing-spec")
        Self.writeFlatSkill(in: dir, slug: "legacy-flat")

        await SkillStoreMigrator.migrate(directoryURL: dir)

        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("existing-spec/SKILL.md").path))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("legacy-flat/SKILL.md").path))
    }

    @Test func sanitizesInvalidLegacyName() async {
        let dir = Self.freshDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        Self.writeFlatSkill(in: dir, slug: "My Old Skill", body: "x")
        await SkillStoreMigrator.migrate(directoryURL: dir)

        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("my-old-skill/SKILL.md").path))
    }

    @Test func dedupesWhenSanitizedSlugCollidesWithExistingFolder() async {
        let dir = Self.freshDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Existing spec folder occupies the slug.
        Self.writeFolderSkill(in: dir, slug: "agent-coder", body: "spec-version")
        // Flat file would land at the same slug — should be deduped.
        Self.writeFlatSkill(in: dir, slug: "agent-coder", body: "flat-version")

        await SkillStoreMigrator.migrate(directoryURL: dir)

        // Original folder still here with original content.
        let existing = try? String(contentsOf: dir.appendingPathComponent("agent-coder/SKILL.md"), encoding: .utf8)
        #expect(existing == "spec-version")

        // Migrated flat lands under -2.
        let migrated = try? String(contentsOf: dir.appendingPathComponent("agent-coder-2/SKILL.md"), encoding: .utf8)
        #expect(migrated == "flat-version")
    }

    @Test func skipsFlatFileWhoseStemSanitizesToEmpty() async {
        let dir = Self.freshDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // "---.md" — stem is "---", sanitize returns "".
        let weird = dir.appendingPathComponent("---.md")
        try? "x".write(to: weird, atomically: true, encoding: .utf8)

        await SkillStoreMigrator.migrate(directoryURL: dir)

        // No folder created; file left where it was (caller can clean).
        #expect(FileManager.default.fileExists(atPath: weird.path))
        // Directory has no subdirs.
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let subdirs = contents.filter {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path, isDirectory: &isDir)
            return isDir.boolValue
        }
        #expect(subdirs.isEmpty)
    }

    @Test func runIfNeededSetsFlagAndIsIdempotent() async {
        let dir = Self.freshDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Reset the flag so this test starts clean.
        let key = "skillStoreSpecMigrationV1Complete"
        let originalValue = UserDefaults.standard.bool(forKey: key)
        UserDefaults.standard.set(false, forKey: key)
        defer { UserDefaults.standard.set(originalValue, forKey: key) }

        Self.writeFlatSkill(in: dir, slug: "alpha", body: "1")

        await SkillStoreMigrator.runIfNeeded(directoryURL: dir)
        #expect(UserDefaults.standard.bool(forKey: key) == true)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("alpha/SKILL.md").path))

        // Second invocation must be a no-op — even if we re-add a flat
        // file, it should NOT be migrated because the flag is set.
        Self.writeFlatSkill(in: dir, slug: "beta", body: "2")
        await SkillStoreMigrator.runIfNeeded(directoryURL: dir)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("beta/SKILL.md").path))
        // beta.md still flat:
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("beta.md").path))
    }
}
