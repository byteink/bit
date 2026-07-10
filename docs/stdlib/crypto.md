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

## Base64

Base64 (RFC 4648) encodes arbitrary bytes as ASCII text, three input bytes per
four output characters. Two variants are provided: the *standard* alphabet
(`+`/`/`, `=`-padded) via `encode`/`decode`, and the *URL-safe* alphabet
(`-`/`_`, no padding) via `encodeUrl`/`decodeUrl` — safe to drop into a URL or a
filename. Each variant is self-inverse: `decode(encode(b))` and
`decodeUrl(encodeUrl(b))` return the original bytes. Decoding is validating: an
out-of-alphabet character or an impossible length is an error, not silent
garbage.

```bit
import { encode, decode, encodeUrl, decodeUrl } from "std/crypto"

// Standard base64 with '=' padding — round-trips any bytes.
function roundTrip(data: []byte): []byte! {
  return decode(encode(data))?
}

// URL-safe alphabet (-/_), no padding — for URLs, query strings, and filenames.
function tokenize(data: []byte): string {
  return encodeUrl(data)
}

function detokenize(token: string): []byte! {
  return decodeUrl(token)?
}
```

### `encode(b: []byte): string`

Encodes `b` with the standard alphabet and `=` padding. The result length is
always a multiple of 4; empty input yields the empty string.

### `decode(s: string): []byte!`

Decodes a standard, `=`-padded base64 string. Fails on a character outside the
standard alphabet or a length that is not a multiple of 4.

### `encodeUrl(b: []byte): string`

Encodes `b` with the URL-safe alphabet (`-` and `_`) and no padding, so the
result is safe inside a URL path, query, or filename.

### `decodeUrl(s: string): []byte!`

Decodes an unpadded URL-safe base64 string. Fails on a character outside the
URL-safe alphabet — an `=` included, since URL-safe output is never padded — or a
length that no valid encoding can produce.
