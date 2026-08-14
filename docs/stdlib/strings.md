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

Appends the single byte `c` - not a rune. Returns the same builder.

### `Builder.toString(): string`

The accumulated string. The builder stays usable.

### `Builder.length(): i64`

Bytes accumulated so far.

```bit
import { newBuilder } from "std/strings"

fn csv(xs: []string): string {
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

`runeCount` and `runes` count and decode by code point; `runeAt` takes a
**byte offset** into `s`, not a code-point index.

### `runeCount(s: string): int`

Code points in `s`. Differs from `len(s)` for any non-ASCII text.

### `runeAt(s: string, i: int): rune`

The code point starting at byte offset `i`, which must land on a rune
boundary. Malformed or out-of-range input decodes as U+FFFD rather than
panicking. Not indexed by rune count — to visit each rune in order, use
`runes` or `runeCount`.

### `runes(s: string): []rune`

Every code point, in order.

### `runeSize(b: int): int`

How many bytes a UTF-8 sequence starting with lead byte `b` occupies: 1 to 4, or
1 for an invalid lead byte so a decoder always advances.

```bit
import { runeCount, runeAt, runes } from "std/strings"

fn describe(s: string) {
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

### `equalFold(a: string, b: string): bool`

Whether `a` and `b` are equal under ASCII case folding (`A`-`Z` treated as
`a`-`z`). Bytes outside ASCII compare exactly, unfolded — this is not full
Unicode case folding, so `equalFold("ÉCOLE", "école")` is `false`.

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

fn scheme(url: string): string {
  if (!hasPrefix(url, "https://")) {
    return "other"
  }
  return "https"
}

fn commas(line: string): i64 {
  return count(line, ",")
}

fn firstSpace(s: string): i64 {
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

### `split(s: string, sep: string): []string`

`s` split on every occurrence of `sep`, in order. Adjacent or edge separators
yield empty parts (`split("a,,b,", ",")` is `["a", "", "b", ""]`); an empty `sep`
yields `[s]`. The inverse of `join`.

### `trimSpace(s: string): string`

`s` with leading and trailing ASCII spaces and tabs removed.

### `parseInt(s: string): int!`

The signed decimal integer `s` denotes. Fails on an empty string, a bare sign, a
non-digit, or a value outside the `int` range - it never silently wraps. Accepts
the most negative `int`, `-9223372036854775808`.

```bit
import { join, repeat, toUpper, split, trimSpace, parseInt } from "std/strings"

fn banner(title: string): string {
  return toUpper(title) + "\n" + repeat("-", len(title))
}

fn render(names: []string): string {
  return join(names, ", ")
}

// Sum a comma-separated list of integers, ignoring surrounding spaces.
fn sumCsv(line: string): int! {
  let total = 0
  for field of split(line, ",") {
    total = total + parseInt(trimSpace(field))?
  }
  return total
}
```

### `parseFloat(s: string): f64!`

The `f64` decimal or hexadecimal float text `s` denotes, correctly rounded.
Fails on an empty string, a bare sign, leading or trailing whitespace, and any
text the predeclared `parseFloat` builtin (SPEC §5.3) cannot parse — a bad
parse never returns a valid-looking float. `parseFloat("0")` succeeds with
value `0`, distinguishable from every failure.

`1e400` and `1e-400` still succeed, rounding to `+Inf` / `0` under IEEE 754 —
overflow and underflow are correctly-rounded conversion results, not parse
failures.

```bit
import { parseFloat } from "std/strings"

// Parse a money column, rejecting anything that is not a real number.
fn parseAmount(field: string): f64! {
  return parseFloat(trimSpace(field))
}
```
