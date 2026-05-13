# Hermes for Noobs — Design

**Date:** 2026-05-13
**Status:** Draft, awaiting user review

## One-line summary

A macOS menu bar app that wraps the [Hermes Agent](https://github.com/NousResearch/hermes-agent) runtime so non-technical users get Hermes' full power — voice, skills, memory, subagents, scheduled tasks, multi-platform messaging — without ever opening a terminal or provisioning a VPS. Forks the TipTour macOS shell, throws away its homegrown subagent system, and uses Hermes as the agent engine instead.

## Goals

1. **Zero terminal, zero VPS.** A non-technical Mac user installs a `.dmg`, double-clicks, pastes a few API keys into a Settings panel, and is talking to a fully-featured agent.
2. **Voice-first front-end.** Keep TipTour's Gemini Live experience (push-to-talk, on-screen cursor, real-time speech) verbatim.
3. **Hermes as the engine.** Reliable subagent spawning, skills, memory, cron, multi-platform messaging — all delegated to Hermes instead of re-implemented in Swift.
4. **Configurable from inside the app.** Any Hermes feature that today requires editing TOML, running `hermes config set`, or doing `hermes gateway setup` becomes a GUI control in the Mac app's Settings.
5. **Safe by default.** Paranoid guardrails that prevent the agent from harming the Mac, the user, or the user's money. Loosenable in Settings, but never bypassable for hard-limit operations.

## Non-goals (for v1)

- Mass distribution / paid tier / per-user accounts. Single-user app for now.
- Windows or Linux. macOS only.
- Replacing Gemini Live with a Hermes-native voice mode. Hermes is text-driven; Gemini Live is bidirectional realtime audio. We keep both, they play different roles.
- Re-inventing Hermes' config schema. We write the same `config.toml` Hermes already understands.

## Architecture

Three processes during normal use:

1. **`HermesForNoobs.app`** (Swift / SwiftUI / AppKit) — menu bar, cursor overlay, Gemini Live WebSocket, AX resolver, ActionExecutor. The only process that can touch the user's screen.
2. **`hermes-runtime`** — bundled Python 3.11 + Hermes venv, launched as a subprocess by the Mac app on first push-to-talk press. Runs the agent loop, owns skills, memory, web/file/shell tools, subagent spawning. Communicates with the Mac app via ACP (JSON-RPC over stdio).
3. **`hermes-gateway`** — same Python venv, second subprocess, launched only when at least one messaging gateway (Telegram / Slack / Discord / WhatsApp / Signal / Email) is enabled in Settings. Reads the same `config.toml` and memory store as the runtime.

```
HermesForNoobs.app
├── Voice front-end ───── Gemini Live (remote)
├── Tool dispatcher ───── local tools (AX / CGEvent / AppleScript)
│                  └──── remote tools ─ ACP stdio ─▶ hermes-runtime
└── Control plane / Settings UI ──── writes ──────▶ config.toml
                                            │
                                            └─────▶ hermes-gateway
                                                    (optional, per
                                                     enabled gateways)
```

Both Hermes subprocesses read the same config and share the same memory store. A Telegram message can reach the same agent the user just spoke to.

The Mac app starts/stops `hermes-gateway` reactively based on Settings toggles. `hermes-runtime` is started lazily on first voice press and stays alive until the app quits.

## Hermes bundling

`HermesForNoobs.app/Contents/Resources/hermes-runtime/` contains:

- A relocatable Python 3.11 build (~30 MB)
- A pre-installed Hermes venv with all `.[all]` extras except Termux-only ones
- A small entrypoint script `hermes-runtime` that exec's `python -m hermes.acp_adapter` with stdio inherited

A Xcode build phase script (`Build/bundle-hermes.sh`) downloads Python and freezes the venv into the bundle at build time. The build script is the *only* moment a network connection is required to construct the Hermes payload; end users get a fully self-contained `.app`.

Estimated `.dmg` size: ~150 MB.

## Wire protocol (ACP over stdio)

Newline-delimited JSON-RPC. Examples:

```jsonc
// Swift → Hermes
{"id":"u1","method":"user.message","params":{"text":"find me a cheap flight to tokyo","channel":"voice"}}
{"id":"t9","method":"tool.result","params":{"tool_call_id":"tc_42","result":"...","is_error":false}}
{"id":"a7","method":"approval.response","params":{"approval_id":"ap_3","approved":true}}

// Hermes → Swift (streamed notifications)
{"method":"agent.thinking","params":{"text":"Looking up flights..."}}
{"method":"agent.message","params":{"text":"Found 3 options. Want me to book?","final":false}}
{"method":"tool.call","params":{"tool_call_id":"tc_42","name":"smart_click","args":{"label":"Book"},"destination":"local"}}
{"method":"approval.request","params":{"approval_id":"ap_3","action":"delete file ~/Downloads/old.zip","risk":"destructive"}}
{"method":"agent.done","params":{"summary":"Booked, confirmation in inbox.","tokens_used":4231}}
```

Every Hermes tool is annotated with a `destination` field: `"local"` (executed by the Swift app) or `"hermes"` (executed inside the Hermes process). Hermes' tool dispatcher checks the field; for `local` tools it emits a `tool.call` notification and blocks on the matching `tool.result` from Swift.

## Tool routing

Two distinct tool surfaces.

**Surface 1 — What Gemini Live sees** (small, high-level):

- `point_at_element(label, box_2d?)` — local, identical to today's TipTour
- `submit_workflow_plan(goal, app, steps)` — local, identical to today's TipTour
- `ask_hermes(task, task_type)` — new. Forwards the entire task to Hermes via `user.message`. Replaces today's `spawn_background_task`. This is the single bridge from voice to Hermes; Gemini Live never sees Hermes' internal tools.

**Surface 2 — What Hermes' agent loop sees** (full, fine-grained). Every tool here is annotated with a `destination` field: `"local"` (executed by the Swift app via ACP round-trip) or `"hermes"` (executed inside the Hermes process).

**Local tools** (Swift, must run in the app for TCC / AX / CGEvent reasons):

- `smart_click`, `ax_press_element`, `click_element`
- `type_text`, `press_keyboard_shortcut`
- `read_ax_tree`, `capture_screenshot`
- `open_url` (via NSWorkspace)
- `run_applescript`, `chrome_control`, `safari_control`, `system_events`

**Hermes-native tools** (Python, no GUI side-effects):

- `web_fetch`, `web_search`
- `read_file`, `write_file`, `list_directory`
- `run_shell_command`, `interactive_shell`
- `recall_skill`, `save_skill`, `import_skill`
- `remember_fact`, `recall_facts`
- `spawn_subagent`
- `schedule_cron`

Hermes subagents call tools through the same routing layer; a subagent that clicks something causes the same `tool.call → tool.result` round-trip back to the Mac app. The Mac app's `ActionExecutor.shared` (single-instance, guarded by `GUIActionMutex`) remains the single serialization point for HID events — Hermes can spawn many subagents but only one click happens at a time.

## Control plane (Settings UI)

Single tabbed Settings window (SwiftUI sheet), launched from the menu bar panel footer:

| Tab | Wraps |
|---|---|
| **Models** | Paste API keys (Keychain). Model picker per task type. "Test connection" per provider. |
| **Gateways** | Toggle Telegram / Slack / Discord / WhatsApp / Signal / Email. Per-platform setup wizard. Approval-channel preference. |
| **Skills** | Browse + toggle bundled and installed skills. Import from GitHub URL. Link to agentskills.io. |
| **Memory** | List, edit, pin, expire, delete stored facts. "Forget everything" with confirm. |
| **Guardrails** | Tier toggle (Paranoid / Standard / Yolo). Allowlist editor. Token-spend cap. "Pause all agents." |
| **Schedule** | Form-based cron editor. when × what × deliver-where. |

All tabs read and write the same `config.toml` Hermes uses. Secrets are referenced from config as `${keychain:openai_api_key}` and stored in macOS Keychain. The UI re-reads the file on focus so hand-edits round-trip.

## Guardrails

Three layers stacked from "always on" to "easy to disable."

### Layer A — Hard limits (never bypassable)

Pattern-matched in a Swift-side pre-flight check *before* the shell command leaves the app. Even Yolo mode can't bypass these.

- `rm -rf /`, `rm -rf $HOME`, any glob that matches outside the agent workspace + an explicit allowlist
- `sudo`, `dscl`, `csrutil`, `kextunload`, anything requiring elevated privileges
- Writes to `/System`, `/Library`, `/usr`, `/bin`, `/sbin`, `/private/var`
- `mkfs`, `dd of=/dev/*`, network reconfig (`networksetup`, `ifconfig`, `route`)
- AppleScript that touches `System Preferences → Privacy`, screen-recording the lock screen, accessing Keychain items not owned by the app

Blocked actions return a structured tool error to Hermes: `"blocked by hard limit: <reason>."`

### Layer B — Per-action approval (default for destructive ops)

For risky-but-not-forbidden actions, Hermes raises an `approval.request`. Risk taxonomy:

| Risk | Examples | Paranoid | Standard | Yolo |
|---|---|---|---|---|
| `read` | read_file, web_fetch, AX read | no approval | no approval | no approval |
| `mutation` | write_file in workspace, click | approval | no approval | no approval |
| `external` | send email, post to Slack, click "Pay" | approval | approval | no approval |
| `destructive` | delete file, drop table | approval | approval | approval |

**Approval routing.** Approval prompts go to the *active channel* — the channel that initiated the task:

- Voice / menu-bar use → macOS-native confirmation sheet, large yellow card on the cursor overlay, voice prompt via Gemini Live
- Telegram → inline-keyboard message with `[Approve] [Deny] [Always]`
- Slack → `chat.postMessage` with action buttons
- Discord → reaction-based approval (✅ / ❌)
- WhatsApp / Signal → text reply with `YES / NO` parsing

Each gateway has an "approval channel" preference in Settings. By default the active channel handles its own approvals; the user can route, e.g., all Slack-initiated approvals to Telegram.

Approvals time out after 5 minutes → deny.

### Layer C — Budget caps

- Daily token-spend cap (configurable, default $5/day), progress bar in the menu bar panel
- Concurrent-subagent cap (default 5)
- Per-tool rate limit (default 30 shell commands per minute)

Hitting any cap pauses all in-flight work and surfaces a single approval to "continue anyway / stop." Tripped cap → persistent menu bar warning.

### Kill switch

Permanently visible button in the menu bar panel: **"Pause all agents."** Sends `agent.cancel` over ACP, terminates `hermes-gateway` if running, halts every in-flight subagent. Gemini Live is told the user has paused everything so it stops speaking.

All approvals, denials, and blocked actions are appended to an audit log (Settings → Memory → Audit log).

## What we fork, what we cut, what's new

Forking once: copy `TipTour-macOS/repo/` into the new project directory. Then file-by-file:

### Keep (voice front-end and macOS plumbing)

- `TipTourApp.swift`, `MenuBarPanelManager.swift`, `CompanionPanelView.swift` (renamed)
- `OverlayWindow.swift`, `CompanionResponseOverlay.swift`, `NekoCursorView.swift`
- `GeminiLiveClient.swift`, `GeminiLiveSession.swift`, `GeminiLiveAudioPlayer.swift`, `PCM16AudioConverter.swift`
- `GlobalPushToTalkShortcutMonitor.swift`, `PushToTalkShortcut.swift`
- `AccessibilityTreeResolver.swift`, `ElementResolver.swift`, `AppChannelRegistry.swift`
- `ActionExecutor.swift`, `GUIActionMutex.swift`
- `ClickDetector.swift`, `WorkflowRunner.swift`, `WorkflowPlan.swift`
- `CompanionScreenCaptureUtility.swift`, `ScreenshotPerceptualHash.swift`, `ScreenRecorder.swift`
- `KeychainStore.swift`, `DesignSystem.swift`, `WindowPositionManager.swift`, `RetryWithExponentialBackoff.swift`
- `Info.plist` (every TCC usage description stays)

### Cut entirely (replaced by Hermes)

- `Agents/Swarm/*` — TaskAgent, AgentSwarmManager, AgentTypes
- `Agents/Core/LLMProvider.swift`, `LLMProviderRegistry.swift`, `EfficiencyMonitor.swift`, `EfficiencyTypes.swift`
- `Agents/Providers/*` — Anthropic, OpenAI, GeminiRest
- `Agents/Memory/*` — AgentMemoryStore, AgentMemoryEntry, MemoryTools
- `Agents/Skills/*` — SkillLibraryStore, SkillImporter, BundledSkillSeeder, SkillExtractor, etc.
- `Agents/Tools/ShellTool.swift`, `InteractiveShellTool.swift`, `WebTools.swift`, `FileTools.swift`, `GenerationTools.swift`, `SpawnClaudeCodeTool.swift`, `MemoryTools.swift`, `SkillTools.swift`
- `Agents/Overlay/AgentPanelView.swift`, `AgentOverlayStackView.swift`, `AgentOverlayWindowController.swift`, `AgentStateDisplay.swift`
- `worker/` — Cloudflare Worker. Users supply their own keys now. Kept on a branch for reference.

### Keep but adapt (become local-tool adapters)

- `Agents/Tools/MacControlTools.swift` — ReadAXTree, ClickElement, AXPressElement, TypeText, PressKeyboardShortcut, OpenURL
- `Agents/Tools/SmartActionTools.swift` — SmartClick
- `Agents/Tools/AppleScriptTools.swift` — AppleScriptRunner, ChromeControl, SafariControl, SystemEvents

Each one stops being an `AgentTool` subclass and becomes a function `func executeLocally(args: JSON) async -> JSON` registered in `LocalToolRegistry`.

### New code

| File | Purpose |
|---|---|
| `Hermes/HermesRuntimeProcess.swift` | Lifecycle for the Python runtime subprocess |
| `Hermes/HermesGatewayProcess.swift` | Lifecycle for the gateway subprocess |
| `Hermes/HermesClient.swift` | ACP framing, pending-request map, streaming notifications |
| `Hermes/HermesBundle.swift` | Locates bundled Python + venv inside the .app |
| `Hermes/ToolDispatcher.swift` | Routes `tool.call` to local or rejects |
| `Hermes/LocalToolRegistry.swift` | Table of local tool name → handler |
| `Hermes/HermesConfigStore.swift` | Reads / writes `config.toml`, marshals Keychain refs |
| `Guardrails/PreflightChecker.swift` | Layer A hard-limit pattern matching |
| `Guardrails/ApprovalRouter.swift` | Layer B; routes prompts to Mac dialog / Telegram / Slack / Discord |
| `Guardrails/BudgetMonitor.swift` | Layer C; token + concurrency + rate caps |
| `Guardrails/AuditLog.swift` | Append-only log of approvals, denials, blocked actions |
| `Settings/Tabs/ModelsTab.swift`, `GatewaysTab.swift`, `SkillsTab.swift`, `MemoryTab.swift`, `GuardrailsTab.swift`, `ScheduleTab.swift` | The six Settings tabs |
| `Activity/HermesActivityView.swift` | Replaces the old AgentOverlayStackView; shows what Hermes is doing in real time |
| `Build/bundle-hermes.sh` | Xcode build phase script that pulls Python + Hermes into Resources/ |

### Boundary worth flagging

`CompanionManager.swift` (~1000 lines today) is the spider in the web — owns Gemini Live, AX, screen capture, tool callbacks, swarm spawning, demonstration recording. It must thin down: keep voice + AX + screen, hand all tool-call dispatch off to `ToolDispatcher`, remove `onSpawnBackgroundTask`. Target post-migration size ~500 lines.

## Data flow — happy path

1. User holds **Ctrl+Option**, speaks: *"Find me a cheap flight to Tokyo."*
2. Mac app's `GeminiLiveSession` streams the mic audio over WebSocket to Gemini Live.
3. Gemini Live replies with a tool call: `ask_hermes(task="find me a cheap flight to tokyo", task_type="browser_research")`.
4. `ToolDispatcher` recognises `ask_hermes` as a remote tool and forwards it to `HermesClient` as a `user.message`.
5. Hermes' agent loop runs. It opens `chrome_control(open_url, ...)` — that's a *local* tool, so Hermes emits `tool.call` over ACP.
6. Mac app's `ToolDispatcher` receives the `tool.call`, runs it through `Guardrails/PreflightChecker` (passes; `chrome_control` is `external` risk, but reading URLs is not destructive), executes via `AppleScriptRunner`, returns `tool.result`.
7. Hermes scrapes flight options, sends `agent.message{text:"Found 3 options.", final:false}` for streaming display.
8. Mac app forwards Gemini Live a synthetic transcript so it can read the result aloud.
9. Hermes proposes `chrome_control(click, "Book")` — that's `external` risk → `approval.request` emitted.
10. `ApprovalRouter` shows a macOS-native sheet (channel was voice). User taps Approve.
11. Hermes finishes, emits `agent.done{summary:"Booked, confirmation in inbox."}`.
12. Gemini Live speaks the summary back to the user.

## Risks and open questions

- **Hermes ACP adapter maturity.** Hermes ships `acp_adapter/` but we haven't verified it supports the full method set we need (especially `approval.request`). May require contributing upstream or writing a small Hermes plugin. Validation task: build a CLI-only ACP smoke test before integrating with Swift.
- **Bundled Python codesigning.** Apple notarization requires all embedded binaries (the Python interpreter, every `.so` in the venv) to be signed. Build phase script must signal this; we'll need a hardened-runtime entitlement and `codesign --deep` over the runtime directory. Expect notarization friction on first ship.
- **Subprocess lifecycle on app crash.** If the Mac app crashes, the Hermes subprocesses are orphaned. Need a parent-PID watcher inside Hermes that terminates the process when its parent dies (already common pattern on macOS).
- **Approval routing for unattended runs.** If a cron job fires at 3 AM and triggers an approval, the active-channel rule fails (no active channel). Resolution: cron jobs always route approvals to the user's "default approval channel" (set in Settings, defaulting to whichever messaging platform has the most recent activity).
- **Gemini Live API key visibility.** Today TipTour fetches the Gemini key from a Cloudflare Worker. After this migration the key lives in the user's Keychain and is used directly. Worth confirming that's acceptable — it does mean a determined user could extract their own key from Keychain (which is fine since it's theirs).
- **Shared SQLite from two Python processes.** `hermes-runtime` and `hermes-gateway` both read and write Hermes' memory and session SQLite databases. Must enable WAL journal mode and tune busy-timeout to avoid `database is locked` errors during concurrent writes. Verified during the runtime smoke test.

## What's deliberately out of scope

- Cross-device sync of memory / skills between two Macs
- Sharing skills between users
- Anything related to training models on user data
- Replacing Gemini Live with a Hermes-native voice mode
- Mobile clients (the user can already reach the agent via Telegram once gateways are configured)

## Acceptance criteria

- A non-technical user installs the `.dmg`, opens the app, pastes a Gemini key, and successfully holds push-to-talk + asks a question that requires a web search. They get a spoken answer.
- The same user enables Telegram from Settings, pastes a bot token, and the bot responds to a message sent on their phone with the same agent's memory.
- An attempt by the agent to run `rm -rf ~/Documents` is blocked by Layer A and the user sees an audit log entry.
- An attempt by the agent to send an email triggers a confirmation in the active channel.
- Token-spend cap, when hit, halts work and surfaces an approval to continue.

## Next step

`/superpowers:writing-plans` to break this design into an implementation plan.
