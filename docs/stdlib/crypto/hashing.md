# Hash passwords and fingerprint content

Inkwell needs password checks, unpredictable tokens and fingerprints of saved
content. Choose the operation for the job, then use the reference below.

<!-- doctest: per-block -->

## Hash a password

Never store a password itself, and never hash it with a plain, fast hash like
SHA-256: a leaked database of fast hashes can be brute-forced on ordinary
hardware in hours. `argon2Hash` runs a hash that is deliberately slow and
memory-hungry, and returns one self-contained string that carries the salt and
cost alongside the result, so you do not have to store them separately.

```bit
import { argon2Hash, argon2Verify, randomBytes } from "std/crypto"

// t (time cost), m (memory in KiB), p (parallelism) and the 32-byte output
// length are the Argon2id defaults: 64 MiB and three passes is a reasonable
// floor for a server; raise m if the hardware and login volume allow it.
fn hashPassword(password: string): string {
  let salt = randomBytes(16)
  return argon2Hash([]byte(password), salt, 3, 65536, 1, 32)
}

fn checkPassword(password: string, stored: string): bool {
  return argon2Verify([]byte(password), stored)
}
```

`argon2Verify` re-derives the hash from the stored parameters and compares it
in constant time, so it never leaks timing information about *how much* of
the password was wrong. It returns `false` for any malformed input rather
than failing, so a corrupted stored value reads as "wrong password", never as
a crash.

`bcryptHash`/`bcryptVerify` and `scrypt` are the same shape for interop with
older systems; prefer Argon2id for anything new.

## Generate random tokens

`randomBytes` reads from the operating system's secure random source, never
a plain pseudo-random generator, so its output is safe to use as a key, a
nonce, or an unguessable id.

```bit
import { randomBytes, encodeHex } from "std/crypto"

// A 16-byte random id, printed as 32 hex characters.
fn newDraftId(): string {
  return encodeHex(randomBytes(16))
}
```

`encodeBase64Url` is a shorter alternative when the token goes in a URL.

## Fingerprint content

A hash turns any amount of data into a short, fixed-size fingerprint: the
same input always produces the same output, and changing even one byte
changes the whole result. Use it to detect whether a draft's body changed
since it was last saved, not to protect a password (see
[Hash a password](#hash-a-password)).

```bit
import { digest, Sha256 } from "std/crypto"

fn contentHash(body: string): []byte {
  return digest(Sha256(), []byte(body))
}
```

`Sha256()` builds a hasher that satisfies `Hash`, the streaming interface every
digest in this module satisfies: call `write` any number of times and `sum` when
you are done, or use `digest` for the common single-buffer case. Every digest is
a class built by calling its name: `Sha256(Sha256Bits.B224)` is SHA-224,
`Sha512(Sha512Bits.B384)` is SHA-384, `Sha3(Sha3Bits.B512)` is SHA3-512. `Blake3`
(`Blake3()`/`blake3Hash`) is faster on large inputs and also supports keyed
hashing and a variable-length output; `Blake2b`, SHA-512, SHA-3, and the
legacy SHA-1 and MD5 (interop only, never for anything security-relevant) are
also available. Content hashes are not secret, so comparing them with `==` is
fine; a MAC or password hash is different (see below).

Another width, or another algorithm in the same family, is an option on the same
constructor, never a different function name:

```bit
import {
  digest, encodeHex, Md5, Sha1, Sha256, Sha256Bits, Sha512, Sha512Bits, Sha3, Sha3Bits,
  Shake, ShakeSecurity, Blake2b, Blake2s, Blake3, Blake3Mode,
} from "std/crypto"

// A cache validator for an exported draft: nobody attacks it, so the cheap,
// legacy MD5 is enough. Anything a stranger could forge needs SHA-256 or better.
fn etag(body: string): string {
  return encodeHex(digest(Md5(), []byte(body)))
}

// Each variant is the same call with one option.
fn variants(body: string): []string! {
  let data = []byte(body)
  let author = [32]byte([]byte("32 bytes of secret key material!"))?
  let keyed = Blake3(Blake3Mode.Keyed(author))
  let sketch = Shake(ShakeSecurity.S256)
  sketch.absorb(data)
  return []string{
    encodeHex(digest(Sha1(), data)),
    encodeHex(digest(Sha256(Sha256Bits.B224), data)),
    encodeHex(digest(Sha512(Sha512Bits.B384), data)),
    encodeHex(digest(Sha3(Sha3Bits.B512), data)),
    encodeHex(digest(Blake2b(32, []byte(0)), data)),
    encodeHex(digest(Blake2s(16, []byte(0)), data)),
    encodeHex(digest(keyed, data)),
    encodeHex(sketch.squeeze(16)),
  }
}
```

When a draft MAC key arrives as bytes, validate it once with `[32]byte(bytes)?`
or `catch`. A length other than 32 fails with
`array conversion length mismatch: expected 32, found N`; the converted key
is an independent copy. `Blake3(Blake3Mode.Keyed(key))` then cannot fail.

For a single draft, the slice-taking helper checks the key for you and keeps
its existing error message, `Blake3: key must be 32 bytes, got N`:

```bit
import { blake3KeyedHash } from "std/crypto"

fn draftMac(keyBytes: []byte, body: string): []byte! {
  return blake3KeyedHash(keyBytes, []byte(body))?
}
```

### Name the hash with a `HashAlg`

`hmac`, `hkdf`, `pbkdf2` and `ecdsaSign` take the hash as a `HashAlg` value, the
way Node's `createHmac("sha256", key)` and .NET's `HashAlgorithmName` do, so a
call reads `hmac(HashAlg.Sha256, key, msg)`. The variants are `Md5`, `Sha1`,
`Sha224`, `Sha256`, `Sha384`, `Sha512`, `Sha512_256` and `Blake3`. A value picked
at run time (for example a protocol's negotiated cipher suite) is passed along
unchanged, and `make()` builds a fresh hasher of that algorithm when you want
to hash directly:

```bit
import { HashAlg, digest, hmac, hkdf, encodeHex } from "std/crypto"

// The same API for every digest: only the `HashAlg` value changes.
fn tag(alg: HashAlg, key: []byte, body: string): string {
  return encodeHex(hmac(alg, key, []byte(body)))
}

// HashAlg.Sha384.make() is Sha512(Sha512Bits.B384); both satisfy `Hash`.
fn fingerprint(body: string): string {
  return encodeHex(digest(HashAlg.Sha384.make(), []byte(body)))
}

fn sessionKey(secret: []byte, context: string): []byte! {
  return hkdf(HashAlg.Sha256, []byte(0), secret, []byte(context), 32)?
}
```

## Hashing

### `Hash`

The streaming digest interface every hash in this module satisfies: `write` any number of times, then `sum` when you are done. `reset` starts over, `size` is the digest length in bytes, and `blockSize` is the algorithm's internal block size.

### `HashAlg`

Names a hash algorithm as a value: `Md5`, `Sha1`, `Sha224`, `Sha256`, `Sha384`, `Sha512`, `Sha512_256` or `Blake3`. `hmac`, `hkdf`, `pbkdf2` and `ecdsaSign` take one, and `HashAlg.Sha256.make()` builds a fresh `Hash` of that algorithm.

### `HashAlg.make(): Hash`

Builds a new, empty hasher for this algorithm: `HashAlg.Sha384.make()` is `Sha512(Sha512Bits.B384)`.

### `digest(h: Hash, data: []byte): []byte`

Resets `h`, writes `data` once, and returns `h.sum()`. The convenience call for hashing one buffer in a single line.

### `Sha256`

A SHA-256 or SHA-224 hasher. `Sha256()` starts a new SHA-256 hash; `Sha256(Sha256Bits.B224)` starts SHA-224, SHA-256's shorter sibling. It satisfies `Hash`.

### `Sha256Bits`

Which SHA-2 digest a `Sha256` computes: `B256` (the default) or `B224`.

### `Sha256.write(data: []byte)`

Feeds more data into the running SHA-256/SHA-224 state. Call it any number of times before `sum`.

### `Sha256.sum(): []byte`

Returns the SHA-256/SHA-224 digest for everything written so far, without resetting the state.

### `Sha256.reset()`

Returns this SHA-256/SHA-224 hash to its empty starting state, so the same value can hash another message.

### `Sha256.size(): int`

The SHA-256/SHA-224 digest length in bytes.

### `Sha256.blockSize(): int`

The SHA-256/SHA-224 algorithm's internal block size in bytes.

### `Sha1`

A SHA-1 hasher: `Sha1()` starts a new hash. Kept for reading data written by older systems; do not use it to protect anything new. It satisfies `Hash`.

### `Sha1.write(data: []byte)`

Feeds more data into the running SHA-1 state. Call it any number of times before `sum`.

### `Sha1.sum(): []byte`

Returns the SHA-1 digest for everything written so far, without resetting the state.

### `Sha1.reset()`

Returns this SHA-1 hash to its empty starting state, so the same value can hash another message.

### `Sha1.size(): int`

The SHA-1 digest length in bytes.

### `Sha1.blockSize(): int`

The SHA-1 algorithm's internal block size in bytes.

### `Md5`

An MD5 hasher: `Md5()` starts a new hash. Kept for reading data written by older systems; do not use it to protect anything new. It satisfies `Hash`.

### `Md5.write(data: []byte)`

Feeds more data into the running MD5 state. Call it any number of times before `sum`.

### `Md5.sum(): []byte`

Returns the MD5 digest for everything written so far, without resetting the state.

### `Md5.reset()`

Returns this MD5 hash to its empty starting state, so the same value can hash another message.

### `Md5.size(): int`

The MD5 digest length in bytes.

### `Md5.blockSize(): int`

The MD5 algorithm's internal block size in bytes.

### `Sha512`

A SHA-512-family hasher. `Sha512()` starts a new SHA-512 hash; `Sha512(Sha512Bits.B384)` starts SHA-384, SHA-512's shorter sibling; `Sha512(Sha512Bits.B256)` starts SHA-512/256, SHA-512's internal state truncated to a 256-bit output. It satisfies `Hash`.

### `Sha512Bits`

Which SHA-512-family digest a `Sha512` computes: `B512` (the default), `B384`, or `B256` for SHA-512/256.

### `Sha512.write(data: []byte)`

Feeds more data into the running SHA-512 state. Call it any number of times before `sum`.

### `Sha512.sum(): []byte`

Returns the SHA-512 digest for everything written so far, without resetting the state.

### `Sha512.reset()`

Returns this SHA-512 hash to its empty starting state, so the same value can hash another message.

### `Sha512.size(): int`

The SHA-512 digest length in bytes.

### `Sha512.blockSize(): int`

The SHA-512 algorithm's internal block size in bytes.

### `Sha3`

A SHA-3 hasher. `Sha3()` starts SHA3-256; pass a `Sha3Bits` for another width, for example `Sha3(Sha3Bits.B512)`. Use it through `write`/`sum` like any `Hash`.

### `Sha3Bits`

The SHA-3 digest width: `B224`, `B256` (the default), `B384`, or `B512`.

### `Sha3.write(data: []byte)`

Feeds more data into the running SHA-3 state. Call it any number of times before `sum`.

### `Sha3.sum(): []byte`

Returns the SHA-3 digest for everything written so far, without resetting the state.

### `Sha3.reset()`

Returns this SHA-3 hash to its empty starting state, so the same value can hash another message.

### `Sha3.size(): int`

The SHA-3 digest length in bytes.

### `Sha3.blockSize(): int`

The SHA-3 algorithm's internal block size in bytes.

### `Shake`

SHAKE, a hash whose output length you choose (`Shake()` is SHAKE128, `Shake(ShakeSecurity.S256)` is SHAKE256): `absorb` input, then `squeeze(n)` as many times as you like for `n` more bytes of output.

### `Shake.absorb(data: []byte)`

Feeds more data into the running SHAKE state. Call `squeeze` once you are done absorbing input.

### `Shake.squeeze(n: int): []byte`

Draws `n` more bytes of output from this SHAKE state. Call it again for more output; the stream continues from where the last call left off.

### `ShakeSecurity`

The SHAKE security level: `S128` (the default) or `S256`.

### `Blake2b`

A BLAKE2b hasher. `Blake2b()` starts a 64-byte unkeyed hash; `Blake2b(outLen, key)` picks the output length (1 to 64 bytes) and an optional key (up to 64 bytes) for use as a MAC, and panics on an out-of-range length. Use it through `write`/`sum` like any `Hash`.

### `Blake2b.write(data: []byte)`

Feeds more data into the running BLAKE2b state. Call it any number of times before `sum`.

### `Blake2b.sum(): []byte`

Returns the BLAKE2b digest for everything written so far, without resetting the state.

### `Blake2b.reset()`

Returns this BLAKE2b hash to its empty starting state, so the same value can hash another message.

### `Blake2b.size(): int`

The BLAKE2b digest length in bytes.

### `Blake2b.blockSize(): int`

The BLAKE2b algorithm's internal block size in bytes.

### `blake2b(data: []byte): []byte`

The one-shot BLAKE2b hash of `data`, 64 bytes long.

### `Blake2s`

BLAKE2b's sibling, tuned for 32-bit hardware. `Blake2s()` starts a 32-byte unkeyed hash; `Blake2s(outLen, key)` picks the output length (1 to 32 bytes) and an optional key (up to 32 bytes), and panics on an out-of-range length. The same shape as `Blake2b`: `write`/`sum`/`reset`.

### `Blake2s.write(data: []byte)`

Feeds more data into the running BLAKE2s state. Call it any number of times before `sum`.

### `Blake2s.sum(): []byte`

Returns the BLAKE2s digest for everything written so far, without resetting the state.

### `Blake2s.reset()`

Returns this BLAKE2s hash to its empty starting state, so the same value can hash another message.

### `Blake2s.size(): int`

The BLAKE2s digest length in bytes.

### `Blake2s.blockSize(): int`

The BLAKE2s algorithm's internal block size in bytes.

### `Blake3`

For a draft digest, use `Blake3()`; for a draft MAC, use
`Blake3(Blake3Mode.Keyed(key))` with a `[32]byte` key.
`Blake3(Blake3Mode.DeriveKey(context))` derives keys for the given context
string. All three constructors are infallible. Convert a dynamic byte slice
with `[32]byte(bytes)?` before keyed construction.

### `Blake3Mode`

How a `Blake3` hasher is keyed: `Hash` (the default, unkeyed), `Keyed(key)` or `DeriveKey(context)`. One constructor takes exactly one mode, so a hasher cannot be both keyed and derive-key.

### `Blake3.write(data: []byte)`

Feeds more data into the running BLAKE3 state. Call it any number of times before `sum`.

### `Blake3.sum(): []byte`

Returns the BLAKE3 digest for everything written so far, without resetting the state.

### `Blake3.reset()`

Returns this BLAKE3 hash to its empty starting state, so the same value can hash another message.

### `Blake3.size(): int`

The BLAKE3 digest length in bytes.

### `Blake3.blockSize(): int`

The BLAKE3 algorithm's internal block size in bytes.

### `Blake3.finalize(n: int): []byte`

Draws `n` bytes of output from this BLAKE3 state, beyond the default 32-byte `sum()`. Call it again for more output from the same point.

### `blake3KeyedHash(key: []byte, data: []byte): []byte!`

The one-shot keyed BLAKE3 hash of `data` under `key`. Fails if `key` is not 32 bytes.

### `blake3DeriveKey(context: string, keyMaterial: []byte): []byte`

Derives a key from `keyMaterial` in the given `context` using BLAKE3's key-derivation mode, in one call.

### `blake3Hash(data: []byte): []byte`

The one-shot, unkeyed BLAKE3 hash of `data`, 32 bytes long.

### `blake3Xof(data: []byte, n: int): []byte`

`n` bytes of BLAKE3's extendable output for `data`, in one call.

## MACs and key derivation

### `hmac(alg: HashAlg, key: []byte, msg: []byte): []byte`

The HMAC of `msg` under `key`, using the hash `alg` names (for example `HashAlg.Sha256`). Use it to prove a message came from someone who holds `key`.

### `hmacEqual(a: []byte, b: []byte): bool`

Compares two MAC tags in constant time (an alias for `ctEq`, see [Compare secrets in constant time](../crypto.md#security-notes)). Always use this, never `==`, to check a MAC.

### `hkdf(alg: HashAlg, salt: []byte, ikm: []byte, info: []byte, outLen: int): []byte!`

RFC 5869 HKDF: derives `outLen` bytes of key material from `ikm`, in one call. `salt` may be empty; `info` binds the output to how it will be used, so two different purposes never share a key.

### `hkdfExtract(alg: HashAlg, salt: []byte, ikm: []byte): []byte`

HKDF's extract step alone: turns `ikm` into a single fixed-length pseudorandom key. Most programs call `hkdf` instead of this and `hkdfExpand` separately.

### `hkdfExpand(alg: HashAlg, prk: []byte, info: []byte, outLen: int): []byte!`

HKDF's expand step alone: stretches an already-extracted key `prk` into `outLen` bytes bound to `info`. Most programs call `hkdf` instead.

### `pbkdf2(alg: HashAlg, password: []byte, salt: []byte, iters: int, outLen: int): []byte`

PBKDF2 key derivation: stretches `password` and `salt` over `iters` rounds of the hash `alg` names, into `outLen` bytes. Prefer `argon2Hash` for new passwords; PBKDF2 is for interop.

## Password hashing

### `argon2Hash(password: []byte, salt: []byte, t: int, m: int, p: int, outLen: int): string`

Hashes `password` with Argon2id, returning one self-describing string that carries the salt and cost parameters `t`, `m`, `p` alongside the result. See [Hash a password](#hash-a-password).

### `argon2Verify(password: []byte, encoded: string): bool`

Checks `password` against a string `argon2Hash` produced, re-deriving the hash and comparing it in constant time. Returns `false`, never fails, on a malformed `encoded` value.

### `argon2id(password: []byte, salt: []byte, secret: []byte, ad: []byte, t: int, m: int, p: int, outLen: int): []byte`

The raw Argon2 variant (the recommended hybrid mode) that `argon2Hash` builds on. Most programs call `argon2Hash` instead, which also encodes the parameters into the result string.

### `argon2i(password: []byte, salt: []byte, secret: []byte, ad: []byte, t: int, m: int, p: int, outLen: int): []byte`

The raw Argon2 variant (the data-independent mode, safer on a shared or observable host) that `argon2Hash` builds on. Most programs call `argon2Hash` instead, which also encodes the parameters into the result string.

### `argon2d(password: []byte, salt: []byte, secret: []byte, ad: []byte, t: int, m: int, p: int, outLen: int): []byte`

The raw Argon2 variant (the data-dependent mode) that `argon2Hash` builds on. Most programs call `argon2Hash` instead, which also encodes the parameters into the result string.

### `bcryptHash(password: []byte, cost: int): string`

Hashes `password` with bcrypt at the given `cost`, for interop with systems that require it. Prefer `argon2Hash` for anything new.

### `bcryptVerify(password: []byte, encoded: string): bool`

Checks `password` against a string `bcryptHash` produced. Returns `false`, never fails, on a malformed `encoded` value.

### `scrypt(password: []byte, salt: []byte, N: int, r: int, p: int, outLen: int): []byte!`

scrypt key derivation: stretches `password` and `salt` with cost parameters `N`, `r`, `p` into `outLen` bytes. Prefer `argon2Hash` for new passwords; scrypt is for interop.

## Randomness

### `randomBytes(n: int): []byte`

`n` bytes read from the operating system's secure random source. Safe to use as a key, a nonce, or an unguessable id. See [Generate random tokens](#generate-random-tokens).

### `randomU64(): uint`

A uniformly random 64-bit value from the secure random source.

### `randomUintBelow(n: uint): uint`

A uniformly random value in the range `[0, n)`, with no bias toward smaller numbers - unlike `randomU64(...) % n`.

### `fillRandom(buf: []byte)`

Overwrites `buf` in place with secure random bytes, without allocating a new slice.

## Encoding

### `encodeHex(b: []byte): string`

Encodes `b` as lowercase hex text.

### `encodeHexUpper(b: []byte): string`

Encodes `b` as uppercase hex text.

### `decodeHex(s: string): []byte!`

Decodes hex text `s` back to bytes. Fails on any character outside `0-9a-fA-F` or an odd-length string.

### `encodeBase64(b: []byte): string`

Encodes `b` as standard base64 text, with `=` padding.

### `decodeBase64(s: string): []byte!`

Decodes standard, padded base64 text `s` back to bytes. Fails on invalid input.

### `encodeBase64Url(b: []byte): string`

Encodes `b` as URL-safe base64 text, with no padding - safe to place directly in a URL path or query string.

### `decodeBase64Url(s: string): []byte!`

Decodes URL-safe, unpadded base64 text `s` back to bytes. Fails on invalid input.

### `encodeBase32(b: []byte): string`

Encodes `b` as base32 text.

### `decodeBase32(s: string): []byte!`

Decodes base32 text `s` back to bytes. Fails on invalid input.

### `PemBlock`

One decoded PEM block: its `label` (for example `CERTIFICATE`) and the raw `der` bytes it wraps.

### `pemEncode(label: string, der: []byte): string`

Wraps `der` in RFC 7468 PEM text, tagged with `label` (for example `"CERTIFICATE"`).

### `pemDecode(pem: string): []PemBlock!`

Parses every PEM block out of `pem` text, in order. Fails if `pem` holds no valid block.

## Constant-time helpers

### `ctEq(a: []byte, b: []byte): bool`

Compares `a` and `b` for equality, always scanning the full length before deciding. Use this, never `==`, for any secret comparison - see [Compare secrets in constant time](../crypto.md#security-notes).

### `ctSelect(v: int, a: int, b: int): int`

Branchless select: returns `a` when `v == 1`, `b` when `v == 0`, without a conditional branch that could leak `v` through timing.

### `secureZero(b: []byte)`

Overwrites `b` with zeros through a barrier the compiler cannot optimize away, unlike an ordinary loop a dead-store pass could drop. Use it to wipe key material when you are done with it.

Read the [crypto safety notes](../crypto.md#security-notes) before using these
operations, or return to the [crypto guide](../crypto.md).
