# Bit Language for VS Code

Editor support for [Bit](https://bit-lang.byteink.com), a systems language with
TypeScript-flavored syntax and Go-like semantics.

## Features

- Syntax highlighting and bracket/indent rules for `.bit` files.
- Diagnostics, hover, goto-definition, completions, and document symbols via
  the `bit lsp` language server.
- Format-on-save using `bit fmt`.

## Requirements

`bit` must be installed and either on your `PATH` or pointed to via the
`bit.serverPath` setting. See the [Bit installation
docs](https://github.com/byteink/bit#build).

## Settings

| Setting              | Default | Description                                    |
|-----------------------|---------|-------------------------------------------------|
| `bit.serverPath`      | `""`    | Path to `bit`. Empty auto-discovers it on PATH. |
| `bit.formatOnSave`    | `true`  | Run `bit fmt` after saving a `.bit` file.       |
| `bit.trace.server`    | `off`   | Trace LSP traffic for debugging.                 |

## Commands

- **Bit: Restart Language Server** — restarts `bit lsp` without reloading the window.

## License

[Apache-2.0](LICENSE)
