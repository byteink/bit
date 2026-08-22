# Changelog

## Unreleased

## 0.1.2

- `bit.json` is now associated with the `jsonc` language (it allows `//` and
  `/* */` comments, which `bit add` preserves byte-for-byte via the CST edit
  layer — #1479), so opening one no longer shows every comment as a JSON
  error. `bit.lock` is associated with plain `json` (it is machine-generated
  and never carries comments).
- Added JSON schemas for both files under `schemas/`, wired through
  `contributes.jsonValidation`: inline validation, key autocomplete and
  hover descriptions for `bit.json`'s `name`/`dependencies` and every field
  `bit.lock` records per resolved dependency (#2752). `bit.lock`'s schema
  states up front that the file is machine-owned and not meant for hand
  edits.

- Removed `bit.formatOnSave`. `bit lsp` now advertises
  `documentFormattingProvider` and serves `textDocument/formatting` itself
  (#3007), so Format Document works in VS Code without the extension having
  to shell out to `bit fmt` after every save — which raced the editor's own
  buffer, since the rewrite landed on disk asynchronously and unawaited.
  Use VS Code's own `editor.formatOnSave` for format-on-save; it now works
  per-language and composes with everything else VS Code offers (format
  selection, format-on-type, an unsaved buffer).

## 0.1.1

- Syntax highlighting no longer treats `function` as a declaration keyword.
  `function` was retired in favor of `fn` (SPEC §10.3); highlighting the old
  spelling told the reader a removed keyword was still valid. `fn` is
  unaffected. `sample.bit` now declares everything with `fn`.

- LSP child process now spawns with `argv0: "bit-lsp"`, so anything reading
  `argv[0]` tells the server apart from a compile: `ps`, `pgrep -f`, `htop`
  and `lsof` all show `bit-lsp lsp --stdio`.

  **macOS Activity Monitor still shows `bit`, and no spawn-side change can
  alter that.** Its Process Name column reads the kernel accounting name
  (`ps -o ucomm=`), which macOS takes from the *resolved* executable's
  filename at exec. `argv0` does not touch it, and neither does invoking
  through a symlink named `bit-lsp` — both were measured, and `ucomm` stayed
  `bit` in each case. Changing it would need a separately-named copy of the
  binary on disk, or a `prctl(PR_SET_NAME)` equivalent, which macOS does not
  provide.

  On Linux the same split applies for the same reason: `/proc/pid/cmdline`
  carries the new name so `ps`, `htop` and System Monitor show it, while
  `/proc/pid/comm` stays `bit`, so `top` does not.

## 0.1.0

- Syntax highlighting and language configuration for `.bit` files.
- LSP client wired to `bit lsp`: diagnostics, hover, goto-definition, completions, document symbols.
- Auto-discovers `bit` on PATH; override with `bit.serverPath`.
- Restarts the language server automatically if `bit lsp` crashes.
- Format-on-save via `bit fmt` (toggle with `bit.formatOnSave`).
