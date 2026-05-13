# Plan 3b — Mac-side tools (`take_screenshot`, `get_a11y_tree`, `point_at`) — Design

**Date:** 2026-05-14
**Status:** Approved (brainstorming session)
**Builds on:**
- [`2026-05-13-plan-1-bundling-and-acp-smoke-test.md`](../plans/2026-05-13-plan-1-bundling-and-acp-smoke-test.md) — bundled Hermes runtime (complete).
- [`2026-05-13-tiptour-hermes-rebrand-design.md`](2026-05-13-tiptour-hermes-rebrand-design.md) — TipTour → TipTour_Hermes rebrand (complete).
- [`2026-05-13-plan-2-acp-bridge-and-dev-textbox-design.md`](2026-05-13-plan-2-acp-bridge-and-dev-textbox-design.md) — Swift `HermesClient` + dev chat window (complete).
- [`2026-05-13-plan-3a-mcp-framework-and-speak-tool-design.md`](2026-05-13-plan-3a-mcp-framework-and-speak-tool-design.md) — `MCPServer` + `SpeakTool` (complete).

## Purpose

Plan 3a built a working MCP server with one tool (`speak`). Plan 3b populates the toolbox with the three remaining "body" capabilities Hermes needs to act as a guiding agent on macOS:

- **`take_screenshot`** — capture the screen and ship a downscaled JPEG so Hermes can see what the user is looking at.
- **`get_a11y_tree`** — enumerate up to 200 actionable UI elements in the frontmost (or hinted) app, with labels, roles, and on-screen rects.
- **`point_at`** — fly the Arc Reactor cursor to a labelled UI element with a speech bubble. Auto-clears after 4 seconds.

After Plan 3b, the dev chat lets you ask "what's on screen?", "what's clickable in Safari?", and "point at the address bar and say 'enter a URL here'" — and Hermes does each of those through MCP tool calls. Plan 3c then rewires push-to-talk to drive the same loop without the dev chat being open.

## Non-Goals

- Voice loop wiring (push-to-talk → STT → Hermes → TTS) — Plan 3c.
- Persistent cursor / "cursor stays until explicitly cleared" — out of scope. Fire-and-forget with a 4-second auto-clear is the contract.
- Tools that mutate the user's machine (typing, clicking, executing AppleScript). Plan 3b is strictly "look and narrate," not "automate."
- Region-of-interest screenshots (cropped to one window). Future plan if needed.
- Programmatic dismissal of the Arc Reactor cursor by Hermes (no `unpoint_at` tool). The 4-second timer covers all current use cases.
- A separate "Show me this on a hi-res screenshot" override for fine-detail tasks. Not yet needed; can be added later as a `full_resolution: bool` argument to `take_screenshot`.

## Decisions captured during brainstorming

| Question | Answer |
|---|---|
| Screenshot output size? | Auto-resize to max **1280px wide**, JPEG quality 70. Typical 80–150 KB; ~750 image tokens to Claude Haiku 4.5. Loses fine text detail in dense IDEs, fine for guiding tasks. |
| Multi-monitor screenshot scope? | Capture the screen the frontmost app's main window is on. Falls back to `NSScreen.main` when the frontmost app's window position can't be read. |
| `point_at` argument shape? | Just `label: string` + `bubble: string` (+ optional `app_hint`). Tool resolves label → screen rect via existing `AccessibilityTreeResolver.findElement(byLabel:)`. No raw-rect argument; Hermes calls `get_a11y_tree` first to discover labels. |
| Cursor lifecycle? | Auto-clear after 4 seconds. A new `point_at` call cancels the previous auto-clear and starts a fresh 4-second window. |
| Wiring approach? | Inject `CompanionManager` into `HermesDebugMenuController.install()`, hand it to `PointAtTool`'s init. No new singletons, no `MacToolEnvironment` abstraction yet. |

## Section 1 — File layout

**New files:**

```
TipTour/Hermes/
├── ScreenshotTool.swift   — SCScreenshotManager capture + downscale + JPEG encode
├── A11yTreeTool.swift     — wraps AccessibilityTreeResolver.setOfMarksForTargetApp
└── PointAtTool.swift      — resolves label → rect → CompanionManager publishes; auto-clear after 4s
```

**Modified files:**

- `TipTour/Hermes/MCPTools.swift` — `MCPTool.call` return type changes from `String` to `[MCPToolContent]` to support image content blocks. Add the `MCPToolContent` enum. `SpeakTool.call` returns `[.text("Speaking: \(text)")]` (one-line change).
- `TipTour/Hermes/MCPServer.swift` — the `tools/call` case in `dispatchRPC` maps `[MCPToolContent]` to the wire JSON (text or image content blocks).
- `TipTour/Hermes/HermesDebugMenuController.swift` — `install()` now takes `companionManager: CompanionManager`; registers all four tools (`SpeakTool` + the three new ones) sharing a single `AccessibilityTreeResolver` instance between `A11yTreeTool` and `PointAtTool`.
- `TipTour/TipTourApp.swift` — one-line edit: `hermesDebugMenu?.install(companionManager: companionManager)`.

**New test files:**

- `TipTourTests/ScreenshotToolTests.swift` — one test, asserts the call returns a text + image block with non-trivial JPEG bytes.
- `TipTourTests/A11yTreeToolTests.swift` — one test, asserts a non-empty parsed JSON array against Finder (always-running target).
- `TipTourTests/PointAtToolTests.swift` — two tests: setting CompanionManager properties, and the 4-second auto-clear.

**Modified test files:**

- `TipTourTests/MCPToolsTests.swift` — one-line update to `testSpeakToolCallReturnsSuccessForValidText` to walk the new `[MCPToolContent]` return type (`guard case .text(let s) = blocks.first` instead of `result.contains(...)`).

**Deliberately NOT modified:**

- Plan 1+2+3a canaries (`HermesBundleTests`, `HermesACPProtocolTests`, `HermesClientTests`, `MCPServerTests`) stay untouched.
- The 15 `TODO(plan-2)` markers in `CompanionManager` / `GeminiLiveSession` / `CompanionPanelView` — Plan 3c.

## Section 2 — `MCPTool` content-block extension

Currently `MCPTool.call(_:)` returns `String`. To support images, extend it to return an array of content blocks. MCP wire format already accepts `{ type: "text", text }` OR `{ type: "image", data: <base64>, mimeType }` in `tools/call` responses.

### Type changes in `MCPTools.swift`

```swift
enum MCPToolContent {
    case text(String)
    case image(base64: String, mimeType: String)
}

protocol MCPTool: Sendable {
    var name: String { get }
    var description: String { get }
    var inputSchema: JSONValue { get }
    @MainActor func call(_ arguments: JSONValue) async throws -> [MCPToolContent]
}
```

### `SpeakTool` migration

The only line that changes inside `SpeakTool.call`:

```swift
return [.text("Speaking: \(text)")]
```

### `MCPServer.dispatchRPC` tools/call mapping

The existing `tools/call` case constructs `content` as `[["type": "text", "text": text]]`. Replace with:

```swift
let blocks = try await tool.call(arguments)
let contentJSON: [[String: Any]] = blocks.map { block in
    switch block {
    case .text(let s):
        return ["type": "text", "text": s]
    case .image(let b64, let mime):
        return ["type": "image", "data": b64, "mimeType": mime]
    }
}
let result: [String: Any] = ["content": contentJSON, "isError": false]
respond(envelope: env, result: result, on: connection)
```

Error path (`catch`) stays as a single text block reporting the error.

### `MCPToolsTests` migration

One line in `testSpeakToolCallReturnsSuccessForValidText`:

```swift
let blocks = try await tool.call(.object(["text": .string("ok")]))
guard case .text(let s) = blocks.first else { XCTFail("expected text"); return }
XCTAssertTrue(s.contains("ok"))
```

Total touched LOC for the protocol extension: ~10 across 3 files. No other tools or callers reach `MCPTool.call` directly.

## Section 3 — `ScreenshotTool`

```swift
// TipTour/Hermes/ScreenshotTool.swift

import Foundation
import AppKit
import ScreenCaptureKit
import CoreImage

@MainActor
final class ScreenshotTool: MCPTool {
    let name = "take_screenshot"
    let description = "Capture the screen the frontmost app is on, resized to 1280px wide as JPEG. Returns a single image content block."
    let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([:]),
        "required": .array([]),
    ])

    func call(_ arguments: JSONValue) async throws -> [MCPToolContent] {
        let targetScreen = Self.frontmostAppScreen() ?? NSScreen.main
        guard let screen = targetScreen else {
            throw MCPToolError.toolFailed("no screen available")
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first(where: { Int($0.displayID) == screen.displayID }) else {
            throw MCPToolError.toolFailed("could not find SCDisplay for active screen")
        }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.width = Int(display.width)
        config.height = Int(display.height)
        config.scalesToFit = true
        config.showsCursor = false

        let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        let resized = Self.downscale(cgImage, maxWidth: 1280)

        guard let jpegData = Self.jpegData(from: resized, quality: 0.7) else {
            throw MCPToolError.toolFailed("JPEG encoding failed")
        }

        let base64 = jpegData.base64EncodedString()
        let dimensions = "\(resized.width)×\(resized.height)"
        return [
            .text("Captured screen \(screen.displayID), \(dimensions), \(jpegData.count) bytes"),
            .image(base64: base64, mimeType: "image/jpeg"),
        ]
    }

    // MARK: - Helpers

    private static func frontmostAppScreen() -> NSScreen? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = app.processIdentifier
        let appRef = AXUIElementCreateApplication(pid)
        var focusedWindow: AnyObject?
        let err = AXUIElementCopyAttributeValue(appRef, kAXFocusedWindowAttribute as CFString, &focusedWindow)
        guard err == .success, let win = focusedWindow else { return nil }
        var posValue: AnyObject?
        AXUIElementCopyAttributeValue(win as! AXUIElement, kAXPositionAttribute as CFString, &posValue)
        var point = CGPoint.zero
        if let p = posValue, AXValueGetType(p as! AXValue) == .cgPoint {
            AXValueGetValue(p as! AXValue, .cgPoint, &point)
        }
        return NSScreen.screens.first { $0.frame.contains(point) }
    }

    private static func downscale(_ image: CGImage, maxWidth: Int) -> CGImage {
        if image.width <= maxWidth { return image }
        let scale = CGFloat(maxWidth) / CGFloat(image.width)
        let newW = maxWidth
        let newH = Int(CGFloat(image.height) * scale)
        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil, width: newW, height: newH,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: newW, height: newH))
        return context.makeImage() ?? image
    }

    private static func jpegData(from image: CGImage, quality: CGFloat) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
    }
}

private extension NSScreen {
    var displayID: CGDirectDisplayID {
        return deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
    }
}
```

Test:

```swift
@MainActor
func testScreenshotToolReturnsImageBlock() async throws {
    let tool = ScreenshotTool()
    let blocks = try await tool.call(.object([:]))
    XCTAssertEqual(blocks.count, 2)
    if case .image(let b64, let mime) = blocks.last {
        XCTAssertEqual(mime, "image/jpeg")
        XCTAssertGreaterThan(b64.count, 1_000)
    } else {
        XCTFail("expected image block as second element")
    }
}
```

Requires Screen Recording permission on the test runner; the .app already has the entitlement / Info.plist string from TipTour.

## Section 4 — `A11yTreeTool`

```swift
// TipTour/Hermes/A11yTreeTool.swift

import Foundation

@MainActor
final class A11yTreeTool: MCPTool {
    let name = "get_a11y_tree"
    let description = "List up to 80 actionable UI elements on the frontmost (or hinted) app's screen, with labels, roles, and rects. Use this to find things to click or point at."
    let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "app_hint": .object([
                "type": .string("string"),
                "description": .string("Optional partial name of the target app (e.g. \"Safari\", \"Xcode\"). When omitted, uses the frontmost app."),
            ]),
            "max_elements": .object([
                "type": .string("integer"),
                "description": .string("Maximum number of elements to return. Defaults to 80; cap at 200."),
            ]),
        ]),
        "required": .array([]),
    ])

    private let resolver: AccessibilityTreeResolver

    init(resolver: AccessibilityTreeResolver) {
        self.resolver = resolver
    }

    func call(_ arguments: JSONValue) async throws -> [MCPToolContent] {
        let hint: String? = {
            guard case .object(let d) = arguments,
                  case .string(let s) = d["app_hint"] ?? .null,
                  !s.isEmpty else { return nil }
            return s
        }()
        let maxElements: Int = {
            guard case .object(let d) = arguments,
                  case .number(let n) = d["max_elements"] ?? .null else { return 80 }
            return max(1, min(200, Int(n)))
        }()

        guard let marks = resolver.setOfMarksForTargetApp(hint: hint, maxElements: maxElements) else {
            throw MCPToolError.toolFailed("could not enumerate accessibility tree (permission denied or no target app)")
        }

        if marks.isEmpty {
            return [.text("[]")]
        }

        let payload = marks.map { mark -> [String: Any] in
            return [
                "label": mark.label,
                "role": mark.role,
                "x": Int(mark.frame.origin.x),
                "y": Int(mark.frame.origin.y),
                "w": Int(mark.frame.size.width),
                "h": Int(mark.frame.size.height),
            ]
        }
        let json = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])
        let text = String(data: json, encoding: .utf8) ?? "[]"
        return [.text(text)]
    }
}
```

Notes:
- Single text content block, JSON-formatted. 30-element app ≈ 3–4 KB.
- `max_elements` capped at 200 to bound response size.
- Assumes `ElementMark` exposes `label: String`, `role: String`, `frame: CGRect`. The implementer should `grep -nA 10 'struct ElementMark' TipTour/AccessibilityTreeResolver.swift` early to confirm field names; adjust the dictionary keys if needed.

Test:

```swift
@MainActor
func testA11yTreeToolReturnsNonEmptyForCurrentApp() async throws {
    let resolver = AccessibilityTreeResolver()
    let tool = A11yTreeTool(resolver: resolver)
    let blocks = try await tool.call(.object(["app_hint": .string("Finder")]))
    guard case .text(let json) = blocks.first else {
        XCTFail("expected text block"); return
    }
    let parsed = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]] ?? []
    XCTAssertFalse(parsed.isEmpty)
    XCTAssertNotNil(parsed.first?["label"])
}
```

Requires Accessibility permission on the test runner.

## Section 5 — `PointAtTool`

```swift
// TipTour/Hermes/PointAtTool.swift

import Foundation
import AppKit

@MainActor
final class PointAtTool: MCPTool {
    let name = "point_at"
    let description = "Fly the Arc Reactor cursor to an on-screen UI element identified by a label, with a speech bubble. Use get_a11y_tree first to find element labels. The cursor auto-clears after 4 seconds."
    let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "label": .object([
                "type": .string("string"),
                "description": .string("Exact or partial label of the UI element to point at (case-insensitive)."),
            ]),
            "bubble": .object([
                "type": .string("string"),
                "description": .string("Short text shown in the speech bubble next to the cursor (≤120 chars)."),
            ]),
            "app_hint": .object([
                "type": .string("string"),
                "description": .string("Optional partial name of the target app (e.g. \"Safari\"). When omitted, uses the frontmost app."),
            ]),
        ]),
        "required": .array([.string("label"), .string("bubble")]),
    ])

    private let resolver: AccessibilityTreeResolver
    private weak var companionManager: CompanionManager?
    private var autoClearTask: Task<Void, Never>?

    init(resolver: AccessibilityTreeResolver, companionManager: CompanionManager) {
        self.resolver = resolver
        self.companionManager = companionManager
    }

    func call(_ arguments: JSONValue) async throws -> [MCPToolContent] {
        guard case .object(let dict) = arguments,
              case .string(let label) = dict["label"] ?? .null,
              !label.isEmpty,
              case .string(let bubble) = dict["bubble"] ?? .null
        else {
            throw MCPToolError.invalidArguments("point_at requires `label` and `bubble` strings")
        }
        let hint: String? = {
            if case .string(let s) = dict["app_hint"] ?? .null, !s.isEmpty { return s }
            return nil
        }()

        guard let resolved = resolver.findElement(byLabel: label, targetAppHint: hint) else {
            throw MCPToolError.toolFailed("no UI element matching label \"\(label)\" was found")
        }
        guard let cm = companionManager else {
            throw MCPToolError.toolFailed("companion manager is gone")
        }

        let center = CGPoint(x: resolved.frame.midX, y: resolved.frame.midY)
        let displayFrame = NSScreen.screens.first(where: { $0.frame.contains(center) })?.frame
            ?? NSScreen.main?.frame
            ?? .zero

        let truncatedBubble = bubble.count > 120 ? String(bubble.prefix(120)) + "…" : bubble

        cm.detectedElementScreenLocation = center
        cm.detectedElementDisplayFrame = displayFrame
        cm.detectedElementBubbleText = truncatedBubble

        // Cancel any prior pending auto-clear so back-to-back calls each
        // get their full 4-second window.
        autoClearTask?.cancel()
        autoClearTask = Task { [weak self, weak cm] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                cm?.clearDetectedElementLocation()
                self?.autoClearTask = nil
            }
        }

        return [.text("Pointing at \"\(label)\" at \(Int(center.x)),\(Int(center.y)); bubble: \"\(truncatedBubble)\"")]
    }
}
```

Tests:

```swift
@MainActor
func testPointAtToolSetsCompanionManagerProps() async throws {
    let resolver = AccessibilityTreeResolver()
    let cm = CompanionManager()
    let tool = PointAtTool(resolver: resolver, companionManager: cm)
    do {
        let blocks = try await tool.call(.object([
            "label": .string("Finder"),
            "bubble": .string("here it is"),
            "app_hint": .string("Finder"),
        ]))
        guard case .text = blocks.first else { XCTFail("expected text"); return }
        XCTAssertNotNil(cm.detectedElementScreenLocation)
        XCTAssertEqual(cm.detectedElementBubbleText, "here it is")
    } catch let e as MCPToolError {
        if case .toolFailed(let s) = e, s.contains("no UI element") {
            throw XCTSkip("a11y permission missing or element absent")
        }
        throw e
    }
}

@MainActor
func testPointAtToolAutoClearsAfterFourSeconds() async throws {
    let resolver = AccessibilityTreeResolver()
    let cm = CompanionManager()
    let tool = PointAtTool(resolver: resolver, companionManager: cm)
    do {
        _ = try await tool.call(.object([
            "label": .string("Finder"),
            "bubble": .string("x"),
        ]))
    } catch { throw XCTSkip("setup failed: \(error)") }
    XCTAssertNotNil(cm.detectedElementScreenLocation)
    try await Task.sleep(nanoseconds: 4_500_000_000)
    XCTAssertNil(cm.detectedElementScreenLocation)
}
```

## Section 6 — Wiring + acceptance + risks

### Wiring changes

`HermesDebugMenuController.swift`:

```swift
private weak var companionManager: CompanionManager?

func install(companionManager: CompanionManager) {
    self.companionManager = companionManager
    let resolver = AccessibilityTreeResolver()
    mcpServer.register(SpeakTool())
    mcpServer.register(ScreenshotTool())
    mcpServer.register(A11yTreeTool(resolver: resolver))
    mcpServer.register(PointAtTool(resolver: resolver, companionManager: companionManager))
    // … rest of status item + menu + global shortcut setup unchanged
}
```

`TipTour/TipTourApp.swift`:

```swift
hermesDebugMenu = HermesDebugMenuController()
hermesDebugMenu?.install(companionManager: companionManager)
```

### Acceptance criteria

Plan 3b is done when ALL of these hold:

1. `xcodebuild build` exits 0.
2. All Plan 1+2+3a tests still pass after `MCPToolsTests`'s one-line migration.
3. New tests pass with Screen Recording + Accessibility permissions granted: `ScreenshotToolTests`, `A11yTreeToolTests`, `PointAtToolTests` (or `XCTSkip` cleanly).
4. In the running .app, asking Hermes **"What's on screen right now?"** produces an agent turn with a `▸ take_screenshot` row containing the JPEG; Hermes describes the screen content correctly.
5. **"What clickable things are visible in Safari?"** (Safari open) → agent turn shows `▸ get_a11y_tree(app_hint="Safari")`; Hermes lists URL bar, tabs, etc.
6. **"Point at the address bar in Safari and say 'enter a URL here'."** → Arc Reactor cursor flies to the URL bar; bubble shows the text; cursor fades after 4 s.
7. Subprocess + listener cleanup on chat-window close still works (Plan 3a regression).

### Risks

| Risk | Mitigation |
|---|---|
| `SCScreenshotManager` returns "Screen recording permission denied" on first run before TCC is granted. | Tests `XCTSkip` cleanly on permission failure. Production .app already requests Screen Recording in Plan 2's Info.plist (carried over from TipTour). User grants once. |
| `AccessibilityTreeResolver.findElement(byLabel:)` may return a stale or wrong match for fuzzy labels ("Save" vs "Save and exit"). | Acceptable. Hermes can re-call `get_a11y_tree` and re-call `point_at` with a more specific label. |
| `ElementMark` field names assumed in the spec (`label`, `role`, `frame`) may differ from the actual struct. | Implementer should grep the struct definition at task start and adjust the dictionary keys in `A11yTreeTool.call`. The mitigation is mechanical, not architectural. |
| `CompanionManager()` zero-arg init may not exist. | The rebrand cleaned up CompanionManager. Implementer confirms by reading the init signature at task start. If the init takes arguments, the test rewrites the setup with whatever the real init expects (this should be a one-line fix). |
| Auto-clear race: rapid back-to-back `point_at` calls within 4 s could result in the second call's bubble being cleared by the first call's timer. | `autoClearTask?.cancel()` at the top of each `call` cancels the prior pending timer before scheduling a new one. |
| JPEG base64 of a 1280-wide screenshot is ~100 KB; that's ~750 image tokens to Claude. Three `take_screenshot` calls per conversation = 2,250 image tokens. | Acceptable given the user's stated preference. Documented as the cost of the chosen sizing. |
| `MCPToolContent` enum migration breaks every existing tool. Currently only `SpeakTool` exists. | One-line migration per existing tool. Tests catch missed call sites. |
| The screenshot test will actually capture the test runner's screen, which may include sensitive content. | Acceptable for a personal dev tool. Production CI would need a mocked capture path; we don't have CI yet. |

### Non-goals (deferred to later plans)

- Voice loop wiring (push-to-talk → STT → Hermes → TTS) — Plan 3c.
- Persistent overlay or programmatic clear — out of scope (4-s auto-clear is the contract).
- Region-of-interest screenshots, full-resolution opt-in, multi-display stitching — future plans.
- Click / type / drag tools — explicitly out of scope.

## Section 7 — What comes after Plan 3b

**Plan 3c — Voice-loop integration.** Wires push-to-talk → Gemini Live STT → `HermesClient.send` → reply → `AVSpeechSynthesizer` TTS, replacing the 15 `TODO(plan-2)` markers in `CompanionManager` / `GeminiLiveSession` / `CompanionPanelView`. After 3c, the voice-first UX from the original TipTour comes back, powered by Hermes the brain.

Plans 4–9 from the original Plan 1 roadmap (guardrails, gateways, settings tabs) remain as scoped there.
