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

### `contains(root: string, p: string): bool`

Whether `p` names a location inside (or equal to) `root`, after both are
lexically normalized with `clean`. Comparison is by whole path component, not
by raw character prefix, so `contains("/a/b", "/a/bc")` is `false` even though
the string `"/a/bc"` starts with `"/a/b"`. A path is always inside itself.

`root == "."` and `root == ""` both mean "the current directory" (`""` cleans
to `"."`, so an unset config field defaults to it). Every relative `p` that
does not climb above it with a leading `..` is inside — `contains(".", "a/b")`
is `true` — and an absolute `p` never is, since a relative root cannot contain
an absolute path.

This comparison is purely lexical — no filesystem access, so a `..` that only
exists on disk (a symlink planted inside `root`, pointing back outside it) is
not detected. `contains` alone is therefore not sufficient to decide whether
serving a path is safe when the tree is attacker-writable.
`examples/staticserver`'s `safePath` is the relevant contrast, and does a
different job on purpose: it is a reject-list run on the untrusted request
string itself, refusing any `..` substring outright, before the filesystem or
`contains` ever enters the picture. `contains` is a general post-`clean`
containment test; `safePath` is a narrower guard against untrusted input.
Neither supersedes the other.

```bit
import { contains } from "std/path"

fn isUnderSiteRoot(root: string, requested: string): bool {
  return contains(root, requested)
}

fn escapesRoot(root: string, requested: string): bool {
  return !contains(root, requested)
}
```
