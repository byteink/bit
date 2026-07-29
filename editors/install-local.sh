#!/usr/bin/env bash
#
# Rebuild the native `bit` and the VS Code extension, and install the extension.
# Run this after landing any language feature to keep the extension and the
# compiler it talks to in sync.
#
# NOTHING IS INSTALLED INTO $HOME ANYMORE. This used to `cp bit-out/bin/bit` to
# ~/.local/bin/bit, which put a development build on PATH ahead of Homebrew's -
# so plain `bit` in a terminal was the dev compiler reporting `0.1.0-dev`, which
# read as a broken release more than once. The rule now:
#
#   bit            the RELEASED compiler, from `brew install byteink/tap/bit`
#   ./bit-out/bin/bit   the development build, by explicit path
#
# The VS Code extension points at the brew binary (.vscode/settings.json), so
# there is nothing left for a local install to feed. Use the full path when you
# want the dev build; that way which one you are running is never ambiguous.
#
# Host hygiene: the compiler build runs the Mac's already-installed native zig
# (required — see below); npm work for the extension happens in a throwaway
# Docker container, so only the .vsix touches the Mac. Requires `zig`, `docker`,
# and the VS Code `code` CLI.
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo"

echo "==> Building native arm64 bit (compiler + LSP) ..."
# NATIVE, not Docker: `bit` (fmt/doc/lsp/lint all self-hosted) is built by RUNNING
# the pinned stage0 over compiler/ (the driver's host-triple check), which only works
# when that compiler targets the build host. A Linux-container cross build cannot
# produce a runnable host `bit` at all. This Mac's zig (brew, kept local on
# purpose — see the toolchain note) already targets its own host, aarch64-macos,
# so a plain `./make` here is both correct and simpler than a container that
# could not do the job anyway.
#
# The seed used to be the thing doing the compiling, and the paragraph here used
# to warn that a container build could only ever yield `bit-seed`, which never
# got lint. Both halves are moot since #1593 deleted seed/.
./make
echo "    built bit-out/bin/bit ($(./bit-out/bin/bit --version))"
echo "    dev builds are used BY PATH: ./bit-out/bin/bit — nothing is copied to \$HOME"

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
