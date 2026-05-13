// TipTourTests/SkillEntrySpecFieldsTests.swift

import Foundation
import Testing
@testable import TipTour

@Suite("SkillEntry optional spec fields")
struct SkillEntrySpecFieldsTests {

    private static let sampleDate = Date(timeIntervalSince1970: 1_715_731_200) // 2026-05-13 approx

    @Test func roundTripsAllThreeOptionalFields() {
        let original = SkillEntry(
            id: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!,
            slug: "spec-skill",
            name: "spec-skill",
            description: "A skill that uses all spec fields",
            taskTypes: [.coding],
            keywords: ["spec", "test"],
            createdAt: Self.sampleDate,
            license: "Apache-2.0",
            compatibility: "macOS 14+ required",
            allowedTools: "Bash(git:*) Read"
        )
        let serialized = original.frontmatter + "\n\nbody"
        let parsed = SkillEntry.parse(from: serialized, slug: "spec-skill")
        #expect(parsed?.license == "Apache-2.0")
        #expect(parsed?.compatibility == "macOS 14+ required")
        #expect(parsed?.allowedTools == "Bash(git:*) Read")
    }

    @Test func roundTripsWithNoOptionalFields() {
        let original = SkillEntry(
            id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
            slug: "plain-skill",
            name: "plain-skill",
            description: "Plain skill, no optional fields",
            taskTypes: [.coding],
            keywords: [],
            createdAt: Self.sampleDate
        )
        let serialized = original.frontmatter + "\n\nbody"
        let parsed = SkillEntry.parse(from: serialized, slug: "plain-skill")
        #expect(parsed?.license == nil)
        #expect(parsed?.compatibility == nil)
        #expect(parsed?.allowedTools == nil)
    }

    @Test func frontmatterOmitsNilFields() {
        let entry = SkillEntry(
            id: UUID(),
            slug: "x",
            name: "x",
            description: "x",
            taskTypes: [.coding],
            keywords: [],
            createdAt: Self.sampleDate
        )
        let fm = entry.frontmatter
        #expect(!fm.contains("license:"))
        #expect(!fm.contains("compatibility:"))
        #expect(!fm.contains("allowed-tools:"))
    }

    @Test func frontmatterIncludesPresentFields() {
        let entry = SkillEntry(
            id: UUID(),
            slug: "x",
            name: "x",
            description: "x",
            taskTypes: [.coding],
            keywords: [],
            createdAt: Self.sampleDate,
            license: "MIT",
            compatibility: nil,
            allowedTools: "Bash"
        )
        let fm = entry.frontmatter
        #expect(fm.contains("license: MIT"))
        #expect(!fm.contains("compatibility:"))
        #expect(fm.contains("allowed-tools: Bash"))
    }

    @Test func parsesUpstreamSkillMDWithLicense() {
        let upstreamSkillMD = """
        ---
        id: 33333333-3333-3333-3333-333333333333
        name: pdf-processing
        description: Extracts text and tables from PDF files.
        taskTypes: [coding]
        keywords: [pdf, extract]
        createdAt: 2026-05-13
        license: Apache-2.0
        compatibility: Requires python 3.11+
        allowed-tools: Bash(python:*) Read
        ---

        # PDF Processing
        Body content.
        """
        let parsed = SkillEntry.parse(from: upstreamSkillMD, slug: "pdf-processing")
        #expect(parsed?.license == "Apache-2.0")
        #expect(parsed?.compatibility == "Requires python 3.11+")
        #expect(parsed?.allowedTools == "Bash(python:*) Read")
    }
}
