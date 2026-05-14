# Plan 7 — Hermes MCP GUI Autopilot (click_element, type_text, press_keyboard_shortcut) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend the MCP surface TipTour exposes to Hermes so Hermes can drive the user's apps — not just point at them. Add three new MCP tools (`click_element`, `type_text`, `press_keyboard_shortcut`) that route through TipTour's existing `ActionExecutor` so the `GUIActionMutex` continues to serialize every CGEvent burst. Gate the destructive tools behind a new `hermesGUIAutopilotEnabled` flag (default OFF) until Plan 6 (Guardrails) ships, at which point the flag is replaced with a `GuardrailsDecider` call. Every click is preceded by a visible glow-cursor flight so the user always sees what Hermes is about to do.

**Architecture:** Three new conformances to the existing `MCPTool` protocol, registered with `MCPServer` at `CompanionManager` init time alongside the existing `ScreenshotTool` / `A11yTreeTool` / `PointAtTool`. Each new tool: (1) refuses early if `hermesGUIAutopilotEnabled` is false, (2) for `click_element`, resolves the label via `AccessibilityTreeResolver` and visibly flies the glow cursor by writing to `CompanionManager.detectedElementScreenLocation` / `detectedElementDisplayFrame` / `detectedElementBubbleText`, sleeps long enough for the bezier flight to land, then calls `ActionExecutor.shared.click`, (3) for `type_text` and `press_keyboard_shortcut`, calls `ActionExecutor.shared.typeText` / `pressKeyboardShortcut` directly — no cursor flight because they act on whatever has keyboard focus. All three accept an optional `app_hint` string that maps to `NSRunningApplication.runningApplications(withBundleIdentifier:)` for the activation parameter.

**Tech Stack:** Swift / SwiftUI / AppKit on macOS. `@MainActor` throughout. Uses existing `MCPTool` protocol, `ActionExecutor`, `AccessibilityTreeResolver`, `GUIActionMutex`. XCTest for unit tests; manual end-to-end test against a real Hermes session for verification.

**Depends on:** None of Plan 7 depends on Plan 6 (Guardrails) shipping. Plan 7 ships its own temporary gate (`hermesGUIAutopilotEnabled`); Plan 6 — when it lands — replaces that gate with `GuardrailsDecider` via the migration described in Task 8.

---

## File map

**Create:**

- `TipTour/Hermes/ClickElementMCPTool.swift` — `click_element` MCP tool. By-label element resolution + visible glow-cursor flight + `ActionExecutor.click`. ~110 lines.
- `TipTour/Hermes/TypeTextMCPTool.swift` — `type_text` MCP tool. Types into the currently focused field via `ActionExecutor.typeText` (pasteboard staging + Cmd+V, layout-agnostic). ~75 lines.
- `TipTour/Hermes/PressKeyboardShortcutMCPTool.swift` — `press_keyboard_shortcut` MCP tool. Parses shortcut string (e.g. "Cmd+S") and posts via `ActionExecutor.pressKeyboardShortcut`. ~75 lines.
- `TipTourTests/ClickElementMCPToolTests.swift` — argument-parsing, autopilot-gate, no-match-found cases.
- `TipTourTests/TypeTextMCPToolTests.swift` — argument-parsing + autopilot-gate.
- `TipTourTests/PressKeyboardShortcutMCPToolTests.swift` — argument-parsing + autopilot-gate.

**Modify:**

- `TipTour/CompanionManager.swift`
  - Add `@Published var hermesGUIAutopilotEnabled: Bool` backed by `UserDefaults` key `"hermesGUIAutopilotEnabled"` (default `false`).
  - Add `setHermesGUIAutopilotEnabled(_ enabled: Bool)` setter that mirrors the published value and persists to `UserDefaults`.
  - In the existing MCP registration block (around line 415), register the three new tools in addition to the existing three.
- `TipTour/CompanionPanelView.swift` — add a `hermesGUIAutopilotRow` to the developer section that exposes the toggle. The toggle's binding flows through `companionManager.setHermesGUIAutopilotEnabled`.
- `AGENTS.md` — add three rows to the Key Files table (one per new tool) and append a sentence to the existing Hermes / MCP architecture bullet noting that destructive MCP tools are gated by `hermesGUIAutopilotEnabled` until Plan 6's `GuardrailsDecider` replaces it.

**Not changed:**

- `TipTour/Hermes/MCPTool.swift` — the protocol stays as-is. Safety tier isn't added in this plan; Plan 6 (Guardrails) introduces it.
- `TipTour/Hermes/MCPServer.swift` — the server's `tools/list` / `tools/call` machinery already handles arbitrary `MCPTool` conformances. No protocol-level changes.
- `TipTour/ActionExecutor.swift` — already does everything we need. No additions.
- `TipTour/Hermes/PointAtTool.swift` — kept untouched. `ClickElementMCPTool` deliberately does NOT extend `PointAtTool`; it duplicates the small AX-tree-resolve + set-detectedElement* block because that block is ~10 lines and an inheritance/composition relationship is more friction than the duplication is worth.

---

## Build / test conventions

This is an Xcode project. Do NOT run `xcodebuild` from the terminal — it invalidates TCC permissions per `CLAUDE.md`. Each task that has a build verification step uses Xcode directly:

- **Build:** in Xcode, select the `TipTour` scheme, ⌘B. Expected: green build, no errors.
- **Run tests:** ⌘U. Expected: all green (or skipped via `try XCTSkipUnless` if a test needs Accessibility/Screen Recording permission).
- **Run the app:** ⌘R. The app appears in the menu bar. The Hermes chat window can be opened from the panel footer.

Do NOT attempt to "fix" the existing Swift 6 concurrency warnings or the deprecated `onChange` warning in `OverlayWindow.swift`. Per `AGENTS.md` these are known non-blocking warnings.

---

## Context — what you're plugging into

You're modifying **TipTour**, a macOS menu-bar voice companion. The app has three big collaborating pieces, and this plan extends the boundary between two of them.

**TipTour (Swift macOS app)** is the eyes, ears, and voice. It owns the menu-bar icon, the floating panel, the full-screen cursor overlay, screen capture, the global Ctrl+Option hotkey, and a direct WebSocket to **Gemini Live** (Google's realtime multimodal API). Gemini hears the user's mic, sees JPEG screenshots, replies in voice, and calls tools — `point_at_element`, `submit_workflow_plan`, `spawn_background_task`, `ask_hermes` — which TipTour dispatches locally.

**Hermes** is a bundled Python coding-agent subprocess (Anthropic's ACP runtime, talks JSON-RPC over stdin/stdout to `HermesClient`). It handles "real work" requests: files, shell commands, multi-step reasoning. Hermes is launched on demand by `HermesClient.send()`; a `parent_watchdog.py` sibling SIGTERMs it if the Mac app crashes.

**MCP** is the back-channel from Hermes into TipTour. When `HermesClient` opens a session it passes an MCP server URL (`MCPServer` in `TipTour/Hermes/MCPServer.swift`) and Hermes registers it. Hermes can then call back into the Mac app for things only TipTour can do — today that's `take_screenshot`, `get_a11y_tree`, `point_at` (read-only or visual). **This plan adds three destructive MCP tools** (`click_element`, `type_text`, `press_keyboard_shortcut`) so Hermes can not just see and point but actually drive the user's apps — gated by an opt-in toggle until Plan 6 (Guardrails) ships a proper per-call approval system.

All the destructive primitives already exist in `ActionExecutor.shared` (`click`, `typeText`, `pressKeyboardShortcut`), wrapped in `GUIActionMutex.runExclusive` so concurrent calls from any source — voice-mode workflows, background agents, Hermes — serialize at the HID layer. **You are not building new GUI-driving capability; you are exposing an existing capability to a new caller** behind a clearly-labelled gate.

The four files you'll modify are: three new `MCPTool` conformances, plus `CompanionManager.swift` (to add the gate + register the tools) and `CompanionPanelView.swift` (to expose the gate as a toggle). The test surface is three small XCTest files. The end-to-end manual test runs against a real Hermes session opened from the menu-bar panel's chat button.

---

## Background — code you'll be calling into

The implementor should read these once before writing code. All paths are relative to the repo root.

- **`TipTour/Hermes/MCPTools.swift`** — defines the `MCPTool` protocol:
  ```swift
  protocol MCPTool: Sendable {
      var name: String { get }
      var description: String { get }
      var inputSchema: JSONValue { get }
      @MainActor func call(_ arguments: JSONValue) async throws -> [MCPToolContent]
  }
  ```
  `MCPToolContent` is `.text(String)` or `.image(base64:mimeType:)`. `MCPToolError` is `.invalidArguments(String)` or `.toolFailed(String)`.

- **`TipTour/Hermes/PointAtTool.swift`** — the closest existing tool to what we're building. Use it as the structural template (header comment, class layout, argument parsing pattern, `@MainActor final class`, `weak var companionManager: CompanionManager?` ownership). Lines ~46-87 show the exact resolver-then-set-detectedElement flow that `ClickElementMCPTool` reuses.

- **`TipTour/AccessibilityTreeResolver.swift`** — `findElement(byLabel:targetAppHint:) -> ResolvedElement?`. `ResolvedElement` has `screenFrame: CGRect` and `appBundleID: String?`. Use `targetAppHint: nil` to search the frontmost app; pass `app_hint` from MCP args otherwise.

- **`TipTour/ActionExecutor.swift`** — singleton at `ActionExecutor.shared`. Three relevant async-throws methods:
  ```swift
  func click(at globalScreenPoint: CGPoint, activatingTargetApp: NSRunningApplication? = nil) async throws
  func pressKeyboardShortcut(_ shortcutString: String, activatingTargetApp: NSRunningApplication? = nil) async throws
  func typeText(_ text: String, activatingTargetApp: NSRunningApplication? = nil) async throws
  ```
  Every entry point is wrapped in `GUIActionMutex.runExclusive` so concurrent calls (e.g. one from Hermes and one from voice-mode `WorkflowRunner`) serialize at the HID layer. Do NOT bypass these — call them directly.

- **`TipTour/CompanionManager.swift`** — the published vars that drive the overlay's glow-cursor flight:
  ```swift
  @Published var detectedElementScreenLocation: CGPoint?
  @Published var detectedElementDisplayFrame: CGRect?
  @Published var detectedElementBubbleText: String?
  ```
  Setting these triggers `OverlayWindow`'s bezier flight. `clearDetectedElementLocation()` (line ~473) nils them all out.

- **`TipTour/Hermes/MCPServer.swift`** — `mcpServer.register(_ tool: MCPTool)` adds a tool to the `tools/list` response Hermes auto-discovers. Registration order doesn't matter.

- **AppKit pattern for resolving `app_hint` → `NSRunningApplication`:** the resolver returns `appBundleID`; we then call `NSRunningApplication.runningApplications(withBundleIdentifier:)` and take `.first`. If the resolver returns no `appBundleID`, pass `nil` to `ActionExecutor` (it falls back to the frontmost app implicitly).

---

## Task 1: `hermesGUIAutopilotEnabled` flag + dev-panel toggle

**Files:**
- Modify: `TipTour/CompanionManager.swift`
- Modify: `TipTour/CompanionPanelView.swift`

The destructive MCP tools refuse outright when this flag is false. Default false so a freshly installed TipTour does NOT grant Hermes click access until the user opts in.

- [ ] **Step 1: Add the flag to `CompanionManager`**

  Near the other `@Published` properties at the top of the class (around lines 30-50), add:

  ```swift
  /// Master gate for Hermes' destructive MCP tools (click_element,
  /// type_text, press_keyboard_shortcut). When false, those tools
  /// throw `MCPToolError.toolFailed` immediately so Hermes never
  /// drives the user's mouse/keyboard without explicit consent.
  ///
  /// Defaults to false on a fresh install. Persisted to UserDefaults
  /// so it survives app restarts.
  ///
  /// Replaced by `GuardrailsDecider` once Plan 6 (Guardrails) lands —
  /// see `docs/superpowers/plans/2026-05-14-plan-7-hermes-mcp-gui-autopilot.md`
  /// Task 8 for the migration steps.
  @Published private(set) var hermesGUIAutopilotEnabled: Bool =
      UserDefaults.standard.bool(forKey: "hermesGUIAutopilotEnabled")

  func setHermesGUIAutopilotEnabled(_ enabled: Bool) {
      hermesGUIAutopilotEnabled = enabled
      UserDefaults.standard.set(enabled, forKey: "hermesGUIAutopilotEnabled")
  }
  ```

- [ ] **Step 2: Add the toggle row to `CompanionPanelView`**

  In the developer section (search for the existing toggle rows like `autopilotToggleRow` or `nekoModeToggleRow` — there should be a similar pattern), add a new private var:

  ```swift
  private var hermesGUIAutopilotRow: some View {
      Toggle(isOn: Binding(
          get: { companionManager.hermesGUIAutopilotEnabled },
          set: { companionManager.setHermesGUIAutopilotEnabled($0) }
      )) {
          VStack(alignment: .leading, spacing: 2) {
              Text("Hermes can drive my Mac")
                  .foregroundColor(DS.Colors.primaryText)
              Text("Allows Hermes' MCP tools to click, type, and press keyboard shortcuts on your apps. Off by default.")
                  .font(.system(size: 10))
                  .foregroundColor(DS.Colors.secondaryText)
                  .fixedSize(horizontal: false, vertical: true)
          }
      }
      .toggleStyle(.switch)
  }
  ```

  Insert it into the developer section's view stack alongside the other dev rows.

- [ ] **Step 3: Verify**
  - Build (⌘B). Expect green.
  - Run (⌘R). Open the menu bar panel → expand the developer section → confirm the new toggle is present and off by default.
  - Toggle on, restart the app, confirm the toggle stays on (UserDefaults persistence).
  - Toggle off, restart, confirm off.

---

## Task 2: `ClickElementMCPTool` + tests

**Files:**
- Create: `TipTour/Hermes/ClickElementMCPTool.swift`
- Create: `TipTourTests/ClickElementMCPToolTests.swift`

By-label clicking with a visible glow-cursor flight. The flight gives the user a ~1-second window to see what's about to be clicked before the actual `CGEvent` fires.

- [ ] **Step 1: Write the failing tests**

  `TipTourTests/ClickElementMCPToolTests.swift`:

  ```swift
  import XCTest
  @testable import TipTour

  @MainActor
  final class ClickElementMCPToolTests: XCTestCase {

      func test_rejects_missing_label() async throws {
          let cm = CompanionManager()  // production init is fine — we don't drive voice
          cm.setHermesGUIAutopilotEnabled(true)
          let tool = ClickElementMCPTool(
              resolver: AccessibilityTreeResolver(),
              companionManager: cm
          )
          do {
              _ = try await tool.call(.object(["bubble": .string("clicking")]))
              XCTFail("expected invalidArguments")
          } catch let MCPToolError.invalidArguments(reason) {
              XCTAssertTrue(reason.contains("label"))
          }
      }

      func test_refuses_when_autopilot_off() async throws {
          let cm = CompanionManager()
          cm.setHermesGUIAutopilotEnabled(false)
          let tool = ClickElementMCPTool(
              resolver: AccessibilityTreeResolver(),
              companionManager: cm
          )
          do {
              _ = try await tool.call(.object([
                  "label": .string("Save"),
                  "bubble": .string("clicking Save"),
              ]))
              XCTFail("expected toolFailed")
          } catch let MCPToolError.toolFailed(reason) {
              XCTAssertTrue(reason.lowercased().contains("autopilot"))
          }
      }

      func test_throws_when_element_not_found() async throws {
          // Use a deliberately garbled label that no app will have. Skip
          // if Accessibility permission isn't granted (CI / headless).
          try XCTSkipUnless(AXIsProcessTrusted(), "AX permission required")
          let cm = CompanionManager()
          cm.setHermesGUIAutopilotEnabled(true)
          let tool = ClickElementMCPTool(
              resolver: AccessibilityTreeResolver(),
              companionManager: cm
          )
          do {
              _ = try await tool.call(.object([
                  "label": .string("zzz_no_element_matches_this_label_zzz"),
                  "bubble": .string("test"),
              ]))
              XCTFail("expected toolFailed")
          } catch let MCPToolError.toolFailed(reason) {
              XCTAssertTrue(reason.contains("no UI element"))
          }
      }
  }
  ```

  Run tests (⌘U). The two non-AX tests should fail-to-compile (no `ClickElementMCPTool` yet) — that's expected.

- [ ] **Step 2: Implement the tool**

  `TipTour/Hermes/ClickElementMCPTool.swift`:

  ```swift
  // TipTour/Hermes/ClickElementMCPTool.swift
  //
  // MCP tool that visibly clicks a labelled UI element. The Arc Reactor
  // cursor flies to the resolved element first (same path as PointAtTool),
  // settles, and then ActionExecutor.shared.click posts the click pair
  // at HID level. Gated by CompanionManager.hermesGUIAutopilotEnabled so
  // Hermes can never click without the user having opted in.
  //
  // Pairs with type_text and press_keyboard_shortcut. For multi-step
  // flows (e.g. fill a form), Hermes is expected to call click_element
  // to focus a field, then type_text to fill it.

  import Foundation
  import AppKit

  @MainActor
  final class ClickElementMCPTool: MCPTool {
      let name = "click_element"
      let description = """
          Click on a labelled UI element. The visible Arc Reactor cursor flies \
          to the target first so the user sees what's about to be clicked, then \
          ~1.1 seconds later the click is posted. Resolves the label via the \
          macOS Accessibility tree. Use get_a11y_tree first to find element \
          labels. Requires the user to have enabled "Hermes can drive my Mac" \
          in the menu bar panel's developer section — when disabled this tool \
          throws an error and the user must opt in before Hermes can click.
          """
      let inputSchema: JSONValue = .object([
          "type": .string("object"),
          "properties": .object([
              "label": .object([
                  "type": .string("string"),
                  "description": .string("Exact or partial label of the UI element to click (case-insensitive)."),
              ]),
              "bubble": .object([
                  "type": .string("string"),
                  "description": .string("Optional text shown in the speech bubble during the flight (≤120 chars). Defaults to \"clicking …\"."),
              ]),
              "app_hint": .object([
                  "type": .string("string"),
                  "description": .string("Optional partial name of the target app (e.g. \"Safari\"). When omitted, uses the frontmost app."),
              ]),
          ]),
          "required": .array([.string("label")]),
      ])

      private let resolver: AccessibilityTreeResolver
      private weak var companionManager: CompanionManager?

      /// Time we wait between starting the flight and posting the click.
      /// The bezier arc in OverlayWindow tops out at ~1.4s for long flights;
      /// 1.1s covers the common case where the target is within a half-screen
      /// hop. Mirrors WorkflowRunner's autopilot delay so the visual cadence
      /// feels consistent across both paths.
      private let preClickFlightSettleSeconds: Double = 1.1

      init(resolver: AccessibilityTreeResolver, companionManager: CompanionManager) {
          self.resolver = resolver
          self.companionManager = companionManager
      }

      func call(_ arguments: JSONValue) async throws -> [MCPToolContent] {
          guard case .object(let dict) = arguments,
                case .string(let label) = dict["label"] ?? .null,
                !label.isEmpty
          else {
              throw MCPToolError.invalidArguments("click_element requires a non-empty `label` string")
          }
          guard let companionManager else {
              throw MCPToolError.toolFailed("companion manager is gone")
          }
          guard companionManager.hermesGUIAutopilotEnabled else {
              throw MCPToolError.toolFailed(
                  "autopilot for Hermes is disabled. Ask the user to enable \"Hermes can drive my Mac\" in the menu bar panel's developer section, then try again."
              )
          }

          let appHint: String? = {
              if case .string(let s) = dict["app_hint"] ?? .null, !s.isEmpty { return s }
              return nil
          }()
          let bubble: String = {
              if case .string(let s) = dict["bubble"] ?? .null, !s.isEmpty { return s }
              return "clicking \(label)"
          }()
          let truncatedBubble = bubble.count > 120 ? String(bubble.prefix(120)) + "…" : bubble

          guard let resolved = resolver.findElement(byLabel: label, targetAppHint: appHint) else {
              throw MCPToolError.toolFailed("no UI element matching label \"\(label)\" was found")
          }

          let center = CGPoint(x: resolved.screenFrame.midX, y: resolved.screenFrame.midY)
          let displayFrame = NSScreen.screens.first(where: { $0.frame.contains(center) })?.frame
              ?? NSScreen.main?.frame
              ?? .zero

          // Trigger the visible flight by setting the @Published vars
          // OverlayWindow watches. Same path PointAtTool uses.
          companionManager.detectedElementScreenLocation = center
          companionManager.detectedElementDisplayFrame = displayFrame
          companionManager.detectedElementBubbleText = truncatedBubble

          // Let the bezier arc land before we post the click. If the user
          // moves their cursor far during this window, OverlayWindow's own
          // return-flight cancel-on-mouse-move logic does not apply (that
          // only triggers on the return flight). Future work: thread a
          // cancellation token through so a user can abort by, e.g.,
          // pressing Esc — see Task 8 follow-ups.
          try? await Task.sleep(nanoseconds: UInt64(preClickFlightSettleSeconds * 1_000_000_000))

          // Resolve the bundle ID → NSRunningApplication so ActionExecutor
          // can activate the right app before clicking. Without this the
          // click can land in the wrong window when the target app isn't
          // frontmost (Apple Forum 724835 — CGEventPostToPid is unreliable;
          // the HID path needs the target activated explicitly).
          let targetApp: NSRunningApplication? = {
              guard let bundleID = resolved.appBundleID else { return nil }
              return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
          }()

          do {
              try await ActionExecutor.shared.click(at: center, activatingTargetApp: targetApp)
          } catch {
              companionManager.clearDetectedElementLocation()
              throw MCPToolError.toolFailed("click failed: \(error.localizedDescription)")
          }

          companionManager.clearDetectedElementLocation()

          return [.text("Clicked \"\(label)\" at \(Int(center.x)),\(Int(center.y))")]
      }
  }
  ```

- [ ] **Step 3: Verify**
  - Build (⌘B). Expect green.
  - Run tests (⌘U). The two non-AX `ClickElementMCPToolTests` should pass. The AX-gated test passes locally when Accessibility is granted, skips otherwise.

---

## Task 3: `TypeTextMCPTool` + tests

**Files:**
- Create: `TipTour/Hermes/TypeTextMCPTool.swift`
- Create: `TipTourTests/TypeTextMCPToolTests.swift`

Types text into whatever currently has keyboard focus. No cursor flight — typing isn't a spatial gesture. Hermes is expected to call `click_element` on the target field first to ensure focus.

- [ ] **Step 1: Write the failing tests**

  `TipTourTests/TypeTextMCPToolTests.swift`:

  ```swift
  import XCTest
  @testable import TipTour

  @MainActor
  final class TypeTextMCPToolTests: XCTestCase {

      func test_rejects_missing_text() async throws {
          let cm = CompanionManager()
          cm.setHermesGUIAutopilotEnabled(true)
          let tool = TypeTextMCPTool(companionManager: cm)
          do {
              _ = try await tool.call(.object([:]))
              XCTFail("expected invalidArguments")
          } catch let MCPToolError.invalidArguments(reason) {
              XCTAssertTrue(reason.contains("text"))
          }
      }

      func test_refuses_when_autopilot_off() async throws {
          let cm = CompanionManager()
          cm.setHermesGUIAutopilotEnabled(false)
          let tool = TypeTextMCPTool(companionManager: cm)
          do {
              _ = try await tool.call(.object(["text": .string("hello")]))
              XCTFail("expected toolFailed")
          } catch let MCPToolError.toolFailed(reason) {
              XCTAssertTrue(reason.lowercased().contains("autopilot"))
          }
      }
  }
  ```

- [ ] **Step 2: Implement the tool**

  `TipTour/Hermes/TypeTextMCPTool.swift`:

  ```swift
  // TipTour/Hermes/TypeTextMCPTool.swift
  //
  // MCP tool that types a string into whatever currently has keyboard
  // focus, using ActionExecutor's pasteboard-staging + Cmd+V path
  // (layout-agnostic, fast for long strings, restores the user's
  // clipboard after). Gated by CompanionManager.hermesGUIAutopilotEnabled.
  //
  // Pairs with click_element. Hermes is expected to call click_element
  // first to focus the target field, then type_text to fill it.

  import Foundation
  import AppKit

  @MainActor
  final class TypeTextMCPTool: MCPTool {
      let name = "type_text"
      let description = """
          Type text into the currently focused field. Uses pasteboard staging \
          + Cmd+V (layout-agnostic, fast for long strings). The user's \
          clipboard contents are saved before and restored after. Call \
          click_element on the target field first to ensure focus. \
          Requires the user to have enabled "Hermes can drive my Mac" in the \
          menu bar panel.
          """
      let inputSchema: JSONValue = .object([
          "type": .string("object"),
          "properties": .object([
              "text": .object([
                  "type": .string("string"),
                  "description": .string("The text to type into the focused field. Multi-line is supported."),
              ]),
              "app_hint": .object([
                  "type": .string("string"),
                  "description": .string("Optional bundle id or partial name of the app to activate before typing. When omitted, uses the frontmost app."),
              ]),
          ]),
          "required": .array([.string("text")]),
      ])

      private weak var companionManager: CompanionManager?

      init(companionManager: CompanionManager) {
          self.companionManager = companionManager
      }

      func call(_ arguments: JSONValue) async throws -> [MCPToolContent] {
          guard case .object(let dict) = arguments,
                case .string(let text) = dict["text"] ?? .null,
                !text.isEmpty
          else {
              throw MCPToolError.invalidArguments("type_text requires a non-empty `text` string")
          }
          guard let companionManager else {
              throw MCPToolError.toolFailed("companion manager is gone")
          }
          guard companionManager.hermesGUIAutopilotEnabled else {
              throw MCPToolError.toolFailed(
                  "autopilot for Hermes is disabled. Ask the user to enable \"Hermes can drive my Mac\" in the menu bar panel's developer section, then try again."
              )
          }

          let appHint: String? = {
              if case .string(let s) = dict["app_hint"] ?? .null, !s.isEmpty { return s }
              return nil
          }()
          let targetApp: NSRunningApplication? = appHint.flatMap { Self.resolveApp(hint: $0) }

          do {
              try await ActionExecutor.shared.typeText(text, activatingTargetApp: targetApp)
          } catch {
              throw MCPToolError.toolFailed("type failed: \(error.localizedDescription)")
          }

          return [.text("Typed \(text.count) characters")]
      }

      /// Resolve an `app_hint` to an `NSRunningApplication` using two
      /// strategies: exact bundle-id match first, then a localized-name
      /// substring match. Matches PointAtTool's hint semantics so Hermes
      /// can pass the same string ("Safari", "com.apple.Safari",
      /// "Notion") to either tool.
      private static func resolveApp(hint: String) -> NSRunningApplication? {
          let byBundle = NSRunningApplication.runningApplications(withBundleIdentifier: hint)
          if let first = byBundle.first { return first }
          let lowered = hint.lowercased()
          return NSWorkspace.shared.runningApplications.first {
              ($0.localizedName ?? "").lowercased().contains(lowered)
          }
      }
  }
  ```

- [ ] **Step 3: Verify**
  - Build (⌘B). Expect green.
  - Run tests (⌘U). Both `TypeTextMCPToolTests` should pass.

---

## Task 4: `PressKeyboardShortcutMCPTool` + tests

**Files:**
- Create: `TipTour/Hermes/PressKeyboardShortcutMCPTool.swift`
- Create: `TipTourTests/PressKeyboardShortcutMCPToolTests.swift`

Posts a keyboard shortcut (Cmd+S, Return, etc.) via `ActionExecutor.pressKeyboardShortcut`. The executor handles parsing — we just pass the string through. Gated by the autopilot flag.

- [ ] **Step 1: Write the failing tests**

  `TipTourTests/PressKeyboardShortcutMCPToolTests.swift`:

  ```swift
  import XCTest
  @testable import TipTour

  @MainActor
  final class PressKeyboardShortcutMCPToolTests: XCTestCase {

      func test_rejects_missing_shortcut() async throws {
          let cm = CompanionManager()
          cm.setHermesGUIAutopilotEnabled(true)
          let tool = PressKeyboardShortcutMCPTool(companionManager: cm)
          do {
              _ = try await tool.call(.object([:]))
              XCTFail("expected invalidArguments")
          } catch let MCPToolError.invalidArguments(reason) {
              XCTAssertTrue(reason.contains("shortcut"))
          }
      }

      func test_refuses_when_autopilot_off() async throws {
          let cm = CompanionManager()
          cm.setHermesGUIAutopilotEnabled(false)
          let tool = PressKeyboardShortcutMCPTool(companionManager: cm)
          do {
              _ = try await tool.call(.object(["shortcut": .string("Cmd+S")]))
              XCTFail("expected toolFailed")
          } catch let MCPToolError.toolFailed(reason) {
              XCTAssertTrue(reason.lowercased().contains("autopilot"))
          }
      }
  }
  ```

- [ ] **Step 2: Implement the tool**

  `TipTour/Hermes/PressKeyboardShortcutMCPTool.swift`:

  ```swift
  // TipTour/Hermes/PressKeyboardShortcutMCPTool.swift
  //
  // MCP tool that posts a keyboard shortcut. ActionExecutor.pressKeyboardShortcut
  // parses strings like "Cmd+S", "Cmd+Shift+N", "Return", and posts virtual
  // key codes via CGEvent at HID level. GUIActionMutex serialises with
  // concurrent click/type calls. Gated by CompanionManager.hermesGUIAutopilotEnabled.

  import Foundation
  import AppKit

  @MainActor
  final class PressKeyboardShortcutMCPTool: MCPTool {
      let name = "press_keyboard_shortcut"
      let description = """
          Press a keyboard shortcut like "Cmd+S", "Cmd+Shift+N", "Return", \
          "Esc". Modifiers (Cmd, Ctrl, Option, Shift) can appear in any order, \
          plus-separated. Useful for save/quit/new-tab/etc. \
          Requires the user to have enabled "Hermes can drive my Mac" in the \
          menu bar panel.
          """
      let inputSchema: JSONValue = .object([
          "type": .string("object"),
          "properties": .object([
              "shortcut": .object([
                  "type": .string("string"),
                  "description": .string("The shortcut string, e.g. \"Cmd+S\", \"Cmd+Shift+T\", \"Return\"."),
              ]),
              "app_hint": .object([
                  "type": .string("string"),
                  "description": .string("Optional bundle id or partial name of the app to activate before posting. When omitted, the shortcut goes to the frontmost app."),
              ]),
          ]),
          "required": .array([.string("shortcut")]),
      ])

      private weak var companionManager: CompanionManager?

      init(companionManager: CompanionManager) {
          self.companionManager = companionManager
      }

      func call(_ arguments: JSONValue) async throws -> [MCPToolContent] {
          guard case .object(let dict) = arguments,
                case .string(let shortcut) = dict["shortcut"] ?? .null,
                !shortcut.isEmpty
          else {
              throw MCPToolError.invalidArguments("press_keyboard_shortcut requires a non-empty `shortcut` string")
          }
          guard let companionManager else {
              throw MCPToolError.toolFailed("companion manager is gone")
          }
          guard companionManager.hermesGUIAutopilotEnabled else {
              throw MCPToolError.toolFailed(
                  "autopilot for Hermes is disabled. Ask the user to enable \"Hermes can drive my Mac\" in the menu bar panel's developer section, then try again."
              )
          }

          let appHint: String? = {
              if case .string(let s) = dict["app_hint"] ?? .null, !s.isEmpty { return s }
              return nil
          }()
          let targetApp: NSRunningApplication? = appHint.flatMap { Self.resolveApp(hint: $0) }

          do {
              try await ActionExecutor.shared.pressKeyboardShortcut(shortcut, activatingTargetApp: targetApp)
          } catch {
              throw MCPToolError.toolFailed("press shortcut failed: \(error.localizedDescription)")
          }

          return [.text("Pressed \(shortcut)")]
      }

      private static func resolveApp(hint: String) -> NSRunningApplication? {
          let byBundle = NSRunningApplication.runningApplications(withBundleIdentifier: hint)
          if let first = byBundle.first { return first }
          let lowered = hint.lowercased()
          return NSWorkspace.shared.runningApplications.first {
              ($0.localizedName ?? "").lowercased().contains(lowered)
          }
      }
  }
  ```

- [ ] **Step 3: Verify**
  - Build (⌘B). Expect green.
  - Run tests (⌘U). Both `PressKeyboardShortcutMCPToolTests` should pass.

> **Refactor opportunity (defer):** `TypeTextMCPTool` and `PressKeyboardShortcutMCPTool` both define an identical `resolveApp(hint:)`. Leave the duplication for now — extracting a shared helper before there are three call sites would be premature.

---

## Task 5: Register the three new tools in `CompanionManager`

**Files:**
- Modify: `TipTour/CompanionManager.swift`

Three new `mcpServer.register(...)` lines at the existing registration site.

- [ ] **Step 1: Add the registrations**

  Find the block around `CompanionManager.swift:415` that currently reads:

  ```swift
  mcpServer.register(ScreenshotTool())
  mcpServer.register(A11yTreeTool(resolver: resolver))
  mcpServer.register(PointAtTool(resolver: resolver, companionManager: self))
  ```

  Append three lines:

  ```swift
  mcpServer.register(ScreenshotTool())
  mcpServer.register(A11yTreeTool(resolver: resolver))
  mcpServer.register(PointAtTool(resolver: resolver, companionManager: self))
  mcpServer.register(ClickElementMCPTool(resolver: resolver, companionManager: self))
  mcpServer.register(TypeTextMCPTool(companionManager: self))
  mcpServer.register(PressKeyboardShortcutMCPTool(companionManager: self))
  ```

- [ ] **Step 2: Verify**
  - Build (⌘B). Expect green.
  - Run the app (⌘R). The new tools should be discoverable by Hermes — see Task 6 for the end-to-end check.

---

## Task 6: End-to-end manual test

This task has no source code changes. It verifies the wiring in a real Hermes session.

- [ ] **Step 1: Confirm tools appear in `tools/list`**

  - Run the app (⌘R).
  - Open the Hermes chat window (footer button in the menu bar panel).
  - In the chat, ask: "list your MCP tools".
  - Expected: Hermes responds with at least these six tools: `take_screenshot`, `get_a11y_tree`, `point_at`, `click_element`, `type_text`, `press_keyboard_shortcut`.

- [ ] **Step 2: Autopilot off — destructive tools refuse**

  - Confirm "Hermes can drive my Mac" is OFF in the dev section.
  - Ask Hermes: "click the Apple menu in the menu bar".
  - Expected: Hermes calls `click_element`, gets back the autopilot-disabled error, and tells the user (in plain language) to enable autopilot.

- [ ] **Step 3: Autopilot on — click succeeds with visible flight**

  - Open a known target app (e.g. Safari, with a clear "Reload" button visible).
  - Toggle "Hermes can drive my Mac" ON.
  - Ask Hermes: "in Safari, click the reload button".
  - Expected:
    1. Hermes calls `get_a11y_tree` (to find the label).
    2. Hermes calls `click_element` with `label: "Reload"`, `app_hint: "Safari"`.
    3. The glow cursor visibly flies from the user's mouse position to the Reload button (~1s).
    4. The click lands on Reload — Safari reloads the page.

- [ ] **Step 4: Type into a field**

  - Open TextEdit, create a new document, focus the document.
  - Ask Hermes: "type 'hello from hermes' into the document".
  - Expected: Hermes calls `type_text` (possibly preceded by a `click_element` on the document body if it isn't focused). The text appears. The user's clipboard is unchanged (verify with ⌘V into another field afterwards).

- [ ] **Step 5: Keyboard shortcut**

  - Still in TextEdit with the text above.
  - Ask Hermes: "save this document with Cmd+S".
  - Expected: Hermes calls `press_keyboard_shortcut` with `shortcut: "Cmd+S"`. The save dialog appears.

- [ ] **Step 6: Concurrent stress check (optional)**

  - With autopilot on, start a voice-mode workflow (Ctrl+Option → "open the App Store and search for Xcode") AND simultaneously ask Hermes via the chat to click something.
  - Expected: clicks serialize correctly via `GUIActionMutex` — no interleaved/phantom clicks. The cursor flights may visibly queue but never overlap at the HID layer.

---

## Task 7: Documentation — update `AGENTS.md`

**Files:**
- Modify: `AGENTS.md` (note: `CLAUDE.md` is a symlink to this file)

- [ ] **Step 1: Add Key Files rows**

  Find the existing rows for `PointAtTool.swift` / `ScreenshotTool.swift` / `A11yTreeTool.swift` in the Key Files table and add three new rows right after them:

  ```
  | `TipTour/Hermes/ClickElementMCPTool.swift` | ~110 | MCP tool — `click_element`. Resolves a label via `AccessibilityTreeResolver`, visibly flies the glow cursor (same path as `PointAtTool` — sets `CompanionManager.detectedElement*` @Published vars that `OverlayWindow` watches), settles ~1.1s, then calls `ActionExecutor.shared.click` (HID-level CGEvent inside `GUIActionMutex`). Refuses early when `CompanionManager.hermesGUIAutopilotEnabled` is false. Maps the resolver's `appBundleID` → `NSRunningApplication.runningApplications(withBundleIdentifier:).first` so the click activates the right app. |
  | `TipTour/Hermes/TypeTextMCPTool.swift` | ~75 | MCP tool — `type_text`. Calls `ActionExecutor.shared.typeText` (pasteboard staging + Cmd+V, layout-agnostic, clipboard restored). No cursor flight — typing isn't spatial. Optional `app_hint` resolves to `NSRunningApplication` via bundle-id then localized-name substring. Gated by `hermesGUIAutopilotEnabled`. |
  | `TipTour/Hermes/PressKeyboardShortcutMCPTool.swift` | ~75 | MCP tool — `press_keyboard_shortcut`. Passes the shortcut string straight to `ActionExecutor.shared.pressKeyboardShortcut` (which parses "Cmd+S" / "Cmd+Shift+T" / "Return" / etc. and posts virtual key codes at HID level). Same `app_hint` resolution as `TypeTextMCPTool`. Gated by `hermesGUIAutopilotEnabled`. |
  ```

- [ ] **Step 2: Update the Architecture section**

  In the existing bullet that describes MCP tools exposed to Hermes (search for "screenshot, ax_tree, point_at" or similar), append:

  > Plan 7 (this plan) adds three destructive MCP tools — `click_element`, `type_text`, `press_keyboard_shortcut` — gated by `CompanionManager.hermesGUIAutopilotEnabled` (default off). The flag is exposed in the menu bar panel's developer section as "Hermes can drive my Mac". When Plan 6 (Guardrails) ships, this flag is replaced by `GuardrailsDecider` — see Task 8 of Plan 7 for the migration steps.

- [ ] **Step 3: Verify**

  Open `AGENTS.md`, confirm the new rows render correctly in the markdown preview.

---

## Task 8: Forward-compat — migration path once Plan 6 (Guardrails) ships

This task does NOT execute as part of Plan 7. It's a written record of how Plan 7's temporary gate gets retired once Plan 6 lands. Implementors of Plan 6 should follow these steps as the final sub-task of that plan.

- [ ] **Step 1: Promote the three destructive tools to a `MCPToolSafetyTier`**

  When Plan 6 introduces `MCPToolSafetyTier` (an enum on `MCPTool`), tag the three destructive tools as `.destructive`. Existing observational tools become `.observational`; `PointAtTool` becomes `.visualOnly`.

- [ ] **Step 2: Route through `GuardrailsDecider` inside `MCPServer.handleToolsCall`**

  Before invoking `tool.call(arguments)` for a `.destructive` tool, consult `GuardrailsDecider`. The decider returns `.allow` / `.deny` / `.askUser`; `.askUser` triggers the `ApprovalSheetView` flow per Plan 6's design.

- [ ] **Step 3: Remove the `hermesGUIAutopilotEnabled` flag**

  - Delete the `@Published var hermesGUIAutopilotEnabled` and its setter from `CompanionManager`.
  - Delete the `hermesGUIAutopilotRow` from `CompanionPanelView`.
  - Delete the three `guard companionManager.hermesGUIAutopilotEnabled else { ... }` blocks in the destructive MCP tools — replaced by the safety-tier gate in `MCPServer`.
  - Remove the `UserDefaults` key `"hermesGUIAutopilotEnabled"` from any documentation.

- [ ] **Step 4: One-time UserDefaults migration**

  In `CompanionManager.init`, if the user had `hermesGUIAutopilotEnabled = true` previously, seed `GuardrailsStore` with `allow` decisions for `click_element` / `type_text` / `press_keyboard_shortcut` so the user doesn't see three approval sheets the first time after the upgrade. Then clear the legacy key.

  ```swift
  // Run once at launch, then clear so it never re-fires.
  if UserDefaults.standard.bool(forKey: "hermesGUIAutopilotEnabled") {
      Task { @MainActor in
          await guardrailsStore.remember(.allow, for: "click_element")
          await guardrailsStore.remember(.allow, for: "type_text")
          await guardrailsStore.remember(.allow, for: "press_keyboard_shortcut")
          UserDefaults.standard.removeObject(forKey: "hermesGUIAutopilotEnabled")
      }
  }
  ```

- [ ] **Step 5: Update `AGENTS.md`**

  Remove the Task 7 paragraph mentioning the temporary flag; replace with the final guardrails-based description.

---

## Out of scope

The following are deliberately NOT part of this plan, even though they're tempting and adjacent:

- **`click_at_coordinates(x, y)`** — a no-fly, raw-coords clicker. Adds value for non-AX-discoverable UI (canvases, custom-drawn controls) but skips the visible-flight transparency users will rely on. Defer until there's a concrete need.
- **`drag(from:, to:)` / `scroll(at:, direction:, amount:)`** — drag and scroll primitives. `ActionExecutor` doesn't expose them today; adding them is its own design conversation.
- **In-flight cancellation (Esc to abort)** — currently the user has the ~1.1s flight window to see what's about to be clicked, but no kill switch. Worth adding once we have a Hermes-driven workflow long enough to warrant it; rough sketch is a `cancelHermesFlightToken` published var on `CompanionManager` that the click step checks before posting the HID event.
- **Per-app autopilot scoping** — "Hermes can click in Safari but not Slack". Better solved by Plan 6's `GuardrailsDecider` (which has per-tool granularity but not per-app); per-app would be a Plan 6 extension if/when needed.
- **Audit trail of every Hermes click** — a log file or transcript entry. The chat transcript already shows each tool call result; a separate log is overkill for v1.

---

## Failure modes the implementor should know about

- **Permissions:** all three tools require Accessibility permission for the host process (granted on first cursor-move attempt; persists). `ActionExecutor` already throws a clear error if it's missing — surfaced as `MCPToolError.toolFailed("...accessibility...")`.
- **App focus race:** `ActionExecutor.click` activates the target app then sleeps `postActivationSettleSeconds` (0.1s) before posting the click. If the target app is unresponsive, the activation may not have taken effect; the click can land in the wrong window. Mitigation in v1: nothing — Hermes will see the unexpected result via the next screenshot and re-plan. Future work: post-click AX-fingerprint validation like `WorkflowRunner` does.
- **`app_hint` ambiguity:** "Mail" matches both Apple Mail and any app whose name contains "mail" (e.g. "MailMate"). The `resolveApp(hint:)` helper takes the first match. For exact targeting, pass the full bundle ID.
- **Long `text` strings:** `ActionExecutor.typeText` stages the entire string on the pasteboard. Limited by NSPasteboard's practical limits (multi-MB strings work but are slow). No additional limit in this plan.

---

## Acceptance criteria

All of these must be true for the plan to be considered done:

- [ ] All three test files pass `⌘U` locally with Accessibility permission granted.
- [ ] The dev-panel toggle "Hermes can drive my Mac" exists, defaults off, and persists across restarts.
- [ ] With autopilot off, all three destructive MCP tools throw `MCPToolError.toolFailed` immediately, mentioning "autopilot" in the error message.
- [ ] With autopilot on, the Task 6 manual flow works end-to-end: glow cursor flies, click lands, text types, shortcut fires.
- [ ] `AGENTS.md` documents the three new files and the temporary flag.
- [ ] No existing tests regress.
- [ ] No new Swift 6 concurrency warnings introduced (the existing known warnings are fine).
