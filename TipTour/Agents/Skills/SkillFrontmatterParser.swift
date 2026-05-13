// TipTour/Agents/Skills/SkillFrontmatterParser.swift

import Foundation

/// Shared logic for turning an upstream `.md` skill file into the
/// fields TipTour's `SkillLibraryStore` needs. Used by both
/// `BundledSkillSeeder` (app-bundled RuFlo + OpenWork files) and
/// `SkillImporter` (user-installed remote files).
///
/// This was extracted from `BundledSkillSeeder` so that the runtime
/// importer can guarantee bit-identical parsing — drift between the
/// two would silently mis-classify imported skills relative to the
/// ~150 bundled ones, and the LLM's `recall_skill` retrieval depends
/// on the task-type + keyword tags being produced by one source of
/// truth.
enum SkillFrontmatterParser {

    struct SplitResult {
        /// Top-level scalar key/value pairs from the frontmatter
        /// (`name`, `description`, `license`, etc.). Block-scalar values
        /// (`> folded` and `| literal`) are decoded into their joined
        /// string form.
        let frontmatter: [String: String]
        /// Children of a top-level `metadata:` map. Per the
        /// agentskills.io spec, clients (us included) should store
        /// non-spec keys under `metadata:` rather than at the
        /// frontmatter root. We keep them in a separate dict so callers
        /// can prefer metadata-nested values while falling back to
        /// legacy top-level ones for backward compat with on-disk
        /// skills written before the metadata move.
        let metadata: [String: String]
        let body: String
    }

    /// Split a markdown file into (frontmatter dict, metadata children
    /// dict, body without frontmatter). Tolerant: if the file has no
    /// `---` opener, the whole thing is treated as body and both dicts
    /// are empty.
    ///
    /// Supports the YAML subset agentskills.io spec files use in
    /// practice:
    ///   1. Plain top-level `key: value` scalars
    ///   2. Folded block scalars (`description: >` followed by indented
    ///      continuation lines) — joined with spaces, blanks become
    ///      paragraph breaks
    ///   3. Literal block scalars (`description: |` + indented lines)
    ///      — newlines preserved
    ///   4. A top-level `metadata:` map with two-space-indented
    ///      `key: value` children. Children may be quoted (`"1.0"`).
    static func split(_ raw: String) -> SplitResult {
        let lines = raw.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
            return SplitResult(frontmatter: [:], metadata: [:], body: raw)
        }
        var frontmatter: [String: String] = [:]
        var metadata: [String: String] = [:]
        var bodyStartIndex = lines.count

        // Index-based loop so we can lookahead-consume continuation
        // lines belonging to a block scalar or a map child without the
        // outer iteration re-visiting them.
        var lineIndex = 1
        while lineIndex < lines.count {
            let line = lines[lineIndex]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" {
                bodyStartIndex = lineIndex + 1
                break
            }

            // Only treat zero-indent lines as new top-level keys. An
            // indented line at the top level is either continuation
            // (already consumed by the previous key's lookahead) or
            // junk; either way, skip.
            let leadingSpaceCount = line.prefix { $0 == " " }.count
            if leadingSpaceCount > 0 {
                lineIndex += 1
                continue
            }

            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else {
                lineIndex += 1
                continue
            }
            let key = String(parts[0])
            let rawValue = String(parts[1])

            if rawValue == ">" || rawValue == "|" {
                let isFolded = rawValue == ">"
                let (joinedValue, nextLineIndex) = consumeBlockScalar(
                    lines: lines,
                    startingAt: lineIndex + 1,
                    isFolded: isFolded
                )
                frontmatter[key] = joinedValue
                lineIndex = nextLineIndex
                continue
            }

            if rawValue.isEmpty, key == "metadata" {
                let (mapChildren, nextLineIndex) = consumeIndentedMap(
                    lines: lines,
                    startingAt: lineIndex + 1
                )
                for (childKey, childValue) in mapChildren {
                    metadata[childKey] = childValue
                }
                lineIndex = nextLineIndex
                continue
            }

            frontmatter[key] = rawValue
            lineIndex += 1
        }

        let body = lines.dropFirst(bodyStartIndex).joined(separator: "\n")
        return SplitResult(frontmatter: frontmatter, metadata: metadata, body: body)
    }

    /// Consume the indented continuation lines following a `key: >` or
    /// `key: |` indicator. Returns the joined string value and the
    /// index of the first line the outer loop should resume at.
    ///
    /// A continuation line is any line that is either fully blank or
    /// has at least one leading space. The first zero-indent non-blank
    /// line (or the closing `---`) ends the scalar.
    private static func consumeBlockScalar(
        lines: [String],
        startingAt startIndex: Int,
        isFolded: Bool
    ) -> (String, Int) {
        var collected: [String] = []
        var lookahead = startIndex
        while lookahead < lines.count {
            let candidate = lines[lookahead]
            let candidateTrimmed = candidate.trimmingCharacters(in: .whitespaces)
            if candidateTrimmed == "---" { break }
            let candidateLeadingSpaces = candidate.prefix { $0 == " " }.count
            // A zero-indent non-blank line ends the scalar (new top
            // level key starts). A blank line is part of the scalar.
            if candidateLeadingSpaces == 0, !candidateTrimmed.isEmpty {
                break
            }
            collected.append(candidateTrimmed)
            lookahead += 1
        }
        // Trim trailing blank lines (YAML "clip" chomping default).
        while collected.last == "" {
            collected.removeLast()
        }
        let joined = isFolded ? foldScalarLines(collected) : collected.joined(separator: "\n")
        return (joined, lookahead)
    }

    /// YAML folded-scalar folding rules in practice: non-empty lines
    /// are joined with a single space; a blank line in the middle
    /// becomes a literal newline (paragraph break).
    private static func foldScalarLines(_ lines: [String]) -> String {
        var result = ""
        var previousLineWasBlank = false
        for line in lines {
            if line.isEmpty {
                if !result.isEmpty {
                    result += "\n"
                }
                previousLineWasBlank = true
            } else {
                if !result.isEmpty, !previousLineWasBlank {
                    result += " "
                }
                result += line
                previousLineWasBlank = false
            }
        }
        return result
    }

    /// Consume the indented `key: value` children of a top-level map
    /// (currently only `metadata:`). Returns the parsed children and
    /// the resume index. Child values are unquoted if surrounded by
    /// single or double quotes — the spec example writes
    /// `version: "1.0"` and we want to preserve `1.0` as the stored
    /// value, not `"1.0"`.
    private static func consumeIndentedMap(
        lines: [String],
        startingAt startIndex: Int
    ) -> ([(String, String)], Int) {
        var collected: [(String, String)] = []
        var lookahead = startIndex
        while lookahead < lines.count {
            let candidate = lines[lookahead]
            let candidateTrimmed = candidate.trimmingCharacters(in: .whitespaces)
            if candidateTrimmed == "---" { break }
            let candidateLeadingSpaces = candidate.prefix { $0 == " " }.count
            if candidateLeadingSpaces == 0, !candidateTrimmed.isEmpty {
                break
            }
            if candidateTrimmed.isEmpty {
                lookahead += 1
                continue
            }
            let childParts = candidateTrimmed
                .split(separator: ":", maxSplits: 1)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            if childParts.count == 2 {
                let childKey = String(childParts[0])
                let childValue = unquoteScalar(String(childParts[1]))
                collected.append((childKey, childValue))
            }
            lookahead += 1
        }
        return (collected, lookahead)
    }

    /// Strip a single pair of matching surrounding quotes. Leaves
    /// inputs without surrounding quotes untouched.
    private static func unquoteScalar(_ raw: String) -> String {
        guard raw.count >= 2 else { return raw }
        let first = raw.first
        let last = raw.last
        if (first == "\"" && last == "\"") || (first == "'" && last == "'") {
            return String(raw.dropFirst().dropLast())
        }
        return raw
    }

    /// Lowercase, replace non-alphanumeric runs with `-`. Matches the
    /// generator in `SkillLibraryStore.generateSlug`.
    static func sanitizeSlug(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics
        var lastWasDash = false
        var result = ""
        for character in raw.lowercased() {
            if character.unicodeScalars.allSatisfy(allowed.contains) {
                result.append(character)
                lastWasDash = false
            } else if !lastWasDash {
                result.append("-")
                lastWasDash = true
            }
        }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    // MARK: - Heuristics for task-type + keyword tagging

    /// Map a bundled skill to the TipTour TaskType(s) it's relevant to.
    /// The slug is the most reliable signal — upstream skills are
    /// already named after their role.
    static func inferTaskTypes(slug: String, name: String, description: String) -> [TaskType] {
        let haystack = (slug + " " + name + " " + description).lowercased()

        // A skill can match multiple task-type buckets at once and
        // we WANT that — `agent-docs` legitimately surfaces to both
        // coding and writing agents, so the four if-blocks below are
        // independent inserts into a set, not a first-match cascade.
        // The `matches.isEmpty` fallback near the end guarantees
        // every skill lands in at least one bucket so `recall_skill`
        // can always find it.
        var matches: Set<TaskType> = []

        // Coding-flavored
        let codingMarkers = [
            "agent-coder", "agent-tester", "agent-reviewer", "agent-implementer",
            "agent-code-", "agent-arch", "agent-architecture", "agent-refactor",
            "agent-pseudocode", "agent-specification", "agent-refinement",
            "sparc", "tdd", "agent-pr", "agent-github", "github-",
            "agent-release", "agent-issue", "release", "agentic-jujutsu",
            "agent-repo-architect", "agent-base-template", "agent-spec",
            "agent-data-ml", "agent-dev-backend", "agent-docs-api",
            "opencode-", "openwork-", "tauri-", "solidjs-", "cargo-",
            "browser-setup", "skill-builder", "stream-chain", "pair-programming",
            "command-release", "agent-css", "agent-docs", "agent-triage",
            "agent-duplicate-pr"
        ]
        if codingMarkers.contains(where: { haystack.contains($0) }) {
            matches.insert(.coding)
        }

        // Analysis-flavored
        let analysisMarkers = [
            "agent-research", "agent-scout", "agent-analyze", "agent-performance",
            "agent-benchmark", "agent-security", "security-audit", "agent-validator",
            "agent-pagerank", "performance-analysis", "neural-training",
            "reasoningbank", "hive-mind", "memory-management",
            "agent-quality", "agent-monitor"
        ]
        if analysisMarkers.contains(where: { haystack.contains($0) }) {
            matches.insert(.analysis)
        }

        // Orchestration / generalMac (broad-purpose agents)
        let generalMarkers = [
            "agent-orchestrator", "agent-planner", "agent-goal-planner",
            "agent-coordinator", "agent-coordination", "agent-swarm",
            "agent-queen", "agent-hierarchical", "agent-mesh", "agent-gossip",
            "agent-consensus", "agent-byzantine", "agent-raft", "agent-quorum",
            "agent-load-balancer", "agent-resource-allocator", "agent-sandbox",
            "agent-topology", "agent-sync", "agent-workflow", "workflow-automation",
            "hooks-automation", "agent-collective-intelligence", "agent-automation",
            "agent-user-tools", "claims", "embeddings", "flow-nexus",
            "agentic-payments", "agent-payments", "agent-app-store", "agent-challenges",
            "agent-migration-plan", "agent-multi-repo", "agent-neural-network",
            "agent-ops-cicd", "agent-project-board", "agent-safla-neural",
            "agent-sona-learning", "agent-trading-predictor", "agent-worker-specialist",
            "agentdb", "agent-crdt", "agent-matrix"
        ]
        if generalMarkers.contains(where: { haystack.contains($0) }) {
            matches.insert(.generalMac)
        }

        // Writing flavors (docs)
        let writingMarkers = ["agent-docs", "command-docs", "docs-api", "command-release"]
        if writingMarkers.contains(where: { haystack.contains($0) }) {
            matches.insert(.writing)
        }

        // Default fallback — every skill should be retrievable for at
        // least one task type so the LLM's `recall_skill` can find it.
        if matches.isEmpty {
            matches.insert(.generalMac)
        }
        return Array(matches).sorted { $0.rawValue < $1.rawValue }
    }

    /// Lightweight keyword extraction — up to 20 substantive tokens
    /// drawn from slug + name + description combined, in source order
    /// with duplicates removed. Filters out stopwords and tokens
    /// shorter than 3 characters so the keyword set is useful for
    /// `SkillLibraryStore`'s retrieval scoring.
    static func inferKeywords(slug: String, name: String, description: String) -> [String] {
        let raw = slug.replacingOccurrences(of: "-", with: " ")
            + " " + name
            + " " + description
        let tokens = raw
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 && !skillStopwords.contains($0) }

        var seen: Set<String> = []
        var ordered: [String] = []
        for token in tokens {
            if seen.insert(token).inserted {
                ordered.append(token)
            }
            if ordered.count >= 20 { break }
        }
        return ordered
    }

    private static let skillStopwords: Set<String> = [
        "the", "and", "for", "with", "this", "that", "from", "into",
        "use", "via", "agent", "skill", "task", "tasks", "your", "you",
        "are", "any", "all", "can", "has", "have", "when", "what",
        "where", "how", "but", "not", "out", "its", "than", "then"
    ]
}
