# std/rand

A fast, seedable pseudo-random generator for ordinary application code:
picking an index, choosing a shard, shuffling a slice, jittering a retry
delay. This is the missing half of a deliberate split - `std/crypto`'s
`randomBytes` / `fillRandom` are a CSPRNG with no seed, so nothing built on
them can ever replay a sequence.

**This generator is NOT cryptographically secure.** Never use it for keys,
tokens, nonces, session ids, passwords, or anything else where an attacker
predicting the next value would matter. Its entire value - a seed you can
print and replay - is the opposite of what a security-sensitive draw needs.
For that, use [`std/crypto`](crypto.md)'s `randomBytes`, `fillRandom`, or
`randomUintBelow`. This split, and the reason for it, is copied directly from
Go's `math/rand` (this module) versus `crypto/rand` (`std/crypto`): the two
must be hard to confuse, which is why this lives in its own module rather
than a "fast mode" inside `std/crypto`.

The algorithm is SplitMix64 (Steele, Lea & Flood, 2014). Two `Rand`s built
from the same seed produce a byte-identical sequence from every method
below, forever - the property that makes a failing randomized test
reproducible: print the seed on failure, replay with `newRand(thatSeed)`.

<!-- doctest: per-block -->

## The generator

### `Rand`

A seedable, non-cryptographic pseudo-random generator. See the warning
above: never use this for anything security-sensitive.

### `newRand(seed: uint): Rand`

A generator seeded with `seed`. Two `Rand`s built from the same seed produce
an identical sequence from every method below.

```bit
import { newRand } from "std/rand"

fn reproducibleRoll(seed: uint): int {
  let r = newRand(seed)
  return r.intn(6) + 1
}
```

### `Rand.uint64(): uint`

The next raw draw, uniform over the full `uint` range. Most callers want
`intn`, `int64`, `f64`, or `shuffle` instead.

### `Rand.intn(n: int): int`

A uniformly random value in `[0, n)`, free of modulo bias via rejection
sampling. Panics if `n` is not positive.

```bit
import { newRand, Rand } from "std/rand"

fn pickIndex(r: Rand, len: int): int {
  return r.intn(len)
}
```

### `Rand.int64(): int`

A uniformly random value over the full `i64` range, positive or negative - a
raw draw reinterpreted as signed. Use `intn` instead when you want a bounded
range.

### `Rand.f64(): f64`

A uniformly random value in `[0.0, 1.0)`, built from the top 53 bits of a
draw so every representable outcome is equally likely.

```bit
import { newRand, Rand } from "std/rand"

// Jittered backoff: a randomized delay so retrying clients don't all retry
// at once (the classic anti-thundering-herd measure).
fn jitteredBackoffMs(r: Rand, baseMs: int): int {
  return baseMs + int(r.f64() * f64(baseMs))
}
```

### `Rand.shuffle(xs: []T)`

Shuffles `xs` in place with Fisher-Yates: uniformly random among all
`len(xs)!` orderings, O(n) draws, no extra allocation.

```bit
import { newRand, Rand } from "std/rand"

fn shuffledCopy(r: Rand, xs: []int): []int {
  let out = []int(len(xs))
  let i = 0
  while (i < len(xs)) {
    out[i] = xs[i]
    i = i + 1
  }
  r.shuffle(out)
  return out
}
```

### `Rand.perm(n: int): []int`

A random permutation of `[0, n)` as a fresh slice. Panics if `n` is
negative; `n == 0` yields an empty slice.

## Package-level convenience

One shared generator, lazily seeded from `std/crypto`'s OS entropy, for
quick one-off use with no `Rand` to manage. It shares one unsynchronized
state across every caller in the process - **not** safe to call from more
than one worker thread at a time. A program drawing from multiple workers
concurrently must give each worker its own `newRand(seed)`.

### `intn(n: int): int`

Same as `Rand.intn`, from the shared generator.

### `int64(): int`

Same as `Rand.int64`, from the shared generator.

### `float64(): f64`

Same as `Rand.f64`, from the shared generator. Named `float64`, not `f64`:
a bare package-level function named after a builtin conversion (`f64(x)`)
would shadow it throughout the module.

```bit
import { intn, float64 } from "std/rand"

fn quickDieRoll(): int {
  return intn(6) + 1
}

fn quickFraction(): f64 {
  return float64()
}
```

### `shuffle(xs: []T)`

Same as `Rand.shuffle`, from the shared generator.

### `perm(n: int): []int`

Same as `Rand.perm`, from the shared generator.
