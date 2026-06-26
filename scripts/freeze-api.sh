#!/usr/bin/env bash
# Bundle the FastAPI backend as a RELOCATABLE Python tree (python-build-standalone
# + deps installed into its own site-packages + the API source). This is the
# CLAUDE.md "Hardening" alternative to PyInstaller, chosen because the LangChain-
# heavy dependency tree is fragile to freeze. The result is staged under
# src-tauri/resources/api/ and bundled via tauri.conf.json `bundle.resources`.
# At runtime lib.rs spawns:  <resources>/api/python/bin/python3  <resources>/api/src/run_api.py
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="$ROOT/vendor/open-notebook"
STAGE="$ROOT/src-tauri/resources/api"
PY_VERSION="${PY_VERSION:-3.12}"   # repo requires >=3.11,<3.13

export PATH="$HOME/.local/bin:$PATH"
command -v uv >/dev/null || { echo "ERROR: uv not found on PATH"; exit 1; }
[ -d "$REPO" ] || { echo "ERROR: $REPO not found. Clone vendor/open-notebook @ v1.9.0 first."; exit 1; }

echo "==> 1/4 obtain relocatable CPython $PY_VERSION (python-build-standalone via uv)"
uv python install "$PY_VERSION"
PYBIN="$(uv python find "$PY_VERSION")"
# Resolve through uv's 3.12 -> 3.12.x symlink to the REAL install root.
PYROOT="$(cd "$(dirname "$PYBIN")/.." && pwd -P)"   # contains bin/ lib/

echo "==> 2/4 copy interpreter into bundle (dereference symlinks -> self-contained)"
rm -rf "$STAGE"
mkdir -p "$STAGE/python"
cp -RL "$PYROOT"/. "$STAGE/python/"
# Drop uv's managed/externally-managed markers so we can install into our copy.
find "$STAGE/python" -name 'EXTERNALLY-MANAGED' -delete 2>/dev/null || true
PYTHON="$STAGE/python/bin/python3.12"
"$PYTHON" --version

echo "==> 3/4 install third-party deps into the bundled interpreter (not the project)"
cd "$REPO"
uv export --no-emit-project --no-dev --frozen --format requirements-txt > "$STAGE/requirements.txt"
# Install into the bundled interpreter's own site-packages (no venv -> stays
# relocatable; python-build-standalone resolves sys.prefix relative to the binary).
uv pip install --python "$PYTHON" -r "$STAGE/requirements.txt"

echo "==> 4/4 stage API source (run_api.py puts its own dir on sys.path)"
mkdir -p "$STAGE/src"
cp -R api open_notebook prompts run_api.py "$STAGE/src/"
for extra in commands migrations pyproject.toml; do
  [ -e "$REPO/$extra" ] && cp -R "$REPO/$extra" "$STAGE/src/"
done
# Trim bytecode caches to shrink the bundle.
find "$STAGE" -type d -name __pycache__ -prune -exec rm -rf {} + 2>/dev/null || true

echo "bundled API at $STAGE ($(du -sh "$STAGE" | cut -f1))"
