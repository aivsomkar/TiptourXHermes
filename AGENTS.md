# TipTour - Agent Instructions

<!-- This is the single source of truth for all AI coding agents. CLAUDE.md is a symlink to this file. -->
<!-- AGENTS.md spec: https://github.com/agentsmd/agents.md — supported by Claude Code, Cursor, Copilot, Gemini CLI, and others. -->

## Overview

macOS menu bar voice companion. Lives entirely in the macOS status bar (no dock icon, no main window). Clicking the menu bar icon opens a custom floating panel. Push-to-talk (Ctrl+Option) opens a Gemini Live realtime session — Gemini hears the user, sees the user's screen via streaming JPEG screenshots, replies in voice, and calls tools to fly a blue cursor at on-screen elements or run a multi-step walkthrough.

All API keys live on a Cloudflare Worker proxy — nothing sensitive ships in the app.

## Architecture

- **App Type**: Menu bar-only (`LSUIElement=true`), no dock icon or main window.
- **Framework**: SwiftUI (macOS native) with AppKit bridging for menu bar panel and cursor overlay.
- **Pattern**: MVVM with `@StateObject` / `@Published` state management.
- **Voice Mode**: Gemini Live only. Single-model realtime WebSocket — bidirectional voice (PCM16 16kHz in, PCM16 24kHz out), vision (JPEG screenshots), text transcription, AND tool calling all in one streaming connection. Three tools exposed: `point_at_element(label, box_2d?)` for single-click asks, `submit_workflow_plan(goal, app, steps)` for multi-step walkthroughs, and `spawn_background_task(task, task_type)` for autonomous background agents. Gemini produces workflow plans itself inside its tool call — no separate planner model. API key fetched from Worker's `/gemini-live-key` endpoint. `CompanionManager` constructs the session directly — no protocol indirection (the previous OpenAI Realtime backend + `VoiceBackend` protocol were removed in the simplification refactor).
- **Screen Capture**: ScreenCaptureKit (macOS 14.2+), multi-monitor support.
- **Voice Input**: `GeminiLiveSession` captures mic audio and streams it directly over the WebSocket. Hotkey is a listen-only CGEvent tap so modifier-only shortcuts (Ctrl+Option) work reliably in the background.
- **Element Pointing**: The LLM calls one of two tools. `ElementResolver` resolves the `label` argument to pixel positions via a two-tier lookup:
    1. **macOS Accessibility tree** — pixel-perfect, ~30ms. Works on Apple-native Mac apps, most Cocoa third-party apps, and Electron apps that respect `AXManualAccessibility` (set on every app focus — see below). Uses batched `AXUIElementCopyMultipleAttributeValues` reads for ~3-10× speedup over per-attribute reads on large trees (Xcode, Electron).
    2. **Raw LLM coordinates from `box_2d`** — Gemini's own spatial grounding. Trusted directly when the model emitted box_2d alongside the label, since both come from the same model decision and don't need cross-checking.
    The previous on-device YOLO+OCR fallback was removed — Gemini's box_2d covers the same role with strictly better accuracy (one model, one decision, no fuzzy text-match drift) and the YOLO weights carried AGPL-3 distribution constraints.
- **Accessibility Tree**: `AccessibilityTreeResolver.swift` walks the user's target app's AX tree via `ApplicationServices`, matches elements by title/description/value, returns exact pixel frames in global AppKit coordinates. Uses a snapshot of `NSWorkspace.frontmostApplication` taken at hotkey press time so the query targets the app the user was actually looking at, not TipTour's own menu bar. **Pre-warmed on hotkey press** via `CompanionManager.prefetchAccessibilityTreeForTargetApp` — the AX walk overlaps the user's first words and Gemini's session setup, so the first `point_at_element` resolves against warm data.
- **AX hardening for Electron**: On every app activation (`NSWorkspace.didActivateApplicationNotification`), `CompanionManager.enableManualAccessibilityIfNeeded` sets `AXManualAccessibility=true` on the activated app's AX element. Electron apps (Framer, VS Code, Slack, Discord, Cursor, Notion, Figma desktop) honor this attribute and populate their full webpage AX tree; non-Electron apps return `kAXErrorAttributeUnsupported` which we silently ignore. Without this, Electron apps return ~0 candidates from AX walks. A `0.4s` `AXUIElementSetMessagingTimeout` is also applied at app launch on the system-wide element + per-app on activation, capping any single AX query from hanging the resolver longer than 400ms.
- **Multi-step walkthroughs**: `WorkflowRunner` consumes plans emitted by Gemini's `submit_workflow_plan` tool, drives the cursor step-by-step, and uses `ClickDetector` (a global listen-only CGEventTap) to auto-advance when the user clicks the resolved target. Each plan is stamped with a fresh `operationToken` (UUID) so callbacks from a stale plan can't mutate the current one after a rapid restart. The runner pauses automatically when the user Cmd-Tabs to an unrelated app, when an `AXSheet`/`AXDialog` modal appears mid-workflow, or when the post-click AX-tree fingerprint stays unchanged through a 350ms settle window (a strong signal the click missed). The UI surfaces the pause reason and offers Resume / Skip / Stop.
- **Two operating modes — Teaching (default) vs Autopilot**: A toggle in the menu bar panel (`autopilotToggleRow` in `CompanionPanelView`) flips TipTour between "show me how" (teaching, default — TipTour points, the user clicks) and "do it for me" (autopilot — TipTour clicks/types/presses keys for the user). When Autopilot is ON, `WorkflowRunner` schedules an `ActionExecutor` click ~650ms after each cursor flight, and non-click step types (`.keyboardShortcut`, `.type`) become actionable end-to-end. Single-element `point_at_element` calls also auto-click in this mode. State persisted to `UserDefaults` under `isAutopilotEnabled`. The pause-on-app-switch + modal + post-click-validator safety net applies to autopilot the same way it does to user-driven flows — autopilot rides the rails, doesn't bypass them.
- **Action execution** (Autopilot only): `ActionExecutor.swift` posts CGEvents at the HID level (`.cghidEventTap`) for clicks, parses keyboard shortcuts (Cmd+S, Cmd+Shift+N, etc.) and posts virtual key codes, and types text via NSPasteboard staging + Cmd+V (layout-agnostic, fast for long strings, restores prior clipboard contents). Activates the target `NSRunningApplication` before posting so events route to the right window — `CGEventPostToPid` is broken for clicks (Apple Forum 724835), HID + activation is the reliable path. Every entry point (`click`, `pressKeyboardShortcut`, `typeText`) runs inside `GUIActionMutex.runExclusive` so two agents — or an agent and the voice-mode `WorkflowRunner` — can't interleave HID events and produce phantom clicks.
- **Background-agent execution channels**: Agents in the swarm route GUI actions through `AppChannelRegistry`, which ranks channels per app — `chromeAppleScript`/`safariAppleScript` for browsers, generic `appleScript` for scriptable Apple apps (Finder, Mail, Numbers, etc.), `axPress` (kAXPressAction — no cursor, parallel-friendly) for everything else, and `cursorClick` as the always-available fallback. `SmartClickTool` reads the registry and dispatches automatically; lower-level primitives (`click_element`, `ax_press_element`, `chrome_control`, `run_applescript`) remain available as escape hatches. Net effect: a Chrome agent can drive its tab via AppleScript while a Framer agent uses the cursor in parallel — they only serialise when both genuinely need the mouse.
- **Bundled skill library** (RuFlo + OpenWork): At app launch `BundledSkillSeeder` populates `SkillLibraryStore` with ~150 markdown skills sourced from [ruvnet/ruflo](https://github.com/ruvnet/ruflo) (`.agents/skills/`, 134 SKILL.md files covering SPARC methodology, agent-coder/tester/reviewer, GitHub workflows, security audit, performance analysis, hive-mind, agentdb patterns) and [different-ai/openwork](https://github.com/different-ai/openwork) (`.opencode/skills/`, `.opencode/agent/`, `.opencode/commands/`, 19 files covering OpenCode primitives, tauri-solidjs, browser-setup-devtools, triage/docs/css agents, release flow). Seeding is idempotent (slug-collision skip), so user customizations are preserved and the bundled set is automatically re-added on every launch. Agents see relevant bundled skills via `fetchSkillsBlock` in their system prompt and can fetch the full body via `recall_skill(slug)`. `SkillLibraryStore.maximumRetainedSkillCount` was bumped to 1000 to keep the bundled set safe from LRU eviction.
- **Per-agent workspace + interactive shell**: Every `TaskAgent` gets a private workspace directory under `~/Library/Application Support/TipTour/agent-workspaces/<agent-uuid>/` and a private `InteractiveShellSession` (one `/bin/zsh -is` subprocess per agent). The shell starts in the workspace, persists working directory / env vars / aliases across the agent's tool calls, and is shut down via `shutdown()` from `markTerminated` and `handleCancellation`. Workspace files survive agent termination so the user can inspect them later. Agents pick between the new `interactive_shell` (stateful, fast for chains) and the existing `run_shell_command` (one-shot, isolated) per call.
- **Walkthrough recording**: `ScreenRecorder.swift` saves the user's walkthrough as an `.mov` to `~/Library/Application Support/TipTour/recordings/`. ScreenCaptureKit + AVAssetWriter, H.264 primary with HEVC fallback, 16-aligned dimensions for codec compatibility, serial sample-buffer queue to preserve FIFO ordering through the writer.
- **Concurrency**: `@MainActor` isolation, async/await throughout.
- **Analytics**: PostHog via `TipTourAnalytics.swift`.
- **First-run setup**: A fresh install has no `~/.hermes/config.yaml`. `HermesSetupCoordinator.needsSetup` returns true; `HermesClient.send` short-circuits with an actionable system-error transcript entry asking the user to open Settings → Models. The Settings → Models tab is the canonical provider/key setup surface (see "Settings sheet" below). On first save the user picks a provider, pastes an API key, and `HermesConfigBootstrapper.writeMinimalConfig` emits a two-field `config.yaml` while `KeychainStore` persists the key under the provider's keychain entry. `HermesClient.launchSubprocessIfNeeded` reads the key back via the coordinator and injects it as the provider's env var (`ANTHROPIC_API_KEY` / `OPENAI_API_KEY` / `GEMINI_API_KEY`) into the subprocess environment.
- **Settings sheet**: Opened from the menu bar panel footer's gearshape button. `SettingsSheetView` hosts three tabs today (`ModelsTabView`, `MemoryTabView`, `SoulTabView`). The Models tab is the user-facing provider/key management surface — provider picker that rewrites `config.yaml`'s `model.provider` field, BYOK key rows for Anthropic/OpenAI/Google (the Google row writes to the merged `geminiAPIKey` Keychain entry), Test Connection probes against each provider's live `/v1/models` endpoint, and the bundled Hermes runtime version. The Memory and Soul tabs are plain TextEditors over `~/.hermes/memories/USER.md` and `~/.hermes/SOUL.md` respectively, backed by `HermesMemoryStore` and `HermesSoulStore` (atomic write-tmp-then-rename so Hermes never sees a partial file). New tabs (Skills, Guardrails, Gateways, Schedule) drop in as one-line additions to `SettingsSheetView`'s TabView body.
- **Orphan cleanup**: The bundle entrypoint shell wrapper launches `parent_watchdog.py` as a sibling Python process before exec-ing `acp_adapter`. The watchdog polls `os.getppid()` and SIGTERMs the adapter when the Mac-app parent is reaped (PPID becomes 1). Prevents long-running orphaned Python processes after Mac-app crashes.
- **Bundle version manifest**: `bundle-hermes.sh` writes `hermes-version.txt` (key=value pairs: `hermes_git_ref`, `hermes_version`, `python_version`, `python_build`, `bundled_at`) next to the entrypoint. `HermesRuntimeVersion.swift` reads it and renders a one-line summary in the Dev panel section — useful for support triage. `HERMES_GIT_REF` is pinned to a specific commit SHA so builds are reproducible.

### API Proxy (Cloudflare Worker)

The app never calls external APIs directly. All requests go through a Cloudflare Worker (`worker/src/index.ts`) that holds the real API keys as secrets.

| Route | Upstream | Purpose |
|-------|----------|---------|
| `GET /gemini-live-key` | — (returns secret) | Returns the Gemini API key so the app can open a direct WebSocket to Gemini Live. Cloudflare Workers can't proxy Gemini's WebSocket so we expose the key to trusted clients. |
| `POST /match-label` | `gemini-2.5-flash-lite` | Multilingual label matcher used by `ElementResolver`'s fallback when the LLM passes a label in one language and the AX tree has it in another. |

Worker secret: `GEMINI_API_KEY`.

### Key Architecture Decisions

**Menu Bar Panel Pattern**: The companion panel uses `NSStatusItem` for the menu bar icon and a custom borderless `NSPanel` for the floating control panel. This gives full control over appearance (dark, rounded corners, custom shadow) and avoids the standard macOS menu/popover chrome. The panel is non-activating so it doesn't steal focus. A global event monitor auto-dismisses it on outside clicks.

**Cursor Overlay**: A full-screen transparent `NSPanel` hosts the blue cursor companion. It's non-activating, joins all Spaces, and never steals focus. The cursor position, response text, waveform, and pointing animations all render in this overlay via SwiftUI through `NSHostingView`.

**Global Push-To-Talk Shortcut**: Background push-to-talk uses a listen-only `CGEvent` tap instead of an AppKit global monitor so modifier-based shortcuts like `Ctrl+Option` are detected more reliably while the app is running in the background.

**Toggle (not hold) push-to-talk**: Press Ctrl+Option once to open the Gemini Live session, press again to close it. The connection stays open between turns so the user can have a real conversation.

## Key Files

| File | Lines | Purpose |
|------|-------|---------|
| `TipTourApp.swift` | ~106 | Menu bar app entry point. Uses `@NSApplicationDelegateAdaptor` with `CompanionAppDelegate` which creates `MenuBarPanelManager` and starts `CompanionManager`. No main window — the app lives entirely in the status bar. |
| `CompanionManager.swift` | ~1000 | Central state machine. Owns the global hotkey, screen capture, Gemini Live session (constructed directly, no protocol indirection), tool handlers, permissions, AX hardening on focus changes, AX-tree prefetch on hotkey press, overlay management, and skill demonstration recording. Wires all three voice tool callbacks (`onPointAtElement`, `onSubmitWorkflowPlan`, `onSpawnBackgroundTask`). Prunes expired memory entries on launch. |
| `MenuBarPanelManager.swift` | ~315 | NSStatusItem + custom NSPanel lifecycle. Creates the menu bar icon, manages the floating companion panel (show/hide/position), installs click-outside-to-dismiss monitor. |
| `CompanionPanelView.swift` | ~1014 | SwiftUI panel content. Status header, permissions setup, optional workflow checklist, neko mode toggle, developer section, footer. Dark aesthetic via `DS` design system. |
| `OverlayWindow.swift` | ~1017 | Full-screen transparent overlay hosting the blue cursor, response text, waveform, and spinner. Cursor animation, element pointing with bezier arcs, multi-monitor coordinate mapping. |
| `CompanionResponseOverlay.swift` | ~217 | SwiftUI view for the response text bubble and waveform displayed next to the cursor in the overlay. |
| `CompanionScreenCaptureUtility.swift` | ~187 | Multi-monitor screenshot capture using ScreenCaptureKit. Returns labeled image data for each connected display. |
| `GlobalPushToTalkShortcutMonitor.swift` | ~155 | System-wide push-to-talk monitor. Owns the listen-only `CGEvent` tap and publishes press/release transitions via `shortcutTransitionPublisher`. Also fires `demonstrationShortcutPublisher` on Ctrl+Option+W to toggle demonstration recording. |
| `PushToTalkShortcut.swift` | ~40 | Encodes the single shortcut TipTour listens for (Ctrl+Option) and translates raw CGEvents into press/release transitions. |
| `AccessibilityTreeResolver.swift` | ~960 | Walks the frontmost app's macOS Accessibility tree, looks up elements by title/description/value, returns pixel-perfect frames. First-tier element-lookup path. Uses batched `AXUIElementCopyMultipleAttributeValues` for ~3-10× speedup on big trees. |
| `ElementResolver.swift` | ~330 | Unified single-entry resolver. Given a label (and optional `box_2d` hint), tries AX tree → Gemini's raw `box_2d` coordinates. Always produces a global AppKit point so the overlay can fly the cursor directly. |
| `ScreenRecorder.swift` | ~395 | Records the main display to `.mov` via ScreenCaptureKit + AVAssetWriter. H.264 primary with HEVC fallback; 16-aligned dimensions; serial sample-buffer queue for FIFO ordering. Output to `~/Library/Application Support/TipTour/recordings/`. Currently unwired — call sites can opt in. |
| `ActionExecutor.swift` | ~330 | Posts synthetic CGEvent input (clicks, keyboard shortcuts, paste-based text typing) at the HID level so Autopilot mode can drive the user's apps. Activates the target `NSRunningApplication` before posting; restores the user's clipboard after a typed-text paste. |
| `GeminiLiveClient.swift` | ~720 | WebSocket client for Google's Gemini Live API. Sends PCM16 audio, JPEG screenshots, and text; receives PCM16 audio chunks, transcripts, and tool calls. All messages are JSON over a single wss:// connection. Tool declarations extracted to static computed properties (`pointAtElementToolDeclaration`, `submitWorkflowPlanToolDeclaration`, `spawnBackgroundTaskToolDeclaration`) so unit tests can verify them. |
| `GeminiLiveAudioPlayer.swift` | ~227 | Streaming PCM16 24kHz audio playback via AVAudioEngine + AVAudioPlayerNode. Queues incoming audio chunks from the WebSocket for gapless playback. |
| `GeminiLiveSession.swift` | ~910 | Orchestrator that ties the WebSocket client + audio player + mic capture together. Owns the Gemini Live conversation lifecycle and exposes published state (input transcript, isModelSpeaking) for the UI. Routes `point_at_element`, `submit_workflow_plan`, and `spawn_background_task` tool calls to CompanionManager via `onPointAtElement`, `onSubmitWorkflowPlan`, and `onSpawnBackgroundTask` callbacks. Exposes `simulateToolCall(id:name:args:)` for unit testing. |
| `WorkflowPlan.swift` | ~185 | Schema for Gemini-emitted multi-step plans (goal, app, steps). |
| `WorkflowRunner.swift` | ~595 | Executes Gemini-produced workflow plans. Resolves each step, arms the click detector, advances when the user clicks the resolved target. Adds operation-token guards against stale callbacks, modal-dialog detection (`AXSheet`/`AXDialog`), pause-on-app-switch via `NSWorkspace.didActivateApplicationNotification`, and a post-click AX-fingerprint validator that pauses if the click didn't change UI state. |
| `ClickDetector.swift` | ~228 | Global listen-only CGEventTap that fires a callback when a left-mouse-down lands within a tolerance radius of an armed target. WorkflowRunner uses it to auto-advance the checklist. |
| `NekoCursorView.swift` | ~285 | Cursor visuals shared between Neko mode and the default (non-Neko) cursor. `ArcReactorCursorView` cross-fades two SVG layers — `NormalState` (passive) and `ActiveState` (fully lit with the inner glow blazing) — driven by `voiceState` + `currentAudioPowerLevel`: mic-driven breathing during `.listening`, held high during `.responding` (TTS doesn't publish power). It plays a one-shot ignition sweep (passive → active → passive) on first appearance, gated by `bootSweepComplete` so audio-driven updates can't fight it. `ArcReactorGlowCursorView` renders the four-triangle "glow cursor" and is used in two roles: (1) **Neko mode point-at flight** — detaches from the reactor at ~110pt and flies to UI elements while the reactor stays put at the user's mouse via `BlueCursorView.reactorAnchorPosition`; (2) **default cursor when Neko mode is off** — sized smaller (~48pt) and follows the mouse continuously, replacing the legacy blue triangle. `displaySize` is a parameter on the view so each call site picks its own size. All three SVGs (`NormalState`, `ActiveState`, `GlowCursor`) share a normalised `876 × 908` viewBox windowed at `(281, 36)` so the reactor circle and the inner triangles land at the same on-screen position regardless of which asset is showing — eliminating the size-mismatch shimmer during the passive↔active cross-fade. The legacy 5-frame `ReactorFrame1–5` assets are no longer referenced (kept in the asset catalog for now). |
| `ScreenshotPerceptualHash.swift` | ~96 | dHash implementation. Deduplicates similar screenshots before sending to Gemini. |
| `RetryWithExponentialBackoff.swift` | ~67 | Utility helper for retry logic. |
| `KeychainStore.swift` | ~130 | macOS Keychain wrapper for storing API keys: `geminiAPIKey`, `anthropicAPIKey`, `openAIAPIKey`, `lumaAPIKey`. |
| `TipTour/Agents/Core/LLMProvider.swift` | ~140 | `LLMProvider` protocol, `LLMMessage`, `LLMTool`, `LLMResponse`, `LLMTokenUsage`, `LLMCompletionResult` types. All providers implement this; `complete()` returns `LLMCompletionResult`. |
| `TipTour/Agents/Core/LLMProviderRegistry.swift` | ~145 | Registry of all LLM providers. Routes `TaskType` → preferred provider. Bootstraps from Keychain at launch. Persists `TaskProfile` changes to `UserDefaults` (key `"taskProfiles"`) so model routing and token budgets survive restarts. |
| `TipTour/Agents/Providers/AnthropicProvider.swift` | ~175 | Claude Haiku/Sonnet/Opus via Anthropic REST API. Returns `LLMCompletionResult` with parsed `LLMTokenUsage` from the `usage` field. |
| `TipTour/Agents/Providers/OpenAIProvider.swift` | ~150 | GPT-4o/mini via OpenAI REST API. Returns `LLMCompletionResult` with parsed `LLMTokenUsage` from the `usage` field. |
| `TipTour/Agents/Providers/GeminiRestProvider.swift` | ~160 | Gemini Flash/Pro via REST (background tasks only — not voice). Returns `LLMCompletionResult` with parsed `LLMTokenUsage` from `usageMetadata`. |
| `TipTour/Agents/Swarm/AgentTypes.swift` | ~135 | `AgentMessage`, `AgentStatus`, `AgentState`, `AgentID`, `AgentBlocker`, `TaskResult`, `AgentMetrics`. |
| `TipTour/Agents/Swarm/AgentSwarmManager.swift` | ~155 | Coordinator actor. Owns spawn/terminate lifecycle, Combine message bus, overlay state publisher. Enforces `maxConcurrentAgents` cap read from `UserDefaults` (key `"maxConcurrentAgents"`, default 5); `spawn()` returns `TaskAgent?` (nil when at capacity). |
| `TipTour/Agents/Swarm/TaskAgent.swift` | ~400 | Individual background agent. Runs agentic LLM loop, accumulates `tokensUsed`/`toolCallCount`/`backtrackCount`, fires `EfficiencyMonitor.shared.evaluate` on completion (via the swarm's `registerSideTask` so dismissing the agent cancels the post-mortem LLM call), injects memory and skills at startup, writes task result to memory, auto-saves skill on tool-using completions, and honors `Task.isCancelled` at every loop boundary + before each LLM call + between tool calls so `terminate` actually stops work. Hard 50-turn cap surfaced to the agent in the system prompt so it can wrap up early. |
| `TipTour/Agents/Tools/AgentTool.swift` | ~135 | `AgentTool` protocol, `ToolBox` factory struct, `ToolArgumentError`. `browserResearch` and `generalMac` task types include `SmartClickTool` first (consults `AppChannelRegistry` to auto-pick AppleScript / AXPress / cursor click), then the lower-level primitives. |
| `TipTour/Agents/Core/GUIActionMutex.swift` | ~80 | Process-wide FIFO actor mutex that serialises every CGEvent burst (`click`, `pressKeyboardShortcut`, `typeText`). macOS exposes one cursor and one keyboard focus, so simultaneous CGEvent posts from two agents (or an agent + voice-mode `WorkflowRunner`) would interleave at the HID layer. `ActionExecutor` wraps every entry point in `GUIActionMutex.runExclusive`. |
| `TipTour/Agents/Core/AppChannelRegistry.swift` | ~110 | Maps bundle-id → ranked list of `AppActionChannel` (chromeAppleScript, safariAppleScript, appleScript, axPress, cursorClick). `SmartClickTool` calls `preferredClickChannel(forBundleID:)` to pick the lowest-friction path per app — Chrome agents drive via AppleScript while a Framer agent uses the cursor, so they actually run in parallel. |
| `TipTour/Agents/Tools/GenerationTools.swift` | ~290 | `GenerateImageTool` (DALL-E 3 via OpenAI) and `GenerateVideoTool` (Luma Dream Machine). Both save output to `~/Library/Application Support/TipTour/generated/` and return the file path. |
| `TipTour/Agents/Tools/ShellTool.swift` | ~170 | `RunShellCommandTool` — /bin/zsh subprocess with 30s timeout. `ShellRunner` async bridge (reused by SpawnClaudeCodeTool). Uses `withTaskCancellationHandler` so cancelling the parent agent terminates the subprocess. |
| `TipTour/Agents/Tools/InteractiveShellTool.swift` | ~245 | `InteractiveShellSession` (actor) + `InteractiveShellTool` — one long-running `/bin/zsh -is` per agent. Working directory, exported env vars, and aliases persist across calls (unlike `run_shell_command` which spawns fresh shells). Uses sentinel-based output delimiting; commands time out at 60s. Started lazily on first call; `shutdown()` called from `markTerminated` / `handleCancellation`. Not a real PTY — full-screen TUIs (vim/top) won't render, but agent commands (build / git / curl / npm) work cleanly. |
| `TipTour/Agents/Skills/BundledSkills/` | (~150 .md) | Markdown skills bundled as app resources, sourced from **RuFlo** (`.agents/skills/`, 134 SKILL.md files: SPARC family, agent-coder/tester/reviewer, GitHub workflow agents, security-audit, performance-analysis, hive-mind, agentdb patterns, etc.) and **OpenWork** (`.opencode/skills/` + `.opencode/agent/` + `.opencode/commands/`, 19 files: opencode-primitives, openwork-core, tauri-solidjs, browser-setup-devtools, triage/docs/css agents, release/hello-stranger/browser-setup commands). |
| `TipTour/Agents/Skills/BundledSkillSeeder.swift` | ~280 | Enumerates bundled `.md` files at launch, parses each upstream skill's `name` + `description` frontmatter, infers TipTour `taskTypes` from the slug (coding / analysis / generalMac / writing) and keyword set from the title+description, then writes them into `SkillLibraryStore` via the new `writeBundledSkill` overload — idempotently. Slug-collision skip means user customizations to bundled skills are never clobbered. |
| `TipTour/Agents/Tools/FileTools.swift` | ~180 | `ReadFileTool`, `WriteFileTool`, `ListDirectoryTool`. |
| `TipTour/Agents/Tools/WebTools.swift` | ~190 | `WebFetchTool` (URLSession GET + HTML strip), `WebSearchTool` (DuckDuckGo Instant API). Used by the headless `browserResearch` fallback path when an agent doesn't need to visibly drive a browser. |
| `TipTour/Agents/Tools/MacControlTools.swift` | ~470 | All GUI primitives in one file: `ReadAXTreeTool` (AX tree dump), `ClickElementTool` (visible cursor click via `ActionExecutor.shared`), `AXPressElementTool` (semantic `kAXPressAction` — no cursor, parallel-friendly, falls back to cursor click when AXPress is unsupported), `TypeTextTool` (paste-based typing via `ActionExecutor.typeText`), `PressKeyboardShortcutTool` (Cmd+S / Return / etc. via `ActionExecutor.pressKeyboardShortcut`), `OpenURLTool` (NSWorkspace.shared.open with optional `browser_bundle_id`). |
| `TipTour/Agents/Tools/AppleScriptTools.swift` | ~870 | `AppleScriptRunner` (NSAppleScript on main thread + wall-clock timeout race), `AppleScriptTool` (generic script execution against any scriptable app), `ChromeControlTool` (typed Chrome adapter: `open_url`, `current_url`, `current_title`, `execute_javascript`, `list_tabs`, `close_active_tab`), `SafariControlTool` (mirror of Chrome adapter — same operations against Safari's AppleScript dictionary, including `do JavaScript`), `SystemEventsTool` (typed wrapper around `tell application "System Events"`: `keystroke`, `key_code` with modifier parsing, `click_menu_item` with nested-menu support, `frontmost_app`, `list_processes`). All four tools run on the Apple Events channel — fully parallel with agents using the cursor in other apps. |
| `TipTour/Info.plist` | (config) | TCC usage descriptions for every permission TipTour or its agents may need: `NSMicrophoneUsageDescription`, `NSScreenCaptureUsageDescription`, `NSAppleEventsUsageDescription`, `NSSystemAdministrationUsageDescription`, `NSCameraUsageDescription`, `NSDesktopFolderUsageDescription`, `NSDocumentsFolderUsageDescription`, `NSDownloadsFolderUsageDescription`, `NSRemovableVolumesUsageDescription`, `NSNetworkVolumesUsageDescription`, `NSContactsUsageDescription`, `NSCalendarsUsageDescription`, `NSCalendarsFullAccessUsageDescription`, `NSRemindersUsageDescription`, `NSRemindersFullAccessUsageDescription`, `NSPhotoLibraryUsageDescription`, `NSPhotoLibraryAddUsageDescription`, `NSAppleMusicUsageDescription`, `NSLocationWhenInUseUsageDescription`, `NSLocationUsageDescription`, `NSSpeechRecognitionUsageDescription`, `NSLocalNetworkUsageDescription`, `NSBluetoothAlwaysUsageDescription`. Without these keys, macOS denies the corresponding TCC requests silently and TipTour never appears in the relevant Privacy & Security pane. |
| `TipTour/Agents/Tools/SmartActionTools.swift` | ~190 | `SmartClickTool` — high-level click dispatcher that consults `AppChannelRegistry.preferredClickChannel` for the target app's bundle id and routes to AppleScript / AXPress / cursor click accordingly. Falls back to cursor click on AXPress failure. |
| `TipTour/Agents/Memory/AgentMemoryEntry.swift` | ~75 | `AgentMemoryEntry`, `MemoryEntryType`, keyword extractor. Codable/Sendable entry type with TTL and permanent-flag support. |
| `TipTour/Agents/Memory/AgentMemoryStore.swift` | ~115 | Actor singleton. Persists entries to `~/Library/Application Support/TipTour/agent-memory.json`. Write/query/prune/clear with task-type + keyword scoring. |
| `TipTour/Agents/Tools/MemoryTools.swift` | ~105 | `RememberFactTool` (remember_fact) and `RecallFactsTool` (recall_facts). Available in all task types via ToolBox. |
| `TipTour/Agents/Skills/SkillEntry.swift` | ~130 | `RecordedToolCall`, `ToolCallHistoryBuffer`, `SkillEntry` (frontmatter parser + writer), `SkillBodyBuilder`. |
| `TipTour/Agents/Skills/SkillLibraryStore.swift` | ~250 | Actor singleton. Persists skills as spec-compliant `<slug>/SKILL.md` folders at `~/Library/Application Support/TipTour/skills/` per the agentskills.io spec. Write paths validate slugs through `SkillNameValidator` (sanitizing legacy/upstream names that don't match the spec regex). `installSkillFolder(slug:source:overrideExisting:)` is the spec-aware entry point used by `SkillImporter`: copies a whole source folder verbatim so `references/`/`templates/`/`scripts/`/`assets/` ride along with `SKILL.md`. Delete removes the whole skill folder. `allEntries()` returns all skills sorted by `createdAt` descending for the Settings Skills tab. |
| `TipTour/Agents/Skills/SkillFrontmatterParser.swift` | ~360 | Shared parser used by `BundledSkillSeeder`, `SkillImporter`, and `SkillEntry.parse`. `split(_:)` splits `---` frontmatter from body and decodes the YAML subset agentskills.io files use — plain scalars, folded (`>`) and literal (`|`) block scalars, and an indented `metadata:` map for non-spec client fields. `sanitizeSlug(_:)` lowercases + hyphenates filenames. `inferTaskTypes(slug:name:description:)` and `inferKeywords(slug:name:description:)` derive a skill's task-type tags and retrieval keywords using marker arrays for the bundled RuFlo upstream slugs. Bumping the parser is a load-bearing change for the seeder, the importer, and the on-disk index — drift between them would silently mis-classify imported skills. |
| `TipTour/Agents/Skills/SkillNameValidator.swift` | ~50 | Per agentskills.io spec: `isValid(_:)` enforces the 1-64 char lowercase-alphanumeric-hyphen regex; `sanitize(_:)` is a lossy ASCII coercion used by `SkillLibraryStore.write` and `SkillStoreMigrator` for legacy / upstream names that don't match the spec. |
| `TipTour/Agents/Skills/SkillSpecValidator.swift` | ~60 | Enforces the agentskills.io max-length constraints (`description` ≤ 1024, `compatibility` ≤ 500). Truncates over-length values with a console warning rather than rejecting them so import flows don't silently drop skills. Called from every write path in `SkillLibraryStore` (`write`, `writeBundledSkill`, `installSkillFolder`). |
| `TipTour/Agents/Skills/SkillStoreMigrator.swift` | ~100 | One-shot upgrade step gated by a UserDefaults flag. Walks the skill-store directory for legacy flat `<slug>.md` files and moves each into a spec-compliant `<slug>/SKILL.md` folder, sanitizing invalid stems and deduping against existing folders. Called from `CompanionManager.init` before `BundledSkillSeeder.seedBundledSkillsIfNeeded()`. |
| `TipTour/Agents/Skills/SkillImporter.swift` | ~270 | Actor that installs skills from a GitHub URL at runtime. `parseGitHubURL(_:)` accepts `owner/repo`, `tree/<branch>`, and `tree/<branch>/<subpath>` forms (rejects blob/pull/commit/etc. with `unsupportedURLForm`). `downloadTarball(for:)` pulls `codeload.github.com/<owner>/<repo>/tar.gz/<branch>` via `URLSession` with URL components percent-encoded. `extractTarball(at:)` shells out to `/usr/bin/tar` via a `withCheckedThrowingContinuation` so the actor doesn't block. `importFromExtractedDirectory(_:subpath:store:)` walks for `SKILL.md` files (per agentskills.io spec) — each match's parent folder is treated as one skill and the whole folder is copied via `SkillLibraryStore.installSkillFolder` so `references/`/`templates/`/`scripts/`/`assets/` ride along. Folders without a `SKILL.md` are invisible to the report. `importFrom(url:store:)` is the public entry point; throws `noSkillsFound` when nothing imported AND nothing skipped. Surfaced in Settings → Skills → "Import…" button. |
| `TipTour/Agents/Tools/SkillTools.swift` | ~180 | `SaveSkillTool` (save_skill), `RecallSkillTool` (recall_skill — now prepends an "Available resources" header listing references/templates/scripts/assets that ship with the recalled skill), and `ReadSkillResourceTool` (read_skill_resource — fetches a single file inside a skill's folder by relative path; rejects path traversal). All three are available in every task type via ToolBox. Together they implement agentskills.io progressive disclosure: metadata at startup → SKILL.md body on recall → individual resources on demand. |
| `TipTour/Agents/Skills/DemonstrationTypes.swift` | ~45 | `ObservedActionType`, `ObservedAction`, `ActionTrajectory` — data model for user demonstration recordings. |
| `TipTour/Agents/Skills/DemonstrationRecorder.swift` | ~290 | `final class @unchecked Sendable` that captures user actions via CGEventTap + NSWorkspace notifications. Accumulates keystrokes into `.type` actions; captures JPEG screenshots on click. `formatForLLM` converts a trajectory to compact text + ordered screenshot array. |
| `TipTour/Agents/Skills/SkillExtractor.swift` | ~70 | Actor singleton. Calls `DemonstrationRecorder.formatForLLM`, attaches screenshots via `LLMMessage.imagesJPEG`, calls `claude-sonnet-4-6` via `LLMProviderRegistry`, returns the skill-body markdown string. |
| `TipTour/Agents/Core/EfficiencyTypes.swift` | ~45 | `TaskOutcome`, `TaskExecution`, `EfficiencyReport` — data model for efficiency evaluation of completed agent runs. |
| `TipTour/Agents/Core/EfficiencyMonitor.swift` | ~130 | Actor singleton. Computes weighted inefficiency score (token overrun, wasted steps, backtracks). Self-critique threshold read from `UserDefaults` (key `"selfCritiqueThreshold"`, default 0.4) on each evaluation so Settings changes take effect immediately. |
| `TipTour/Agents/Tools/SpawnClaudeCodeTool.swift` | ~95 | `SpawnClaudeCodeTool` — spawns `claude --print` subprocess with 120s timeout. |
| `TipTour/Agents/Overlay/AgentStateDisplay.swift` | ~65 | Pure map: `AgentState` → `AgentDotVariant`, dot color, pulsing bool, SF symbol. Fully tested. |
| `TipTour/Agents/Overlay/AgentPanelView.swift` | ~270 | SwiftUI view for one agent: collapsed row (dot + name + [−][×]) + expanded detail (steps, metrics, chat). |
| `TipTour/Agents/Overlay/AgentOverlayStackView.swift` | ~250 | Root SwiftUI stack: subscribes to `overlayStatePublisher`, owns expand/dismiss state, 30s auto-dismiss timer, new-task form. |
| `TipTour/Agents/Overlay/AgentOverlayWindowController.swift` | ~145 | Non-activating NSPanel host anchored top-right. Shows when agents exist, auto-resizes via `fittingSize` KVO. |
| `TipTour/Hermes/HermesConfigBootstrapper.swift` | ~95 | Writes minimum-viable `~/.hermes/config.yaml` so the bundled runtime can complete `session/new` without `hermes setup`. Provider enum (anthropic / openai / google) carries display name, env var name, Keychain key, and default model — single source of truth for provider strings. Used by `ModelsTabView`'s segmented picker and `HermesSetupCoordinator`. |
| `TipTour/Hermes/HermesRuntimeVersion.swift` | ~75 | Parses `hermes-version.txt` emitted by `bundle-hermes.sh`. Exposes `shortDisplayString` for the Settings → Models tab runtime line (`Hermes 0.13.0 (abc1234) · Python 3.11.15`). |
| `TipTour/Hermes/HermesSetupCoordinator.swift` | ~85 | Cross-references `config.yaml` (via `HermesConfigBootstrapper`) against the Keychain (via injected `HermesProviderKeyReader`) to answer "is the runtime ready to take a prompt?". `HermesClient.send` pre-flights through this; `ModelsTabView` reads `configuredProvider` through this to seed its segmented picker. `KeychainProviderKeyReader` is the production implementation; tests inject fakes. |
| `TipTour/Settings/SettingsSheetView.swift` | ~50 | Root of the tabbed Settings sheet opened from the panel footer. Hosts Models, Memory, and Soul tabs via SwiftUI `TabView`. Adding a future tab (Skills, Guardrails, Gateways, Schedule) is a one-line `.tabItem` insertion here. |
| `TipTour/Settings/ModelsTabView.swift` | ~180 | Provider segmented picker (rewrites `~/.hermes/config.yaml` via `HermesConfigBootstrapper.writeMinimalConfig`), three Keychain key rows (Anthropic / OpenAI / Google), per-row Test button that hits the provider's `/v1/models` GET endpoint via `ProviderHealthCheckerFactory`, and a runtime-version line from `HermesRuntimeVersion`. |
| `TipTour/Settings/MemoryTabView.swift` | ~85 | TextEditor over `~/.hermes/memories/USER.md` via `HermesMemoryStore`. Refresh-from-disk button for the Hermes-also-writes-this-file case. |
| `TipTour/Settings/SoulTabView.swift` | ~85 | TextEditor over `~/.hermes/SOUL.md` via `HermesSoulStore`. Surfaces the "edits apply on next session" caveat. |
| `TipTour/Settings/HermesMemoryStore.swift` | ~60 | Atomic read/write for `~/.hermes/memories/USER.md`. Creates the parent directory if missing; falls back to `moveItem` when `replaceItem` can't find a destination (first write to fresh home). |
| `TipTour/Settings/HermesSoulStore.swift` | ~55 | Atomic read/write for `~/.hermes/SOUL.md`. Sibling of `HermesMemoryStore` — kept separate because memory and soul have different semantics (accumulate vs replace). |
| `TipTour/Settings/ProviderHealthChecker.swift` | ~140 | `ProviderHealthChecker` protocol + `AnthropicHealthChecker` / `OpenAIHealthChecker` / `GoogleHealthChecker` implementations + `ProviderHealthCheckerFactory` switch. Each implementation issues a single GET to the provider's models endpoint to validate the key — no LLM call, no Hermes involvement. `Fetch` is a closure typealias (`(URLRequest) async throws -> (Data, URLResponse)`) injected for tests; production defaults to `URLSession.shared.data(for:)`. |
| `DesignSystem.swift` | ~880 | Design system tokens — colors, corner radii, shared styles. All UI references `DS.Colors`, `DS.CornerRadius`, etc. |
| `TipTourAnalytics.swift` | ~106 | PostHog analytics integration for usage tracking. |
| `WindowPositionManager.swift` | ~262 | Window placement logic, Screen Recording permission flow, and accessibility permission helpers. |
| `AppBundleConfiguration.swift` | ~28 | Runtime configuration reader for keys stored in the app bundle Info.plist. |
| `BuildScripts/runtime-assets/parent_watchdog.py` | ~55 | Sibling Python process launched by the bundle entrypoint. Polls `os.getppid()`; when the Mac-app parent dies, sends SIGTERM (then SIGKILL after 3s) to the `acp_adapter` PID. Prevents orphaned Hermes processes after Mac-app crashes. |
| `BuildScripts/runtime-assets/reference-config.yaml` | ~12 | Reference shape for the YAML `HermesConfigBootstrapper` emits. Documents the provider/model strings the bootstrapper supports. Not copied into the bundle — purely a developer reference. |
| `worker/src/index.ts` | ~140 | Cloudflare Worker proxy. Two routes: `/gemini-live-key` (Gemini Live API key) and `/match-label` (multilingual label matcher). |

## Build & Run

```bash
# Open in Xcode
open tiptour-macos.xcodeproj

# Select the TipTour scheme, set signing team, Cmd+R to build and run

# Known non-blocking warnings: Swift 6 concurrency warnings,
# deprecated onChange warning in OverlayWindow.swift. Do NOT attempt to fix these.
```

**Do NOT run `xcodebuild` from the terminal** — it invalidates TCC (Transparency, Consent, and Control) permissions and the app will need to re-request screen recording, accessibility, etc.

## Cloudflare Worker

```bash
cd worker
npm install

# Add secret
npx wrangler secret put GEMINI_API_KEY

# Deploy
npx wrangler deploy

# Local dev (create worker/.dev.vars with GEMINI_API_KEY=...)
npx wrangler dev
```

## Code Style & Conventions

### Variable and Method Naming

IMPORTANT: Follow these naming rules strictly. Clarity is the top priority.

- Be as clear and specific with variable and method names as possible
- **Optimize for clarity over concision.** A developer with zero context on the codebase should immediately understand what a variable or method does just from reading its name
- Use longer names when it improves clarity. Do NOT use single-character variable names
- Example: use `originalQuestionLastAnsweredDate` instead of `originalAnswered`
- When passing props or arguments to functions, keep the same names as the original variable. Do not shorten or abbreviate parameter names. If you have `currentCardData`, pass it as `currentCardData`, not `card` or `cardData`

### Code Clarity

- **Clear is better than clever.** Do not write functionality in fewer lines if it makes the code harder to understand
- Write more lines of code if additional lines improve readability and comprehension
- Make things so clear that someone with zero context would completely understand the variable names, method names, what things do, and why they exist
- When a variable or method name alone cannot fully explain something, add a comment explaining what is happening and why

### Swift/SwiftUI Conventions

- Use SwiftUI for all UI unless a feature is only supported in AppKit (e.g., `NSPanel` for floating windows)
- All UI state updates must be on `@MainActor`
- Use async/await for all asynchronous operations
- Comments should explain "why" not just "what", especially for non-obvious AppKit bridging
- AppKit `NSPanel`/`NSWindow` bridged into SwiftUI via `NSHostingView`
- All buttons must show a pointer cursor on hover
- For any interactive element, explicitly think through its hover behavior (cursor, visual feedback, and whether hover should communicate clickability)

### Do NOT

- Do not add features, refactor code, or make "improvements" beyond what was asked
- Do not add docstrings, comments, or type annotations to code you did not change
- Do not try to fix the known non-blocking warnings (Swift 6 concurrency, deprecated onChange)
- Do not run `xcodebuild` from the terminal — it invalidates TCC permissions

## Git Workflow

- Branch naming: `feature/description` or `fix/description`
- Commit messages: imperative mood, concise, explain the "why" not the "what"
- Do not force-push to main

## Self-Update Instructions

<!-- AI agents: follow these instructions to keep this file accurate. -->

When you make changes to this project that affect the information in this file, update this file to reflect those changes. Specifically:

1. **New files**: Add new source files to the "Key Files" table with their purpose and approximate line count
2. **Deleted files**: Remove entries for files that no longer exist
3. **Architecture changes**: Update the architecture section if you introduce new patterns, frameworks, or significant structural changes
4. **Build changes**: Update build commands if the build process changes
5. **New conventions**: If the user establishes a new coding convention during a session, add it to the appropriate conventions section
6. **Line count drift**: If a file's line count changes significantly (>50 lines), update the approximate count in the Key Files table

Do NOT update this file for minor edits, bug fixes, or changes that don't affect the documented architecture or conventions.
