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
[ -d "$REPO" ] || { echo "ERROR: $REPO not found. Run 'make vendor' first (clones + pins open-notebook)."; exit 1; }

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
# Track PY_VERSION rather than hardcoding the minor (lib.rs spawns the generic python3).
PYTHON="$STAGE/python/bin/python$PY_VERSION"
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

# Disable the in-app update check. This is a desktop bundle: the API, frontend, and
# DB ship together and are updated only by replacing the whole .app — an in-app
# "update available" prompt (which links to GitHub) is misleading and is suppressed.
# Append an override of get_latest_version_cached; Python's last module-level
# definition wins, and api/routers/config.py:get_config resolves the name at call
# time, so /api/config returns latestVersion=null, hasUpdate=false.
CONFIG_PY="$STAGE/src/api/routers/config.py"
if [ -f "$CONFIG_PY" ]; then
  cat >> "$CONFIG_PY" <<'PY'


# --- open-notebook-desktop patch: disable in-app update check ---
async def get_latest_version_cached(current_version):  # noqa: F811
    """Desktop builds are updated by replacing the bundle; never advertise updates."""
    return None, False
PY
  echo "patched out the in-app update check in api/routers/config.py"
fi

# Redirect runtime data out of the (signed, read-only) bundle. Upstream hardcodes
# DATA_FOLDER = "./data" relative to the cwd, which lib.rs sets to the bundled source
# dir — so the LangGraph SQLite checkpoint DB, uploads, and tiktoken cache would be
# written INSIDE the .app. That breaks the code signature ("sealed resource … invalid"
# / "damaged") and fails outright when installed read-only in /Applications. Make
# DATA_FOLDER env-overridable; lib.rs points OPEN_NOTEBOOK_DATA_DIR at the app data dir.
APP_CONFIG="$STAGE/src/open_notebook/config.py"
if [ -f "$APP_CONFIG" ]; then
  perl -0pi -e 's/^DATA_FOLDER = "\.\/data"$/DATA_FOLDER = os.environ.get("OPEN_NOTEBOOK_DATA_DIR", ".\/data")/m' "$APP_CONFIG"
  grep -q 'os.environ.get("OPEN_NOTEBOOK_DATA_DIR"' "$APP_CONFIG" || {
    echo "ERROR: failed to patch DATA_FOLDER in open_notebook/config.py (upstream format changed)"; exit 1; }
  echo "patched DATA_FOLDER to honor OPEN_NOTEBOOK_DATA_DIR in open_notebook/config.py"
fi

# Trim bytecode caches to shrink the bundle.
find "$STAGE" -type d -name __pycache__ -prune -exec rm -rf {} + 2>/dev/null || true

echo "bundled API at $STAGE ($(du -sh "$STAGE" | cut -f1))"
