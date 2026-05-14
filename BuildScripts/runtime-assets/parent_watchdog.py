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
