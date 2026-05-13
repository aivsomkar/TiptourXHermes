// TipTourTests/SkillLibraryStoreFolderTests.swift

import Foundation
import Testing
@testable import TipTour

@Suite("SkillLibraryStore folder layout")
struct SkillLibraryStoreFolderTests {

    private static func freshStoreDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tiptour-folder-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func writeCreatesSkillFolderWithSkillMD() async {
        let dir = Self.freshStoreDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SkillLibraryStore(directoryURL: dir)

        let slug = await store.write(
            slug: "test-skill",
            name: "Test Skill",
            description: "desc",
            taskTypes: [.coding],
            body: "# body"
        )

        #expect(slug == "test-skill")
        let folderPath = dir.appendingPathComponent("test-skill").path
        let skillPath = dir.appendingPathComponent("test-skill").appendingPathComponent("SKILL.md").path
        #expect(FileManager.default.fileExists(atPath: folderPath))
        #expect(FileManager.default.fileExists(atPath: skillPath))
    }

    @Test func writeRejectsAndSanitizesInvalidSlug() async {
        let dir = Self.freshStoreDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SkillLibraryStore(directoryURL: dir)

        let slug = await store.write(
            slug: "INVALID Slug!",
            name: "x", description: "x",
            taskTypes: [.coding], body: "body"
        )
        #expect(slug == "invalid-slug")
    }

    @Test func writeEmptyAfterSanitizationReturnsNil() async {
        let dir = Self.freshStoreDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SkillLibraryStore(directoryURL: dir)

        let slug = await store.write(
            slug: "---",
            name: "x", description: "x",
            taskTypes: [.coding], body: "body"
        )
        #expect(slug == nil)
    }

    @Test func writeDedupesCollidingSlugs() async {
        let dir = Self.freshStoreDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SkillLibraryStore(directoryURL: dir)

        _ = await store.write(slug: "x", name: "a", description: "a", taskTypes: [.coding], body: "1")
        let second = await store.write(slug: "x", name: "b", description: "b", taskTypes: [.coding], body: "2")
        #expect(second == "x-2")
    }

    @Test func fetchBodyReturnsContentFromSkillMD() async {
        let dir = Self.freshStoreDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SkillLibraryStore(directoryURL: dir)

        _ = await store.write(slug: "abc", name: "n", description: "d", taskTypes: [.coding], body: "BODY")
        let raw = await store.fetchBody(slug: "abc")
        #expect(raw?.contains("BODY") == true)
        #expect(raw?.contains("---") == true) // frontmatter present
    }

    @Test func deleteRemovesEntireFolder() async {
        let dir = Self.freshStoreDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SkillLibraryStore(directoryURL: dir)

        _ = await store.write(slug: "to-delete", name: "n", description: "d", taskTypes: [.coding], body: "x")
        // Drop an extra file into the folder to verify cascading removal.
        let extra = dir.appendingPathComponent("to-delete").appendingPathComponent("note.txt")
        try? "extra".write(to: extra, atomically: true, encoding: .utf8)

        await store.delete(slug: "to-delete")

        let folderPath = dir.appendingPathComponent("to-delete").path
        #expect(!FileManager.default.fileExists(atPath: folderPath))
    }

    @Test func initIgnoresLooseFlatMarkdownFiles() async {
        let dir = Self.freshStoreDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Drop a flat legacy file at the top level.
        let legacy = dir.appendingPathComponent("legacy.md")
        try? "---\nid: 00000000-0000-0000-0000-000000000000\nname: legacy\n---\nbody"
            .write(to: legacy, atomically: true, encoding: .utf8)

        let store = SkillLibraryStore(directoryURL: dir)
        let entries = await store.allEntries()
        // The flat file must be invisible to the new init.
        #expect(entries.allSatisfy { $0.slug != "legacy" })
    }

    @Test func initLoadsSpecFolderSkills() async {
        let dir = Self.freshStoreDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Build a hand-rolled spec skill on disk.
        let folder = dir.appendingPathComponent("manual-skill", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let skillMd = folder.appendingPathComponent("SKILL.md")
        let frontmatter = """
        ---
        id: 11111111-1111-1111-1111-111111111111
        name: manual-skill
        description: A manually built skill
        taskTypes: [coding]
        keywords: []
        createdAt: 2026-05-13
        ---

        Body content.
        """
        try? frontmatter.write(to: skillMd, atomically: true, encoding: .utf8)

        let store = SkillLibraryStore(directoryURL: dir)
        let entries = await store.allEntries()
        #expect(entries.contains(where: { $0.slug == "manual-skill" }))
    }
}
