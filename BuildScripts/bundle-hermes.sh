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
# Pinned 2026-05-14. Reproducible-build requirement: every CI/release
# build resolves the same Hermes source. To upgrade, replace this SHA
# AND rebuild reference-config.yaml against the new model_dev_cache
# (provider names rarely change but model defaults do).
HERMES_GIT_REF="${HERMES_GIT_REF:-6122a79aab45041d8b7c8d775f95be3ac6ce579f}"

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

# Strip macOS extended attributes — python-build-standalone tarballs and
# pip-installed wheels carry `com.apple.provenance` and similar attrs
# that make codesign reject the file with "resource fork ... not allowed".
echo "→ Stripping extended attributes"
xattr -cr "$OUT_DIR" 2>/dev/null || true

# Ad-hoc sign every Mach-O file in the runtime so Xcode's outer
# hardened-runtime sign pass doesn't choke on "code object is not signed
# at all". Identity `-` means ad-hoc (no team identity); Xcode re-signs
# the whole .app with the dev team afterwards.
echo "→ Ad-hoc signing bundled Mach-O files"
find "$OUT_DIR" -type f \( -name '*.dylib' -o -name '*.so' -o -perm -u+x \) -print0 \
  | xargs -0 -n 50 codesign --force --sign - --timestamp=none 2>/dev/null \
  || echo "  (some files could not be signed; non-fatal for dev builds)"

echo "✓ Bundled Hermes ready at $OUT_DIR"
