#!/usr/bin/env bash
# Statically export Open Notebook's Next.js frontend, pointed at the local API,
# and stage it as Tauri's frontendDist (./out).
#
# This script also applies the Spike-2 patches required to make `output: 'export'`
# work (see CLAUDE.md / memory). It is idempotent: safe to re-run on a fresh
# `vendor/open-notebook` clone.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FE="$ROOT/vendor/open-notebook/frontend"
APP="$FE/src/app/(dashboard)"

[ -d "$FE" ] || { echo "ERROR: $FE not found. Clone vendor/open-notebook @ v1.9.0 first."; exit 1; }

echo "==> Patch 1/4: next.config.ts -> output:'export'"
cat > "$FE/next.config.ts" <<'TS'
import type { NextConfig } from "next";

// PATCHED for Tauri static-export ("two-sidecar") build.
// - output: "export" emits a static ./out served via Tauri's tauri:// asset protocol.
// - images.unoptimized: required because the Next image optimizer needs a server.
// - The /api/* rewrites proxy and proxyClientMaxBodySize are intentionally dropped:
//   there is no Next server at runtime. The frontend reaches FastAPI directly via
//   NEXT_PUBLIC_API_URL (set at export time), resolved in src/lib/config.ts.
const nextConfig: NextConfig = {
  output: "export",
  images: { unoptimized: true },
};

export default nextConfig;
TS

echo "==> Patch 2/4: remove dynamic route handler src/app/config/route.ts"
rm -f "$FE/src/app/config/route.ts"
rmdir "$FE/src/app/config" 2>/dev/null || true

split_dynamic_route () {
  # $1 = route dir, $2 = client component name
  local dir="$1" name="$2"
  if [ ! -f "$dir/client.tsx" ]; then
    mv "$dir/page.tsx" "$dir/client.tsx"
    # Rename whatever the original default export was to the client name.
    perl -0pi -e "s/export default function \w+\(/export default function ${name}(/" "$dir/client.tsx"
  fi
}

echo "==> Patch 3/4: split client dynamic pages, add server generateStaticParams shells"
split_dynamic_route "$APP/notebooks/[id]" "NotebookDetailClient"
split_dynamic_route "$APP/sources/[id]"   "SourceDetailClient"

cat > "$APP/notebooks/[id]/page.tsx" <<'TSX'
// Server shell for the dynamic /notebooks/[id] route.
// generateStaticParams is server-only and required by `output: "export"`; it
// cannot live in a 'use client' module. We emit one placeholder so Next produces
// the route's HTML template + JS chunk; the real id is read client-side via
// useParams() in client.tsx. In the Tauri shell all navigation is client-side.
import NotebookDetailClient from './client'

// Re-export the context types so the many `../[id]/page` importers keep resolving.
export type { ContextMode, ContextSelections } from './client'

export function generateStaticParams() {
  return [{ id: 'index' }]
}

export default function Page() {
  return <NotebookDetailClient />
}
TSX

cat > "$APP/sources/[id]/page.tsx" <<'TSX'
// Server shell for the dynamic /sources/[id] route. See notebooks/[id]/page.tsx.
import SourceDetailClient from './client'

export function generateStaticParams() {
  return [{ id: 'index' }]
}

export default function Page() {
  return <SourceDetailClient />
}
TSX

echo "==> Patch 4/4: build static export"
cd "$FE"
# Spike 1: the frontend resolves its API base URL from NEXT_PUBLIC_API_URL at
# build time (src/lib/config.ts), baked into the bundle.
export NEXT_PUBLIC_API_URL="http://localhost:5055"
[ -d node_modules ] || npm ci
npm run build          # emits ./out for a static export

echo "==> Stage ./out and add loading splash"
cd "$ROOT"
rm -rf out && cp -r "$FE/out" out
cat > out/loading.html <<'HTML'
<!doctype html><meta charset="utf-8">
<title>Open Notebook</title>
<style>html,body{height:100%;margin:0;display:grid;place-items:center;
font:16px system-ui;background:#0e1116;color:#cdd3da}</style>
<div>Starting Open Notebook…</div>
HTML
echo "staged ./out"
