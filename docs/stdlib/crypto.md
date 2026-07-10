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
