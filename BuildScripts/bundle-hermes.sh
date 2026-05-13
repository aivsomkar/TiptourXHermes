#!/usr/bin/env bash
# bundle-hermes.sh — Downloads a relocatable Python and installs Hermes
# into $1/hermes-runtime/. Idempotent: skips Python download if cached.

set -euo pipefail

# python-build-standalone was transferred from indygreg/ to astral-sh/ in
# 2025; old indygreg URLs 404 today. The astral-sh repo publishes the same
# release naming scheme so only the host org changes.
PYTHON_VERSION="3.11.15"
PYTHON_BUILD="20260510"
PYTHON_ARCH="aarch64-apple-darwin"
PYTHON_FLAVOUR="install_only"
HERMES_GIT_REF="${HERMES_GIT_REF:-main}"

PROJECT_DIR="${SRCROOT:-$(pwd)}"
OUT_DIR="${1:-$PROJECT_DIR/build/hermes-runtime}"
CACHE_DIR="$PROJECT_DIR/build/.cache"

PYTHON_URL="https://github.com/astral-sh/python-build-standalone/releases/download/$PYTHON_BUILD/cpython-$PYTHON_VERSION+$PYTHON_BUILD-$PYTHON_ARCH-$PYTHON_FLAVOUR.tar.gz"
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

if ! "$PYTHON_BIN" -c "import hermes_constants" 2>/dev/null; then
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
exec "$DIR/python-relocatable/bin/python3" -m acp_adapter "$@"
ENTRYPOINT_EOF
chmod +x "$OUT_DIR/hermes-runtime"

echo "✓ Bundled Hermes ready at $OUT_DIR"
