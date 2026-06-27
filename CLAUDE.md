# open-notebook-desktop — Tauri v2 build

A **native desktop wrapper** for [open-notebook](https://github.com/lfnovo/open-notebook) using **Tauri v2**. The target is a self-contained `.app` (macOS) and `.AppImage`/`.deb` (Linux) with **no Docker dependency**.

> **Status: implemented and verified on macOS (aarch64).** This file is the design
> brief plus the record of decisions actually made. The **Architectural decisions**
> section immediately below is authoritative; the detailed sketch further down (config
> snippets, scripts, `lib.rs`) is the original plan and is largely accurate, but where
> it differs from `src-tauri/` and `scripts/`, **the files in the repo win** — the
> as-built deltas are called out inline.

---

## Architectural decisions (as built)

- **Variant: two-sidecar static-export.** The Next.js server is dropped; its static
  export (`out/`) is served over Tauri's `tauri://` asset protocol and embedded in the
  app binary. The two backing processes are SurrealDB and the Python API. (The
  three-sidecar fallback was not needed — see spike outcomes.)
- **Upstream pinned at `v1.10.0`** in `vendor/open-notebook` (frontend: Next.js 16 /
  React 19; backend: FastAPI; DB: SurrealDB). The pin is the `ON_VERSION` variable in
  the `Makefile`.
- **Frontend → static export.** `scripts/export-frontend.sh` idempotently patches the
  vendored frontend: `next.config.ts` → `output: 'export'` + `images.unoptimized` (drops
  the `/api/*` rewrites proxy); removes the dynamic `app/config/route.ts`; splits the two
  `'use client'` `[id]` pages into a server shell `page.tsx` (server-only
  `generateStaticParams`, placeholder id) + the original `client.tsx`. Built with
  `NEXT_PUBLIC_API_URL=http://localhost:5055`, baked into the bundle as the API base URL.
- **API → python-build-standalone, NOT PyInstaller.** `scripts/freeze-api.sh` copies a
  relocatable CPython 3.12 (from uv; symlinks dereferenced, `EXTERNALLY-MANAGED` marker
  removed), installs the locked deps into its own site-packages (no venv → stays
  relocatable), and copies the API source. Shipped via `bundle.resources`
  (`{"resources/api":"api"}`), **not** as an `externalBin` sidecar.
- **API process model.** `lib.rs` spawns `…/api/python/bin/python3.12 run_api.py`
  (cwd = the source dir) with **`std::process`**, `API_RELOAD=false` so it is a single,
  cleanly-killable uvicorn process, in its **own process group** (unix).
- **SurrealDB → shell-plugin sidecar.** Vendored static binary **v2.1.4** (`externalBin`),
  run against a persistent RocksDB store in `app_data_dir()` (`on.db`).
- **Lifecycle.** Window opens on `loading.html` → spawn SurrealDB → wait `:8000` →
  spawn API → wait `:5055` → navigate to `index.html` (client-redirects to `/notebooks`).
- **Teardown.** Kill on **both `RunEvent::Exit` and `ExitRequested`** — macOS quit fires
  `Exit`, not `ExitRequested`. SurrealDB via the sidecar's `kill()`; the API via
  process-group `kill(-pid, SIGTERM→SIGKILL)` through the `libc` crate, so grandchildren
  (ffmpeg, content extraction) die too. (Graceful quit leaves no orphans; a hard SIGKILL
  of the app itself still can.)
- **CORS.** `CORS_ORIGINS=tauri://localhost,http://tauri.localhost` passed to the API.
- **Encryption key** persisted at `app_data_dir()/encryption.key` (generated once).
- **App icons** generated from the upstream logo via `tauri icon` → `src-tauri/icons/`,
  referenced in `bundle.icon`.
- **In-app update check DISABLED.** `freeze-api.sh` appends an override to the bundled
  `api/routers/config.py` so `get_latest_version_cached` returns `(None, False)` →
  `/api/config` reports `latestVersion: null, hasUpdate: false`, suppressing the
  frontend's update toast (`use-version-check.ts`). A desktop bundle versions its API +
  frontend + DB together; it is updated by replacing the whole `.app`, so the upstream
  prompt (which only links to GitHub) is misleading.
- **Build orchestration via `Makefile`.** `make build` runs the whole pipeline
  (vendor → surreal → api → frontend → icons → app); `make run`/`clean` also exist.
- **Releases via `make release`.** `make package` zips the `.app` (via `ditto`) to
  `build/dist/`; `make release` builds + packages + publishes a GitHub release tagged
  `$(ON_VERSION)` to `crueber/open-notebook-rui`, idempotently (create, else refresh
  notes + re-upload). Notes come from `packaging/release-notes.md` (placeholders).
  Distributed as a zipped `.app` (arm64); unsigned, so users clear quarantine / use
  "Open Anyway". Override the CLI with `GH='env -u GH_TOKEN gh'` if a stale token shadows login.
- **Build output is top-level `build/`** (cargo target-dir set in
  `src-tauri/.cargo/config.toml`), not `src-tauri/target/`.
- **Build target:** `app` bundle (via `npx @tauri-apps/cli@2 build --bundles app`);
  `dmg` untested; Linux not yet built.

---

## Architecture (the "static-export, two-sidecar" variant)

Open Notebook normally runs three things: a Python/FastAPI backend on `:5055`, a Next.js/React frontend on `:8502`, and a SurrealDB instance on `:8000`. In this variant we **drop the Next.js server** and ship the frontend as a static export served by Tauri's own asset protocol, leaving two sidecars.

```
Tauri shell (Rust, system webview)
├── frontendDist = open-notebook's Next.js export (out/), loaded via tauri:// asset protocol
├── sidecar: surrealdb   (vendored single static binary)  → 127.0.0.1:8000
└── sidecar: on-api      (PyInstaller-frozen FastAPI)      → 127.0.0.1:5055
```

**Launch sequence:** window opens on a bundled `loading.html` → spawn SurrealDB → wait for `:8000` → spawn API → wait for `:5055` → navigate the window to the real app (`index.html`). The static app's first API calls therefore only fire once the API is healthy.

**Exit:** kill both sidecars (see Hardening for the orphan caveat).

Open Notebook is MIT licensed, so bundling/redistribution is fine.

---

## Spike outcomes — all three passed ✅

These were the make-or-break viability checks. **All passed**, which is why the
two-sidecar variant above was chosen (no fallback needed). Kept here as rationale.

- **Spike 1 (API base URL):** PASSED. `frontend/src/lib/config.ts` resolves the base URL
  from `NEXT_PUBLIC_API_URL` at build time (after a now-removed `/config` fetch that fails
  harmlessly). Set to `http://localhost:5055` at export time.
- **Spike 2 (`output: 'export'`):** PASSED with the patches listed in the decisions
  section. The `[id]` pages are client components reading `useParams()`, so they work as a
  SPA; no core flow needs server rendering.
- **Spike 3 (CORS):** PASSED. The API reads `CORS_ORIGINS`; it returns
  `access-control-allow-origin: tauri://localhost` for the bundled origin.

Original spike instructions (for reference / re-validation against a new upstream pin):

```bash
git clone https://github.com/lfnovo/open-notebook vendor/open-notebook
cd vendor/open-notebook && git checkout v1.10.0   # pin (Makefile ON_VERSION); `make vendor` does this
```

**Spike 1 — How does the frontend address the API?**
Inspect `frontend/`. In normal operation the UI (`:8502`) and API (`:5055`) are on different ports, so the frontend *already* calls the API cross-origin — that's a good sign there's a configurable base URL. Find it (likely a `NEXT_PUBLIC_*` env var or a runtime config). Record the exact var name; you'll set it to `http://localhost:5055` at export time.
- Configurable base URL → proceed.
- Hardcoded relative `/api/*` proxied by `next.config` rewrites → the proxy disappears with static export. You must inject an absolute base URL (env or patch the API client) **or** fall back to three-sidecar.

**Spike 2 — Does `output: 'export'` actually work?**
This is the decisive risk. In `frontend/`, set `output: 'export'` and `images: { unoptimized: true }` in `next.config`, then `npm ci && npm run build`. Failure modes that force a **fallback to the three-sidecar build** (keep the Next.js server as a third sidecar):
- **Dynamic route segments** like `/notebook/[id]` rendered server-side — static export can't pre-generate unknown IDs. (If the app instead navigates client-side via query params or a SPA shell, you're fine.)
- Route handlers (`app/**/route.ts`), middleware, server actions, or server-component data fetching used for core flows.

Document exactly what breaks. If it's only image optimization or a couple of dynamic routes you can convert to client-side, patch and continue. If core navigation depends on server rendering, **stop and switch to three-sidecar** — that path keeps the Next server and the window just navigates to `http://localhost:8502`.

**Spike 3 — CORS.**
The bundled app's origin is `tauri://localhost` (macOS/Linux) / `http://tauri.localhost` (Windows). The FastAPI backend must allow it. Find Open Notebook's CORS config (env-driven or in `api/`) and confirm you can add those origins. Fetches from a `tauri://` secure context to `http://localhost:5055` are allowed (localhost is treated as potentially-trustworthy), but the CORS allowlist must include the Tauri origin.

Only proceed with the files below once Spikes 1–3 pass.

---

## Prerequisites (verify each is installed)

- Rust + cargo (stable)
- Node 20+ (for the one-time frontend export)
- Python matching the repo's `.python-version` (3.11+), plus `uv`
- `pyinstaller` (`uv tool install pyinstaller` or `pipx install pyinstaller`)
- Tauri CLI v2: `cargo install tauri-cli --version "^2"` (or `npm i -g @tauri-apps/cli@latest`)
- SurrealDB v2 binary for the host platform (download from surrealdb.com)

---

## Target directory layout

```
.
├── CLAUDE.md                  # this file
├── vendor/open-notebook/      # pinned clone (gitignored)
├── out/                       # Next.js static export + loading.html (gitignored)
├── scripts/
│   ├── fetch-surreal.sh
│   ├── freeze-api.sh
│   └── export-frontend.sh
└── src-tauri/
    ├── Cargo.toml
    ├── build.rs
    ├── tauri.conf.json
    ├── binaries/              # sidecars, triple-suffixed (gitignored)
    ├── capabilities/default.json
    └── src/
        ├── main.rs
        └── lib.rs
```

Add `vendor/`, `out/`, and `src-tauri/binaries/` to `.gitignore`.

---

## `src-tauri/tauri.conf.json`

> **As built (see the file):** `externalBin` lists only `binaries/surrealdb` (the API is
> shipped under `bundle.resources` as `{"resources/api":"api"}`, not as a sidecar), and a
> `bundle.icon` array was added. Otherwise as below.

```json
{
  "$schema": "https://schema.tauri.app/config/2",
  "productName": "Open Notebook",
  "version": "0.1.0",
  "identifier": "ai.opennotebook.desktop",
  "build": {
    "frontendDist": "../out"
  },
  "app": {
    "windows": [
      {
        "label": "main",
        "title": "Open Notebook",
        "url": "loading.html",
        "width": 1280,
        "height": 860,
        "visible": true
      }
    ],
    "security": { "csp": null }
  },
  "bundle": {
    "active": true,
    "targets": "all",
    "externalBin": [
      "binaries/surrealdb",
      "binaries/on-api"
    ]
  }
}
```

`url: "loading.html"` must exist inside `out/` (the export script copies it there). `frontendDist` is the export root, served at `tauri://localhost/`.

---

## `src-tauri/capabilities/default.json`

> **As built (see the file):** the `on-api` sidecar entry was removed (the API is no
> longer a sidecar); only the `surrealdb` sidecar remains under `shell:allow-spawn`. The
> permission identifiers below were accepted by codegen as-is.

```json
{
  "$schema": "../gen/schemas/desktop-schema.json",
  "identifier": "default",
  "windows": ["main"],
  "permissions": [
    "core:default",
    "shell:allow-kill",
    {
      "identifier": "shell:allow-spawn",
      "allow": [
        { "name": "surrealdb", "sidecar": true },
        { "name": "on-api", "sidecar": true }
      ]
    }
  ]
}
```

> ⚠️ The exact `tauri-plugin-shell` permission identifiers/scope shape have drifted across v2 point releases. Verify `allow-spawn`/`allow-kill` against the version you install before trusting this; this is the single most likely thing to be subtly wrong.

---

## `src-tauri/Cargo.toml`

```toml
[package]
name = "open-notebook-desktop"
version = "0.1.0"
edition = "2021"

[lib]
name = "app_lib"
crate-type = ["staticlib", "cdylib", "rlib"]

[build-dependencies]
tauri-build = { version = "2", features = [] }

[dependencies]
tauri = { version = "2", features = [] }
tauri-plugin-shell = "2"
serde = { version = "1", features = ["derive"] }
serde_json = "1"
```

## `src-tauri/build.rs`

```rust
fn main() {
    tauri_build::build();
}
```

## `src-tauri/src/main.rs`

```rust
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]
fn main() {
    app_lib::run();
}
```

## `src-tauri/src/lib.rs`

> **As built (see the file), three changes from the sketch below:** (1) the API is spawned
> with `std::process` from the bundled resources (`…/api/python/bin/python3.12 run_api.py`,
> `API_RELOAD=false`, own process group) — not as a shell sidecar; SurrealDB stays a
> sidecar. (2) Teardown matches **both `RunEvent::Exit` and `ExitRequested`** (macOS quit
> fires `Exit`), and kills the API's process group via `libc`. (3) `CORS_ORIGINS` is set on
> the API process.

```rust
use std::{net::TcpStream, sync::Mutex, thread, time::Duration};
use tauri::{Manager, RunEvent};
use tauri_plugin_shell::{process::CommandChild, ShellExt};

struct Sidecars(Mutex<Vec<CommandChild>>);

/// Poll a localhost port until it accepts a TCP connection (or we give up).
fn wait_for_port(port: u16, tries: u32) -> bool {
    for _ in 0..tries {
        if TcpStream::connect(("127.0.0.1", port)).is_ok() {
            return true;
        }
        thread::sleep(Duration::from_millis(500));
    }
    false
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        .manage(Sidecars(Mutex::new(Vec::new())))
        .setup(|app| {
            let handle = app.handle().clone();
            let data_dir = app.path().app_data_dir()?;
            std::fs::create_dir_all(&data_dir).ok();

            thread::spawn(move || {
                let shell = handle.shell();
                let push = |c: CommandChild| {
                    handle.state::<Sidecars>().0.lock().unwrap().push(c);
                };

                // 1) SurrealDB (persistent rocksdb in the app data dir)
                let db = format!("rocksdb:{}", data_dir.join("on.db").display());
                match shell.sidecar("surrealdb").unwrap()
                    .args([
                        "start", "--user", "root", "--pass", "root",
                        "--bind", "127.0.0.1:8000", &db,
                    ])
                    .spawn()
                {
                    Ok((_rx, child)) => push(child),
                    Err(e) => { eprintln!("surreal spawn failed: {e}"); return; }
                }
                if !wait_for_port(8000, 60) { eprintln!("surreal never came up"); return; }

                // 2) Python API. Encryption key must persist across launches — it
                //    encrypts stored provider credentials. Generate once, reuse.
                let key_path = data_dir.join("encryption.key");
                let enc_key = std::fs::read_to_string(&key_path).unwrap_or_else(|_| {
                    let k = uuid_like();
                    std::fs::write(&key_path, &k).ok();
                    k
                });
                match shell.sidecar("on-api").unwrap()
                    .env("SURREAL_URL", "ws://127.0.0.1:8000/rpc")
                    .env("SURREAL_USER", "root")
                    .env("SURREAL_PASSWORD", "root")
                    .env("SURREAL_NAMESPACE", "open_notebook")
                    .env("SURREAL_DATABASE", "open_notebook")
                    .env("OPEN_NOTEBOOK_ENCRYPTION_KEY", enc_key)
                    // Add CORS env here if Open Notebook reads one (Spike 3),
                    // e.g. allow origin "tauri://localhost".
                    .spawn()
                {
                    Ok((_rx, child)) => push(child),
                    Err(e) => { eprintln!("api spawn failed: {e}"); return; }
                }
                if !wait_for_port(5055, 60) { eprintln!("api never came up"); return; }
                // TODO(hardening): replace the TCP check above with an HTTP GET
                // to http://127.0.0.1:5055/health for true readiness.

                // 3) Stack is live — swap the window from the splash to the app.
                if let Some(win) = handle.get_webview_window("main") {
                    let _ = win.eval("location.replace('index.html')");
                }
            });
            Ok(())
        })
        .build(tauri::generate_context!())
        .expect("error building app")
        .run(|app, event| {
            if let RunEvent::ExitRequested { .. } = event {
                if let Some(state) = app.try_state::<Sidecars>() {
                    for child in state.0.lock().unwrap().drain(..) {
                        let _ = child.kill();
                    }
                }
            }
        });
}

/// Cheap random key generator to avoid pulling in the `uuid` crate.
/// Replace with a real CSPRNG if you care.
fn uuid_like() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let n = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
    format!("on-{n:x}")
}
```

---

## Helper scripts

### `scripts/fetch-surreal.sh`
Download a SurrealDB v2 binary for the host and place it triple-suffixed in `binaries/`. Tauri resolves sidecars as `<name>-<target-triple>` and strips the triple at runtime, so the on-disk filename **must** carry the suffix.

```bash
#!/usr/bin/env bash
set -euo pipefail
TRIPLE=$(rustc -Vv | sed -n 's/host: //p')   # e.g. aarch64-apple-darwin
mkdir -p src-tauri/binaries
# Obtain `surreal` for this platform (curl -sSf https://install.surrealdb.com | sh,
# or download the matching archive), then:
cp "$(command -v surreal)" "src-tauri/binaries/surrealdb-${TRIPLE}"
chmod +x "src-tauri/binaries/surrealdb-${TRIPLE}"
echo "placed surrealdb-${TRIPLE}"
```

### `scripts/freeze-api.sh`

> **As built: this PyInstaller approach was NOT used.** The LangChain-heavy tree was too
> fragile to freeze, so the script instead bundles a relocatable **python-build-standalone**
> interpreter + deps + source as a Tauri resource (see the decisions section). The
> PyInstaller sketch below is retained only as the rejected alternative.

Freeze the FastAPI backend with PyInstaller. The entrypoint is `run_api.py` at the repo root.

```bash
#!/usr/bin/env bash
set -euo pipefail
TRIPLE=$(rustc -Vv | sed -n 's/host: //p')
cd vendor/open-notebook
uv sync                      # install deps into a venv
# LangChain/uvicorn/surrealdb client need help being discovered. Expect to
# iterate on --collect-all / --hidden-import until startup is clean.
uv run pyinstaller run_api.py \
  --name on-api \
  --onefile \
  --collect-all langchain \
  --collect-all langchain_core \
  --collect-all open_notebook \
  --collect-all esperanto \
  --hidden-import uvicorn \
  --hidden-import uvicorn.logging \
  --hidden-import uvicorn.protocols.http.auto
cd ../..
mkdir -p src-tauri/binaries
cp vendor/open-notebook/dist/on-api "src-tauri/binaries/on-api-${TRIPLE}"
chmod +x "src-tauri/binaries/on-api-${TRIPLE}"
echo "placed on-api-${TRIPLE}"
```

> Freezing a LangChain-heavy app is the most time-consuming step — budget for hidden-import whack-a-mole. If it becomes a swamp, see Hardening for the standalone-Python alternative.

### `scripts/export-frontend.sh`
Statically export the Next.js frontend, pointed at the local API, then stage it as Tauri's `frontendDist`.

```bash
#!/usr/bin/env bash
set -euo pipefail
cd vendor/open-notebook/frontend
# Spike 1: set the ACTUAL env var the frontend uses for the API base URL.
export NEXT_PUBLIC_API_URL="http://localhost:5055"
# Ensure next.config has: output: 'export', images: { unoptimized: true }
npm ci
npm run build                # emits ./out for a static export
cd ../../..
rm -rf out && cp -r vendor/open-notebook/frontend/out out
cat > out/loading.html <<'HTML'
<!doctype html><meta charset="utf-8">
<title>Open Notebook</title>
<style>html,body{height:100%;margin:0;display:grid;place-items:center;
font:16px system-ui;background:#0e1116;color:#cdd3da}</style>
<div>Starting Open Notebook…</div>
HTML
echo "staged ./out"
```

---

## Build order

> **As built:** use the `Makefile` — `make build` runs the whole pipeline below
> (plus `make vendor` and `make icons`) and bundles to top-level `build/`.

```bash
make build       # vendor -> surreal -> api -> frontend -> icons -> app
# equivalently, the underlying stages:
#   make vendor    (git clone + checkout $ON_VERSION)
#   bash scripts/fetch-surreal.sh
#   bash scripts/freeze-api.sh
#   bash scripts/export-frontend.sh
#   npx @tauri-apps/cli@2 build --bundles app
```

---

## Hardening (do after the happy path works)

- **Orphaned API on quit.** PyInstaller `--onefile` extracts and forks; a hard quit (`SIGKILL` to the sidecar) can leave the real uvicorn process running. Either (a) send `SIGTERM` so the bootloader forwards it for a graceful uvicorn shutdown, (b) spawn the sidecar in its own process group and kill the group, or (c) switch the API to `--onedir` (no fork) bundled via `bundle.resources`, spawned by absolute path from `resource_dir()`. Test a force-quit and confirm nothing's still listening on `:5055`/`:8000`.
- **PyInstaller too fragile?** Ship a relocatable interpreter (python-build-standalone) + a uv-synced venv + the source as resources, and spawn `python run_api.py`. Often more robust than freezing for ML-heavy dependency trees.
- **Readiness.** Replace the TCP port check with an HTTP `GET /health` so you wait for the app to be *ready*, not just *listening*.
- **macOS distribution.** You'll need code-signing + notarization for Gatekeeper; budget for it if distributing beyond yourself.
- **Encryption key.** Confirm the generated key survives app restarts and OS updates (it lives in `app_data_dir`). Losing it means losing access to stored provider credentials.

---

## Fallback: three-sidecar build

> **Not used** — Spike 2 passed, so the static export is shipped directly. Retained as the
> escape hatch if a future upstream pin makes core flows depend on server rendering.

If Spike 2 fails (core flows need the Next server), keep `on-frontend` as a third sidecar: build the Next.js standalone server (`output: 'standalone'`), freeze/bundle it with Node, spawn it after the API, wait for `:8502`, and have `lib.rs` navigate the window to `http://localhost:8502` instead of `index.html`. Everything else (SurrealDB + API sidecars, lifecycle, kill-on-exit) is identical.

