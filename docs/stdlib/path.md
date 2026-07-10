# std/path

Lexical path handling. Nothing here touches the filesystem — `base("/no/such")`
answers without asking whether the file exists. For that, use `std/fs`.

<!-- doctest: per-block -->

### `Separator: string`

The path separator, `"/"`.

### `isAbs(p: string): bool`

Whether `p` starts at the root.

### `join(a: string, b: string): string`

`a` and `b` joined with exactly one separator between them. An absolute `b`
replaces `a` entirely, and an empty component contributes nothing.

```bit
import { join, isAbs } from "std/path"

function configPath(home: string): string {
  return join(home, ".config/bit.toml")
}

function resolve(base: string, p: string): string {
  if (isAbs(p)) {
    return p
  }
  return join(base, p)
}
```

## Splitting a path

The four accessors partition a path. For `/tmp/report.tar.gz`:

| Call | Result |
|---|---|
| `dir(p)` | `/tmp` |
| `base(p)` | `report.tar.gz` |
| `stem(p)` | `report.tar` |
| `ext(p)` | `.gz` |

### `base(p: string): string`

The final component, without any directory prefix.

### `dir(p: string): string`

Everything before the final component, without its trailing separator. `"."` when
`p` has no separator.

### `ext(p: string): string`

The extension of the final component, including the leading dot — the **last**
dot, so `.gz` and not `.tar.gz`. Empty when there is none, and a leading dot does
not count (`.bashrc` has no extension).

### `stem(p: string): string`

The final component with its extension removed. `base(p) == stem(p) + ext(p)`,
always.

```bit
import { base, dir, ext, stem } from "std/path"

function isBitSource(p: string): bool {
  return ext(p) == ".bit"
}

// Same directory, same name, different extension.
function withExt(p: string, newExt: string): string {
  return dir(p) + "/" + stem(p) + newExt
}

function fileName(p: string): string {
  return base(p)
}
```
