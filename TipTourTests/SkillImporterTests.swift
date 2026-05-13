// TipTourTests/SkillImporterTests.swift

import Foundation
import Testing
@testable import TipTour

@Suite("SkillFrontmatterParser")
struct SkillFrontmatterParserTests {

    @Test func splitFrontmatterReturnsKeysAndBody() {
        let raw = """
        ---
        name: my-skill
        description: A test skill
        ---

        # Body
        Body content.
        """
        let result = SkillFrontmatterParser.split(raw)
        #expect(result.frontmatter["name"] == "my-skill")
        #expect(result.frontmatter["description"] == "A test skill")
        #expect(result.body.contains("# Body"))
    }

    @Test func splitTreatsMissingOpenerAsBodyOnly() {
        let raw = "no frontmatter here\nsecond line"
        let result = SkillFrontmatterParser.split(raw)
        #expect(result.frontmatter.isEmpty)
        #expect(result.body == raw)
    }

    @Test func sanitizeSlugLowercasesAndHyphenates() {
        #expect(SkillFrontmatterParser.sanitizeSlug("My Skill Name!") == "my-skill-name")
        #expect(SkillFrontmatterParser.sanitizeSlug("agent-coder") == "agent-coder")
        #expect(SkillFrontmatterParser.sanitizeSlug("--multi---dash--") == "multi-dash")
    }

    @Test func inferTaskTypesPicksCodingForCodingMarkers() {
        let types = SkillFrontmatterParser.inferTaskTypes(
            slug: "agent-coder", name: "Coder", description: "writes code"
        )
        #expect(types.contains(.coding))
    }

    @Test func inferTaskTypesFallsBackToGeneralMacWhenNothingMatches() {
        let types = SkillFrontmatterParser.inferTaskTypes(
            slug: "unknown-thing", name: "Unknown", description: "no markers here"
        )
        #expect(types == [.generalMac])
    }
}

@Suite("SkillImporter URL parsing")
struct SkillImporterURLParsingTests {

    @Test func parsesStandardRepoURL() throws {
        let parsed = try SkillImporter.parseGitHubURL("https://github.com/ruvnet/ruflo")
        #expect(parsed.owner == "ruvnet")
        #expect(parsed.repo == "ruflo")
        #expect(parsed.subpath == nil)
        #expect(parsed.branch == "main")
    }

    @Test func parsesTreeURLWithSubpath() throws {
        let parsed = try SkillImporter.parseGitHubURL(
            "https://github.com/ruvnet/ruflo/tree/main/.agents/skills"
        )
        #expect(parsed.owner == "ruvnet")
        #expect(parsed.repo == "ruflo")
        #expect(parsed.subpath == ".agents/skills")
        #expect(parsed.branch == "main")
    }

    @Test func parsesTreeURLWithDifferentBranch() throws {
        let parsed = try SkillImporter.parseGitHubURL(
            "https://github.com/foo/bar/tree/develop/skills"
        )
        #expect(parsed.branch == "develop")
        #expect(parsed.subpath == "skills")
    }

    @Test func rejectsNonGitHubURL() {
        #expect(throws: SkillImporter.ImportError.self) {
            try SkillImporter.parseGitHubURL("https://gitlab.com/foo/bar")
        }
    }

    @Test func rejectsMalformedURL() {
        #expect(throws: SkillImporter.ImportError.self) {
            try SkillImporter.parseGitHubURL("not even a url")
        }
    }

    @Test func rejectsBlobURL() {
        #expect(throws: SkillImporter.ImportError.self) {
            try SkillImporter.parseGitHubURL("https://github.com/owner/repo/blob/main/README.md")
        }
    }

    @Test func rejectsPullRequestURL() {
        #expect(throws: SkillImporter.ImportError.self) {
            try SkillImporter.parseGitHubURL("https://github.com/owner/repo/pull/123")
        }
    }

    @Test func stripsDotGitSuffixFromRepoName() throws {
        let parsed = try SkillImporter.parseGitHubURL("https://github.com/foo/bar.git")
        #expect(parsed.repo == "bar")
        #expect(parsed.owner == "foo")
    }
}

@Suite("SkillImporter extraction")
struct SkillImporterExtractionTests {

    @Test func extractsMarkdownFromTarball() async throws {
        let bundle = Bundle(for: TipTourTestsAnchor.self)
        guard let fixtureURL = bundle.url(forResource: "skill-folder-fixture", withExtension: "tar.gz") else {
            Issue.record("Missing fixture skill-folder-fixture.tar.gz in TipTourTests resources")
            return
        }
        let importer = SkillImporter()
        let extractedURL = try await importer.extractTarball(at: fixtureURL)
        defer { try? FileManager.default.removeItem(at: extractedURL) }

        // Fixture has 4 .md files total: test-importer-skill/SKILL.md,
        // test-importer-skill/references/REFERENCE.md, empty-skill/SKILL.md,
        // not-a-skill-dir/notes.md.
        let mdFiles = try FileManager.default.subpathsOfDirectory(atPath: extractedURL.path)
            .filter { $0.hasSuffix(".md") }
        #expect(mdFiles.count == 4)
    }
}

@Suite("SkillImporter import pipeline")
struct SkillImporterImportTests {

    @Test func importFromExtractedDirectoryWritesSkillsToStore() async throws {
        let bundle = Bundle(for: TipTourTestsAnchor.self)
        guard let fixtureURL = bundle.url(forResource: "skill-folder-fixture", withExtension: "tar.gz") else {
            Issue.record("Missing fixture skill-folder-fixture.tar.gz in TipTourTests resources")
            return
        }

        // Use a fresh, isolated store directory so the test doesn't
        // collide with the user's real skill library.
        let testStoreDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tiptour-test-store-\(UUID().uuidString)", isDirectory: true)
        let testStore = SkillLibraryStore(directoryURL: testStoreDir)
        defer { try? FileManager.default.removeItem(at: testStoreDir) }

        let importer = SkillImporter()
        let extracted = try await importer.extractTarball(at: fixtureURL)
        defer { try? FileManager.default.removeItem(at: extracted) }

        let report = await importer.importFromExtractedDirectory(
            extracted,
            subpath: nil,
            store: testStore
        )

        // test-importer-skill imports successfully (valid frontmatter).
        #expect(report.imported.count == 1)
        #expect(report.imported.contains("test-importer-skill"))
        // empty-skill has SKILL.md but no `name:` frontmatter — counts as failed.
        #expect(report.failed.count == 1)
        // not-a-skill-dir has no SKILL.md — entirely invisible to the report.
        #expect(!report.imported.contains("not-a-skill-dir"))
        #expect(!report.failed.contains("not-a-skill-dir"))

        // The references file rode along with its parent skill folder.
        let copiedReference = testStoreDir
            .appendingPathComponent("test-importer-skill")
            .appendingPathComponent("references")
            .appendingPathComponent("REFERENCE.md")
        #expect(FileManager.default.fileExists(atPath: copiedReference.path))
    }
}

/// Anchor class so `Bundle(for:)` resolves the test bundle.
private final class TipTourTestsAnchor {}
