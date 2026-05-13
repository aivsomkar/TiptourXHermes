# Phase A — Skill Storage Migration to agentskills.io Spec

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use `- [ ]` syntax.

**Goal:** Move TipTour's on-disk skill format from flat `<slug>.md` files to spec-compliant `<slug>/SKILL.md` folders. Migration **preserves the bundled RuFlo set and any previously existing user skills** (including auto-saved, demo-recorded, etc.). **OpenWork is dropped from the bundled set** so it stops re-appearing on every launch; Hermes (which was user-imported with the previous broken importer) and the leftover OpenWork folders can be deleted by the user via Settings → Skills after Phase A lands.

**Spec reference:** https://agentskills.io/specification

**Architecture:** `SkillLibraryStore` is the single chokepoint. Change its internal storage shape. Add a migrator that runs once at launch (UserDefaults gate), walks the store dir, and moves each `<slug>.md` into a new `<slug>/SKILL.md` inside a folder of the same slug.

---

## File Structure

| Action | Path | Responsibility |
|--------|------|----------------|
| Create | `TipTour/Agents/Skills/SkillNameValidator.swift` | `isValid(_:)` per spec; `sanitize(_:)` lossy fallback |
| Create | `TipTour/Agents/Skills/SkillStoreMigrator.swift` | One-shot: `<slug>.md` → `<slug>/SKILL.md`. Idempotent. UserDefaults gate. |
| Modify | `TipTour/Agents/Skills/SkillLibraryStore.swift` | Folder-layout reads/writes/deletes |
| Modify | `TipTour/Agents/Skills/SkillEntry.swift` | Optional `license`, `compatibility`, `allowedTools` |
| Modify | `TipTour/Agents/Skills/SkillFrontmatterParser.swift` | Helper exposing spec extras |
| Modify | `TipTour/CompanionManager.swift` | Call migrator BEFORE bundled seeder at launch |
| Create | `TipTourTests/SkillStoreSpecTests.swift` | Migrator + new layout coverage |

---

## Task 1: `SkillNameValidator`

**Files:** Create `SkillNameValidator.swift` + tests.

- [ ] Test cases: valid (`pdf-processing`, `agent-coder`), invalid (`PDF-x`, `-leading`, `trailing-`, `with--double`, `""`, 65-char, `with_underscore`). Sanitizer: `"My Skill 2.0"` → `"my-skill-2-0"`, `"agent-coder"` → `"agent-coder"`, `"--weird--"` → `"weird"`.
- [ ] Implementation:
```swift
enum SkillNameValidator {
    static func isValid(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 64 else { return false }
        guard name.first != "-", name.last != "-" else { return false }
        if name.contains("--") { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        return name.unicodeScalars.allSatisfy(allowed.contains)
    }

    static func sanitize(_ raw: String) -> String {
        var out = ""
        var lastWasDash = false
        for char in raw.lowercased() {
            let isASCIIAlphaNum = (char.isLetter && char.isASCII) || (char.isNumber && char.isASCII)
            if isASCIIAlphaNum {
                out.append(char); lastWasDash = false
            } else if !lastWasDash, !out.isEmpty {
                out.append("-"); lastWasDash = true
            }
        }
        out = String(out.prefix(64)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return out
    }
}
```
- [ ] Commit: `feat(skills): SkillNameValidator per agentskills.io spec`

---

## Task 2: `SkillLibraryStore` folder layout

**Files:** Modify `SkillLibraryStore.swift` + tests.

- [ ] Path helpers:
```swift
private func skillFolderURL(slug: String) -> URL {
    directoryURL.appendingPathComponent(slug, isDirectory: true)
}
private func skillMarkdownURL(slug: String) -> URL {
    skillFolderURL(slug: slug).appendingPathComponent("SKILL.md")
}
```
- [ ] `init`: scan subdirectories of `directoryURL`. For each subdir with `SKILL.md`, parse + index. Ignore subdirs without `SKILL.md`. Ignore loose `.md` files at the top level — those are pre-migration leftovers; the migrator (Task 3) consumes them.
- [ ] `write` / `writeBundledSkill`: create the folder via `FileManager.createDirectory(withIntermediateDirectories: true)`, write `SKILL.md` inside. `write` still sanitizes invalid slugs via `SkillNameValidator.sanitize` and dedupes against the index.
- [ ] `fetchBody(slug:)` reads `skillMarkdownURL(slug:)`.
- [ ] `delete(slug:)` removes the whole folder via `removeItem(at: skillFolderURL(slug:))`.
- [ ] `clear()` enumerates subdirs and removes each. Also removes any leftover top-level `.md` files defensively.
- [ ] `evictOldestIfOverCapacity` removes folders instead of files.
- [ ] Tests: write/fetch round-trip, write-then-delete-folder-is-gone, two skills coexist, invalid-slug sanitization, name-collision dedup via `-2`.
- [ ] Commit: `refactor(skills): SkillLibraryStore uses spec folder layout`

---

## Task 3: One-shot migrator

**Files:** Create `SkillStoreMigrator.swift` + tests.

- [ ] Tests:
  - All-flat input: every `<slug>.md` becomes `<slug>/SKILL.md`.
  - Already-spec input (folders only): no-op.
  - Mixed input: flat files migrate, folders untouched.
  - Invalid-name flat file (`"My Skill.md"`): migrates with sanitized slug.
  - Slug collision: `agent-coder.md` exists AND `agent-coder/SKILL.md` exists — sanitizer adds `-2` to the migrating one.
  - Running twice: idempotent (UserDefaults flag set).
- [ ] Implementation:
```swift
enum SkillStoreMigrator {
    private static let migrationCompletedKey = "skillStoreSpecMigrationV1Complete"

    static func runIfNeeded(directoryURL: URL = SkillLibraryStore.defaultDirectoryURL) async {
        if UserDefaults.standard.bool(forKey: migrationCompletedKey) { return }
        await migrate(directoryURL: directoryURL)
        UserDefaults.standard.set(true, forKey: migrationCompletedKey)
    }

    static func migrate(directoryURL: URL) async {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey]
        )) ?? []
        let flatFiles = contents.filter {
            $0.pathExtension == "md" &&
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
        var existingSlugs = Set(
            contents
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                .map { $0.lastPathComponent }
        )
        var migrated = 0
        for fileURL in flatFiles {
            let rawStem = fileURL.deletingPathExtension().lastPathComponent
            let baseSlug = SkillNameValidator.isValid(rawStem)
                ? rawStem
                : SkillNameValidator.sanitize(rawStem)
            let finalSlug = deduplicate(baseSlug.isEmpty ? "skill" : baseSlug, against: existingSlugs)
            existingSlugs.insert(finalSlug)
            let folderURL = directoryURL.appendingPathComponent(finalSlug, isDirectory: true)
            let skillURL = folderURL.appendingPathComponent("SKILL.md")
            do {
                try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: fileURL, to: skillURL)
                migrated += 1
            } catch {
                print("[SkillStoreMigrator] failed for \(rawStem): \(error.localizedDescription)")
            }
        }
        print("[SkillStoreMigrator] migrated \(migrated) flat skill file(s) to folder format")
    }

    private static func deduplicate(_ base: String, against existing: Set<String>) -> String {
        if !existing.contains(base) { return base }
        var counter = 2
        while existing.contains("\(base)-\(counter)") { counter += 1 }
        return "\(base)-\(counter)"
    }
}
```
- [ ] Commit: `feat(skills): one-shot migrator from flat .md to SKILL.md folders`

---

## Task 4: Wire migrator into launch

**Files:** Modify `CompanionManager.swift`.

- [ ] Find the existing skill-seeding call at init. Add the migrator BEFORE it:
```swift
Task {
    await SkillStoreMigrator.runIfNeeded()
    await BundledSkillSeeder.seedBundledSkillsIfNeeded()
}
```
- [ ] Commit: `feat(skills): run spec migration before bundled-skill seeding`

---

## Task 5: Optional spec fields on `SkillEntry`

**Files:** Modify `SkillFrontmatterParser.swift` + `SkillEntry.swift` + tests.

- [ ] `SkillEntry` gains optional `let license: String?`, `let compatibility: String?`, `let allowedTools: String?`.
- [ ] `SkillEntry.parse(from:slug:)` reads them when present.
- [ ] `SkillEntry.frontmatter` serializes when non-nil:
```
license: Apache-2.0
compatibility: macOS 14+ required
allowed-tools: Bash(git:*) Read
```
- [ ] Tests: round-trip all three; round-trip with none (forward compat); parse upstream SKILL.md with `license:` — verify it surfaces.
- [ ] Commit: `feat(skills): persist optional license/compatibility/allowed-tools frontmatter`

---

## Task 6: Drop OpenWork from bundled seeder

**Files:** Modify `TipTour/Agents/Skills/BundledSkillSeeder.swift`. Optionally delete `TipTour/Agents/Skills/BundledSkills/openwork/` from the app bundle resources.

- [ ] In `enumerateBundledSkills`, change the structured-root path to only descend into `BundledSkills/ruflo/`:
```swift
let structuredRoot = resourceURL.appendingPathComponent("BundledSkills", isDirectory: true)
let rufloRoot = structuredRoot.appendingPathComponent("ruflo", isDirectory: true)
if FileManager.default.fileExists(atPath: rufloRoot.path) {
    return collectMarkdown(under: rufloRoot).compactMap { parse(fileURL: $0) }
}
```
- [ ] In the fallback flattened-group path, remove `openwork-`, `skill-`, `command-` from the accepted prefixes (those were OpenWork-specific). Keep `agent-` and `ruflo-`.
- [ ] (Optional but recommended) physically delete `TipTour/Agents/Skills/BundledSkills/openwork/` from the working tree so the app bundle gets smaller. The synced root group auto-drops it from the build.
- [ ] Tests: launch-time seeding count should drop from ~150 to ~134 (RuFlo only). Existing OpenWork folders on disk from prior launches are NOT auto-cleaned — user removes them via Settings UI.
- [ ] Commit: `feat(skills): drop OpenWork from bundled seeder`

---

## Task 7: Docs

- [ ] Update AGENTS.md Key Files: `SkillNameValidator.swift`, `SkillStoreMigrator.swift`. Update the `SkillLibraryStore.swift` row to mention folder layout. Add a 2-line architecture note on spec compliance + migration.
- [ ] Commit: `docs: document spec-compliant skill storage`

---

## Risks

1. **Migration runs concurrently with seeder if not chained.** Migrator MUST complete before seeder starts. Task 4 enforces this via sequential `await`. Don't parallelize.
2. **Bundled seeder still writes single-file bodies** until Phase C. After Phase A the seeder writes via `writeBundledSkill` which creates `<slug>/SKILL.md` — but the body content is still the flat upstream content with no `references/templates/scripts/assets`. That's correct interim state.
3. **UserDefaults flag means a botched migration won't retry.** The migrator only sets the flag after the loop returns. Individual file-move failures log a warning but don't reset the flag. Failed-to-move files stay as flat `.md` and the new `SkillLibraryStore.init` simply ignores them — they're invisible to the LRU/dedup but disk-resident. Acceptable; user can delete them by hand from `~/Library/Application Support/TipTour/skills/`.
4. **Names not matching spec regex are sanitized lossily.** `"Some Cool Skill"` becomes `"some-cool-skill"`. Slug is internal; if external code (e.g. demos with hardcoded slugs) breaks, the original name is gone.
