// TipTourTests/SkillNameValidatorTests.swift

import Foundation
import Testing
@testable import TipTour

@Suite("SkillNameValidator.isValid")
struct SkillNameValidatorIsValidTests {

    @Test func acceptsValidSpecNames() {
        #expect(SkillNameValidator.isValid("pdf-processing"))
        #expect(SkillNameValidator.isValid("agent-coder"))
        #expect(SkillNameValidator.isValid("dogfood"))
        #expect(SkillNameValidator.isValid("a"))
        #expect(SkillNameValidator.isValid("a1"))
        #expect(SkillNameValidator.isValid(String(repeating: "a", count: 64)))
    }

    @Test func rejectsUppercase() {
        #expect(!SkillNameValidator.isValid("PDF-Processing"))
        #expect(!SkillNameValidator.isValid("agent-Coder"))
    }

    @Test func rejectsLeadingHyphen() {
        #expect(!SkillNameValidator.isValid("-leading"))
    }

    @Test func rejectsTrailingHyphen() {
        #expect(!SkillNameValidator.isValid("trailing-"))
    }

    @Test func rejectsConsecutiveHyphens() {
        #expect(!SkillNameValidator.isValid("with--double"))
        #expect(!SkillNameValidator.isValid("a--b"))
    }

    @Test func rejectsEmpty() {
        #expect(!SkillNameValidator.isValid(""))
    }

    @Test func rejectsOver64Chars() {
        #expect(!SkillNameValidator.isValid(String(repeating: "a", count: 65)))
    }

    @Test func rejectsUnderscores() {
        #expect(!SkillNameValidator.isValid("with_underscore"))
    }

    @Test func rejectsSpaces() {
        #expect(!SkillNameValidator.isValid("with space"))
    }

    @Test func rejectsDots() {
        #expect(!SkillNameValidator.isValid("with.dot"))
    }

    @Test func rejectsNonASCIIAlphanumeric() {
        #expect(!SkillNameValidator.isValid("café"))
        #expect(!SkillNameValidator.isValid("naïve"))
        #expect(!SkillNameValidator.isValid("слово"))
    }
}

@Suite("SkillNameValidator.sanitize")
struct SkillNameValidatorSanitizeTests {

    @Test func passesThroughAlreadyValid() {
        #expect(SkillNameValidator.sanitize("agent-coder") == "agent-coder")
        #expect(SkillNameValidator.sanitize("dogfood") == "dogfood")
    }

    @Test func lowercasesAndReplacesSpaces() {
        #expect(SkillNameValidator.sanitize("My Skill 2.0") == "my-skill-2-0")
    }

    @Test func trimsLeadingTrailingDashes() {
        #expect(SkillNameValidator.sanitize("--weird--") == "weird")
    }

    @Test func collapsesConsecutiveNonAlphaNum() {
        #expect(SkillNameValidator.sanitize("a___b") == "a-b")
        #expect(SkillNameValidator.sanitize("a   b") == "a-b")
    }

    @Test func capsAt64Chars() {
        let long = String(repeating: "a", count: 100)
        let result = SkillNameValidator.sanitize(long)
        #expect(result.count <= 64)
    }

    @Test func emptyInputReturnsEmpty() {
        #expect(SkillNameValidator.sanitize("") == "")
    }

    @Test func dropsLeadingNonAlphaNum() {
        #expect(SkillNameValidator.sanitize("___pdf") == "pdf")
    }
}
