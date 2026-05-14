# Plan 6 — Guardrails (per-tool approval prompt + persistence)

**Date:** 2026-05-14
**Status:** Design

## Goal

Replace `HermesClient`'s current "auto-allow every `session/request_permission`" stub with a real approval flow: a SwiftUI modal that surfaces each permission ask to the user with Allow / Allow Always / Deny / Deny Always choices. "Always" decisions persist to `~/.hermes/guardrails.json` and are managed via a new Guardrails tab in the Settings sheet. Mac-side MCP tools (point_at / take_screenshot / get_a11y_tree) bypass the prompt — they're auto-allowed because they're ours and they fire frequently during voice mode.

This is v1 of the guardrails surface. Future plans can layer hard-coded refusals, pattern matching, and resource-scope rules on top.

## Big picture

```
Hermes (Python subprocess)
   │ session/request_permission { toolCall: {name, args} }
   ▼
HermesClient.handleServerRequest  ← replaces the existing "auto-allow everything"
   │
   ├─ 1. Is this an MCP tool we control? (point_at / take_screenshot / get_a11y_tree —
   │       sourced live from MCPServer.registeredToolNames, not a hard-coded list)
   │       → allow, no prompt
   │
   ├─ 2. Does GuardrailsStore have a remembered decision for this tool?
   │       always_allow → allow, no prompt
   │       always_deny  → deny, no prompt
   │
   └─ 3. Otherwise → fire approvalDelegate to show modal
            │
            ▼
        ApprovalSheetView shows { tool name, args summary, expandable full args }
        User picks: [Allow] [Allow Always] [Deny] [Deny Always]
            │
            ├─ "always" choices → GuardrailsStore.set(tool, decision)
            │
            └─ Respond to Hermes with the decision
```

**Three layers stacked**, even at v1:
- Built-in safe list: MCP tools, dynamic from `MCPServer`
- Persisted rules: user's remembered "Always Allow / Always Deny" decisions
- Per-call prompt: anything else

## Section 1 — Components & file layout

### Create

- `TipTour/Settings/GuardrailsStore.swift`
  JSON-backed store at `~/.hermes/guardrails.json`. Same atomic-write-tmp-then-rename pattern as `HermesMemoryStore` / `HermesSoulStore`.
  ```swift
  struct GuardrailsStore {
      enum Decision: String, Codable { case allow, deny }
      let hermesHome: URL
      init(hermesHome: URL? = nil)
      var filePath: URL                                    // ~/.hermes/guardrails.json
      func decision(forTool name: String) -> Decision?     // nil = no remembered rule
      func setDecision(_ decision: Decision, forTool name: String) throws
      func remove(toolName name: String) throws
      func allDecisions() -> [String: Decision]            // for the Guardrails tab UI
  }
  ```

- `TipTour/Hermes/GuardrailsDecider.swift`
  Pure decision logic. Given a tool name + args, returns:
  ```swift
  struct ApprovalRequest: Identifiable {
      let id: String                  // mirrors the ACP request id so the
                                      // chat view can wire the reply back
      let toolName: String
      let argsSummary: String         // pre-truncated, display-ready
      let argsFullJSON: String        // pretty-printed JSON for the disclosure
      let onDecision: (Decision, Bool) -> Void
      // Decision = .allow / .deny, Bool = "remember" (true → setDecision)
  }

  enum GuardrailsOutcome {
      case allowImmediately       // MCP tool or remembered allow
      case denyImmediately        // remembered deny
      case askUser(ApprovalRequest)
  }
  ```
  Auto-allow list is **dynamic** — injected via a closure or protocol that reads `MCPServer.registeredToolNames`. Holds no I/O state of its own; consults `GuardrailsStore` for persisted decisions.

- `TipTour/Hermes/ApprovalSheetView.swift`
  SwiftUI sheet hosted by `HermesChatView`. Shows the tool name, args summary, expandable raw-args disclosure, and four buttons.

- `TipTour/Settings/GuardrailsTabView.swift`
  New tab in the Settings sheet alongside Models / Memory / Soul. Lists remembered decisions with Revoke buttons + Reset All.

### Modify

- `TipTour/Hermes/HermesClient.swift`
  Replace the current auto-allow block in `handleServerRequest`. Add `var approvalDelegate: GuardrailsApprovalDelegate?` and `var guardrailsDecider: GuardrailsDecider` properties (the decider is injectable for tests). On a permission request: call `decider.decide(toolName:args:)`, branch on the outcome. For `.askUser`, post `Notification.Name.tipTourPermissionRequested` AND call the delegate. Auto-deny + log warning when no delegate is registered (defensive fallback).

- `TipTour/Hermes/HermesChatWindow.swift`
  `HermesChatView` conforms to `GuardrailsApprovalDelegate`. Owns `@State var pendingApproval: ApprovalRequest?`. Presents `.sheet(item: $pendingApproval) { ApprovalSheetView(...) }`. On any decision: persist if "always", reply to Hermes via a continuation passed in the request, clear `pendingApproval`.

- `TipTour/Settings/SettingsSheetView.swift`
  Add `case guardrails` to the `Tab` enum + a new tab-bar button + a switch case rendering `GuardrailsTabView`.

- `TipTour/Hermes/HermesDebugMenuController.swift`
  Listen for `Notification.Name.tipTourPermissionRequested`. If the chat window isn't currently open, call `openChat()` so the sheet has a host. If the chat window IS open, the notification is a no-op.

### Tests

- `TipTourTests/GuardrailsStoreTests.swift` — 7 tests mirroring `HermesMemoryStoreTests`: missing file returns no decision; setDecision then decision round-trips; remove drops the entry; allDecisions returns the map; idempotent writes; atomic-rename leaves no `.tmp` stragglers; corrupt JSON returns empty (no crash).

- `TipTourTests/GuardrailsDeciderTests.swift` — 6 tests for the decision matrix: MCP tool → allowImmediately; remembered allow → allowImmediately; remembered deny → denyImmediately; unknown tool → askUser with correct toolName + args; MCP allow-list comes from the injected source (not hardcoded — verify); malformed args don't crash the decider.

### Not changed

- `TipTour/Hermes/HermesACPProtocol.swift` — `PermissionResponse` types already accept both `allow` and `reject` outcomes. No protocol changes needed.

## Section 2 — Approval modal UX

**When it fires:** `HermesClient` receives `session/request_permission`. `GuardrailsDecider` returns `.askUser(ApprovalRequest)`. `HermesClient` calls the delegate AND posts the notification. If the chat window is closed, `HermesDebugMenuController` opens it; if open, no-op. The chat view's `.sheet(item: $pendingApproval)` modifier triggers the sheet automatically once the request is delivered to the delegate.

**Visual** (JARVIS-styled — cyan section header, monospaced caps tool name, cyan-bordered args code block, outlined buttons):

```
▬ HERMES // PERMISSION REQUEST

  run_shell_command
  ────────────────

  Hermes wants to run a command on your Mac:

  ┌──────────────────────────────────────────┐
  │ ls -la ~/Documents                       │
  └──────────────────────────────────────────┘

  ▸ See full arguments

  [ DENY ]  [ DENY ALWAYS ]  ··· [ ALLOW ]  [ ALLOW ALWAYS ]

  "Always" remembers your choice and skips this prompt next
  time. Revoke in Settings → Guardrails.
```

Deny on the left so the safer choice is the easier-to-reach one.

**Args summary** (since args can be huge for `write_text_file`):
- For string values ≤ 200 chars: show full
- For string values > 200 chars: show first 200 + `… (N more chars)`
- For dict values: pretty-print one level + truncate per inner value
- "See full arguments" `DisclosureGroup` reveals the raw JSON in a scrollable monospaced block

**Decision wiring:**
- `Allow` → reply `{outcome: "selected", optionId: "allow"}` to Hermes; sheet dismisses
- `Allow Always` → `GuardrailsStore.setDecision(.allow, forTool: name)` THEN reply allow
- `Deny` → reply `{outcome: "selected", optionId: "reject"}` to Hermes; sheet dismisses
- `Deny Always` → `GuardrailsStore.setDecision(.deny, forTool: name)` THEN reply reject

**Keyboard shortcuts:** `Return` = Allow, `Escape` = Deny. "Always" variants have no accelerator — intentional friction.

**Concurrency:** Hermes blocks on `session/request_permission` until we respond. Per-session there's only one in flight. Defensive: if a second arrives while one's pending, log + auto-deny the second.

## Section 3 — Guardrails Settings tab

A new tab alongside Models / Memory / Soul. JARVIS-styled — same `JarvisSectionHeader` + `JarvisButton` primitives from the Settings restyle.

```
▬ REMEMBERED DECISIONS                   ──────────

  ┌────────────────────────────────────────────────┐
  │ run_shell_command            ● ALLOW   [REVOKE] │
  │ web_fetch                    ● DENY    [REVOKE] │
  │ write_text_file              ● ALLOW   [REVOKE] │
  └────────────────────────────────────────────────┘

  (empty state: "No remembered decisions yet. Allow Always
   or Deny Always choices appear here.")

▬ ACTIONS                                 ──────────

  [ RESET ALL ]   removes every remembered decision

▬ WHERE                                   ──────────

  Stored at ~/.hermes/guardrails.json. Edit directly if you'd
  rather. Hermes reads decisions in real time — no app
  restart needed.
```

**Components:**

- `GuardrailsTabView` reads `GuardrailsStore.allDecisions()` in `.onAppear` and after each Revoke. State held as `@State var decisions: [String: GuardrailsStore.Decision]`.
- Each row: monospaced caps tool name, status dot (cyan for allow, red for deny), `[REVOKE]` outlined button.
- Revoke → `try? store.remove(toolName:)` + reload list.
- "Reset all" → confirmation dialog → wipe the file via `try? FileManager.default.removeItem(at: store.filePath)` → reload (returns empty).
- Empty state shown when `decisions.isEmpty`.

**Not in v1:** no edit-in-place. To flip a row from Allow to Deny, the user Revokes; the next time Hermes calls the tool, the modal appears and they choose the new default. Keeps the UI driven by a single flow.

## Section 4 — Edge cases & defensive behavior

| Case | Handling |
|---|---|
| **Hermes sends a malformed permission request** (missing `toolCall.name`) | Auto-deny + log warning. Don't crash, don't auto-allow. |
| **`~/.hermes/guardrails.json` is corrupt** (invalid JSON, partial write) | `GuardrailsStore.allDecisions()` returns empty + logs warning. Same as missing file. User can delete the file via Reset All. |
| **Concurrent permission requests** | Per-session, Hermes blocks waiting for our reply, so realistic risk is zero. Defensive: if a second arrives while one's pending, log + auto-deny the second. No queue. |
| **App quit mid-approval** | Plan 4's `parent_watchdog.py` already kills Hermes when the Mac app dies. No new handling. |
| **MCP auto-allow drift** | Build the auto-allow list **dynamically** from `MCPServer.registeredToolNames` instead of a hard-coded array. Future plans that add MCP tools don't have to update `GuardrailsDecider`. |
| **Tool-name collision** (Hermes ships an internal tool with the same name as ours) | Acceptable risk for v1. Document the assumption in `GuardrailsDecider`. Hermes Agent doesn't currently ship anything matching our MCP names. |
| **Decision visibility in chat transcript** | **No** for v1. Approvals are operational UX, not conversation. Logged to console for debugging. |
| **Sheet auto-opens chat window when Hermes asks while chat is closed** | `HermesClient` posts `Notification.Name.tipTourPermissionRequested` on the main actor. `HermesDebugMenuController` observes it → calls existing `openChat()` → chat view picks up the pending request through the delegate. |

## Section 5 — Testing & verification

### Unit tests (XCTest, fast, no subprocess)

| File | Coverage |
|---|---|
| `GuardrailsStoreTests` | 7 tests: missing file → nil; setDecision + decision round-trips; remove drops the entry; allDecisions returns map; idempotent writes; atomic-rename leaves no `.tmp` stragglers; corrupt JSON returns empty (no crash) |
| `GuardrailsDeciderTests` | 6 tests: MCP tool → allowImmediately; remembered allow → allowImmediately; remembered deny → denyImmediately; unknown tool → askUser with correct toolName + args; MCP allow-list comes from injected source; malformed args don't crash |

### Manual end-to-end smoke test

1. ⌘R, ⌥⇧H, type *"list the files in my home directory"* → sheet appears with `run_shell_command` and the args → click **Allow** → Hermes proceeds, transcript shows the listing
2. Ask *"check the news on hacker news"* → sheet for `web_fetch` → click **Allow Always** → confirm `~/.hermes/guardrails.json` contains `{"web_fetch": "allow"}` → ask another web fetch question → no sheet, proceeds silently
3. Ask *"write a file called test.txt with the word hello"* → sheet for `write_text_file` → click **Deny Always** → Hermes responds it couldn't write → confirm `guardrails.json` has `write_text_file: deny` → ask again → no sheet, immediate denial
4. Open **Settings → Guardrails** → see two rows (web_fetch ALLOW, write_text_file DENY) → click Revoke on `web_fetch` → row disappears, JSON updated
5. Voice mode: Ctrl+Option, *"search for the latest Swift news and summarize"* → Hermes triggers `web_fetch` → revoked in step 4 so the sheet pops, auto-opening the chat window if needed → click Allow → Gemini speaks the summary
6. Click **Reset all** in the Guardrails tab → confirm dialog → file emptied or removed → tab shows the empty state

No automated end-to-end test — live Hermes + ACP + permission flow isn't mockable from XCTest cleanly. Unit tests cover the decision matrix; manual smokes cover the wire path.

## Out of scope (deferred to future plans)

- **Hard-coded refusals (Layer A)** — `rm -rf /`, `curl | sh`, mass-delete patterns. Future plan.
- **Pattern matching** — "deny anything that reads `~/private/*`", regex on args. Future plan.
- **Per-resource rules** — file system scopes, network host allowlist. Future plan.
- **Edit-in-place in Guardrails tab** — flipping a row from Allow to Deny without going through the modal. Future plan.
- **Approval history** — a log of past decisions with timestamps. Future plan.
- **Remote approval routing** — Telegram or other gateway forwards an approval ask to the user's phone. Plan 7+ territory.
- **Auto-revoke after N days** — time-bounded "always" decisions. Future plan.
