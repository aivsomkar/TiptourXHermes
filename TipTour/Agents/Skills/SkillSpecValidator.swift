// TipTour/Agents/Skills/SkillSpecValidator.swift

import Foundation

/// Enforces the field-length constraints declared in the
/// agentskills.io specification (https://agentskills.io/specification).
///
/// Distinct from `SkillNameValidator` — that one is the regex gate for
/// the required `name` field. This one covers the optional / textual
/// fields where the spec sets only a maximum length:
///   - `description` ≤ 1024 characters
///   - `compatibility` ≤ 500 characters
///
/// We *truncate* over-length values rather than rejecting. Reason:
/// upstream skills (RuFlo, OpenWork) and user-edited descriptions
/// occasionally drift past the cap, and a hard reject would either
/// silently drop the skill from the library or surface as an import
/// error users can't act on. Truncation preserves the skill's
/// usefulness and emits a console warning so the drift is visible to
/// devs.
enum SkillSpecValidator {

    static let maximumDescriptionLength = 1024
    static let maximumCompatibilityLength = 500

    /// Returns `value` if it fits the spec's max length, otherwise a
    /// truncated copy. A `nil` input passes through. The optional
    /// `skillSlug` parameter is only used to make truncation log
    /// messages traceable.
    static func clampedDescription(_ value: String, skillSlug: String? = nil) -> String {
        clamp(
            value,
            maxLength: maximumDescriptionLength,
            fieldName: "description",
            skillSlug: skillSlug
        )
    }

    static func clampedCompatibility(_ value: String?, skillSlug: String? = nil) -> String? {
        guard let value else { return nil }
        return clamp(
            value,
            maxLength: maximumCompatibilityLength,
            fieldName: "compatibility",
            skillSlug: skillSlug
        )
    }

    private static func clamp(
        _ value: String,
        maxLength: Int,
        fieldName: String,
        skillSlug: String?
    ) -> String {
        guard value.count > maxLength else { return value }
        let truncated = String(value.prefix(maxLength))
        let slugFragment = skillSlug.map { "'\($0)' " } ?? ""
        print("[SkillSpecValidator] truncated \(fieldName) for skill \(slugFragment)from \(value.count) to \(maxLength) chars")
        return truncated
    }
}
