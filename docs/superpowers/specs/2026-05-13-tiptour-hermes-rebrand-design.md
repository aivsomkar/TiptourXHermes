# TipTour → TipTour_Hermes Rebrand — Design

**Date:** 2026-05-13
**Status:** Approved (brainstorming session)
**Followed by:** Plan-level implementation plan (writing-plans skill, separate doc)
**Builds on:** [`2026-05-13-plan-1-bundling-and-acp-smoke-test.md`](../plans/2026-05-13-plan-1-bundling-and-acp-smoke-test.md) (already implemented and merged on `main`).

## Purpose

Plan 1 forked TipTour into this project directory and bundled Hermes Agent inside the `.app` so an ACP smoke test could prove the Python runtime is launchable. The macOS app itself is still 100% TipTour: TipTour's display name, TipTour's swarm/skills/demonstration features, TipTour's analytics and Sparkle update feed.

This rebrand reshapes the existing project so that — from the user's perspective and from the codebase's perspective — it is **TipTour_Hermes**, a new app whose **brain** is Hermes (over ACP) and whose **body** is TipTour's distinctive UI surface (menu-bar shell, push-to-talk shortcut, on-screen pointing overlay, voice in/out, screen capture, accessibility tree).

It stops *just before* wiring the body to the brain. Hooking Hermes up to the overlay/voice is Plan 2's job and gets its own design. The rebrand's purpose is to land a clean codebase that Plan 2 can build on without dragging TipTour's old agent runtime along for the ride.

## Non-Goals

This design intentionally does NOT cover:

- Writing the Swift ACP client (`HermesClient`).
- Building the Mac-side MCP server that exposes `take_screenshot` / `get_a11y_tree` / `point_at` / `speak`.
- Routing push-to-talk audio → Gemini Live STT → Hermes → AVSpeechSynthesizer TTS.
- The dev-only "talk to Hermes" textbox.
- Replacing the swarm-stub call sites left behind by Section 2 with real ACP calls.
- Re-publishing under a new Sparkle feed or wiring fresh analytics.

Each of those is its own subsequent plan.

## Architecture in one paragraph

The rebrand is a **subtractive** change. After it, the project tree contains: (a) Plan 1's Hermes bundling infra unchanged, (b) the menu-bar / overlay / voice / screen-capture / a11y body of TipTour, (c) the app shell renamed to `TipTour_Hermes` everywhere user-visible (display name, Info.plist permission strings, executable name). Everything else (swarm, skills, demonstration recorder, efficiency monitor, generation tools, Sparkle, PostHog, the Cloudflare worker, TipTour's release scripts and DMG branding) is deleted. Bundle ID, dev team, target name, scheme name, and directory paths inside the repo stay as-is — those are developer-facing internals, and changing them risks the pbxproj for no macOS-visible payoff.

## Decisions captured during brainstorming

| Question | Answer |
|---|---|
| Same dir or new repo? | Same directory, rebranded in place. Preserves Plan 1's 11 commits and the working scaffold. |
| Keep TipTour's features? | Strip the brain (swarm, skills, workflow engine, demonstration recorder, efficiency monitor); keep the body (push-to-talk, pointing overlay, voice, screen capture, a11y tree). Hermes (over ACP) becomes the new brain in subsequent plans. |
| Voice path? | Hybrid. Gemini Live for STT (low-latency streaming user→transcript). macOS `AVSpeechSynthesizer` for TTS (local, free, no Google dependency for output). |
| Screen awareness? | Mac-side MCP server exposed to Hermes via `session/new` MCP registration. Tools: `take_screenshot`, `get_a11y_tree`, `point_at`, `speak`. This rebrand prepares the body code; the MCP server itself is a later plan. |
| Display name? | `TipTour_Hermes` |
| Bundle ID? | `com.milindsoni.tiptour` — **unchanged**. Reuses existing TCC grants and keychain access group. |
| Dev team? | `6D7X9GGZAW` — **unchanged**. |
| Sparkle? | **Disable.** TipTour's appcast URL would silently revert to upstream binaries. |
| PostHog? | **Disable.** Events would land in TipTour's tenant. |
| `worker/` directory? | **Delete.** TipTour's Cloudflare backend; not used by the .app. |

## Section 1 — Identity changes

The only `.app`-visible strings that change:

| Setting | Before | After |
|---|---|---|
| `INFOPLIST_KEY_CFBundleDisplayName` (Debug & Release in pbxproj) | `TipTour` | `TipTour_Hermes` |
| `PRODUCT_NAME` (Debug & Release) | `TipTour` | `TipTour_Hermes` |
| Info.plist `NSMicrophoneUsageDescription` and ~12 sibling `NS*UsageDescription` keys | `"TipTour …"` | `"TipTour_Hermes …"` |

Unchanged (deliberately):

- `PRODUCT_BUNDLE_IDENTIFIER` — stays `com.milindsoni.tiptour` / `.tests` / `.uitests`. macOS will treat the rebranded app as the same identity, so existing TCC permissions (microphone, screen recording, AppleEvents) and keychain items carry over without re-prompting.
- `DEVELOPMENT_TEAM = 6D7X9GGZAW`.
- Target names (`tiptour-macos`, `tiptour-macosTests`, `tiptour-macosUITests`) and scheme name (`tiptour-macos.xcscheme`).
- Directory layout (`TipTour/`, `TipTourTests/`, `TipTourUITests/`, `tiptour-macos.xcodeproj/`). Renaming these would propagate hundreds of pbxproj path updates with no end-user benefit.

After build, the produced bundle's executable is `TipTour_Hermes.app/Contents/MacOS/TipTour_Hermes` and the display name shown by Finder / menu bar / About box is `TipTour_Hermes`.

## Section 2 — What gets stripped

Each bullet is one logical deletion batch and should land as one commit so it can be reverted independently if something turns out to be unexpectedly load-bearing.

### 2.1 Agent swarm (the brain we're replacing)

- `TipTour/Agents/Core/` — `TaskAgent.swift` lives in `TipTour/Agents/Swarm/TaskAgent.swift` (confirmed during Plan 1); the `Core/` subtree contains `EfficiencyMonitor.swift`, `ToolBox.swift`, the LLMProvider protocol and concrete implementations.
- `TipTour/Agents/Swarm/` — `AgentSwarmManager.swift`, `AgentMessage.swift`, `AgentTypes.swift`, `TaskAgent.swift`, related types.
- `TipTour/Agents/Overlay/` — the in-app swarm dashboard (e.g. `AgentPanelView.swift`'s per-agent rows). NOT to be confused with the on-screen pointing overlay (`CompanionResponseOverlay.swift` + `OverlayWindow.swift` + `NekoCursorView.swift`'s Arc Reactor cursor), which stays. `AgentPanelView.swift` references `ArcReactorColors`, but that enum is defined in `NekoCursorView.swift` (kept), so its deletion is non-load-bearing for the cursor visuals.
- `WorkflowRunner.swift`, `WorkflowPlan.swift`.

### 2.2 Skill library

- `TipTour/Agents/Skills/` (recursive) — including all of `BundledSkills/` (~3k files cluttering the pbxproj `membershipExceptions`).
- `SkillImporter.swift`, `SkillLibraryStore.swift`, `SkillResourceTools.swift`, `SkillSpecValidator.swift`, `SkillNameValidator.swift`, etc.
- Skill-related Settings UI tabs.

### 2.3 Demonstration recorder

- The `TipTour/Agents/Demonstration/` subtree.
- The record-key handler (distinct from push-to-talk; push-to-talk stays).

### 2.4 Generation tools / image generation

- The image-generation tool used by the swarm.
- `GenerationToolTests.swift` and its test fixture references.

### 2.5 Analytics

- `TipTourAnalytics.swift`.
- The `posthog-ios` SPM dependency in `tiptour-macos.xcodeproj/project.pbxproj` and `Package.resolved`.
- All call sites that fire PostHog events.

### 2.6 Tests for stripped features

These tests target deleted code and have no value in the rebranded app:

`AgentMemoryTests.swift`, `AgentOverlayTests.swift`, `AgentSwarmTests.swift`, `AgentToolTests.swift`, `DemonstrationTests.swift`, `EfficiencyMonitorTests.swift`, `GenerationToolTests.swift`, `IntegrationPolishTests.swift`, every `Skill*Tests.swift` file.

The Plan-1 "unblock" patches that touched some of these files are naturally undone as the files themselves disappear.

### 2.7 External services

- **Sparkle:** drop the `Sparkle` SPM package from the project, delete Sparkle init in `TipTourApp.swift`, delete `appcast.xml` from the repo root.
- **PostHog:** drop the `posthog-ios` package; delete analytics call sites and the PostHog framework reference.
- **Cloudflare worker:** delete the entire `worker/` directory.

### 2.8 Top-level cleanup

- `frame 1.svg` … `frame 5.svg` — TipTour design files. Delete after a sanity check that nothing in the kept codebase loads them as bundle resources.
- `dmg-background.png` — TipTour DMG branding, used by `scripts/release.sh` which is going away too.
- `scripts/release.sh` and `scripts/validate-bundled-skills.sh` — TipTour release pipeline. Delete the entire `scripts/` directory; recreate later when there are HermesForNoobs scripts to add.

## Section 3 — What stays (the body)

| Concern | Files kept |
|---|---|
| App shell | `TipTour/TipTourApp.swift` (rename only the Swift `struct` declaration from `TipTourApp` to `TipTour_HermesApp`; filename unchanged), `TipTour/DesignSystem.swift` |
| Menu bar | `TipTour/MenuBarPanelManager.swift` |
| Push-to-talk | `TipTour/PushToTalkShortcut.swift`, `TipTour/GlobalPushToTalkShortcutMonitor.swift` |
| Voice STT (Gemini Live, input side only) | `TipTour/GeminiLiveSession.swift`, `TipTour/GeminiLiveAudioPlayer.swift`, `TipTour/PCM16AudioConverter.swift`, `TipTour/RetryWithExponentialBackoff.swift` |
| Screen capture | `TipTour/ScreenRecorder.swift`, `TipTour/CompanionScreenCaptureUtility.swift`, `TipTour/ScreenshotPerceptualHash.swift` |
| Accessibility tree | `TipTour/AccessibilityTreeResolver.swift`, `TipTour/ActionExecutor.swift` |
| On-screen pointing overlay (+ Arc Reactor cursor) | `TipTour/CompanionResponseOverlay.swift`, `TipTour/NekoCursorView.swift` (defines `ArcReactorColors`, `ArcReactorInnerShape`, `ArcReactorCursorView`, `ArcReactorTrailView`), `TipTour/OverlayWindow.swift` (hosts the reactor cursor + flight trail) |
| Iron Man / Jarvis sound effects | Top-level `ironman-repulsors.mp3` (boot animation, played by `TipTourApp.swift:87-90`), `jarvislistening.wav` (voice-state: listening), `jarvisworking.wav` (voice-state: working). Loaded by `CompanionManager.swift:180-204` (`playVoiceStateSound(named:)`). All three stay at the repo root and remain bundled into `Resources/`. |
| Keychain | `TipTour/KeychainStore.swift` |
| Settings UI (trimmed) | A reduced `TipTour/Agents/UI/SettingsView.swift` — keep theme, push-to-talk shortcut, voice prefs; drop swarm, skills, efficiency monitor tabs |
| App bundle config | `TipTour/AppBundleConfiguration.swift`, `TipTour/TipTour.entitlements` (filename stays; contents unchanged unless an entitlement was swarm-specific) |
| Plan 1 work | `BuildScripts/`, `Tests/Python/`, `TipTourTests/HermesBundleTests.swift`, `docs/superpowers/` (all unchanged) |

### 3.1 The swing case: `CompanionManager.swift`

`CompanionManager.swift` (~19 references to "TipTour" — the most of any file) mixes:

- Companion UX state (overlay visibility, current narration state) — **keep**.
- Swarm orchestration glue (dispatching to `AgentSwarmManager`, listening for agent state changes) — **strip**.

Action: in the same commit that deletes `AgentSwarmManager`, **edit** `CompanionManager.swift` to remove swarm references rather than delete the file. Stub-out the call sites that used to dispatch to the swarm with `// TODO(plan-2): route through HermesClient` placeholders so the file still compiles.

## Section 4 — External-service disconnects

The pbxproj diff:

- Remove `Sparkle` from `XCSwiftPackageProductDependency` and `XCRemoteSwiftPackageReference` sections.
- Remove `PostHog` from the same sections.
- `Frameworks` build phase loses two `PBXBuildFile` entries.

The `Package.resolved` diff:

- Remove the `Sparkle` and `posthog-ios` package entries.

The Swift source diff:

- `TipTourApp.swift`: delete Sparkle's `SPUStandardUpdaterController` init block and PostHog's `PostHogConfig` / `PostHogSDK.shared.setup(...)` block.
- Any `TipTourAnalytics` import + call sites in keep-list files (none expected, but verify): replace with no-ops or delete.

## Section 5 — Risk and rollback

### Primary risk

A "body" file silently depends on a "brain" file. Example: `CompanionResponseOverlay` might import `AgentSwarmManager` to query current task state.

### Mitigation strategy

1. **Build after each section-2 batch.** Don't move to the next deletion until the prior one builds.
2. **Stub, don't delete, on the first pass through swing-case files.** Replace call sites with `// TODO(plan-2): ...` placeholders so the body compiles standalone. The placeholders become real ACP calls in Plan 2.
3. **One commit per section (2.1, 2.2, ..., 2.8).** Each commit is independently revertable via `git revert` if a later integration step reveals it removed something we needed.
4. **`HermesBundleTests` stays green throughout.** It does not depend on the swarm or skills, so a regression there means the rebrand has accidentally damaged the Hermes bundling infra. Run it after every section commit:

   ```sh
   xcodebuild -project tiptour-macos.xcodeproj -scheme tiptour-macos \
              test -only-testing:tiptour-macosTests/HermesBundleTests
   ```

5. **`./BuildScripts/bundle-hermes.sh build/hermes-runtime` stays idempotent.** Plan 1 cached state should be untouched; if a `BuildScripts/` file accidentally lands in a deletion batch, the bundler stops working immediately and the bundle test fails.

### Secondary risk: Plan-1 test-target patches

In Plan 1, six test files were patched to make `tiptour-macosTests` compile on Xcode 26.5 (`chore(tests): unblock tiptour-macosTests target on Xcode 26.5` — commit `1ba8a2e`). Five of those six files are slated for deletion in Section 2.6 (`GenerationToolTests`, `leanring_buddyTests`, `SkillResourceToolsTests`, `AgentToolTests`, `DemonstrationTests`). The sixth (`EfficiencyMonitor.swift` production change) needs to be **reverted** when its caller `EfficiencyMonitorTests` is deleted, because no other code uses the new `selfCritiqueThreshold:` parameter we added. The implementation plan should include "revert the EfficiencyMonitor selfCritiqueThreshold parameter" as an explicit step when `EfficiencyMonitor.swift` itself is deleted in Section 2.1.

### Rollback path

If the rebrand goes off the rails, `git reset --hard <commit-before-rebrand-starts>` restores the Plan-1-complete state. We're working on local `main` with no remote, so this is safe and instant. Each section commit is also independently revertable per Mitigation #3.

## Section 6 — What comes after this rebrand

Two follow-on plans are blocked behind this design:

**Plan 2 — ACP bridge and dev textbox.** Adds `TipTour/Hermes/HermesClient.swift` (Swift ACP client), a dev-only "Talk to Hermes" textbox surfaced via a debug menu item, and proves the chat round-trips through the same bundled runtime Plan 1 already validated. The TODO stubs that Section 3.1 leaves in `CompanionManager.swift` get filled in here.

**Plan 3 — Mac-side MCP server.** Adds an in-process MCP server inside the Swift app exposing `take_screenshot`, `get_a11y_tree`, `point_at(rect, label)`, `speak(text)` tools. Registers it in ACP `session/new` so Hermes can call those tools to drive the kept body. This is where the UX of "Hermes points at things and narrates" comes back to life — but powered by Hermes the reasoning agent, not TipTour's old swarm.

Both follow-on plans assume the rebrand has landed cleanly. Their text refers to `TipTour_Hermes` rather than `TipTour`.
