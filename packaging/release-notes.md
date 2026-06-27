Native desktop build of [Open Notebook](https://github.com/lfnovo/open-notebook) **@ON_VERSION@**, packaged with Tauri v2. No Docker, no terminal, no separate database — the FastAPI backend and SurrealDB are bundled into one self-contained `.app`.

## Download

- **`@ZIPNAME@`** — macOS, Apple Silicon (M-series) only.

Unzip and move **Open Notebook.app** to `/Applications`.

## ⚠️ First launch (unsigned app)

This build is **not yet code-signed or notarized**, so macOS Gatekeeper will block it on first open. To run it:

1. Try to open it once (it will be blocked).
2. Go to **System Settings → Privacy & Security**, scroll down, and click **Open Anyway**.

Or, from Terminal, clear the quarantine flag:

```bash
xattr -dr com.apple.quarantine "/Applications/Open Notebook.app"
```

A splash screen appears while the backend starts (first launch takes a few extra seconds to run database migrations), then the app loads. Add AI provider credentials in **Settings → API Keys** before using AI features.

## Your data

Stored locally in `~/Library/Application Support/ai.opennotebook.desktop/` (SurrealDB store + an `encryption.key` that protects saved provider keys — don't delete it).

## Notes

- Bundled: Open Notebook @ON_VERSION@ · SurrealDB @SURREAL_VERSION@ · Python 3.12 runtime.
- The in-app "update available" prompt is intentionally disabled — update by installing a newer release over the old app; your data is preserved.
- Apple Silicon (@ARCH@) only for now — no Intel/x86_64 or Linux build in this release.
