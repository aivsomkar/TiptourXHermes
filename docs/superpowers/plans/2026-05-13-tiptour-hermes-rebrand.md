# TipTour → TipTour_Hermes Rebrand — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Subtract everything in this project that belongs to TipTour's old agent runtime (swarm, skill library, demonstration recorder, efficiency monitor, workflow engine, image-generation tool, analytics, Sparkle update feed, Cloudflare worker, TipTour-branded release artifacts), rename the user-visible identity to `TipTour_Hermes`, and land a clean codebase that Plan 2 can build the Hermes-driven chat/voice/overlay on. Keep Plan 1's bundled Hermes runtime infra and TipTour's "body" (menu-bar shell, push-to-talk, on-screen Arc Reactor overlay, Iron Man / Jarvis sound effects, Gemini Live STT, screen capture, a11y tree).

**Architecture:** Subtractive change applied to the existing `main` branch in place. Identity strings flip first; then a single "deep excision" task strips swarm/workflow/skill references from the kept files (`CompanionManager.swift`, `CompanionPanelView.swift`, `SettingsView.swift`, `TipTourApp.swift`) so the to-be-deleted modules become unreferenced; then each `TipTour/Agents/*` subtree is deleted in dependency order (leaves first). Builds run between every task and `HermesBundleTests` plus the Python ACP smoke test gate each commit.

**Tech Stack:** Xcode 26.5, Swift, AppKit/SwiftUI, Bash, `xcodebuild` for verification. No new dependencies are introduced.

**Spec:** [docs/superpowers/specs/2026-05-13-tiptour-hermes-rebrand-design.md](../specs/2026-05-13-tiptour-hermes-rebrand-design.md)

---

## File-structure summary

Every file path referenced in the plan is verified to exist (or to be the target of an explicit creation step) as of commit `6c81e02` on `main`. Anything not listed below is untouched.

**Files this plan deletes (33 files + 4 directories + 1 worker subtree):**

- `TipTour/Agents/Core/EfficiencyMonitor.swift`
- `TipTour/Agents/Core/EfficiencyTypes.swift`
- `TipTour/Agents/Memory/AgentMemoryEntry.swift`
- `TipTour/Agents/Memory/AgentMemoryStore.swift`
- `TipTour/Agents/Overlay/AgentOverlayStackView.swift`
- `TipTour/Agents/Overlay/AgentOverlayWindowController.swift`
- `TipTour/Agents/Overlay/AgentPanelView.swift`
- `TipTour/Agents/Overlay/AgentStateDisplay.swift`
- `TipTour/Agents/Providers/` (entire directory; LLM provider implementations only used by the swarm)
- `TipTour/Agents/Skills/` (entire directory: `BundledSkillSeeder.swift`, `DemonstrationRecorder.swift`, `DemonstrationTypes.swift`, `SkillEntry.swift`, `SkillExtractor.swift`, `SkillFrontmatterParser.swift`, `SkillImporter.swift`, `SkillLibraryStore.swift`, `SkillNameValidator.swift`, `SkillSpecValidator.swift`, `SkillStoreMigrator.swift`, and the `BundledSkills/` subtree of ~3k files)
- `TipTour/Agents/Swarm/AgentSwarmManager.swift`
- `TipTour/Agents/Swarm/AgentTypes.swift`
- `TipTour/Agents/Swarm/TaskAgent.swift`
- `TipTour/Agents/Tools/AgentTool.swift`
- `TipTour/Agents/Tools/GenerationTools.swift`
- `TipTour/Agents/Tools/SkillTools.swift`
- `TipTour/WorkflowPlan.swift`
- `TipTour/WorkflowRunner.swift`
- `TipTour/TipTourAnalytics.swift`
- `TipTourTests/AgentMemoryTests.swift`
- `TipTourTests/AgentOverlayTests.swift`
- `TipTourTests/AgentSwarmTests.swift`
- `TipTourTests/AgentToolTests.swift`
- `TipTourTests/DemonstrationTests.swift`
- `TipTourTests/EfficiencyMonitorTests.swift`
- `TipTourTests/GenerationToolTests.swift`
- `TipTourTests/IntegrationPolishTests.swift`
- `TipTourTests/leanring_buddyTests.swift`
- All `TipTourTests/Skill*Tests.swift` files (`SkillEntrySpecFieldsTests`, `SkillFrontmatterParserBlockScalarTests`, `SkillImporterTests`, `SkillLibraryStoreFolderTests`, `SkillLibraryStoreInstallTests`, `SkillLibraryTests`, `SkillNameValidatorTests`, `SkillResourceToolsTests`, `SkillSpecValidatorTests`, `SkillStoreMigratorTests`)
- `appcast.xml`
- `dmg-background.png`
- `frame 1.svg`, `frame 2.svg`, `frame 3.svg`, `frame 4.svg`, `frame 5.svg`
- `scripts/release.sh`, `scripts/validate-bundled-skills.sh`, `scripts/README.md`, `scripts/` directory itself
- `worker/` directory (TipTour's Cloudflare worker — `package.json`, `package-lock.json`, `wrangler.toml`, `src/index.ts`)

**Files this plan edits (no deletion):**

- `tiptour-macos.xcodeproj/project.pbxproj` — display name + product name (Task 1), Sparkle removal (Task 2), PostHog removal (Task 3), remove `BundledSkills` resource reference and the long `membershipExceptions` list of SKILL.md paths (Task 7)
- `tiptour-macos.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` — drop Sparkle + posthog-ios entries (Tasks 2 & 3)
- `TipTour/Info.plist` — `NS*UsageDescription` strings, "TipTour" → "TipTour_Hermes" (Task 1)
- `TipTour/TipTourApp.swift` — strip `import Sparkle`, `import PostHog`, `TipTourAnalytics.*` calls, `sparkleUpdaterController`, `startSparkleUpdater()`; rename Swift `struct TipTourApp` → `struct TipTour_HermesApp` (Tasks 1, 2, 3, 4)
- `TipTour/CompanionManager.swift` — excise all swarm / workflow / skill orchestration (Task 6)
- `TipTour/CompanionPanelView.swift` — excise `WorkflowRunner` / `WorkflowPlan` / Skills-save UI (Task 6)
- `TipTour/Agents/UI/SettingsView.swift` — drop the `Skills` tab and any other swarm/skill-specific tabs (Task 6)
- `TipTour/Agents/UI/` siblings of `SettingsView.swift` — anything in this directory that depends on the stripped modules; the `Agents/UI/` directory itself is **kept** but trimmed (Task 6)

**Files this plan leaves alone (the kept "body"):**

- Build infra: `BuildScripts/`, `Tests/Python/`, `docs/superpowers/`, `.gitignore`
- App shell: `TipTour/TipTourApp.swift` (after Task 4 edits)
- Menu bar: `TipTour/MenuBarPanelManager.swift`, `TipTour/AppBundleConfiguration.swift`
- Push-to-talk: `TipTour/PushToTalkShortcut.swift`, `TipTour/GlobalPushToTalkShortcutMonitor.swift`
- Voice STT: `TipTour/GeminiLiveSession.swift`, `TipTour/GeminiLiveClient.swift`, `TipTour/GeminiLiveAudioPlayer.swift`, `TipTour/PCM16AudioConverter.swift`, `TipTour/RetryWithExponentialBackoff.swift`
- Screen capture: `TipTour/ScreenRecorder.swift`, `TipTour/CompanionScreenCaptureUtility.swift`, `TipTour/ScreenshotPerceptualHash.swift`
- A11y: `TipTour/AccessibilityTreeResolver.swift`, `TipTour/ActionExecutor.swift`, `TipTour/ElementResolver.swift`, `TipTour/ClickDetector.swift`, `TipTour/WindowPositionManager.swift`
- Arc Reactor cursor + overlay: `TipTour/NekoCursorView.swift`, `TipTour/OverlayWindow.swift`, `TipTour/CompanionResponseOverlay.swift`, `TipTour/NekoSprites/` directory
- Sound effects: top-level `ironman-repulsors.mp3`, `jarvislistening.wav`, `jarvisworking.wav`
- Reactor image assets: `TipTour/Assets.xcassets/ReactorActive.imageset`, `ReactorFrame1..5.imageset`, `ReactorIdle.imageset`
- Keychain: `TipTour/KeychainStore.swift`
- Companion UI surface: `TipTour/CompanionManager.swift` (after Task 6 excision), `TipTour/CompanionPanelView.swift` (after Task 6 excision), `TipTour/DesignSystem.swift`, `TipTour/TipTour.entitlements`
- Plan-1 Swift test: `TipTourTests/HermesBundleTests.swift`
- TipTour-test surviving files: `TipTourTests/Fixtures/` (if any keep-list test references it), `TipTourUITests/` (do not touch; UI tests are orthogonal to this rebrand)

---

## Verification commands used throughout

These three commands appear in many tasks. Reference them by name to keep the plan compact.

**BUILD-CHECK** — confirms the project compiles:

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  xcodebuild -project tiptour-macos.xcodeproj -scheme tiptour-macos \
             -configuration Debug build 2>&1 | tail -5
```
Expected: last line is `** BUILD SUCCEEDED **`.

**TEST-CHECK** — confirms `HermesBundleTests` still passes:

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  xcodebuild -project tiptour-macos.xcodeproj -scheme tiptour-macos \
             -configuration Debug test \
             -only-testing:tiptour-macosTests/HermesBundleTests 2>&1 | \
  grep -E '^\*\* (TEST|BUILD) (SUCCEEDED|FAILED)|Test Case.*(passed|failed)'
```
Expected: three `Test Case ... passed` lines, then `** TEST SUCCEEDED **`.

**SMOKE-CHECK** — confirms the Python ACP smoke test still passes (phase 1 only; no key required):

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  PYTHONUNBUFFERED=1 ./Tests/Python/smoke_test_acp.py
```
Expected: `→ Phase 1: initialize`, one `←` frame line, then `PASS (phase 1)`, exit 0.

---

## Task 1: Pre-flight rollback tag

**Files:** none (git only).

- [ ] **Step 1: Verify the working tree is clean.**

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && git status --short
```
Expected: empty output (or only the `.claude/` untracked directory, which is fine). If anything else is dirty, stash or commit it before proceeding.

- [ ] **Step 2: Tag the current `main` head as `pre-rebrand`.**

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  git tag pre-rebrand && \
  git tag --list pre-rebrand
```
Expected: prints `pre-rebrand`. If anything in this plan goes off the rails, `git reset --hard pre-rebrand` restores Plan-1-complete state. The tag is local-only — never gets pushed.

---

## Task 2: Identity rename

**Files:**
- Modify: `tiptour-macos.xcodeproj/project.pbxproj` (4 lines: `INFOPLIST_KEY_CFBundleDisplayName` x2, `PRODUCT_NAME` x2)
- Modify: `TipTour/Info.plist` (~12 `NS*UsageDescription` strings)
- Modify: `TipTour/TipTourApp.swift` (Swift `struct` name)

- [ ] **Step 1: Flip display name and product name in pbxproj.**

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  sed -i '' \
    -e 's/INFOPLIST_KEY_CFBundleDisplayName = TipTour;/INFOPLIST_KEY_CFBundleDisplayName = TipTour_Hermes;/g' \
    -e 's/PRODUCT_NAME = TipTour;/PRODUCT_NAME = TipTour_Hermes;/g' \
    tiptour-macos.xcodeproj/project.pbxproj && \
  grep -n 'INFOPLIST_KEY_CFBundleDisplayName\|PRODUCT_NAME = TipTour' \
    tiptour-macos.xcodeproj/project.pbxproj | head -6
```
Expected: 4 lines showing `TipTour_Hermes`, plus the unchanged `PRODUCT_NAME = "$(TARGET_NAME)"` lines for the test targets (those use the target's name, no edit needed).

- [ ] **Step 2: Replace TipTour with TipTour_Hermes in Info.plist permission strings.**

Every `TipTour` mention in `Info.plist` lives inside `<string>...</string>` permission descriptions (23 occurrences in Plan 1's snapshot — verify with `grep -c TipTour TipTour/Info.plist`). Some are at the start of a description, some are mid-string (e.g. "the first time TipTour tries..."). A single safe substitution handles both.

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  python3 - <<'PY'
import re
path = "TipTour/Info.plist"
text = open(path).read()
# Replace `TipTour` only when NOT immediately followed by `_` (otherwise a re-run
# would turn `TipTour_Hermes` into `TipTour_Hermes_Hermes`). The negative
# lookahead makes the substitution idempotent.
text = re.sub(r'TipTour(?!_)', 'TipTour_Hermes', text)
open(path, 'w').write(text)
PY
grep -c 'TipTour_Hermes' TipTour/Info.plist
echo '---unrewritten TipTour count (should be 0):'
grep -cE 'TipTour(?!_Hermes)' TipTour/Info.plist 2>/dev/null || \
  python3 -c "import re; print(sum(1 for _ in re.finditer(r'TipTour(?!_)', open('TipTour/Info.plist').read())))"
```
Expected: first count ≥20 (per-mention occurrences), second count is `0`. (The `grep -cE` line uses negative lookahead which BSD `grep` doesn't support — the Python fallback runs if `grep` errors.)

- [ ] **Step 3: Rename the Swift `struct TipTourApp` to `struct TipTour_HermesApp`.**

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  sed -i '' \
    -e 's/struct TipTourApp:/struct TipTour_HermesApp:/g' \
    -e 's/@main *$/@main/g' \
    TipTour/TipTourApp.swift && \
  grep -n 'struct TipTour' TipTour/TipTourApp.swift
```
Expected: one line showing `struct TipTour_HermesApp:`. Filename stays `TipTourApp.swift` (renaming the file changes pbxproj path entries and is out of scope per spec).

- [ ] **Step 4: BUILD-CHECK.**

Run the BUILD-CHECK from the top of the plan. Expected: `** BUILD SUCCEEDED **`. If it fails with "cannot find type 'TipTourApp'" anywhere else, search for it: `grep -rn 'TipTourApp' TipTour/ TipTourTests/ TipTourUITests/` and rename those references too (most likely zero — `@main` typically isn't referenced by name elsewhere).

- [ ] **Step 5: Commit.**

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  git add tiptour-macos.xcodeproj/project.pbxproj TipTour/Info.plist TipTour/TipTourApp.swift && \
  git commit -m "rebrand: display name TipTour → TipTour_Hermes (pbxproj + plist + @main struct)"
```

---

## Task 3: Disconnect Sparkle

**Files:**
- Modify: `tiptour-macos.xcodeproj/project.pbxproj` (4 sections: `PBXBuildFile`, `PBXFrameworksBuildPhase.files`, `productRefs`, `XCRemoteSwiftPackageReference`)
- Modify: `tiptour-macos.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` (drop `sparkle` entry)
- Modify: `TipTour/TipTourApp.swift` (remove `import Sparkle`, `sparkleUpdaterController`, `startSparkleUpdater()`)

- [ ] **Step 1: Inspect what Sparkle integration looks like in TipTourApp.swift.**

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  grep -n 'Sparkle\|sparkle\|SPUStandard' TipTour/TipTourApp.swift
```
Confirm references match expectations: `import Sparkle` (line 13), `sparkleUpdaterController` (line 36), `startSparkleUpdater()` invocation (line 64), `startSparkleUpdater()` definition (line 104), close brace of method (look for it).

- [ ] **Step 2: Remove Sparkle from TipTourApp.swift.**

Open `TipTour/TipTourApp.swift` and:
- Delete the `import Sparkle` line at the top.
- Delete the line `private var sparkleUpdaterController: SPUStandardUpdaterController?` (and any associated property comments).
- Delete the call to `startSparkleUpdater()` from `init` / `applicationDidFinishLaunching` / wherever it lives (line 64 area).
- Delete the entire `private func startSparkleUpdater() { ... }` method body (lines ~104 through its closing brace).

Then verify nothing Sparkle-related remains:

```bash
grep -n 'Sparkle\|SPUStandard' TipTour/TipTourApp.swift
```
Expected: no output.

- [ ] **Step 3: Remove Sparkle from project.pbxproj.**

In `tiptour-macos.xcodeproj/project.pbxproj`, delete these lines (line numbers are from the current commit but may shift; grep for the exact strings):

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  grep -n 'Sparkle' tiptour-macos.xcodeproj/project.pbxproj
```

Delete:
1. The `PBXBuildFile` line `AA00BB032F6500030039DA55 /* Sparkle in Frameworks */ = ...;` (around line 10).
2. The matching entry in the Frameworks build phase `files = ( ... AA00BB032F6500030039DA55 /* Sparkle in Frameworks */, ... );` (around line 217).
3. The matching entry in the target's `packageProductDependencies = ( ... AA00BB022F6500020039DA55 /* Sparkle */, ... );` (around line 281).
4. The matching entry in the project's `packageReferences = ( ... AA00BB012F6500010039DA55 /* XCRemoteSwiftPackageReference "Sparkle" */, ... );` (around line 367).
5. The `XCRemoteSwiftPackageReference "Sparkle"` block at the bottom (around line 848-853 — 6 lines including the opening `{` and trailing `};`).
6. The `XCSwiftPackageProductDependency` block for Sparkle (search for `productRef = AA00BB022F6500020039DA55` or `package = AA00BB012F6500010039DA55`).

Delete each entry. The pbxproj has a `requirement = { ... }` nested block inside `XCRemoteSwiftPackageReference`, so naive regexes that match `{[^}]*}` will stop at the inner closing brace. We use a brace-counter helper instead.

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  python3 - <<'PY'
import re
path = "tiptour-macos.xcodeproj/project.pbxproj"
src = open(path).read()
lines = src.splitlines(keepends=True)

def delete_simple(pattern):
    """Drop every full line matching `pattern` (substring match)."""
    return [ln for ln in lines if pattern not in ln]

def delete_block(start_marker):
    """Drop a `IDENT /* ... */ = { ... };` block starting on the line containing
    `start_marker`, by counting braces until depth returns to 0."""
    out = []
    i = 0
    while i < len(lines):
        ln = lines[i]
        if start_marker in ln and '= {' in ln:
            depth = ln.count('{') - ln.count('}')
            i += 1
            while i < len(lines) and depth > 0:
                depth += lines[i].count('{') - lines[i].count('}')
                i += 1
            continue  # entire block dropped
        out.append(ln)
        i += 1
    return out

# 1. One-line PBXBuildFile + Frameworks entries + ref-list entries
for needle in [
    'AA00BB032F6500030039DA55 /* Sparkle in Frameworks */',
    'AA00BB022F6500020039DA55 /* Sparkle */,',
    'AA00BB012F6500010039DA55 /* XCRemoteSwiftPackageReference "Sparkle" */,',
]:
    lines = [ln for ln in lines if needle not in ln]

# 2. Multi-line definition blocks (brace-counted, handles nested `requirement = { ... }`)
lines = delete_block('AA00BB012F6500010039DA55 /* XCRemoteSwiftPackageReference "Sparkle" */')
lines = delete_block('AA00BB022F6500020039DA55 /* Sparkle */')

open(path, 'w').writelines(lines)
PY
grep -c 'Sparkle' tiptour-macos.xcodeproj/project.pbxproj
```
Expected: `0`. If non-zero, list remaining lines (`grep -n Sparkle ...`) and delete them by hand.

- [ ] **Step 4: Drop the Sparkle entry from Package.resolved.**

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  python3 - <<'PY'
import json
path = "tiptour-macos.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
data = json.load(open(path))
pins = data.get("pins") or data.get("object", {}).get("pins", [])
filtered = [p for p in pins if p.get("identity") != "sparkle"]
if "pins" in data:
    data["pins"] = filtered
else:
    data["object"]["pins"] = filtered
json.dump(data, open(path, "w"), indent=2)
PY
grep -c '"identity"' tiptour-macos.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved && \
  grep '"identity"' tiptour-macos.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
```
Expected: count is `1`, the remaining identity is `posthog-ios` (Task 4 removes it next).

- [ ] **Step 5: BUILD-CHECK.**

Expected: `** BUILD SUCCEEDED **`. If `xcodebuild` fails with "cannot resolve package Sparkle", the pbxproj still has a Sparkle reference — re-grep and delete it.

- [ ] **Step 6: Commit.**

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  git add tiptour-macos.xcodeproj/project.pbxproj \
          tiptour-macos.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved \
          TipTour/TipTourApp.swift && \
  git commit -m "rebrand: remove Sparkle auto-update integration"
```

---

## Task 4: Disconnect PostHog

**Files:**
- Modify: `tiptour-macos.xcodeproj/project.pbxproj` (4 sections — same shape as Sparkle, different identifiers)
- Modify: `tiptour-macos.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` (drop `posthog-ios`)
- Modify: `TipTour/TipTourApp.swift` (remove `TipTourAnalytics.configure()` / `TipTourAnalytics.trackAppOpened()`)

Note: `TipTourAnalytics.swift` itself stays in place until Task 5 — this task only stops calling it. That keeps each commit independently revertable.

- [ ] **Step 1: Strip the analytics calls from TipTourApp.swift.**

Open `TipTour/TipTourApp.swift` and delete lines 48-49:

```swift
TipTourAnalytics.configure()
TipTourAnalytics.trackAppOpened()
```

Replace them with a single comment line `// Analytics removed during rebrand; see Plan 2 if reinstating.` so the surrounding indentation is preserved. Then verify:

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  grep -n 'TipTourAnalytics\|PostHog\|import PostHog' TipTour/TipTourApp.swift
```
Expected: no output (any remaining `TipTourAnalytics` reference must be deleted in this step).

- [ ] **Step 2: Remove PostHog from project.pbxproj using the same brace-counted approach as Sparkle.**

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  python3 - <<'PY'
path = "tiptour-macos.xcodeproj/project.pbxproj"
lines = open(path).readlines()

def delete_block(start_marker, lines):
    out, i = [], 0
    while i < len(lines):
        ln = lines[i]
        if start_marker in ln and '= {' in ln:
            depth = ln.count('{') - ln.count('}')
            i += 1
            while i < len(lines) and depth > 0:
                depth += lines[i].count('{') - lines[i].count('}')
                i += 1
            continue
        out.append(ln)
        i += 1
    return out

for needle in [
    'AA00BB062F6500060039DA55 /* PostHog in Frameworks */',
    'AA00BB052F6500050039DA55 /* PostHog */,',
    'AA00BB042F6500040039DA55 /* XCRemoteSwiftPackageReference "posthog-ios" */,',
]:
    lines = [ln for ln in lines if needle not in ln]

lines = delete_block('AA00BB042F6500040039DA55 /* XCRemoteSwiftPackageReference "posthog-ios" */', lines)
lines = delete_block('AA00BB052F6500050039DA55 /* PostHog */', lines)

open(path, 'w').writelines(lines)
PY
grep -c 'PostHog\|posthog' tiptour-macos.xcodeproj/project.pbxproj
```
Expected: `0`.

- [ ] **Step 3: Drop posthog-ios from Package.resolved.**

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  python3 - <<'PY'
import json
path = "tiptour-macos.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
data = json.load(open(path))
pins = data.get("pins") or data.get("object", {}).get("pins", [])
filtered = [p for p in pins if p.get("identity") != "posthog-ios"]
if "pins" in data:
    data["pins"] = filtered
else:
    data["object"]["pins"] = filtered
json.dump(data, open(path, "w"), indent=2)
PY
cat tiptour-macos.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
```
Expected: `pins` array is now empty (`[]`).

- [ ] **Step 4: BUILD-CHECK.**

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit.**

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  git add tiptour-macos.xcodeproj/project.pbxproj \
          tiptour-macos.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved \
          TipTour/TipTourApp.swift && \
  git commit -m "rebrand: remove PostHog analytics SDK"
```

---

## Task 5: Strip `TipTourAnalytics.swift` (Section 2.5)

**Files:**
- Delete: `TipTour/TipTourAnalytics.swift`

The file has no remaining callers after Task 4. This step removes the file itself.

- [ ] **Step 1: Confirm no stragglers reference the file.**

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  grep -rn 'TipTourAnalytics' TipTour TipTourTests TipTourUITests 2>/dev/null
```
Expected: only matches inside `TipTour/TipTourAnalytics.swift` itself (the file's own `class TipTourAnalytics` declaration and method definitions). If any other file matches, replace its call site with a no-op or delete the calling line.

- [ ] **Step 2: Delete the file.**

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  git rm TipTour/TipTourAnalytics.swift
```

- [ ] **Step 3: BUILD-CHECK + TEST-CHECK.**

Both should succeed. If a test file references `TipTourAnalytics` (unlikely, but check), it'll be in the list of test files we delete in Task 11 — for now, comment out the offending line(s) and add a note to Task 11 to verify.

- [ ] **Step 4: Commit.**

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  git commit -m "rebrand: delete TipTourAnalytics.swift (no remaining callers)"
```

---

## Task 6: Deep excision — strip swarm/workflow/skill refs from KEPT files

**Files (all are modify-only, kept after this task):**
- Modify: `TipTour/CompanionManager.swift`
- Modify: `TipTour/CompanionPanelView.swift`
- Modify: `TipTour/Agents/UI/SettingsView.swift`
- Possibly modify: `TipTour/Agents/UI/*.swift` siblings (whatever references the stripped modules)
- Possibly modify: other top-level Swift files surfaced by grep

This is the most invasive task. Its purpose is to make `Agents/Swarm/`, `Agents/Memory/`, `Agents/Providers/`, `Agents/Tools/`, `Agents/Overlay/`, `Agents/Skills/`, `Agents/Core/`, `WorkflowRunner.swift`, and `WorkflowPlan.swift` **entirely unreferenced** by the kept code, so subsequent tasks can `git rm` those files without breaking the build.

The strategy: replace each reference with either a deletion (when the surrounding code only exists to feed the swarm) or a `// TODO(plan-2): route through HermesClient` comment that compiles (when the surrounding code is a kept UI affordance whose backend is being deferred to Plan 2).

- [ ] **Step 1: Survey every kept file for the symbols we'll be deleting.**

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  KEPT_FILES=$(find TipTour -maxdepth 1 -name '*.swift'; find TipTour/Agents/UI -name '*.swift' 2>/dev/null) && \
  for f in $KEPT_FILES; do
    hits=$(grep -cE 'AgentSwarm|TaskAgent\b|AgentMessage|SkillEntry|SkillExtractor|SkillImporter|SkillLibraryStore|SkillNameValidator|SkillSpecValidator|SkillStoreMigrator|BundledSkillSeeder|DemonstrationRecorder|EfficiencyMonitor|WorkflowRunner|WorkflowPlan|WorkflowStep|AgentTool\b|GenerationTools|SkillTools|AgentMemoryStore|AgentMemoryEntry' "$f")
    [ "$hits" -gt 0 ] && printf "%4d %s\n" "$hits" "$f"
  done | sort -rn
```
Expected: a short list. Plan 1 verification showed CompanionManager (≈25 hits), CompanionPanelView (≈8), SettingsView (≈10). If a file we didn't anticipate shows up, add it to the excision list in step 2.

- [ ] **Step 2: Excise CompanionManager.swift.**

Open `TipTour/CompanionManager.swift`. For each of these member-level concerns, take the action listed:

| Symbol / region | Action | Why |
|---|---|---|
| Imports of `Agents.Swarm` / `Agents.Skills` / `WorkflowRunner` (if any) | Delete the import line | Modules go away in later tasks |
| `var isDemonstratingSkill`, `var isExtractingSkill`, `var skillExtractorOverrideForTests`, `var effectiveSkillExtractor` (lines ~55-66) | Delete the declarations | UI-state for skill recording; the entire flow goes away |
| `private let agentSwarmManager = AgentSwarmManager.shared` (line ~95) | Delete | Swarm is going away |
| `backend.onSubmitWorkflowPlan = { ... }` closure assignment (line ~133-135) | Replace closure body with `_ = (id, goal, app, steps); return ["ok": false]` and add `// TODO(plan-2): route workflow submission through HermesClient` above the assignment | Keep the GeminiLive backend's tool wiring intact but no-op the dispatcher |
| `if let activePlan = WorkflowRunner.shared.activePlan { ... }` (lines ~281-283, ~368-379) | Delete the entire `if` block; replace with `// TODO(plan-2): re-implement workflow short-circuit via HermesClient session state` | No WorkflowRunner to consult |
| `private func handleToolSubmitWorkflowPlan(...) async -> [String: Any]` (lines ~361-425) | Delete the entire method | Sole purpose was bridging Gemini tool calls into the swarm |
| `print("[Workflow] entering Gemini narration mode ...")` and surrounding workflow-narration logic (lines ~430-500) | Delete | Workflow-specific narration path |
| `private func handleAgentSwarmMessage(_ message: AgentMessage) async` (line ~698) and the registration `await self?.handleAgentSwarmMessage(message)` (line ~665) | Delete both | No more swarm messages |
| `func spawnBackgroundAgent(...) async -> TaskAgent?` (line ~785) | Delete the entire method (and any callers — verify with grep after) | No TaskAgent type exists post-strip |
| `await BundledSkillSeeder.seedBundledSkillsIfNeeded()` (line ~680) | Delete the line | No skills to seed |
| `WorkflowRunner.shared.isAutopilotEnabledProvider = { ... }` (line ~657) | Delete the assignment | No WorkflowRunner |
| Any `TipTourAnalytics.*` call (e.g. line 588 `TipTourAnalytics.trackOnboardingStarted()`) | Delete the line | Analytics already stripped |

After editing, verify no listed symbol remains:

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  grep -nE 'AgentSwarm|TaskAgent\b|AgentMessage|SkillExtractor|SkillEntry|BundledSkillSeeder|DemonstrationRecorder|WorkflowRunner|WorkflowPlan|WorkflowStep|TipTourAnalytics' TipTour/CompanionManager.swift
```
Expected: no output. If any remain, edit them out before moving on.

- [ ] **Step 3: BUILD-CHECK.**

Expected: `** BUILD SUCCEEDED **`. If the build fails because excising left the file in a structurally-broken state (e.g. dangling closing brace from a deleted method), fix the structure. Do NOT add stub helper functions — the goal is reduction, not re-implementation.

- [ ] **Step 4: Excise CompanionPanelView.swift.**

Open `TipTour/CompanionPanelView.swift`. For each of these regions, take the action listed:

| Symbol / region | Action |
|---|---|
| `@ObservedObject private var workflowRunner: WorkflowRunner = .shared` (line ~15) | Delete the property |
| `SaveSkillSheetView(skillName: $pendingSkillName, ...)` block (around line ~75-85) | Delete the entire sheet declaration |
| `@State private var pendingSkillName: String = ""` (line ~854) | Delete |
| `private func planChecklistSection(plan: WorkflowPlan) -> some View` (line ~552) and its body | Delete the entire method (and its call sites — search for `planChecklistSection`) |
| `private func planChecklistRow(...)` (line ~656) | Delete |
| `if companionManager.isDemonstratingSkill { ... }` (line ~956) | Delete the entire `if` and its content (no more `isDemonstratingSkill` after Step 2) |
| `private struct SaveSkillSheetView: View` (line ~1169) and entire body | Delete |

Verify:
```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  grep -nE 'Workflow|Skill|isDemonstratingSkill' TipTour/CompanionPanelView.swift
```
Expected: no output.

- [ ] **Step 5: BUILD-CHECK.**

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Excise SettingsView.swift.**

Open `TipTour/Agents/UI/SettingsView.swift`. The grep in step 1 will show specific line numbers; broadly:

| Region | Action |
|---|---|
| `case skills = "Skills"` in the tabs enum (line ~13) | Delete the case |
| `SkillsSettingsView()` in the tab switch (line ~49) | Delete the case-branch line |
| `struct SkillsSettingsView: View` and its entire body (lines ~187-275+) | Delete the struct |
| Any references to `EfficiencyMonitor`, `SkillLibraryStore`, etc. inside SettingsView | Delete |

If `SettingsView.swift` has other tabs that reference stripped modules (Memory, Demonstration, etc.), delete those tabs and their corresponding view-struct declarations using the same pattern.

Verify:
```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  grep -nE 'AgentSwarm|TaskAgent\b|SkillEntry|SkillLibraryStore|EfficiencyMonitor|DemonstrationRecorder|WorkflowRunner|WorkflowPlan' TipTour/Agents/UI/SettingsView.swift
```
Expected: no output.

- [ ] **Step 7: Sweep any remaining hits from the survey.**

Re-run the survey from Step 1. If any file still has hits, repeat the excise pattern: open it, delete declarations and call sites of stripped symbols, leave `// TODO(plan-2): ...` comments where a kept UI affordance loses its backend.

Continue until the survey reports zero files with hits across `KEPT_FILES`.

- [ ] **Step 8: BUILD-CHECK and TEST-CHECK and SMOKE-CHECK.**

All three must pass before committing. This is the largest single change in the plan — if anything is going to regress, it'll be here.

- [ ] **Step 9: Commit.**

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  git add -u TipTour && \
  git commit -m "rebrand: excise swarm/workflow/skill refs from kept files

CompanionManager, CompanionPanelView, SettingsView no longer reference
AgentSwarmManager / TaskAgent / Workflow* / Skill* / EfficiencyMonitor /
TipTourAnalytics. Those modules become unreferenced and are deleted in
subsequent tasks. UI affordances whose backend now belongs to Plan 2's
HermesClient are marked with TODO(plan-2) comments."
```

---

## Task 7: Strip `TipTour/Agents/Skills/` and the bundled-skills resource

**Files:**
- Delete: `TipTour/Agents/Skills/` (entire subtree — Swift files + `BundledSkills/` tree)
- Modify: `tiptour-macos.xcodeproj/project.pbxproj` (drop `BundledSkills` resource reference and its `membershipExceptions` list)

- [ ] **Step 1: Delete the Skills source tree.**

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  git rm -r TipTour/Agents/Skills && \
  ls TipTour/Agents/ 2>&1
```
Expected: `Skills` no longer listed.

- [ ] **Step 2: Drop the BundledSkills file reference and the membership exceptions list from pbxproj.**

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  python3 - <<'PY'
import re
path = "tiptour-macos.xcodeproj/project.pbxproj"
lines = open(path).readlines()

def delete_block(start_marker, lines):
    out, i = [], 0
    while i < len(lines):
        ln = lines[i]
        if start_marker in ln and '= {' in ln:
            depth = ln.count('{') - ln.count('}')
            i += 1
            while i < len(lines) and depth > 0:
                depth += lines[i].count('{') - lines[i].count('}')
                i += 1
            continue
        out.append(ln)
        i += 1
    return out

# 1. Drop single-line entries
for needle in [
    'B626385B2FB2581000BDE96A /* BundledSkills in Resources */',
    'B626385C2FB2581000BDE96A /* BundledSkills */ =',
    'B626385A2FB2581000BDE96A /* Exceptions for "TipTour" folder',
]:
    # Note: the "Exceptions" needle would also match the block definition line; we only
    # want to drop the *reference* (one-liner ending in `,`) here, not the definition.
    # Filter to lines ending in `,` (whitespace allowed) for the Exceptions case.
    if 'Exceptions' in needle:
        lines = [ln for ln in lines if not (needle in ln and ln.rstrip().endswith(','))]
    else:
        lines = [ln for ln in lines if needle not in ln]

# 2. Drop the multi-line PBXFileSystemSynchronizedBuildFileExceptionSet definition block
lines = delete_block(
    'B626385A2FB2581000BDE96A /* Exceptions for "TipTour" folder in "tiptour-macos" target */',
    lines,
)

# 3. Collapse the now-empty section markers if both ends are adjacent
text = ''.join(lines)
text = re.sub(
    r'/\* Begin PBXFileSystemSynchronizedBuildFileExceptionSet section \*/\s*\n\s*/\* End PBXFileSystemSynchronizedBuildFileExceptionSet section \*/\s*\n',
    '',
    text,
)
open(path, 'w').write(text)
PY
grep -c 'BundledSkills' tiptour-macos.xcodeproj/project.pbxproj
```
Expected: `0`.

- [ ] **Step 3: BUILD-CHECK and TEST-CHECK.**

Both succeed.

- [ ] **Step 4: Commit.**

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  git add -A && \
  git commit -m "rebrand: strip TipTour/Agents/Skills/ + BundledSkills resource

Includes DemonstrationRecorder (lived under Skills/) and the bundled
skill markdown library (~3k files). pbxproj loses the BundledSkills
resource reference and the PBXFileSystemSynchronizedBuildFileExceptionSet
that listed each SKILL.md membership exception."
```

---

## Task 8: Strip `TipTour/Agents/Tools/`

**Files:**
- Delete: `TipTour/Agents/Tools/` (entire directory: `AgentTool.swift`, `GenerationTools.swift`, `SkillTools.swift`)

After Task 6, nothing kept references these. After Task 7, the `SkillTools` references inside `Tools/` are themselves dangling references to deleted Skill types.

- [ ] **Step 1: Delete the Tools directory.**

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  git rm -r TipTour/Agents/Tools
```

- [ ] **Step 2: BUILD-CHECK.**

If the build fails with `cannot find 'AgentTool' in scope`, something in a kept file still references it — re-do Task 6 Step 7's sweep for `AgentTool` specifically.

- [ ] **Step 3: Commit.**

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  git commit -m "rebrand: strip TipTour/Agents/Tools/ (AgentTool, GenerationTools, SkillTools)"
```

---

## Task 9: Strip `TipTour/Agents/Memory/`, `Providers/`, `Core/`

**Files:**
- Delete: `TipTour/Agents/Memory/`
- Delete: `TipTour/Agents/Providers/`
- Delete: `TipTour/Agents/Core/`

- [ ] **Step 1: Delete the three directories.**

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  git rm -r TipTour/Agents/Memory TipTour/Agents/Providers TipTour/Agents/Core && \
  ls TipTour/Agents/ 2>&1
```
Expected: only `Overlay/`, `Swarm/`, `UI/` remain. (`Skills/` and `Tools/` already gone from Tasks 7 and 8.)

- [ ] **Step 2: BUILD-CHECK.**

Expected: pass.

- [ ] **Step 3: Commit.**

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  git commit -m "rebrand: strip TipTour/Agents/{Memory,Providers,Core}/"
```

---

## Task 10: Strip `TipTour/Agents/Swarm/` and `TipTour/Agents/Overlay/`

**Files:**
- Delete: `TipTour/Agents/Swarm/` (entire directory: `AgentSwarmManager.swift`, `AgentTypes.swift`, `TaskAgent.swift`)
- Delete: `TipTour/Agents/Overlay/` (entire directory: `AgentOverlayStackView.swift`, `AgentOverlayWindowController.swift`, `AgentPanelView.swift`, `AgentStateDisplay.swift`)

- [ ] **Step 1: Delete both directories.**

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  git rm -r TipTour/Agents/Swarm TipTour/Agents/Overlay && \
  ls TipTour/Agents/ 2>&1
```
Expected: only `UI/` remains under `TipTour/Agents/`.

- [ ] **Step 2: BUILD-CHECK.**

Expected: pass. If anything fails, the culprit is almost certainly a `import` of `Agents.Swarm` we missed in Task 6 — locate via `grep -rn 'AgentSwarm\|TaskAgent\b\|AgentMessage' TipTour TipTourTests` and excise.

- [ ] **Step 3: Commit.**

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  git commit -m "rebrand: strip TipTour/Agents/{Swarm,Overlay}/ (the brain + its in-app panels)"
```

---

## Task 11: Strip workflow engine (`WorkflowRunner.swift`, `WorkflowPlan.swift`)

**Files:**
- Delete: `TipTour/WorkflowRunner.swift`
- Delete: `TipTour/WorkflowPlan.swift`

- [ ] **Step 1: Delete both files.**

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  git rm TipTour/WorkflowRunner.swift TipTour/WorkflowPlan.swift
```

- [ ] **Step 2: BUILD-CHECK + TEST-CHECK.**

Both must pass.

- [ ] **Step 3: Commit.**

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  git commit -m "rebrand: strip WorkflowRunner + WorkflowPlan"
```

---

## Task 12: Remove tests for stripped features

**Files (all deletes):**
- `TipTourTests/AgentMemoryTests.swift`
- `TipTourTests/AgentOverlayTests.swift`
- `TipTourTests/AgentSwarmTests.swift`
- `TipTourTests/AgentToolTests.swift`
- `TipTourTests/DemonstrationTests.swift`
- `TipTourTests/EfficiencyMonitorTests.swift`
- `TipTourTests/GenerationToolTests.swift`
- `TipTourTests/IntegrationPolishTests.swift`
- `TipTourTests/leanring_buddyTests.swift`
- `TipTourTests/SkillEntrySpecFieldsTests.swift`
- `TipTourTests/SkillFrontmatterParserBlockScalarTests.swift`
- `TipTourTests/SkillImporterTests.swift`
- `TipTourTests/SkillLibraryStoreFolderTests.swift`
- `TipTourTests/SkillLibraryStoreInstallTests.swift`
- `TipTourTests/SkillLibraryTests.swift`
- `TipTourTests/SkillNameValidatorTests.swift`
- `TipTourTests/SkillResourceToolsTests.swift`
- `TipTourTests/SkillSpecValidatorTests.swift`
- `TipTourTests/SkillStoreMigratorTests.swift`

This task also implicitly reverts the Plan-1 `EfficiencyMonitor.swift` test-unblock patch (the `selfCritiqueThreshold:` parameter), but since `EfficiencyMonitor.swift` itself is already gone (deleted in Task 9), nothing remains to revert — the parameter died with the file.

`TipTourTests/HermesBundleTests.swift` and `TipTourTests/Fixtures/` are NOT in the delete list.

- [ ] **Step 1: Delete all the test files in one command.**

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  git rm \
    TipTourTests/AgentMemoryTests.swift \
    TipTourTests/AgentOverlayTests.swift \
    TipTourTests/AgentSwarmTests.swift \
    TipTourTests/AgentToolTests.swift \
    TipTourTests/DemonstrationTests.swift \
    TipTourTests/EfficiencyMonitorTests.swift \
    TipTourTests/GenerationToolTests.swift \
    TipTourTests/IntegrationPolishTests.swift \
    TipTourTests/leanring_buddyTests.swift \
    TipTourTests/Skill*Tests.swift && \
  ls TipTourTests/*.swift
```
Expected: only `HermesBundleTests.swift` remains in the list (`Fixtures/` is a directory, not a `.swift` file).

- [ ] **Step 2: TEST-CHECK.**

`HermesBundleTests` must still pass. The test target should now compile far faster (single small file).

- [ ] **Step 3: Commit.**

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  git commit -m "rebrand: delete tests for stripped features

Leaves HermesBundleTests as the sole test in the target. The Plan-1
unblock patches to EfficiencyMonitor/AgentTool/etc. are naturally
undone as the files they touched disappear."
```

---

## Task 13: Top-level cleanup (`worker/`, `appcast.xml`, `frames`, `dmg-background`, `scripts/`)

**Files (all deletes):**
- `worker/` (entire directory)
- `appcast.xml`
- `dmg-background.png`
- `frame 1.svg`, `frame 2.svg`, `frame 3.svg`, `frame 4.svg`, `frame 5.svg`
- `scripts/` (entire directory)

- [ ] **Step 1: Sanity check — confirm no kept Swift file references these.**

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  grep -rln 'appcast.xml\|dmg-background\|frame [12345]\.svg\|scripts/release\|scripts/validate' TipTour TipTourTests TipTourUITests BuildScripts Tests 2>/dev/null
```
Expected: no output. If anything matches, investigate before deleting that file.

- [ ] **Step 2: Delete everything in one batch.**

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  git rm -r worker scripts && \
  git rm appcast.xml dmg-background.png 'frame 1.svg' 'frame 2.svg' 'frame 3.svg' 'frame 4.svg' 'frame 5.svg' && \
  ls
```
Expected listing: only the kept directories + files (`TipTour`, `TipTourTests`, `TipTourUITests`, `tiptour-macos.xcodeproj`, `BuildScripts`, `Tests`, `docs`, `AGENTS.md`, `CLAUDE.md`, `LICENSE`, `README.md`, `ironman-repulsors.mp3`, `jarvislistening.wav`, `jarvisworking.wav`, `.gitignore`).

- [ ] **Step 3: BUILD-CHECK + TEST-CHECK + SMOKE-CHECK.**

All three must pass. This is the last meaningful change before final verification — if anything regresses now, it's specifically due to this cleanup batch.

- [ ] **Step 4: Commit.**

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  git commit -m "rebrand: drop worker/, appcast.xml, dmg-background.png, frame *.svg, scripts/

worker/ was TipTour's Cloudflare backend (not bundled into the .app).
appcast.xml + dmg-background.png + scripts/ were the TipTour release
pipeline. frame *.svg were design source files. None are referenced
by the kept code."
```

---

## Task 14: Final verification + acceptance

This task introduces no edits. It is the gate that says "the rebrand has actually landed cleanly."

- [ ] **Step 1: BUILD-CHECK.** Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 2: TEST-CHECK.** Expected: all three HermesBundleTests methods pass.

- [ ] **Step 3: SMOKE-CHECK.** Expected: `PASS (phase 1)`, exit 0.

- [ ] **Step 4: Locate the built .app and confirm display name + bundle contents.**

```bash
APP=$(find ~/Library/Developer/Xcode/DerivedData -name 'TipTour_Hermes.app' -path '*/Debug/*' 2>/dev/null | head -1) && \
  echo "App: $APP" && \
  test -n "$APP" && echo "✓ .app exists at new display name" || echo "✗ .app NOT FOUND at TipTour_Hermes.app — display-name rename did not propagate" && \
  test -x "$APP/Contents/Resources/hermes-runtime/hermes-runtime" && echo "✓ Hermes runtime still bundled" && \
  /usr/libexec/PlistBuddy -c 'Print CFBundleDisplayName' "$APP/Contents/Info.plist" 2>&1
```
Expected: app path ends in `TipTour_Hermes.app`, both `✓` lines print, `CFBundleDisplayName` prints `TipTour_Hermes`.

- [ ] **Step 5: Launch the .app and confirm Finder shows the new identity.**

```bash
open "$APP"
```
Visual check: menu bar item appears as `TipTour_Hermes`. Quit the app afterwards.

- [ ] **Step 6: Inventory remaining source files for a final sanity check.**

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  echo "=== TipTour/ top level ===" && ls TipTour/*.swift | wc -l && \
  echo "=== TipTour/Agents/ ===" && ls TipTour/Agents/ && \
  echo "=== TipTourTests/ ===" && ls TipTourTests/*.swift && \
  echo "=== top-level ===" && ls
```
Expected:
- `TipTour/*.swift` count is around 23 (Plan-1 snapshot had 27; we deleted 2 workflow files + TipTourAnalytics + … nothing else top-level. 23-24 is plausible.)
- `TipTour/Agents/` contains only `UI`.
- `TipTourTests/*.swift` is exactly `HermesBundleTests.swift`.
- Top-level contains no `worker/`, `appcast.xml`, `frame *.svg`, `dmg-background.png`, `scripts/`.

- [ ] **Step 7: No additional commit needed — Task 13's commit is the final state.**

---

## Rollback procedure

If a task fails partway and ad-hoc fixes don't recover, the safest recovery is:

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  git status --short && \
  # If untracked, stash or discard. If committed:
  git reset --hard pre-rebrand
```

This restores the Plan-1-complete state from Task 1's tag. The user is on local `main` with no remote, so the reset is safe and complete.

For partial rollback of a single task, find the offending commit with `git log --oneline` and `git revert <sha>` — each task's commit is structured to be independently revertable per the spec's Section 5 mitigation.

---

## Acceptance criteria

You're done with the rebrand when ALL of the following are true:

1. `xcodebuild -project tiptour-macos.xcodeproj -scheme tiptour-macos -configuration Debug build` exits 0 with `** BUILD SUCCEEDED **`.
2. `xcodebuild ... test -only-testing:tiptour-macosTests/HermesBundleTests` reports three `Test Case ... passed` lines and `** TEST SUCCEEDED **`.
3. `./Tests/Python/smoke_test_acp.py` exits 0 with `PASS (phase 1)`.
4. `find ~/Library/Developer/Xcode/DerivedData -name 'TipTour_Hermes.app' -path '*/Debug/*'` returns exactly one path, and that .app contains `Contents/Resources/hermes-runtime/hermes-runtime`.
5. The .app's `CFBundleDisplayName` reads `TipTour_Hermes`.
6. `TipTour/Agents/` contains only the `UI/` subdirectory; no `Swarm/`, `Skills/`, `Tools/`, `Overlay/`, `Memory/`, `Providers/`, or `Core/`.
7. `TipTourTests/` contains only `HermesBundleTests.swift` and the `Fixtures/` directory.
8. `git grep -E '(TipTourAnalytics|AgentSwarmManager|TaskAgent|WorkflowRunner|WorkflowPlan|SkillLibraryStore|DemonstrationRecorder|EfficiencyMonitor)'` finds zero matches across the entire repo.
9. The repo root has no `worker/`, `appcast.xml`, `dmg-background.png`, `frame [1-5].svg`, or `scripts/`.

Once green, the next plan is **Plan 2 — ACP bridge and dev textbox**, which adds `TipTour/Hermes/HermesClient.swift` and surfaces a debug menu item for chatting with the bundled runtime that Plan 1 already verified.
