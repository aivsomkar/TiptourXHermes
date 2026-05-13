# Phase C — Skill Resource Tool + RuFlo Re-bundle

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use `- [ ]` syntax.
>
> **Prerequisites:** Phase A (folder layout + RuFlo-only seeder) and Phase B (folder-copy importer) both landed.

**Goal:** Give background agents progressive-disclosure access to skill resources, and re-bundle the RuFlo set as proper spec folders (with their original `references/`, `templates/`, etc. preserved from upstream).

**Architecture:**
- New agent tool `read_skill_resource(slug, relative_path)` lets a background agent read any file inside a skill's folder on demand (references/templates/scripts/assets) without bloating its system prompt.
- `recall_skill` is extended to list the available resources at the top of the returned body so the agent knows what to ask for.
- Bundled RuFlo files are rebuilt from `ruvnet/ruflo` upstream — each skill ships as a folder with its full upstream contents.

---

## File Structure

| Action | Path | Responsibility |
|--------|------|----------------|
| Create | `TipTour/Agents/Tools/SkillResourceTools.swift` | `ReadSkillResourceTool` (new) — reads `<skill-store>/<slug>/<relative-path>` |
| Modify | `TipTour/Agents/Tools/SkillTools.swift` | `RecallSkillTool.execute` lists `references/`, `templates/`, `scripts/`, `assets/` resources at the top of the returned body |
| Modify | `TipTour/Agents/Skills/SkillLibraryStore.swift` | `listResources(slug:) -> [String]` returns relative paths to non-SKILL.md files inside a skill folder; `fetchResource(slug:relativePath:) -> String?` reads safely |
| Modify | `TipTour/Agents/Tools/AgentTool.swift` | Register `ReadSkillResourceTool` alongside the existing skill tools in every task type that already has `RecallSkillTool` |
| Modify | `TipTour/Agents/Skills/BundledSkills/ruflo/` | Re-bundle: replace flat `agent-*.md` files with full folders from upstream `ruvnet/ruflo` at `.agents/skills/<name>/` |
| Modify | `TipTour/Agents/Skills/BundledSkillSeeder.swift` | When enumerating bundled skills, treat each folder containing `SKILL.md` as one skill. Call `SkillLibraryStore.installSkillFolder` instead of `writeBundledSkill`. |
| Create | `TipTourTests/SkillResourceToolsTests.swift` | Tool coverage + path-traversal safety |

---

## Task 1: `SkillLibraryStore.listResources` + `fetchResource`

**Files:** Modify `SkillLibraryStore.swift` + tests.

- [ ] Tests:
  - Empty skill folder (SKILL.md only) → `listResources` returns `[]`.
  - Folder with `references/REFERENCE.md` and `templates/intro.md` → returns `["references/REFERENCE.md", "templates/intro.md"]` (sorted).
  - `fetchResource(slug:"x", relativePath:"references/REFERENCE.md")` returns the file content.
  - `fetchResource` with `relativePath` containing `..` (path traversal) returns nil.
  - `fetchResource` with absolute path (`/etc/passwd`) returns nil.

- [ ] Implementation:
```swift
extension SkillLibraryStore {

    /// List every non-SKILL.md file inside a skill's folder, as paths
    /// relative to the folder root. Used by RecallSkillTool to advertise
    /// the resources available for progressive disclosure.
    func listResources(slug: String) async -> [String] {
        let folder = skillFolderURL(slug: slug)
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var results: [String] = []
        let folderPath = folder.path
        for case let fileURL as URL in enumerator
        where (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            if fileURL.lastPathComponent == "SKILL.md" { continue }
            let absolutePath = fileURL.path
            guard absolutePath.hasPrefix(folderPath + "/") else { continue }
            let relativePath = String(absolutePath.dropFirst(folderPath.count + 1))
            results.append(relativePath)
        }
        return results.sorted()
    }

    /// Read a single file inside a skill's folder by relative path.
    /// Rejects absolute paths and any path containing `..` to prevent
    /// agents from escaping the skill folder.
    func fetchResource(slug: String, relativePath: String) async -> String? {
        guard !relativePath.hasPrefix("/"),
              !relativePath.contains("..") else { return nil }
        let folder = skillFolderURL(slug: slug)
        let target = folder.appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: target.path) else { return nil }
        return try? String(contentsOf: target, encoding: .utf8)
    }
}
```
- [ ] Commit: `feat(skills): listResources + fetchResource for progressive disclosure`

---

## Task 2: `ReadSkillResourceTool` agent tool

**Files:** Create `SkillResourceTools.swift` + tests.

- [ ] Tool definition:
```swift
struct ReadSkillResourceTool: AgentTool {
    let taskType: TaskType

    let name = "read_skill_resource"
    let description = "Read a single file inside a skill's folder by relative path. Use this after recall_skill returns a list of available references/templates/scripts/assets and you need their content. Paths must be relative to the skill folder; absolute paths and `..` are rejected."
    let parametersJSON = #"""
    {"type":"object","properties":{"slug":{"type":"string","description":"The skill slug (folder name)."},"relative_path":{"type":"string","description":"Path relative to the skill folder, e.g. 'references/REFERENCE.md'."}},"required":["slug","relative_path"]}
    """#

    func execute(argumentsJSON: String) async -> String {
        guard let data = argumentsJSON.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let slug = dict["slug"] as? String,
              let relativePath = dict["relative_path"] as? String else {
            return "Error: arguments must be { slug: string, relative_path: string }"
        }
        guard let content = await SkillLibraryStore.shared.fetchResource(slug: slug, relativePath: relativePath) else {
            return "Error: resource not found at \(slug)/\(relativePath) (or path was rejected for security)"
        }
        return content
    }
}
```
- [ ] Tests: tool args parse correctly; missing slug → error message; valid call returns content; path traversal returns the security error string.
- [ ] Commit: `feat(skills): read_skill_resource agent tool`

---

## Task 3: Register the tool

**Files:** Modify `AgentTool.swift`.

- [ ] In `ToolBox.build(for:)` and overloads, add `ReadSkillResourceTool(taskType: taskType)` to the `sharedTools` array next to `RecallSkillTool`. The tool is universal — every task type that has `recall_skill` also gets `read_skill_resource`.
- [ ] Smoke check that no provider's tool-schema serialization complains about the new entry.
- [ ] Commit: `feat(skills): wire read_skill_resource into every task type's toolbox`

---

## Task 4: `RecallSkillTool` lists resources

**Files:** Modify `SkillTools.swift` + tests.

- [ ] Update `RecallSkillTool.execute` to prepend an "## Available resources" header listing the relative paths, when non-empty:

```swift
func execute(argumentsJSON: String) async -> String {
    // ... existing argument parsing
    guard let body = await SkillLibraryStore.shared.fetchBody(slug: slug) else {
        return "Error: no skill with slug '\(slug)'"
    }
    let resources = await SkillLibraryStore.shared.listResources(slug: slug)
    guard !resources.isEmpty else { return body }
    let header = """
    ## Available resources (use `read_skill_resource(slug: \"\(slug)\", relative_path: …)` to read)
    \(resources.map { "- \($0)" }.joined(separator: "\n"))

    ---

    """
    return header + body
}
```
- [ ] Tests:
  - Skill with no resources: response equals the body (no header).
  - Skill with two resources: response begins with the header listing both paths in sorted order, separated from the body by `---`.
- [ ] Commit: `feat(skills): recall_skill advertises available resources`

---

## Task 5: Re-bundle RuFlo as folders

**Files:** Replace contents of `TipTour/Agents/Skills/BundledSkills/ruflo/` with the upstream folder structure.

- [ ] Download the upstream RuFlo skills tree once:
```bash
cd /tmp
curl -L https://codeload.github.com/ruvnet/ruflo/tar.gz/main -o ruflo.tar.gz
tar -xzf ruflo.tar.gz
SOURCE="/tmp/ruflo-main/.agents/skills"
DEST="/Users/omkar/Desktop/TipTour-macOS/repo/TipTour/Agents/Skills/BundledSkills/ruflo"
rm -rf "$DEST"
mkdir -p "$DEST"
cp -R "$SOURCE/." "$DEST/"
rm -rf /tmp/ruflo-main /tmp/ruflo.tar.gz
```
- [ ] Verify: `ls "$DEST" | head` should show folder names matching the bundled slugs (e.g. `agent-coder/`, `agent-tester/`), each containing `SKILL.md` (and possibly references/templates).
- [ ] Verify a sample: `cat "$DEST/agent-coder/SKILL.md" | head` should show valid frontmatter.
- [ ] Commit: `feat(skills): re-bundle RuFlo upstream as spec folders`

(Optional caveat: the upstream RuFlo set may have ~140+ subfolders. App-bundle size will grow modestly. If size becomes a concern, a follow-up could trim to a curated subset.)

---

## Task 6: `BundledSkillSeeder` walks folders

**Files:** Modify `BundledSkillSeeder.swift`.

- [ ] Replace `enumerateBundledSkills` to scan for `SKILL.md` files inside `BundledSkills/ruflo/`. Each match's parent folder is one bundled skill.
- [ ] Replace the call to `SkillLibraryStore.shared.writeBundledSkill(...)` with `SkillLibraryStore.shared.installSkillFolder(slug: parentFolder.lastPathComponent, source: parentFolder, overrideExisting: false)`. Drop the `inferTaskTypes`/`inferKeywords` calls — those were per-file heuristics; the spec frontmatter carries everything we need natively, and the parser handles `name`/`description`/`license`/etc.
- [ ] Existing slug-skip logic already lives in `installSkillFolder` (returns nil when destination exists and `overrideExisting=false`). Adjust the seeder's skip-counting to use this nil signal.
- [ ] Tests: launch with empty store seeds N skills; second launch seeds 0 (skip-on-existing); a skill with `references/` ends up with that file at `~/Library/Application Support/TipTour/skills/<slug>/references/...`.
- [ ] Commit: `refactor(skills): bundled seeder copies whole skill folders`

---

## Task 7: Docs

- [ ] Update AGENTS.md: add `SkillResourceTools.swift`, document `listResources`/`fetchResource` in the `SkillLibraryStore.swift` row, document `read_skill_resource` in the architecture section. Note that bundled skills are now full spec folders (RuFlo upstream verbatim).
- [ ] Commit: `docs: progressive disclosure tools + re-bundled RuFlo`

---

## Risks

1. **Re-bundling RuFlo grows the app bundle.** Some skills include large `references/` or `assets/`. Verify the final bundle size; if it's surprising (e.g. >50 MB net), consider committing a `BUNDLE.txt` allow-list and pruning. For v1 ship verbatim.
2. **Path traversal protection is regex-soft.** `fetchResource` rejects `..` substring and absolute paths. A path like `references/../scripts/x.sh` would be rejected; `references%2F..%2F` from a URL-encoded source would NOT be (we operate on the post-decode string, but worth a manual review). Mitigation: caller controls slug + path; the LLM is the threat surface, not the user. Reject defensively.
3. **`installSkillFolder` is not transactional.** Crash mid-copy leaves a partial folder. The store's `init` ignores folders without `SKILL.md`, so a partial copy that didn't write SKILL.md last is invisible. If SKILL.md WAS written first and other files failed, the entry shows in the index but has incomplete resources. Acceptable for v1; a future fix could write to a temp folder and rename.
4. **Existing-slug skip vs override:** The seeder calls with `overrideExisting: false`, so the user's customizations to bundled skills survive launches. This matches the previous bundled-seeder contract.
5. **OpenWork imports are now permanently un-bundled** (Phase A dropped them). If you ever want them back, importing `https://github.com/different-ai/openwork/tree/main/.opencode/skills` via the new spec-aware importer would land them correctly.
