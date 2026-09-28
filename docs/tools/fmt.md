# Format

<!-- doctest: per-block -->

Bit has one canonical layout, and `bit fmt` writes it. There is no
configuration file and no house-style debate to have - a file either
matches the one layout or `bit fmt` rewrites it until it does.

## Running it

```
bit fmt [--check] <path>...
```

`<path>` may be one or more files or directories; a directory is walked
recursively for `.bit` files.

```bit
fn main() {
  println("hello")
}
```

```
$ bit fmt hello.bit
```

A file already in canonical form is left untouched - `bit fmt` only rewrites
a file when the canonical text actually differs from what's on disk, so
running it twice in a row never produces a second diff.

## `--check`

```
bit fmt --check <path>...
```

Writes nothing. Instead it names every file that is not already canonical
and exits nonzero if any were found - the shape a pre-commit hook or a CI
step wants: fail loudly, never silently rewrite someone's working tree.

```
$ bit fmt --check .
src/legacy.bit: not canonically formatted
```

## Sharp edges

- A file that fails to parse is left untouched, and its errors go to
  stderr; `bit fmt` cannot reformat code it cannot read.
- `bit fmt` wraps long bracketed lists (an argument list, an array or map
  literal) at 100 columns on its own - there is no line-width setting to
  reach for.

## Where next

[Lint](lint.md) covers the other kind of source-level feedback: not "does
it look right" but "is it healthy" - dead code, oversized functions, a
handful of Bit-specific footguns the type checker cannot catch.
