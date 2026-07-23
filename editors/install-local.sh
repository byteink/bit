#!/usr/bin/env bash
#
# Rebuild the native `bit` (compiler + LSP server) and the VS Code extension,
# then install both locally so the latest language and tooling changes can be
# tested in the editor. Run this after landing any language feature to keep the
# extension, the language server, and the installed compiler in sync.
#
# Host hygiene: the compiler build runs the Mac's already-installed native zig
# (required — see below); npm work for the extension still happens in a
# throwaway Docker container, so only the finished binary and .vsix touch the
# Mac otherwise. Requires `zig`, `docker`, and the VS Code `code` CLI.
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo"

bin="$HOME/.local/bin/bit"

echo "==> Building native arm64 bit (compiler + LSP) ..."
# NATIVE, not Docker: `bit` (fmt/doc/lsp/lint all self-hosted now) is built by
# RUNNING the seed to compile selfhost/ (build.zig's `native` check), which
# only works when the seed targets the build host. A Linux-container cross
# build can only ever produce `bit-seed` — and the seed never gets lint
# (spec/LINT.md's epic scope: "seed/ is not touched"), so installing it would
# silently serve an LSP that can never publish a lint finding. This Mac's zig
# (brew, kept local on purpose — see the toolchain note) already targets its
# own host, aarch64-macos, so a plain `zig build` here is both correct and
# simpler than a container that could not do the job anyway.
zig build
mkdir -p "$HOME/.local/bin"
cp zig-out/bin/bit "$bin"
# Re-sign ad-hoc: copying a signed Mach-O to a new path invalidates its
# signature, and macOS SIGKILLs an invalidly-signed binary on exec.
codesign --force --sign - "$bin"
echo "    installed $bin ($(file -b "$bin"))"

echo "==> Building VS Code extension (.vsix) ..."
docker run --rm -v "$repo/editors/vscode":/out node:20 sh -c '
  cp -r /out /build && cd /build &&
  rm -rf node_modules dist ./*.vsix &&
  npm install --no-audit --no-fund >/dev/null 2>&1 &&
  npm run esbuild-base >/dev/null 2>&1 &&
  npx --yes @vscode/vsce package --no-dependencies -o /out/bit.vsix >/dev/null 2>&1
'

echo "==> Installing extension into VS Code ..."
# `code` is often only a shell alias; resolve the real CLI (fall back to the
# macOS app bundle) so this works from a non-interactive script.
code_cli="$(command -v code || true)"
[ -z "$code_cli" ] && code_cli="/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"
"$code_cli" --install-extension "$repo/editors/vscode/bit.vsix" --force >/dev/null
echo "    installed $("$code_cli" --list-extensions --show-versions | grep byteink.bit)"

echo
echo "Done. Reload VS Code (Cmd+Shift+P -> 'Developer: Reload Window') to load the new server."
