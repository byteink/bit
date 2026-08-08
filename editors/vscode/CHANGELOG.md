# Changelog

## 0.1.1

- LSP child process now spawns with `argv0: "bit-lsp"`, so `ps`/Activity
  Monitor show `bit-lsp` instead of a bare `bit`.

## 0.1.0

- Syntax highlighting and language configuration for `.bit` files.
- LSP client wired to `bit lsp`: diagnostics, hover, goto-definition, completions, document symbols.
- Auto-discovers `bit` on PATH; override with `bit.serverPath`.
- Restarts the language server automatically if `bit lsp` crashes.
- Format-on-save via `bit fmt` (toggle with `bit.formatOnSave`).
