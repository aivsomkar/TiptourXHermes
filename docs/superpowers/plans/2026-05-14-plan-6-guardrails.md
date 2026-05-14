# Plan 6 — Guardrails (per-tool approval prompt + persistence) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `HermesClient`'s "auto-allow everything" with a real approval modal + persisted decisions. Users see a SwiftUI sheet on each `session/request_permission` from Hermes (except for our own MCP tools, which auto-allow). "Allow Always" / "Deny Always" choices persist to `~/.hermes/guardrails.json` and are managed via a new Guardrails tab in Settings.

**Architecture:** A pure `GuardrailsDecider` consults `GuardrailsStore` (JSON-backed, atomic write-tmp-then-rename) and a live MCP-tool allow-list, returning one of three outcomes: allow / deny / askUser. The askUser path carries a callback closure; `HermesClient` invokes it via a `GuardrailsApprovalDelegate` protocol implemented by `HermesChatView`. The chat view shows `ApprovalSheetView` and responds back. A NotificationCenter event auto-opens the chat window when a permission ask arrives with no open host.

**Tech Stack:** Swift / SwiftUI / AppKit on macOS, `FileManager.replaceItem` for atomic writes, `Codable` for JSON, existing `JarvisSectionHeader` + `JarvisButton` design primitives, XCTest.

**Spec:** [docs/superpowers/specs/2026-05-14-plan-6-guardrails-design.md](../specs/2026-05-14-plan-6-guardrails-design.md)

---

## File map

**Create:**

- `TipTour/Settings/GuardrailsStore.swift` — JSON-backed store at `~/.hermes/guardrails.json`. `Decision` enum (allow/deny). Atomic write-tmp-then-rename. Mirrors `HermesMemoryStore` / `HermesSoulStore`.
- `TipTour/Hermes/GuardrailsDecider.swift` — `ApprovalRequest` struct, `GuardrailsOutcome` enum, `GuardrailsApprovalDelegate` protocol, `GuardrailsDecider` struct. Pure logic.
- `TipTour/Hermes/ApprovalSheetView.swift` — SwiftUI sheet with tool name, args summary, expandable raw-args disclosure, 4 buttons.
- `TipTour/Settings/GuardrailsTabView.swift` — Settings tab listing remembered decisions with Revoke + Reset All.
- `TipTourTests/GuardrailsStoreTests.swift`
- `TipTourTests/GuardrailsDeciderTests.swift`

**Modify:**

- `TipTour/Hermes/HermesClient.swift` — Replace auto-allow in `handleServerRequest`. Add `var approvalDelegate: GuardrailsApprovalDelegate?` and `var guardrailsDecider: GuardrailsDecider` properties.
- `TipTour/Hermes/HermesChatWindow.swift` — `HermesChatView` conforms to `GuardrailsApprovalDelegate`. Owns `@State var pendingApproval: ApprovalRequest?`. Presents `.sheet(item: $pendingApproval) { ApprovalSheetView(...) }`.
- `TipTour/Hermes/HermesDebugMenuController.swift` — Listen for `Notification.Name.tipTourPermissionRequested` → call `openChat()` if window is closed.
- `TipTour/MenuBarPanelManager.swift` — Add `static let tipTourPermissionRequested = Notification.Name("tipTourPermissionRequested")` to the existing extension.
- `TipTour/Settings/SettingsSheetView.swift` — Add `case guardrails` to `Tab` enum + tab-bar button + switch case for `GuardrailsTabView`.
- `AGENTS.md` — Document the new files + a Guardrails architecture bullet.

**Not changed:**

- `TipTour/Hermes/HermesACPProtocol.swift` — `PermissionResponse` + `PermissionOutcome` already accept any `optionId` string. No protocol changes.

---

## Build / test conventions

This is an Xcode project. Do NOT run `xcodebuild` from the terminal — it invalidates TCC permissions per `CLAUDE.md`. Each task that has a build verification step uses Xcode directly:

- **Build:** in Xcode, select the `TipTour` scheme, ⌘B. Expected: green build, no errors.
- **Run tests:** ⌘U. Expected: all green except live tests gated by `try XCTSkipUnless`.
- **Run the app:** ⌘R. The app appears in the menu bar.

---

## Task 1: GuardrailsStore + tests

**Files:**
- Create: `TipTour/Settings/GuardrailsStore.swift`
- Create: `TipTourTests/GuardrailsStoreTests.swift`

Plain JSON file at `~/.hermes/guardrails.json` mapping tool name → "allow" | "deny". Same atomic-write pattern as `HermesMemoryStore`. No-op missing/corrupt file: callers get empty map, never a crash.

- [ ] **Step 1: Write the failing tests**

Create `TipTourTests/GuardrailsStoreTests.swift`:

```swift
import XCTest
@testable import TipTour

final class GuardrailsStoreTests: XCTestCase {

    private var tempHome: URL!

    override func setUpWithError() throws {
        tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("hermes-guardrails-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let url = tempHome { try? FileManager.default.removeItem(at: url) }
    }

    func testDecisionForMissingFileReturnsNil() {
        let store = GuardrailsStore(hermesHome: tempHome)
        XCTAssertNil(store.decision(forTool: "run_shell_command"))
    }

    func testSetThenDecisionRoundTrips() throws {
        let store = GuardrailsStore(hermesHome: tempHome)
        try store.setDecision(.allow, forTool: "run_shell_command")
        XCTAssertEqual(store.decision(forTool: "run_shell_command"), .allow)
        try store.setDecision(.deny, forTool: "web_fetch")
        XCTAssertEqual(store.decision(forTool: "web_fetch"), .deny)
        XCTAssertEqual(store.decision(forTool: "run_shell_command"), .allow)
    }

    func testRemoveDropsTheEntry() throws {
        let store = GuardrailsStore(hermesHome: tempHome)
        try store.setDecision(.allow, forTool: "run_shell_command")
        try store.remove(toolName: "run_shell_command")
        XCTAssertNil(store.decision(forTool: "run_shell_command"))
    }

    func testAllDecisionsReturnsMap() throws {
        let store = GuardrailsStore(hermesHome: tempHome)
        try store.setDecision(.allow, forTool: "run_shell_command")
        try store.setDecision(.deny, forTool: "web_fetch")
        let all = store.allDecisions()
        XCTAssertEqual(all["run_shell_command"], .allow)
        XCTAssertEqual(all["web_fetch"], .deny)
        XCTAssertEqual(all.count, 2)
    }

    func testWriteIsIdempotent() throws {
        let store = GuardrailsStore(hermesHome: tempHome)
        try store.setDecision(.allow, forTool: "run_shell_command")
        let first = try Data(contentsOf: store.filePath)
        try store.setDecision(.allow, forTool: "run_shell_command")
        let second = try Data(contentsOf: store.filePath)
        XCTAssertEqual(first, second)
    }

    func testNoTmpStragglersAfterWrite() throws {
        let store = GuardrailsStore(hermesHome: tempHome)
        try store.setDecision(.allow, forTool: "run_shell_command")
        let dir = store.filePath.deletingLastPathComponent()
        let contents = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        let stragglers = contents.filter { $0.lastPathComponent.hasSuffix(".tmp") }
        XCTAssertTrue(stragglers.isEmpty,
                      "leftover .tmp files: \(stragglers.map(\.lastPathComponent))")
    }

    func testCorruptJSONReturnsEmptyWithoutCrash() throws {
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
        let store = GuardrailsStore(hermesHome: tempHome)
        // Write malformed JSON into the file.
        try "not valid json {{{".write(to: store.filePath, atomically: true, encoding: .utf8)
        XCTAssertEqual(store.allDecisions(), [:])
        XCTAssertNil(store.decision(forTool: "anything"))
    }
}
```

- [ ] **Step 2: Run the tests (will fail to compile — type doesn't exist yet)**

In Xcode, ⌘U. Expected: build error `cannot find 'GuardrailsStore' in scope`.

- [ ] **Step 3: Implement GuardrailsStore**

Create `TipTour/Settings/GuardrailsStore.swift`:

```swift
// TipTour/Settings/GuardrailsStore.swift
//
// JSON-backed store of remembered Allow/Deny decisions per tool name.
// Atomic write-tmp-then-rename so Hermes never sees a partial file
// even if it has its own writer racing ours (which it doesn't, but
// the pattern matches HermesMemoryStore / HermesSoulStore for
// consistency).
//
// File layout: ~/.hermes/guardrails.json
//   {"run_shell_command": "allow", "web_fetch": "deny"}

import Foundation

struct GuardrailsStore {

    enum Decision: String, Codable {
        case allow
        case deny
    }

    let hermesHome: URL

    init(hermesHome: URL? = nil) {
        self.hermesHome = hermesHome
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".hermes", isDirectory: true)
    }

    var filePath: URL {
        hermesHome.appendingPathComponent("guardrails.json")
    }

    /// Returns the remembered decision for `name`, or nil if no rule.
    func decision(forTool name: String) -> Decision? {
        allDecisions()[name]
    }

    /// Returns every remembered decision. Empty map if file missing or
    /// corrupt (logged warning, never throws).
    func allDecisions() -> [String: Decision] {
        guard let data = try? Data(contentsOf: filePath) else { return [:] }
        do {
            return try JSONDecoder().decode([String: Decision].self, from: data)
        } catch {
            NSLog("[GuardrailsStore] ⚠️ corrupt JSON at %@ — treating as empty", filePath.path)
            return [:]
        }
    }

    /// Sets (or overwrites) the decision for `name`. Idempotent.
    func setDecision(_ decision: Decision, forTool name: String) throws {
        var map = allDecisions()
        map[name] = decision
        try writeAtomically(map)
    }

    /// Removes any remembered decision for `name`. No-op if absent.
    func remove(toolName name: String) throws {
        var map = allDecisions()
        guard map.removeValue(forKey: name) != nil else { return }
        try writeAtomically(map)
    }

    // MARK: - private

    private func writeAtomically(_ map: [String: Decision]) throws {
        try FileManager.default.createDirectory(
            at: hermesHome, withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(map)
        let tmp = hermesHome.appendingPathComponent(".guardrails.json.\(UUID().uuidString).tmp")
        try data.write(to: tmp, options: .atomic)
        do {
            try FileManager.default.replaceItem(
                at: filePath,
                withItemAt: tmp,
                backupItemName: nil,
                options: [],
                resultingItemURL: nil
            )
        } catch CocoaError.fileNoSuchFile {
            try FileManager.default.moveItem(at: tmp, to: filePath)
        }
    }
}
```

- [ ] **Step 4: Run the tests; verify all 7 pass**

In Xcode, ⌘U. Expected: 7/7 GuardrailsStoreTests pass.

- [ ] **Step 5: Commit**

```bash
git add TipTour/Settings/GuardrailsStore.swift \
        TipTourTests/GuardrailsStoreTests.swift
git commit -m "feat(guardrails): GuardrailsStore atomic-rename read/write for ~/.hermes/guardrails.json"
```

---

## Task 2: GuardrailsDecider + tests

**Files:**
- Create: `TipTour/Hermes/GuardrailsDecider.swift`
- Create: `TipTourTests/GuardrailsDeciderTests.swift`

Pure decision logic. Defines `ApprovalRequest`, `GuardrailsOutcome`, `GuardrailsApprovalDelegate`, and the `GuardrailsDecider` struct itself. Tests inject a fake MCP allow-list provider + a temp HermesHome.

- [ ] **Step 1: Write the failing tests**

Create `TipTourTests/GuardrailsDeciderTests.swift`:

```swift
import XCTest
@testable import TipTour

final class GuardrailsDeciderTests: XCTestCase {

    private var tempHome: URL!

    override func setUpWithError() throws {
        tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("guardrails-decider-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let url = tempHome { try? FileManager.default.removeItem(at: url) }
    }

    /// Build a decider with an injected MCP allow-list + the temp store.
    private func makeDecider(mcpToolNames: Set<String>) -> GuardrailsDecider {
        let store = GuardrailsStore(hermesHome: tempHome)
        return GuardrailsDecider(store: store, mcpToolNamesProvider: { mcpToolNames })
    }

    func testMCPToolReturnsAllowImmediately() {
        let decider = makeDecider(mcpToolNames: ["point_at", "take_screenshot"])
        let outcome = decider.decide(
            requestID: "rq-1",
            toolName: "point_at",
            args: ["label": "Save"]
        )
        guard case .allowImmediately = outcome else {
            return XCTFail("expected .allowImmediately for MCP tool, got \(outcome)")
        }
    }

    func testRememberedAllowReturnsAllowImmediately() throws {
        let store = GuardrailsStore(hermesHome: tempHome)
        try store.setDecision(.allow, forTool: "run_shell_command")
        let decider = makeDecider(mcpToolNames: [])
        let outcome = decider.decide(
            requestID: "rq-1",
            toolName: "run_shell_command",
            args: ["command": "ls"]
        )
        guard case .allowImmediately = outcome else {
            return XCTFail("expected .allowImmediately for remembered allow, got \(outcome)")
        }
    }

    func testRememberedDenyReturnsDenyImmediately() throws {
        let store = GuardrailsStore(hermesHome: tempHome)
        try store.setDecision(.deny, forTool: "web_fetch")
        let decider = makeDecider(mcpToolNames: [])
        let outcome = decider.decide(
            requestID: "rq-1",
            toolName: "web_fetch",
            args: ["url": "https://example.com"]
        )
        guard case .denyImmediately = outcome else {
            return XCTFail("expected .denyImmediately for remembered deny, got \(outcome)")
        }
    }

    func testUnknownToolReturnsAskUserWithCorrectFields() {
        let decider = makeDecider(mcpToolNames: [])
        let outcome = decider.decide(
            requestID: "rq-42",
            toolName: "write_text_file",
            args: ["path": "/tmp/x", "content": "hello"]
        )
        guard case .askUser(let request) = outcome else {
            return XCTFail("expected .askUser, got \(outcome)")
        }
        XCTAssertEqual(request.id, "rq-42")
        XCTAssertEqual(request.toolName, "write_text_file")
        XCTAssertTrue(request.argsSummary.contains("path"))
        XCTAssertTrue(request.argsFullJSON.contains("hello"))
    }

    func testMCPAllowListIsConsultedFromInjectedProvider() {
        var allowedNames: Set<String> = ["point_at"]
        let store = GuardrailsStore(hermesHome: tempHome)
        let decider = GuardrailsDecider(store: store, mcpToolNamesProvider: { allowedNames })
        // First call: point_at is in the allow-list → allow.
        var outcome = decider.decide(requestID: "rq-1", toolName: "point_at", args: [:])
        guard case .allowImmediately = outcome else {
            return XCTFail("expected allow for point_at in list, got \(outcome)")
        }
        // Mutate the source-of-truth — decider should pick up the change live.
        allowedNames = []
        outcome = decider.decide(requestID: "rq-2", toolName: "point_at", args: [:])
        guard case .askUser = outcome else {
            return XCTFail("expected askUser after removing point_at from list, got \(outcome)")
        }
    }

    func testMalformedArgsDoNotCrash() {
        let decider = makeDecider(mcpToolNames: [])
        // args dict contains a value that JSONSerialization would reject
        // (NaN as a Double isn't valid JSON) — the decider's argsFullJSON
        // builder must not crash.
        let outcome = decider.decide(
            requestID: "rq-1",
            toolName: "unknown_tool",
            args: ["bad": Double.nan]
        )
        guard case .askUser(let request) = outcome else {
            return XCTFail("expected askUser, got \(outcome)")
        }
        // Allow either a graceful "unrepresentable" stub or just an empty
        // dict — what matters is no crash.
        XCTAssertNotNil(request.argsFullJSON)
    }
}
```

- [ ] **Step 2: Run the tests (will fail to compile — types don't exist yet)**

In Xcode, ⌘U. Expected: build errors on `GuardrailsDecider`, `ApprovalRequest`, `GuardrailsOutcome`.

- [ ] **Step 3: Implement GuardrailsDecider**

Create `TipTour/Hermes/GuardrailsDecider.swift`:

```swift
// TipTour/Hermes/GuardrailsDecider.swift
//
// Pure decision logic for permission requests. Given a tool name + args,
// returns one of:
//   .allowImmediately    — MCP tool we control, OR user has chosen
//                          "Allow Always" for this tool name
//   .denyImmediately     — user has chosen "Deny Always" for this tool
//   .askUser(request)    — no rule + not an MCP tool; UI should prompt
//
// The askUser path carries an ApprovalRequest whose onDecision closure
// captures the request id so the chat view doesn't need to thread it
// through manually. The closure also handles persistence (when the user
// picks "always") before signalling HermesClient.
//
// The MCP allow-list is injected via a closure rather than a hard-coded
// array so future plans can add MCP tools without editing this file.
// HermesClient passes a closure that reads MCPServer.registeredToolNames
// live.

import Foundation

/// Posted by the chat view (or whoever owns the modal) when the user
/// decides on a permission ask. `remember` controls persistence.
typealias GuardrailsDecisionCallback = (_ decision: GuardrailsStore.Decision, _ remember: Bool) -> Void

struct ApprovalRequest: Identifiable {
    /// ACP request id — mirrors the original `session/request_permission`
    /// JSON-RPC id so the eventual reply lines up server-side. Also used
    /// as SwiftUI's Identifiable conformance for `.sheet(item:)`.
    let id: String
    let toolName: String
    /// Pre-truncated display string for the modal's headline area.
    let argsSummary: String
    /// Pretty-printed full JSON for the expandable disclosure block.
    let argsFullJSON: String
    /// Called by the UI when the user picks a button.
    let onDecision: GuardrailsDecisionCallback
}

enum GuardrailsOutcome {
    case allowImmediately
    case denyImmediately
    case askUser(ApprovalRequest)
}

/// Implemented by the chat view (or whoever owns the approval modal).
/// HermesClient calls this when the decider returns `.askUser`.
@MainActor
protocol GuardrailsApprovalDelegate: AnyObject {
    func requestApproval(_ request: ApprovalRequest)
}

struct GuardrailsDecider {
    let store: GuardrailsStore
    /// Returns the current set of MCP-server tool names that bypass the
    /// approval prompt. Read fresh on each decide() call so additions
    /// from future plans are picked up live.
    let mcpToolNamesProvider: () -> Set<String>

    init(
        store: GuardrailsStore = GuardrailsStore(),
        mcpToolNamesProvider: @escaping () -> Set<String>
    ) {
        self.store = store
        self.mcpToolNamesProvider = mcpToolNamesProvider
    }

    /// Decide what to do with a permission request. The `onDecision`
    /// closure inside `.askUser`'s payload writes back to `store` if
    /// the user picks "always", then calls the supplied
    /// `clientCallback` so HermesClient can respond to Hermes.
    func decide(
        requestID: String,
        toolName: String,
        args: [String: Any]
    ) -> GuardrailsOutcome {
        // 1. MCP allow-list (highest priority — voice mode etc.)
        if mcpToolNamesProvider().contains(toolName) {
            return .allowImmediately
        }
        // 2. Remembered user decision
        if let remembered = store.decision(forTool: toolName) {
            switch remembered {
            case .allow: return .allowImmediately
            case .deny:  return .denyImmediately
            }
        }
        // 3. Ask
        let request = ApprovalRequest(
            id: requestID,
            toolName: toolName,
            argsSummary: Self.argsSummary(args),
            argsFullJSON: Self.argsFullJSON(args),
            onDecision: { decision, remember in
                if remember {
                    try? store.setDecision(decision, forTool: toolName)
                }
            }
        )
        return .askUser(request)
    }

    // MARK: - Display helpers

    /// One-line summary suitable for the modal headline. Truncates long
    /// values; pretty-prints small dicts.
    static func argsSummary(_ args: [String: Any]) -> String {
        guard !args.isEmpty else { return "(no arguments)" }
        let parts = args.sorted(by: { $0.key < $1.key }).map { key, value -> String in
            let str = stringify(value)
            let trimmed = str.count > 80 ? String(str.prefix(80)) + "…" : str
            return "\(key): \(trimmed)"
        }
        return parts.joined(separator: "\n")
    }

    /// Pretty-printed JSON for the expandable detail. Falls back to a
    /// plain description if JSONSerialization can't represent the input.
    static func argsFullJSON(_ args: [String: Any]) -> String {
        // Filter values JSONSerialization would reject (NaN, Inf, etc.)
        // and stringify them defensively so we never crash on a bad arg.
        let safe: [String: Any] = args.mapValues { (value: Any) -> Any in
            if let d = value as? Double, !d.isFinite { return "<non-finite>" }
            return value
        }
        if let data = try? JSONSerialization.data(
            withJSONObject: safe,
            options: [.prettyPrinted, .sortedKeys]
        ), let text = String(data: data, encoding: .utf8) {
            return text
        }
        return String(describing: args)
    }

    private static func stringify(_ value: Any) -> String {
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        if let b = value as? Bool { return b ? "true" : "false" }
        if let arr = value as? [Any] { return "[…\(arr.count) items]" }
        if let dict = value as? [String: Any] { return "{…\(dict.count) keys}" }
        return String(describing: value)
    }
}
```

- [ ] **Step 4: Run the tests; verify all 6 pass**

In Xcode, ⌘U. Expected: 6/6 GuardrailsDeciderTests pass.

- [ ] **Step 5: Commit**

```bash
git add TipTour/Hermes/GuardrailsDecider.swift \
        TipTourTests/GuardrailsDeciderTests.swift
git commit -m "feat(guardrails): GuardrailsDecider + ApprovalRequest + delegate protocol"
```

---

## Task 3: Add tipTourPermissionRequested notification name

**Files:**
- Modify: `TipTour/MenuBarPanelManager.swift`

- [ ] **Step 1: Append to the existing Notification.Name extension**

Find the `extension Notification.Name` block at the top of `TipTour/MenuBarPanelManager.swift` (around line 17). Add a new line inside it after the existing `tipTourDismissPanel` declaration:

```swift
extension Notification.Name {
    static let tipTourDismissPanel = Notification.Name("tipTourDismissPanel")
    // ... existing names ...

    /// Posted by `HermesClient` when a permission request arrives and
    /// no host UI surface is visible. `HermesDebugMenuController`
    /// listens and opens the chat window so the approval sheet has
    /// somewhere to attach.
    static let tipTourPermissionRequested = Notification.Name("tipTourPermissionRequested")
}
```

(Preserve the existing names in the block — only insert the new constant + its comment.)

- [ ] **Step 2: Build to verify**

In Xcode, ⌘B. Expected: green build.

- [ ] **Step 3: Commit**

```bash
git add TipTour/MenuBarPanelManager.swift
git commit -m "feat(guardrails): add tipTourPermissionRequested Notification.Name"
```

---

## Task 4: Replace auto-allow in HermesClient with decider + delegate

**Files:**
- Modify: `TipTour/Hermes/HermesClient.swift`

The existing `handleServerRequest` (around line 381) blindly auto-allows every `session/request_permission`. We replace its body with: parse the request → call the decider → branch on outcome → respond directly OR call the delegate. We also add `var approvalDelegate: GuardrailsApprovalDelegate?` and `var guardrailsDecider: GuardrailsDecider?` properties (decider is injectable for tests; defaults to a real one with `mcpServerToolNames` source).

- [ ] **Step 1: Add the new properties**

In `TipTour/Hermes/HermesClient.swift`, find the `// MARK: Internal state` section (around line 174). Add after the existing properties:

```swift
/// Permission-prompt host. Set by `HermesChatView.onAppear`. When the
/// decider returns `.askUser`, we call this; the chat view shows a
/// sheet and eventually invokes the request's onDecision closure.
weak var approvalDelegate: (any GuardrailsApprovalDelegate)?

/// Decision logic for incoming permission requests. Injectable so
/// tests can swap in a fake. Defaults to a real decider whose MCP
/// allow-list reads live from a closure callers can wire to the
/// shared MCPServer.
var guardrailsDecider: GuardrailsDecider = GuardrailsDecider(mcpToolNamesProvider: { [] })
```

The default `mcpToolNamesProvider: { [] }` is a safe fallback if no caller wires the real list. The real wiring happens in Step 4 below.

- [ ] **Step 2: Replace `handleServerRequest` body**

Find `private func handleServerRequest(id: String, method: String, line: Data)` (around line 381). The current body looks like this (verify by reading):

```swift
private func handleServerRequest(id: String, method: String, line: Data) {
    guard method == "session/request_permission" else {
        writeMethodNotFound(id: id, method: method)
        return
    }
    var toolName = "<unknown>"
    if let any = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
       let params = any["params"] as? [String: Any],
       let tc = params["toolCall"] as? [String: Any],
       let name = tc["name"] as? String {
        toolName = name
    }
    NSLog("⚠️ auto-allowed: %@", toolName)
    let resp = PermissionResponse(outcome: PermissionOutcome(outcome: "selected", optionId: "allow"))
    writeResponse(id: id, result: resp)
}
```

Replace the entire body with:

```swift
private func handleServerRequest(id: String, method: String, line: Data) {
    guard method == "session/request_permission" else {
        writeMethodNotFound(id: id, method: method)
        return
    }

    // Parse the request envelope. We need the tool name + args for the
    // decider; if anything is malformed we auto-deny defensively rather
    // than auto-allow as the Plan 2 stub did.
    var toolName = "<unknown>"
    var args: [String: Any] = [:]
    if let any = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
       let params = any["params"] as? [String: Any],
       let tc = params["toolCall"] as? [String: Any] {
        if let name = tc["name"] as? String { toolName = name }
        if let inputArgs = tc["arguments"] as? [String: Any] { args = inputArgs }
    }
    guard toolName != "<unknown>" else {
        NSLog("[Guardrails] ⚠️ malformed permission request (no tool name) — denying")
        respondToHermes(requestID: id, decision: .deny)
        return
    }

    let outcome = guardrailsDecider.decide(
        requestID: id,
        toolName: toolName,
        args: args
    )

    switch outcome {
    case .allowImmediately:
        NSLog("[Guardrails] ✓ allow %@ (auto)", toolName)
        respondToHermes(requestID: id, decision: .allow)
    case .denyImmediately:
        NSLog("[Guardrails] ✗ deny %@ (auto)", toolName)
        respondToHermes(requestID: id, decision: .deny)
    case .askUser(let request):
        NSLog("[Guardrails] ? ask user about %@", toolName)
        // Wrap the request's onDecision so we ALSO reply to Hermes
        // after the user decides + the store persists.
        let wrapped = ApprovalRequest(
            id: request.id,
            toolName: request.toolName,
            argsSummary: request.argsSummary,
            argsFullJSON: request.argsFullJSON,
            onDecision: { [weak self] decision, remember in
                request.onDecision(decision, remember)
                self?.respondToHermes(requestID: id, decision: decision)
            }
        )
        // Defensive: if no delegate is registered, auto-deny rather than
        // silently dropping the request (Hermes would hang forever).
        guard let delegate = approvalDelegate else {
            NSLog("[Guardrails] ⚠️ no approvalDelegate — auto-denying %@", toolName)
            respondToHermes(requestID: id, decision: .deny)
            return
        }
        // Post the notification so the menu-bar controller can open the
        // chat window if it's currently closed (sheet host must exist).
        NotificationCenter.default.post(name: .tipTourPermissionRequested, object: nil)
        delegate.requestApproval(wrapped)
    }
}

/// Send the appropriate ACP response back to Hermes for a permission
/// request. Centralised so allow/deny use the exact same wire shape.
private func respondToHermes(requestID: String, decision: GuardrailsStore.Decision) {
    let optionId: String
    switch decision {
    case .allow: optionId = "allow"
    case .deny:  optionId = "reject"
    }
    let resp = PermissionResponse(outcome: PermissionOutcome(outcome: "selected", optionId: optionId))
    writeResponse(id: requestID, result: resp)
}
```

Note on `optionId`: ACP 0.9.0 expects the optionId from the agent's offered options list. `"allow"` matches the existing auto-allow path; `"reject"` is the Hermes Agent convention for the deny option. If smoke testing reveals Hermes uses a different string (e.g. `"deny"`), update both `respondToHermes` and the verification step below.

- [ ] **Step 3: Wire the real MCP allow-list source in CompanionManager**

`HermesClient` is owned by `CompanionManager` (after Plan 4 Task 1). The same `CompanionManager` owns the `MCPServer`, so it's the natural place to plug the live tool-name source into the decider.

Open `TipTour/CompanionManager.swift`. Find the existing `mcpServer.register(...)` block inside `start()` (it's the block that registers `SpeakTool` — oh wait, SpeakTool was deleted. The block registers `ScreenshotTool`, `A11yTreeTool`, `PointAtTool`). Immediately AFTER that block (still inside `start()`, before `mcpServer.start()`), add:

```swift
// Wire the guardrails decider's MCP allow-list to the live registered
// tools on our MCP server. New MCP tools added in future plans are
// auto-allowed without touching GuardrailsDecider.
hermesClient.guardrailsDecider = GuardrailsDecider(
    mcpToolNamesProvider: { [weak self] in
        guard let self else { return [] }
        return Set(self.mcpServer.registeredToolNames)
    }
)
```

This re-assigns `hermesClient.guardrailsDecider` (which started as the empty-allow-list default) to a version that consults `MCPServer.registeredToolNames` live.

- [ ] **Step 4: Add `registeredToolNames` to MCPServer**

`MCPServer` needs to expose the names of its registered tools. Open `TipTour/Hermes/MCPServer.swift`. Grep for the existing `register` method body — it stores tools in a `[String: MCPTool]` dictionary (by name). Add a read-only accessor:

```swift
/// Names of every registered tool. Used by GuardrailsDecider to
/// auto-allow our own MCP-side tools without prompting.
var registeredToolNames: Set<String> {
    Set(tools.keys)
}
```

(The exact property name might be `tools` or similar — grep for `register(tool:)` to find the underlying storage. Adapt the accessor name if needed.)

- [ ] **Step 5: Build to verify**

In Xcode, ⌘B. Expected: green build. Any compile error means a property name didn't match — grep and fix before continuing.

- [ ] **Step 6: Commit**

```bash
git add TipTour/Hermes/HermesClient.swift \
        TipTour/CompanionManager.swift \
        TipTour/Hermes/MCPServer.swift
git commit -m "feat(guardrails): HermesClient routes permission requests through GuardrailsDecider"
```

---

## Task 5: ApprovalSheetView

**Files:**
- Create: `TipTour/Hermes/ApprovalSheetView.swift`

The SwiftUI sheet shown when `HermesChatView.pendingApproval` is non-nil. JARVIS-styled to match the rest of the app.

- [ ] **Step 1: Create the view**

Create `TipTour/Hermes/ApprovalSheetView.swift`:

```swift
// TipTour/Hermes/ApprovalSheetView.swift
//
// SwiftUI sheet that surfaces a Hermes permission request to the user.
// Shows the tool name, a truncated args summary, an expandable raw-args
// disclosure, and four decision buttons. Dismisses immediately on any
// pick — HermesClient handles the wire-level response via the request's
// onDecision closure.

import SwiftUI

struct ApprovalSheetView: View {
    let request: ApprovalRequest
    @Binding var isPresented: Bool
    @State private var showFullArgs: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            JarvisSectionHeader(title: "HERMES // PERMISSION REQUEST")

            Text(request.toolName)
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .tracking(1.2)
                .foregroundColor(DS.Colors.textPrimary)

            Text("Hermes wants to run this on your Mac.")
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .tracking(0.4)
                .foregroundColor(DS.Colors.textSecondary)

            // Args summary block
            Text(request.argsSummary)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(DS.Colors.textPrimary)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    ZStack {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(DS.Colors.surface1)
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(DS.Colors.jarvisBorder, lineWidth: 1)
                    }
                )

            // Full args disclosure
            DisclosureGroup(isExpanded: $showFullArgs) {
                ScrollView {
                    Text(request.argsFullJSON)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(DS.Colors.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(maxHeight: 160)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(DS.Colors.surface1)
                )
            } label: {
                Text(showFullArgs ? "▾ HIDE FULL ARGUMENTS" : "▸ SEE FULL ARGUMENTS")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(1.0)
                    .foregroundColor(DS.Colors.jarvisAccent)
            }
            .padding(.vertical, 2)

            // Buttons
            HStack(spacing: 10) {
                JarvisButton(title: "DENY") {
                    decide(.deny, remember: false)
                }
                JarvisButton(title: "DENY ALWAYS") {
                    decide(.deny, remember: true)
                }
                Spacer()
                JarvisButton(title: "ALLOW") {
                    decide(.allow, remember: false)
                }
                JarvisButton(title: "ALLOW ALWAYS") {
                    decide(.allow, remember: true)
                }
            }

            Text("\"ALWAYS\" REMEMBERS YOUR CHOICE AND SKIPS THIS PROMPT NEXT TIME. REVOKE IN SETTINGS → GUARDRAILS.")
                .font(.system(size: 9, weight: .regular, design: .monospaced))
                .tracking(0.6)
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(22)
        .frame(width: 520)
    }

    private func decide(_ decision: GuardrailsStore.Decision, remember: Bool) {
        request.onDecision(decision, remember)
        isPresented = false
    }
}
```

- [ ] **Step 2: Build to verify**

In Xcode, ⌘B. Expected: green build (the view has no callers yet; it just compiles cleanly).

- [ ] **Step 3: Commit**

```bash
git add TipTour/Hermes/ApprovalSheetView.swift
git commit -m "feat(guardrails): ApprovalSheetView with JARVIS styling + 4-button decision panel"
```

---

## Task 6: Wire HermesChatView as the approval delegate

**Files:**
- Modify: `TipTour/Hermes/HermesChatWindow.swift`

`HermesChatView` becomes the `GuardrailsApprovalDelegate`. It owns the `@State var pendingApproval: ApprovalRequest?`, sets itself as the client's delegate in `.onAppear`, and presents the sheet via `.sheet(item:)`.

- [ ] **Step 1: Conform to the delegate protocol**

In `TipTour/Hermes/HermesChatWindow.swift`, find the `struct HermesChatView: View` declaration (around line 22). SwiftUI structs can't directly conform to a `@MainActor` class-bound protocol because they're value types. The clean fix is a small `final class` companion that the view holds as `@StateObject` (or as a `@State` plain reference).

Two changes to `HermesChatView`:

First, define the companion class. Inside the file but OUTSIDE `HermesChatView` (place above the struct or below — doesn't matter), add:

```swift
/// Bridges the SwiftUI value-type view into `GuardrailsApprovalDelegate`.
/// HermesChatView holds one as `@StateObject` and registers it as the
/// client's delegate on appear. Stores the pending request as
/// `@Published` so the view's `.sheet(item:)` modifier reacts.
@MainActor
final class HermesApprovalBridge: ObservableObject, GuardrailsApprovalDelegate {
    @Published var pendingRequest: ApprovalRequest?

    func requestApproval(_ request: ApprovalRequest) {
        // Defensive: a second permission ask while one's still showing
        // shouldn't happen (Hermes blocks until we respond), but if it
        // does we drop the new one with a deny so we never lose track.
        if pendingRequest != nil {
            NSLog("[Guardrails] ⚠️ concurrent approval request — auto-denying")
            request.onDecision(.deny, false)
            return
        }
        pendingRequest = request
    }

    func clear() {
        pendingRequest = nil
    }
}
```

Second, modify `HermesChatView`:

```swift
struct HermesChatView: View {
    @ObservedObject var client: HermesClient
    @State private var draft: String = ""
    @State private var showSetupSheet: Bool = false   // existing
    @StateObject private var approvalBridge = HermesApprovalBridge()
    @FocusState private var inputFocused: Bool

    var body: some View {
        // ... existing body unchanged ...
    }

    // ... existing methods unchanged ...
}
```

(Insert the `@StateObject private var approvalBridge = HermesApprovalBridge()` line alongside the other `@State` / `@StateObject` declarations near the top of the struct. Do NOT remove anything that's already there.)

- [ ] **Step 2: Register the bridge as the client's delegate + present the sheet**

In the same file, find the root `VStack` of `HermesChatView.body` (the one that owns the chat band + transcript + input). It currently ends with `.onAppear { inputFocused = true }` and a `.sheet(isPresented: $showSetupSheet)` modifier from Plan 4.

Modify the `.onAppear` to ALSO register the bridge:

```swift
.onAppear {
    inputFocused = true
    client.approvalDelegate = approvalBridge
}
```

Add a new `.sheet(item:)` modifier at the end of the modifier chain (after the existing `.sheet`):

```swift
.sheet(item: $approvalBridge.pendingRequest) { request in
    ApprovalSheetView(
        request: request,
        isPresented: Binding(
            get: { approvalBridge.pendingRequest != nil },
            set: { newValue in if !newValue { approvalBridge.clear() } }
        )
    )
}
```

Note: `.sheet(item:)` requires the bound value to be `Identifiable`. `ApprovalRequest` is already `Identifiable` (its `id` property). The binding's setter clears the pending request when the sheet dismisses, which also tears down the modal cleanly if the user closes it via Escape.

- [ ] **Step 3: Build to verify**

In Xcode, ⌘B. Expected: green build.

- [ ] **Step 4: Commit**

```bash
git add TipTour/Hermes/HermesChatWindow.swift
git commit -m "feat(guardrails): HermesChatView hosts the approval sheet via bridge object"
```

---

## Task 7: Auto-open chat window on permission request

**Files:**
- Modify: `TipTour/Hermes/HermesDebugMenuController.swift`

If a permission request fires while the chat window is closed, the sheet has no host. Listen for the `tipTourPermissionRequested` notification and call `openChat()` so the window appears just in time.

- [ ] **Step 1: Add a notification observer in install()**

Open `TipTour/Hermes/HermesDebugMenuController.swift`. Find `func install(companionManager: CompanionManager)` (around line 26). At the end of the method body (after `installGlobalShortcut()`), add:

```swift
// When HermesClient asks the user for permission while the chat window
// is closed, the approval sheet has nowhere to attach. Open the window
// just in time so HermesChatView's @StateObject bridge can host it.
NotificationCenter.default.addObserver(
    forName: .tipTourPermissionRequested,
    object: nil,
    queue: .main
) { [weak self] _ in
    Task { @MainActor in
        self?.openChatIfClosed()
    }
}
```

- [ ] **Step 2: Add the openChatIfClosed helper**

In the same file, find `@objc private func openChat()` (around line 84). Just AFTER its closing `}`, add:

```swift
/// Variant of `openChat` that only acts if the chat window isn't
/// currently visible. Used by the permission-request notification path
/// to ensure a sheet host exists without re-focusing an already-open
/// chat window the user is actively reading.
@MainActor
private func openChatIfClosed() {
    if window == nil || !(window?.isVisible ?? false) {
        openChat()
    }
}
```

- [ ] **Step 3: Build to verify**

In Xcode, ⌘B. Expected: green build.

- [ ] **Step 4: Commit**

```bash
git add TipTour/Hermes/HermesDebugMenuController.swift
git commit -m "feat(guardrails): auto-open chat window when Hermes asks for permission"
```

---

## Task 8: GuardrailsTabView

**Files:**
- Create: `TipTour/Settings/GuardrailsTabView.swift`

Settings tab listing remembered decisions with Revoke buttons + Reset All. JARVIS-styled.

- [ ] **Step 1: Create the view**

Create `TipTour/Settings/GuardrailsTabView.swift`:

```swift
// TipTour/Settings/GuardrailsTabView.swift
//
// Settings tab listing remembered Allow/Deny decisions. Each row has
// a Revoke button; a Reset All button at the bottom wipes the whole
// guardrails.json file. JARVIS-styled to match the rest of Settings.

import SwiftUI

struct GuardrailsTabView: View {

    @State private var decisions: [String: GuardrailsStore.Decision] = [:]
    @State private var showResetConfirm: Bool = false

    private let store = GuardrailsStore()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                JarvisSectionHeader(title: "REMEMBERED DECISIONS")
                if decisions.isEmpty {
                    emptyState
                } else {
                    decisionsList
                }
                JarvisSectionHeader(title: "ACTIONS")
                actionsRow
                JarvisSectionHeader(title: "WHERE")
                Text("STORED AT ~/.hermes/guardrails.json. EDIT DIRECTLY IF YOU PREFER. HERMES READS DECISIONS IN REAL TIME — NO APP RESTART NEEDED.")
                    .font(.system(size: 9, weight: .regular, design: .monospaced))
                    .tracking(0.6)
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
        }
        .onAppear(perform: reload)
        .confirmationDialog(
            "Reset all guardrails decisions?",
            isPresented: $showResetConfirm,
            titleVisibility: .visible
        ) {
            Button("Reset All", role: .destructive) { resetAll() }
            Button("Cancel", role: .cancel) { }
        }
    }

    // MARK: Sections

    private var emptyState: some View {
        Text("NO REMEMBERED DECISIONS YET. ALLOW ALWAYS OR DENY ALWAYS CHOICES APPEAR HERE.")
            .font(.system(size: 10, weight: .regular, design: .monospaced))
            .tracking(0.6)
            .foregroundColor(DS.Colors.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var decisionsList: some View {
        VStack(spacing: 8) {
            ForEach(decisions.keys.sorted(), id: \.self) { toolName in
                decisionRow(toolName: toolName, decision: decisions[toolName]!)
            }
        }
    }

    private func decisionRow(toolName: String, decision: GuardrailsStore.Decision) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(decision == .allow ? DS.Colors.jarvisAccent : DS.Colors.destructive)
                .frame(width: 6, height: 6)
                .shadow(color: (decision == .allow ? DS.Colors.jarvisAccent : DS.Colors.destructive).opacity(0.6), radius: 3)
            Text(toolName.uppercased())
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .tracking(1.0)
                .foregroundColor(DS.Colors.textPrimary)
            Text(decision == .allow ? "ALLOW" : "DENY")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(1.0)
                .foregroundColor(decision == .allow ? DS.Colors.jarvisAccent : DS.Colors.destructive)
            Spacer()
            JarvisButton(title: "REVOKE") {
                revoke(toolName: toolName)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(DS.Colors.jarvisBorder, lineWidth: 1)
        )
    }

    private var actionsRow: some View {
        HStack {
            JarvisButton(title: "RESET ALL", enabled: !decisions.isEmpty) {
                showResetConfirm = true
            }
            Spacer()
        }
    }

    // MARK: Actions

    private func reload() {
        decisions = store.allDecisions()
    }

    private func revoke(toolName: String) {
        try? store.remove(toolName: toolName)
        reload()
    }

    private func resetAll() {
        try? FileManager.default.removeItem(at: store.filePath)
        reload()
    }
}
```

- [ ] **Step 2: Build to verify**

In Xcode, ⌘B. Expected: green build (the view has no callers yet — Task 9 wires it into SettingsSheetView).

- [ ] **Step 3: Commit**

```bash
git add TipTour/Settings/GuardrailsTabView.swift
git commit -m "feat(guardrails): GuardrailsTabView with revoke + reset all"
```

---

## Task 9: Add Guardrails tab to SettingsSheetView

**Files:**
- Modify: `TipTour/Settings/SettingsSheetView.swift`

Add a `guardrails` case to the `Tab` enum + a tab-bar button + a switch case for the new tab body.

- [ ] **Step 1: Extend the Tab enum**

In `TipTour/Settings/SettingsSheetView.swift`, find:

```swift
private enum Tab: String, Hashable {
    case models, memory, soul
}
```

Change to:

```swift
private enum Tab: String, Hashable {
    case models, memory, soul, guardrails
}
```

- [ ] **Step 2: Add the body switch case**

In the same file, find the `Group { switch selectedTab { case .models: ModelsTabView() ... } }` block. Add a new branch:

```swift
Group {
    switch selectedTab {
    case .models:     ModelsTabView()
    case .memory:     MemoryTabView()
    case .soul:       SoulTabView()
    case .guardrails: GuardrailsTabView()
    }
}
```

- [ ] **Step 3: Add the tab-bar button**

Find the `tabBar` computed property (the HStack containing `tabButton("MODELS", ...)` etc.). Add a fourth button alongside the existing three:

```swift
private var tabBar: some View {
    HStack(spacing: 0) {
        tabButton("MODELS",     systemImage: "cpu",         tab: .models)
        tabButton("MEMORY",     systemImage: "brain",       tab: .memory)
        tabButton("SOUL",       systemImage: "sparkles",    tab: .soul)
        tabButton("GUARDRAILS", systemImage: "shield",      tab: .guardrails)
        Spacer()
    }
    .padding(.horizontal, 14)
    .padding(.bottom, 4)
}
```

- [ ] **Step 4: Build to verify**

In Xcode, ⌘B. Expected: green build. ⌘R + open Settings; expect the new tab.

- [ ] **Step 5: Commit**

```bash
git add TipTour/Settings/SettingsSheetView.swift
git commit -m "feat(settings): add Guardrails tab to Settings sheet"
```

---

## Task 10: Update AGENTS.md

**Files:**
- Modify: `AGENTS.md`

- [ ] **Step 1: Add Key Files rows**

In `AGENTS.md`, find the Key Files table. Add these rows in the same general vicinity as the other `TipTour/Settings/*` and `TipTour/Hermes/*` rows (group with related concerns):

```markdown
| `TipTour/Settings/GuardrailsStore.swift` | ~75 | Atomic read/write for `~/.hermes/guardrails.json`. `Decision` enum (allow/deny). `setDecision`/`remove`/`decision(forTool:)`/`allDecisions()`. Corrupt JSON returns empty map without crash. |
| `TipTour/Hermes/GuardrailsDecider.swift` | ~120 | Pure decision logic: MCP-allow-list → remembered-decision → askUser. Defines `ApprovalRequest` (Identifiable, carries `onDecision` callback), `GuardrailsOutcome` enum, `GuardrailsApprovalDelegate` protocol. MCP allow-list injected via closure (reads `MCPServer.registeredToolNames` live). |
| `TipTour/Hermes/ApprovalSheetView.swift` | ~95 | SwiftUI sheet: tool name, args summary, expandable raw-args disclosure, 4 buttons (Deny / Deny Always / Allow / Allow Always). Hosted by `HermesChatView` via `HermesApprovalBridge` (an `ObservableObject` companion that bridges the value-type view into the `@MainActor` delegate protocol). |
| `TipTour/Settings/GuardrailsTabView.swift` | ~110 | Settings tab listing remembered decisions. Per-row Revoke button + Reset All confirm dialog. Reads `GuardrailsStore` directly; reloads on `.onAppear` and after each action. |
```

- [ ] **Step 2: Add an Architecture bullet**

In the Architecture section, find the "Settings sheet" bullet (added in Plan 5). Add a new bullet AFTER it:

```markdown
- **Guardrails**: `HermesClient.handleServerRequest` no longer auto-allows every `session/request_permission` — it routes through `GuardrailsDecider` which consults a dynamic MCP allow-list (from `MCPServer.registeredToolNames`) and the persisted `~/.hermes/guardrails.json`. Unknown tools surface an approval sheet (`ApprovalSheetView`) hosted by the chat window via `HermesApprovalBridge`; if the chat window is closed when a request arrives, `HermesDebugMenuController` opens it via the `tipTourPermissionRequested` notification. "Allow Always" / "Deny Always" choices persist to `guardrails.json` and are managed in the Settings → Guardrails tab.
```

- [ ] **Step 3: Update the HermesClient row description**

Find the `HermesClient.swift` row in Key Files. The existing description mentions "auto-allow for `session/request_permission`". Update to reflect guardrails routing:

```markdown
| `TipTour/Hermes/HermesClient.swift` | ~XXX | ACP client speaking newline-delimited JSON-RPC over the bundled Python subprocess's stdio. `send(_:)` is serialized via a Task-queue tail so concurrent callers (voice ask_hermes + chat window) hit Hermes one at a time. `session/request_permission` is routed through `GuardrailsDecider`; auto-deny on malformed requests. `lastAgentReplyText` accessor exposes the most recent agent turn's text for the voice-mode `ask_hermes` handler. `mcpServerURL` registered on `session/new` so Hermes calls our Mac-side tools (Plan 3b). |
```

Replace `~XXX` with the actual current line count (`wc -l TipTour/Hermes/HermesClient.swift`).

- [ ] **Step 4: Commit**

```bash
git add AGENTS.md
git commit -m "docs(agents): document Plan 6 guardrails — decider, store, sheet, tab"
```

---

## Task 11: Manual end-to-end smoke test (user)

**Files:** None. Manual procedure run from Xcode.

This task can't be automated — live Hermes + ACP + permission flow isn't mockable from XCTest cleanly. The user runs these six scenarios in Xcode and confirms each one works.

- [ ] **Step 1: Build + run**

In Xcode, ⌘R.

- [ ] **Step 2: Trigger a permission ask via chat**

⌥⇧H to open the chat window. Type *"list the files in my home directory"* and press Return.

Expected:
- Sheet appears with `run_shell_command` tool name, the `ls ~` command in the args block, and 4 buttons
- Click **ALLOW** → sheet dismisses → Hermes proceeds → transcript shows the file listing
- Console: `[Guardrails] ? ask user about run_shell_command` then `[Guardrails] ✓ allow run_shell_command (auto)` on the next call (if any)

- [ ] **Step 3: Test "Allow Always"**

Ask *"check the news on hacker news"* (or any web fetch task).

Expected:
- Sheet appears with `web_fetch` or similar
- Click **ALLOW ALWAYS** → sheet dismisses → Hermes proceeds
- Run `cat ~/.hermes/guardrails.json` in a terminal — file should contain `{"web_fetch": "allow"}` (or whatever the actual tool name is)
- Ask another web fetch question → no sheet appears, Hermes proceeds silently
- Console: `[Guardrails] ✓ allow web_fetch (auto)` on the second call

- [ ] **Step 4: Test "Deny Always"**

Ask *"write a file called test.txt with the word hello"*.

Expected:
- Sheet appears for `write_text_file`
- Click **DENY ALWAYS** → sheet dismisses → Hermes responds with an error (it couldn't write)
- `cat ~/.hermes/guardrails.json` now also contains `write_text_file: deny`
- Ask again to write a file → no sheet, immediate denial, Hermes reports the same error
- Console: `[Guardrails] ✗ deny write_text_file (auto)`

- [ ] **Step 5: Verify the Guardrails Settings tab**

Open **Settings → Guardrails**.

Expected:
- Two rows visible: `WEB_FETCH ● ALLOW [REVOKE]` and `WRITE_TEXT_FILE ● DENY [REVOKE]`
- Status dots are cyan for allow, red for deny
- Click **REVOKE** on `web_fetch` → row disappears immediately
- Run `cat ~/.hermes/guardrails.json` — `web_fetch` is gone, `write_text_file` remains

- [ ] **Step 6: Test voice-mode permission flow**

Press Ctrl+Option and say *"search for the latest Swift news and summarize"*.

Expected:
- Gemini speaks an acknowledgement ("on it…")
- Hermes triggers a web fetch (which was revoked in Step 5)
- The chat window auto-opens with the approval sheet (because the previous window was closed)
- Click **ALLOW** → sheet dismisses → Hermes proceeds → Gemini speaks the summary

- [ ] **Step 7: Test Reset All**

Open **Settings → Guardrails** → click **RESET ALL** → confirm in the dialog.

Expected:
- Tab shows the empty state ("NO REMEMBERED DECISIONS YET…")
- `cat ~/.hermes/guardrails.json` either shows `{}` or the file is gone
- Next permission ask shows the sheet again

- [ ] **Step 8: Commit a record**

```bash
git commit --allow-empty -m "test(guardrails): manually verified six-scenario smoke test"
```

---

## Self-review

**Spec coverage:**
- v1 modal approval prompt → Task 5 (ApprovalSheetView) + Task 6 (wiring)
- Persistence to `~/.hermes/guardrails.json` → Task 1 (GuardrailsStore)
- MCP auto-allow → Task 2 (GuardrailsDecider) + Task 4 step 3-4 (live MCPServer source)
- Guardrails Settings tab → Task 8 + Task 9
- Edge cases (malformed request, corrupt JSON, concurrent requests, app close mid-request, sheet-window auto-open) → Task 4 (decider routing + auto-deny fallbacks) + Task 7 (auto-open) + Task 1 step 1 test 7 (corrupt JSON) + Task 6 step 1 (concurrent request handling in HermesApprovalBridge)
- Unit tests (7 store + 6 decider) → Task 1 + Task 2
- Manual smoke test → Task 11

**Placeholder scan:** None of "TBD", "TODO", "implement later", "fill in details", "Add appropriate error handling", "Similar to Task N" appear in any task. Every code-bearing step shows the complete code.

**Type consistency:**
- `GuardrailsStore.Decision` (allow/deny) used consistently across decider, sheet, bridge, tab
- `ApprovalRequest`'s `onDecision: (Decision, Bool) -> Void` signature matches between the decider's construction (Task 2) and HermesClient's wrap (Task 4 step 2) and ApprovalSheetView's `decide()` call (Task 5)
- `GuardrailsApprovalDelegate.requestApproval(_:)` signature matches between Task 2 (protocol) and Task 6 (bridge conformance) and Task 4 (HermesClient call site)
- `mcpToolNamesProvider: () -> Set<String>` consistent between Task 2 (decider declaration) and Task 4 step 3 (CompanionManager wiring) and Task 4 step 4 (MCPServer accessor returns `Set<String>`)

**Pre-flight:** The `optionId` for deny is assumed to be `"reject"` in Task 4 step 2 (`respondToHermes`). If the smoke test in Task 11 shows Hermes doesn't recognize `"reject"`, the engineer updates `respondToHermes` accordingly — most likely candidates are `"deny"` or sending `outcome: "cancelled"` with no `optionId`.

---

## Execution handoff

Plan complete and saved to `docs/superpowers/plans/2026-05-14-plan-6-guardrails.md`. Two execution options:

**1. Subagent-Driven (recommended)** — Dispatch a fresh subagent per task with two-stage review between tasks. Same flow as Plans 4 and 5. Tasks 1, 2, 3 are independent; 4 depends on 2 and 3; 5 is independent; 6 depends on 5; 7, 8 are independent; 9 depends on 8; 10, 11 are docs/manual.

**2. Inline Execution** — Batch execution in this session via `superpowers:executing-plans` with checkpoints.

Which approach?
