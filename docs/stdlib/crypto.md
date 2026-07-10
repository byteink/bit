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

## SHA-512 family

The 64-bit SHA-2 hashes from FIPS 180-4: SHA-512, SHA-384, and SHA-512/256. All
three share one compression function over a 128-byte block and differ only in
their initial value and how much of the final state they keep, so they cost the
same and behave identically through the `Hash` interface. Each constructor
returns a fresh `Hash`, so everything in the Hashing section applies: stream with
`write` then read with `sum`, or hash a single buffer with `digest`. `sum` is
non-destructive, so a value can be read and then written to further.

SHA-512/256 is not SHA-512 truncated to 32 bytes: it uses a distinct initial
value (FIPS 180-4 §5.3.6), which makes it a different function that happens to
share the engine. Prefer it over SHA-256 on 64-bit hardware, where it is faster.

```bit
import { digest, newSha512, newSha384, newSha512_256, encodeHex } from "std/crypto"

// One-shot: hash a whole buffer and render the digest as lowercase hex.
function sha512Hex(data: []byte): string {
  return encodeHex(digest(newSha512(), data))
}

// The shorter digests share the exact same call shape.
function sha384Hex(data: []byte): string {
  return encodeHex(digest(newSha384(), data))
}

function sha512_256Hex(data: []byte): string {
  return encodeHex(digest(newSha512_256(), data))
}

// Streaming: absorb a message across as many `write`s as you like, read once.
function fingerprint(head: []byte, tail: []byte): string {
  let h = newSha512()
  h.write(head)
  h.write(tail)
  return encodeHex(h.sum())
}
```

### `newSha512(): Hash`

A new SHA-512 hasher: a 64-byte (512-bit) digest computed over 128-byte blocks.
The strongest and, on 64-bit hardware, typically the fastest SHA-2 variant.

### `newSha384(): Hash`

A new SHA-384 hasher: a 48-byte (384-bit) digest, the SHA-512 engine with a
different initial value and the last two output words dropped. Its truncation
also makes it resistant to the length-extension attack that SHA-512 admits.

### `newSha512_256(): Hash`

A new SHA-512/256 hasher: a 32-byte (256-bit) digest from the SHA-512 engine
with the FIPS 180-4 §5.3.6 initial value. A drop-in 256-bit hash that is not
SHA-256 and, on 64-bit hardware, outruns it.
