# std/strings

A Bit `string` is immutable UTF-8 bytes. `len(s)` counts **bytes**; indexing
`s[i]` yields the byte at `i`. The rune functions here decode the code points.

```bit ignore
import { toUpper, runeCount } from "std/strings"
```

<!-- doctest: per-block -->

## Building strings

Concatenating in a loop copies the whole string every time, which turns an
`O(n)` job into `O(n²)`. A `Builder` appends into one buffer instead.

### `Builder`

An append-only string buffer. A struct, so it is a reference type: its methods
mutate it in place, and they also return it so calls can chain.

### `newBuilder(): Builder`

An empty `Builder`.

### `Builder.write(s: string): Builder`

Appends `s`. Returns the same builder.

### `Builder.writeByte(c: u8): Builder`

Appends the single byte `c` — not a rune. Returns the same builder.

### `Builder.toString(): string`

The accumulated string. The builder stays usable.

### `Builder.length(): i64`

Bytes accumulated so far.

```bit
import { newBuilder } from "std/strings"

function csv(xs: []string): string {
  let b = newBuilder()
  let first = true
  for x of xs {
    if (!first) {
      b.writeByte(',')
    }
    b.write(x)
    first = false
  }
  return b.toString()
}
```

## Runes (UTF-8 code points)

### `runeCount(s: string): int`

Code points in `s`. Differs from `len(s)` for any non-ASCII text.

### `runeAt(s: string, i: int): rune`

The `i`-th code point, counting code points, not bytes.

### `runes(s: string): []rune`

Every code point, in order.

### `runeSize(b: int): int`

How many bytes a UTF-8 sequence starting with lead byte `b` occupies: 1 to 4, or
1 for an invalid lead byte so a decoder always advances.

```bit
import { runeCount, runeAt, runes } from "std/strings"

function describe(s: string) {
  println("${len(s)} bytes, ${runeCount(s)} runes")
  if (runeCount(s) > 0) {
    println("first rune is ${runeAt(s, 0)}")
  }
  println("decoded ${len(runes(s))}")
}
```

## Comparing

### `equal(a: string, b: string): bool`

Whether `a` and `b` are the same bytes. Same as `a == b`; provided so it can be
passed as a function value.

### `compare(a: string, b: string): i64`

Negative, zero, or positive as `a` sorts before, with, or after `b`. Byte order,
so it is code-point order for valid UTF-8.

### `hasPrefix(s: string, prefix: string): bool`

Whether `s` begins with `prefix`. An empty prefix is always present.

### `hasSuffix(s: string, suffix: string): bool`

Whether `s` ends with `suffix`.

## Searching

### `indexOf(s: string, sub: string): i64`

The **byte** offset of the first `sub` in `s`, or `-1`. An empty `sub` is at `0`.

### `contains(s: string, sub: string): bool`

Whether `sub` occurs in `s`.

### `count(s: string, sub: string): i64`

Non-overlapping occurrences of `sub` in `s`.

```bit
import { hasPrefix, indexOf, count } from "std/strings"

function scheme(url: string): string {
  if (!hasPrefix(url, "https://")) {
    return "other"
  }
  return "https"
}

function commas(line: string): i64 {
  return count(line, ",")
}

function firstSpace(s: string): i64 {
  return indexOf(s, " ")
}
```

## Transforming

### `repeat(s: string, n: i64): string`

`s` concatenated `n` times. Empty when `n <= 0`.

### `join(parts: []string, sep: string): string`

`parts` joined with `sep` between each pair. This is also the way to render a
`[]string`, which string interpolation cannot do.

### `toUpper(s: string): string`

ASCII letters uppercased. Bytes outside `a`–`z` are untouched.

### `toLower(s: string): string`

ASCII letters lowercased.

```bit
import { join, repeat, toUpper } from "std/strings"

function banner(title: string): string {
  return toUpper(title) + "\n" + repeat("-", len(title))
}

function render(names: []string): string {
  return join(names, ", ")
}
```
