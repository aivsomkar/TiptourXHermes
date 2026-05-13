# Plan 3b — Mac-side Tools (take_screenshot, get_a11y_tree, point_at) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add three Mac-side MCP tools on top of the framework Plan 3a built — `take_screenshot` (downscaled JPEG of the active screen), `get_a11y_tree` (up to 200 actionable UI elements with labels/roles/positions), and `point_at` (fly the Arc Reactor cursor to a labelled element with a speech bubble for 4 seconds). After this plan, the dev chat lets you ask Hermes to "look at the screen", "find clickable things in Safari", and "point at the address bar" — and each works end-to-end.

**Architecture:** Three new `MCPTool` conformers (`ScreenshotTool`, `A11yTreeTool`, `PointAtTool`) register on the existing `MCPServer` alongside `SpeakTool`. The `MCPTool` protocol is widened from `String` to `[MCPToolContent]` (text or image blocks) so screenshots can return image data. Plan 3b reuses TipTour's existing `AccessibilityTreeResolver` and `CompanionManager.detectedElement*` overlay-driving properties — no new screen-capture or a11y-tree infrastructure written.

**Tech Stack:** Swift 5, Foundation, AppKit (`NSWorkspace`, `NSScreen`, `NSBitmapImageRep`), ScreenCaptureKit (`SCScreenshotManager`, `SCShareableContent`), ApplicationServices (`AXUIElement` for frontmost-app focus), Core Graphics (downscaling). Tests in XCTest. Zero new external dependencies.

**Spec:** [docs/superpowers/specs/2026-05-13-plan-3b-mac-tools-design.md](../specs/2026-05-13-plan-3b-mac-tools-design.md)

---

## File-structure summary

**New Swift source files (all in `TipTour/Hermes/`):**

- `ScreenshotTool.swift` — `MCPTool` that captures the frontmost app's screen via `SCScreenshotManager`, downscales to 1280px wide, encodes JPEG q=70, returns text + image blocks.
- `A11yTreeTool.swift` — `MCPTool` that wraps `AccessibilityTreeResolver.setOfMarksForTargetApp(hint:maxElements:)` and serialises the marks to JSON.
- `PointAtTool.swift` — `MCPTool` that resolves a label via `AccessibilityTreeResolver.findElement(byLabel:targetAppHint:)`, writes the resulting position + bubble text into `CompanionManager`'s `@Published` vars, and auto-clears after 4 seconds.

**Modified Swift source files:**

- `TipTour/Hermes/MCPTools.swift` — add `MCPToolContent` enum; change `MCPTool.call` return type from `String` to `[MCPToolContent]`; update `SpeakTool.call` to return `[.text(…)]`.
- `TipTour/Hermes/MCPServer.swift` — the `tools/call` case in `dispatchRPC` builds content blocks from `[MCPToolContent]` (text → `{type:"text", text:…}`, image → `{type:"image", data:…, mimeType:…}`).
- `TipTour/Hermes/HermesDebugMenuController.swift` — `install()` takes `companionManager: CompanionManager`; registers all four tools.
- `TipTour/TipTourApp.swift` — pass `companionManager` to `hermesDebugMenu?.install(companionManager:)`.

**New test files:**

- `TipTourTests/ScreenshotToolTests.swift` — 1 test, asserts text + image blocks with non-trivial JPEG bytes.
- `TipTourTests/A11yTreeToolTests.swift` — 1 test, asserts non-empty parsed JSON for Finder.
- `TipTourTests/PointAtToolTests.swift` — 2 tests: set companion props + auto-clear after 4s.

**Modified test files:**

- `TipTourTests/MCPToolsTests.swift` — one-line update to walk the new `[MCPToolContent]` return type.

**Deliberately NOT modified:**

- Plan 1/2/3a canaries: `HermesBundleTests`, `HermesACPProtocolTests`, `HermesClientTests`, `MCPServerTests` stay untouched.
- The 15 `TODO(plan-2)` markers in `CompanionManager` / `GeminiLiveSession` / `CompanionPanelView` — Plan 3c.

## Verification commands used throughout

**BUILD-CHECK:**
```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  xcodebuild -project tiptour-macos.xcodeproj -scheme tiptour-macos \
             -configuration Debug build 2>&1 | tail -3
```
Expected: `** BUILD SUCCEEDED **`.

**FULL-TEST-CHECK:**
```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  xcodebuild -project tiptour-macos.xcodeproj -scheme tiptour-macos \
             -configuration Debug test 2>&1 | \
  grep -E '^\*\* (TEST|BUILD) (SUCCEEDED|FAILED)'
```
Expected: `** TEST SUCCEEDED **`.

---

## Task 1: Pre-flight rollback tag

**Files:** none (git only).

- [ ] **Step 1: Confirm clean working tree.**

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && git status --short
```
Expected: empty (or only `.claude/`). Stop if anything else is dirty.

- [ ] **Step 2: Tag `pre-plan-3b`.**

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  git tag pre-plan-3b && \
  git tag --list 'pre-*'
```
Expected: prints `pre-plan-2`, `pre-plan-3a`, `pre-plan-3b`, `pre-rebrand`.

---

## Task 2: Migrate `MCPTool` to `[MCPToolContent]` return type

**Files:**
- Modify: `TipTour/Hermes/MCPTools.swift`
- Modify: `TipTour/Hermes/MCPServer.swift`
- Modify: `TipTourTests/MCPToolsTests.swift`

Atomic migration. Changing the protocol return type breaks `SpeakTool`, the server's `tools/call` dispatcher, and the existing tool tests — all in one commit so nothing is broken between commits.

- [ ] **Step 1: Add `MCPToolContent` enum and widen the `MCPTool` protocol in `MCPTools.swift`.**

Find the existing `protocol MCPTool` definition. Insert the new enum BEFORE it and change the protocol's `call` return type:

```swift
// A single piece of content returned by a tool call. Mirrors the MCP
// spec's content-block shape so MCPServer can serialise it directly.
enum MCPToolContent {
    case text(String)
    case image(base64: String, mimeType: String)
}

protocol MCPTool: Sendable {
    var name: String { get }
    var description: String { get }
    var inputSchema: JSONValue { get }
    /// Run the tool. Return one or more content blocks (text, image, or
    /// both). Throw `MCPToolError` to indicate a tool failure.
    @MainActor func call(_ arguments: JSONValue) async throws -> [MCPToolContent]
}
```

- [ ] **Step 2: Update `SpeakTool.call` in the same file.**

Find `SpeakTool.call`. Change ONLY its return statement and signature:

```swift
    func call(_ arguments: JSONValue) async throws -> [MCPToolContent] {
        guard case .object(let dict) = arguments,
              case .string(let text) = dict["text"] ?? .null,
              !text.isEmpty
        else {
            throw MCPToolError.invalidArguments("speak requires a non-empty `text` string")
        }

        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synth.speak(utterance)
        return [.text("Speaking: \(text)")]
    }
```

- [ ] **Step 3: Update `MCPServer.dispatchRPC`'s `tools/call` case in `MCPServer.swift`.**

Find the existing `case "tools/call":` block. Replace it entirely with:

```swift
        case "tools/call":
            guard case .object(let params) = env.params ?? .null,
                  case .string(let toolName) = params["name"] ?? .null,
                  let tool = tools[toolName]
            else {
                respondError(envelope: env, code: -32601,
                             message: "tool not found", on: connection)
                return
            }
            let arguments = params["arguments"] ?? .object([:])
            do {
                let blocks = try await tool.call(arguments)
                let contentJSON: [[String: Any]] = blocks.map { block in
                    switch block {
                    case .text(let s):
                        return ["type": "text", "text": s]
                    case .image(let b64, let mime):
                        return ["type": "image", "data": b64, "mimeType": mime]
                    }
                }
                let result: [String: Any] = [
                    "content": contentJSON,
                    "isError": false,
                ]
                respond(envelope: env, result: result, on: connection)
            } catch {
                let result: [String: Any] = [
                    "content": [["type": "text", "text": "\(error)"]],
                    "isError": true,
                ]
                respond(envelope: env, result: result, on: connection)
            }
```

- [ ] **Step 4: Update `MCPToolsTests.swift` `testSpeakToolCallReturnsSuccessForValidText` to walk the new return type.**

Find that test method and replace the assertion lines (the body of the test). Replace ONLY the test body, keeping the `@MainActor func testSpeakToolCallReturnsSuccessForValidText() async throws {` line and the closing brace:

```swift
        let tool = SpeakTool()
        let blocks = try await tool.call(.object(["text": .string("ok")]))
        guard case .text(let s) = blocks.first else {
            XCTFail("expected text block")
            return
        }
        XCTAssertTrue(s.contains("ok"))
```

- [ ] **Step 5: BUILD-CHECK.** Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Run the full Plan 3a regression gate.**

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  xcodebuild -project tiptour-macos.xcodeproj -scheme tiptour-macos \
             -configuration Debug test \
             -only-testing:tiptour-macosTests/MCPToolsTests \
             -only-testing:tiptour-macosTests/MCPServerTests 2>&1 | \
  grep -E '^\*\* (TEST|BUILD) (SUCCEEDED|FAILED)'
```
Expected: `** TEST SUCCEEDED **`. All 4 `MCPToolsTests` + 5 `MCPServerTests` (testServerStartsAndStops, testInitializeRoundTrip, testToolsListIncludesRegisteredTool, testToolsCallSpeakReturnsSuccess, testToolsCallUnknownToolReturnsError) pass.

- [ ] **Step 7: Commit.**

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  git add TipTour/Hermes/MCPTools.swift TipTour/Hermes/MCPServer.swift \
          TipTourTests/MCPToolsTests.swift && \
  git commit -m "refactor(mcp): MCPTool.call returns [MCPToolContent] for image support

Widens the tool protocol from String to [MCPToolContent] so tools can
emit image content blocks (Plan 3b's ScreenshotTool needs this).
SpeakTool migrates trivially to [.text(...)]. The tools/call wire JSON
maps text/image variants directly. MCPServerTests still pass because
the existing tools/call success test reads result.content[0].text which
still works for text blocks."
```

---

## Task 3: `ScreenshotTool`

**Files:**
- Create: `TipTour/Hermes/ScreenshotTool.swift`
- Create: `TipTourTests/ScreenshotToolTests.swift`

- [ ] **Step 1: Create the failing test file `TipTourTests/ScreenshotToolTests.swift`.**

```swift
import XCTest
@testable import TipTour

final class ScreenshotToolTests: XCTestCase {

    @MainActor
    func testScreenshotToolReturnsImageBlock() async throws {
        let tool = ScreenshotTool()
        let blocks: [MCPToolContent]
        do {
            blocks = try await tool.call(.object([:]))
        } catch let error as MCPToolError {
            // Screen Recording permission not granted yet — skip rather
            // than fail. Production users grant once and the cache sticks.
            if case .toolFailed(let s) = error,
               s.lowercased().contains("permission") || s.lowercased().contains("denied") {
                throw XCTSkip("Screen Recording permission missing: \(s)")
            }
            throw error
        }
        XCTAssertEqual(blocks.count, 2)
        guard case .text(let breadcrumb) = blocks.first else {
            XCTFail("expected text breadcrumb as first block"); return
        }
        XCTAssertFalse(breadcrumb.isEmpty)
        guard case .image(let b64, let mime) = blocks.last else {
            XCTFail("expected image block as last block"); return
        }
        XCTAssertEqual(mime, "image/jpeg")
        XCTAssertGreaterThan(b64.count, 1_000, "expected a non-trivial JPEG")
    }
}
```

- [ ] **Step 2: Run the test; expect a compile failure.**

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  xcodebuild -project tiptour-macos.xcodeproj -scheme tiptour-macos \
             -configuration Debug test \
             -only-testing:tiptour-macosTests/ScreenshotToolTests 2>&1 | tail -5
```
Expected: build fails with "Cannot find 'ScreenshotTool' in scope".

- [ ] **Step 3: Create `TipTour/Hermes/ScreenshotTool.swift`.**

```swift
// TipTour/Hermes/ScreenshotTool.swift
//
// MCP tool that captures the screen the frontmost app is on, downscales
// to 1280px wide, and returns a JPEG image content block (plus a one-
// line text breadcrumb so the chat transcript shows what was captured).
//
// Requires Screen Recording permission for the host process. macOS
// prompts on first use; permission persists.

import Foundation
import AppKit
import ScreenCaptureKit
import ApplicationServices

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
        guard let screen = Self.frontmostAppScreen() ?? NSScreen.main else {
            throw MCPToolError.toolFailed("no screen available")
        }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            throw MCPToolError.toolFailed("SCShareableContent failed — Screen Recording permission may be missing: \(error.localizedDescription)")
        }
        guard let display = content.displays.first(where: { Int($0.displayID) == Int(screen.displayID) }) else {
            throw MCPToolError.toolFailed("could not find SCDisplay for active screen")
        }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.width = Int(display.width)
        config.height = Int(display.height)
        config.scalesToFit = true
        config.showsCursor = false

        let cgImage: CGImage
        do {
            cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            throw MCPToolError.toolFailed("SCScreenshotManager failed: \(error.localizedDescription)")
        }

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

    /// Returns the NSScreen the frontmost app's focused window is on,
    /// or nil if the focused-window position can't be read (e.g. no
    /// frontmost app, or Accessibility permission missing).
    private static func frontmostAppScreen() -> NSScreen? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let appRef = AXUIElementCreateApplication(app.processIdentifier)
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

    /// Downscale a CGImage to `maxWidth` (no-op if already smaller).
    private static func downscale(_ image: CGImage, maxWidth: Int) -> CGImage {
        if image.width <= maxWidth { return image }
        let scale = CGFloat(maxWidth) / CGFloat(image.width)
        let newW = maxWidth
        let newH = Int(CGFloat(image.height) * scale)
        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: newW, height: newH,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return image
        }
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
    /// CGDirectDisplayID for matching against SCDisplay.displayID.
    var displayID: CGDirectDisplayID {
        return deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
    }
}
```

- [ ] **Step 4: Run the test.**

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  xcodebuild -project tiptour-macos.xcodeproj -scheme tiptour-macos \
             -configuration Debug test \
             -only-testing:tiptour-macosTests/ScreenshotToolTests 2>&1 | \
  grep -E '^\*\* (TEST|BUILD) (SUCCEEDED|FAILED)'
```
Expected: `** TEST SUCCEEDED **`. The test may print a brief "Screen Recording permission" prompt the first time it runs against the Xcode test runner. Grant the permission; subsequent runs proceed silently.

- [ ] **Step 5: BUILD-CHECK.** Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit.**

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  git add TipTour/Hermes/ScreenshotTool.swift TipTourTests/ScreenshotToolTests.swift && \
  git commit -m "feat(mcp): take_screenshot tool

Captures the screen the frontmost app's focused window is on, downscales
to max 1280px wide, encodes JPEG q=70. Returns a one-line text
breadcrumb + the image content block. Falls back to NSScreen.main when
the frontmost app's window position can't be read."
```

---

## Task 4: `A11yTreeTool`

**Files:**
- Create: `TipTour/Hermes/A11yTreeTool.swift`
- Create: `TipTourTests/A11yTreeToolTests.swift`

Important: `ElementMark` exposes `{role, label, center: CGPoint}` (no `frame`). The tool returns `{label, role, x, y}` per element — coordinates are the element's center, not a rect.

- [ ] **Step 1: Create the failing test file `TipTourTests/A11yTreeToolTests.swift`.**

```swift
import XCTest
@testable import TipTour

final class A11yTreeToolTests: XCTestCase {

    @MainActor
    func testA11yTreeToolReturnsNonEmptyForFinder() async throws {
        let resolver = AccessibilityTreeResolver()
        let tool = A11yTreeTool(resolver: resolver)
        let blocks: [MCPToolContent]
        do {
            blocks = try await tool.call(.object(["app_hint": .string("Finder")]))
        } catch let error as MCPToolError {
            if case .toolFailed(let s) = error,
               s.lowercased().contains("permission") || s.lowercased().contains("no target") {
                throw XCTSkip("Accessibility permission missing or Finder absent: \(s)")
            }
            throw error
        }
        guard case .text(let json) = blocks.first else {
            XCTFail("expected text block"); return
        }
        let parsed = (try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]]) ?? []
        XCTAssertFalse(parsed.isEmpty, "expected at least one element for Finder")
        XCTAssertNotNil(parsed.first?["label"])
        XCTAssertNotNil(parsed.first?["role"])
    }
}
```

- [ ] **Step 2: Run the test; expect compile failure.**

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  xcodebuild -project tiptour-macos.xcodeproj -scheme tiptour-macos \
             -configuration Debug test \
             -only-testing:tiptour-macosTests/A11yTreeToolTests 2>&1 | tail -5
```
Expected: "Cannot find 'A11yTreeTool' in scope".

- [ ] **Step 3: Create `TipTour/Hermes/A11yTreeTool.swift`.**

```swift
// TipTour/Hermes/A11yTreeTool.swift
//
// MCP tool that returns up to 200 actionable UI elements in the
// frontmost (or hinted) app, with labels, roles, and center positions.
// Wraps AccessibilityTreeResolver.setOfMarksForTargetApp.
//
// ElementMark's actual shape: { role: String, label: String, center: CGPoint }.
// (No frame — only center coordinates.) The JSON output reflects that:
// each element is { label, role, x, y } where x/y are the global-screen
// center coordinates of the element.

import Foundation

@MainActor
final class A11yTreeTool: MCPTool {
    let name = "get_a11y_tree"
    let description = "List up to 80 actionable UI elements on the frontmost (or hinted) app's screen, with labels, roles, and center positions. Use this to find things to click or point at."
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

        let payload: [[String: Any]] = marks.map { mark in
            return [
                "label": mark.label,
                "role": mark.role,
                "x": Int(mark.center.x),
                "y": Int(mark.center.y),
            ]
        }
        let json = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])
        let text = String(data: json, encoding: .utf8) ?? "[]"
        return [.text(text)]
    }
}
```

- [ ] **Step 4: Run the test.**

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  xcodebuild -project tiptour-macos.xcodeproj -scheme tiptour-macos \
             -configuration Debug test \
             -only-testing:tiptour-macosTests/A11yTreeToolTests 2>&1 | \
  grep -E '^\*\* (TEST|BUILD) (SUCCEEDED|FAILED)'
```
Expected: `** TEST SUCCEEDED **`. First run may prompt for Accessibility permission for the Xcode test runner; grant and re-run.

- [ ] **Step 5: BUILD-CHECK.** Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit.**

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  git add TipTour/Hermes/A11yTreeTool.swift TipTourTests/A11yTreeToolTests.swift && \
  git commit -m "feat(mcp): get_a11y_tree tool

Wraps AccessibilityTreeResolver.setOfMarksForTargetApp. Returns a JSON
array of {label, role, x, y} per actionable element (up to 200, default
80). x/y are the element's center coordinates — ElementMark exposes
center: CGPoint, not a frame. Hermes uses the labels in subsequent
point_at calls to disambiguate fuzzy matches."
```

---

## Task 5: `PointAtTool`

**Files:**
- Create: `TipTour/Hermes/PointAtTool.swift`
- Create: `TipTourTests/PointAtToolTests.swift`

Important: `ResolvedElement.screenFrame: CGRect` (not `frame`). Use `screenFrame.midX`/`midY`.

- [ ] **Step 1: Create the failing test file `TipTourTests/PointAtToolTests.swift`.**

```swift
import XCTest
@testable import TipTour

final class PointAtToolTests: XCTestCase {

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
            guard case .text = blocks.first else {
                XCTFail("expected text block"); return
            }
            XCTAssertNotNil(cm.detectedElementScreenLocation)
            XCTAssertEqual(cm.detectedElementBubbleText, "here it is")
        } catch let error as MCPToolError {
            if case .toolFailed(let s) = error, s.contains("no UI element") {
                throw XCTSkip("a11y permission missing or element absent: \(s)")
            }
            throw error
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
        } catch {
            throw XCTSkip("setup failed: \(error)")
        }
        XCTAssertNotNil(cm.detectedElementScreenLocation)
        // Sleep slightly past the 4-second auto-clear window.
        try await Task.sleep(nanoseconds: 4_500_000_000)
        XCTAssertNil(cm.detectedElementScreenLocation,
                     "PointAtTool should auto-clear CompanionManager state after 4 seconds")
    }
}
```

- [ ] **Step 2: Run the tests; expect compile failure.**

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  xcodebuild -project tiptour-macos.xcodeproj -scheme tiptour-macos \
             -configuration Debug test \
             -only-testing:tiptour-macosTests/PointAtToolTests 2>&1 | tail -5
```
Expected: "Cannot find 'PointAtTool' in scope".

- [ ] **Step 3: Create `TipTour/Hermes/PointAtTool.swift`.**

```swift
// TipTour/Hermes/PointAtTool.swift
//
// MCP tool that flies the Arc Reactor cursor to a labelled UI element
// and shows a speech bubble next to it. Resolves the label via the
// existing AccessibilityTreeResolver.findElement; drives the overlay
// by writing to CompanionManager's @Published vars. Auto-clears the
// cursor after 4 seconds.

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
    /// Token that's cancelled when a new point_at call arrives, so a stacked
    /// pair doesn't fight over the auto-clear timer.
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

        // ResolvedElement.screenFrame is a CGRect in global AppKit coords.
        let center = CGPoint(x: resolved.screenFrame.midX, y: resolved.screenFrame.midY)
        let displayFrame = NSScreen.screens.first(where: { $0.frame.contains(center) })?.frame
            ?? NSScreen.main?.frame
            ?? .zero

        let truncatedBubble = bubble.count > 120 ? String(bubble.prefix(120)) + "…" : bubble

        cm.detectedElementScreenLocation = center
        cm.detectedElementDisplayFrame = displayFrame
        cm.detectedElementBubbleText = truncatedBubble

        // Cancel any pending auto-clear so back-to-back calls each get
        // their full 4-second window.
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

- [ ] **Step 4: Run the tests.**

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  xcodebuild -project tiptour-macos.xcodeproj -scheme tiptour-macos \
             -configuration Debug test \
             -only-testing:tiptour-macosTests/PointAtToolTests 2>&1 | \
  grep -E '^\*\* (TEST|BUILD) (SUCCEEDED|FAILED)'
```
Expected: `** TEST SUCCEEDED **`. The auto-clear test takes ~5 seconds; that's normal.

- [ ] **Step 5: BUILD-CHECK.** Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit.**

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  git add TipTour/Hermes/PointAtTool.swift TipTourTests/PointAtToolTests.swift && \
  git commit -m "feat(mcp): point_at tool

Resolves label via AccessibilityTreeResolver.findElement, computes
center from ResolvedElement.screenFrame, writes to CompanionManager's
@Published detectedElement* properties to trigger the existing Arc
Reactor overlay animation. Auto-clears after 4 seconds; back-to-back
calls each get their full window via Task cancellation."
```

---

## Task 6: Wire `HermesDebugMenuController` + `TipTourApp`

**Files:**
- Modify: `TipTour/Hermes/HermesDebugMenuController.swift`
- Modify: `TipTour/TipTourApp.swift`

- [ ] **Step 1: Update `HermesDebugMenuController.swift`.**

Open `TipTour/Hermes/HermesDebugMenuController.swift`. Find the existing `install()` method. Replace the property declarations + `install()` with:

```swift
    private var statusItem: NSStatusItem?
    private var window: NSWindow?
    private let client = HermesClient()
    private let mcpServer = MCPServer(name: "tiptour-tools")
    private weak var companionManager: CompanionManager?
    private var globalMonitor: Any?
    private var localMonitor: Any?

    func install(companionManager: CompanionManager) {
        self.companionManager = companionManager

        // Build a shared AccessibilityTreeResolver so A11yTreeTool and
        // PointAtTool see the same a11y cache + permissions state.
        let resolver = AccessibilityTreeResolver()

        mcpServer.register(SpeakTool())
        mcpServer.register(ScreenshotTool())
        mcpServer.register(A11yTreeTool(resolver: resolver))
        mcpServer.register(PointAtTool(resolver: resolver, companionManager: companionManager))

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "🛠 Hermes"
        item.button?.toolTip = "Hermes Debug"

        let menu = NSMenu()

        let header = NSMenuItem(title: "Hermes Debug", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let talk = NSMenuItem(title: "Talk to Hermes…", action: #selector(openChat), keyEquivalent: "h")
        talk.keyEquivalentModifierMask = [.option, .shift]
        talk.target = self
        menu.addItem(talk)

        item.menu = menu
        self.statusItem = item

        installGlobalShortcut()
    }
```

Everything below `install()` (the global shortcut, `openChat`, `windowWillClose`, etc.) stays unchanged.

- [ ] **Step 2: Update `TipTour/TipTourApp.swift` to pass `companionManager` to `install()`.**

Find this block (around the `applicationDidFinishLaunching` method):

```swift
        hermesDebugMenu = HermesDebugMenuController()
        hermesDebugMenu?.install()
```

Replace with:

```swift
        hermesDebugMenu = HermesDebugMenuController()
        hermesDebugMenu?.install(companionManager: companionManager)
```

- [ ] **Step 3: BUILD-CHECK.** Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Full test gate (all Plan 1+2+3a+3b suites).**

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  xcodebuild -project tiptour-macos.xcodeproj -scheme tiptour-macos \
             -configuration Debug test 2>&1 | \
  grep -E '^\*\* (TEST|BUILD) (SUCCEEDED|FAILED)'
```
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit.**

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  git add TipTour/Hermes/HermesDebugMenuController.swift TipTour/TipTourApp.swift && \
  git commit -m "feat(hermes): register Mac tools (screenshot, a11y_tree, point_at)

HermesDebugMenuController.install() now takes a CompanionManager and
registers all four tools on the MCP server. A single
AccessibilityTreeResolver is shared between A11yTreeTool and
PointAtTool so they see the same a11y cache and permission state.
TipTourApp passes companionManager through from CompanionAppDelegate."
```

---

## Task 7: Manual end-to-end verification + acceptance gate

No edits. Runs the spec's acceptance criteria.

- [ ] **Step 1: BUILD-CHECK.** Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 2: Full test gate.**

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  xcodebuild -project tiptour-macos.xcodeproj -scheme tiptour-macos \
             -configuration Debug test 2>&1 | \
  grep -E '^\*\* (TEST|BUILD) (SUCCEEDED|FAILED)'
```
Expected: `** TEST SUCCEEDED **`. New tests (`ScreenshotToolTests`, `A11yTreeToolTests`, `PointAtToolTests`) may `XCTSkip` if Screen Recording / Accessibility permission isn't granted to the test runner — that's acceptable as a regression gate.

- [ ] **Step 3: Python smoke test (Plan 1 canary).**

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  PYTHONUNBUFFERED=1 ./Tests/Python/smoke_test_acp.py | tail -3
```
Expected: `PASS` (full cycle with user's `~/.hermes/.env` ANTHROPIC_API_KEY).

- [ ] **Step 4: Kill leftovers + relaunch.**

```bash
pkill -x TipTour_Hermes 2>/dev/null
pkill -f 'hermes-runtime.*acp_adapter' 2>/dev/null
sleep 1
APP=$(find ~/Library/Developer/Xcode/DerivedData -name 'TipTour_Hermes.app' -path '*/Debug/*' 2>/dev/null | head -1)
echo "Opening: $APP"
open "$APP"
sleep 1
```

- [ ] **Step 5: Open Safari (or any browser) so there's a real a11y target.**

- [ ] **Step 6: Live verification of acceptance criteria.**

In the running app, press **⌥⇧H** to open the chat window.

  - [ ] Type **`What's on screen right now?`** and press Enter. Expected: agent turn with a `▸ take_screenshot ...` row containing the captured JPEG (click the disclosure to see the args + breadcrumb). Hermes describes the current screen content correctly.
  - [ ] Type **`What clickable things are visible in Safari?`** Expected: agent turn with `▸ get_a11y_tree(app_hint="Safari") ...` row; Hermes lists URL bar, tabs, etc.
  - [ ] Type **`Point at the address bar in Safari and say 'enter a URL here'.`** Expected: agent turn with `▸ point_at(label="address bar", ...) ...` row; the Arc Reactor cursor flies to the URL bar on screen; speech bubble shows "enter a URL here"; the cursor fades after ~4 seconds.
  - [ ] Close the chat window. Run in a terminal:

```bash
ps ax | grep -v grep | grep hermes-runtime || echo "(none)"
lsof -iTCP:LISTEN -P 2>/dev/null | grep TipTour_Hermes || echo "(no listeners)"
```

Both should report nothing — subprocess + MCP listener cleanly torn down (Plan 3a regression).

- [ ] **Step 7: No commit — Task 6's commit is the final state.**

Plan 3b is complete when all six steps above pass.

---

## Rollback procedure

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  git status --short && \
  git reset --hard pre-plan-3b
```

Each task's commit is independently revertable via `git revert <sha>`.

---

## What comes after Plan 3b

**Plan 3c — Voice-loop integration.** Push-to-talk → Gemini Live STT → `HermesClient.send` → reply → `AVSpeechSynthesizer` TTS. Replaces the 15 `TODO(plan-2)` markers in `CompanionManager` / `GeminiLiveSession` / `CompanionPanelView`. End state: hold push-to-talk, say "what's on screen?", hear Hermes answer.
