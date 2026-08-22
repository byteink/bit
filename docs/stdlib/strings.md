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

### `padLeft(s: string, width: int): string`

`s` left-padded with `U+0020` spaces until it is `width` **runes** — measured
with `runeCount`, never `len` — so a multi-byte rune like `é` still counts as
one column. Returns `s` unchanged, never truncated, when it is already
`width` runes or longer or when `width` is `0` or less.

### `padRight(s: string, width: int): string`

`s` right-padded with `U+0020` spaces until it is `width` runes, by the same
rules as `padLeft`.

### `padStart(s: string, width: int, pad: string): string`

`s` left-padded with `pad`, repeated cyclically by code point (measured with
`runeCount`, never `len`) until it is `width` runes long — matches JS's
`String.prototype.padStart`, generalised from UTF-16 units to code points. If
`s` is already `width` runes or longer, `width` is `0` or less, or `pad` is
empty, returns `s` unchanged; this never truncates `s`. A multi-rune `pad`
that does not divide the needed width evenly is cut short on its last cycle
rather than repeated whole. Distinct from `padLeft`, which only ever pads
with a single space.

### `padEnd(s: string, width: int, pad: string): string`

`s` right-padded with `pad`. Same rules as `padStart`, on the other end.
Matches JS's `String.prototype.padEnd`. Distinct from `padRight`, which only
ever pads with a single space.

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

### `indexOfFrom(s: string, sub: string, at: i64): i64`

Like `indexOf`, but the search starts at byte offset `at`. A negative `at`
clamps to `0` rather than reading out of bounds. An `at` beyond `len(s)`
finds nothing, even for an empty `sub` — but an empty `sub` at exactly
`len(s)` does match, returning `at`.

### `lastIndexOf(s: string, sub: string): i64`

The **byte** offset of the *last* `sub` in `s`, or `-1`. An empty `sub`
matches at `len(s)`. An overlapping candidate reports the rightmost start
position — `lastIndexOf("aaa", "aa")` is `1`, not `0` — since the scan never
skips past a candidate the way `count`'s non-overlapping scan does.

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

### `splitN(s: string, sep: string, n: i64): []string`

`s` split on `sep`, keeping at most `n` parts: the first `n - 1` parts are
split as `split` would, and the last part keeps everything remaining,
unsplit — so a limit larger than the number of matches behaves exactly like
`split`. `n == 0` yields no parts at all (an empty slice, not `[s]`); `n < 0`
is unlimited, identical to `split`. An empty `sep` yields `[s]` for any
`n != 0`, same convention as `split`.

### `trimLeft(s: string, cutset: string): string`

`s` with every leading byte that appears in `cutset` removed. Byte-level
membership: a multi-byte rune in `cutset` matches only its individual
encoded bytes, not the character as a whole. An empty `cutset` matches
nothing, so `s` is returned unchanged.

### `trimRight(s: string, cutset: string): string`

`s` with every trailing byte that appears in `cutset` removed. Same
byte-level cutset membership as `trimLeft`.

### `trim(s: string, cutset: string): string`

`s` trimmed on both ends against `cutset` — equivalent to
`trimRight(trimLeft(s, cutset), cutset)`.

### `trimSpace(s: string): string`

`s` with leading and trailing ASCII whitespace removed: space, tab, newline,
vertical tab, form feed, and carriage return.

### `replace(s: string, old: string, repl: string): string`

`s` with every non-overlapping occurrence of `old` replaced by `repl`,
scanned left to right. An empty `old` is a no-op, returning `s` unchanged —
unlike Go's `strings.ReplaceAll`, which instead inserts `repl` at every
position including both ends.

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

A named `import { parseFloat }` warns with `E0048`, since `parseFloat` is also
a predeclared identifier (SPEC §5.3); use the namespace form to avoid it.

```bit
import * as strings from "std/strings"

// Parse a money column, rejecting anything that is not a real number.
fn parseAmount(field: string): f64! {
  return strings.parseFloat(strings.trimSpace(field))?
}
```

## Formatting

### `formatFloat(x: f64, decimals: int): string`

`x` rendered to exactly `decimals` digits after the point, rounding half away
from zero with carry (`formatFloat(9.999, 2)` is `"10.00"`). `decimals < 0` is
treated as `0`, which omits the point entirely (`formatFloat(2.5, 0)` is
`"3"`). The sign always comes from `x`, even when the rounded digits are all
zero (`formatFloat(-0.004, 2)` is `"-0.00"`). `NaN` is `"NaN"`; the infinities
are `"+Inf"` / `"-Inf"`. Never uses exponent notation.

Works on the decimal text of `x`, not `x` scaled by a power of ten — scaling
with binary floating-point loses digits (`i64(150.15 * 100.0)` is `15014`,
not `15015`).

```bit
import { formatFloat } from "std/strings"

fn priceLabel(cents: f64): string {
  return "$" + formatFloat(cents, 2)
}
```

### `groupDigits(s: string, sep: string): string`

Inserts `sep` between groups of three digits in the integer part of `s`
(the text before the first `.`, or the whole string when there is none),
counted from the right: `groupDigits("1234567", ",")` is `"1,234,567"`.
Text at and after the `.` is copied unchanged.

A leading `-` or `+` sign is kept out of the grouping
(`groupDigits("-1234.50", ",")` is `"-1,234.50"`). An integer part of three
digits or fewer, an empty `s`, or an empty `sep` is returned unchanged. If
any character of the integer part after the sign is not an ASCII digit, `s`
is returned unchanged rather than grouping a guess at digit boundaries.

```bit
import { formatFloat, groupDigits } from "std/strings"

fn moneyLabel(cents: f64): string {
  return "$" + groupDigits(formatFloat(cents, 2), ",")
}
```
