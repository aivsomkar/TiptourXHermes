// TipTourTests/SkillFrontmatterParserBlockScalarTests.swift

import Foundation
import Testing
@testable import TipTour

@Suite("SkillFrontmatterParser block scalars")
struct SkillFrontmatterParserBlockScalarTests {

    /// Reproduces the RuFlo `agent-coordination/SKILL.md` shape that
    /// silently lost its description with the old line-splitter parser.
    /// Folded `>` block scalars must join continuation lines with
    /// spaces and not stop at the first `:` inside the content.
    @Test func foldedBlockScalarJoinsContinuationLines() {
        let raw = """
        ---
        name: agent-coordination
        description: >
          Agent spawning, lifecycle management, and coordination patterns.
          Use when: spawning agents, coordinating multi-agent tasks.
          Skip when: single-agent work, no coordination needed.
        ---

        # body
        """
        let result = SkillFrontmatterParser.split(raw)
        #expect(result.frontmatter["name"] == "agent-coordination")
        let expectedDescription = "Agent spawning, lifecycle management, and coordination patterns. Use when: spawning agents, coordinating multi-agent tasks. Skip when: single-agent work, no coordination needed."
        #expect(result.frontmatter["description"] == expectedDescription)
        #expect(result.body.contains("# body"))
    }

    @Test func foldedBlockScalarConvertsBlankLineToParagraphBreak() {
        let raw = """
        ---
        name: paragraph-fold
        description: >
          First paragraph line.

          Second paragraph line.
        ---
        """
        let result = SkillFrontmatterParser.split(raw)
        #expect(result.frontmatter["description"] == "First paragraph line.\nSecond paragraph line.")
    }

    @Test func literalBlockScalarPreservesNewlines() {
        let raw = """
        ---
        name: literal-block
        description: |
          line one
          line two
          line three
        ---
        """
        let result = SkillFrontmatterParser.split(raw)
        #expect(result.frontmatter["description"] == "line one\nline two\nline three")
    }

    @Test func plainScalarStillParses() {
        let raw = """
        ---
        name: plain
        description: A plain one-line description.
        ---
        """
        let result = SkillFrontmatterParser.split(raw)
        #expect(result.frontmatter["description"] == "A plain one-line description.")
    }

    @Test func blockScalarOnLastFieldBeforeClosingMarker() {
        let raw = """
        ---
        name: trailing-block
        description: >
          only a single continuation line
        ---
        """
        let result = SkillFrontmatterParser.split(raw)
        #expect(result.frontmatter["description"] == "only a single continuation line")
    }
}

@Suite("SkillFrontmatterParser metadata map")
struct SkillFrontmatterParserMetadataMapTests {

    @Test func parsesIndentedMetadataChildren() {
        let raw = """
        ---
        name: spec-skill
        description: A skill using the spec metadata map.
        metadata:
          author: example-org
          version: "1.0"
        ---
        """
        let result = SkillFrontmatterParser.split(raw)
        #expect(result.metadata["author"] == "example-org")
        #expect(result.metadata["version"] == "1.0")
        #expect(result.frontmatter["name"] == "spec-skill")
    }

    @Test func unquotesSingleQuotedMetadataValues() {
        let raw = """
        ---
        name: single-quoted
        description: x
        metadata:
          flavor: 'spicy'
        ---
        """
        let result = SkillFrontmatterParser.split(raw)
        #expect(result.metadata["flavor"] == "spicy")
    }

    @Test func metadataChildrenDoNotLeakIntoTopLevelDict() {
        let raw = """
        ---
        name: isolated
        description: top-level only
        metadata:
          author: someone
        ---
        """
        let result = SkillFrontmatterParser.split(raw)
        #expect(result.frontmatter["author"] == nil)
        #expect(result.metadata["author"] == "someone")
    }

    @Test func entryParsePrefersMetadataNestedTaskTypesOverTopLevel() {
        let raw = """
        ---
        name: prefer-metadata
        description: tests routing precedence
        taskTypes: [analysis]
        metadata:
          taskTypes: [coding, writing]
        ---
        """
        let entry = SkillEntry.parse(from: raw, slug: "prefer-metadata")
        // Metadata-nested takes precedence when both are present.
        #expect(entry?.taskTypes.contains(.coding) == true)
        #expect(entry?.taskTypes.contains(.writing) == true)
        #expect(entry?.taskTypes.contains(.analysis) == false)
    }

    @Test func entryParseFallsBackToTopLevelWhenMetadataAbsent() {
        // Legacy on-disk format: TipTour fields at frontmatter root,
        // no `metadata:` map. SkillEntry.parse must still accept it
        // so users don't lose pre-upgrade skills.
        let raw = """
        ---
        id: 12345678-1234-1234-1234-123456789012
        name: legacy-format
        description: pre-metadata-move skill
        taskTypes: [coding]
        keywords: [legacy, test]
        createdAt: 2026-01-15
        ---
        """
        let entry = SkillEntry.parse(from: raw, slug: "legacy-format")
        #expect(entry?.id == UUID(uuidString: "12345678-1234-1234-1234-123456789012"))
        #expect(entry?.taskTypes == [.coding])
        #expect(entry?.keywords == ["legacy", "test"])
    }

    @Test func writerEmitsMetadataMap() {
        let entry = SkillEntry(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            slug: "writer-test",
            name: "writer-test",
            description: "Spec-compliant writer test",
            taskTypes: [.coding],
            keywords: ["spec", "writer"],
            createdAt: Date(timeIntervalSince1970: 1_715_731_200)
        )
        let fm = entry.frontmatter
        // Spec fields at root.
        #expect(fm.contains("name: writer-test"))
        #expect(fm.contains("description: Spec-compliant writer test"))
        // Custom fields under metadata.
        #expect(fm.contains("metadata:"))
        #expect(fm.contains("  id: AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"))
        #expect(fm.contains("  taskTypes: [coding]"))
        #expect(fm.contains("  keywords: [spec, writer]"))
        // Custom fields NOT at root anymore.
        #expect(!fm.contains("\nid: "))
        #expect(!fm.contains("\ntaskTypes:"))
    }

    @Test func roundTripsThroughMetadataMap() {
        let original = SkillEntry(
            id: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
            slug: "roundtrip-meta",
            name: "roundtrip-meta",
            description: "round trip through metadata map",
            taskTypes: [.coding, .analysis],
            keywords: ["a", "b", "c"],
            createdAt: Date(timeIntervalSince1970: 1_715_731_200)
        )
        let serialized = original.frontmatter + "\n\nbody content"
        let parsed = SkillEntry.parse(from: serialized, slug: original.slug)
        #expect(parsed?.id == original.id)
        #expect(parsed?.name == original.name)
        #expect(parsed?.description == original.description)
        #expect(parsed?.taskTypes == original.taskTypes)
        #expect(parsed?.keywords == original.keywords)
    }
}
