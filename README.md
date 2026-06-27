# Open Notebook — Desktop

A self-contained native desktop build of [Open Notebook](https://github.com/lfnovo/open-notebook)
(an open-source, privacy-focused alternative to Google's NotebookLM), packaged with
[Tauri v2](https://tauri.app). **No Docker, no terminal, no separate database to
install** — everything runs inside one app.

Pinned to Open Notebook **v1.10.0**. Open Notebook is MIT licensed, so bundling and
redistribution are permitted.

---

## For users

### What it is

Open Notebook is an AI research assistant: upload sources (PDFs, audio, video, web
pages), generate notes and insights, chat with your documents, search semantically,
and produce podcasts — using the AI provider of your choice, with your data staying
on your machine.

This desktop build wraps the whole stack (web UI + API + database) into a single
**Open Notebook.app**. Launch it and everything starts automatically.

### Install & run

1. Build the app (see [For developers](#for-developers)) or obtain a prebuilt
   `Open Notebook.app`.
2. Move it to `/Applications` and open it.
3. A splash screen shows while the backend starts (first launch takes a few extra
   seconds to run database migrations), then the app loads.
4. Open **Settings → API Keys** to add credentials for an AI provider before using
   AI features.

> macOS: because the app is not yet code-signed/notarized, the first launch may need
> **right-click → Open** to get past Gatekeeper.

### Where your data lives

Everything is stored locally under:

```
~/Library/Application Support/ai.opennotebook.desktop/
├── on.db/            # SurrealDB database (notebooks, sources, notes, embeddings)
└── encryption.key    # encrypts your stored provider API keys
```

⚠️ **Do not delete `encryption.key`** — losing it means losing access to your saved
provider credentials. Back up this folder to preserve your data.

### Updating

Updates ship as new builds of this app — install a newer `Open Notebook.app` over
the old one; your data in Application Support is preserved. The app does **not** show
in-app "update available" prompts (the bundled backend, frontend, and database are
versioned together as one unit).

### Quitting

Quit normally (⌘Q or the menu) and the bundled database + API shut down cleanly. A
forced kill (e.g. Activity Force Quit) may leave background helpers running until the
next reboot.

---

## For developers

### Architecture (the "two-sidecar static-export" variant)

Open Notebook normally runs three services. Here the Next.js server is dropped and
its frontend is shipped as a static export served over Tauri's `tauri://` asset
protocol, leaving two backing processes:

```
Tauri shell (Rust, system webview)
├── frontendDist = Next.js static export (out/), embedded in the app binary
├── sidecar:  surrealdb  (vendored static binary, externalBin)       → 127.0.0.1:8000
└── resource: API        (relocatable Python + deps + source)         → 127.0.0.1:5055
```

**Launch sequence** (`src-tauri/src/lib.rs`): window opens on `loading.html` → spawn
SurrealDB → wait for `:8000` → spawn the API → wait for `:5055` → navigate the window
to `index.html`, which client-redirects to `/notebooks`.

**Shutdown**: on `RunEvent::Exit`/`ExitRequested`, the SurrealDB sidecar is killed and
the API's process group is terminated (SIGTERM → SIGKILL).

### Repository layout

```
.
├── README.md                  # this file
├── Makefile                   # build + release orchestration (make build / run / package / release)
├── packaging/
│   └── release-notes.md       # GitHub release notes template (placeholders filled at publish)
├── scripts/
│   ├── _triple.sh             # host target-triple helper (rustc, uname fallback)
│   ├── fetch-surreal.sh       # download SurrealDB v2 -> src-tauri/binaries/
│   ├── freeze-api.sh          # bundle the Python API (+ disable update check) -> src-tauri/resources/api/
│   └── export-frontend.sh     # patch + statically export the frontend -> ./out
├── src-tauri/
│   ├── Cargo.toml             # tauri, tauri-plugin-shell, libc (unix)
│   ├── tauri.conf.json        # externalBin (surreal) + resources (api) + icons
│   ├── capabilities/default.json
│   ├── .cargo/config.toml     # sends build artifacts to top-level build/
│   ├── icons/                 # generated from vendor logo
│   └── src/{main,lib}.rs      # process lifecycle
└── build/                     # (gitignored) Rust/Tauri output incl. the .app bundle
```

Gitignored (rebuilt by `make`): `vendor/`, `out/`, `build/`, `src-tauri/binaries/`,
`src-tauri/resources/`, `src-tauri/gen/`.

### Prerequisites

- Rust + cargo (stable)
- Node 20+ (one-time frontend export)
- [`uv`](https://docs.astral.sh/uv/) (provides the relocatable CPython 3.12)
- Tauri CLI v2 — used here via `npx @tauri-apps/cli@2`
- Internet access (downloads SurrealDB, CPython, and npm/uv dependencies)
- GitHub CLI (`gh`), authenticated — only for `make release`

### Build

The whole pipeline is driven by the `Makefile`:

```bash
make build
# clones + pins upstream, assembles the three payloads, generates icons, and
# bundles the app -> build/release/bundle/macos/Open Notebook.app  (~800 MB)

make run        # build (if needed) and launch
make clean      # remove build outputs (keeps vendored source + compile cache)
```

The wrapped upstream version is pinned by the `ON_VERSION` variable (default
**`v1.10.0`**); override it with `make build ON_VERSION=v1.10.0`.

Individual stages run in order and can be invoked on their own:

```bash
make vendor      # git clone + checkout $(ON_VERSION) into vendor/open-notebook
make surreal     # SurrealDB v2.1.4 binary -> src-tauri/binaries/
make api         # relocatable Python API  -> src-tauri/resources/api/   (~730 MB)
make frontend    # static frontend export  -> ./out
make icons       # app icon set (only if missing)
make app         # compile + bundle the .app
```

All Rust/Tauri build artifacts (including the bundle) go to the top-level `build/`
directory, set via `src-tauri/.cargo/config.toml`.

### Cutting a release

```bash
make package    # build, then zip the .app -> build/dist/OpenNotebook-Desktop-<ver>-macos-<arch>.zip
make release    # package, then publish a GitHub release tagged $(ON_VERSION) with that asset
```

`make release` is idempotent: it creates the release if the tag doesn't exist, or
refreshes the notes and re-uploads the asset if it does. Release notes come from
`packaging/release-notes.md` (placeholders filled in at publish time). It needs the
GitHub CLI authenticated; if a stale `GH_TOKEN` shadows your login, override the CLI:

```bash
make release GH='env -u GH_TOKEN gh'
```

### How the three payloads are produced

**Frontend (`export-frontend.sh`)** — applies these idempotent patches so
`output: 'export'` works, then runs `next build`:
- `next.config.ts` → `output: 'export'`, `images.unoptimized` (drops the `/api/*`
  rewrites proxy — there is no Next server at runtime).
- Removes the dynamic `src/app/config/route.ts` route handler.
- Splits the two `'use client'` dynamic pages (`notebooks/[id]`, `sources/[id]`) into
  a server shell `page.tsx` (holds the server-only `generateStaticParams`, emitting a
  placeholder so Next produces the route's HTML template + JS chunk) plus the original
  client code in `client.tsx`. The real id is read client-side via `useParams()`.
- Builds with `NEXT_PUBLIC_API_URL=http://localhost:5055`, which the frontend's
  `src/lib/config.ts` bakes into the bundle as the API base URL.

**API (`freeze-api.sh`)** — uses **python-build-standalone** rather than PyInstaller
(the LangChain-heavy tree is fragile to freeze):
- Copies uv's relocatable CPython 3.12 into the bundle (dereferencing symlinks;
  removing the `EXTERNALLY-MANAGED` marker so it is installable).
- Installs the locked third-party deps into that interpreter's own site-packages
  (no venv → stays relocatable).
- Copies the API source (`run_api.py`, `api/`, `open_notebook/`, `prompts/`, …).
- At runtime `lib.rs` spawns `…/api/python/bin/python3.12 run_api.py` (cwd = `src`)
  with `API_RELOAD=false` so it is a single, cleanly-killable uvicorn process.

**Database** — a vendored SurrealDB v2 static binary, run as a Tauri shell-plugin
sidecar against a persistent RocksDB store in the app data dir.

### Notable implementation choices

| Area | Choice & rationale |
|---|---|
| API packaging | **python-build-standalone**, not PyInstaller — far more robust for the LangChain/ML dependency tree than freezing |
| API process model | Shipped as a Tauri **resource** (not a single-file `externalBin` sidecar) and spawned with `std::process`; `API_RELOAD=false` keeps it to one cleanly-killable uvicorn process |
| Shutdown event | macOS quit fires `RunEvent::Exit`, **not** `ExitRequested` — both are handled, and the API's process group is killed via `libc` so no sidecars are orphaned |
| App icons | Generated from the upstream logo with `tauri icon` and referenced in `bundle.icon` |
| In-app update check | **Disabled** — `freeze-api.sh` patches the bundled `api/routers/config.py` so `/api/config` reports no update. A desktop bundle is updated by replacing the whole app, so the upstream "update available" prompt (which just links to GitHub) is misleading |
| Build output | All cargo/Tauri artifacts go to the top-level `build/` dir via `src-tauri/.cargo/config.toml` |

### Known limitations / hardening TODO

- Readiness uses a TCP port check; replace with `GET /health`.
- A hard SIGKILL of the app (not a normal quit) can orphan the sidecars.
- No code-signing / notarization (needed for friendly macOS distribution).
- Client-side navigation to a real `/notebooks/<id>` builds and the SPA loads, but
  should be confirmed with a manual click-through (the route chunk exists).
- Only the `app` bundle target is exercised; `dmg` is untested.
- Linux (`.AppImage`/`.deb`) follows the same scripts but has not been built here.
