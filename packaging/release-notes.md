Native desktop build of [Open Notebook](https://github.com/lfnovo/open-notebook) **@ON_VERSION@**, packaged with Tauri v2. No Docker, no terminal, no separate database — the FastAPI backend and SurrealDB are bundled into one self-contained `.app`.

## Download

- **`@ZIPNAME@`** — macOS, Apple Silicon (M-series) only.

Unzip and move **Open Notebook.app** to `/Applications`.

## ⚠️ First launch (ad-hoc signed, not notarized)

This build is ad-hoc signed but **not notarized** with an Apple Developer ID, so
macOS Gatekeeper blocks it on first open. **The simplest fix** — clear the
quarantine flag macOS adds to downloads, then open it:

```bash
xattr -cr "/Applications/Open Notebook.app"     # adjust the path to where you put it
open "/Applications/Open Notebook.app"
```

Alternatively, double-click it, dismiss the warning, then go to **System Settings →
Privacy & Security**, scroll down, and click **Open Anyway**.

> If you see **"Open Notebook is damaged and can't be opened"**, that's the same
> Gatekeeper block — the `xattr -cr` command above resolves it. The app is not
> actually damaged.

A splash screen appears while the backend starts (first launch takes a few extra seconds to run database migrations), then the app loads. Add AI provider credentials in **Settings → API Keys** before using AI features.

## Your data

Stored locally in `~/Library/Application Support/ai.opennotebook.desktop/` (SurrealDB store + an `encryption.key` that protects saved provider keys — don't delete it).

## Notes

- Bundled: Open Notebook @ON_VERSION@ · SurrealDB @SURREAL_VERSION@ · Python 3.12 runtime.
- The in-app "update available" prompt is intentionally disabled — update by installing a newer release over the old app; your data is preserved.
- Apple Silicon (@ARCH@) only for now — no Intel/x86_64 or Linux build in this release.
