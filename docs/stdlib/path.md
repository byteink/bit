# std/path

Lexical path handling. Nothing here touches the filesystem - `base("/no/such")`
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

fn configPath(home: string): string {
  return join(home, ".config/bit.toml")
}

fn resolve(base: string, p: string): string {
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

The extension of the final component, including the leading dot - the **last**
dot, so `.gz` and not `.tar.gz`. Empty when there is none, and a leading dot does
not count (`.bashrc` has no extension).

### `stem(p: string): string`

The final component with its extension removed. `base(p) == stem(p) + ext(p)`,
always.

```bit
import { base, dir, ext, stem } from "std/path"

fn isBitSource(p: string): bool {
  return ext(p) == ".bit"
}

// Same directory, same name, different extension.
fn withExt(p: string, newExt: string): string {
  return dir(p) + "/" + stem(p) + newExt
}

fn fileName(p: string): string {
  return base(p)
}
```

### `clean(p: string): string`

`p`, normalized: runs of `/` collapse to one, `.` elements are dropped, and
each inner `..` cancels the non-`..` element before it. A `..` that would
climb above a rooted path's `/` is dropped instead. The result never ends in
`/` unless it is the root, and an empty result becomes `"."`.

```bit
import { clean } from "std/path"

fn normalize(p: string): string {
  return clean(p)
}

fn sameLocation(a: string, b: string): bool {
  return clean(a) == clean(b)
}
```
