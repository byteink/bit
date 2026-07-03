# Bit Language for VS Code

Editor support for [Bit](https://bit-lang.byteink.com), a systems language with
TypeScript-flavored syntax and Go-like semantics.

## Features

- Syntax highlighting and bracket/indent rules for `.bit` files.
- Diagnostics, hover, goto-definition, completions, and document symbols via
  the `bitc lsp` language server.
- Format-on-save using `bitc fmt`.

## Requirements

`bitc` must be installed and either on your `PATH` or pointed to via the
`bit.serverPath` setting. See the [Bit installation
docs](https://github.com/byteink/bit#build).

## Settings

| Setting              | Default | Description                                    |
|-----------------------|---------|-------------------------------------------------|
| `bit.serverPath`      | `""`    | Path to `bitc`. Empty auto-discovers it on PATH. |
| `bit.formatOnSave`    | `true`  | Run `bitc fmt` after saving a `.bit` file.       |
| `bit.trace.server`    | `off`   | Trace LSP traffic for debugging.                 |

## Commands

- **Bit: Restart Language Server** — restarts `bitc lsp` without reloading the window.

## License

[MIT](LICENSE)
