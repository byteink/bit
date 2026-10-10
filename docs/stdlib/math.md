# std/math

Floating-point maths on `f64`, the bit-level view of `f32` and `f64`, plus the
integer helpers that would otherwise be written badly. Bit has no implicit numeric conversion, so an `int` argument must
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

Magnitude of `x`: the sign bit cleared. So `abs(-0.0)` is `+0.0` exactly, and
`1.0 / abs(-0.0)` is `inf`, not `-inf`. Note that `abs(-0.0) == 0.0` is true
either way - `-0.0 == 0.0` in IEEE 754 floating point - so a test that
compares against zero cannot tell a correct result from a wrong one.

### `sign(x: f64): f64`

`-1.0`, `0.0`, or `1.0` as `x` is negative, zero, or positive.

### `min(a: f64, b: f64): f64`

The smaller of the two, matching Go's `math.Min`. If either argument is NaN,
the result is NaN. Of the two zeros, `-0.0` is smaller: `min(-0.0, 0.0)` and
`min(0.0, -0.0)` are both `-0.0` - note `1.0 / result` to see the sign, since
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

## Bit patterns

A float's IEEE 754 encoding as an unsigned integer, and back. Nothing is
converted: the bits move verbatim, so `-0.0` keeps its sign and a NaN keeps its
payload, which `==` cannot see and a bit pattern can. Each call is one register
move (`fmov` on arm64, `movq`/`movd` on x86-64). Go spells these
`Float64bits`, `Float64frombits`, `Float32bits` and `Float32frombits`.

### `f64Bits(x: f64): u64`

The binary64 pattern of `x`: sign in bit 63, exponent in bits 62 to 52,
fraction in bits 51 to 0.

### `f64FromBits(b: u64): f64`

The `f64` with bit pattern `b`; the inverse of `f64Bits`.

### `f32Bits(x: f32): u32`

The binary32 pattern of `x`: sign in bit 31, exponent in bits 30 to 23,
fraction in bits 22 to 0.

### `f32FromBits(b: u32): f32`

The `f32` with bit pattern `b`; the inverse of `f32Bits`.

```bit
import { f64Bits } from "std/math"

fn isNegative(x: f64): bool {
  return (f64Bits(x) >> u64(63)) == u64(1)
}

fn isNegativeZero(x: f64): bool {
  return f64Bits(x) == u64(0x8000000000000000)
}

fn sameBits(a: f64, b: f64): bool {
  return f64Bits(a) == f64Bits(b)
}
```

### `f32sToLe(xs: []f32): []u8`

`xs` as little-endian binary32, four bytes per float, in order. This is the
float32 wire form of a vector: a Redis `FP32` blob, a tensor file, a network
message.

### `f32sFromLe(b: []u8): []f32!`

The floats in little-endian binary32 bytes `b`; the inverse of `f32sToLe`,
bit for bit. A length that is not a multiple of four is an error, since the
tail would be half a float.

```bit
import { f32sToLe, f32sFromLe } from "std/math"

fn roundTrip(xs: []f32): []f32! {
  return f32sFromLe(f32sToLe(xs))
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

### `mul64(a: u64, b: u64): (u64, u64)`

The full 128-bit product as `(hi, lo)`: `a * b == hi * 2^64 + lo` exactly,
where the plain `a * b` operator keeps only `lo`. It compiles inline to one
high-multiply instruction plus the ordinary multiply, with no call and no
allocation, and its time does not depend on the operands, so it is safe in
constant-time code.

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

`mul64` is what a 64-bit hash mix or a multi-word integer needs: the bits the
plain product throws away.

```bit
import { mul64 } from "std/math"

fn mix(a: u64, b: u64): u64 {
  let (hi, lo) = mul64(a, b)
  return hi ^ lo
}
```
