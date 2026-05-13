#!/usr/bin/env python3
"""
Smoke test: launch the bundled hermes-runtime, run the standard ACP
handshake (initialize → new_session → prompt), and confirm the runtime
holds a JSON-RPC conversation over stdio.

Wire framing: newline-delimited JSON (one JSON-RPC object per line,
terminated by '\\n'). Verified against agent-client-protocol 0.9.0's
acp/stdio.py — readline() on stdin, raw bytes write on stdout.

The smoke test runs in three escalating phases. A phase failing causes
the script to exit non-zero with a phase-tagged diagnostic.

  Phase 1 — initialize round-trip
      Proves stdio + protocol framing + capability negotiation work.
      Requires no API key.

  Phase 2 — new_session
      Proves session management works. Requires Hermes to have a
      provider configured (Hermes pre-binds the LLM at session
      creation, so `session/new` errors out without a provider —
      verified empirically against hermes-agent 0.13.0).

  Phase 3 — prompt + end-of-turn
      Sends a trivial user prompt and waits for the prompt RESPONSE
      (PromptResponse carries `stopReason`). Streamed chunks arrive
      as `session/update` notifications and are logged.

  Phases 2+3 are skipped (not failed) when Hermes is not yet
  configured locally — detected by the presence of
  `$HERMES_HOME/config.yaml` (default `~/.hermes/config.yaml`) plus
  one of GEMINI_API_KEY / OPENAI_API_KEY / ANTHROPIC_API_KEY in env.
  To unlock those phases, run `hermes setup` once using the bundled
  Python (or any system Python with hermes-agent installed).

See docs/superpowers/notes/2026-05-13-acp-investigation.md for the
method surface this test exercises.
"""

from __future__ import annotations

import json
import os
import select
import subprocess
import sys
import time
from pathlib import Path
from typing import Any, Optional

PROJECT_ROOT = Path(__file__).resolve().parents[2]
RUNTIME = PROJECT_ROOT / "build/hermes-runtime/hermes-runtime"

PROTOCOL_VERSION = 1
REQUEST_TIMEOUT_SECONDS = 15
PROMPT_TIMEOUT_SECONDS = 60


def _hermes_home() -> Path:
    return Path(os.environ.get("HERMES_HOME") or (Path.home() / ".hermes"))


def _hermes_configured() -> bool:
    """True iff Hermes has both a config.yaml on disk AND a provider key in env."""
    has_config = (_hermes_home() / "config.yaml").is_file()
    has_key = any(
        os.environ.get(k)
        for k in ("GEMINI_API_KEY", "OPENAI_API_KEY", "ANTHROPIC_API_KEY")
    )
    return has_config and has_key


def _send(proc: subprocess.Popen, payload: dict[str, Any]) -> None:
    line = json.dumps(payload) + "\n"
    assert proc.stdin is not None
    proc.stdin.write(line)
    proc.stdin.flush()


def _read_until(
    proc: subprocess.Popen,
    predicate,
    deadline: float,
) -> Optional[dict[str, Any]]:
    """Read JSON frames from stdout, printing each, until predicate(frame)
    is truthy or the deadline elapses. Returns the matching frame, or None
    on timeout / stdout close."""
    assert proc.stdout is not None
    while time.monotonic() < deadline:
        remaining = max(0.0, deadline - time.monotonic())
        ready, _, _ = select.select([proc.stdout], [], [], remaining)
        if not ready:
            return None
        line = proc.stdout.readline()
        if not line:
            return None
        line = line.strip()
        if not line:
            continue
        try:
            frame = json.loads(line)
        except json.JSONDecodeError:
            print(f"  (non-JSON line ignored: {line!r})", file=sys.stderr)
            continue
        print(f"  ← {json.dumps(frame)}")
        if predicate(frame):
            return frame
    return None


def _is_response_to(request_id: str):
    def pred(frame: dict[str, Any]) -> bool:
        return frame.get("id") == request_id and (
            "result" in frame or "error" in frame
        )
    return pred


def main() -> int:
    if not RUNTIME.exists():
        print(
            f"FAIL: {RUNTIME} does not exist. "
            "Run BuildScripts/bundle-hermes.sh first.",
            file=sys.stderr,
        )
        return 1

    env = os.environ.copy()
    # Hermes' ACP server uses stdout for protocol traffic. We keep stderr
    # captured separately so we can surface it on failure.
    proc = subprocess.Popen(
        [str(RUNTIME)],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=env,
        text=True,
        bufsize=1,
    )

    try:
        # ── Phase 1: initialize ───────────────────────────────────────────
        print("→ Phase 1: initialize")
        init_id = "init-1"
        _send(
            proc,
            {
                "jsonrpc": "2.0",
                "id": init_id,
                "method": "initialize",
                "params": {
                    "protocolVersion": PROTOCOL_VERSION,
                    "clientCapabilities": {
                        "fs": {"readTextFile": False, "writeTextFile": False},
                        "terminal": False,
                    },
                },
            },
        )
        deadline = time.monotonic() + REQUEST_TIMEOUT_SECONDS
        init_response = _read_until(proc, _is_response_to(init_id), deadline)
        if init_response is None:
            return _fail(proc, 2, "Phase 1: no initialize response within "
                                  f"{REQUEST_TIMEOUT_SECONDS}s")
        if "error" in init_response:
            return _fail(proc, 3,
                         f"Phase 1: initialize errored: {init_response['error']}")

        if not _hermes_configured():
            print(
                "⚠ Phases 2+3 skipped — Hermes is not configured locally.\n"
                f"  Looked for: {_hermes_home()}/config.yaml\n"
                "  And one of: GEMINI_API_KEY / OPENAI_API_KEY / "
                "ANTHROPIC_API_KEY in env.\n"
                "  Run `hermes setup` once to enable the full smoke test."
            )
            print("PASS (phase 1)")
            return 0

        # ── Phase 2: new_session ──────────────────────────────────────────
        print("→ Phase 2: new_session")
        ns_id = "ns-1"
        _send(
            proc,
            {
                "jsonrpc": "2.0",
                "id": ns_id,
                "method": "session/new",
                "params": {
                    "cwd": str(PROJECT_ROOT),
                    "mcpServers": [],
                },
            },
        )
        deadline = time.monotonic() + REQUEST_TIMEOUT_SECONDS
        ns_response = _read_until(proc, _is_response_to(ns_id), deadline)
        if ns_response is None:
            return _fail(proc, 4, "Phase 2: no session/new response within "
                                  f"{REQUEST_TIMEOUT_SECONDS}s")
        if "error" in ns_response:
            return _fail(proc, 5,
                         f"Phase 2: session/new errored: {ns_response['error']}")
        session_id = (
            ns_response.get("result", {}).get("sessionId")
            or ns_response.get("result", {}).get("session_id")
        )
        if not session_id:
            return _fail(proc, 6,
                         "Phase 2: session/new response missing sessionId: "
                         f"{ns_response}")

        # ── Phase 3: prompt ───────────────────────────────────────────────
        print("→ Phase 3: prompt")
        p_id = "p-1"
        _send(
            proc,
            {
                "jsonrpc": "2.0",
                "id": p_id,
                "method": "session/prompt",
                "params": {
                    "sessionId": session_id,
                    "prompt": [
                        {
                            "type": "text",
                            "text": "Reply with only the single word 'pong'.",
                        }
                    ],
                },
            },
        )
        deadline = time.monotonic() + PROMPT_TIMEOUT_SECONDS
        p_response = _read_until(proc, _is_response_to(p_id), deadline)
        if p_response is None:
            return _fail(proc, 7, "Phase 3: no session/prompt response within "
                                  f"{PROMPT_TIMEOUT_SECONDS}s")
        if "error" in p_response:
            return _fail(proc, 8,
                         f"Phase 3: session/prompt errored: {p_response['error']}")
        stop_reason = p_response.get("result", {}).get("stopReason")
        print(f"✓ prompt completed with stopReason={stop_reason!r}")
        print("PASS")
        return 0

    finally:
        if proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()


def _fail(proc: subprocess.Popen, code: int, message: str) -> int:
    print(f"FAIL: {message}", file=sys.stderr)
    try:
        if proc.stderr is not None:
            # Best-effort drain — non-blocking.
            ready, _, _ = select.select([proc.stderr], [], [], 0.5)
            if ready:
                print("--- runtime stderr ---", file=sys.stderr)
                print(proc.stderr.read(), file=sys.stderr)
    except Exception:
        pass
    return code


if __name__ == "__main__":
    sys.exit(main())
