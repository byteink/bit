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
## SHA-1 (legacy)

SHA-1 (FIPS 180-1) produces a 160-bit (20-byte) digest. It is provided for
**interoperability only**: SHA-1 is **not** collision-resistant — practical
collisions have existed since 2017 (SHAttered) — so it must **never** back a new
signature, certificate, MAC, or any new security decision. Use it solely to
speak formats that still mandate it: UUIDv5 (RFC 4122) and the fingerprints of
pre-existing X.509 certificates. For anything new, use SHA-256.

The hasher satisfies the streaming `Hash` interface, so it works one-shot
through `digest` or incrementally through `write`/`sum`.

```bit
import { newSha1, digest, encodeHex } from "std/crypto"

// One-shot: the lowercase hex fingerprint of a buffer. Legacy interop only —
// e.g. a UUIDv5 namespace hash or an old certificate fingerprint, never a new
// signature.
function sha1Hex(data: []byte): string {
  return encodeHex(digest(newSha1(), data))
}

// Streaming: reset, feed the bytes across as many writes as you like, then read
// the 20-byte digest with `sum`.
function sha1Stream(head: []byte, tail: []byte): []byte {
  let h = newSha1()
  h.reset()
  h.write(head)
  h.write(tail)
  return h.sum()
}
```

### `newSha1(): Hash`

A fresh SHA-1 hasher in the empty state, typed as the streaming `Hash` interface
— digest size 20 bytes, block size 64. Legacy: interop only, not
collision-resistant; never use it for new signatures or MACs.

## MD5 (legacy)

MD5 (RFC 1321) produces a 128-bit (16-byte) digest. It is **broken** and provided
for **interoperability only**: collisions are trivial to produce (seconds on a
laptop) and chosen-prefix collisions have forged real CA certificates. It must
**never** back integrity checks, signatures, MACs, password hashing, or any
security decision. Use it solely to read or reproduce legacy formats that still
mandate it — old checksums, ETags, and pre-existing protocol fields. For anything
new, use SHA-256.

MD5 is little-endian throughout (message words and the length pad), unlike the
big-endian SHA family. The hasher satisfies the streaming `Hash` interface, so it
works one-shot through `digest` or incrementally through `write`/`sum`.

```bit
import { newMd5, digest, encodeHex } from "std/crypto"

// One-shot: the lowercase hex digest of a buffer. Legacy interop only — e.g.
// reproducing an old checksum or ETag, never an integrity check or signature.
function md5Hex(data: []byte): string {
  return encodeHex(digest(newMd5(), data))
}

// Streaming: reset, feed the bytes across as many writes as you like, then read
// the 16-byte digest with `sum`.
function md5Stream(head: []byte, tail: []byte): []byte {
  let h = newMd5()
  h.reset()
  h.write(head)
  h.write(tail)
  return h.sum()
}
```

### `newMd5(): Hash`

A fresh MD5 hasher in the empty state, typed as the streaming `Hash` interface —
digest size 16 bytes, block size 64. Broken: interop only, not
collision-resistant; never use it for integrity, signatures, or MACs.

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

## ChaCha20

The ChaCha20 stream cipher (RFC 8439) and its HChaCha20 key-derivation core
(draft-irtf-cfrg-xchacha §2.2). ChaCha20 turns a 256-bit key, a 96-bit nonce, and
a 32-bit block counter into a keystream that is XORed with the data. Because XOR is
its own inverse, one function both encrypts and decrypts: run it again over the
ciphertext with the same key, nonce, and counter to recover the plaintext.

Both are constant-time by construction — every loop bound is a public length and no
branch or memory access depends on a key or plaintext byte. Outputs are verified
against the RFC 8439 known-answer vectors (the §2.3.2 keystream block and the
§2.4.2 "Ladies and Gentlemen" ciphertext) and the XChaCha draft's §2.2.1 HChaCha20
subkey.

A (key, nonce) pair must never repeat: ChaCha20 is a stream cipher, so reusing one
XORs two plaintexts under the same keystream and leaks their difference. HChaCha20
is not a cipher on its own — it is the step XChaCha20 uses to stretch a longer
random nonce into a fresh ChaCha20 key.

```bit
import { chacha20, hchacha20 } from "std/crypto"

// Encrypt under a 32-byte key and 12-byte nonce, starting at block counter 1.
function seal(key: []byte, nonce: []byte, plaintext: []byte): []byte {
  return chacha20(key, nonce, 1, plaintext)
}

// Decrypt: the identical call — XOR with the keystream is its own inverse.
function unseal(key: []byte, nonce: []byte, ciphertext: []byte): []byte {
  return chacha20(key, nonce, 1, ciphertext)
}

// Derive a 32-byte subkey from a 32-byte key and a 16-byte nonce, as XChaCha20
// does to absorb a longer nonce before running ChaCha20.
function subkey(key: []byte, nonce16: []byte): []byte {
  return hchacha20(key, nonce16)
}
```

### `chacha20(key: []byte, nonce: []byte, counter: u32, data: []byte): []byte`

Encrypt or decrypt `data` under ChaCha20 (RFC 8439). `key` must be 32 bytes and
`nonce` 12 bytes; `counter` is the block counter of the first block — the RFC's
worked examples start at 1. Returns a fresh slice the length of `data`. Encryption
and decryption are the same operation, so passing ciphertext back through the same
key, nonce, and counter recovers the plaintext. Panics if `key` or `nonce` is the
wrong length. A (key, nonce) pair must never be reused.

### `hchacha20(key: []byte, nonce16: []byte): []byte`

The HChaCha20 subkey of `key` (32 bytes) under the 16-byte `nonce16`
(draft-irtf-cfrg-xchacha §2.2): 20 ChaCha rounds over the state with the nonce in
the last four words and no final add-back, returning a 32-byte subkey. This is
XChaCha20's key-derivation step — it lets XChaCha20 accept a 192-bit nonce — and is
not a cipher on its own. Panics if `key` or `nonce16` is the wrong length.

## AEAD

Authenticated encryption with associated data. `Aead` is the contract every
authenticated cipher in the library satisfies; concrete algorithms — AES-GCM,
ChaCha20-Poly1305 — are separate types that conform to it structurally, so code
can encrypt against `Aead` without naming a specific algorithm.

AEAD binds confidentiality and integrity in one operation. `seal` encrypts the
plaintext and authenticates both it and the unencrypted `aad` (additional
authenticated data — headers, sequence numbers: data you must not hide but must
not let an attacker forge), returning the ciphertext with the authentication tag
appended. `open` recomputes that tag in constant time and *fails* on any
mismatch, so a tampered message — or a wrong key, nonce, or `aad` — yields an
error, never unauthenticated plaintext.

Because interfaces are structural, a type is an `Aead` simply by having the four
methods below. The example is a stand-in cipher — it XORs against a fixed pad
rather than encrypting — but a real one plugs in exactly the same way.

```bit
import { Aead } from "std/crypto"

// A stand-in "cipher", NOT real encryption: it XORs each byte with a fixed pad
// and appends a one-byte XOR-fold as the "tag". A real AES-GCM satisfies `Aead`
// the same way — by its four methods.
struct XorSeal {
  pad: byte
}

function (x: XorSeal) seal(nonce: []byte, plaintext: []byte, aad: []byte): []byte {
  let out = []byte(len(plaintext) + 1)
  let tag: byte = 0
  let i = 0
  while (i < len(plaintext)) {
    let c = plaintext[i] ^ x.pad
    out[i] = c
    tag = tag ^ c
    i = i + 1
  }
  out[len(plaintext)] = tag // the 1-byte authentication tag
  return out
}

function (x: XorSeal) open(nonce: []byte, ciphertext: []byte, aad: []byte): []byte! {
  if (len(ciphertext) < 1) {
    fail newError("open: ciphertext shorter than the tag")
  }
  let n = len(ciphertext) - 1
  let out = []byte(n)
  let tag: byte = 0
  let i = 0
  while (i < n) {
    let c = ciphertext[i]
    tag = tag ^ c
    out[i] = c ^ x.pad
    i = i + 1
  }
  if (tag != ciphertext[n]) { // tag mismatch: reject, never return plaintext
    fail newError("open: authentication failed")
  }
  return out
}

function (x: XorSeal) nonceSize(): int {
  return 12
}

function (x: XorSeal) overhead(): int {
  return 1
}

// Encrypt-then-decrypt through the `Aead` interface: `open` recovers what `seal`
// produced, or fails if the ciphertext was tampered with.
function roundtrip(a: Aead, nonce: []byte, msg: []byte, aad: []byte): []byte! {
  let ct = a.seal(nonce, msg, aad)
  return a.open(nonce, ct, aad)?
}
```

### `Aead`

The authenticated-encryption contract:

```bit ignore
interface Aead {
  seal(nonce: []byte, plaintext: []byte, aad: []byte): []byte,   // ciphertext‖tag
  open(nonce: []byte, ciphertext: []byte, aad: []byte): []byte!, // verify, then decrypt
  nonceSize(): int, // required nonce length in bytes
  overhead(): int,  // bytes seal adds — the tag length
}
```

`seal` returns the ciphertext with the tag appended, so `len(seal(...))` is
`len(plaintext) + overhead()`. `open` verifies the tag in constant time and
returns `[]byte!` — it *fails* rather than return plaintext when the tag does not
match, which is the whole point of authenticated encryption: unverified bytes
never reach the caller.

The **nonce must be unique per key** for every `seal`. It need not be secret or
random — a per-key counter is fine — but it must never repeat under one key.
Nonce reuse is catastrophic: it exposes the XOR of two plaintexts, and for
AES-GCM a single repeat also leaks the polynomial authentication key `H`,
letting an attacker forge tags for *any* message under that key. If you cannot
guarantee uniqueness — random nonces at high volume risk a birthday collision,
and distributed writers cannot share a counter — use a misuse-resistant scheme:
XChaCha20-Poly1305 (a 192-bit random nonce makes collision negligible) or
AES-GCM-SIV (nonce reuse degrades only to revealing message equality, not
catastrophe).
## AES

The AES block cipher (FIPS 197) for 128-, 192-, and 256-bit keys. `newAes`
expands a key once into an `AesCipher`; that value then enciphers or deciphers
any number of 16-byte blocks. This is the raw single-block permutation — no
chaining, no padding, no IV. Real messages need a mode of operation (CBC, CTR,
GCM) layered on top; never encrypt more than one block under bare ECB, because
identical plaintext blocks would then produce identical ciphertext.

The S-box is computed in GF(2^8) — the multiplicative inverse via `x^254`
followed by the affine map — not read from a 256-byte table indexed by a secret
byte. So there is no key- or plaintext-dependent memory access or branch
anywhere in the cipher: it is constant-time by construction, which is the whole
point of shipping it rather than a table-driven version that leaks through the
data cache. The cost is speed — each substitution is a short chain of field
multiplies instead of one load. Hardware AES (AES-NI, ARMv8 crypto) is a
separate, later track; this is the portable reference every target shares.

```bit
import { newAes, encodeHex } from "std/crypto"

// Encipher a single 16-byte block with AES-128 and return the ciphertext as
// hex. `newAes` fails unless the key is 16, 24, or 32 bytes, so this is fallible.
function encryptBlockHex(key: []byte, block: []byte): string! {
  let cipher = newAes(key)?
  return encodeHex(cipher.encryptBlock(block))
}

// Decipher one block — the inverse of encryptBlock under the same key.
function decryptBlockHex(key: []byte, block: []byte): string! {
  let cipher = newAes(key)?
  return encodeHex(cipher.decryptBlock(block))
}
```

### `AesCipher`

A key-scheduled AES cipher. Build one with `newAes` rather than a struct
literal — the constructor validates the key length and expands the round-key
schedule once, which every `encryptBlock`/`decryptBlock` call then reuses. One
value ciphers any number of blocks.

### `newAes(key: []byte): AesCipher!`

Builds an AES cipher from `key`. The key length selects the variant: 16 bytes is
AES-128, 24 is AES-192, 32 is AES-256. Fails on any other length.

### `AesCipher.encryptBlock(block: []byte): []byte`

Enciphers one 16-byte `block`, returning a fresh 16-byte ciphertext block.
`block` must be exactly 16 bytes. This is the bare block permutation with no
chaining — use a mode of operation for multi-block messages.

### `AesCipher.decryptBlock(block: []byte): []byte`

Deciphers one 16-byte `block`, returning a fresh 16-byte plaintext block — the
inverse of `encryptBlock` under the same key, so `decryptBlock(encryptBlock(b))`
equals `b`. `block` must be exactly 16 bytes.

## Poly1305

Poly1305 (RFC 8439 §2.5) is a **one-time** message authentication code: it takes
a 32-byte key `r‖s` and a message and produces a 16-byte tag. It evaluates a
polynomial in the message blocks modulo the prime 2^130 - 5, then adds the
secret pad `s` modulo 2^128 — no hash function underneath, just field
arithmetic, so it is fast and simple to make constant-time.

The **one-time** part is not a suggestion: a given key must authenticate **at
most one message**. Authenticating two different messages under the same key
lets an attacker solve for `r` and forge tags for any message. In practice the
key is never a constant — it is derived per-message from a nonce, which is
exactly what ChaCha20-Poly1305 does (it keys Poly1305 with the first block of the
cipher's keystream). Use Poly1305 directly only when you produce a fresh key for
every single message.

Verification must be constant-time. `poly1305Verify` recomputes the tag and
compares with `ctEq`, never `==`: a comparison that stops at the first differing
byte leaks *where* two tags diverge, and that timing oracle is enough to forge a
valid tag one byte at a time.

```bit
import { poly1305, poly1305Verify, encodeHex } from "std/crypto"

// The 16-byte tag of `msg` under a 32-byte one-time key, as lowercase hex. The
// key is r‖s and must be used for exactly one message — a real caller derives a
// fresh key per message (e.g. from a nonce-keyed ChaCha20 keystream), never a
// reused constant.
function authTag(key: []byte, msg: []byte): string {
  return encodeHex(poly1305(key, msg))
}

// The receiver recomputes the tag and checks it in constant time. Prefer this
// over comparing `poly1305(key, msg)` to the received tag with `==`, which would
// leak the mismatch position through timing.
function verified(key: []byte, msg: []byte, tag: []byte): bool {
  return poly1305Verify(key, msg, tag)
}
```

### `poly1305(key: []byte, msg: []byte): []byte`

The 16-byte Poly1305 tag of `msg` under the 32-byte one-time `key` (`r` in the
first 16 bytes, `s` in the last 16). `key` must be exactly 32 bytes. Remember it
is one-time: never authenticate two messages with the same key.

### `poly1305Verify(key: []byte, msg: []byte, tag: []byte): bool`

Recompute the tag of `msg` under `key` and compare it against `tag` in constant
time, returning true iff they match. Always use this to check a tag rather than
comparing bytes with `==`, which leaks the first mismatch position through
timing.

## HMAC

HMAC (RFC 2104) keys a message authentication code out of any unkeyed hash `H`:

    HMAC(K, m) = H((K' ^ opad) || H((K' ^ ipad) || m))

where `ipad` is the byte `0x36` and `opad` the byte `0x5c`, each repeated across
one hash block, and `K'` is the key sized to that block. The two nested hashes
with the pad-masked key are what make it a pseudo-random function even when the
bare hash is not, and they close the length-extension weakness of the
Merkle–Damgård hashes (SHA-1, SHA-2). Unlike Poly1305 it is not one-time: the
same key authenticates any number of messages.

The construction is generic over the digest. `hmac` takes a hash *constructor*
(`() => Hash`) rather than a hash value, so the same code runs over SHA-256,
SHA-384, or SHA-512 — it asks the hash for its own `blockSize` instead of
hard-coding one, and calls the constructor once per message to get a fresh
hasher. The SHA-512 family already returns `Hash`, so `newSha512`/`newSha384`
pass directly; `newSha256` returns the concrete `Sha256`, so wrap it in a tiny
`() => Hash` function.

The key is normalized to exactly one block (RFC 2104 §2): a key longer than
`blockSize` is hashed down first (then it is `size` bytes, always at most a
block), and a shorter key is zero-padded up. Verify a tag with `hmacEqual`, which
compares in constant time via `ctEq` — never with `==`, whose first-mismatch
timing leaks enough to forge a tag one byte at a time.

```bit
import { Hash, hmac, hmacEqual, newSha256, newSha512, encodeHex } from "std/crypto"

// SHA-256 returns the concrete `Sha256`, so expose its constructor as a
// `() => Hash` value; the SHA-512 family already returns `Hash` (see below).
function sha256Hash(): Hash { return newSha256() }

// The HMAC-SHA-256 tag of `msg` under `key`, as lowercase hex.
function tagHex(key: []byte, msg: []byte): string {
  return encodeHex(hmac(sha256Hash, key, msg))
}

// The same call over a different hash — HMAC-SHA-512 — by handing in another
// constructor. `newSha512` already returns `Hash`, so it needs no wrapper.
function tag512Hex(key: []byte, msg: []byte): string {
  return encodeHex(hmac(newSha512, key, msg))
}

// Verify a received tag in constant time. Prefer this over comparing the tag
// bytes with `==`, which leaks the first mismatch position through timing.
function verify(key: []byte, msg: []byte, tag: []byte): bool {
  return hmacEqual(hmac(sha256Hash, key, msg), tag)
}
```

### `hmac(newHash: () => Hash, key: []byte, msg: []byte): []byte`

The HMAC of `msg` under `key`, using the hash built by `newHash`. The tag length
is the hash's own `size` (32 bytes for SHA-256, 64 for SHA-512). A key longer
than the hash's block is hashed down first; a shorter key is zero-padded.
`newHash` must return a fresh, empty hasher on each call — the SHA-512 family
constructors qualify directly, while `newSha256`/`newSha224` are wrapped as a
`() => Hash` since they return the concrete `Sha256`.

### `hmacEqual(a: []byte, b: []byte): bool`

Constant-time equality of two HMAC tags, via `ctEq`. Returns true iff `a` and `b`
have the same length and bytes, always scanning the full length so it never
leaks *where* two tags diverge. Use it to check a tag rather than comparing bytes
with `==`.
## AES modes

Modes of operation (NIST SP 800-38A) that turn the single-block `AesCipher` into
a cipher over arbitrary-length messages. Each rides an already-keyed cipher, so
it reuses the expanded key schedule and adds no key handling of its own.

`ctr` is the workhorse — counter mode, and the keystream generator AES-GCM is
built on. It enciphers a big-endian 128-bit counter starting from the 16-byte
`iv`, then XORs that keystream into the data. Because XOR is its own inverse,
encryption and decryption are the *same* operation, so one function serves both;
it needs no padding and handles a trailing partial block.

`cbcEncrypt` / `cbcDecrypt` are cipher-block-chaining, provided for interop with
existing CBC protocols rather than as a default. They do no padding, so the data
must already be an exact multiple of the 16-byte block size. `ecbEncryptBlock` is
the bare block permutation, exposed only for QUIC header protection — it is unsafe
as a general mode because ECB reveals when two plaintext blocks are equal.

None of these authenticate: a mode gives confidentiality only. Whenever the
ciphertext could be tampered with, use an AEAD (AES-GCM, ChaCha20-Poly1305).

```bit
import { newAes, ctr, ecbEncryptBlock, cbcEncrypt, cbcDecrypt, encodeHex } from "std/crypto"

// CTR encrypts and decrypts with the same call. `key` is 16/24/32 bytes and `iv`
// is the 16-byte initial counter block; the result is the ciphertext as hex.
function ctrHex(key: []byte, iv: []byte, data: []byte): string! {
  let cipher = newAes(key)?
  return encodeHex(ctr(cipher, iv, data))
}

// CBC over block-aligned data (`data` must be a multiple of 16 bytes).
function cbcHex(key: []byte, iv: []byte, data: []byte): string! {
  let cipher = newAes(key)?
  return encodeHex(cbcEncrypt(cipher, iv, data))
}

// CBC decrypt is fallible: a ciphertext that is not a whole number of blocks
// fails rather than returning garbage.
function cbcOpen(key: []byte, iv: []byte, ct: []byte): []byte! {
  let cipher = newAes(key)?
  return cbcDecrypt(cipher, iv, ct)?
}

// QUIC header protection derives a mask from one sampled ciphertext block via
// the bare ECB permutation — never a general-purpose cipher.
function headerMask(key: []byte, sample: []byte): string! {
  let cipher = newAes(key)?
  return encodeHex(ecbEncryptBlock(cipher, sample))
}
```

### `ctr(cipher: AesCipher, iv: []byte, data: []byte): []byte`

Encrypts or decrypts `data` in AES counter (CTR) mode under the keyed `cipher`.
The 16-byte `iv` is the initial value of a big-endian 128-bit counter block; each
successive block enciphers the incremented counter and XORs that keystream into
the data. XORing the keystream is its own inverse, so the same call both encrypts
and decrypts, and `data` may be any length. This is the keystream engine AES-GCM
is built on.

### `ecbEncryptBlock(cipher: AesCipher, block: []byte): []byte`

Enciphers one 16-byte `block` as a bare ECB block — the raw AES permutation with
no chaining or IV. Exposed **only** for QUIC header protection, which enciphers a
sampled ciphertext block to derive the header mask. It is unsafe as a general
mode: ECB reveals when two plaintext blocks are equal, so never encrypt more than
one block of real data through it.

### `cbcEncrypt(cipher: AesCipher, iv: []byte, data: []byte): []byte`

Encrypts `data` in AES cipher-block-chaining (CBC) mode with the explicit 16-byte
`iv`, XORing each plaintext block with the previous ciphertext block before
enciphering. `data` must already be an exact multiple of 16 bytes — CBC does no
padding, so a non-block-multiple length is a caller error and panics. Interop
only; prefer `ctr` or an AEAD for new designs.

### `cbcDecrypt(cipher: AesCipher, iv: []byte, data: []byte): []byte!`

Decrypts `data` in AES CBC mode with the explicit 16-byte `iv` — the inverse of
`cbcEncrypt`. Fails (fallible `[]byte!`) if `data` is not a multiple of 16 bytes,
since a truncated ciphertext cannot be a valid CBC stream. Interop only.

## HKDF

HKDF (RFC 5869) is the HMAC-based extract-and-expand key derivation function —
the TLS 1.3 key schedule. It turns one input keying material into any number of
independent, cryptographically strong output keys, in two steps built entirely
from `hmac`:

- `hkdfExtract(salt, IKM)` concentrates the entropy of the input keying material
  into a fixed-length pseudo-random key `PRK`, exactly one digest long. A public
  `salt` (defaulting to `HashLen` zero bytes when empty) makes it a strong
  randomness extractor.
- `hkdfExpand(PRK, info, L)` stretches `PRK` to `L` bytes with the counter chain
  `T(i) = HMAC(PRK, T(i-1) || info || byte(i))`, where the application-specific
  `info` binds the derived key to its context. Because the counter is one byte,
  `L` cannot exceed `255 * HashLen`.

`hkdf` runs both in one call. All three are generic over the digest: they take a
hash *constructor* (`() => Hash`) and ask the hash for its own `size`, so the
same code derives keys under SHA-256, SHA-384, or SHA-512. As with `hmac`,
`newSha512`/`newSha384` pass directly, while `newSha256` returns the concrete
`Sha256` and is wrapped as a `() => Hash`.

```bit
import { Hash, hkdf, hkdfExtract, hkdfExpand, newSha256, newSha512, encodeHex } from "std/crypto"

// SHA-256 returns the concrete `Sha256`, so expose its constructor as a
// `() => Hash` value; the SHA-512 family already returns `Hash`.
function sha256Hash(): Hash { return newSha256() }

// Derive a 32-byte key in two explicit steps: extract the entropy of `ikm` into
// a pseudo-random key, then expand it under a context label to the wanted size.
function deriveKey(salt: []byte, ikm: []byte): []byte! {
  let prk = hkdfExtract(sha256Hash, salt, ikm)
  return hkdfExpand(sha256Hash, prk, []byte("app v1 encryption"), 32)?
}

// The same derivation in one call — extract and expand together — as hex.
function deriveKeyHex(salt: []byte, ikm: []byte): string! {
  return encodeHex(hkdf(sha256Hash, salt, ikm, []byte("app v1 encryption"), 32)?)
}

// The digest selects the strength and the output ceiling: HKDF-SHA-512 can
// derive up to 255*64 bytes. An empty salt takes the HashLen-zero default.
function deriveLong(ikm: []byte): []byte! {
  return hkdf(newSha512, []byte(0), ikm, []byte("stream keys"), 128)?
}
```

### `hkdfExtract(newHash: () => Hash, salt: []byte, ikm: []byte): []byte`

HKDF-Extract (RFC 5869 §2.2): the pseudo-random key `PRK = HMAC(salt, IKM)`,
exactly one digest long. An empty `salt` is replaced by `HashLen` zero bytes, as
the standard requires — that zero salt is what makes extraction a strong
randomness extractor, so it is not the same as omitting the salt entirely.
`newHash` selects the digest and must return a fresh, empty hasher on each call.

### `hkdfExpand(newHash: () => Hash, prk: []byte, info: []byte, outLen: int): []byte!`

HKDF-Expand (RFC 5869 §2.3): stretch the pseudo-random key `prk` to `outLen`
bytes of output keying material, bound to the context `info`, via the
`T(i) = HMAC(prk, T(i-1) || info || byte(i))` counter chain. Fails if `outLen`
exceeds `255 * HashLen`, the most the one-byte block counter can address. `prk`
should be a digest-length key from `hkdfExtract`; `info` may be empty.

### `hkdf(newHash: () => Hash, salt: []byte, ikm: []byte, info: []byte, outLen: int): []byte!`

HKDF (RFC 5869 §2): extract then expand in one call — derive `outLen` bytes of
output keying material from `ikm`, salted by `salt` and bound to the context
`info`. Equivalent to `hkdfExpand(newHash, hkdfExtract(newHash, salt, ikm),
info, outLen)`, and fails on the same over-long `outLen` as `hkdfExpand`.

## ChaCha20-Poly1305

The ChaCha20-Poly1305 (RFC 8439 §2.8) and XChaCha20-Poly1305
(draft-irtf-cfrg-xchacha §2.1) authenticated ciphers. Each is an `Aead`: `seal`
encrypts the plaintext and authenticates it together with the `aad`, returning
`ciphertext ‖ tag` (a 16-byte Poly1305 tag); `open` recomputes the tag, verifies
it in constant time, and *fails* on any mismatch — a tampered message, or a wrong
key, nonce, or `aad` — so unauthenticated plaintext never reaches the caller.

`ChaChaPoly` derives a one-time Poly1305 key from ChaCha20 block 0, encrypts with
the counter starting at block 1, and authenticates
`aad ‖ pad16 ‖ ciphertext ‖ pad16 ‖ le64(len aad) ‖ le64(len ct)`. Its nonce is
**12 bytes** and, like any stream cipher, MUST be unique per key: a repeat XORs
two plaintexts under one keystream and leaks their difference.

`XChaChaPoly` takes a **24-byte** nonce. It derives a subkey with HChaCha20 over
the key and the first 16 nonce bytes, then runs the same construction under that
subkey. The 192-bit nonce makes a random-nonce collision negligible, so — unlike
the 96-bit variant — a freshly random nonce per message is safe.

Both compose the audited `chacha20`, `hchacha20`, `poly1305`, and
`poly1305Verify` primitives, so they inherit their constant-time-by-construction
property. Outputs are checked against the RFC 8439 §2.8.2 and §A.5 vectors and a
libsodium-verified XChaCha20-Poly1305 vector.

```bit
import { newChaChaPoly, newXChaChaPoly } from "std/crypto"

// Encrypt-then-authenticate with ChaCha20-Poly1305, then verify-then-decrypt.
// `open` returns the original plaintext or fails — it never returns unverified
// bytes. `key` is 32 bytes and `nonce` 12 bytes, unique per key.
function protect(key: []byte, nonce: []byte, msg: []byte, aad: []byte): []byte! {
  let c = newChaChaPoly(key)?
  let sealed = c.seal(nonce, msg, aad) // ciphertext ‖ 16-byte tag
  return c.open(nonce, sealed, aad)?
}

// The same with XChaCha20-Poly1305: a 24-byte nonce, wide enough that a random
// nonce per message is safe.
function protectX(key: []byte, nonce: []byte, msg: []byte, aad: []byte): []byte! {
  let c = newXChaChaPoly(key)?
  let sealed = c.seal(nonce, msg, aad)
  return c.open(nonce, sealed, aad)?
}
```

### `ChaChaPoly`

A ChaCha20-Poly1305 cipher (RFC 8439 §2.8), an `Aead` with a 12-byte nonce and a
16-byte tag. Build one with `newChaChaPoly`; a value seals and opens any number of
messages under its key.

### `newChaChaPoly(key: []byte): ChaChaPoly!`

Build a ChaCha20-Poly1305 cipher from a 32-byte `key`. Fails on any other length.
The key is copied into the cipher, so the caller may reuse or wipe its slice.

### `ChaChaPoly.seal(nonce: []byte, plaintext: []byte, aad: []byte): []byte`

Encrypt `plaintext` and authenticate it with `aad`, returning `ciphertext ‖ tag`
(16 bytes longer than `plaintext`). `nonce` must be 12 bytes and unique per key;
a wrong length panics, like Go's `cipher.AEAD.Seal`.

### `ChaChaPoly.open(nonce: []byte, ciphertext: []byte, aad: []byte): []byte!`

Verify the tag over `ciphertext` and `aad` in constant time, then decrypt.
Returns the plaintext, or *fails* on a tampered message, a wrong key/nonce/`aad`,
or an input shorter than the tag — never unauthenticated plaintext. A wrong nonce
length panics.

### `ChaChaPoly.nonceSize(): int`

The required nonce length in bytes: 12.

### `ChaChaPoly.overhead(): int`

The number of bytes `seal` adds — the 16-byte tag length.

### `XChaChaPoly`

An XChaCha20-Poly1305 cipher (draft-irtf-cfrg-xchacha §2.1), an `Aead` with a
24-byte nonce and a 16-byte tag. The extended nonce makes a random nonce per
message safe. Build one with `newXChaChaPoly`.

### `newXChaChaPoly(key: []byte): XChaChaPoly!`

Build an XChaCha20-Poly1305 cipher from a 32-byte `key`. Fails on any other
length. The key is copied.

### `XChaChaPoly.seal(nonce: []byte, plaintext: []byte, aad: []byte): []byte`

Encrypt `plaintext` and authenticate it with `aad`, returning `ciphertext ‖ tag`.
`nonce` must be 24 bytes; at this width a random nonce per message is safe. A
wrong length panics.

### `XChaChaPoly.open(nonce: []byte, ciphertext: []byte, aad: []byte): []byte!`

Verify the tag over `ciphertext` and `aad` in constant time, then decrypt. Fails
on any mismatch or a short input. A wrong nonce length panics.

### `XChaChaPoly.nonceSize(): int`

The required nonce length in bytes: 24.

### `XChaChaPoly.overhead(): int`

The number of bytes `seal` adds — the 16-byte tag length.
## AES-GCM

Authenticated encryption (NIST SP 800-38D) — the AEAD behind TLS 1.2/1.3, IPsec,
and SSH. AES-GCM layers a GHASH authentication tag onto AES counter mode, so one
pass gives confidentiality for the plaintext and integrity for both the plaintext
and the associated data. `AesGcm` is the concrete cipher; it satisfies the `Aead`
interface, so code written against `Aead` accepts it without naming it.

`newGcm` keys the cipher once — expanding the AES schedule and deriving the GHASH
subkey `H = AES_K(0)` — and the returned value seals and opens any number of
messages under 16- or 32-byte keys (AES-128-GCM / AES-256-GCM). Each `seal` takes
a 12-byte (96-bit) nonce and appends a 16-byte tag; `open` recomputes the tag,
compares it in constant time, and *fails* on any mismatch — a tampered ciphertext,
a wrong key, nonce, or `aad` — so unverified bytes never reach the caller.

The **nonce must be unique for every `seal` under a given key.** It need not be
secret or random — a per-key counter is ideal — but a single repeat is
catastrophic for GCM: it exposes the XOR of two plaintexts *and* leaks the GHASH
subkey `H`, which lets an attacker forge tags for any message under that key. If
unique nonces cannot be guaranteed (random nonces at high volume risk a birthday
collision), reach for a misuse-resistant scheme instead (XChaCha20-Poly1305 or
AES-GCM-SIV).

GHASH multiplies in GF(2^128) with a constant-time, bit-by-bit shift-and-xor —
not a key- or ciphertext-indexed table, which would leak through cache timing.
Correctness over speed: a PCLMULQDQ/PMULL hardware GHASH is a separate later track.

```bit
import { newGcm, encodeHex } from "std/crypto"

// Seal then open one message. `key` is 16 or 32 bytes (AES-128/256-GCM); `nonce`
// is 12 bytes and MUST be unique per key — never reuse one under the same key.
// `aad` is authenticated but not encrypted (headers, sequence numbers). Returns
// the recovered plaintext as hex, or fails if the tag does not verify.
function protect(key: []byte, nonce: []byte, msg: []byte, aad: []byte): string! {
  let cipher = newGcm(key)?
  let sealed = cipher.seal(nonce, msg, aad) // ciphertext ‖ 16-byte tag
  let opened = cipher.open(nonce, sealed, aad)? // fails on any tag mismatch
  return encodeHex(opened)
}
```

### `AesGcm`

A keyed AES-GCM cipher. Build one with `newGcm`, not a struct literal — the
constructor validates the key length and derives the GHASH subkey. One value
seals and opens any number of messages; it satisfies the `Aead` interface.

### `newGcm(key: []byte): AesGcm!`

Keys an AES-GCM cipher from `key`, whose length selects the variant: 16 bytes
(AES-128-GCM) or 32 bytes (AES-256-GCM); 24 (AES-192) also works. Fails on any
other length. The GHASH subkey is derived here once and reused by every later
`seal`/`open`.

### `AesGcm.seal(nonce: []byte, plaintext: []byte, aad: []byte): []byte`

Encrypts `plaintext` under the 12-byte `nonce` and authenticates both it and the
unencrypted `aad`, returning the ciphertext with the 16-byte tag appended (so
`len(seal(...))` is `len(plaintext) + 16`). The **nonce must be unique per key** —
reuse is catastrophic for GCM. A wrong nonce length is a caller error and panics.

### `AesGcm.open(nonce: []byte, ciphertext: []byte, aad: []byte): []byte!`

Verifies and decrypts `ciphertext` (the sealed `ct ‖ tag`) under `nonce` and
`aad`. Recomputes the tag and compares it in constant time, *failing* on any
mismatch — a tampered message, or a wrong key, nonce, or `aad` — without returning
the plaintext. Also fails if the input is shorter than the 16-byte tag.

### `AesGcm.nonceSize(): int`

The required nonce length in bytes: `12` (96-bit), the GCM/TLS standard.

### `AesGcm.overhead(): int`

The number of bytes `seal` appends: `16`, the authentication tag length.
## ASN.1 / DER

The Distinguished Encoding Rules (X.690) — the canonical binary form of ASN.1
behind X.509 certificates, PKCS keys, and ECDSA/RSA signatures. Everything is one
flat `Element`: a tag (class + constructed flag + number) carrying either raw
content octets (a primitive) or a list of child elements (a constructed type).
`asn1Parse` turns bytes into that tree; `asn1Encode` turns it back. Typed
constructors and readers on top build and interpret the universal types.

Decoding is **strict**: malformed ASN.1 is a classic parser attack surface, so
`asn1Parse` and every reader are fallible (`T!`) and *reject* rather than
best-effort. A non-minimal length, an indefinite-length marker, a non-minimal
(redundantly sign-extended) INTEGER, a non-minimal OID subidentifier, or trailing
bytes after the top-level element all fail the parse — there is exactly one valid
encoding of a value, and only that encoding is accepted.

```bit
import {
  Element, asn1Encode, asn1Parse, asn1Sequence, asn1Integer,
  asn1ReadSequence, asn1ReadInteger,
} from "std/crypto"

// Build SEQUENCE { INTEGER, INTEGER }, encode it, parse it back, and sum the two.
function seqSum(a: int, b: int): int! {
  let seq = asn1Sequence([]Element{ asn1Integer(a), asn1Integer(b) })
  let parts = asn1ReadSequence(asn1Parse(asn1Encode(seq))?)?
  return asn1ReadInteger(parts[0])? + asn1ReadInteger(parts[1])?
}
```

### `Element`

A parsed or to-be-encoded ASN.1 element. Its exported fields are `cls` (the tag
class, one of the `class*` constants), `constructed` (whether it holds child
elements rather than raw octets), `tag` (the tag number), `bytes` (the primitive
content octets), and `children` (the members of a constructed type). Build one
with a typed constructor; branch on `cls`/`tag` to interpret a parsed one.

### `BitString`

The decoded content of a BIT STRING: `unusedBits` (0..7) trailing bits of the
final octet are padding, and `bytes` are the value octets.

```bit
import { asn1Encode, asn1Parse, asn1BitString, asn1ReadBitString } from "std/crypto"

// Round-trip a BIT STRING (no unused bits) and return its value octets.
function bitOctets(data: []byte): []byte! {
  let bs = asn1ReadBitString(asn1Parse(asn1Encode(asn1BitString(0, data)))?)?
  return bs.bytes
}
```

### `asn1Parse(der: []byte): Element!`

Parse a single top-level DER element from `der`, recursing into constructed
content. Fails on any malformed structure (non-minimal length, indefinite length,
non-minimal INTEGER, a SEQUENCE/SET that is not constructed) or on octets left
over after the element.

### `asn1Encode(e: Element): []byte`

The DER encoding of `e`: identifier octet(s), definite length, then content — a
constructed element's content is the concatenation of its encoded children, a
primitive's is its raw bytes. Total and deterministic: every value has exactly one
encoding, so `asn1Encode(asn1Parse(der)?)` reproduces valid DER byte-for-byte.

### `asn1Boolean(v: bool): Element`

A BOOLEAN. DER spells true as `0xFF` and false as `0x00`.

### `asn1ReadBoolean(e: Element): bool!`

The bool of a BOOLEAN. Strict DER: content must be exactly `0x00` or `0xFF`.

### `asn1Integer(v: int): Element`

A signed INTEGER from a 64-bit value, minimally two's-complement encoded. For
values wider than 64 bits use `asn1BigInteger`.

### `asn1ReadInteger(e: Element): int!`

The signed value of an INTEGER that fits in 64 bits. Fails on a non-minimal
encoding or a value wider than eight octets.

### `asn1BigInteger(mag: []byte): Element`

A non-negative INTEGER from an unsigned big-endian magnitude. Leading zero octets
are dropped and a `0x00` sign octet is prepended when the top bit would otherwise
read as negative, so the result is always minimal DER. This is how RSA moduli and
ECDSA `r`/`s` are encoded.

### `asn1ReadBigInteger(e: Element): []byte!`

The unsigned big-endian magnitude of a non-negative INTEGER, with the sign octet
removed — the inverse of `asn1BigInteger`. Fails on a non-minimal encoding or a
negative value.

```bit
import {
  Element, asn1Encode, asn1Parse, asn1Sequence, asn1BigInteger,
  asn1ReadSequence, asn1ReadBigInteger,
} from "std/crypto"

// Encode an ECDSA signature SEQUENCE { INTEGER r, INTEGER s } from raw magnitudes.
function encodeSig(r: []byte, s: []byte): []byte {
  return asn1Encode(asn1Sequence([]Element{ asn1BigInteger(r), asn1BigInteger(s) }))
}

// Read `r` back out of a DER signature.
function sigR(der: []byte): []byte! {
  let parts = asn1ReadSequence(asn1Parse(der)?)?
  return asn1ReadBigInteger(parts[0])?
}
```

### `asn1BitString(unusedBits: int, data: []byte): Element`

A BIT STRING whose final octet has `unusedBits` (0..7) of padding; `data` is the
value octets.

### `asn1ReadBitString(e: Element): BitString!`

The decoded BIT STRING. Fails if the unused-bits octet is missing or > 7, if an
empty value claims unused bits, or (strict DER) if any trailing unused bit is set.

### `asn1OctetString(data: []byte): Element`

An OCTET STRING carrying `data` verbatim.

### `asn1ReadOctetString(e: Element): []byte!`

The content octets of an OCTET STRING.

### `asn1Null(): Element`

A NULL: empty content.

### `asn1ReadNull(e: Element): ()!`

Verify a NULL: fails unless the element is a NULL with empty content.

### `asn1Oid(arcs: []int): Element!`

An OBJECT IDENTIFIER from its dotted arcs, e.g. `[1, 2, 840, 113549, 1, 1, 11]`.
Fails unless there are at least two arcs, the first is 0/1/2, and the second is
< 40 when the first is 0 or 1. The first two arcs are packed into one
subidentifier (`40*arc0 + arc1`).

### `asn1ReadOid(e: Element): []int!`

The dotted arcs of an OBJECT IDENTIFIER, with the first subidentifier unpacked
back into the first two arcs. Fails on an empty OID, a truncated subidentifier, or
a non-minimal (leading-`0x80`) subidentifier.

### `asn1OidString(arcs: []int): string`

The dotted-decimal text of `arcs`, e.g. `"1.2.840.113549.1.1.11"`. A rendering
helper — it does no validation.

```bit
import { asn1Encode, asn1Parse, asn1Oid, asn1ReadOid, asn1OidString } from "std/crypto"

// The dotted form of an OID after a build/parse round-trip (e.g. ecdsa-with-SHA256).
function oidText(arcs: []int): string! {
  let oid = asn1Oid(arcs)?
  return asn1OidString(asn1ReadOid(asn1Parse(asn1Encode(oid))?)?)
}
```

### `asn1Utf8String(s: string): Element`

A UTF8String.

### `asn1PrintableString(s: string): Element`

A PrintableString. The caller is responsible for the restricted charset.

### `asn1IA5String(s: string): Element`

An IA5String (ASCII).

### `asn1UtcTime(s: string): Element`

A UTCTime, e.g. `"230607000000Z"`. The caller supplies the formatted string.

### `asn1GeneralizedTime(s: string): Element`

A GeneralizedTime, e.g. `"20230607000000Z"`.

### `asn1ReadString(e: Element): string!`

The text of a string- or time-valued element: UTF8String, PrintableString,
IA5String, UTCTime, or GeneralizedTime. Fails on any other type. The raw octets
are returned as-is; per-type charset validation is the caller's.

```bit
import { asn1Encode, asn1Parse, asn1Utf8String, asn1ReadString } from "std/crypto"

// Round-trip a UTF8String through DER.
function utf8RoundTrip(s: string): string! {
  return asn1ReadString(asn1Parse(asn1Encode(asn1Utf8String(s)))?)?
}
```

### `asn1Sequence(children: []Element): Element`

A SEQUENCE of the given members, in order.

### `asn1ReadSequence(e: Element): []Element!`

The members of a SEQUENCE. Fails unless `e` is a universal constructed SEQUENCE.

### `asn1Set(children: []Element): Element`

A SET of the given members. DER requires SET OF members to be sorted by their
encoding; that ordering is the caller's responsibility.

### `asn1ReadSet(e: Element): []Element!`

The members of a SET. Fails unless `e` is a universal constructed SET.

### `asn1ExplicitTag(tag: int, inner: Element): Element`

An explicit context tag `[tag]`: a constructed context-class element wrapping
`inner` whole, so `inner`'s own tag is preserved inside.

### `asn1ImplicitTag(tag: int, inner: Element): Element`

An implicit context tag `[tag]`: `inner` retagged to context class `tag`, keeping
its content and constructed-ness but replacing its tag. The original universal tag
is lost, so the reader must know the underlying type.

### `asn1ReadExplicit(e: Element, tag: int): Element!`

The inner element of an explicit context tag `[tag]`. Fails unless `e` is a
constructed context tag with that number wrapping exactly one element.

```bit
import {
  Element, asn1Encode, asn1Parse, asn1ExplicitTag, asn1OctetString,
  asn1ReadExplicit, asn1ReadOctetString,
} from "std/crypto"

// Wrap an OCTET STRING in an explicit [0] tag, then unwrap it after a round-trip.
function unwrapZero(data: []byte): []byte! {
  let tagged = asn1ExplicitTag(0, asn1OctetString(data))
  let inner = asn1ReadExplicit(asn1Parse(asn1Encode(tagged))?, 0)?
  return asn1ReadOctetString(inner)?
}
```

### `classUniversal: int`

Tag class 0: the standard ASN.1 types (INTEGER, SEQUENCE, ...).

### `classApplication: int`

Tag class 1: types specific to an application.

### `classContext: int`

Tag class 2: the `[n]` context-specific tags that disambiguate SEQUENCE members
or CHOICE alternatives.

### `classPrivate: int`

Tag class 3: types specific to an enterprise.

### `tagBoolean: int`

Universal tag number 1, BOOLEAN.

### `tagInteger: int`

Universal tag number 2, INTEGER.

### `tagBitString: int`

Universal tag number 3, BIT STRING.

### `tagOctetString: int`

Universal tag number 4, OCTET STRING.

### `tagNull: int`

Universal tag number 5, NULL.

### `tagOid: int`

Universal tag number 6, OBJECT IDENTIFIER.

### `tagUtf8String: int`

Universal tag number 12, UTF8String.

### `tagSequence: int`

Universal tag number 16, SEQUENCE (always constructed).

### `tagSet: int`

Universal tag number 17, SET (always constructed).

### `tagPrintableString: int`

Universal tag number 19, PrintableString.

### `tagIA5String: int`

Universal tag number 22, IA5String.

### `tagUtcTime: int`

Universal tag number 23, UTCTime.

### `tagGeneralizedTime: int`

Universal tag number 24, GeneralizedTime.

```bit
import { Element, asn1Parse, asn1ReadSequence, classUniversal, tagSequence } from "std/crypto"

// Whether a parsed element is a universal SEQUENCE by inspecting its tag directly.
function isSequence(e: Element): bool {
  return e.cls == classUniversal && e.constructed && e.tag == tagSequence
}
```

## Big integers

Variable-width unsigned big integers — the modular-arithmetic bedrock the
public-key primitives build on (RSA, the NIST curves). A `Nat` is an
arbitrary-precision non-negative integer; its magnitude is unbounded, its
representation always normalized. All routines are total on well-formed input,
failing only where a result cannot exist (a negative difference, a zero modulus,
a non-invertible element) or does not fit a requested fixed width.

The exponentiation entry points split by whether the exponent is secret.
`bigintModExp` defaults to a constant-time Montgomery ladder, so its timing does
not leak the exponent — this is the path for RSA private-key operations and
ECDSA nonces. `bigintModExpPublic` is a faster variable-time square-and-multiply
for public exponents (RSA verification and encryption), and must never be used
with a secret exponent. Likewise `bigintModInverse` is variable-time; for a
secret inverse under a prime modulus use `bigintModExp(a, p-2, p)` (Fermat)
instead.

### `Nat`

A non-negative arbitrary-precision integer, backed by a normalized little-endian
slice of 32-bit limbs (zero is the empty slice). Its field is module-private, so
a `Nat` is built and inspected only through the `bigint*` functions below —
`bigintFromU64` and `bigintFromBytes` in, `bigintToU64` and `bigintToBytes` out.

```bit
import {
  Nat, bigintFromBytes, bigintToBytes, bigintCmp, bigintIsZero, bigintBitLen,
} from "std/crypto"

// Parse a big-endian modulus, and report its width and whether it is nonzero.
function inspect(nBytes: []byte): int {
  let n = bigintFromBytes(nBytes)
  if (bigintIsZero(n)) {
    return 0
  }
  if (bigintCmp(n, n) != 0) {
    return -1
  }
  return bigintBitLen(n)
}

// Re-serialize a Nat to a fixed width, restoring any leading zero bytes.
function fixedWidth(n: Nat, width: int): []byte! {
  return bigintToBytes(n, width)?
}
```

### `QuotRem`

The result of a division: the exported fields `q` (quotient) and `r` (remainder),
both `Nat`. Returned by `bigintDivMod` so a caller in another module can read the
two halves directly.

### `bigintZero(): Nat`

The number zero.

### `bigintFromU64(v: u64): Nat`

The `Nat` equal to the unsigned 64-bit value `v`.

### `bigintToU64(n: Nat): u64!`

The value of `n` as a `u64`; fails if `n` needs more than 64 bits. Intended for
small results and assertions — compare large values as bytes via `bigintToBytes`.

### `bigintIsZero(n: Nat): bool`

Whether `n` is zero.

### `bigintBitLen(n: Nat): int`

The number of significant bits in `n`: 0 for zero, otherwise the position of the
highest set bit plus one.

### `bigintCmp(a: Nat, b: Nat): int`

Compare `a` and `b`: `-1` if `a < b`, `0` if equal, `1` if `a > b`.

### `bigintAdd(a: Nat, b: Nat): Nat`

The sum `a + b`.

### `bigintSub(a: Nat, b: Nat): Nat!`

The difference `a - b`. Fails if `b > a`: a `Nat` is unsigned, so there is no
negative value to return.

### `bigintMul(a: Nat, b: Nat): Nat`

The product `a * b` (schoolbook multiplication).

### `bigintSqr(a: Nat): Nat`

The square `a * a`.

### `bigintDivMod(a: Nat, b: Nat): QuotRem!`

The quotient and remainder of `a / b` (Knuth's Algorithm D). Fails on division by
zero.

### `bigintMod(a: Nat, b: Nat): Nat!`

The non-negative remainder `a mod b`. Fails on a zero modulus.

```bit
import {
  QuotRem, bigintFromU64, bigintDivMod, bigintMod, bigintGcd,
  bigintAdd, bigintSub, bigintMul, bigintSqr, bigintToU64,
} from "std/crypto"

// Long division: 1000 / 7 is quotient 142, remainder 6.
function divide(): QuotRem! {
  return bigintDivMod(bigintFromU64(1000), bigintFromU64(7))?
}

// gcd(48, 36) == 12, and reduce it through the other primitives.
function reduce(): u64! {
  let g = bigintGcd(bigintFromU64(48), bigintFromU64(36))
  let sum = bigintAdd(g, bigintFromU64(0))
  let diff = bigintSub(sum, bigintFromU64(0))?
  let prod = bigintMul(diff, bigintFromU64(1))
  let sq = bigintSqr(prod)
  return bigintToU64(bigintMod(sq, bigintFromU64(1000))?)?
}
```

### `bigintModExp(base: Nat, exp: Nat, modN: Nat): Nat!`

`base^exp mod modN` by a constant-time Montgomery ladder, safe for secret
exponents. Fails on a zero modulus. `modN == 1` gives 0 and a zero exponent gives
1. An even modulus (where Montgomery reduction does not apply) falls back to
variable-time square-and-multiply.

### `bigintModExpPublic(base: Nat, exp: Nat, modN: Nat): Nat!`

`base^exp mod modN` by variable-time square-and-multiply, for a *public*
exponent. Faster than the constant-time path, but it branches on the exponent
bits — use only when the exponent is not secret. Fails on a zero modulus.

```bit
import { Nat, bigintModExp, bigintModExpPublic, bigintFromBytes, bigintToBytes, bigintFromU64 } from "std/crypto"

// RSA public operation c = m^e mod n over big-endian byte strings (e = 65537).
function rsaPublic(mBytes: []byte, nBytes: []byte): []byte! {
  let m = bigintFromBytes(mBytes)
  let n = bigintFromBytes(nBytes)
  let c = bigintModExpPublic(m, bigintFromU64(65537), n)?
  return bigintToBytes(c, len(nBytes))?
}

// RSA private operation m = c^d mod n takes the constant-time ladder.
function rsaPrivate(c: Nat, d: Nat, n: Nat): Nat! {
  return bigintModExp(c, d, n)?
}
```

### `bigintModInverse(a: Nat, n: Nat): Nat!`

The modular inverse of `a` modulo `n`: the value `x` in `[0, n)` with
`a*x = 1 (mod n)`. Fails if `a` and `n` are not coprime or `n == 0`.
Variable-time — for a secret inverse under a prime modulus prefer Fermat's little
theorem via `bigintModExp`.

```bit
import { bigintFromU64, bigintModInverse, bigintToU64 } from "std/crypto"

// The modular inverse of 3 modulo 11 is 4.
function inverse(): u64! {
  return bigintToU64(bigintModInverse(bigintFromU64(3), bigintFromU64(11))?)?
}
```

### `bigintGcd(a: Nat, b: Nat): Nat`

The greatest common divisor of `a` and `b` (Euclid); `gcd(x, 0) = x`.

### `bigintFromBytes(be: []byte): Nat`

The `Nat` whose big-endian encoding is `be`. Leading zero bytes are absorbed by
normalization, so `00 00 01` and `01` yield the same value; an empty slice is
zero. This is the OS2IP direction (RFC 8017).

### `bigintToBytes(n: Nat, outLen: int): []byte!`

`n` as exactly `outLen` big-endian bytes, left-padded with zeros. Fails if `n`
does not fit in `outLen` bytes rather than silently truncating — the safe I2OSP
policy, so a key or point that overflows its field width is caught.

## NIST curves (P-256/P-384)

Elliptic-curve point arithmetic over the two prime-field NIST curves, secp256r1
(P-256) and secp384r1 (P-384), the building block for ECDSA and ECDH. Both curves
have `a = -3` and a prime group order, so a single set of *complete* addition
formulas (Renes–Costello–Batina, 2016) covers every case — the identity, a
doubling, and `P + (-P)` — with no exceptional inputs. Scalar multiplication is a
Montgomery ladder whose accumulators are exchanged by a branchless masked select,
so it has no secret-dependent branch or table index and runs a fixed number of
iterations per curve.

Constant-time scope: the ladder is branch-safe by construction, but the
underlying field arithmetic is the variable-width `Nat` bigint, whose timing
still depends on operand limb counts. Machine-level timing-flat field arithmetic
awaits the fixed-width Montgomery reduction noted for the bigint module; until
then this code resists the classic branch/index side channels but is not a
defense against a limb-timing adversary. Scalars are taken as a `Nat`; a private
key in bytes becomes one with `bigintFromBytes`, and a decoded point is always
validated to lie on the curve before it is multiplied.

```bit
import {
  Point,
  nistecP256, nistecP384, nistecScalarBaseMult, nistecScalarMult,
  nistecPointEncode, nistecPointDecode, nistecIsOnCurve,
  bigintFromBytes,
} from "std/crypto"

// The SEC 1 uncompressed public key for a P-256 private scalar.
function p256PublicKey(privateKey: []byte): []byte! {
  let c = nistecP256()
  let pub = nistecScalarBaseMult(c, bigintFromBytes(privateKey))
  return nistecPointEncode(c, pub, false)?
}

// The ECDH shared secret: decode and validate the peer's point, multiply it by
// our scalar, and return the compressed result.
function p256Ecdh(privateKey: []byte, peerPublic: []byte): []byte! {
  let c = nistecP256()
  let peer = nistecPointDecode(c, peerPublic)?
  let shared = nistecScalarMult(c, peer, bigintFromBytes(privateKey))?
  return nistecPointEncode(c, shared, true)?
}

// P-384 goes through the same API; only the curve constructor changes.
function p384OnCurve(point: Point): bool {
  return nistecIsOnCurve(nistecP384(), point)
}
```

### `Curve`

A curve's domain parameters (field prime, order, coefficients, and base point)
plus the values derived once at construction. The fields are module-private; a
`Curve` is obtained from `nistecP256` / `nistecP384` and passed opaquely to the
point routines.

### `Point`

An affine curve point with exported `Nat` coordinates `x` and `y`, or the point
at infinity when the `infinity` field is set.

### `nistecP256(): Curve`

The NIST P-256 curve (secp256r1 / prime256v1), a 256-bit prime-order curve.

### `nistecP384(): Curve`

The NIST P-384 curve (secp384r1), a 384-bit prime-order curve.

### `nistecScalarBaseMult(curve: Curve, scalar: Nat): Point`

`scalar * G`, the base-point multiplication that derives a public key from a
private scalar. `G` is always valid, so this cannot fail.

### `nistecScalarMult(curve: Curve, point: Point, scalar: Nat): Point!`

`scalar * point`. Rejects an off-curve `point` before multiplying, closing the
invalid-curve attack; the point at infinity maps to itself.

### `nistecIsOnCurve(curve: Curve, point: Point): bool`

Whether `point` satisfies `y^2 = x^3 + a*x + b (mod p)` with both coordinates in
`[0, p)`. The point at infinity is on the curve.

### `nistecPointEncode(curve: Curve, point: Point, compressed: bool): []byte!`

The SEC 1 octet encoding of `point`: a single `0x00` for infinity, the
`0x04 || X || Y` uncompressed form, or — when `compressed` is set — the
`0x02|0x03 || X` compressed form whose prefix carries `y`'s low bit. Fails if a
coordinate does not fit the field width.

### `nistecPointDecode(curve: Curve, data: []byte): Point!`

Decode a SEC 1 octet string (infinity, uncompressed, or compressed) into a
validated affine point; compressed input recovers `y` by a modular square root.
Fails on a bad length, an out-of-range coordinate, an unknown prefix, or a point
that is not on the curve.
## RSA

RSA (PKCS#1 v2.2 / RFC 8017) over the big-integer and ASN.1 layers: the four
schemes — EMSA-PKCS1-v1_5 and EMSA-PSS signatures, RSAES-OAEP and
RSAES-PKCS1-v1_5 encryption — plus parsers for the standard key encodings. Keys
are `RsaPublicKey` / `RsaPrivateKey`; construct them from DER with the parsers,
or from `Nat` fields directly.

Two secret-dependent paths get constant-time care. The private-key operation runs
on the constant-time Montgomery ladder and is **base-blinded** (a fresh random `r`
turns `m^d` into `(m·r^e)^d · r^-1 mod n`), so its timing does not correlate with
the ciphertext. The two **decrypt** padding checks are the Manger (OAEP) and
Bleichenbacher (v1.5) oracle surfaces: both decode branchlessly, fold every check
into one running mask, and reject a malformed ciphertext with a single uniform
`"rsa: decryption error"` — never an early or check-specific failure. CRT (the
p/q fast path) is deferred in v1; the plain `c^d mod n` is used.

The signature and OAEP schemes take a hash *constructor* (`() => Hash`, e.g.
`newSha256` — wrap it as `newSha256` returns the concrete `Sha256`) so one
implementation serves the whole SHA-2 family; the PKCS#1 v1.5 signer additionally
takes the matching `DigestInfo` prefix (`rsaDigestInfoSha256`, ...).

```bit
import {
  RsaPrivateKey, RsaPublicKey, Hash, newSha256,
  rsaSignPkcs1v15, rsaVerifyPkcs1v15, rsaDigestInfoSha256,
} from "std/crypto"

// SHA-256 as a `() => Hash` value (newSha256 returns the concrete Sha256).
function sha256Hash(): Hash { return newSha256() }

// EMSA-PKCS1-v1_5 sign over SHA-256, then verify the signature.
function signAndVerify(priv: RsaPrivateKey, pub: RsaPublicKey, msg: []byte): bool! {
  let sig = rsaSignPkcs1v15(priv, sha256Hash, rsaDigestInfoSha256(), msg)?
  return rsaVerifyPkcs1v15(pub, sha256Hash, rsaDigestInfoSha256(), msg, sig)
}
```

### `RsaPublicKey`

An RSA public key: the exported `Nat` fields `n` (modulus) and `e` (public
exponent). Build one with `rsaParsePublicKey` / `rsaParsePkcs1PublicKey`, or the
struct literal.

### `RsaPrivateKey`

An RSA private key: the exported `Nat` fields `n` (modulus), `e` (public
exponent, used for blinding), and `d` (private exponent). The CRT parameters are
not retained in v1.

### `rsaParsePublicKey(der: []byte): RsaPublicKey!`

Parse a `SubjectPublicKeyInfo` (X.509 / SPKI) DER public key — a `SEQUENCE` of an
`rsaEncryption` `AlgorithmIdentifier` and a `BIT STRING` wrapping the PKCS#1
`RSAPublicKey`. Fails on any structural problem or a non-RSA algorithm.

```bit
import { RsaPublicKey, rsaParsePublicKey } from "std/crypto"

// Load an SPKI (X.509) public key from its DER bytes.
function loadPublicKey(der: []byte): RsaPublicKey! {
  return rsaParsePublicKey(der)?
}
```

### `rsaParsePkcs1PublicKey(der: []byte): RsaPublicKey!`

Parse a PKCS#1 `RSAPublicKey` DER — `SEQUENCE { modulus INTEGER, publicExponent
INTEGER }`. This is the inner structure `rsaParsePublicKey` unwraps.

### `rsaParsePrivateKey(der: []byte): RsaPrivateKey!`

Parse a PKCS#8 `PrivateKeyInfo` (RFC 5958) DER private key — a `SEQUENCE` of a
version, an `rsaEncryption` `AlgorithmIdentifier`, and an `OCTET STRING` wrapping
the PKCS#1 `RSAPrivateKey`. Fails on any structural problem or a non-RSA
algorithm.

```bit
import { RsaPrivateKey, rsaParsePrivateKey } from "std/crypto"

// Load a PKCS#8 private key from its DER bytes.
function loadPrivateKey(der: []byte): RsaPrivateKey! {
  return rsaParsePrivateKey(der)?
}
```

### `rsaParsePkcs1PrivateKey(der: []byte): RsaPrivateKey!`

Parse a PKCS#1 `RSAPrivateKey` DER — `SEQUENCE { version, n, e, d, p, q, dP, dQ,
qInv }`. The CRT fields must be present and well-formed but are not retained; only
`n`, `e`, `d` are kept. This is the inner structure `rsaParsePrivateKey` unwraps.

### `rsaSignPkcs1v15(priv: RsaPrivateKey, newHash: () => Hash, digestInfoPrefix: []byte, message: []byte): []byte!`

An EMSA-PKCS1-v1_5 signature over `message`, hashed by `newHash` with the matching
`digestInfoPrefix` (one of `rsaDigestInfoSha256/384/512`). The signature is `k`
bytes, `k` the modulus length. The private-key operation is constant-time and
base-blinded.

### `rsaVerifyPkcs1v15(pub: RsaPublicKey, newHash: () => Hash, digestInfoPrefix: []byte, message: []byte, sig: []byte): bool`

Whether `sig` is a valid EMSA-PKCS1-v1_5 signature over `message` under `pub`.
Recomputes the expected encoded message and compares; any structural problem
returns false rather than raising.

### `rsaSignPss(priv: RsaPrivateKey, newHash: () => Hash, message: []byte, saltLen: int): []byte!`

An EMSA-PSS (MGF1) signature over `message`, hashed by `newHash`, with a fresh
`saltLen`-byte random salt (the common choice is `saltLen == hash size`). The
signature is `k` bytes.

```bit
import { RsaPrivateKey, RsaPublicKey, Hash, newSha256, rsaSignPss, rsaVerifyPss } from "std/crypto"

function sha256Hash(): Hash { return newSha256() }

// EMSA-PSS sign and verify with a 32-byte salt.
function pssRoundTrip(priv: RsaPrivateKey, pub: RsaPublicKey, msg: []byte): bool! {
  let sig = rsaSignPss(priv, sha256Hash, msg, 32)?
  return rsaVerifyPss(pub, sha256Hash, msg, sig, 32)
}
```

### `rsaVerifyPss(pub: RsaPublicKey, newHash: () => Hash, message: []byte, sig: []byte, saltLen: int): bool`

Whether `sig` is a valid EMSA-PSS signature over `message` under `pub`, expecting
a salt of exactly `saltLen` bytes.

### `rsaEncryptOaep(pub: RsaPublicKey, newHash: () => Hash, message: []byte, label: []byte): []byte!`

RSAES-OAEP encryption with MGF1 over `newHash` and the (usually empty) `label`.
Fails if `message` exceeds `k - 2*hLen - 2` bytes. Prefer OAEP over v1.5 for new
protocols.

```bit
import { RsaPrivateKey, RsaPublicKey, Hash, newSha256, rsaEncryptOaep, rsaDecryptOaep } from "std/crypto"

function sha256Hash(): Hash { return newSha256() }

// RSAES-OAEP encrypt then decrypt with an empty label.
function oaepRoundTrip(pub: RsaPublicKey, priv: RsaPrivateKey, msg: []byte): []byte! {
  let ct = rsaEncryptOaep(pub, sha256Hash, msg, []byte(0))?
  return rsaDecryptOaep(priv, sha256Hash, ct, []byte(0))?
}
```

### `rsaDecryptOaep(priv: RsaPrivateKey, newHash: () => Hash, ciphertext: []byte, label: []byte): []byte!`

RSAES-OAEP decryption. The padding decode is constant-time (Manger): the leading
byte, the label-hash match, and the `PS || 01` separator all fold into one mask
decided once at the end, so a malformed ciphertext yields a single uniform
`"rsa: decryption error"` with data-independent control flow.

### `rsaEncryptPkcs1v15(pub: RsaPublicKey, message: []byte): []byte!`

RSAES-PKCS1-v1_5 encryption: `00 02 || PS || 00 || M` with non-zero random `PS`.
Fails if `message` exceeds `k - 11` bytes. Prefer OAEP for new protocols.

```bit
import { RsaPrivateKey, RsaPublicKey, rsaEncryptPkcs1v15, rsaDecryptPkcs1v15 } from "std/crypto"

// RSAES-PKCS1-v1_5 encrypt then decrypt.
function v15RoundTrip(pub: RsaPublicKey, priv: RsaPrivateKey, msg: []byte): []byte! {
  let ct = rsaEncryptPkcs1v15(pub, msg)?
  return rsaDecryptPkcs1v15(priv, ct)?
}
```

### `rsaDecryptPkcs1v15(priv: RsaPrivateKey, ciphertext: []byte): []byte!`

RSAES-PKCS1-v1_5 decryption. Constant-time (Bleichenbacher): the `00 02` prefix,
the eight-octet minimum on `PS`, and the `00` separator are checked with a single
running mask and one uniform failure, so a padding oracle cannot distinguish
*why* a ciphertext was rejected.

### `rsaDigestInfoSha256(): []byte`

The DER `DigestInfo` prefix for SHA-256 — prepend to a 32-byte digest to form the
`T` of an EMSA-PKCS1-v1_5 encoding. Pass to `rsaSignPkcs1v15` /
`rsaVerifyPkcs1v15`.

### `rsaDigestInfoSha384(): []byte`

The DER `DigestInfo` prefix for SHA-384 (48-byte digest).

### `rsaDigestInfoSha512(): []byte`

The DER `DigestInfo` prefix for SHA-512 (64-byte digest).
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

## NIST ECDH

Elliptic-Curve Diffie-Hellman over the NIST curves P-256 and P-384, layered on
the `nistec` point arithmetic. Each side generates a key pair, exchanges its
SEC 1 public point, and derives the same shared secret — the x-coordinate of the
joint point `d_A * d_B * G`, fixed-width big-endian. Both curves have cofactor 1,
so that x is the raw ECDH secret TLS 1.3 feeds directly to HKDF as input keying
material (no hashing, no cofactor multiplication).

The peer's public point is validated before every use: an off-curve or malformed
SEC 1 encoding, or the identity point, is rejected — the invalid-curve attack
defense. The private scalar is drawn from the OS CSPRNG and reduced into
`[1, n-1]` with the FIPS 186-4 extra-bits method, so it is never zero and never
`>= n`.

```bit
import {
  nistecP256,
  ecdhnistGenerateKeypair, ecdhnistSharedSecret,
} from "std/crypto"

// A full ECDH exchange on P-256. Both sides derive the identical secret; here
// Alice combines her private key with Bob's public key. The returned bytes are
// the raw shared x-coordinate — hand them straight to HKDF as input keying
// material.
function ecdhExchangeP256(): []byte! {
  let c = nistecP256()
  let alice = ecdhnistGenerateKeypair(c)
  let bob = ecdhnistGenerateKeypair(c)
  return ecdhnistSharedSecret(alice.priv, bob.pub, c)?
}
```

### `EcdhKeypair`

An ECDH key pair. `priv` is the private scalar as exactly `curve.size` big-endian
bytes; `pub` is the SEC 1 *uncompressed* public point `0x04 || X || Y` of
`priv * G`. Both fields are exported.

### `ecdhnistGenerateKeypair(curve: Curve): EcdhKeypair`

Generate a fresh key pair on `curve`. The private scalar comes from the OS CSPRNG
reduced into `[1, n-1]` (FIPS 186-4 extra-bits), and the public key is the SEC 1
uncompressed encoding of `priv * G`.

### `ecdhnistSharedSecret(priv: []byte, peerPub: []byte, curve: Curve): []byte!`

The raw ECDH shared secret: the fixed-width big-endian x-coordinate of
`priv * peerPoint`, where `peerPub` is the peer's SEC 1 public point. Validates
that the peer point is on the curve and is not the identity before multiplying —
closing the invalid-curve attack — and fails on any malformed, off-curve, or
identity input.

## ECDSA

The Elliptic Curve Digital Signature Algorithm (FIPS 186-4 / SEC 1) over the
NIST P-256 and P-384 curves, built on the `nistec` point arithmetic, the `bigint`
integers, the `asn1` DER codec, and `hmac`. Sign a pre-computed digest, verify a
signature, handle keys, and serialize a signature as the standard
`SEQUENCE { INTEGER r, INTEGER s }`.

The nonce is **RFC 6979 deterministic** — derived by HMAC-DRBG from the private
key and the message digest rather than drawn at random. A biased or repeated
ECDSA nonce discloses the private key, so removing randomness removes that whole
failure class; it also makes signatures reproducible, which is what lets them be
checked against fixed known-answer vectors (the P-256/SHA-256 and P-384/SHA-384
"sample" vectors of RFC 6979 A.2.5 / A.2.6). The secret nonce is inverted in
constant time via Fermat's little theorem on the constant-time modular-exponent
ladder; the scalar multiplications use `nistec`'s branchless Montgomery ladder.
As in `nistec`, the field arithmetic is not yet timing-flat at the limb level, so
this is branch-safe but not a defence against a limb-timing adversary.

The signature is **not** low-`s` normalized: the standard accepts any `s` in
`[1, n-1]` and the RFC 6979 vectors are themselves high-`s`. A protocol that
requires canonical low-`s` (e.g. BIP-62) can replace `s` with `n - s` when
`s > n/2`; verification accepts either form. The digest is caller-supplied — hash
the message with SHA-256 (P-256) or SHA-384 (P-384) and pass the digest bytes
plus the matching hash constructor (RFC 6979 keys its HMAC on the same hash).

```bit
import {
  Curve, EcdsaPublicKey,
  ecdsaPrivateKey, ecdsaSign, ecdsaVerify,
  ecdsaSignatureToDer, ecdsaSignatureFromDer,
  Hash, newSha256,
} from "std/crypto"

// SHA-256 as a `() => Hash` value (newSha256 returns the concrete Sha256).
function sha256Hash(): Hash { return newSha256() }

// Deterministically sign a SHA-256 digest, DER-encode and re-parse the
// signature, and verify it against the derived public key.
function signAndVerify(curve: Curve, scalar: []byte, digest: []byte): bool! {
  let priv = ecdsaPrivateKey(curve, scalar)?
  let sig = ecdsaSign(priv, digest, sha256Hash)?
  let der = ecdsaSignatureToDer(sig)
  let parsed = ecdsaSignatureFromDer(der)?
  let pub = EcdsaPublicKey{ curve: curve, q: priv.q }
  return ecdsaVerify(pub, digest, parsed)
}
```

### `EcdsaPublicKey`

An ECDSA public key: the exported `curve: Curve` it lives on and the public point
`q: Point` (`q = d*G`). Build one from a SEC 1 point encoding with `ecdsaPublicKey`,
or from a private key's `q` field via the struct literal.

### `EcdsaPrivateKey`

An ECDSA private key: the exported `curve: Curve`, the secret scalar `d: Nat` in
`[1, n-1]`, and the cached public point `q: Point`. Build one with
`ecdsaPrivateKey` or `ecdsaGenerateKey`.

### `EcdsaSignature`

An ECDSA signature: the exported `Nat` fields `r` and `s`, each in `[1, n-1]`.
Serialize with `ecdsaSignatureToDer` and parse with `ecdsaSignatureFromDer`.

### `ecdsaPublicKey(curve: Curve, sec1: []byte): EcdsaPublicKey!`

The public key whose point is the SEC 1 octet string `sec1` (uncompressed
`0x04 || X || Y` or compressed `0x02|0x03 || X`) on `curve`. The point is validated
to lie on the curve; the point at infinity is rejected.

### `ecdsaPrivateKey(curve: Curve, scalar: []byte): EcdsaPrivateKey!`

The private key whose scalar is the big-endian octet string `scalar` on `curve`,
with its public point derived. Fails unless the scalar is in `[1, n-1]`.

### `ecdsaGenerateKey(curve: Curve): EcdsaPrivateKey`

A freshly generated private key on `curve`, its scalar drawn uniformly from
`[1, n-1]` via the OS CSPRNG (rejection sampling, no modulo bias). Read `priv.q`
for the matching public point.

### `ecdsaSign(priv: EcdsaPrivateKey, hash: []byte, newHash: () => Hash): EcdsaSignature!`

Sign the pre-computed digest `hash` under `priv`, returning `(r, s)`. The nonce is
RFC 6979 deterministic with HMAC over `newHash`, which must be the same hash
family used to produce `hash` (`newSha256` for a SHA-256 digest, `newSha384` for
SHA-384). Only the leftmost `bitlen(n)` bits of the digest are used, so any digest
length is accepted. The signature is not low-`s` normalized.

### `ecdsaVerify(pub: EcdsaPublicKey, hash: []byte, sig: EcdsaSignature): bool`

Whether `sig` is a valid signature of the digest `hash` under `pub`. Rejects an
`r` or `s` outside `[1, n-1]`, an off-curve or infinite public point, and any
signature whose recovered `x` does not match `r`. Never fails — a malformed input
is simply `false`.

### `ecdsaSignatureToDer(sig: EcdsaSignature): []byte`

The DER encoding of `sig`: `SEQUENCE { INTEGER r, INTEGER s }`, the standard X.509
/ TLS signature form. Each integer is minimally encoded, with a `0x00` sign octet
when its top bit is set.

### `ecdsaSignatureFromDer(der: []byte): EcdsaSignature!`

Parse a DER `SEQUENCE { INTEGER r, INTEGER s }` back into a signature. Fails on any
structure that is not exactly two INTEGERs, on a negative or non-minimally encoded
integer (the strict `asn1` reader enforces this), or on a zero `r`/`s`.
## PEM

PEM (RFC 7468) is the textual wrapper that carries DER-encoded objects —
certificates, public and private keys — as ASCII. Each object is one *block*:

```
-----BEGIN CERTIFICATE-----
<base64 of the DER, wrapped at 64 columns>
-----END CERTIFICATE-----
```

`pemEncode` builds one block from a label and its DER; `pemDecode` parses one or
more concatenated blocks back into `PemBlock` values, so a file holding a
certificate followed by its key parses in a single call. The two are inverse:
`pemDecode(pemEncode(label, der))[0].der` is `der`.

Decoding is strict — a lax PEM reader is a classic parser attack surface. The
END label must match its BEGIN, a block with no END line is a truncation error,
and the base64 body must be valid. Line endings are tolerant: CRLF, LF, and stray
spaces or tabs inside the body are stripped before the base64 is decoded, so PEM
produced on Windows or Unix parses the same.

```bit
import { pemEncode, pemDecode, PemBlock } from "std/crypto"

// Wrap DER bytes as a PEM "CERTIFICATE" block — the text you would write to a
// .pem or .crt file, base64 wrapped at 64 columns with the BEGIN/END framing.
function certToPem(der: []byte): string {
  return pemEncode("CERTIFICATE", der)
}

// The first block of a PEM file: its label and decoded DER. Fails on malformed
// framing, a mismatched END label, or an invalid base64 body.
function firstBlock(pem: string): PemBlock! {
  let blocks = pemDecode(pem)?
  return blocks[0]
}
```

### `PemBlock`

One decoded PEM block. `label` is the object type from its BEGIN/END markers
(e.g. `"CERTIFICATE"`, `"PRIVATE KEY"`), and `der` is the raw DER its base64 body
decoded to. Both fields are exported.

### `pemEncode(label: string, der: []byte): string`

Encodes `der` as one PEM block of type `label`: the `-----BEGIN label-----` /
`-----END label-----` framing around the standard `=`-padded base64 of `der`,
wrapped at 64 columns and LF-terminated.

### `pemDecode(pem: string): []PemBlock!`

Parses one or more concatenated PEM blocks from `pem`, in order; text before,
between, or after blocks is ignored. Tolerates CRLF and LF line endings. Fails on
a block whose END line is missing (truncated) or whose END label does not match
its BEGIN label, and on a body that is not valid base64.
## BLAKE3

BLAKE3 (the official specification) hashes a message through a binary Merkle tree
of 1024-byte chunks, reduced by a seven-round compression function over a 16-word
`u32` state. It is fast, and it is an extendable-output function (XOF): the same
hasher yields a 32-byte digest by default or any number of bytes on demand. Three
keying modes share one code path — the default hash, `keyed_hash` (a 32-byte-keyed
MAC), and `derive_key` (a KDF seeded by a context string). Every value is read and
written little-endian, so output is byte-identical on x86-64 and ARM64, and every
result is verified against the official BLAKE3 test vectors.

`Blake3` is a streaming hasher: feed bytes with any number of `write` calls, then
read the digest with `sum` (32 bytes) or `finalize(n)` (an arbitrary-length XOF
draw). It conforms structurally to `Hash`, so it drops into `digest`, `hmac`, and
`hkdf` unchanged. Tree hashing here is single-threaded, and memory stays bounded
regardless of message length. Reuse one hasher for many messages by calling
`reset` between them.

```bit
import {
  Hash, digest, encodeHex,
  newBlake3, newBlake3Keyed, newBlake3DeriveKey,
  blake3Hash, blake3KeyedHash, blake3Xof,
} from "std/crypto"

// One-shot 32-byte digest, rendered as a lowercase hex string.
function fingerprint(data: []byte): string {
  return encodeHex(blake3Hash(data))
}

// Streaming: feed input across as many `write` calls as convenient, read `sum`.
function streamed(): []byte {
  let h = newBlake3()
  h.write([]byte("BLAKE3 "))
  h.write([]byte("streaming"))
  return h.sum()
}

// A keyed MAC (BLAKE3's keyed_hash) under a 32-byte key.
function mac(key: []byte, msg: []byte): []byte! {
  return blake3KeyedHash(key, msg)?
}

// The same keyed MAC, built as a streaming hasher.
function keyedStream(key: []byte): []byte! {
  let h = newBlake3Keyed(key)?
  h.write([]byte("authenticated data"))
  return h.sum()
}

// Key derivation: a subkey from a context string and input key material.
function subkey(material: []byte): []byte {
  let h = newBlake3DeriveKey("example.com 2026 session-key")
  h.write(material)
  return h.finalize(32)
}

// Extendable output: draw a 64-byte key stream from the default hash.
function widen(seed: []byte): []byte {
  return blake3Xof(seed, 64)
}

// Hashing against the `Hash` interface — the algorithm is a parameter, so BLAKE3
// drops into any `Hash`-based helper (HMAC, HKDF, `digest`) unchanged.
function tag(h: Hash, msg: []byte): string {
  return encodeHex(digest(h, msg))
}
```

### `Blake3`

A streaming BLAKE3 hasher and XOF, conforming structurally to `Hash`. Build one
with `newBlake3`, `newBlake3Keyed`, or `newBlake3DeriveKey`; do not construct it
by field.

### `newBlake3(): Blake3`

A fresh unkeyed BLAKE3 hasher — the default hash function.

### `newBlake3Keyed(key: []byte): Blake3!`

A fresh keyed hasher (BLAKE3's `keyed_hash`, a MAC). `key` must be exactly 32
bytes; its little-endian words become the initial key words. Fails otherwise.

### `newBlake3DeriveKey(context: string): Blake3`

A fresh derive-key hasher (BLAKE3's `derive_key`). The context is hashed once in
context mode; its chaining value keys the hashing of the key material fed next.
`context` should be a hardcoded, globally unique application string — not a
runtime secret or variable.

### `Blake3.write(data: []byte)`

Absorbs more input into the running hash.

### `Blake3.sum(): []byte`

The 32-byte default digest of everything written since the last `reset` — exactly
`finalize(32)`. Non-destructive, so the hasher may keep accepting input afterward.

### `Blake3.finalize(n: int): []byte`

Draws `n` output bytes (the XOF). Non-destructive, so the hasher may keep
absorbing afterward. The first `n` bytes are the same for any larger `n`; a
non-positive `n` yields an empty slice.

### `Blake3.reset()`

Returns the hasher to the empty message, keeping its mode (the key or derive-key
words and flags).

### `Blake3.size(): int`

The default digest length in bytes (32).

### `Blake3.blockSize(): int`

The internal block size in bytes (64) — the value HMAC needs.

### `blake3Hash(data: []byte): []byte`

One-shot BLAKE3: the 32-byte default digest of `data`.

### `blake3KeyedHash(key: []byte, data: []byte): []byte!`

One-shot BLAKE3 keyed hash: the 32-byte MAC of `data` under the 32-byte `key`.
Fails if the key is not exactly 32 bytes.

### `blake3DeriveKey(context: string, keyMaterial: []byte): []byte`

One-shot BLAKE3 key derivation: a 32-byte key derived from `keyMaterial` under the
given `context` string.

### `blake3Xof(data: []byte, n: int): []byte`

One-shot BLAKE3 XOF: `n` output bytes of the default hash of `data`. For `n == 32`
this equals `blake3Hash(data)`.

## Curve25519 field

Arithmetic in the prime field GF(2^255 - 19), the field underneath Curve25519.
A field element is a `[]u64` of length 5 — the value in radix 2^51, five 51-bit
limbs, little-endian. The representation is redundant between operations (limbs
carry a few spare bits); `fe25519ToBytes` performs the one canonical reduction to
the unique 0..p-1 representative. All operations are constant-time: no branch or
memory access depends on a field value. These primitives are the building blocks
for X25519 and Ed25519.

Elements are decoded from 32 little-endian bytes with `fe25519FromBytes` and
re-encoded canonically with `fe25519ToBytes`; the arithmetic operations consume
and produce the 5-limb form.

```bit
import {
  fe25519FromBytes, fe25519ToBytes, fe25519Add, fe25519Sub,
  fe25519Mul, fe25519Sqr, fe25519Mul121666, fe25519Invert,
} from "std/crypto"

// a * a^-1 == 1, checked by comparing canonical encodings: 1 is the byte 0x01
// followed by 31 zero bytes.
function isInverse(scalar: []byte): bool {
  let a = fe25519FromBytes(scalar)
  let one = fe25519ToBytes(fe25519Mul(a, fe25519Invert(a)))
  if (one[0] != 1) {
    return false
  }
  let i = 1
  while (i < 32) {
    if (one[i] != 0) {
      return false
    }
    i = i + 1
  }
  return true
}

// (a + b)(a - b) + 121666 * a^2, exercising the remaining operations.
function combine(xBytes: []byte, yBytes: []byte): []byte {
  let a = fe25519FromBytes(xBytes)
  let b = fe25519FromBytes(yBytes)
  let diffProd = fe25519Mul(fe25519Add(a, b), fe25519Sub(a, b))
  let scaled = fe25519Mul121666(fe25519Sqr(a))
  return fe25519ToBytes(fe25519Add(diffProd, scaled))
}
```

### `fe25519FromBytes(s: []byte): []u64`

Decode 32 little-endian bytes into a field element (five 51-bit limbs). Bit 255
of the input is ignored, matching the Curve25519 wire convention; the value is
taken mod 2^255 and later reduced mod p by `fe25519ToBytes`. `s` must be at least
32 bytes.

### `fe25519ToBytes(f: []u64): []byte`

Fully reduce `f` mod p = 2^255 - 19 and serialize it as 32 little-endian bytes —
the unique canonical encoding, with bit 255 always clear. The reduction is
constant-time; two representations of the same field element always encode to the
same bytes.

### `fe25519Add(f: []u64, g: []u64): []u64`

Field addition, `(f + g) mod p`. The result is loosely reduced and safe to feed
straight into any other field operation.

### `fe25519Sub(f: []u64, g: []u64): []u64`

Field subtraction, `(f - g) mod p`. A multiple of p is added before subtracting
so the unsigned limb arithmetic never underflows; the result is loosely reduced.

### `fe25519Mul(f: []u64, g: []u64): []u64`

Field multiplication, `(f * g) mod p`. Schoolbook 5×5 limb products with the
2^255 = 19 wrap-around fold, accumulated in 128-bit columns and carried back to
51-bit limbs.

### `fe25519Sqr(f: []u64): []u64`

Field squaring, `(f * f) mod p`. Equivalent to `fe25519Mul(f, f)`; provided
separately because inversion and the Montgomery ladder square far more often than
they multiply.

### `fe25519Mul121666(f: []u64): []u64`

Multiply by the curve constant 121666, `(121666 * f) mod p`. This is the scalar
step of the X25519 Montgomery ladder.

### `fe25519Invert(z: []u64): []u64`

Field inverse, `z^(-1) mod p`, computed as `z^(p-2)` by Fermat's little theorem
using the standard Curve25519 addition chain (constant-time). The inverse of 0 is
0.

## Ed25519

EdDSA signatures over the edwards25519 curve (RFC 8032, PureEdDSA), built on the
Curve25519 field arithmetic above and SHA-512. Keys and signatures are the RFC
8032 byte strings, so they interoperate with any other Ed25519 implementation: a
private key is a 32-byte seed, a public key is 32 bytes, a signature is 64 bytes.

Signing is deterministic — the per-signature nonce is derived from the private
key and message, so no random number generator is involved and the same key and
message always produce the same signature. Verification rejects malformed inputs:
a wrong-length key or signature, a non-canonically encoded point, and a scalar `S`
that is not fully reduced mod the group order (`S >= L`) all fail rather than
being accepted. The secret-dependent scalar multiplication is constant-time.

```bit
import { ed25519PublicKey, ed25519Sign, ed25519Verify } from "std/crypto"

// Derive the public key, sign a message, and confirm the signature verifies.
function signAndVerify(seed: []byte, msg: []byte): bool {
  let pub = ed25519PublicKey(seed)
  let sig = ed25519Sign(seed, msg)
  return ed25519Verify(pub, msg, sig)
}

// A single flipped bit in the signature must make verification fail.
function rejectsTamperedSignature(seed: []byte, msg: []byte): bool {
  let pub = ed25519PublicKey(seed)
  let sig = ed25519Sign(seed, msg)
  sig[0] = sig[0] ^ 0x01
  return !ed25519Verify(pub, msg, sig)
}
```

### `ed25519PublicKey(priv: []byte): []byte`

The 32-byte public key for the 32-byte private seed `priv`. The key is `[a]B`,
where `B` is the curve base point and `a` is the clamped lower half of
`SHA-512(priv)`.

### `ed25519Sign(priv: []byte, msg: []byte): []byte`

Sign `msg` with the 32-byte private seed `priv`, returning the 64-byte signature
`R || S`. Deterministic: the nonce is `H(prefix || msg)` for the key's secret
prefix, so signing needs no randomness and is reproducible.

### `ed25519Verify(pub: []byte, msg: []byte, sig: []byte): bool`

Verify the 64-byte signature `sig` on `msg` under the 32-byte public key `pub`.
Returns `false` for a wrong-length input, a non-canonical point encoding, a
non-canonical scalar (`S >= L`), or a signature that fails the group equation.
