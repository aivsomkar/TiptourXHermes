# Skill Importer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let users install additional agent skills at runtime by pasting a GitHub URL — the importer downloads, parses, and writes the skills into `SkillLibraryStore` using the same on-disk format as the bundled RuFlo/OpenWork sets.

**Architecture:** A new `SkillImporter` actor pulls a GitHub repo tarball over HTTPS, walks the extracted tree for `*.md` files whose first line is `---` (frontmatter present), reuses the existing parser logic from `BundledSkillSeeder` (after promoting it into a standalone helper), and writes each parsed entry through `SkillLibraryStore.write`. A new "Import…" button in the existing Skills settings tab calls the importer with a user-supplied URL and shows a per-skill success/skipped/failed count.

**Tech Stack:** Swift actors, `URLSession.download`, `Process` + system `tar` for archive extraction (already on every macOS), the existing `SkillLibraryStore` + `SkillEntry` types, SwiftUI for the settings UI, Swift Testing (`import Testing`).

---

## File Structure

| Action | Path | Responsibility |
|--------|------|----------------|
| Create | `TipTour/Agents/Skills/SkillFrontmatterParser.swift` | Shared frontmatter parser, slug sanitizer, task-type/keyword inference — extracted from `BundledSkillSeeder` so both the seeder and the new importer use the same logic |
| Create | `TipTour/Agents/Skills/SkillImporter.swift` | `SkillImporter` actor — fetch a GitHub repo tarball, extract, enumerate `.md`, parse, write to store. Returns an `ImportReport` |
| Modify | `TipTour/Agents/Skills/BundledSkillSeeder.swift` | Delete the private parser helpers; call into `SkillFrontmatterParser` instead. Behavior unchanged |
| Modify | `TipTour/Agents/UI/SettingsView.swift` | Add "Import…" button to `SkillsSettingsView` header, sheet with URL input + import progress |
| Create | `TipTourTests/SkillImporterTests.swift` | Unit tests for parser refactor + importer behavior using a local tarball fixture |

---

## Task 1: Extract frontmatter parser into a shared helper

**Files:**
- Create: `TipTour/Agents/Skills/SkillFrontmatterParser.swift`
- Modify: `TipTour/Agents/Skills/BundledSkillSeeder.swift`
- Create: `TipTourTests/SkillImporterTests.swift`

- [ ] **Step 1: Write failing test for `SkillFrontmatterParser`**

Create `TipTourTests/SkillImporterTests.swift`:

```swift
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
```

- [ ] **Step 2: Run test to verify it fails**

Open the test target and run `SkillFrontmatterParserTests` in Xcode (Cmd+U). Do NOT run `xcodebuild` from the terminal — it invalidates TCC permissions.
Expected: compile failure ("cannot find 'SkillFrontmatterParser' in scope").

- [ ] **Step 3: Create `SkillFrontmatterParser` with the methods needed by tests AND by the existing seeder**

Create `TipTour/Agents/Skills/SkillFrontmatterParser.swift`. Copy the bodies verbatim from the private methods currently in `BundledSkillSeeder.swift` — only the access level and host change.

```swift
// TipTour/Agents/Skills/SkillFrontmatterParser.swift

import Foundation

/// Shared logic for turning an upstream `.md` skill file into the
/// fields TipTour's `SkillLibraryStore` needs. Used by both
/// `BundledSkillSeeder` (app-bundled RuFlo + OpenWork files) and
/// `SkillImporter` (user-installed remote files).
enum SkillFrontmatterParser {

    struct SplitResult {
        let frontmatter: [String: String]
        let body: String
    }

    static func split(_ raw: String) -> SplitResult {
        let lines = raw.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
            return SplitResult(frontmatter: [:], body: raw)
        }
        var dict: [String: String] = [:]
        var bodyStartIndex = lines.count
        for (i, line) in lines.dropFirst().enumerated() {
            if line.trimmingCharacters(in: .whitespaces) == "---" {
                bodyStartIndex = i + 2
                break
            }
            let parts = line.split(separator: ":", maxSplits: 1)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 {
                dict[String(parts[0])] = String(parts[1])
            }
        }
        let body = lines.dropFirst(bodyStartIndex).joined(separator: "\n")
        return SplitResult(frontmatter: dict, body: body)
    }

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

    static func inferTaskTypes(slug: String, name: String, description: String) -> [TaskType] {
        // COPY the exact body of `BundledSkillSeeder.inferTaskTypes`
        // verbatim. Do NOT change classification rules in this task —
        // the bundled seeder relies on identical output.
        // (See BundledSkillSeeder.swift:204-274 for current logic.)
        let haystack = (slug + " " + name + " " + description).lowercased()
        var matches: Set<TaskType> = []
        let codingMarkers = [/* full list from BundledSkillSeeder */]
        if codingMarkers.contains(where: { haystack.contains($0) }) { matches.insert(.coding) }
        let analysisMarkers = [/* full list */]
        if analysisMarkers.contains(where: { haystack.contains($0) }) { matches.insert(.analysis) }
        let generalMarkers = [/* full list */]
        if generalMarkers.contains(where: { haystack.contains($0) }) { matches.insert(.generalMac) }
        let writingMarkers = [/* full list */]
        if writingMarkers.contains(where: { haystack.contains($0) }) { matches.insert(.writing) }
        if matches.isEmpty { matches.insert(.generalMac) }
        return Array(matches).sorted { $0.rawValue < $1.rawValue }
    }

    static func inferKeywords(slug: String, name: String, description: String) -> [String] {
        let raw = slug.replacingOccurrences(of: "-", with: " ")
            + " " + name + " " + description
        let tokens = raw.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 && !skillStopwords.contains($0) }
        var seen: Set<String> = []
        var ordered: [String] = []
        for token in tokens {
            if seen.insert(token).inserted { ordered.append(token) }
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
```

When copying the marker arrays, take them verbatim from `BundledSkillSeeder.swift:213-225` (coding), `:231-237` (analysis), `:243-256` (general), `:263` (writing). Do NOT abbreviate — the bundled set depends on the full set of markers matching.

- [ ] **Step 4: Run tests to verify they pass**

Run `SkillFrontmatterParserTests` in Xcode.
Expected: all 5 tests pass.

- [ ] **Step 5: Replace private helpers in `BundledSkillSeeder` with calls to the new parser**

In `TipTour/Agents/Skills/BundledSkillSeeder.swift`, delete the now-duplicated private methods (`splitFrontmatter`, `sanitizeSlug`, `inferTaskTypes`, `inferKeywords`, and the `skillStopwords` constant), and change the three call sites:

```swift
// Inside parse(fileURL:)
let (frontmatter, body) = SkillFrontmatterParser.split(raw)
//  ↑ was: splitFrontmatter(raw)

let slug = SkillFrontmatterParser.sanitizeSlug(fileURL.deletingPathExtension().lastPathComponent)
//  ↑ was: sanitizeSlug(...)

let taskTypes = SkillFrontmatterParser.inferTaskTypes(slug: slug, name: parsedName, description: parsedDescription)
let keywords = SkillFrontmatterParser.inferKeywords(slug: slug, name: parsedName, description: parsedDescription)
```

Leave `upstreamLabel` private to the seeder — it's specific to the bundled set's directory layout.

- [ ] **Step 6: Build to confirm `BundledSkillSeeder` still compiles**

Build the TipTour target in Xcode (Cmd+B). Run the app once (Cmd+R), confirm `[BundledSkillSeeder] seeded N bundled skill(s), M already present` still prints on launch with the same `N + M = ~150` total.

- [ ] **Step 7: Commit**

```bash
git add TipTour/Agents/Skills/SkillFrontmatterParser.swift \
        TipTour/Agents/Skills/BundledSkillSeeder.swift \
        TipTourTests/SkillImporterTests.swift
git commit -m "refactor: extract bundled-skill parser into shared helper"
```

---

## Task 2: `SkillImporter` actor — fetch and extract a GitHub tarball

**Files:**
- Create: `TipTour/Agents/Skills/SkillImporter.swift`
- Modify: `TipTourTests/SkillImporterTests.swift`

- [ ] **Step 1: Write failing tests for `SkillImporter.parseGitHubURL`**

Append to `TipTourTests/SkillImporterTests.swift`:

```swift
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
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run `SkillImporterURLParsingTests` in Xcode.
Expected: compile failure ("cannot find 'SkillImporter' in scope").

- [ ] **Step 3: Create `SkillImporter` with URL parsing and the result/error types**

```swift
// TipTour/Agents/Skills/SkillImporter.swift

import Foundation

/// Fetches a GitHub repo's `.md` skill files and writes them into the
/// user's `SkillLibraryStore`. Reuses the same parser logic as
/// `BundledSkillSeeder` so an imported skill is indistinguishable from
/// a bundled one once on disk.
///
/// **Why GitHub-only:** the bundled sources (RuFlo, OpenWork) already
/// live there, and GitHub serves repo tarballs at a stable URL pattern
/// (`https://codeload.github.com/<owner>/<repo>/tar.gz/<branch>`) with
/// no auth required for public repos. GitLab/Bitbucket can be added
/// later by extending `parseGitHubURL` and the tarball URL builder.
actor SkillImporter {

    struct GitHubRef {
        let owner: String
        let repo: String
        let branch: String
        let subpath: String?
    }

    struct ImportReport: Sendable {
        let imported: [String]   // slugs of newly-written skills
        let skipped: [String]    // slugs that already existed
        let failed: [String]     // file basenames that couldn't be parsed
    }

    enum ImportError: Error, LocalizedError {
        case notAGitHubURL
        case malformedURL
        case downloadFailed(underlying: Error)
        case extractionFailed(reason: String)
        case noSkillsFound

        var errorDescription: String? {
            switch self {
            case .notAGitHubURL: return "URL must point to github.com"
            case .malformedURL: return "URL doesn't look like a GitHub repo"
            case .downloadFailed(let err): return "Download failed: \(err.localizedDescription)"
            case .extractionFailed(let reason): return "Extraction failed: \(reason)"
            case .noSkillsFound: return "No skill .md files found in the imported tree"
            }
        }
    }

    static func parseGitHubURL(_ raw: String) throws -> GitHubRef {
        guard let url = URL(string: raw), let host = url.host,
              host == "github.com" || host == "www.github.com" else {
            throw ImportError.notAGitHubURL
        }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { throw ImportError.malformedURL }
        let owner = parts[0]
        let repo = parts[1]
        if parts.count >= 4, parts[2] == "tree" {
            let branch = parts[3]
            let subpath = parts.count >= 5
                ? parts[4...].joined(separator: "/")
                : nil
            return GitHubRef(owner: owner, repo: repo, branch: branch, subpath: subpath)
        }
        return GitHubRef(owner: owner, repo: repo, branch: "main", subpath: nil)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run `SkillImporterURLParsingTests` in Xcode.
Expected: all 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add TipTour/Agents/Skills/SkillImporter.swift TipTourTests/SkillImporterTests.swift
git commit -m "feat(skills): scaffold SkillImporter with GitHub URL parsing"
```

---

## Task 3: `SkillImporter` — tarball download + tar extraction

**Files:**
- Modify: `TipTour/Agents/Skills/SkillImporter.swift`
- Modify: `TipTourTests/SkillImporterTests.swift`

- [ ] **Step 1: Write a failing test using a local fixture tarball**

Place a fixture tarball at `TipTourTests/Fixtures/skill-fixture.tar.gz` containing two `.md` files with frontmatter (one valid, one with no frontmatter to exercise the skip path). Generate it once with:

```bash
mkdir -p /tmp/skill-fixture-root/skills
cat > /tmp/skill-fixture-root/skills/agent-test-importer.md <<'EOF'
---
name: test-importer-skill
description: A fixture skill used by SkillImporterTests
---

# Test Importer
A fixture body.
EOF

cat > /tmp/skill-fixture-root/skills/no-frontmatter.md <<'EOF'
# Just a body, no frontmatter
EOF

cd /tmp && tar -czf skill-fixture.tar.gz skill-fixture-root
mv /tmp/skill-fixture.tar.gz \
   /Users/omkar/Desktop/TipTour-macOS/repo/TipTourTests/Fixtures/skill-fixture.tar.gz
```

Add the fixture to the test target's Resources in Xcode (drag the file into `TipTourTests` → ensure "Copy items if needed" is unchecked, "Add to targets: TipTourTests" is checked).

Append to `SkillImporterTests.swift`:

```swift
@Suite("SkillImporter extraction")
struct SkillImporterExtractionTests {

    @Test func extractsMarkdownFromTarball() async throws {
        let bundle = Bundle(for: TipTourTestsAnchor.self)
        guard let fixtureURL = bundle.url(forResource: "skill-fixture", withExtension: "tar.gz") else {
            Issue.record("Missing fixture skill-fixture.tar.gz in TipTourTests resources")
            return
        }
        let importer = SkillImporter()
        let extractedURL = try await importer.extractTarball(at: fixtureURL)
        defer { try? FileManager.default.removeItem(at: extractedURL) }

        let mdFiles = try FileManager.default.subpathsOfDirectory(atPath: extractedURL.path)
            .filter { $0.hasSuffix(".md") }
        #expect(mdFiles.count == 2)
    }
}

/// Anchor class so `Bundle(for:)` resolves the test bundle.
private final class TipTourTestsAnchor {}
```

- [ ] **Step 2: Run test to verify it fails**

Run `SkillImporterExtractionTests` in Xcode.
Expected: compile failure ("value of type 'SkillImporter' has no member 'extractTarball'").

- [ ] **Step 3: Add `extractTarball` using system `tar`**

Append to `SkillImporter.swift`:

```swift
extension SkillImporter {

    /// Extract a `.tar.gz` into a fresh temp directory and return the URL.
    /// Uses `/usr/bin/tar` (present on every macOS); avoids pulling in a
    /// libarchive dependency. The caller is responsible for deleting the
    /// returned directory when finished.
    func extractTarball(at tarballURL: URL) async throws -> URL {
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("tiptour-skill-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xzf", tarballURL.path, "-C", dest.path]
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = Pipe()

        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errText = String(data: errData, encoding: .utf8) ?? "<unreadable>"
            throw ImportError.extractionFailed(reason: errText.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return dest
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run `SkillImporterExtractionTests` in Xcode.
Expected: passes; the 2 `.md` files are found inside the extracted directory.

- [ ] **Step 5: Add `downloadTarball` (network)**

Append:

```swift
extension SkillImporter {

    /// Download `https://codeload.github.com/<owner>/<repo>/tar.gz/<branch>`
    /// to a temp file. Times out after 60 seconds.
    func downloadTarball(for ref: GitHubRef) async throws -> URL {
        let tarballURLString = "https://codeload.github.com/\(ref.owner)/\(ref.repo)/tar.gz/\(ref.branch)"
        guard let tarballURL = URL(string: tarballURLString) else {
            throw ImportError.malformedURL
        }
        var request = URLRequest(url: tarballURL)
        request.timeoutInterval = 60
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw ImportError.downloadFailed(
                    underlying: NSError(domain: "SkillImporter", code: http.statusCode,
                                        userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
                )
            }
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("tiptour-skill-tarball-\(UUID().uuidString).tar.gz")
            try data.write(to: dest)
            return dest
        } catch let error as ImportError {
            throw error
        } catch {
            throw ImportError.downloadFailed(underlying: error)
        }
    }
}
```

No test for this step — network calls are flaky in unit tests. The integration test in Task 5 will exercise it end-to-end with a real URL.

- [ ] **Step 6: Commit**

```bash
git add TipTour/Agents/Skills/SkillImporter.swift TipTourTests/SkillImporterTests.swift TipTourTests/Fixtures/skill-fixture.tar.gz
git commit -m "feat(skills): tarball download + extraction in SkillImporter"
```

---

## Task 4: `SkillImporter.importFrom(url:)` — full pipeline

**Files:**
- Modify: `TipTour/Agents/Skills/SkillImporter.swift`
- Modify: `TipTourTests/SkillImporterTests.swift`

- [ ] **Step 1: Write a failing end-to-end test using the fixture**

Append a test that exercises the local-fixture path (skips download):

```swift
@Suite("SkillImporter import pipeline")
struct SkillImporterImportTests {

    @Test func importFromExtractedDirectoryWritesSkillsToStore() async throws {
        let bundle = Bundle(for: TipTourTestsAnchor.self)
        let fixtureURL = bundle.url(forResource: "skill-fixture", withExtension: "tar.gz")!

        // Use a fresh, isolated store directory so the test doesn't
        // collide with the user's real skill library.
        let testStoreDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tiptour-test-store-\(UUID().uuidString)", isDirectory: true)
        let testStore = SkillLibraryStore(directoryURL: testStoreDir)

        let importer = SkillImporter()
        let extracted = try await importer.extractTarball(at: fixtureURL)
        defer { try? FileManager.default.removeItem(at: extracted) }

        let report = await importer.importFromExtractedDirectory(
            extracted,
            subpath: nil,
            store: testStore
        )

        #expect(report.imported.count == 1)
        #expect(report.imported.contains("agent-test-importer"))
        #expect(report.failed.count == 1)  // the no-frontmatter file
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run `SkillImporterImportTests` in Xcode.
Expected: compile failure ("value of type 'SkillImporter' has no member 'importFromExtractedDirectory'").

- [ ] **Step 3: Implement the import method and the full `importFrom(url:)` entry point**

Append:

```swift
extension SkillImporter {

    /// Walk every `.md` file under `root` (optionally filtered to
    /// `subpath` relative to the GitHub tree URL the user pasted),
    /// parse, and write to the supplied store. The store parameter is
    /// injectable for tests; in production callers pass
    /// `SkillLibraryStore.shared`.
    func importFromExtractedDirectory(
        _ root: URL,
        subpath: String?,
        store: SkillLibraryStore
    ) async -> ImportReport {
        // GitHub tarballs unpack into a single top-level
        // `<repo>-<branch>/` directory; descend into that first so the
        // user-supplied subpath ("skills", ".agents/skills") matches.
        let topLevel = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil))?.first ?? root
        let searchRoot: URL
        if let subpath, !subpath.isEmpty {
            searchRoot = topLevel.appendingPathComponent(subpath, isDirectory: true)
        } else {
            searchRoot = topLevel
        }

        var imported: [String] = []
        var skipped: [String] = []
        var failed: [String] = []

        guard let enumerator = FileManager.default.enumerator(
            at: searchRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return ImportReport(imported: imported, skipped: skipped, failed: failed)
        }

        let existingSlugs = await store.existingSlugs()

        for case let fileURL as URL in enumerator where fileURL.pathExtension == "md" {
            guard let raw = try? String(contentsOf: fileURL, encoding: .utf8) else {
                failed.append(fileURL.lastPathComponent)
                continue
            }
            let parsed = SkillFrontmatterParser.split(raw)
            guard let name = parsed.frontmatter["name"], !name.isEmpty else {
                failed.append(fileURL.lastPathComponent)
                continue
            }
            let description = parsed.frontmatter["description"] ?? "Imported skill"
            let slug = SkillFrontmatterParser.sanitizeSlug(
                fileURL.deletingPathExtension().lastPathComponent
            )
            if existingSlugs.contains(slug) {
                skipped.append(slug)
                continue
            }
            let taskTypes = SkillFrontmatterParser.inferTaskTypes(
                slug: slug, name: name, description: description
            )
            let keywords = SkillFrontmatterParser.inferKeywords(
                slug: slug, name: name, description: description
            )
            let written = await store.writeBundledSkill(
                slug: slug,
                name: name,
                description: description,
                taskTypes: taskTypes,
                keywords: keywords,
                body: parsed.body
            )
            if written != nil {
                imported.append(slug)
            } else {
                failed.append(fileURL.lastPathComponent)
            }
        }

        return ImportReport(imported: imported, skipped: skipped, failed: failed)
    }

    /// Public entry point: parse the URL, download, extract, import.
    /// Cleans up its temp files on the way out.
    func importFrom(url: String, store: SkillLibraryStore = .shared) async throws -> ImportReport {
        let ref = try Self.parseGitHubURL(url)
        let tarball = try await downloadTarball(for: ref)
        defer { try? FileManager.default.removeItem(at: tarball) }

        let extracted = try await extractTarball(at: tarball)
        defer { try? FileManager.default.removeItem(at: extracted) }

        let report = await importFromExtractedDirectory(
            extracted,
            subpath: ref.subpath,
            store: store
        )
        if report.imported.isEmpty && report.skipped.isEmpty {
            throw ImportError.noSkillsFound
        }
        return report
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run all `SkillImporterTests` in Xcode.
Expected: all tests pass; the local-fixture path imports 1 skill and reports 1 failed (the no-frontmatter file).

- [ ] **Step 5: Commit**

```bash
git add TipTour/Agents/Skills/SkillImporter.swift TipTourTests/SkillImporterTests.swift
git commit -m "feat(skills): SkillImporter end-to-end import pipeline"
```

---

## Task 5: Settings UI — "Import…" button + sheet

**Files:**
- Modify: `TipTour/Agents/UI/SettingsView.swift`

- [ ] **Step 1: Add an `@State` for the import sheet to `SkillsSettingsView`**

In `TipTour/Agents/UI/SettingsView.swift`, modify the `SkillsSettingsView` struct (starts at line 187). Add these state vars under `skills`:

```swift
@State private var skills: [SkillEntry] = []
@State private var isImporting: Bool = false
@State private var showImportSheet: Bool = false
@State private var importURL: String = ""
@State private var importStatus: String?
@State private var importError: String?
```

- [ ] **Step 2: Add the "Import…" button to the header row**

The header row currently shows the skill count and a Clear All button. Add a third button between them:

```swift
HStack {
    Text("\(skills.count) skill\(skills.count == 1 ? "" : "s")")
        .font(.system(size: 12))
        .foregroundColor(DS.Colors.textTertiary)
    Spacer()
    Button(action: { showImportSheet = true }) {
        Label("Import…", systemImage: "arrow.down.circle")
            .font(.system(size: 12))
    }
    .buttonStyle(.borderless)
    .pointerCursor()
    // ... existing "Clear All" button stays here
}
```

- [ ] **Step 3: Add the sheet content**

After the existing `.alert(...)` modifier on the outer view, add:

```swift
.sheet(isPresented: $showImportSheet) {
    VStack(alignment: .leading, spacing: 12) {
        Text("Import skills from a GitHub repo")
            .font(.headline)
        Text("Paste any public github.com URL. To import a subfolder, paste the tree URL — e.g. https://github.com/ruvnet/ruflo/tree/main/.agents/skills")
            .font(.system(size: 11))
            .foregroundColor(DS.Colors.textTertiary)

        TextField("https://github.com/owner/repo", text: $importURL)
            .textFieldStyle(.roundedBorder)
            .disabled(isImporting)

        if let status = importStatus {
            Text(status).font(.system(size: 11)).foregroundColor(DS.Colors.textSecondary)
        }
        if let error = importError {
            Text(error).font(.system(size: 11)).foregroundColor(.red)
        }

        HStack {
            Spacer()
            Button("Cancel") { showImportSheet = false }
                .disabled(isImporting)
            Button(isImporting ? "Importing…" : "Import") {
                Task { await runImport() }
            }
            .keyboardShortcut(.return)
            .disabled(isImporting || importURL.isEmpty)
        }
    }
    .padding(20)
    .frame(width: 480)
}

private func runImport() async {
    isImporting = true
    importError = nil
    importStatus = "Downloading…"
    do {
        let report = try await SkillImporter().importFrom(url: importURL)
        importStatus = "Imported \(report.imported.count), skipped \(report.skipped.count), failed \(report.failed.count)."
        await loadSkills()
    } catch let error as SkillImporter.ImportError {
        importError = error.localizedDescription
        importStatus = nil
    } catch {
        importError = error.localizedDescription
        importStatus = nil
    }
    isImporting = false
}
```

- [ ] **Step 4: Build and smoke-test in the running app**

Build (Cmd+B) then run (Cmd+R) the TipTour app. Open Settings → Skills, click Import…, paste `https://github.com/ruvnet/ruflo/tree/main/.agents/skills`, click Import. Expected: status text shows "Imported 0, skipped ~134, failed N" (the bundled skills are already present, so all RuFlo entries are skipped). Test a non-bundled repo to confirm fresh imports work — e.g. `https://github.com/anthropics/agent-skills` (or any small public repo with `.md` files).

- [ ] **Step 5: Commit**

```bash
git add TipTour/Agents/UI/SettingsView.swift
git commit -m "feat(skills): Import… button in Skills settings tab"
```

---

## Task 6: Update CLAUDE.md / AGENTS.md to document the new tool

**Files:**
- Modify: `AGENTS.md` (which is symlinked from CLAUDE.md)

- [ ] **Step 1: Add `SkillImporter.swift` and `SkillFrontmatterParser.swift` to the Key Files table**

Open `AGENTS.md`. Find the "Key Files" table and add two rows alongside the other Skills files:

```markdown
| `TipTour/Agents/Skills/SkillFrontmatterParser.swift` | ~110 | Shared parser used by `BundledSkillSeeder` and `SkillImporter`: `split` (`---` frontmatter ↔ body), `sanitizeSlug`, `inferTaskTypes`, `inferKeywords`. |
| `TipTour/Agents/Skills/SkillImporter.swift` | ~200 | Actor that turns a GitHub repo URL into installed skills: parses the URL into `(owner, repo, branch, subpath?)`, downloads `codeload.github.com` tarball, extracts via `/usr/bin/tar`, walks the result, writes through `SkillLibraryStore.writeBundledSkill`. Surfaced in Settings → Skills → "Import…" button. |
```

- [ ] **Step 2: Commit**

```bash
git add AGENTS.md
git commit -m "docs: document SkillImporter + SkillFrontmatterParser in AGENTS.md"
```

---

## Self-Review Checklist

- ✅ **Spec coverage:** Task 1 extracts the parser, Tasks 2-4 build the importer, Task 5 surfaces it in Settings, Task 6 documents it. No gaps.
- ✅ **No placeholders:** Every step has concrete code, file paths, and exact commands. The marker arrays in Task 1 step 3 reference the source file by line numbers so the engineer copies them verbatim — not "TBD".
- ✅ **Type consistency:** `ImportReport.imported` is a `[String]` in every reference; `GitHubRef` matches the struct definition; `SkillFrontmatterParser.split` returns the same `SplitResult` everywhere.

---

## Notes for the engineer

- `SkillLibraryStore.writeBundledSkill` (not `write`) is the right method for imports — it accepts pre-supplied `taskTypes` and `keywords` and skips dedup-suffixing. The seeder uses it for the same reason: imported and bundled skills have stable slugs.
- `SkillFrontmatterParser.inferTaskTypes` keeps the bundled-seeder's marker heuristics. Don't tune the heuristic in this PR — drift between bundled and imported tagging would surprise users. Tune in a separate change with a deliberate rationale.
- The `/usr/bin/tar` dependency is intentional: macOS ships it, libarchive is BSD-2 + dynamic-link risk, and we already shell out elsewhere (see `ShellTool.swift`).
- The codeload URL pattern (`codeload.github.com/owner/repo/tar.gz/branch`) is what `git clone --depth 1` uses internally and has no rate limit on public repos for typical user volume. If we hit rate limits in practice, fall back to the GitHub REST `/zipball/` endpoint.
