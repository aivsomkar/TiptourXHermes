# Plan 1: Bundling and ACP smoke test — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fork TipTour into the new project, bundle a relocatable Python 3.11 + Hermes inside `.app/Contents/Resources/hermes-runtime/`, and prove the bundled runtime can hold a JSON-RPC conversation over stdio with its ACP adapter.

**Architecture:** A `Build/bundle-hermes.sh` script downloads `python-build-standalone`, creates an isolated venv, pip-installs Hermes, and emits a small `hermes-runtime` entrypoint shell script. An Xcode Run Script build phase copies that directory into the .app at every build. A Swift test confirms the runtime ships and is executable; a Python end-to-end smoke test confirms the ACP adapter answers JSON-RPC.

**Tech Stack:** Bash, Python 3.11, [python-build-standalone](https://github.com/indygreg/python-build-standalone) (relocatable Python), pip, Hermes Agent, Xcode build phases, Swift XCTest.

---

## Why this is Plan 1 of 9

The full Hermes for Noobs spec (`docs/superpowers/specs/2026-05-13-hermes-for-noobs-design.md`) is large enough that it can't be one plan without losing focus. Slicing into nine, each producing standalone testable software:

| # | Plan | What ships |
|---|---|---|
| **1** | **Bundling and ACP smoke test** *(this plan)* | A bundled Hermes runtime inside the .app + a green smoke test |
| 2 | ACP bridge + dev "talk to Hermes" textbox | Swift `HermesClient`, dev menu item, end-to-end text chat |
| 3 | Replace swarm with `ask_hermes` + tool routing | Voice loop works through Hermes; Mac tools called back over ACP |
| 4 | Guardrails Layer A (hard limits) + audit log | Destructive commands are blocked pre-flight |
| 5 | Guardrails Layer B (approvals, Mac dialog only) | Per-action confirmation for risky ops |
| 6 | Guardrails Layer C (budget caps) + kill switch | Token + concurrency + rate limits, "Pause all agents" |
| 7 | First gateway: Telegram + remote approval routing | Bot works; approvals can fire over Telegram |
| 8 | Remaining gateways (Slack, Discord, WhatsApp, Signal, Email) | Multi-platform reach |
| 9 | Skills, Memory, Schedule tabs in Settings | Full control plane parity with Hermes CLI |

Plans 2–9 will each get their own implementation plan when we start them.

---

## Important caveats before you begin

**You are running on macOS Apple Silicon.** All Python URLs and the Xcode build phase assume `aarch64-apple-darwin`. If you also need Intel support, you'll add a parallel download in the script — out of scope for Plan 1.

**The ACP adapter's exact method names are unverified.** Hermes ships an `acp_adapter/` directory but we haven't pinned its API. **Task 2 is a hard prerequisite** to Tasks 3–7: if it turns out Hermes' ACP adapter is missing methods we need (especially `approval.request`), this plan grows a Task 2.5 to write a small Hermes plugin upstream or vendor a patched fork.

**Builds will be slow the first time.** The bundling script downloads ~30 MB of Python and pip-installs Hermes' full `[all]` extras (~100 MB on disk). Expect 2–5 minutes on first build. The script is idempotent — incremental builds reuse the cached Python archive.

---

## File structure produced by this plan

```
Hermes for Noobs/
├── Build/
│   ├── bundle-hermes.sh          (new — Python+Hermes bundler)
│   └── README.md                  (new — build infra docs)
├── Tests/
│   └── Python/
│       └── smoke_test_acp.py     (new — JSON-RPC round-trip test)
├── TipTourTests/
│   └── HermesBundleTests.swift   (new — bundle presence + launchability)
├── docs/superpowers/
│   ├── specs/2026-05-13-hermes-for-noobs-design.md (existing)
│   ├── plans/2026-05-13-plan-1-bundling-and-acp-smoke-test.md (this file)
│   └── notes/2026-05-13-acp-investigation.md (new — Task 2 findings)
├── tiptour-macos.xcodeproj/      (forked from TipTour, build phase added)
├── TipTour/                       (forked from TipTour, unmodified by Plan 1)
└── .gitignore                     (modified — adds build/)
```

Nothing inside `TipTour/` is touched by Plan 1 — the fork is preserved exactly. Plan 2 starts modifying Swift code.

---

## Task 1: Fork TipTour into the project directory

**Files:**
- Source: `/Users/omkar/Desktop/TipTour-macOS/repo/`
- Destination: `/Users/omkar/Desktop/Fun Projects/Hermes for Noobs/`

- [ ] **Step 1: Copy TipTour, excluding `.git` and macOS metadata.**

```bash
rsync -av \
  --exclude='.git' \
  --exclude='.DS_Store' \
  --exclude='build/' \
  --exclude='DerivedData/' \
  /Users/omkar/Desktop/TipTour-macOS/repo/ \
  "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs/"
```

Expected: rsync prints a long file list, finishes without errors. The existing `docs/` directory (containing the spec) is preserved because rsync runs without `--delete`.

- [ ] **Step 2: Open the Xcode project to confirm it loads.**

```bash
open "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs/tiptour-macos.xcodeproj"
```

Expected: Xcode opens, project loads. Do NOT click Run — just confirm the project tree is visible without red error icons. Close Xcode.

- [ ] **Step 3: Commit the fork.**

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs" && \
  git add -A && \
  git commit -m "fork: import TipTour as Hermes for Noobs base"
```

Expected: commit succeeds with thousands of files added.

---

## Task 2: ACP investigation spike

**Files:**
- Read: `/tmp/hermes-agent/acp_adapter/` (cloned in this task)
- Create: `docs/superpowers/notes/2026-05-13-acp-investigation.md`

This task is research, not TDD. Its output is a document the rest of Plan 1 (and Plan 2) depends on.

- [ ] **Step 1: Clone Hermes for inspection.**

```bash
git clone --depth=1 https://github.com/NousResearch/hermes-agent.git /tmp/hermes-agent
ls /tmp/hermes-agent/acp_adapter
```

Expected: directory listing with at least one `.py` file.

- [ ] **Step 2: Identify the ACP entrypoint module name.**

```bash
grep -r "if __name__" /tmp/hermes-agent/acp_adapter/ --include='*.py'
find /tmp/hermes-agent -name 'pyproject.toml' -exec grep -l 'acp' {} \;
```

Look for either a `__main__.py` inside `acp_adapter/` (means `python -m hermes.acp_adapter` works) or a console_script entrypoint in `pyproject.toml` (means a binary like `hermes-acp` is on PATH after install).

- [ ] **Step 3: Catalogue the supported JSON-RPC methods.**

```bash
grep -rn "method" /tmp/hermes-agent/acp_adapter/ --include='*.py' | head -60
grep -rn "@method\|register_method\|case \"" /tmp/hermes-agent/acp_adapter/ --include='*.py'
```

Write down every method name you can find. We need at minimum:
- something equivalent to `user.message` (Swift → Hermes: user said X)
- something equivalent to `agent.message` (Hermes → Swift: agent replies)
- something equivalent to `tool.call` and `tool.result` (Hermes ⇄ Swift: tool round-trips)
- something equivalent to `approval.request` and `approval.response` (Hermes ⇄ Swift: ask user)

- [ ] **Step 4: Write findings to `docs/superpowers/notes/2026-05-13-acp-investigation.md`.**

Required sections:

```markdown
# ACP adapter investigation — 2026-05-13

## Entrypoint
Module name or binary to launch: `<fill in>`
Exact invocation: `<fill in, e.g., python -m hermes.acp_adapter>`

## Methods supported (Swift → Hermes)
- `<method name>` — `<one-line purpose>` — params: `<schema>`
- ...

## Notifications emitted (Hermes → Swift)
- `<method name>` — `<one-line purpose>` — params: `<schema>`
- ...

## Gaps vs. our spec
- `approval.request` — present / missing / needs-equivalent (`<name>`)
- `tool.call` with `destination: "local"` — present / missing
- ... 

## Conclusion
- ☐ Use ACP adapter as-is (no gaps)
- ☐ Use ACP adapter with a small Hermes plugin we own (list gaps)
- ☐ Skip ACP, write our own JSON protocol over stdio (recommend if 3+ critical gaps)
```

- [ ] **Step 5: Commit the notes.**

```bash
git add docs/superpowers/notes && \
  git commit -m "docs: ACP adapter investigation notes"
```

- [ ] **Step 6: Decision gate.** If your conclusion is "skip ACP," stop here and rewrite Plan 1 Task 5 (smoke test) and the entrypoint in Task 3 to use the alternative protocol. Otherwise continue.

---

## Task 3: Write the Hermes bundling script

**Files:**
- Create: `Build/bundle-hermes.sh`

- [ ] **Step 1: Create `Build/` directory and the script.**

```bash
mkdir -p "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs/Build"
```

Then write `Build/bundle-hermes.sh` with this exact content. **Before pasting, substitute `<ACP_ENTRYPOINT_MODULE>` with the module name from Task 2 Step 2** (likely `hermes.acp_adapter` but verify).

```bash
#!/usr/bin/env bash
# bundle-hermes.sh — Downloads a relocatable Python and installs Hermes
# into $1/hermes-runtime/. Idempotent: skips Python download if cached.

set -euo pipefail

PYTHON_VERSION="3.11.9"
PYTHON_BUILD="20240909"
PYTHON_ARCH="aarch64-apple-darwin"
PYTHON_FLAVOUR="install_only"
HERMES_GIT_REF="${HERMES_GIT_REF:-main}"

PROJECT_DIR="${SRCROOT:-$(pwd)}"
OUT_DIR="${1:-$PROJECT_DIR/build/hermes-runtime}"
CACHE_DIR="$PROJECT_DIR/build/.cache"

PYTHON_URL="https://github.com/indygreg/python-build-standalone/releases/download/$PYTHON_BUILD/cpython-$PYTHON_VERSION+$PYTHON_BUILD-$PYTHON_ARCH-$PYTHON_FLAVOUR.tar.gz"
PYTHON_ARCHIVE="$CACHE_DIR/python-$PYTHON_VERSION-$PYTHON_BUILD-$PYTHON_ARCH.tar.gz"

mkdir -p "$CACHE_DIR" "$OUT_DIR"

if [ ! -f "$PYTHON_ARCHIVE" ]; then
  echo "→ Downloading Python $PYTHON_VERSION ($PYTHON_ARCH)"
  curl -fL "$PYTHON_URL" -o "$PYTHON_ARCHIVE"
fi

if [ ! -d "$OUT_DIR/python-relocatable" ]; then
  echo "→ Extracting Python into $OUT_DIR/python-relocatable"
  tmp="$(mktemp -d)"
  tar -xzf "$PYTHON_ARCHIVE" -C "$tmp"
  mv "$tmp/python" "$OUT_DIR/python-relocatable"
  rmdir "$tmp"
fi

PYTHON_BIN="$OUT_DIR/python-relocatable/bin/python3"

if ! "$PYTHON_BIN" -c "import hermes" 2>/dev/null; then
  echo "→ Installing Hermes (ref: $HERMES_GIT_REF)"
  "$PYTHON_BIN" -m pip install --upgrade pip --quiet
  # PEP 508 direct reference — the legacy "#egg=name[extras]" syntax is
  # deprecated and silently drops the extras on modern pip.
  "$PYTHON_BIN" -m pip install --quiet \
    "hermes-agent[all] @ git+https://github.com/NousResearch/hermes-agent.git@$HERMES_GIT_REF"
fi

echo "→ Writing runtime entrypoint"
cat > "$OUT_DIR/hermes-runtime" <<'ENTRYPOINT_EOF'
#!/usr/bin/env bash
# Launched by HermesForNoobs.app. Exec's the bundled Python with the
# Hermes ACP adapter, inheriting stdin/stdout/stderr.
DIR="$(cd "$(dirname "$0")" && pwd)"
exec "$DIR/python-relocatable/bin/python3" -m <ACP_ENTRYPOINT_MODULE> "$@"
ENTRYPOINT_EOF
chmod +x "$OUT_DIR/hermes-runtime"

echo "✓ Bundled Hermes ready at $OUT_DIR"
```

- [ ] **Step 2: Make the script executable.**

```bash
chmod +x "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs/Build/bundle-hermes.sh"
```

- [ ] **Step 3: Add `build/` to `.gitignore`.**

Edit `.gitignore` in the project root. If it already exists, append the lines below; if not, create it with these contents:

```
build/
DerivedData/
.DS_Store
```

- [ ] **Step 4: Commit.**

```bash
git add Build/bundle-hermes.sh .gitignore && \
  git commit -m "feat(build): add Hermes bundling script"
```

---

## Task 4: Run the bundling script manually and verify outputs

This is a manual test of Task 3's script before we integrate it into Xcode.

- [ ] **Step 1: Run the script.**

```bash
cd "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs"
./Build/bundle-hermes.sh build/hermes-runtime
```

Expected: prints `→ Downloading Python …`, `→ Extracting …`, `→ Installing Hermes …`, then `✓ Bundled Hermes ready at …`. Takes 2–5 minutes the first time.

- [ ] **Step 2: Verify the bundle layout.**

```bash
test -x build/hermes-runtime/hermes-runtime && echo "✓ entrypoint exists"
test -x build/hermes-runtime/python-relocatable/bin/python3 && echo "✓ python exists"
build/hermes-runtime/python-relocatable/bin/python3 -c "import hermes; print('hermes version:', hermes.__version__)"
```

Expected: three lines printed, all positive, ending with a Hermes version string.

- [ ] **Step 3: Re-run the script to confirm it's idempotent.**

```bash
./Build/bundle-hermes.sh build/hermes-runtime
```

Expected: should NOT re-download Python and should NOT re-install Hermes. Should finish in under 3 seconds, printing only `→ Writing runtime entrypoint` and `✓ Bundled Hermes ready at …`.

- [ ] **Step 4: No commit needed** — `build/` is gitignored from Task 3.

---

## Task 5: Write a Python smoke test for the ACP round-trip

**Files:**
- Create: `Tests/Python/smoke_test_acp.py`

The exact JSON-RPC method names come from the Task 2 investigation notes. The skeleton below uses `user.message` / `agent.done` as placeholders — **substitute the real names** before running.

- [ ] **Step 1: Create the test file.**

```bash
mkdir -p "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs/Tests/Python"
```

Then write `Tests/Python/smoke_test_acp.py`:

```python
#!/usr/bin/env python3
"""
Smoke test: launch the bundled hermes-runtime, send a user message over
stdio, wait for an end-of-turn notification. Validates that the ACP
adapter is reachable from outside Python.

Requires: bundle built (./Build/bundle-hermes.sh) and an API key for at
least one provider via env var (GEMINI_API_KEY / OPENAI_API_KEY /
ANTHROPIC_API_KEY). The Hermes config used here is minimal; see Plan 2
for the production config loader.
"""

import json
import os
import select
import subprocess
import sys
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[2]
RUNTIME = PROJECT_ROOT / "build/hermes-runtime/hermes-runtime"

# Substitute method names below with the values you recorded in
# docs/superpowers/notes/2026-05-13-acp-investigation.md.
USER_MESSAGE_METHOD = "user.message"
DONE_NOTIFICATION_METHOD = "agent.done"


def main() -> int:
    if not RUNTIME.exists():
        print(f"FAIL: {RUNTIME} does not exist. Run Build/bundle-hermes.sh first.", file=sys.stderr)
        return 1

    if not any(k in os.environ for k in ("GEMINI_API_KEY", "OPENAI_API_KEY", "ANTHROPIC_API_KEY")):
        print("FAIL: set one of GEMINI_API_KEY / OPENAI_API_KEY / ANTHROPIC_API_KEY before running.", file=sys.stderr)
        return 1

    proc = subprocess.Popen(
        [str(RUNTIME)],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=os.environ.copy(),
        text=True,
        bufsize=1,
    )

    request = {
        "id": "smoke-1",
        "method": USER_MESSAGE_METHOD,
        "params": {
            "text": "Reply with only the single word 'pong'.",
            "channel": "smoke-test",
        },
    }
    proc.stdin.write(json.dumps(request) + "\n")
    proc.stdin.flush()

    timeout_seconds = 30
    seen_frames = 0
    while True:
        ready, _, _ = select.select([proc.stdout], [], [], timeout_seconds)
        if not ready:
            print(f"FAIL: timed out after {timeout_seconds}s waiting for {DONE_NOTIFICATION_METHOD}", file=sys.stderr)
            proc.kill()
            return 2

        line = proc.stdout.readline()
        if not line:
            stderr = proc.stderr.read()
            print("FAIL: stdout closed.", file=sys.stderr)
            print(f"stderr was:\n{stderr}", file=sys.stderr)
            return 3

        try:
            frame = json.loads(line)
        except json.JSONDecodeError:
            print(f"NOTE: non-JSON line ignored: {line.rstrip()}", file=sys.stderr)
            continue

        seen_frames += 1
        print(f"FRAME #{seen_frames}: {json.dumps(frame)}")

        if frame.get("method") == DONE_NOTIFICATION_METHOD:
            proc.terminate()
            proc.wait(timeout=5)
            print("PASS")
            return 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 2: Make it executable.**

```bash
chmod +x Tests/Python/smoke_test_acp.py
```

- [ ] **Step 3: Run it with an API key.** Pick whichever provider you have a key for.

```bash
export GEMINI_API_KEY="..."   # or OPENAI_API_KEY / ANTHROPIC_API_KEY
python3 Tests/Python/smoke_test_acp.py
```

Expected: a stream of `FRAME #N: {...}` lines followed by `PASS`.

If the script times out, recheck the method names against your investigation notes. If frames come back but no `agent.done` is ever emitted, Hermes may use a different "end-of-turn" notification — update `DONE_NOTIFICATION_METHOD` and re-run.

- [ ] **Step 4: Update the investigation notes with anything learned.** If the smoke test exposed methods you missed in Task 2, append them to `docs/superpowers/notes/2026-05-13-acp-investigation.md`.

- [ ] **Step 5: Commit.**

```bash
git add Tests/Python/smoke_test_acp.py docs/superpowers/notes && \
  git commit -m "test: ACP round-trip smoke test (Python)"
```

---

## Task 6: Add an Xcode build phase that runs the bundling script

**Files:**
- Modify: `tiptour-macos.xcodeproj/project.pbxproj` (via Xcode UI; do not hand-edit)

- [ ] **Step 1: Open the project in Xcode.**

```bash
open "/Users/omkar/Desktop/Fun Projects/Hermes for Noobs/tiptour-macos.xcodeproj"
```

- [ ] **Step 2: Add the build phase.**

In Xcode: select the **TipTour** target → **Build Phases** tab → **+** at the top-left of the Build Phases pane → **New Run Script Phase**.

Rename the new phase to **"Bundle Hermes runtime"** (double-click the title).

Drag the phase so it sits ABOVE **Copy Bundle Resources** in the ordered list.

Paste this into the script body (the box labeled `Shell` should read `/bin/sh`):

```bash
"$SRCROOT/Build/bundle-hermes.sh" "$BUILT_PRODUCTS_DIR/$EXECUTABLE_FOLDER_PATH/Contents/Resources/hermes-runtime"
```

Uncheck **Based on dependency analysis** (the script is internally idempotent and we want it to run on every build).

In the **Output Files** section, add one entry:

```
$(BUILT_PRODUCTS_DIR)/$(EXECUTABLE_FOLDER_PATH)/Contents/Resources/hermes-runtime/hermes-runtime
```

This tells Xcode the phase produces a file, so subsequent incremental builds know whether to re-run it.

- [ ] **Step 3: Build the project.** Press **Cmd+B**.

Expected: build succeeds. Build log shows the bundling script's `→` output lines.

If you see `command not found`: confirm `Build/bundle-hermes.sh` is executable (`chmod +x`).
If you see `permission denied`: same fix.
If the script downloads succeed but Hermes pip-install fails: usually a transient network error — re-run the build.

- [ ] **Step 4: Locate the bundled runtime inside the built .app.**

```bash
find ~/Library/Developer/Xcode/DerivedData -path '*/TipTour.app/Contents/Resources/hermes-runtime/hermes-runtime' 2>/dev/null
```

Expected: at least one matching path. Note it — Task 7 will assert against the same shape.

- [ ] **Step 5: Commit the project file change.**

```bash
git add tiptour-macos.xcodeproj && \
  git commit -m "feat(build): add 'Bundle Hermes runtime' build phase"
```

---

## Task 7: Write a Swift test that locates and launches the bundled runtime

**Files:**
- Create: `TipTourTests/HermesBundleTests.swift`

- [ ] **Step 1: Create the test file.**

```swift
import XCTest

/// Verifies the Hermes runtime ships inside the .app and can be launched.
/// Does NOT test the JSON-RPC round-trip — that lives in the Python
/// smoke test (Tests/Python/smoke_test_acp.py). This test is the
/// "is the bundle actually here?" gate.
final class HermesBundleTests: XCTestCase {

    private var runtimeURL: URL {
        Bundle.main.resourceURL!
            .appendingPathComponent("hermes-runtime")
            .appendingPathComponent("hermes-runtime")
    }

    func testBundledRuntimeFileExists() throws {
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: runtimeURL.path),
            "Bundled hermes-runtime not found at \(runtimeURL.path). Did the 'Bundle Hermes runtime' build phase run?"
        )
    }

    func testBundledRuntimeIsExecutable() throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: runtimeURL.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
        XCTAssertNotEqual(
            permissions & 0o111, 0,
            "Bundled hermes-runtime is not executable (perms: \(String(permissions, radix: 8)))"
        )
    }

    /// Launches the runtime, sends one JSON-RPC frame, asserts at least
    /// one JSON-RPC frame is read back within 30 seconds. We don't
    /// assert on content — that's the Python smoke test's job — we just
    /// confirm the subprocess is alive and speaking JSON.
    func testBundledRuntimeAcceptsJSONOverStdio() throws {
        // Skip the test if no provider key is available. CI without keys
        // shouldn't fail this test; the bundling itself is what we're
        // gating on locally.
        let hasKey = ProcessInfo.processInfo.environment.keys.contains(where: {
            ["GEMINI_API_KEY", "OPENAI_API_KEY", "ANTHROPIC_API_KEY"].contains($0)
        })
        try XCTSkipUnless(hasKey, "No LLM provider API key in environment — skipping live ACP launch.")

        let process = Process()
        process.executableURL = runtimeURL
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()

        // Same placeholder method name as the Python smoke test —
        // substitute against Task 2's investigation notes.
        let request: [String: Any] = [
            "id": "swift-smoke-1",
            "method": "user.message",
            "params": ["text": "Reply with only 'ack'.", "channel": "swift-smoke"]
        ]
        let data = try JSONSerialization.data(withJSONObject: request) + Data("\n".utf8)
        try stdin.fileHandleForWriting.write(contentsOf: data)

        // Read up to 30s of stdout looking for any JSON line.
        let deadline = Date().addingTimeInterval(30)
        var buffer = Data()
        var foundJSON = false
        while Date() < deadline {
            let chunk = stdout.fileHandleForReading.availableData
            if chunk.isEmpty {
                Thread.sleep(forTimeInterval: 0.05)
                continue
            }
            buffer.append(chunk)
            if let text = String(data: buffer, encoding: .utf8),
               let newlineIndex = text.firstIndex(of: "\n") {
                let firstLine = String(text[..<newlineIndex])
                if let lineData = firstLine.data(using: .utf8),
                   (try? JSONSerialization.jsonObject(with: lineData)) != nil {
                    foundJSON = true
                    break
                }
            }
        }

        process.terminate()
        process.waitUntilExit()

        XCTAssertTrue(foundJSON, "Bundled runtime did not emit any parseable JSON within 30s.")
    }
}
```

- [ ] **Step 2: Add the test file to the TipTourTests target.**

In Xcode: right-click the `TipTourTests` group in the navigator → **Add Files to "tiptour-macos"…** → select `HermesBundleTests.swift` → ensure **TipTourTests** is checked under "Add to targets" → **Add**.

- [ ] **Step 3: Run the file-presence tests.** From the test file, click the diamond next to `testBundledRuntimeFileExists` then `testBundledRuntimeIsExecutable`.

Expected: both green.

If either fails: re-build with Cmd+B (the test target may have built before the build phase ran).

- [ ] **Step 4: Run the live ACP test if you have a provider key.**

In the Test scheme (Cmd+<), set environment variable `GEMINI_API_KEY=...` (or another provider). Run `testBundledRuntimeAcceptsJSONOverStdio`.

Expected: green.

If it fails with "did not emit any parseable JSON": same root cause as Task 5 — the method names are probably wrong. Fix them in both the Swift test and the Python smoke test, and update the investigation notes.

- [ ] **Step 5: Commit.**

```bash
git add TipTourTests/HermesBundleTests.swift tiptour-macos.xcodeproj && \
  git commit -m "test: HermesBundleTests verifies runtime is bundled and launchable"
```

---

## Task 8: Document the build infrastructure

**Files:**
- Create: `Build/README.md`

- [ ] **Step 1: Write `Build/README.md` with this exact content:**

```markdown
# Build infrastructure

## Bundling Hermes into the .app

`bundle-hermes.sh` downloads a relocatable Python 3.11 (via
[python-build-standalone](https://github.com/indygreg/python-build-standalone))
and pip-installs Hermes into `Contents/Resources/hermes-runtime/`. It is
invoked as the Xcode Run Script Phase **"Bundle Hermes runtime"**, which
runs BEFORE Copy Bundle Resources.

### Updating the Hermes version

The script pulls Hermes from `main` by default. To pin a commit or tag, set
the env var before building:

    HERMES_GIT_REF=abc1234 ./Build/bundle-hermes.sh build/hermes-runtime

Or edit `HERMES_GIT_REF` in `bundle-hermes.sh` for a permanent change.

### Updating Python

Edit `PYTHON_VERSION`, `PYTHON_BUILD`, and `PYTHON_ARCH` in
`bundle-hermes.sh`. URLs come from python-build-standalone's GitHub
releases — verify the version/build/arch combination exists before
committing.

`aarch64-apple-darwin` is Apple Silicon. For Intel-only support use
`x86_64-apple-darwin`. Universal builds aren't supported today; add a
parallel download + thin-binary merge to the script if needed.

### Validating the bundle manually

    ./Build/bundle-hermes.sh build/hermes-runtime
    build/hermes-runtime/python-relocatable/bin/python3 \
      -c "import hermes; print(hermes.__version__)"
    GEMINI_API_KEY=... python3 Tests/Python/smoke_test_acp.py

The smoke test exits 0 on success and non-zero on failure.

### Common failure modes

| Symptom | Cause | Fix |
|---|---|---|
| `curl: (22) … 404` on Python download | URL drift in python-build-standalone | Bump `PYTHON_BUILD` to a current release |
| `pip install … fails on hermes-agent` | Transient git/network error | Re-run the build |
| `python3 -c "import hermes"` raises ImportError | Install partially completed | `rm -rf build/hermes-runtime && ./Build/bundle-hermes.sh build/hermes-runtime` |
| Build phase doesn't re-run on incremental builds | "Based on dependency analysis" is checked | Uncheck it in Xcode build phase settings |
```

- [ ] **Step 2: Commit.**

```bash
git add Build/README.md && \
  git commit -m "docs: build infrastructure README"
```

---

## Acceptance criteria for Plan 1

You're done with Plan 1 when ALL of these are true:

- `Build/bundle-hermes.sh build/hermes-runtime` runs idempotently and produces a working `python-relocatable/bin/python3` that can `import hermes`.
- `python3 Tests/Python/smoke_test_acp.py` exits 0 with a valid provider key.
- `tiptour-macos.xcodeproj` builds without errors and produces a `.app` that contains `Contents/Resources/hermes-runtime/hermes-runtime`.
- `HermesBundleTests` passes all three test methods (the third requires a provider key in the test scheme).
- `docs/superpowers/notes/2026-05-13-acp-investigation.md` accurately documents the ACP method names used by both smoke tests.

Once green, Plan 2 starts: writing `HermesClient.swift` in Swift, building the first dev-only "Talk to Hermes" textbox, and routing one tool call end-to-end. The shape of Plan 2 depends on the investigation notes from Task 2 — that's why we did it now.
