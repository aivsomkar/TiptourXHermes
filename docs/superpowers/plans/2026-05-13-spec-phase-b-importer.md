# Phase B — Importer Rewrite for Folder-Based Skills

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use `- [ ]` syntax.
>
> **Prerequisite:** Phase A complete (`SkillLibraryStore` writes `<slug>/SKILL.md` folders; migrator already moved any flat files).

**Goal:** Rewrite `SkillImporter` so it discovers skills by anchoring on `SKILL.md`, then copies the **entire enclosing folder** (including `references/`, `templates/`, `scripts/`, `assets/`) into the store. The previous body-only importer is gone; the new one is spec-aware end-to-end.

**Architecture:** When walking an extracted tarball, find every `SKILL.md`. Its parent directory IS the skill (the spec requires `name` to match the parent dir name). Copy the entire parent folder verbatim into `SkillLibraryStore`, mapped to `<slug>/`. Index update via `SkillLibraryStore.writeBundledSkill` so the in-memory `SkillEntry` is created from the parsed frontmatter.

---

## File Structure

| Action | Path | Responsibility |
|--------|------|----------------|
| Modify | `TipTour/Agents/Skills/SkillImporter.swift` | Replace `importFromExtractedDirectory(_:subpath:store:)` with new SKILL.md-anchored discovery + folder copy. Remove `deriveImportSlug` (no longer needed). |
| Modify | `TipTour/Agents/Skills/SkillLibraryStore.swift` | Add `installSkillFolder(slug:source:overrideExisting:)` — atomically copies a folder into the store, parses its `SKILL.md`, updates the index. Returns the final slug or nil. |
| Modify | `TipTourTests/SkillImporterTests.swift` | Replace the current fixture with a multi-file fixture containing `SKILL.md` + `references/` + `templates/`. Test that referenced files land in the store. |
| Create | `TipTourTests/Fixtures/skill-folder-fixture.tar.gz` | Replaces `skill-fixture.tar.gz`. Two skill folders, one with refs, one without; plus a sibling non-skill directory to verify the discovery filter. |

---

## Task 1: `SkillLibraryStore.installSkillFolder`

**Files:** Modify `SkillLibraryStore.swift` + tests.

Why a new entry point: `writeBundledSkill` takes pre-parsed fields and a body string — it's file-content-oriented. The new flow is folder-content-oriented. We need atomic folder copy with index sync.

- [ ] Tests:
  - Source folder with `SKILL.md` only: copies, index has the entry, body matches.
  - Source folder with `SKILL.md` + `references/foo.md`: both files at destination; index has the entry.
  - Source `SKILL.md` lacks `name` field: returns nil; destination folder NOT created; index unchanged.
  - Slug-collision with existing folder + `overrideExisting=false`: returns nil; destination unchanged.
  - Slug-collision + `overrideExisting=true`: replaces.

- [ ] Implementation:
```swift
extension SkillLibraryStore {

    /// Install a spec-format skill folder (containing SKILL.md +
    /// optional references/templates/scripts/assets/) into the store.
    /// The slug is taken from the source folder's last path component
    /// (matches the spec's "name must match parent dir" rule) and
    /// validated via SkillNameValidator. Returns the final on-disk
    /// slug or nil on failure.
    func installSkillFolder(
        slug rawSlug: String,
        source sourceFolderURL: URL,
        overrideExisting: Bool = false
    ) async -> String? {
        // Validate or sanitize the slug.
        let slug = SkillNameValidator.isValid(rawSlug) ? rawSlug : SkillNameValidator.sanitize(rawSlug)
        guard !slug.isEmpty else { return nil }

        // Read + parse SKILL.md from the source.
        let sourceSkillMd = sourceFolderURL.appendingPathComponent("SKILL.md")
        guard let rawContent = try? String(contentsOf: sourceSkillMd, encoding: .utf8),
              let entry = SkillEntry.parse(from: rawContent, slug: slug),
              !entry.name.isEmpty else {
            return nil
        }

        // Resolve destination, handling collision.
        let destination = skillFolderURL(slug: slug)
        if FileManager.default.fileExists(atPath: destination.path) {
            guard overrideExisting else { return nil }
            try? FileManager.default.removeItem(at: destination)
        }

        // Copy the whole source folder verbatim.
        do {
            try FileManager.default.copyItem(at: sourceFolderURL, to: destination)
        } catch {
            print("[SkillLibraryStore] installSkillFolder copy failed for \(slug): \(error.localizedDescription)")
            return nil
        }

        // Update the in-memory index.
        if let existing = index.firstIndex(where: { $0.slug == slug }) {
            index[existing] = entry
        } else {
            index.append(entry)
            evictOldestIfOverCapacity()
        }
        return slug
    }
}
```

- [ ] Commit: `feat(skills): SkillLibraryStore.installSkillFolder copies whole spec folder`

---

## Task 2: Rewrite `SkillImporter.importFromExtractedDirectory`

**Files:** Modify `SkillImporter.swift`.

- [ ] Replace the existing method body. New flow:
  1. Resolve `searchRoot` (same logic — descend through tarball top-level + optional subpath).
  2. Walk for files named `SKILL.md`. For each, the parent folder is the skill.
  3. Validate the parent folder's name via `SkillNameValidator`. Sanitize if needed. Dedupe against `existingSlugs` BEFORE copy — skipped slugs go to `skipped`.
  4. Call `await store.installSkillFolder(slug:source:overrideExisting:false)`. On success → `imported`; on nil → `failed` with the folder's basename.

```swift
extension SkillImporter {
    func importFromExtractedDirectory(
        _ root: URL,
        subpath: String?,
        store: SkillLibraryStore
    ) async -> ImportReport {
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
        ) else { return ImportReport(imported: imported, skipped: skipped, failed: failed) }

        let existingSlugs = await store.existingSlugs()

        for case let fileURL as URL in enumerator where fileURL.lastPathComponent == "SKILL.md" {
            let parentFolder = fileURL.deletingLastPathComponent()
            let rawSlug = parentFolder.lastPathComponent
            let slug = SkillNameValidator.isValid(rawSlug) ? rawSlug : SkillNameValidator.sanitize(rawSlug)
            guard !slug.isEmpty else {
                failed.append(parentFolder.lastPathComponent)
                continue
            }
            if existingSlugs.contains(slug) {
                skipped.append(slug)
                continue
            }
            if let written = await store.installSkillFolder(slug: slug, source: parentFolder) {
                imported.append(written)
            } else {
                failed.append(parentFolder.lastPathComponent)
            }
        }

        return ImportReport(imported: imported, skipped: skipped, failed: failed)
    }
}
```

- [ ] Delete `deriveImportSlug` from the file — no longer used (spec mandates parent-dir = slug, so the heuristic for generic stems is redundant).
- [ ] `importFrom(url:store:)` unchanged at the call-site level — it still calls `importFromExtractedDirectory`. The internal contract is preserved.
- [ ] Commit: `refactor(skills): importer anchors on SKILL.md, copies whole folder`

---

## Task 3: New multi-file fixture

**Files:** Replace `TipTourTests/Fixtures/skill-fixture.tar.gz` with a new fixture that exercises folder-based discovery.

- [ ] Build the fixture:
```bash
mkdir -p /tmp/skill-folder-fixture/skills/test-importer-skill/references
mkdir -p /tmp/skill-folder-fixture/skills/empty-skill
mkdir -p /tmp/skill-folder-fixture/skills/not-a-skill-dir

cat > /tmp/skill-folder-fixture/skills/test-importer-skill/SKILL.md <<'EOF'
---
name: test-importer-skill
description: A fixture skill used by SkillImporterTests
---

# Test Importer
Body.
EOF

cat > /tmp/skill-folder-fixture/skills/test-importer-skill/references/REFERENCE.md <<'EOF'
# Reference
Reference content.
EOF

cat > /tmp/skill-folder-fixture/skills/empty-skill/SKILL.md <<'EOF'
# No frontmatter, should fail
EOF

cat > /tmp/skill-folder-fixture/skills/not-a-skill-dir/notes.md <<'EOF'
# Loose notes, no SKILL.md — should be ignored entirely
EOF

cd /tmp && tar -czf skill-folder-fixture.tar.gz skill-folder-fixture
mv /tmp/skill-folder-fixture.tar.gz /Users/omkar/Desktop/TipTour-macOS/repo/TipTourTests/Fixtures/
rm -rf /tmp/skill-folder-fixture
```
- [ ] Delete the old `skill-fixture.tar.gz`.

---

## Task 4: Update tests for new fixture + flow

**Files:** Modify `TipTourTests/SkillImporterTests.swift`.

- [ ] Update both `SkillImporterExtractionTests` and `SkillImporterImportTests` to use `skill-folder-fixture` instead of `skill-fixture`.
- [ ] In `SkillImporterImportTests.importFromExtractedDirectoryWritesSkillsToStore`:
  - Assert `report.imported.count == 1`, `report.imported.contains("test-importer-skill")`.
  - Assert `report.failed.count == 1` (the `empty-skill` folder — has SKILL.md but no `name` frontmatter).
  - Assert the `not-a-skill-dir` folder is invisible to the report (`!report.imported.contains("not-a-skill-dir") && !report.failed.contains("not-a-skill-dir")`).
  - NEW assertion: the references file landed in the store:
    ```swift
    let referencesURL = testStoreDir
        .appendingPathComponent("test-importer-skill")
        .appendingPathComponent("references")
        .appendingPathComponent("REFERENCE.md")
    #expect(FileManager.default.fileExists(atPath: referencesURL.path))
    ```
- [ ] Commit: `test(skills): folder-based fixture for spec-format imports`

---

## Task 5: Docs

- [ ] Update AGENTS.md: `SkillImporter.swift` row description — note SKILL.md-anchored discovery + full-folder copy. `SkillLibraryStore.swift` row — note `installSkillFolder`.
- [ ] Commit: `docs: document SKILL.md-anchored importer`

---

## Risks

1. **Folder copy is not atomic across mount points.** `FileManager.copyItem` is filesystem-best-effort. Failures partway leave a partial destination. Mitigation: `removeItem` on failure (Task 1 implementation already does this implicitly by NOT updating the index on copy failure; consider an explicit `try? remove` after a failed copy if real-world races bite).
2. **Slug collision on bundled re-import.** If user imports a repo whose `<slug>/SKILL.md` parent dir name matches a bundled slug, the importer reports `skipped` (existing). User expects this — repeated re-imports of bundled URLs report skipped.
3. **Large skill folders waste disk.** Some upstream `templates/` or `assets/` folders can be tens of MB. We copy verbatim. No size cap. Mitigation: future Settings tab could show disk usage per skill.
4. **`importFromExtractedDirectory` is no longer "no-frontmatter file = failed".** A folder with a `SKILL.md` that has no `name:` frontmatter is failed. A folder with no `SKILL.md` is INVISIBLE (not in the report at all). This is a behavior change — the previous "289 failed" report for the Hermes import will become "0 failed" because references/templates folders just don't have SKILL.md so they're ignored. Confirm this in the UI status string after Phase B + Phase C land.
