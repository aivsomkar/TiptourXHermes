# Build infrastructure

## Bundling Hermes into the .app

`bundle-hermes.sh` downloads a relocatable Python 3.11 (via
[python-build-standalone](https://github.com/astral-sh/python-build-standalone))
and pip-installs Hermes into `Contents/Resources/hermes-runtime/`. It is
invoked as the Xcode Run Script Phase **"Bundle Hermes runtime"** on the
`tiptour-macos` target, which runs BEFORE `Copy Bundle Resources`.

The script also strips macOS extended attributes and ad-hoc signs every
Mach-O file it lays down (the bundled `python3` plus dozens of `.so`
extensions inside Hermes). Without that step, Xcode's outer
hardened-runtime sign pass fails with `code object is not signed at all`.

### Why `BuildScripts/`, not `Build/`?

macOS's case-insensitive filesystem treats `Build/` and `build/` as the
same directory, so a lowercase `build/` artifact dir (which the script
populates) would clobber the uppercase `Build/` source dir. The
`BuildScripts/` name avoids the collision.

### Why is `ENABLE_USER_SCRIPT_SANDBOXING` set to `NO`?

Xcode 14+ sandboxes Run Script Phases by default and denies file reads
outside an enumerated allowlist. Our bundler legitimately needs to
download files, run pip, and write to many paths inside the .app —
declaring every input/output for the sandbox would be brittle. We turn
sandboxing off project-wide; the production-build implications (notary
review, App Store distribution) are a Plan 7+ concern.

### Updating the Hermes version

The script pulls Hermes from `main` by default. To pin a commit or tag,
set the env var before building:

    HERMES_GIT_REF=abc1234 ./BuildScripts/bundle-hermes.sh build/hermes-runtime

Or edit `HERMES_GIT_REF` in `bundle-hermes.sh` for a permanent change.

### Updating Python

Edit `PYTHON_VERSION`, `PYTHON_BUILD`, and `PYTHON_ARCH` in
`bundle-hermes.sh`. URLs come from `astral-sh/python-build-standalone`'s
GitHub releases — verify the version/build/arch combination exists
before committing. (The repo was transferred from indygreg/ to
astral-sh/ in 2025; URLs against the old org return 404.)

`aarch64-apple-darwin` is Apple Silicon. For Intel-only support use
`x86_64-apple-darwin`. Universal builds aren't supported today; add a
parallel download + thin-binary merge to the script if needed.

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

### Validating the bundle manually

    ./BuildScripts/bundle-hermes.sh build/hermes-runtime
    build/hermes-runtime/python-relocatable/bin/python3 \
      -c "import hermes_constants, importlib.metadata; \
          print(importlib.metadata.version('hermes-agent'))"
    python3 Tests/Python/smoke_test_acp.py

The bundle's import check uses `hermes_constants` rather than `hermes`
because the `hermes-agent` distribution exposes no top-level `hermes`
module — `pyproject.toml`'s packages.find lists `agent`, `tools`,
`acp_adapter`, etc.

The smoke test exits 0 after the `initialize` ACP round-trip even
without an API key. To exercise `session/new` and `session/prompt` as
well, first configure Hermes with `hermes setup` (creates
`~/.hermes/config.yaml`) and export a provider API key.

### Common failure modes

| Symptom | Cause | Fix |
|---|---|---|
| `curl: (22) … 404` on Python download | URL drift in python-build-standalone | Bump `PYTHON_BUILD` to a current release from astral-sh |
| `Sandbox: bash(NNN) deny(1) file-read-data …/bundle-hermes.sh` | `ENABLE_USER_SCRIPT_SANDBOXING = YES` | Flip to `NO` in Build Settings (or `project.pbxproj`) |
| `Command CodeSign failed`, `code object is not signed at all` | Bundled Mach-Os unsigned | The script already ad-hoc signs them; if the error returns, confirm `codesign` is in `PATH` and the script's signing pass ran |
| Build phase writes to `…/MacOS/Contents/Resources/…` (wrong path) | Run Script uses `$EXECUTABLE_FOLDER_PATH` | Use `$CONTENTS_FOLDER_PATH` instead — on macOS, `EXECUTABLE_FOLDER_PATH` already includes `/Contents/MacOS` |
| `pip install … fails on hermes-agent` | Transient git/network error | Re-run the build |
| `python3 -c "import hermes_constants"` raises ImportError | Install partially completed | `rm -rf build/hermes-runtime && ./BuildScripts/bundle-hermes.sh build/hermes-runtime` |
| Build phase doesn't re-run on incremental builds | "Based on dependency analysis" is checked | Uncheck it in Xcode build phase settings |
| HermesRuntimeVersion.ReadError thrown at app launch | `hermes-version.txt` missing or malformed | Rerun the bundler. If the file exists but a field is empty, the build host failed to invoke the bundled `python3` for one of the introspection steps — check the script's stderr |
