# Open Notebook — desktop build orchestration.
#
#   make build      # full pipeline -> build/release/bundle/macos/Open Notebook.app
#   make run        # build (if needed) and launch the app
#   make clean      # remove build outputs (keeps the vendored upstream + caches)
#
# Individual stages (run in this order) are also available as targets:
#   make vendor surreal api frontend icons app

SHELL := /usr/bin/env bash

# Pin the upstream Open Notebook release to wrap. Override: make ON_VERSION=v1.10.0
ON_VERSION ?= v1.10.0
ON_REPO    ?= https://github.com/lfnovo/open-notebook

# Pinned SurrealDB sidecar version (consumed by scripts/fetch-surreal.sh).
SURREAL_VERSION ?= v2.1.4
export SURREAL_VERSION

# Tooling installed outside the default PATH (rustup, uv).
export PATH := $(HOME)/.cargo/bin:$(HOME)/.local/bin:$(PATH)
TAURI := npx --yes @tauri-apps/cli@2
# GitHub CLI. Override if a stale GH_TOKEN shadows your login, e.g.:
#   make release GH='env -u GH_TOKEN gh'
GH ?= gh

ROOT       := $(CURDIR)
VENDOR     := $(ROOT)/vendor/open-notebook
APP        := build/release/bundle/macos/Open Notebook.app

# Release artifact naming. ON_VER strips the leading "v" (v1.10.0 -> 1.10.0).
GH_REPO := crueber/open-notebook-rui
ON_VER  := $(ON_VERSION:v%=%)
ARCH    := $(shell uname -m)
DIST    := build/dist
ZIPNAME := OpenNotebook-Desktop-$(ON_VER)-macos-$(ARCH).zip
ZIP     := $(DIST)/$(ZIPNAME)

.DEFAULT_GOAL := build
.PHONY: build run app vendor surreal api frontend icons package release clean clean-vendor distclean help

## Full build: vendor + all three payloads + icons + app bundle.
build: vendor surreal api frontend icons app
	@echo "✔ built $(APP)"

## Clone and pin the upstream source (idempotent).
vendor:
	@if [ ! -d "$(VENDOR)/.git" ]; then \
	  echo "==> cloning $(ON_REPO) -> vendor/open-notebook"; \
	  git clone "$(ON_REPO)" "$(VENDOR)"; \
	fi
	@echo "==> checking out $(ON_VERSION)"
	@git -C "$(VENDOR)" fetch --tags --quiet
	@git -C "$(VENDOR)" checkout --quiet "$(ON_VERSION)"
	@echo "    vendor @ $$(git -C "$(VENDOR)" describe --tags)"

## SurrealDB sidecar binary -> src-tauri/binaries/
surreal:
	bash scripts/fetch-surreal.sh

## Python API bundle (relocatable interpreter + deps + source) -> src-tauri/resources/api/
api:
	bash scripts/freeze-api.sh

## Patch + statically export the frontend -> ./out
frontend:
	bash scripts/export-frontend.sh

## Generate the app icon set from the upstream logo (only if missing).
icons:
	@if [ ! -f src-tauri/icons/icon.icns ]; then \
	  echo "==> generating icons from vendor logo"; \
	  $(TAURI) icon "$(VENDOR)/logo.png"; \
	else \
	  echo "==> icons already present"; \
	fi

## Compile + bundle the .app (artifacts land in top-level build/ via src-tauri/.cargo/config.toml).
app:
	$(TAURI) build --bundles app

## Build if needed, then launch.
run: app
	open "$(APP)"

## Build, then zip the .app into a downloadable archive (build/dist/).
package: build
	@mkdir -p "$(DIST)"
	@rm -f "$(ZIP)"
	ditto -c -k --keepParent "$(APP)" "$(ZIP)"
	@echo "✔ packaged $(ZIP) ($$(du -h "$(ZIP)" | cut -f1 | tr -d ' '))"

## Build + package + publish a GitHub release for $(ON_VERSION). Idempotent: creates
## the release if missing, otherwise refreshes its notes and re-uploads the asset.
## Requires `gh` auth. See the GH variable above if a stale GH_TOKEN gets in the way.
release: package
	@mkdir -p build
	@sed -e 's/@ON_VERSION@/$(ON_VERSION)/g' \
	     -e 's/@SURREAL_VERSION@/$(SURREAL_VERSION)/g' \
	     -e 's/@ARCH@/$(ARCH)/g' \
	     -e 's/@ZIPNAME@/$(ZIPNAME)/g' \
	     packaging/release-notes.md > build/release-notes.md
	@if $(GH) release view $(ON_VERSION) --repo $(GH_REPO) >/dev/null 2>&1; then \
	  echo "==> release $(ON_VERSION) exists — refreshing notes + asset"; \
	  $(GH) release edit $(ON_VERSION) --repo $(GH_REPO) --notes-file build/release-notes.md; \
	  $(GH) release upload $(ON_VERSION) "$(ZIP)" --repo $(GH_REPO) --clobber; \
	else \
	  echo "==> creating release $(ON_VERSION)"; \
	  $(GH) release create $(ON_VERSION) "$(ZIP)" --repo $(GH_REPO) --target master \
	    --title "Open Notebook Desktop — $(ON_VERSION) (macOS, Apple Silicon)" \
	    --notes-file build/release-notes.md; \
	fi
	@echo "✔ released $(ON_VERSION): https://github.com/$(GH_REPO)/releases/tag/$(ON_VERSION)"

## Remove build outputs but keep the vendored source and compile caches.
clean:
	rm -rf out src-tauri/binaries src-tauri/resources
	rm -rf "build/release/bundle" build/dist build/release-notes.md

## Also remove the cargo target cache.
distclean: clean
	rm -rf build

## Remove the vendored upstream clone.
clean-vendor:
	rm -rf vendor

help:
	@grep -E '^##|^[a-zA-Z_-]+:' Makefile | sed 's/^## /  /' | sed 's/:.*//'
