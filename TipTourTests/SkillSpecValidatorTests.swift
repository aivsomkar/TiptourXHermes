// TipTourTests/SkillSpecValidatorTests.swift

import Foundation
import Testing
@testable import TipTour

@Suite("SkillSpecValidator length enforcement")
struct SkillSpecValidatorTests {

    @Test func descriptionUnderMaximumPassesThrough() {
        let short = "A short description."
        #expect(SkillSpecValidator.clampedDescription(short) == short)
    }

    @Test func descriptionAtMaximumPassesThrough() {
        let atMax = String(repeating: "a", count: SkillSpecValidator.maximumDescriptionLength)
        #expect(SkillSpecValidator.clampedDescription(atMax) == atMax)
    }

    @Test func descriptionOverMaximumTruncates() {
        let over = String(repeating: "a", count: SkillSpecValidator.maximumDescriptionLength + 50)
        let clamped = SkillSpecValidator.clampedDescription(over)
        #expect(clamped.count == SkillSpecValidator.maximumDescriptionLength)
    }

    @Test func compatibilityNilPassesThrough() {
        #expect(SkillSpecValidator.clampedCompatibility(nil) == nil)
    }

    @Test func compatibilityUnderMaximumPassesThrough() {
        let value = "macOS 14+ required"
        #expect(SkillSpecValidator.clampedCompatibility(value) == value)
    }

    @Test func compatibilityOverMaximumTruncates() {
        let over = String(repeating: "x", count: SkillSpecValidator.maximumCompatibilityLength + 1)
        let clamped = SkillSpecValidator.clampedCompatibility(over)
        #expect(clamped?.count == SkillSpecValidator.maximumCompatibilityLength)
    }

    @Test func emptyStringPassesThrough() {
        #expect(SkillSpecValidator.clampedDescription("") == "")
    }
}
