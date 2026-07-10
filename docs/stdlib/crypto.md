# std/crypto

Cryptographically secure randomness, drawn from the operating system's CSPRNG.
Every value here traces back to `cryptoRandomBytes` (ABI.md §21) — the OS entropy
pool, never a userspace PRNG and never a weak or zero fallback. This module only
reshapes those raw bytes into convenient forms; it adds no randomness of its own,
so its output is exactly as strong as the OS source.

If the OS entropy source fails, a draw is fatal rather than degraded — a
silently weak key is worse than a crash.

<!-- doctest: per-block -->

## Random bytes

### `randomBytes(n: int): []byte`

`n` secure random bytes, as a fresh mutable slice the caller owns. A non-positive
`n` yields an empty slice.

### `fillRandom(buf: []byte)`

Overwrite every byte of `buf` in place with secure random bytes; its length is
unchanged. Use it to re-key an existing buffer without allocating a new one.

```bit
import { randomBytes, fillRandom } from "std/crypto"

function token(): []byte {
  return randomBytes(16)
}

function rekey(key: []byte) {
  fillRandom(key)
}
```

## Random integers

### `randomU64(): uint`

A uniformly random 64-bit value, packed from 8 secure random bytes. Every bit is
independent and uniform.

### `randomUintBelow(n: uint): uint`

A uniformly random value in `[0, n)`, free of modulo bias. `n` must be greater
than zero.

A plain `randomU64() % n` over-represents the low residues whenever `n` does not
divide 2^64. This rejects and redraws the draws that would cause that skew — the
top `2^64 mod n` values — so every residue is equally likely.

```bit
import { randomU64, randomUintBelow } from "std/crypto"

function nonce(): uint {
  return randomU64()
}

function rollDie(): uint {
  return randomUintBelow(6) + 1
}
```
