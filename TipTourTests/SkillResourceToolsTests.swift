// TipTourTests/SkillResourceToolsTests.swift

import Foundation
import Testing
@testable import TipTour

@Suite("SkillLibraryStore.listResources / fetchResource")
struct SkillLibraryStoreResourceTests {

    private static func freshDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tiptour-resource-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Build a spec-format skill on disk with optional sub-files.
    static func writeSkill(
        in dir: URL,
        slug: String,
        extraFiles: [(relativePath: String, content: String)] = []
    ) {
        let folder = dir.appendingPathComponent(slug, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let skillMd = folder.appendingPathComponent("SKILL.md")
        try? """
        ---
        id: 11111111-1111-1111-1111-111111111111
        name: \(slug)
        description: Resource fixture
        taskTypes: [coding]
        keywords: []
        createdAt: 2026-05-13
        ---

        body
        """.write(to: skillMd, atomically: true, encoding: .utf8)
        for extra in extraFiles {
            let target = folder.appendingPathComponent(extra.relativePath)
            try? FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? extra.content.write(to: target, atomically: true, encoding: .utf8)
        }
    }

    @Test func listResourcesReturnsEmptyWhenOnlySkillMD() async {
        let dir = Self.freshDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        Self.writeSkill(in: dir, slug: "plain")
        let store = SkillLibraryStore(directoryURL: dir)
        let resources = await store.listResources(slug: "plain")
        #expect(resources.isEmpty)
    }

    @Test func listResourcesEnumeratesNonSkillMDFiles() async {
        let dir = Self.freshDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        Self.writeSkill(in: dir, slug: "rich", extraFiles: [
            (relativePath: "references/REFERENCE.md", content: "ref"),
            (relativePath: "templates/intro.md", content: "tpl"),
            (relativePath: "scripts/run.sh", content: "#!/bin/bash"),
        ])
        let store = SkillLibraryStore(directoryURL: dir)
        let resources = await store.listResources(slug: "rich")
        // Sorted output:
        #expect(resources == [
            "references/REFERENCE.md",
            "scripts/run.sh",
            "templates/intro.md"
        ])
    }

    @Test func fetchResourceReturnsContent() async {
        let dir = Self.freshDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        Self.writeSkill(in: dir, slug: "ref-skill", extraFiles: [
            (relativePath: "references/REFERENCE.md", content: "Reference content here"),
        ])
        let store = SkillLibraryStore(directoryURL: dir)
        let content = await store.fetchResource(slug: "ref-skill", relativePath: "references/REFERENCE.md")
        #expect(content == "Reference content here")
    }

    @Test func fetchResourceRejectsPathTraversal() async {
        let dir = Self.freshDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        Self.writeSkill(in: dir, slug: "tricky")
        let store = SkillLibraryStore(directoryURL: dir)
        let escape = await store.fetchResource(
            slug: "tricky",
            relativePath: "../../../../etc/passwd"
        )
        #expect(escape == nil)
    }

    @Test func fetchResourceRejectsAbsolutePath() async {
        let dir = Self.freshDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        Self.writeSkill(in: dir, slug: "tricky")
        let store = SkillLibraryStore(directoryURL: dir)
        let abs = await store.fetchResource(slug: "tricky", relativePath: "/etc/passwd")
        #expect(abs == nil)
    }

    @Test func fetchResourceReturnsNilForMissingFile() async {
        let dir = Self.freshDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        Self.writeSkill(in: dir, slug: "x")
        let store = SkillLibraryStore(directoryURL: dir)
        let missing = await store.fetchResource(slug: "x", relativePath: "references/missing.md")
        #expect(missing == nil)
    }
}

@Suite("ReadSkillResourceTool")
struct ReadSkillResourceToolTests {

    private static func freshStore() -> (SkillLibraryStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tiptour-resource-tool-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (SkillLibraryStore(directoryURL: dir), dir)
    }

    @Test func returnsResourceContentForValidArgs() async {
        let (store, dir) = Self.freshStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        SkillLibraryStoreResourceTests.writeSkill(in: dir, slug: "tool-test", extraFiles: [
            (relativePath: "references/REFERENCE.md", content: "Hello from reference"),
        ])
        // Recreate the store so its index picks up the manually-written skill folder.
        let store2 = SkillLibraryStore(directoryURL: dir)
        let tool = ReadSkillResourceTool(taskType: .coding, store: store2)
        let result = await tool.execute(argumentsJSON: #"{"slug":"tool-test","relative_path":"references/REFERENCE.md"}"#)
        #expect(result == "Hello from reference")
    }

    @Test func errorsOnMissingArgs() async {
        let (store, dir) = Self.freshStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tool = ReadSkillResourceTool(taskType: .coding, store: store)
        let result = await tool.execute(argumentsJSON: #"{"slug":"x"}"#)
        #expect(result.lowercased().contains("error"))
    }

    @Test func errorsOnPathTraversalAttempt() async {
        let (store, dir) = Self.freshStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        SkillLibraryStoreResourceTests.writeSkill(in: dir, slug: "trav")
        let store2 = SkillLibraryStore(directoryURL: dir)
        let tool = ReadSkillResourceTool(taskType: .coding, store: store2)
        let result = await tool.execute(argumentsJSON: #"{"slug":"trav","relative_path":"../../../../etc/passwd"}"#)
        #expect(result.lowercased().contains("error"))
        #expect(result.contains("rejected for security"))
    }
}
