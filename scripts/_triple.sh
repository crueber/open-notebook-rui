#!/usr/bin/env bash
# Resolve the Rust host target triple. Prefer rustc; fall back to uname so the
# fetch/freeze scripts work before the Rust toolchain is installed.
host_triple () {
  if command -v rustc >/dev/null 2>&1; then
    rustc -Vv | sed -n 's/host: //p'
    return
  fi
  local os arch
  os="$(uname -s)"; arch="$(uname -m)"
  case "$os:$arch" in
    Darwin:arm64)   echo "aarch64-apple-darwin" ;;
    Darwin:x86_64)  echo "x86_64-apple-darwin" ;;
    Linux:x86_64)   echo "x86_64-unknown-linux-gnu" ;;
    Linux:aarch64)  echo "aarch64-unknown-linux-gnu" ;;
    *) echo "UNKNOWN-$os-$arch" ;;
  esac
}
