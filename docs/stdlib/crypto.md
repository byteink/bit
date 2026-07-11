# std/crypto

The cryptography module: hashing, message authentication, key derivation,
authenticated encryption, public-key primitives, and cryptographically secure
randomness. Algorithms are built from scratch in Bit and written to be
constant-time (data-independent control flow and memory access); see each
section for the guarantees and the known-answer vectors behind them.

<!-- doctest: per-block -->

## Hashing

The cryptographic hash contract. `Hash` is the streaming interface every digest
in the library satisfies; concrete algorithms — SHA-256, SHA-512 — are separate
types that conform to it structurally, so code can hash against `Hash` without
naming a specific algorithm.

Because interfaces are structural, a type is a `Hash` simply by having the five
methods below. The example is a stand-in digest — it counts bytes rather than
hashing them — but a real one plugs in exactly the same way.

```bit
import { Hash, digest } from "std/crypto"

// A stand-in "digest": it remembers how many bytes it saw and returns a fixed
// 4-byte tag. A real SHA-256 satisfies `Hash` the same way — by its methods.
struct ByteCounter {
  seen: int
}

function (c: ByteCounter) write(data: []byte) {
  c.seen = c.seen + len(data)
}

function (c: ByteCounter) sum(): []byte {
  let out = []byte(4)
  out[0] = 1
  out[1] = 2
  out[2] = 3
  out[3] = 4
  return out
}

function (c: ByteCounter) reset() {
  c.seen = 0
}

function (c: ByteCounter) size(): int {
  return 4
}

function (c: ByteCounter) blockSize(): int {
  return 64
}

// Streaming: reset, feed bytes across as many `write`s as you like, read `sum`.
function streamed(c: ByteCounter): []byte {
  c.reset()
  c.write([]byte("ab"))
  c.write([]byte("c"))
  return c.sum()
}

// One-shot: `digest` does the reset / write / sum for a single buffer.
function oneShot(c: ByteCounter): []byte {
  return digest(c, []byte("abc"))
}
```

### `Hash`

The streaming hash contract, modelled on Go's `hash.Hash`:

```bit ignore
interface Hash {
  write(data: []byte)   // absorb more input
  sum(): []byte         // the digest of everything written since the last reset
  reset()               // return to the empty state
  size(): int           // digest length in bytes (e.g. 32 for SHA-256)
  blockSize(): int      // internal block size in bytes (HMAC needs it)
}
```

Feed input with any number of `write` calls, then read the digest with `sum`.
`reset` rewinds to the empty state so one value can hash many messages. `size` is
the digest length and `blockSize` the algorithm's internal block size — HMAC keys
that block, so it must be able to ask.

### `digest(h: Hash, data: []byte): []byte`

Hashes a single buffer: resets `h`, writes `data`, and returns `h.sum()`. A
convenience over the streaming methods for the common one-buffer case.

## Randomness

Cryptographically secure randomness, drawn from the operating system's CSPRNG.
Every value here traces back to `cryptoRandomBytes` (ABI.md §21) — the OS entropy
pool, never a userspace PRNG and never a weak or zero fallback. This module only
reshapes those raw bytes into convenient forms; it adds no randomness of its own,
so its output is exactly as strong as the OS source.

If the OS entropy source fails, a draw is fatal rather than degraded — a
silently weak key is worse than a crash.

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

## Hex encoding

Byte-slice <-> hex-string conversion. Each byte is two hex digits, high nibble
first, so `n` bytes become a `2n`-character string. Encoding never fails;
decoding does, on an odd length or a non-hex digit, so a malformed string is a
handled error rather than silent garbage.

```bit
import { encodeHex, encodeHexUpper, decodeHex } from "std/crypto"

// Lowercase hex, e.g. a hash or key rendered for logs.
function fingerprint(raw: []byte): string {
  return encodeHex(raw)
}

// Uppercase hex, for formats that expect it.
function shout(raw: []byte): string {
  return encodeHexUpper(raw)
}

// Parse hex back to bytes, handling a malformed string at the call site.
function parse(s: string): []byte {
  return decodeHex(s) catch e {
    println("bad hex: ${e.message()}")
    return []byte(0)
  }
}
```

### `encodeHex(b: []byte): string`

`b` rendered as lowercase hex (`0-9a-f`), high nibble first. An empty slice
yields `""`. Never fails.

### `encodeHexUpper(b: []byte): string`

Like `encodeHex`, but with uppercase digits (`0-9A-F`).

### `decodeHex(s: string): []byte!`

The bytes `s` spells in hex, high nibble first. Case-insensitive. Fails if `s`
has an odd length or contains any character outside `[0-9a-fA-F]`, so it is the
exact inverse of `encodeHex`/`encodeHexUpper` on well-formed input.

## SHA-3 and SHAKE

The FIPS 202 hash family, built on the Keccak-f[1600] sponge. Two shapes share
one permutation: the fixed-output hashes SHA3-224/256/384/512, which conform to
`Hash`, and the extendable-output functions SHAKE128/256, which absorb a message
and then squeeze an arbitrary number of output bytes. All are verified against
the NIST known-answer vectors.

The state is addressed as little-endian bytes, so output is byte-identical on
x86-64 and ARM64. Every value is fresh from its constructor — reuse one hash for
many messages by calling `reset` between them.

```bit
import { Hash, digest, encodeHex, newSha3_256, newShake128 } from "std/crypto"

// One-shot SHA3-256, rendered as a lowercase hex string.
function sha3Hex(data: []byte): string {
  return encodeHex(digest(newSha3_256(), data))
}

// Streaming: feed input across as many `write` calls as convenient, read `sum`.
function streamed(): []byte {
  let h = newSha3_256()
  h.write([]byte("Keccak "))
  h.write([]byte("sponge"))
  return h.sum()
}

// SHAKE128 as an XOF: absorb the seed once, then squeeze a 64-byte key stream.
function derive(seed: []byte): []byte {
  let x = newShake128()
  x.absorb(seed)
  return x.squeeze(64)
}

// Hashing against the `Hash` interface — the algorithm is a parameter.
function tag(h: Hash, msg: []byte): string {
  return encodeHex(digest(h, msg))
}
```

### `Sha3`

A fixed-output SHA-3 hash: a streaming Keccak sponge conforming to `Hash`. Build
one with a `newSha3_*` constructor; do not construct it by field.

### `Sha3.write(data: []byte)`

Absorbs more input into the running hash.

### `Sha3.sum(): []byte`

The digest of everything written since the last `reset`. Non-destructive — it
finalizes a copy, so the hash may keep accepting input afterward.

### `Sha3.reset()`

Returns the hash to the empty state, ready for a new message.

### `Sha3.size(): int`

The digest length in bytes (28, 32, 48, or 64).

### `Sha3.blockSize(): int`

The sponge rate in bytes — the algorithm's internal block size, which HMAC needs.

### `newSha3_224(): Sha3`

A SHA3-224 hash: 28-byte digest, 144-byte rate.

### `newSha3_256(): Sha3`

A SHA3-256 hash: 32-byte digest, 136-byte rate.

### `newSha3_384(): Sha3`

A SHA3-384 hash: 48-byte digest, 104-byte rate.

### `newSha3_512(): Sha3`

A SHA3-512 hash: 64-byte digest, 72-byte rate.

### `Shake`

A SHAKE extendable-output function (XOF): absorb a message, then squeeze any
number of output bytes. Build one with `newShake128`/`newShake256`.

### `Shake.absorb(data: []byte)`

Absorbs more input. Panics if called after squeezing has begun — the sponge has
already switched to producing output.

### `Shake.squeeze(n: int): []byte`

The next `n` output bytes of the stream. The first call closes absorption;
further calls continue where the last left off, so `squeeze(a)` then `squeeze(b)`
yields the same bytes as a single `squeeze(a + b)`. A non-positive `n` yields an
empty slice.

### `newShake128(): Shake`

A SHAKE128 XOF: 128-bit security strength, 168-byte rate.

### `newShake256(): Shake`

A SHAKE256 XOF: 256-bit security strength, 136-byte rate.
