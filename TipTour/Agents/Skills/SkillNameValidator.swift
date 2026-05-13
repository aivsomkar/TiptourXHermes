// TipTour/Agents/Skills/SkillNameValidator.swift

import Foundation

/// Validates skill names per the agentskills.io specification.
/// A valid name:
///   - is 1-64 characters
///   - contains only lowercase a-z, 0-9, and hyphens
///   - does not start or end with a hyphen
///   - does not contain consecutive hyphens
///
/// Used by `SkillLibraryStore` to validate slugs at write time and by
/// `SkillStoreMigrator` to coerce legacy/imported names into spec-
/// compliant form.
enum SkillNameValidator {

    static func isValid(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 64 else { return false }
        guard name.first != "-", name.last != "-" else { return false }
        if name.contains("--") { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        return name.unicodeScalars.allSatisfy(allowed.contains)
    }

    /// Best-effort coercion for legacy or upstream names that don't
    /// already match the spec. Lossy: only ASCII a-z/0-9/- survive;
    /// runs of disallowed characters collapse into single hyphens;
    /// the result is trimmed of leading/trailing hyphens and capped
    /// at 64 chars.
    static func sanitize(_ raw: String) -> String {
        var out = ""
        var lastWasDash = false
        for char in raw.lowercased() {
            let isASCIIAlphaNum = (char.isLetter && char.isASCII) || (char.isNumber && char.isASCII)
            if isASCIIAlphaNum {
                out.append(char)
                lastWasDash = false
            } else if !lastWasDash, !out.isEmpty {
                out.append("-")
                lastWasDash = true
            }
        }
        out = String(out.prefix(64)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return out
    }
}
