# Bit Language for VS Code

Editor support for [Bit](https://bitlang.org), a systems language with
TypeScript-flavored syntax and Go-like semantics.

## Features

- Syntax highlighting and bracket/indent rules for `.bit` files.
- Diagnostics, hover, goto-definition, completions, document symbols, and
  Format Document via the `bit lsp` language server. Enable VS Code's own
  `editor.formatOnSave` for format-on-save.

## Requirements

`bit` must be installed and either on your `PATH` or pointed to via the
`bit.serverPath` setting. See the [Bit installation
docs](https://github.com/byteink/bit#build).

## Settings

| Setting              | Default | Description                                    |
|-----------------------|---------|-------------------------------------------------|
| `bit.serverPath`      | `""`    | Path to `bit`. Empty auto-discovers it on PATH. |
| `bit.trace.server`    | `off`   | Trace LSP traffic for debugging.                 |

## Commands

- **Bit: Restart Language Server** — restarts `bit lsp` without reloading the window.

## License

[Apache-2.0](LICENSE)
