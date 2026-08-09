# std/math

Floating-point maths on `f64`, plus the integer helpers that would otherwise be
written badly. Bit has no implicit numeric conversion, so an `int` argument must
be widened with `f64(x)` first.

<!-- doctest: per-block -->

## Constants

### `pi: f64`

The ratio of a circle's circumference to its diameter.

### `e: f64`

The base of the natural logarithm.

```bit
import { pi } from "std/math"

fn circleArea(r: f64): f64 {
  return pi * r * r
}
```

## Sign and magnitude

### `abs(x: f64): f64`

Magnitude of `x`: the sign bit cleared, IEEE 754-2019 §5.5.1. So `abs(-0.0)` is
`+0.0` exactly, and `1.0 / abs(-0.0)` is `inf`, not `-inf`. Note that
`abs(-0.0) == 0.0` is true either way — `-0.0 == 0.0` in IEEE 754 — so a test
that compares against zero cannot tell a correct result from a wrong one.

### `sign(x: f64): f64`

`-1.0`, `0.0`, or `1.0` as `x` is negative, zero, or positive.

### `min(a: f64, b: f64): f64`

The smaller of the two, matching Go's `math.Min`. If either argument is NaN,
the result is NaN. Of the two zeros, `-0.0` is smaller: `min(-0.0, 0.0)` and
`min(0.0, -0.0)` are both `-0.0` — note `1.0 / result` to see the sign, since
`-0.0 == 0.0` is true.

### `max(a: f64, b: f64): f64`

The larger of the two, matching Go's `math.Max`. If either argument is NaN,
the result is NaN. Of the two zeros, `+0.0` is larger: `max(-0.0, 0.0)` and
`max(0.0, -0.0)` are both `0.0` with the sign bit clear.

### `clamp(x: f64, lo: f64, hi: f64): f64`

`x` confined to `[lo, hi]`.

```bit
import { clamp, abs } from "std/math"

fn normalize(x: f64): f64 {
  return clamp(x, 0.0, 1.0)
}

fn closeEnough(a: f64, b: f64): bool {
  return abs(a - b) < 0.000001
}
```

## Rounding

Four ways to reach an integer value, differing only in direction.

### `trunc(x: f64): f64`

Toward zero.

### `floor(x: f64): f64`

Toward negative infinity.

### `ceil(x: f64): f64`

Toward positive infinity.

### `round(x: f64): f64`

To the nearest, halves away from zero.

```bit
import { floor, ceil, round, trunc } from "std/math"

fn directions(x: f64) {
  println("${trunc(x)} ${floor(x)} ${ceil(x)} ${round(x)}")
}
```

## Powers and logarithms

### `sqrt(x: f64): f64`

Square root. Negative input yields NaN.

### `pow(x: f64, y: f64): f64`

`x` raised to `y`.

### `log(x: f64): f64`

Natural logarithm.

### `log2(x: f64): f64`

Base-2 logarithm.

### `log10(x: f64): f64`

Base-10 logarithm.

### `atan2(y: f64, x: f64): f64`

The angle of the point `(x, y)` from the positive x-axis, in radians, using the
signs of both arguments to pick the quadrant. Note the argument order: `y` first.

```bit
import { sqrt, pow, log2, atan2 } from "std/math"

fn hypot(a: f64, b: f64): f64 {
  return sqrt(a * a + b * b)
}

fn bitsNeeded(n: f64): f64 {
  return log2(n)
}

fn angle(x: f64, y: f64): f64 {
  return atan2(y, x)
}

fn cube(x: f64): f64 {
  return pow(x, 3.0)
}
```

## Integers

Separate names because Bit does not overload: these take and return `int`, with
no rounding and no `f64` round-trip.

### `iabs(x: int): int`

Magnitude of `x`.

### `imin(a: int, b: int): int`

The smaller of the two.

### `imax(a: int, b: int): int`

The larger of the two.

### `ipow(base: int, exp: int): int`

`base` raised to `exp` by repeated squaring. `1` when `exp <= 0`.

### `gcd(a: int, b: int): int`

Greatest common divisor of `|a|` and `|b|`. `gcd(0, 0)` is `0`.

```bit
import { gcd, ipow, imax, iabs } from "std/math"

fn reduceFraction(n: int, d: int): int {
  return gcd(iabs(n), iabs(d))
}

fn kilobytes(n: int): int {
  return n * ipow(2, 10)
}

fn widest(xs: []int): int {
  let best = 0
  for x of xs {
    best = imax(best, x)
  }
  return best
}
```
