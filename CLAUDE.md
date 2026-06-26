# open-notebook-desktop — Tauri v2 bootstrap brief

You are setting up a **native desktop wrapper** for [open-notebook](https://github.com/lfnovo/open-notebook) using **Tauri v2**, in this currently-empty directory. The target is a self-contained `.app` (macOS) and `.AppImage`/`.deb` (Linux) with **no Docker dependency**.

Read this whole file before writing code. Several decisions hinge on spikes you must run first — do not skip them.

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

## STOP — run these three spikes before building anything

This variant is only viable if Open Notebook's frontend can be statically exported and can reach the API cross-origin. Clone and pin first, then validate:

```bash
git clone https://github.com/lfnovo/open-notebook vendor/open-notebook
cd vendor/open-notebook && git checkout v1.9.0   # pin; latest release as of writing
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

```bash
bash scripts/fetch-surreal.sh
bash scripts/freeze-api.sh
bash scripts/export-frontend.sh
cd src-tauri && cargo tauri build      # or: npm run tauri build
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

If Spike 2 fails (core flows need the Next server), keep `on-frontend` as a third sidecar: build the Next.js standalone server (`output: 'standalone'`), freeze/bundle it with Node, spawn it after the API, wait for `:8502`, and have `lib.rs` navigate the window to `http://localhost:8502` instead of `index.html`. Everything else (SurrealDB + API sidecars, lifecycle, kill-on-exit) is identical.

