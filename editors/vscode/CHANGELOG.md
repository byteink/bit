# Changelog

## 0.1.0

- Syntax highlighting and language configuration for `.bit` files.
- LSP client wired to `bitc lsp`: diagnostics, hover, goto-definition, completions, document symbols.
- Auto-discovers `bitc` on PATH; override with `bit.serverPath`.
- Restarts the language server automatically if `bitc lsp` crashes.
- Format-on-save via `bitc fmt` (toggle with `bit.formatOnSave`).
