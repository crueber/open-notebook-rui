#!/usr/bin/env bash
# Download a SurrealDB v2 binary for the host and place it triple-suffixed in
# src-tauri/binaries/. Tauri resolves sidecars as <name>-<target-triple> and
# strips the triple at runtime, so the on-disk filename MUST carry the suffix.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/_triple.sh"

SURREAL_VERSION="${SURREAL_VERSION:-v2.1.4}"   # pin a v2 release; override via env
TRIPLE="$(host_triple)"
mkdir -p "$ROOT/src-tauri/binaries"
DEST="$ROOT/src-tauri/binaries/surrealdb-${TRIPLE}"

# Map the Rust triple to SurrealDB's release asset naming.
case "$TRIPLE" in
  aarch64-apple-darwin)      ASSET="surreal-${SURREAL_VERSION}.darwin-arm64.tgz" ;;
  x86_64-apple-darwin)       ASSET="surreal-${SURREAL_VERSION}.darwin-amd64.tgz" ;;
  x86_64-unknown-linux-gnu)  ASSET="surreal-${SURREAL_VERSION}.linux-amd64.tgz" ;;
  aarch64-unknown-linux-gnu) ASSET="surreal-${SURREAL_VERSION}.linux-arm64.tgz" ;;
  *) echo "ERROR: unsupported triple $TRIPLE"; exit 1 ;;
esac

URL="https://github.com/surrealdb/surrealdb/releases/download/${SURREAL_VERSION}/${ASSET}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "==> downloading $URL"
curl -sSfL "$URL" -o "$TMP/surreal.tgz"
tar -xzf "$TMP/surreal.tgz" -C "$TMP"
# The archive contains a single `surreal` binary.
cp "$TMP/surreal" "$DEST"
chmod +x "$DEST"
echo "placed surrealdb-${TRIPLE} ($("$DEST" version 2>/dev/null || echo '?'))"
