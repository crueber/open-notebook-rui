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

# Tooling installed outside the default PATH (rustup, uv).
export PATH := $(HOME)/.cargo/bin:$(HOME)/.local/bin:$(PATH)
TAURI := npx --yes @tauri-apps/cli@2

ROOT       := $(CURDIR)
VENDOR     := $(ROOT)/vendor/open-notebook
APP        := build/release/bundle/macos/Open Notebook.app

.DEFAULT_GOAL := build
.PHONY: build run app vendor surreal api frontend icons clean clean-vendor distclean help

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

## Remove build outputs but keep the vendored source and compile caches.
clean:
	rm -rf out src-tauri/binaries src-tauri/resources
	rm -rf "build/release/bundle"

## Also remove the cargo target cache.
distclean: clean
	rm -rf build

## Remove the vendored upstream clone.
clean-vendor:
	rm -rf vendor

help:
	@grep -E '^##|^[a-zA-Z_-]+:' Makefile | sed 's/^## /  /' | sed 's/:.*//'
