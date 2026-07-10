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

## Constant-time

Branchless, data-independent building blocks for constant-time code — tag
comparison, secret-dependent selection, and wiping key material. Each is written
so its control flow and memory access depend only on public values (slice
lengths), never on secret contents.

Policy for v1: the library is written to be constant-time *by construction* —
no primitive here branches on, or indexes memory by, a secret. The compiler does
**not** machine-verify constant-timeness; it is a property of how this code is
written, not a guarantee the toolchain enforces. And these are software
implementations: they defend against data-dependent branches and lookups, but
**not** against hardware micro-architectural side channels (cache, speculation,
port contention, data-dependent instruction timing). Defeating those needs
constant-time hardware primitives — a later hardware-acceleration track, out of
scope here.

Because Bit is Go-like it has no `bool`->`int` conversion, so — like Go's own
`crypto/subtle` — the selector for `ctSelect` is an `int` in `{0, 1}` (the 0/1
result of a prior constant-time comparison), not a `bool`.

```bit
import { ctEq, ctSelect, secureZero } from "std/crypto"

// Verify a MAC tag in constant time — no early exit reveals where a forgery
// first diverges — then wipe the key so it can't linger in memory.
function checkTag(key: []byte, want: []byte, got: []byte): bool {
  let ok = ctEq(want, got)
  secureZero(key)
  return ok
}

// Pick `hi` when `v` is 1 and `lo` when `v` is 0, with no branch on `v`.
function pick(v: int, hi: int, lo: int): int {
  return ctSelect(v, hi, lo)
}
```

### `ctEq(a: []byte, b: []byte): bool`

Constant-time byte-slice equality, for comparing MACs and hash digests. Unlike
`a == b`, which can stop at the first differing byte and so leak *where* two tags
diverge, this always scans the full length before deciding. The one
length-dependent branch is the fast `len(a) != len(b)` reject — slice lengths are
public, not secret — after which it OR-accumulates every `a[i] ^ b[i]` and
returns whether that accumulator is still zero.

### `ctSelect(v: int, a: int, b: int): int`

Constant-time select: returns `a` when `v` is 1 and `b` when `v` is 0, with no
branch on `v`. `v` must be exactly 0 or 1 — pass the 0/1 result of a prior
constant-time comparison. Internally `0 - v` is an all-ones mask for `v == 1` and
an all-zeros mask for `v == 0`; `a` survives through the mask, `b` through its
complement, and the two are ORed, so the choice never becomes a branch.

### `secureZero(b: []byte)`

Wipe every byte of `b` to zero through the runtime's un-elidable barrier
(ABI.md §21), so a dead-store optimizer cannot drop the clear. Use it to destroy
key material, plaintext, or intermediate secrets the moment they are no longer
needed; `b`'s length is unchanged.
## SHA-2

The SHA-2 32-bit digests, SHA-256 and SHA-224 (FIPS 180-4). Both share one
64-round compression over 32-bit words and differ only in their initial state and
output length: SHA-256 is 32 bytes, SHA-224 is 28. Each is a `Hash` (structurally,
§14.3), so it streams — feed bytes with any number of `write` calls, then read the
digest with `sum` — and slots into anything written against `Hash`, including HMAC
and `digest`.

`sum` finalizes on a copy of the running state, so it neither consumes the hasher
nor blocks further writes; `reset` rewinds to the empty message. Outputs are
verified against the FIPS 180-4 known-answer vectors (e.g. SHA-256 of `"abc"` is
`ba7816bf…f20015ad`).

```bit
import { newSha256, newSha224, digest, encodeHex } from "std/crypto"

// One-shot SHA-256 of a string, rendered as lowercase hex.
function sha256Hex(s: string): string {
  return encodeHex(digest(newSha256(), []byte(s)))
}

// One-shot SHA-224, rendered as hex.
function sha224Hex(s: string): string {
  return encodeHex(digest(newSha224(), []byte(s)))
}

// Streaming: write the message in parts, then read the digest. `size` and
// `blockSize` report 32 and 64 for SHA-256; `reset` rewinds for reuse.
function streamed(): []byte {
  let h = newSha256()
  h.write([]byte("abc"))
  h.write([]byte("def"))
  let d = h.sum()
  h.reset()
  return d
}
```

### `Sha256`

The streaming state for both SHA-256 and SHA-224. Build one with `newSha256` or
`newSha224` rather than a literal — the constructors install the correct initial
state and round constants. It satisfies `Hash`, so it carries the five streaming
methods below.

### `newSha256(): Sha256`

A fresh SHA-256 hasher over the empty message. Its `size` is 32.

### `newSha224(): Sha256`

A fresh SHA-224 hasher over the empty message. Its `size` is 28. SHA-224 is
SHA-256 with a different initial state, truncated to the first 28 output bytes.

### `Sha256.write(data: []byte)`

Absorb `data`, buffering internally into 64-byte blocks. Call it as many times as
you like; the digest is of everything written since the last `reset`.

### `Sha256.sum(): []byte`

The digest of everything written so far — 32 bytes for SHA-256, 28 for SHA-224.
Finalizes on a copy of the state, so it is non-destructive: you may call it
repeatedly and keep writing afterward.

### `Sha256.reset()`

Rewind to the empty message, restoring the variant's initial state and dropping
any buffered bytes, so one value can hash many messages.

### `Sha256.size(): int`

The digest length in bytes: 32 for SHA-256, 28 for SHA-224.

### `Sha256.blockSize(): int`

The internal block size in bytes — 64 for both variants. HMAC keys this block.
