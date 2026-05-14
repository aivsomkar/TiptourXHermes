# Plan 4 — Hermes Runtime Production-Readiness

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the four gaps that block real first-time users on the existing bundled-Hermes runtime: (1) no in-app provider-key entry so chat just errors out, (2) Python subprocess survives Mac-app crashes, (3) Hermes git ref is `main` (mutable) and invisible in UI, (4) runtime errors surface as opaque transcript lines instead of actionable prompts.

**Architecture:** All changes are additive to existing files, plus four new Swift files (`HermesConfigBootstrapper`, `FirstRunSetupView`, `HermesRuntimeVersion`, `HermesSetupCoordinator`) and one new Python file (`parent_watchdog.py`). The single existing touchpoint in `HermesClient` is `launchSubprocessIfNeeded` — it gains an env-injection step and a pre-flight bootstrapper check. UI hooks into the existing `footerSection` in `CompanionPanelView` and the existing system-error rendering in `HermesChatWindow`. Production codesigning + notarization are explicitly **out of scope** (Plan 7+ per `BuildScripts/README.md`); this plan only ensures the bundle is *capable* of being notarized cleanly.

**Tech stack:** SwiftUI for the first-run sheet, existing `KeychainStore` for provider keys, hand-emitted YAML strings for `config.yaml` (Hermes's minimum schema is two fields — no YAML library needed), Python stdlib `os` for the PID watcher, XCTest with `@MainActor async` for unit tests, established `HermesBundleTests` pattern for integration tests.

---

## File structure

**Create:**
- `TipTour/Hermes/HermesConfigBootstrapper.swift` — writes `~/.hermes/config.yaml`, detects "needs setup"
- `TipTour/Hermes/HermesRuntimeVersion.swift` — reads `hermes-version.txt` from bundle
- `TipTour/Hermes/HermesSetupCoordinator.swift` — orchestrates needs-setup state across `HermesClient`, Keychain, bootstrapper
- `TipTour/Hermes/FirstRunSetupView.swift` — SwiftUI sheet for provider+key entry
- `BuildScripts/runtime-assets/parent_watchdog.py` — orphan-cleanup watchdog
- `TipTourTests/HermesConfigBootstrapperTests.swift`
- `TipTourTests/HermesRuntimeVersionTests.swift`
- `TipTourTests/HermesSetupCoordinatorTests.swift`
- `TipTourTests/Fixtures/sample-hermes-version.txt` — test fixture

**Modify:**
- `BuildScripts/bundle-hermes.sh` — pin `HERMES_GIT_REF` to a SHA, write `hermes-version.txt`, copy `parent_watchdog.py` into bundle, wrap the entrypoint to launch the watchdog
- `TipTour/Hermes/HermesClient.swift` — pre-flight needs-setup check in `send`; inject Keychain provider keys into subprocess env in `launchSubprocessIfNeeded`; extend `HermesClientError`
- `TipTour/KeychainStore.swift` — add `geminiAPIKey` is already there, but rename usage to `googleAPIKey` to match Hermes's `google` provider string (preserves backward-compat by aliasing)
- `TipTour/CompanionPanelView.swift` — add "Set up Hermes…" footer button gated on `HermesSetupCoordinator.needsSetup`; show Hermes version line in Dev panel
- `TipTour/Hermes/HermesChatWindow.swift` — render an inline "Set Up Hermes…" button when the latest transcript entry is a structured setup-needed system error
- `BuildScripts/README.md` — document the new version file, watchdog, and bootstrap flow
- `AGENTS.md` (the file `CLAUDE.md` symlinks to) — add new files to the Key Files table; update the Hermes runtime architecture description

**Do NOT modify (load-bearing, leave alone):**
- `TipTour/Hermes/HermesACPProtocol.swift` (protocol types — schema-stable)
- `TipTour/Hermes/MCPServer.swift` and MCP tool files (Plan 3b territory)
- `TipTour/TipTour.entitlements` (current entitlements are correct for non-sandboxed dev)
- `Tests/Python/smoke_test_acp.py` (independent CLI smoke test; do NOT couple it to Swift changes)

---

## Workstream A — Discovery + test harness

### Task A1: Capture minimum viable config.yaml as a reference

**Files:**
- Create: `BuildScripts/runtime-assets/reference-config.yaml`

The user's `~/.hermes/config.yaml` (which already works against the bundled runtime) is the canonical minimum we'll emit from Swift.

- [ ] **Step 1: Inspect the user's working config**

Run: `cat ~/.hermes/config.yaml`
Expected output (two top-level fields under `model`):
```yaml
model:
  default: "anthropic/claude-haiku-4-5"
  provider: "anthropic"
```

- [ ] **Step 2: Write the reference template**

Create `BuildScripts/runtime-assets/reference-config.yaml`:
```yaml
# Reference shape for ~/.hermes/config.yaml.
# HermesConfigBootstrapper emits this template with the user's chosen
# provider substituted in. Provider names match keys in Hermes's
# models_dev_cache.json (verified 2026-05-14): anthropic, openai, google.
#
# Default model per provider:
#   anthropic → anthropic/claude-haiku-4-5     (fast, cheap, capable)
#   openai    → openai/gpt-4o-mini             (fast, cheap)
#   google    → google/gemini-flash-lite-latest (fast, cheap)
model:
  default: "<provider>/<model>"
  provider: "<provider>"
```

- [ ] **Step 3: Commit**

```bash
git add BuildScripts/runtime-assets/reference-config.yaml
git commit -m "docs(hermes): reference shape for bootstrapped config.yaml"
```

### Task A2: Add bootstrapper test scaffolding

**Files:**
- Create: `TipTourTests/HermesConfigBootstrapperTests.swift`
- Create: `TipTourTests/Fixtures/.gitkeep` (if not already present)

- [ ] **Step 1: Write the failing scaffold**

Create `TipTourTests/HermesConfigBootstrapperTests.swift`:
```swift
import XCTest
@testable import TipTour

/// Tests run against an isolated temp directory passed as HERMES_HOME,
/// so they never touch the user's real ~/.hermes. Each test wipes its
/// own tempdir on teardown to avoid leaking state between runs.
final class HermesConfigBootstrapperTests: XCTestCase {

    private var tempHome: URL!

    override func setUpWithError() throws {
        tempHome = try makeTempHome()
    }

    override func tearDownWithError() throws {
        if let url = tempHome,
           FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func makeTempHome() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("hermes-bootstrapper-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    func testPlaceholderExistsSoTestTargetCompiles() {
        XCTAssertTrue(true)
    }
}
```

- [ ] **Step 2: Run to verify it compiles**

Run: open Xcode, select `TipTourTests` scheme, run only `HermesConfigBootstrapperTests`.
Expected: 1 test runs and passes. If the test target can't see `@testable import TipTour`, the file isn't a member of `TipTourTests` — fix by adding it in Xcode's File Inspector → Target Membership.

- [ ] **Step 3: Commit**

```bash
git add TipTourTests/HermesConfigBootstrapperTests.swift
git commit -m "test(hermes): scaffold HermesConfigBootstrapperTests with temp HERMES_HOME"
```

---

## Workstream B — Hermes version pinning + UI surface

### Task B1: Pin HERMES_GIT_REF to a specific commit

**Files:**
- Modify: `BuildScripts/bundle-hermes.sh:14`

Today `HERMES_GIT_REF` defaults to `main`, which makes builds non-reproducible. Pin to the current `main` SHA so the .app records exactly what shipped.

- [ ] **Step 1: Get the current Hermes main SHA**

Run:
```bash
curl -sL https://api.github.com/repos/NousResearch/hermes-agent/commits/main | \
  python3 -c 'import json,sys; print(json.load(sys.stdin)["sha"][:40])'
```
Expected: a 40-char hex SHA, e.g. `a1b2c3d4e5f6...`. Capture the value; you'll paste it into the script in Step 2.

- [ ] **Step 2: Pin the SHA in the bundler**

Edit `BuildScripts/bundle-hermes.sh`. Replace line 14:
```bash
HERMES_GIT_REF="${HERMES_GIT_REF:-main}"
```
with (substitute `<SHA>` with the value from Step 1):
```bash
# Pinned 2026-05-14. Reproducible-build requirement: every CI/release
# build resolves the same Hermes source. To upgrade, replace this SHA
# AND rebuild reference-config.yaml against the new model_dev_cache
# (provider names rarely change but model defaults do).
HERMES_GIT_REF="${HERMES_GIT_REF:-<SHA>}"
```

- [ ] **Step 3: Rebuild the bundle to verify the SHA resolves**

Run:
```bash
rm -rf build/hermes-runtime
./BuildScripts/bundle-hermes.sh build/hermes-runtime 2>&1 | tail -5
```
Expected: ends with `✓ Bundled Hermes ready at …/build/hermes-runtime`. If pip fails with a 404 for the SHA, the SHA was typo'd — re-verify Step 1's output.

- [ ] **Step 4: Commit**

```bash
git add BuildScripts/bundle-hermes.sh
git commit -m "build(hermes): pin HERMES_GIT_REF to specific SHA for reproducible builds"
```

### Task B2: Emit hermes-version.txt during bundling

**Files:**
- Modify: `BuildScripts/bundle-hermes.sh` (insert before the final `echo "✓ Bundled Hermes ready..."`)

- [ ] **Step 1: Add the version-file writer**

In `BuildScripts/bundle-hermes.sh`, insert this block immediately after the `xattr -cr` line (around line 63) and BEFORE the codesigning find/xargs block:
```bash
# Write a machine-readable version manifest the Swift app can read from
# Bundle.main.resourceURL. Format: one "key=value" per line, ASCII only.
# Fields:
#   hermes_git_ref     The SHA we pinned to in this script
#   hermes_version     pip-reported version of hermes-agent (may be the
#                      same across SHAs if upstream hasn't bumped __version__)
#   python_version     CPython version reported by the bundled interpreter
#   python_build       astral-sh/python-build-standalone release tag
#   bundled_at         ISO-8601 UTC timestamp this bundle was produced
echo "→ Writing hermes-version.txt"
HERMES_VER="$("$PYTHON_BIN" -c 'import importlib.metadata; print(importlib.metadata.version("hermes-agent"))' 2>/dev/null || echo "unknown")"
PY_VER="$("$PYTHON_BIN" -c 'import sys; print(".".join(map(str, sys.version_info[:3])))')"
NOW="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
cat > "$OUT_DIR/hermes-version.txt" <<VERSION_EOF
hermes_git_ref=$HERMES_GIT_REF
hermes_version=$HERMES_VER
python_version=$PY_VER
python_build=$PYTHON_BUILD
bundled_at=$NOW
VERSION_EOF
```

- [ ] **Step 2: Re-run the bundler**

Run: `./BuildScripts/bundle-hermes.sh build/hermes-runtime 2>&1 | tail -10`
Expected: log includes `→ Writing hermes-version.txt`.

- [ ] **Step 3: Verify the file**

Run: `cat build/hermes-runtime/hermes-version.txt`
Expected: 5 `key=value` lines, all non-empty values. The `hermes_git_ref` matches what you pinned in B1.

- [ ] **Step 4: Commit**

```bash
git add BuildScripts/bundle-hermes.sh
git commit -m "build(hermes): emit hermes-version.txt with pinned SHA + python build"
```

### Task B3: Write HermesRuntimeVersion.swift

**Files:**
- Create: `TipTour/Hermes/HermesRuntimeVersion.swift`
- Create: `TipTourTests/Fixtures/sample-hermes-version.txt`
- Create: `TipTourTests/HermesRuntimeVersionTests.swift`

- [ ] **Step 1: Write the failing test**

Create `TipTourTests/Fixtures/sample-hermes-version.txt`:
```
hermes_git_ref=abc1234deadbeef
hermes_version=0.13.0
python_version=3.11.15
python_build=20260510
bundled_at=2026-05-14T18:00:00Z
```

Create `TipTourTests/HermesRuntimeVersionTests.swift`:
```swift
import XCTest
@testable import TipTour

final class HermesRuntimeVersionTests: XCTestCase {

    private func fixtureURL() -> URL {
        Bundle(for: HermesRuntimeVersionTests.self)
            .url(forResource: "sample-hermes-version", withExtension: "txt")!
    }

    func testParsesAllFiveFieldsFromFixture() throws {
        let version = try HermesRuntimeVersion.read(from: fixtureURL())
        XCTAssertEqual(version.hermesGitRef, "abc1234deadbeef")
        XCTAssertEqual(version.hermesVersion, "0.13.0")
        XCTAssertEqual(version.pythonVersion, "3.11.15")
        XCTAssertEqual(version.pythonBuild, "20260510")
        XCTAssertEqual(version.bundledAt, "2026-05-14T18:00:00Z")
    }

    func testShortDisplayStringIsHumanReadable() throws {
        let version = try HermesRuntimeVersion.read(from: fixtureURL())
        // Short string for footer display — readable, ~50 chars max.
        XCTAssertEqual(
            version.shortDisplayString,
            "Hermes 0.13.0 (abc1234) · Python 3.11.15"
        )
    }

    func testMissingFileThrowsReadableError() {
        let bogus = URL(fileURLWithPath: "/nonexistent/hermes-version.txt")
        XCTAssertThrowsError(try HermesRuntimeVersion.read(from: bogus)) { error in
            XCTAssertTrue(error is HermesRuntimeVersion.ReadError)
        }
    }

    func testMalformedFileThrowsReadableError() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("malformed-\(UUID()).txt")
        try "not a key value file at all".write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }
        XCTAssertThrowsError(try HermesRuntimeVersion.read(from: tmp)) { error in
            guard case HermesRuntimeVersion.ReadError.missingField(let field) = error else {
                return XCTFail("expected missingField, got \(error)")
            }
            // Any of the five required fields can be the first missing one.
            XCTAssertTrue(
                ["hermes_git_ref", "hermes_version", "python_version",
                 "python_build", "bundled_at"].contains(field)
            )
        }
    }
}
```

- [ ] **Step 2: Verify it fails to compile (HermesRuntimeVersion doesn't exist yet)**

Run in Xcode: test target compile.
Expected: build error `cannot find 'HermesRuntimeVersion' in scope`.

- [ ] **Step 3: Implement the type**

Create `TipTour/Hermes/HermesRuntimeVersion.swift`:
```swift
// TipTour/Hermes/HermesRuntimeVersion.swift
//
// Reads the version manifest emitted by BuildScripts/bundle-hermes.sh.
// Format: one "key=value" per line, ASCII only. All five fields required.

import Foundation

struct HermesRuntimeVersion: Equatable {
    let hermesGitRef: String
    let hermesVersion: String
    let pythonVersion: String
    let pythonBuild: String
    let bundledAt: String

    enum ReadError: Error, Equatable, CustomStringConvertible {
        case fileMissing(URL)
        case missingField(String)
        case unreadable(String)

        var description: String {
            switch self {
            case .fileMissing(let url):
                return "hermes-version.txt missing at \(url.path)"
            case .missingField(let field):
                return "hermes-version.txt missing required field '\(field)'"
            case .unreadable(let why):
                return "hermes-version.txt unreadable: \(why)"
            }
        }
    }

    /// Resolves the bundle copy of `hermes-version.txt`. Returns nil if
    /// the bundle is missing the resource — callers can treat that as a
    /// dev-build that didn't run the bundler.
    static var bundledURL: URL? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let url = resources
            .appendingPathComponent("hermes-runtime", isDirectory: true)
            .appendingPathComponent("hermes-version.txt")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func read(from url: URL) throws -> HermesRuntimeVersion {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ReadError.fileMissing(url)
        }
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw ReadError.unreadable("\(error)")
        }
        var fields: [String: String] = [:]
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            fields[key] = value
        }
        func required(_ key: String) throws -> String {
            guard let v = fields[key], !v.isEmpty else { throw ReadError.missingField(key) }
            return v
        }
        return HermesRuntimeVersion(
            hermesGitRef: try required("hermes_git_ref"),
            hermesVersion: try required("hermes_version"),
            pythonVersion: try required("python_version"),
            pythonBuild: try required("python_build"),
            bundledAt: try required("bundled_at")
        )
    }

    /// Short, single-line string for the Dev panel footer.
    /// Format: "Hermes <version> (<sha7>) · Python <python_version>"
    var shortDisplayString: String {
        let shortRef = String(hermesGitRef.prefix(7))
        return "Hermes \(hermesVersion) (\(shortRef)) · Python \(pythonVersion)"
    }
}
```

- [ ] **Step 4: Run the tests; verify all four pass**

Run in Xcode: `HermesRuntimeVersionTests`.
Expected: 4/4 tests pass. If `testParsesAllFiveFieldsFromFixture` can't find the resource, the fixture isn't in the test bundle — add `TipTourTests/Fixtures/sample-hermes-version.txt` to Target Membership for `TipTourTests` in File Inspector.

- [ ] **Step 5: Commit**

```bash
git add TipTour/Hermes/HermesRuntimeVersion.swift \
        TipTourTests/HermesRuntimeVersionTests.swift \
        TipTourTests/Fixtures/sample-hermes-version.txt
git commit -m "feat(hermes): HermesRuntimeVersion reads bundled hermes-version.txt"
```

### Task B4: Surface the version in the Dev panel

**Files:**
- Modify: `TipTour/CompanionPanelView.swift`

- [ ] **Step 1: Locate the Dev section**

Run: `grep -n 'showDevTools\|devSection\|Dev\b' TipTour/CompanionPanelView.swift | head -10`
Expected: find the existing `devSection` (or equivalent) view — that's where we'll add the version line. Identify the SwiftUI view function name and the existing styling (font + foreground color).

- [ ] **Step 2: Add the version line inside the Dev section**

In `TipTour/CompanionPanelView.swift`, inside the existing Dev section's `VStack` (after any existing rows), add:
```swift
// Hermes runtime version — load lazily on first appearance.
if let version = (try? HermesRuntimeVersion.bundledURL.flatMap { try HermesRuntimeVersion.read(from: $0) }) {
    HStack {
        Text(version.shortDisplayString)
            .font(.system(size: 10, design: .monospaced))
            .foregroundColor(DS.Colors.textTertiary)
        Spacer()
    }
    .padding(.top, 4)
}
```

(If `DS.Colors.textTertiary` doesn't exist, substitute the dimmest existing token from `DesignSystem.swift` — grep `DS.Colors.text` to find the options.)

- [ ] **Step 3: Manual verify**

Build + run in Xcode. Open the menu bar panel, click the Dev button to expand the Dev section. Expected: a small monospaced line showing `Hermes <version> (<sha7>) · Python 3.11.15`.

- [ ] **Step 4: Commit**

```bash
git add TipTour/CompanionPanelView.swift
git commit -m "feat(hermes): show runtime version in Dev panel"
```

---

## Workstream C — Parent-PID watcher

### Task C1: Write the watchdog Python script

**Files:**
- Create: `BuildScripts/runtime-assets/parent_watchdog.py`

The watchdog runs as a sibling Python process. It polls `os.getppid()`; when the PPID transitions to 1 (init/launchd reaped it) it sends SIGTERM to a target PID we pass on the command line.

- [ ] **Step 1: Write the script**

Create `BuildScripts/runtime-assets/parent_watchdog.py`:
```python
#!/usr/bin/env python3
"""
parent_watchdog.py — terminate a target PID when our parent process dies.

Launched as a sibling of the Hermes ACP adapter from hermes-runtime
(the shell entrypoint). Polls os.getppid() every POLL_INTERVAL_SECONDS;
when it returns 1, the original parent (the Mac app) has been reaped
and we SIGTERM the target. After GRACE_SECONDS, escalates to SIGKILL.

Why a separate process and not signal-handling inside the ACP adapter?
acp_adapter takes ownership of SIGTERM/SIGINT for its own shutdown flow.
A separate tiny process lets us own orphan-cleanup without changing
upstream behavior.

Usage:
  python3 parent_watchdog.py <target_pid>

Exits 0 on successful termination, 1 if the target was already gone,
2 on argument error.
"""

from __future__ import annotations

import os
import signal
import sys
import time

POLL_INTERVAL_SECONDS = 0.5
GRACE_SECONDS = 3.0


def _process_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        # Process exists but we can't signal it. Treat as alive.
        return True


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(f"usage: {argv[0]} <target_pid>", file=sys.stderr)
        return 2
    try:
        target = int(argv[1])
    except ValueError:
        print(f"invalid pid: {argv[1]}", file=sys.stderr)
        return 2

    # Start state. If we already lost our parent before we got going,
    # bail immediately — don't keep an orphaned process alive.
    while True:
        ppid = os.getppid()
        if ppid == 1:
            break
        if not _process_alive(target):
            return 1
        time.sleep(POLL_INTERVAL_SECONDS)

    # Parent gone. Ask the target to terminate, then escalate.
    try:
        os.kill(target, signal.SIGTERM)
    except ProcessLookupError:
        return 1

    deadline = time.monotonic() + GRACE_SECONDS
    while time.monotonic() < deadline:
        if not _process_alive(target):
            return 0
        time.sleep(0.1)

    try:
        os.kill(target, signal.SIGKILL)
    except ProcessLookupError:
        return 0
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
```

- [ ] **Step 2: Smoke test the watchdog directly**

Run (in one terminal):
```bash
python3 -c 'import time; print("victim pid:", __import__("os").getpid()); time.sleep(60)' &
VICTIM=$!
echo "victim is $VICTIM"
# Launch watchdog; its parent is this shell. Park it in background.
python3 BuildScripts/runtime-assets/parent_watchdog.py $VICTIM &
WATCHDOG=$!
echo "watchdog is $WATCHDOG"
sleep 1
# Kill the shell that's the watchdog's parent... we ARE the parent. So
# simulate a different way: kill the watchdog's *target* manually. The
# watchdog should exit code 1 (target gone before parent).
kill $VICTIM
wait $WATCHDOG
echo "watchdog exit: $?"
```
Expected: prints `watchdog exit: 1` (target died first).

For the *real* parent-dies case: this can only be tested against the actual Mac app launching the runtime — covered in Task C4.

- [ ] **Step 3: Commit**

```bash
git add BuildScripts/runtime-assets/parent_watchdog.py
git commit -m "feat(hermes): parent_watchdog.py terminates Hermes on Mac-app crash"
```

### Task C2: Wire the watchdog into the bundle

**Files:**
- Modify: `BuildScripts/bundle-hermes.sh`

- [ ] **Step 1: Copy the asset and update the entrypoint**

In `BuildScripts/bundle-hermes.sh`, find the existing entrypoint write block (the `cat > "$OUT_DIR/hermes-runtime" <<'ENTRYPOINT_EOF'` block). Replace the entire block with:
```bash
echo "→ Copying runtime assets"
cp "$PROJECT_DIR/BuildScripts/runtime-assets/parent_watchdog.py" "$OUT_DIR/parent_watchdog.py"
chmod +x "$OUT_DIR/parent_watchdog.py"

echo "→ Writing runtime entrypoint"
cat > "$OUT_DIR/hermes-runtime" <<'ENTRYPOINT_EOF'
#!/usr/bin/env bash
# Launched by HermesForNoobs.app. Starts the parent-watchdog as a
# sibling, then exec's the bundled Python with the Hermes ACP adapter.
# stdin/stdout/stderr are inherited from the Mac-app parent.
DIR="$(cd "$(dirname "$0")" && pwd)"
PY="$DIR/python-relocatable/bin/python3"

# Watchdog is a tiny separate Python process. Its job: if the Mac app
# (our parent) dies, kill our PID. It exits on its own if we exit first.
"$PY" "$DIR/parent_watchdog.py" $$ &
disown $!

exec "$PY" -m acp_adapter "$@"
ENTRYPOINT_EOF
chmod +x "$OUT_DIR/hermes-runtime"
```

- [ ] **Step 2: Rebuild and verify**

Run:
```bash
rm -rf build/hermes-runtime
./BuildScripts/bundle-hermes.sh build/hermes-runtime 2>&1 | tail -10
ls build/hermes-runtime/
```
Expected: `parent_watchdog.py` and `hermes-runtime` both present; `hermes-runtime` script contains the new watchdog-launch line.

- [ ] **Step 3: Run the existing ACP smoke test**

Run: `python3 Tests/Python/smoke_test_acp.py 2>&1 | tail -20`
Expected: still passes phase 1 (the watchdog must not interfere with the ACP handshake).

- [ ] **Step 4: Commit**

```bash
git add BuildScripts/bundle-hermes.sh
git commit -m "build(hermes): launch parent_watchdog.py alongside acp_adapter"
```

### Task C3: Manual verification — orphan cleanup

**Files:** None (manual test, document the procedure in commit message)

- [ ] **Step 1: Launch the app from Xcode**

In Xcode, build + run TipTour. Open the chat window (⌥⇧H) and send any message to spin up the Hermes subprocess.

- [ ] **Step 2: Locate the Hermes process**

In a terminal:
```bash
pgrep -af 'hermes-runtime|acp_adapter|parent_watchdog' | sort
```
Expected output (PIDs vary): three lines — the shell wrapper, the python3 running `acp_adapter`, and the python3 running `parent_watchdog.py`.

Note the acp_adapter PID — call it `$ACP_PID`.

- [ ] **Step 3: Force-kill the Mac app (simulating a crash)**

In Xcode: Product → Stop. Or:
```bash
pkill -9 -f 'TipTour.app/Contents/MacOS/TipTour'
```

- [ ] **Step 4: Verify Hermes exits within ~5 seconds**

Within 5 seconds, run:
```bash
pgrep -af 'acp_adapter'
```
Expected: empty output (`acp_adapter` is gone). If still running after 10s, the watchdog isn't firing — debug by re-running with `python3 …/parent_watchdog.py` standalone and inspecting `os.getppid()` behavior on macOS.

- [ ] **Step 5: Commit a record of the verification**

```bash
git commit --allow-empty -m "test(hermes): manually verified parent-watchdog kills orphaned acp_adapter on app crash"
```

---

## Workstream D — HermesConfigBootstrapper

### Task D1: Define the bootstrapper public surface

**Files:**
- Create: `TipTour/Hermes/HermesConfigBootstrapper.swift`
- Modify: `TipTourTests/HermesConfigBootstrapperTests.swift`

- [ ] **Step 1: Write the failing tests**

Replace `TipTourTests/HermesConfigBootstrapperTests.swift` (the placeholder from Task A2) with:
```swift
import XCTest
@testable import TipTour

final class HermesConfigBootstrapperTests: XCTestCase {

    private var tempHome: URL!

    override func setUpWithError() throws {
        tempHome = try makeTempHome()
    }

    override func tearDownWithError() throws {
        if let url = tempHome,
           FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func makeTempHome() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("hermes-bootstrapper-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    // MARK: hasValidConfig

    func testHasValidConfigReturnsFalseWhenFileMissing() {
        let b = HermesConfigBootstrapper(hermesHome: tempHome)
        XCTAssertFalse(b.hasValidConfig)
    }

    func testHasValidConfigReturnsTrueAfterWritingMinimalConfig() throws {
        let b = HermesConfigBootstrapper(hermesHome: tempHome)
        try b.writeMinimalConfig(provider: .anthropic)
        XCTAssertTrue(b.hasValidConfig)
    }

    func testHasValidConfigReturnsFalseForEmptyFile() throws {
        let b = HermesConfigBootstrapper(hermesHome: tempHome)
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
        try "".write(to: b.configPath, atomically: true, encoding: .utf8)
        XCTAssertFalse(b.hasValidConfig)
    }

    func testHasValidConfigReturnsFalseForConfigMissingModelKey() throws {
        let b = HermesConfigBootstrapper(hermesHome: tempHome)
        try "irrelevant: value\n".write(to: b.configPath, atomically: true, encoding: .utf8)
        XCTAssertFalse(b.hasValidConfig)
    }

    // MARK: writeMinimalConfig

    func testWriteMinimalConfigForAnthropicEmitsExpectedYAML() throws {
        let b = HermesConfigBootstrapper(hermesHome: tempHome)
        try b.writeMinimalConfig(provider: .anthropic)
        let text = try String(contentsOf: b.configPath, encoding: .utf8)
        XCTAssertTrue(text.contains(#"default: "anthropic/claude-haiku-4-5""#))
        XCTAssertTrue(text.contains(#"provider: "anthropic""#))
    }

    func testWriteMinimalConfigForGoogleEmitsExpectedYAML() throws {
        let b = HermesConfigBootstrapper(hermesHome: tempHome)
        try b.writeMinimalConfig(provider: .google)
        let text = try String(contentsOf: b.configPath, encoding: .utf8)
        XCTAssertTrue(text.contains(#"default: "google/gemini-flash-lite-latest""#))
        XCTAssertTrue(text.contains(#"provider: "google""#))
    }

    func testWriteMinimalConfigForOpenAIEmitsExpectedYAML() throws {
        let b = HermesConfigBootstrapper(hermesHome: tempHome)
        try b.writeMinimalConfig(provider: .openai)
        let text = try String(contentsOf: b.configPath, encoding: .utf8)
        XCTAssertTrue(text.contains(#"default: "openai/gpt-4o-mini""#))
        XCTAssertTrue(text.contains(#"provider: "openai""#))
    }

    func testWriteMinimalConfigIsIdempotent() throws {
        let b = HermesConfigBootstrapper(hermesHome: tempHome)
        try b.writeMinimalConfig(provider: .anthropic)
        let first = try String(contentsOf: b.configPath, encoding: .utf8)
        try b.writeMinimalConfig(provider: .anthropic)
        let second = try String(contentsOf: b.configPath, encoding: .utf8)
        XCTAssertEqual(first, second)
    }

    func testWriteMinimalConfigCreatesHermesHomeDirectory() throws {
        let nested = tempHome.appendingPathComponent("nested-fresh-home", isDirectory: true)
        // nested doesn't exist yet
        let b = HermesConfigBootstrapper(hermesHome: nested)
        try b.writeMinimalConfig(provider: .anthropic)
        var isDir: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: nested.path, isDirectory: &isDir)
            && isDir.boolValue
        )
    }

    func testWriteMinimalConfigOverwritesExistingFile() throws {
        let b = HermesConfigBootstrapper(hermesHome: tempHome)
        try b.writeMinimalConfig(provider: .anthropic)
        try b.writeMinimalConfig(provider: .google)
        let text = try String(contentsOf: b.configPath, encoding: .utf8)
        XCTAssertTrue(text.contains(#"provider: "google""#))
        XCTAssertFalse(text.contains(#"provider: "anthropic""#))
    }

    // MARK: provider enum

    func testProviderEnvVarMatchesHermesExpectation() {
        XCTAssertEqual(HermesConfigBootstrapper.Provider.anthropic.environmentVariable, "ANTHROPIC_API_KEY")
        XCTAssertEqual(HermesConfigBootstrapper.Provider.openai.environmentVariable, "OPENAI_API_KEY")
        XCTAssertEqual(HermesConfigBootstrapper.Provider.google.environmentVariable, "GEMINI_API_KEY")
    }
}
```

- [ ] **Step 2: Verify it fails to compile**

Run in Xcode: build test target.
Expected: build error `cannot find 'HermesConfigBootstrapper' in scope`.

- [ ] **Step 3: Implement HermesConfigBootstrapper**

Create `TipTour/Hermes/HermesConfigBootstrapper.swift`:
```swift
// TipTour/Hermes/HermesConfigBootstrapper.swift
//
// Writes a minimum-viable ~/.hermes/config.yaml so the bundled Hermes
// runtime can complete session/new without `hermes setup`. Provider
// names + default models match Hermes's models_dev_cache.json
// (verified 2026-05-14): anthropic, openai, google.

import Foundation

struct HermesConfigBootstrapper {

    enum Provider: String, CaseIterable, Identifiable {
        case anthropic
        case openai
        case google

        var id: String { rawValue }

        /// Display label for UI (sentence case).
        var displayName: String {
            switch self {
            case .anthropic: return "Anthropic"
            case .openai:    return "OpenAI"
            case .google:    return "Google (Gemini)"
            }
        }

        /// Env var Hermes reads at session/new time. Note: Google's is
        /// GEMINI_API_KEY by convention even though the provider key in
        /// config.yaml is "google".
        var environmentVariable: String {
            switch self {
            case .anthropic: return "ANTHROPIC_API_KEY"
            case .openai:    return "OPENAI_API_KEY"
            case .google:    return "GEMINI_API_KEY"
            }
        }

        /// KeychainStore key used to persist the API key for this provider.
        var keychainKey: String {
            switch self {
            case .anthropic: return "anthropicAPIKey"
            case .openai:    return "openAIAPIKey"
            case .google:    return "googleAPIKey"
            }
        }

        /// "<provider>/<model>" string written into config.yaml's
        /// model.default field. Chosen as fast + cheap defaults; user
        /// can edit ~/.hermes/config.yaml directly to override.
        fileprivate var defaultModel: String {
            switch self {
            case .anthropic: return "anthropic/claude-haiku-4-5"
            case .openai:    return "openai/gpt-4o-mini"
            case .google:    return "google/gemini-flash-lite-latest"
            }
        }
    }

    /// The directory we treat as $HERMES_HOME. Defaults to ~/.hermes.
    /// Tests inject a temp dir; HermesClient injects the same path it
    /// passes to the subprocess as HERMES_HOME env var.
    let hermesHome: URL

    init(hermesHome: URL? = nil) {
        self.hermesHome = hermesHome
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".hermes", isDirectory: true)
    }

    var configPath: URL {
        hermesHome.appendingPathComponent("config.yaml")
    }

    /// True iff config.yaml exists and contains a `model:` key. Looks
    /// for the literal substring "model:" (a top-level key with that
    /// name) so we don't pull in a YAML library for one check.
    var hasValidConfig: Bool {
        guard FileManager.default.fileExists(atPath: configPath.path) else { return false }
        guard let text = try? String(contentsOf: configPath, encoding: .utf8) else { return false }
        // Match a top-level `model:` (start of line or start of file).
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("model:") { return true }
        }
        return false
    }

    /// Writes the minimum config.yaml for the given provider. Creates
    /// the parent directory if missing. Idempotent: the same provider
    /// produces byte-identical output.
    func writeMinimalConfig(provider: Provider) throws {
        try FileManager.default.createDirectory(
            at: hermesHome, withIntermediateDirectories: true
        )
        let body = """
        # ~/.hermes/config.yaml
        # Written by HermesForNoobs on first-run setup. Edit freely —
        # Hermes reads this directly. To change provider via the UI,
        # use Settings → Provider in the menu bar panel.
        model:
          default: "\(provider.defaultModel)"
          provider: "\(provider.rawValue)"

        """
        try body.write(to: configPath, atomically: true, encoding: .utf8)
    }
}
```

- [ ] **Step 4: Run the tests; verify all 11 pass**

Run in Xcode: `HermesConfigBootstrapperTests`.
Expected: 11/11 tests pass.

- [ ] **Step 5: Commit**

```bash
git add TipTour/Hermes/HermesConfigBootstrapper.swift \
        TipTourTests/HermesConfigBootstrapperTests.swift
git commit -m "feat(hermes): HermesConfigBootstrapper writes minimal config.yaml"
```

### Task D2: Add googleAPIKey to KeychainStore

**Files:**
- Modify: `TipTour/KeychainStore.swift`

The existing `geminiAPIKey` accessor stores under key `"geminiAPIKey"`. We need an alias under `"googleAPIKey"` so it matches the bootstrapper's provider naming. Don't remove the old accessor — `GeminiLiveSession.swift` still consumes `geminiAPIKey` for its WebSocket key (separate concern from Hermes).

- [ ] **Step 1: Add the new accessor**

In `TipTour/KeychainStore.swift`, after the existing `lumaAPIKey` accessor (around line 127), add:
```swift
/// Provider key for Hermes's "google" provider. Same value the
/// user would put in GEMINI_API_KEY env var. Separate from
/// `geminiAPIKey` (used by GeminiLiveSession's WebSocket) so the
/// two surfaces can have different keys if the user chooses — most
/// users will just paste the same value into both.
static var googleAPIKey: String? {
    get { get(forKey: "googleAPIKey") }
    set { set(newValue ?? "", forKey: "googleAPIKey") }
}
```

- [ ] **Step 2: Manual verify (no new test — KeychainStore tests aren't worth the harness)**

Build the test target; existing KeychainStore consumers must still compile.
Expected: clean build.

- [ ] **Step 3: Commit**

```bash
git add TipTour/KeychainStore.swift
git commit -m "feat(keychain): add googleAPIKey for Hermes google provider"
```

---

## Workstream E — HermesSetupCoordinator + HermesClient wiring

### Task E1: HermesSetupCoordinator — needs-setup state

**Files:**
- Create: `TipTour/Hermes/HermesSetupCoordinator.swift`
- Create: `TipTourTests/HermesSetupCoordinatorTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `TipTourTests/HermesSetupCoordinatorTests.swift`:
```swift
import XCTest
@testable import TipTour

@MainActor
final class HermesSetupCoordinatorTests: XCTestCase {

    private var tempHome: URL!

    override func setUpWithError() throws {
        tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("hermes-setup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let url = tempHome {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Pluggable key reader so the test doesn't touch the real Keychain.
    private final class FakeKeyReader: HermesProviderKeyReader {
        var keys: [String: String] = [:]
        func value(forKey key: String) -> String? {
            let v = keys[key]
            return (v?.isEmpty ?? true) ? nil : v
        }
    }

    func testNeedsSetupTrueWhenConfigMissingAndKeyMissing() {
        let reader = FakeKeyReader()
        let coord = HermesSetupCoordinator(hermesHome: tempHome, keyReader: reader)
        XCTAssertTrue(coord.needsSetup)
    }

    func testNeedsSetupTrueWhenConfigPresentButNoMatchingKey() throws {
        let reader = FakeKeyReader()  // no keys
        let bootstrapper = HermesConfigBootstrapper(hermesHome: tempHome)
        try bootstrapper.writeMinimalConfig(provider: .anthropic)
        let coord = HermesSetupCoordinator(hermesHome: tempHome, keyReader: reader)
        XCTAssertTrue(coord.needsSetup)
    }

    func testNeedsSetupFalseWhenConfigPresentAndMatchingKeyPresent() throws {
        let reader = FakeKeyReader()
        reader.keys["anthropicAPIKey"] = "sk-ant-test"
        let bootstrapper = HermesConfigBootstrapper(hermesHome: tempHome)
        try bootstrapper.writeMinimalConfig(provider: .anthropic)
        let coord = HermesSetupCoordinator(hermesHome: tempHome, keyReader: reader)
        XCTAssertFalse(coord.needsSetup)
    }

    func testNeedsSetupTrueWhenConfigProviderDiffersFromAvailableKey() throws {
        // Config says google, but only anthropicAPIKey is set in Keychain.
        let reader = FakeKeyReader()
        reader.keys["anthropicAPIKey"] = "sk-ant-test"
        let bootstrapper = HermesConfigBootstrapper(hermesHome: tempHome)
        try bootstrapper.writeMinimalConfig(provider: .google)
        let coord = HermesSetupCoordinator(hermesHome: tempHome, keyReader: reader)
        XCTAssertTrue(coord.needsSetup)
    }

    func testConfiguredProviderReturnsAnthropic() throws {
        let bootstrapper = HermesConfigBootstrapper(hermesHome: tempHome)
        try bootstrapper.writeMinimalConfig(provider: .anthropic)
        let coord = HermesSetupCoordinator(hermesHome: tempHome, keyReader: FakeKeyReader())
        XCTAssertEqual(coord.configuredProvider, .anthropic)
    }

    func testConfiguredProviderReturnsNilWhenConfigMissing() {
        let coord = HermesSetupCoordinator(hermesHome: tempHome, keyReader: FakeKeyReader())
        XCTAssertNil(coord.configuredProvider)
    }

    func testEnvironmentVariablesForSubprocessIncludesConfiguredKey() throws {
        let reader = FakeKeyReader()
        reader.keys["anthropicAPIKey"] = "sk-ant-real"
        let bootstrapper = HermesConfigBootstrapper(hermesHome: tempHome)
        try bootstrapper.writeMinimalConfig(provider: .anthropic)
        let coord = HermesSetupCoordinator(hermesHome: tempHome, keyReader: reader)
        let env = coord.environmentVariablesForSubprocess()
        XCTAssertEqual(env["ANTHROPIC_API_KEY"], "sk-ant-real")
    }

    func testEnvironmentVariablesForSubprocessEmptyWhenNeedsSetup() {
        let coord = HermesSetupCoordinator(hermesHome: tempHome, keyReader: FakeKeyReader())
        XCTAssertTrue(coord.environmentVariablesForSubprocess().isEmpty)
    }
}
```

- [ ] **Step 2: Verify it fails to compile**

Expected build errors on `HermesSetupCoordinator` and `HermesProviderKeyReader`.

- [ ] **Step 3: Implement the coordinator**

Create `TipTour/Hermes/HermesSetupCoordinator.swift`:
```swift
// TipTour/Hermes/HermesSetupCoordinator.swift
//
// Single source of truth for "is the Hermes runtime ready to take a
// prompt?". Cross-references config.yaml (via HermesConfigBootstrapper)
// against the Keychain (via the injected HermesProviderKeyReader).
// HermesClient consults this before launching the subprocess; the panel
// UI consults it to decide whether to show the "Set up Hermes" button.

import Foundation

/// Read-only abstraction over the Keychain so tests can inject fakes
/// without touching the real macOS Keychain.
protocol HermesProviderKeyReader {
    func value(forKey key: String) -> String?
}

struct KeychainProviderKeyReader: HermesProviderKeyReader {
    func value(forKey key: String) -> String? {
        KeychainStore.get(forKey: key)
    }
}

@MainActor
struct HermesSetupCoordinator {
    let hermesHome: URL
    let keyReader: HermesProviderKeyReader

    init(
        hermesHome: URL? = nil,
        keyReader: HermesProviderKeyReader = KeychainProviderKeyReader()
    ) {
        self.hermesHome = hermesHome
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".hermes", isDirectory: true)
        self.keyReader = keyReader
    }

    var bootstrapper: HermesConfigBootstrapper {
        HermesConfigBootstrapper(hermesHome: hermesHome)
    }

    /// True iff we should ask the user to complete setup before letting
    /// HermesClient launch the subprocess.
    var needsSetup: Bool {
        guard bootstrapper.hasValidConfig else { return true }
        guard let provider = configuredProvider else { return true }
        let key = keyReader.value(forKey: provider.keychainKey)
        return key == nil
    }

    /// The provider currently named in config.yaml's model.provider
    /// field, if any. Parsed via a tiny ad-hoc scan — we don't need a
    /// YAML library for one line.
    var configuredProvider: HermesConfigBootstrapper.Provider? {
        guard FileManager.default.fileExists(atPath: bootstrapper.configPath.path),
              let text = try? String(contentsOf: bootstrapper.configPath, encoding: .utf8)
        else { return nil }
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            // Look for `provider: "<name>"` (indented under model:).
            guard line.hasPrefix("provider:") else { continue }
            let after = line.dropFirst("provider:".count)
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: #""'"#))
            if let p = HermesConfigBootstrapper.Provider(rawValue: after) {
                return p
            }
        }
        return nil
    }

    /// Env vars to merge into ProcessInfo.processInfo.environment before
    /// launching the Hermes subprocess. Returns an empty dict when
    /// needsSetup is true.
    func environmentVariablesForSubprocess() -> [String: String] {
        guard !needsSetup,
              let provider = configuredProvider,
              let key = keyReader.value(forKey: provider.keychainKey)
        else { return [:] }
        return [provider.environmentVariable: key]
    }
}
```

- [ ] **Step 4: Run the tests; verify all 8 pass**

Run in Xcode: `HermesSetupCoordinatorTests`.
Expected: 8/8 pass.

- [ ] **Step 5: Commit**

```bash
git add TipTour/Hermes/HermesSetupCoordinator.swift \
        TipTourTests/HermesSetupCoordinatorTests.swift
git commit -m "feat(hermes): HermesSetupCoordinator cross-references config.yaml + Keychain"
```

### Task E2: Extend HermesClientError with new cases

**Files:**
- Modify: `TipTour/Hermes/HermesClient.swift` (the `HermesClientError` enum at the bottom)

- [ ] **Step 1: Replace the error enum**

In `TipTour/Hermes/HermesClient.swift`, replace the existing `HermesClientError` enum (around line 471) with:
```swift
enum HermesClientError: Error, CustomStringConvertible {
    case runtimeMissing
    case subprocessGone
    case malformedResponse(String)
    case needsSetup(reason: NeedsSetupReason)

    enum NeedsSetupReason: Equatable {
        case noConfig                       // ~/.hermes/config.yaml missing or malformed
        case noKeyForProvider(String)       // config names a provider but Keychain has no key
    }

    var description: String {
        switch self {
        case .runtimeMissing:
            return "hermes-runtime executable not found inside the app bundle"
        case .subprocessGone:
            return "hermes-runtime subprocess is not running"
        case .malformedResponse(let why):
            return "malformed ACP response: \(why)"
        case .needsSetup(.noConfig):
            return "Hermes isn't set up yet. Open Settings → Set up Hermes to pick a provider."
        case .needsSetup(.noKeyForProvider(let p)):
            return "Hermes is configured for \(p) but no API key is stored. Open Settings → Set up Hermes to paste one."
        }
    }

    /// True when the error is a setup-related one the UI should resolve
    /// with the "Set Up Hermes…" affordance rather than a retry.
    var isSetupError: Bool {
        if case .needsSetup = self { return true }
        return false
    }
}
```

- [ ] **Step 2: Build to verify**

Expected: clean build. The existing `appendSystemError(HermesClientError.runtimeMissing)` etc. still compile.

- [ ] **Step 3: Commit**

```bash
git add TipTour/Hermes/HermesClient.swift
git commit -m "feat(hermes): HermesClientError adds .needsSetup cases for first-run UX"
```

### Task E3: HermesClient consults the coordinator before launching

**Files:**
- Modify: `TipTour/Hermes/HermesClient.swift` (the `send` method and `launchSubprocessIfNeeded`)

- [ ] **Step 1: Add a coordinator property**

In `TipTour/Hermes/HermesClient.swift`, after the `// MARK: Internal state` block (around line 132), add:
```swift
/// Setup-state oracle. Default points at the same HERMES_HOME we'll
/// pass to the subprocess. Tests can inject a coordinator backed by a
/// fake key reader; production code uses the Keychain-backed default.
private let setupCoordinator: HermesSetupCoordinator
```

Update the `init`:
```swift
init(hermesHome: URL? = nil) {
    self.hermesHomeOverride = hermesHome
    self.setupCoordinator = HermesSetupCoordinator(hermesHome: hermesHome)
}
```

And add a designated init for tests:
```swift
init(hermesHome: URL?, setupCoordinator: HermesSetupCoordinator) {
    self.hermesHomeOverride = hermesHome
    self.setupCoordinator = setupCoordinator
}
```

- [ ] **Step 2: Pre-flight check in send()**

In `send`, replace the existing handshake block (the `if sessionId == nil { … }` block around line 36):
```swift
if sessionId == nil {
    if setupCoordinator.needsSetup {
        // Don't even try to launch — surface an actionable error.
        let reason: HermesClientError.NeedsSetupReason
        if !setupCoordinator.bootstrapper.hasValidConfig {
            reason = .noConfig
        } else if let p = setupCoordinator.configuredProvider {
            reason = .noKeyForProvider(p.displayName)
        } else {
            reason = .noConfig
        }
        appendSystemError(HermesClientError.needsSetup(reason: reason))
        isWorking = false
        return
    }
    isWorking = true
    do {
        try await launchSubprocessIfNeeded()
        try await initializeHandshake()
        try await openSession()
    } catch {
        isWorking = false
        appendSystemError(error)
        return
    }
}
```

- [ ] **Step 3: Inject provider env vars in launchSubprocessIfNeeded**

Replace the existing env-building block (around line 167):
```swift
var env = ProcessInfo.processInfo.environment
if let override = hermesHomeOverride {
    env["HERMES_HOME"] = override.path
}
// Inject provider API key from Keychain (or test reader). This is
// the env var Hermes reads at session/new time to authenticate with
// the upstream model provider.
for (key, value) in setupCoordinator.environmentVariablesForSubprocess() {
    env[key] = value
}
p.environment = env
```

- [ ] **Step 4: Add tests for the new behavior**

Append to `TipTourTests/HermesSetupCoordinatorTests.swift`:
```swift
extension HermesSetupCoordinatorTests {

    /// Verifies that HermesClient appends a system error and does NOT
    /// spawn a subprocess when setup is incomplete.
    func testHermesClientWithNeedsSetupAppendsSystemErrorWithoutLaunching() async throws {
        let reader = FakeKeyReader()  // no keys → needsSetup is true
        let coord = HermesSetupCoordinator(hermesHome: tempHome, keyReader: reader)
        let client = HermesClient(hermesHome: tempHome, setupCoordinator: coord)
        await client.send("hello")
        // Transcript: one user turn, one system error turn — no agent.
        XCTAssertEqual(client.transcript.count, 2)
        if case .system(_, let text) = client.transcript.last {
            XCTAssertTrue(text.lowercased().contains("set up hermes"),
                          "system error didn't mention setup: \(text)")
        } else {
            XCTFail("expected a system error as last transcript entry")
        }
    }
}
```

- [ ] **Step 5: Run all HermesSetupCoordinator + HermesConfigBootstrapper tests**

Expected: all pass. The new `testHermesClientWithNeedsSetupAppendsSystemErrorWithoutLaunching` does not spin up the subprocess — runs in milliseconds.

- [ ] **Step 6: Commit**

```bash
git add TipTour/Hermes/HermesClient.swift \
        TipTourTests/HermesSetupCoordinatorTests.swift
git commit -m "feat(hermes): HermesClient pre-flights setup state, injects provider env"
```

---

## Workstream F — First-run setup UI

### Task F1: FirstRunSetupView

**Files:**
- Create: `TipTour/Hermes/FirstRunSetupView.swift`

- [ ] **Step 1: Write the view**

Create `TipTour/Hermes/FirstRunSetupView.swift`:
```swift
// TipTour/Hermes/FirstRunSetupView.swift
//
// Sheet shown the first time a user opens the menu bar panel without
// a configured Hermes runtime. Collects one provider + one API key,
// writes config.yaml via HermesConfigBootstrapper, and persists the
// key to Keychain. The sheet dismisses on success; the caller (the
// CompanionPanelView footer) re-evaluates needsSetup on dismissal.

import SwiftUI

struct FirstRunSetupView: View {

    /// Bound to the calling view's @State Bool — flipping to false
    /// dismisses the sheet.
    @Binding var isPresented: Bool

    /// Called on successful setup (config written + key stored), AFTER
    /// the sheet flips isPresented to false. Lets the caller refresh
    /// any cached needsSetup state.
    var onSetupComplete: () -> Void

    @State private var provider: HermesConfigBootstrapper.Provider = .anthropic
    @State private var apiKey: String = ""
    @State private var errorMessage: String?
    @State private var isSubmitting: Bool = false

    private var trimmedKey: String {
        apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Set up Hermes")
                .font(.title2.bold())
            Text("Hermes runs a small bundled Python agent under the hood. Pick a provider and paste your API key.")
                .font(.body)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Provider", selection: $provider) {
                ForEach(HermesConfigBootstrapper.Provider.allCases) { p in
                    Text(p.displayName).tag(p)
                }
            }
            .pickerStyle(.segmented)

            VStack(alignment: .leading, spacing: 6) {
                Text("API key")
                    .font(.callout.bold())
                SecureField("paste here", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                Text("Stored in macOS Keychain. Used only to launch Hermes.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if let error = errorMessage {
                Text(error)
                    .font(.callout)
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(isSubmitting ? "Saving…" : "Save") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedKey.isEmpty || isSubmitting)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func submit() {
        errorMessage = nil
        isSubmitting = true
        let key = trimmedKey
        let chosenProvider = provider

        // Run on a detached task so the UI doesn't hitch if the disk
        // write is slow. Writes are tiny but it costs nothing to be
        // good citizens.
        Task {
            do {
                let bootstrapper = HermesConfigBootstrapper()
                try bootstrapper.writeMinimalConfig(provider: chosenProvider)
                let stored = KeychainStore.set(key, forKey: chosenProvider.keychainKey)
                guard stored else {
                    await MainActor.run {
                        errorMessage = "Couldn't save the key to Keychain. Try again."
                        isSubmitting = false
                    }
                    return
                }
                await MainActor.run {
                    isSubmitting = false
                    isPresented = false
                    onSetupComplete()
                }
            } catch {
                await MainActor.run {
                    errorMessage = "Couldn't write config: \(error.localizedDescription)"
                    isSubmitting = false
                }
            }
        }
    }
}
```

- [ ] **Step 2: Build to verify**

Expected: clean build. The view doesn't have a preview — that's intentional (provider enum requires the full app target).

- [ ] **Step 3: Commit**

```bash
git add TipTour/Hermes/FirstRunSetupView.swift
git commit -m "feat(hermes): FirstRunSetupView sheet for provider + API key entry"
```

### Task F2: Wire FirstRunSetupView from CompanionPanelView footer

**Files:**
- Modify: `TipTour/CompanionPanelView.swift`

- [ ] **Step 1: Add state for the setup sheet and a setup coordinator**

In `TipTour/CompanionPanelView.swift`, near the top of the `CompanionPanelView` struct (alongside any existing @State / @ObservedObject), add:
```swift
@State private var showFirstRunSetup: Bool = false
@State private var setupNeedsRefresh: Bool = false
// Re-evaluate every body call so the button hides as soon as the user
// finishes setup. The coordinator is cheap to construct (no I/O until
// methods are called).
private var setupCoordinator: HermesSetupCoordinator {
    _ = setupNeedsRefresh   // touch to force a recompute
    return HermesSetupCoordinator()
}
```

- [ ] **Step 2: Add the footer button**

Find `footerSection` in `TipTour/CompanionPanelView.swift` (around line 560). In the footer's HStack, alongside the existing "Settings" and "Dev" footer buttons, add:
```swift
if setupCoordinator.needsSetup {
    footerButton("Set up Hermes", systemImage: "key", toggled: false) {
        showFirstRunSetup = true
    }
}
```

- [ ] **Step 3: Attach the sheet**

On the root VStack in `body` (the one that closes around line 70), append:
```swift
.sheet(isPresented: $showFirstRunSetup) {
    FirstRunSetupView(
        isPresented: $showFirstRunSetup,
        onSetupComplete: {
            // Toggle to force the body to recompute setupCoordinator
            // and re-evaluate needsSetup.
            setupNeedsRefresh.toggle()
        }
    )
}
```

- [ ] **Step 4: Manual verify — first-run UX**

1. Quit the app.
2. Delete the config: `rm -f ~/.hermes/config.yaml`
3. Build + run in Xcode.
4. Open the menu bar panel.
Expected: "Set up Hermes" button visible in the footer. Click it. Pick "Anthropic", paste a valid Anthropic key, click Save. Sheet closes. Button disappears from the footer.
5. Open ⌥⇧H chat window. Type "say hi". Expected: Hermes replies.

- [ ] **Step 5: Commit**

```bash
git add TipTour/CompanionPanelView.swift
git commit -m "feat(panel): footer Set up Hermes button + FirstRunSetupView sheet"
```

---

## Workstream G — Runtime error UX

### Task G1: HermesChatWindow detects setup-error transcript entries

**Files:**
- Modify: `TipTour/Hermes/HermesChatWindow.swift`

The chat window already renders `.system` transcript entries as plain text. We want setup-related entries to render with an inline "Set Up Hermes…" button.

- [ ] **Step 1: Locate the system-entry rendering**

Run: `grep -n 'case .system\|system(' TipTour/Hermes/HermesChatWindow.swift`
Expected: find the switch case (or equivalent) that renders system entries. Note the SwiftUI view body for that case.

- [ ] **Step 2: Replace the system-entry case**

In `TipTour/Hermes/HermesChatWindow.swift`, replace the `.system` case rendering with:
```swift
case .system(_, let text):
    HStack(alignment: .top, spacing: 8) {
        Image(systemName: "exclamationmark.triangle.fill")
            .foregroundColor(.yellow)
        VStack(alignment: .leading, spacing: 6) {
            Text(text)
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if text.lowercased().contains("set up hermes") {
                Button("Set Up Hermes…") {
                    openSetupSheet()
                }
                .controlSize(.small)
            }
        }
        Spacer(minLength: 0)
    }
    .padding(.vertical, 4)
```

(If the existing chat window doesn't have a `Spacer` / vertical padding pattern, match what `.user` and `.agent` cases use. The point is the inline button next to the error text.)

- [ ] **Step 3: Add openSetupSheet helper**

Near the top of the chat window's body or as a method on the view, add:
```swift
@State private var showSetupSheet: Bool = false

private func openSetupSheet() {
    showSetupSheet = true
}
```

And attach the sheet to the chat window's root view:
```swift
.sheet(isPresented: $showSetupSheet) {
    FirstRunSetupView(
        isPresented: $showSetupSheet,
        onSetupComplete: { /* user can re-send from the chat window */ }
    )
}
```

- [ ] **Step 4: Manual verify — error UX**

1. Quit the app.
2. Delete the config: `rm -f ~/.hermes/config.yaml`
3. Build + run.
4. Open chat (⌥⇧H), type "hello", press Enter.
Expected: a yellow warning row with the text "Hermes isn't set up yet…" and an inline "Set Up Hermes…" button. Click the button. The same FirstRunSetupView from the panel opens. Save a key. Retype "hello" and press Enter.
Expected: Hermes replies.

- [ ] **Step 5: Commit**

```bash
git add TipTour/Hermes/HermesChatWindow.swift
git commit -m "feat(hermes): inline Set Up Hermes button in chat for setup errors"
```

---

## Workstream H — Cleanup + verification + docs

### Task H1: End-to-end manual smoke test on a fresh-state install

**Files:** None (manual procedure)

- [ ] **Step 1: Tear down all Hermes state**

Run:
```bash
mv ~/.hermes ~/.hermes-backup-$(date +%s) 2>/dev/null || true
```

- [ ] **Step 2: Remove the test provider key from Keychain**

In Keychain Access.app (or via `security delete-generic-password -s com.milindsoni.tiptour -a anthropicAPIKey` if you know the exact account), remove `anthropicAPIKey`, `openAIAPIKey`, `googleAPIKey`. Verify none remain by searching the keychain for `tiptour`.

- [ ] **Step 3: Build + launch the app from Xcode**

Expected: app launches. Menu bar icon visible. Open panel. Footer shows "Set up Hermes" button.

- [ ] **Step 4: Run the setup flow**

Click the button. Pick a provider you have a key for. Paste the key. Save.
Expected: sheet closes, button disappears.

- [ ] **Step 5: Send a message through chat**

Open ⌥⇧H. Type "say the single word ready". Press Enter.
Expected: Hermes replies with text containing "ready" within ~10 seconds. No system error.

- [ ] **Step 6: Verify the version surface**

In the panel, expand the Dev section. Expected: a small monospaced line `Hermes <version> (<sha7>) · Python 3.11.15`.

- [ ] **Step 7: Verify orphan cleanup**

Find acp_adapter PID: `pgrep -af acp_adapter`. Force-stop the Mac app (Cmd+Q in Xcode → Stop). Within 5 seconds, run `pgrep -af acp_adapter` again. Expected: empty.

- [ ] **Step 8: Restore the user's backed-up state if desired**

Run:
```bash
# Optional — only if Step 1 made a backup you want back.
ls -d ~/.hermes-backup-* 2>/dev/null
```

If you want to restore: `rm -rf ~/.hermes && mv ~/.hermes-backup-<timestamp> ~/.hermes`. Otherwise leave the new fresh-state config in place.

- [ ] **Step 9: Commit a record**

```bash
git commit --allow-empty -m "test(hermes): end-to-end manual smoke test pass on fresh-install state"
```

### Task H2: Update BuildScripts/README.md

**Files:**
- Modify: `BuildScripts/README.md`

- [ ] **Step 1: Add a section on the version manifest**

In `BuildScripts/README.md`, after the existing "Updating Python" section and before "Validating the bundle manually", add:
```markdown
### Runtime version manifest

The script also emits `hermes-version.txt` next to the `hermes-runtime`
entrypoint:

    hermes_git_ref=<pinned SHA from this script>
    hermes_version=<pip-reported hermes-agent version>
    python_version=<bundled CPython version>
    python_build=<python-build-standalone release tag>
    bundled_at=<ISO-8601 UTC timestamp>

The Swift app reads this through `HermesRuntimeVersion.read(from:)`
and surfaces a short summary in the menu bar panel's Dev section.
Useful when triaging "which build is this user on" support questions.

### Parent-PID watchdog

`parent_watchdog.py` is copied alongside the entrypoint and launched as
a sibling Python process by the entrypoint shell wrapper. It polls
`os.getppid()` every 0.5s; when its parent (the Mac app) is reaped
and PPID becomes 1, it sends SIGTERM (then SIGKILL after 3s) to the
acp_adapter PID. Without this, a Mac-app crash would orphan a Python
process that consumes memory until the user reboots.

The watchdog is a separate process — not a thread or signal handler
inside acp_adapter — because the adapter owns SIGTERM/SIGINT for its
own shutdown flow.
```

- [ ] **Step 2: Update the "Common failure modes" table**

Add this row to the table at the bottom of `BuildScripts/README.md`:
```markdown
| HermesRuntimeVersion.ReadError thrown at app launch | `hermes-version.txt` missing or malformed | Rerun the bundler. If the file exists but a field is empty, the build host failed to invoke the bundled `python3` for one of the introspection steps — check the script's stderr |
```

- [ ] **Step 3: Commit**

```bash
git add BuildScripts/README.md
git commit -m "docs(build): document hermes-version.txt manifest + parent watchdog"
```

### Task H3: Update AGENTS.md (CLAUDE.md symlink target)

**Files:**
- Modify: `AGENTS.md`

- [ ] **Step 1: Add new files to the Key Files table**

In `AGENTS.md`, find the Key Files table. Add these rows in alphabetical order by file path:
```markdown
| `TipTour/Hermes/HermesConfigBootstrapper.swift` | ~95 | Writes minimum-viable `~/.hermes/config.yaml` so the bundled runtime can complete `session/new` without `hermes setup`. Provider enum (anthropic / openai / google) carries display name, env var name, Keychain key, and default model — single source of truth for provider strings. Used by `FirstRunSetupView` and `HermesSetupCoordinator`. |
| `TipTour/Hermes/HermesRuntimeVersion.swift` | ~75 | Parses `hermes-version.txt` emitted by `bundle-hermes.sh`. Exposes `shortDisplayString` for the Dev panel footer (`Hermes 0.13.0 (abc1234) · Python 3.11.15`). |
| `TipTour/Hermes/HermesSetupCoordinator.swift` | ~85 | Cross-references `config.yaml` (via `HermesConfigBootstrapper`) against the Keychain (via injected `HermesProviderKeyReader`) to answer "is the runtime ready to take a prompt?". `HermesClient.send` pre-flights through this; the panel footer hides/shows "Set up Hermes" through this. `KeychainProviderKeyReader` is the production implementation; tests inject fakes. |
| `TipTour/Hermes/FirstRunSetupView.swift` | ~110 | SwiftUI sheet: provider segmented picker + secure key field + save button. Writes `config.yaml` and stores the key in Keychain under the provider's `keychainKey`. Reused from both the panel footer and the chat window's inline error UI. |
| `BuildScripts/runtime-assets/parent_watchdog.py` | ~55 | Sibling Python process launched by the bundle entrypoint. Polls `os.getppid()`; when the Mac-app parent dies, sends SIGTERM (then SIGKILL after 3s) to the `acp_adapter` PID. Prevents orphaned Hermes processes after Mac-app crashes. |
| `BuildScripts/runtime-assets/reference-config.yaml` | ~12 | Reference shape for the YAML `HermesConfigBootstrapper` emits. Documents the provider/model strings the bootstrapper supports. Not copied into the bundle — purely a developer reference. |
```

- [ ] **Step 2: Update the architecture description for the Hermes runtime**

In `AGENTS.md`, find the section describing the Hermes runtime / ACP. Add a new paragraph after the existing description of `bundle-hermes.sh`:
```markdown
- **First-run setup**: A fresh install has no `~/.hermes/config.yaml`. `HermesSetupCoordinator.needsSetup` returns true; `CompanionPanelView` shows a "Set up Hermes" footer button that opens `FirstRunSetupView`. The user picks a provider (anthropic / openai / google), pastes the API key, and `HermesConfigBootstrapper.writeMinimalConfig` emits a two-field `config.yaml` while `KeychainStore` persists the key. `HermesClient.launchSubprocessIfNeeded` reads the key back via the coordinator and injects it as the provider's env var (`ANTHROPIC_API_KEY` / `OPENAI_API_KEY` / `GEMINI_API_KEY`) into the subprocess environment. `HermesClient.send` pre-flights through the same coordinator and appends a system-error transcript entry — surfaced in `HermesChatWindow` as a yellow warning with an inline "Set Up Hermes…" button — when setup is incomplete, so the subprocess is never launched in a non-ready state.

- **Orphan cleanup**: The bundle entrypoint shell wrapper launches `parent_watchdog.py` as a sibling Python process before exec-ing `acp_adapter`. The watchdog polls `os.getppid()` and SIGTERMs the adapter when the Mac-app parent is reaped (PPID becomes 1). Prevents long-running orphaned Python processes after Mac-app crashes.

- **Bundle version manifest**: `bundle-hermes.sh` writes `hermes-version.txt` (key=value pairs: `hermes_git_ref`, `hermes_version`, `python_version`, `python_build`, `bundled_at`) next to the entrypoint. `HermesRuntimeVersion.swift` reads it and renders a one-line summary in the Dev panel section — useful for support triage. `HERMES_GIT_REF` is pinned to a specific commit SHA so builds are reproducible.
```

- [ ] **Step 3: Update line counts for files that changed substantially**

Update the existing rows for any file whose line count drifted >50 from this plan's edits:
- `TipTour/Hermes/HermesClient.swift` — recheck wc-l after Task E1/E3.
- `TipTour/CompanionPanelView.swift` — recheck wc-l after Task F2.
- `BuildScripts/bundle-hermes.sh` — recheck wc-l after Task B1/B2/C2.

Run:
```bash
wc -l TipTour/Hermes/HermesClient.swift \
      TipTour/CompanionPanelView.swift \
      BuildScripts/bundle-hermes.sh
```
And update the corresponding numbers in `AGENTS.md`'s Key Files table.

- [ ] **Step 4: Commit**

```bash
git add AGENTS.md
git commit -m "docs(agents): document Plan 4 — runtime setup, watchdog, version manifest"
```

---

## Self-review

**Spec coverage check (all four scoped gaps):**
- First-run setup UX → Workstreams D + E + F + G (bootstrapper, coordinator, view, error UX)
- Parent-PID watcher → Workstream C
- Hermes version pinning + UI surface → Workstream B
- Runtime error UX → Workstreams E (typed error) + G (chat-window rendering)

**Out-of-scope confirmations:**
- Production codesigning (dev-team identity) — NOT touched. Existing ad-hoc signing in `bundle-hermes.sh` stays as-is.
- Notarization — NOT touched.
- Settings tabs proper (Models / Gateways / Skills / Memory / Guardrails / Schedule) — explicitly Plan 5+.

**Naming consistency check:**
- `HermesConfigBootstrapper.Provider` enum cases: `anthropic`, `openai`, `google` (matches `models_dev_cache.json`)
- Env var names: `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `GEMINI_API_KEY` (note: Google's env var is GEMINI_API_KEY, not GOOGLE_API_KEY — verified against smoke_test_acp.py:67-69)
- Keychain key names: `anthropicAPIKey`, `openAIAPIKey`, `googleAPIKey` (NB: `googleAPIKey` is new in Task D2; existing `geminiAPIKey` in KeychainStore is for `GeminiLiveSession`, a separate consumer)
- Default models: `anthropic/claude-haiku-4-5`, `openai/gpt-4o-mini`, `google/gemini-flash-lite-latest` (all confirmed via `models_dev_cache.json`)
- `HermesClientError.needsSetup` cases used consistently in `HermesClient.send` and `HermesClientError.isSetupError`

**Type-flow check:**
- `HermesSetupCoordinator.environmentVariablesForSubprocess() -> [String: String]` returns `[provider.environmentVariable: key]`, consumed in `HermesClient.launchSubprocessIfNeeded` via `env[key] = value` loop. ✓
- `FirstRunSetupView.onSetupComplete: () -> Void` called after `isPresented = false`; both call sites (panel + chat window) match. ✓
- `HermesProviderKeyReader.value(forKey:) -> String?` returns nil on empty AND missing — both treated as "no key". The `FakeKeyReader` test helper enforces this. ✓

**Placeholder scan:** No "TBD", "TODO", "implement later", "fill in details", "Add appropriate error handling" found in any task. Every code-bearing step includes complete code blocks.

---

## Execution handoff

Plan complete and saved to `docs/superpowers/plans/2026-05-14-plan-4-hermes-runtime-production-ready.md`. Two execution options:

**1. Subagent-Driven (recommended)** — dispatch a fresh subagent per task, review between tasks, fast iteration. Best for this plan since the workstreams are mostly independent and several can run in parallel (B and C have no dependency on each other; D, E, F, G layer on top).

**2. Inline Execution** — execute tasks in this session via `superpowers:executing-plans`, batched execution with checkpoints. Slower turn-around but everything stays in one conversation.

Which approach?
