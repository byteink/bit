#!/usr/bin/env bash
#
# Rebuild the native `bit` (compiler + LSP server) and the VS Code extension,
# then install both locally so the latest language and tooling changes can be
# tested in the editor. Run this after landing any language feature to keep the
# extension, the language server, and the installed compiler in sync.
#
# Host hygiene: all zig/npm work happens in throwaway Docker containers; only
# the finished binary and .vsix touch the Mac. Requires `docker` and the VS Code
# `code` CLI.
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo"

zig_image="bit-zig-0.16.0-amd64:latest"
bin="$HOME/.local/bin/bit"

echo "==> Building native arm64 bit (compiler + LSP) ..."
docker run --rm --platform linux/amd64 -v "$repo":/w -w /w "$zig_image" \
  zig build -Dtarget=aarch64-macos
mkdir -p "$HOME/.local/bin"
# The editor compiler must serve `bit lsp` / `bit fmt`. Those subcommands are not
# self-hosted yet (epic #1345), so the LSP-capable binary is the bootstrap seed,
# `bit-seed`. Install it AS `bit` for the editor. This cross-build also produces
# only `bit-seed` anyway (the self-hosted `bit` needs a native build — see
# build.zig). Switch this to zig-out/bin/bit once lsp/fmt land in selfhost/.
cp zig-out/bin/bit-seed "$bin"
# Re-sign ad-hoc: copying a cross-signed arm64 Mach-O to a new path invalidates
# its signature, and macOS SIGKILLs an invalidly-signed binary on exec.
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
