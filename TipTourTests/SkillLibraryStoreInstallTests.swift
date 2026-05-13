// TipTourTests/SkillLibraryStoreInstallTests.swift

import Foundation
import Testing
@testable import TipTour

@Suite("SkillLibraryStore.installSkillFolder")
struct SkillLibraryStoreInstallTests {

    private static func freshDir(label: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tiptour-install-\(label)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Build a spec-format skill source folder. NO `id:` field — that's
    /// the upstream norm; `installSkillFolder` generates one.
    private static func writeSourceSkill(
        at sourceURL: URL,
        name: String,
        withReferences: Bool = false
    ) {
        try? FileManager.default.createDirectory(at: sourceURL, withIntermediateDirectories: true)
        let skillMd = sourceURL.appendingPathComponent("SKILL.md")
        try? """
        ---
        name: \(name)
        description: Fixture skill for install tests
        ---

        # \(name)
        body
        """.write(to: skillMd, atomically: true, encoding: .utf8)
        if withReferences {
            let refDir = sourceURL.appendingPathComponent("references", isDirectory: true)
            try? FileManager.default.createDirectory(at: refDir, withIntermediateDirectories: true)
            try? "Reference content".write(
                to: refDir.appendingPathComponent("REFERENCE.md"),
                atomically: true,
                encoding: .utf8
            )
        }
    }

    @Test func installsSkillFolderWithSkillMD() async {
        let storeDir = Self.freshDir(label: "store")
        let sourceParent = Self.freshDir(label: "src")
        defer {
            try? FileManager.default.removeItem(at: storeDir)
            try? FileManager.default.removeItem(at: sourceParent)
        }
        let sourceURL = sourceParent.appendingPathComponent("agent-coder", isDirectory: true)
        Self.writeSourceSkill(at: sourceURL, name: "agent-coder")

        let store = SkillLibraryStore(directoryURL: storeDir)
        let slug = await store.installSkillFolder(slug: "agent-coder", source: sourceURL)

        #expect(slug == "agent-coder")
        #expect(FileManager.default.fileExists(
            atPath: storeDir.appendingPathComponent("agent-coder/SKILL.md").path
        ))
    }

    @Test func copiesReferencesFolderAlongside() async {
        let storeDir = Self.freshDir(label: "store")
        let sourceParent = Self.freshDir(label: "src")
        defer {
            try? FileManager.default.removeItem(at: storeDir)
            try? FileManager.default.removeItem(at: sourceParent)
        }
        let sourceURL = sourceParent.appendingPathComponent("skill-with-refs", isDirectory: true)
        Self.writeSourceSkill(at: sourceURL, name: "skill-with-refs", withReferences: true)

        let store = SkillLibraryStore(directoryURL: storeDir)
        _ = await store.installSkillFolder(slug: "skill-with-refs", source: sourceURL)

        let copiedRef = storeDir
            .appendingPathComponent("skill-with-refs")
            .appendingPathComponent("references")
            .appendingPathComponent("REFERENCE.md")
        #expect(FileManager.default.fileExists(atPath: copiedRef.path))
        let copiedContent = try? String(contentsOf: copiedRef, encoding: .utf8)
        #expect(copiedContent == "Reference content")
    }

    @Test func returnsNilWhenSkillMDLacksNameFrontmatter() async {
        let storeDir = Self.freshDir(label: "store")
        let sourceParent = Self.freshDir(label: "src")
        defer {
            try? FileManager.default.removeItem(at: storeDir)
            try? FileManager.default.removeItem(at: sourceParent)
        }
        let sourceURL = sourceParent.appendingPathComponent("bad-skill", isDirectory: true)
        try? FileManager.default.createDirectory(at: sourceURL, withIntermediateDirectories: true)
        try? """
        ---
        description: missing name
        ---

        body
        """.write(to: sourceURL.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        let store = SkillLibraryStore(directoryURL: storeDir)
        let slug = await store.installSkillFolder(slug: "bad-skill", source: sourceURL)

        #expect(slug == nil)
        let destFolder = storeDir.appendingPathComponent("bad-skill").path
        #expect(!FileManager.default.fileExists(atPath: destFolder))
    }

    @Test func returnsNilOnCollisionWhenOverrideDisabled() async {
        let storeDir = Self.freshDir(label: "store")
        let sourceParent = Self.freshDir(label: "src")
        defer {
            try? FileManager.default.removeItem(at: storeDir)
            try? FileManager.default.removeItem(at: sourceParent)
        }
        let sourceURL = sourceParent.appendingPathComponent("dup", isDirectory: true)
        Self.writeSourceSkill(at: sourceURL, name: "dup")

        let store = SkillLibraryStore(directoryURL: storeDir)
        let first = await store.installSkillFolder(slug: "dup", source: sourceURL)
        #expect(first == "dup")

        let second = await store.installSkillFolder(slug: "dup", source: sourceURL, overrideExisting: false)
        #expect(second == nil)
    }

    @Test func overridesExistingWhenFlagSet() async {
        let storeDir = Self.freshDir(label: "store")
        let sourceParent = Self.freshDir(label: "src")
        defer {
            try? FileManager.default.removeItem(at: storeDir)
            try? FileManager.default.removeItem(at: sourceParent)
        }
        let v1URL = sourceParent.appendingPathComponent("ver-skill", isDirectory: true)
        Self.writeSourceSkill(at: v1URL, name: "ver-skill")

        let store = SkillLibraryStore(directoryURL: storeDir)
        _ = await store.installSkillFolder(slug: "ver-skill", source: v1URL)

        let updatedMd = """
        ---
        name: ver-skill
        description: Version 2
        ---

        V2 BODY
        """
        try? updatedMd.write(to: v1URL.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        let second = await store.installSkillFolder(slug: "ver-skill", source: v1URL, overrideExisting: true)
        #expect(second == "ver-skill")

        let onDisk = try? String(
            contentsOf: storeDir.appendingPathComponent("ver-skill/SKILL.md"),
            encoding: .utf8
        )
        #expect(onDisk?.contains("V2 BODY") == true)
        #expect(onDisk?.contains("Version 2") == true)
    }

    @Test func sanitizesInvalidSlug() async {
        let storeDir = Self.freshDir(label: "store")
        let sourceParent = Self.freshDir(label: "src")
        defer {
            try? FileManager.default.removeItem(at: storeDir)
            try? FileManager.default.removeItem(at: sourceParent)
        }
        let sourceURL = sourceParent.appendingPathComponent("anything", isDirectory: true)
        Self.writeSourceSkill(at: sourceURL, name: "My Skill")

        let store = SkillLibraryStore(directoryURL: storeDir)
        let slug = await store.installSkillFolder(slug: "My Skill", source: sourceURL)
        #expect(slug == "my-skill")
        #expect(FileManager.default.fileExists(
            atPath: storeDir.appendingPathComponent("my-skill/SKILL.md").path
        ))
    }
}
