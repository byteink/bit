# std/crypto

Hashing, passwords, encryption, signing, and secure random data, all built in
Bit with no dependency on OpenSSL or any other system library. Reach for it
whenever a program needs to protect data: checking a login, encrypting a
backup before it leaves the machine, signing something so a reader can prove
who wrote it, or generating an id nobody can guess.

<!-- doctest: per-block -->

## What to reach for

| Task | Use |
| --- | --- |
| Store and check a password | `argon2Hash` / `argon2Verify` |
| Encrypt data so only the key holder can read it | `newXChaChaPoly` or `newGcm` (both AEAD ciphers, see [Encrypt and decrypt data](#encrypt-and-decrypt-data)) |
| Sign data so anyone can verify who wrote it | `ed25519Sign` / `ed25519Verify` |
| Generate an unguessable id or token | `randomBytes` |
| Fingerprint content to detect changes | `newSha256` + `digest` |
| Compare two secrets (a token, a MAC) | `ctEq`, never `==` |

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

## Encrypt and decrypt data

An AEAD cipher (an authenticated cipher: one call both encrypts your data and
produces a tag proving it was not tampered with) is the right tool whenever
you need to keep data secret and be sure nobody altered it while it was out
of your hands, for example a drafts backup written to a shared disk.

`std/crypto` has two: `XChaChaPoly` (a 24-byte nonce, safe to pick at random)
and `AesGcm` (a 12-byte nonce, which needs a counter or a very low volume of
messages per key to stay unique - see [Sharp edges](#sharp-edges)). Reach for
`XChaChaPoly` unless you specifically need AES.

```bit
import { randomBytes, newXChaChaPoly } from "std/crypto"

// The nonce travels with the ciphertext; only the 32-byte key is secret.
class Sealed {
  nonce: []byte,
  ciphertext: []byte,
}

fn encryptDraft(key: []byte, body: string): Sealed! {
  let cipher = newXChaChaPoly(key)?
  let nonce = randomBytes(24)
  let ciphertext = cipher.seal(nonce, []byte(body), []byte(0))
  return Sealed{ nonce = nonce, ciphertext = ciphertext }
}

fn decryptDraft(key: []byte, sealed: Sealed): string! {
  let cipher = newXChaChaPoly(key)?
  let plaintext = cipher.open(sealed.nonce, sealed.ciphertext, []byte(0))?
  return string(plaintext)
}
```

`seal`'s third argument is associated data: bytes that are authenticated but
not encrypted, such as a draft id, so a ciphertext cannot be silently swapped
onto a different record. Pass `[]byte(0)` (empty) when there is none. `open`
fails on any tampering, wrong key, or wrong nonce; it never returns
unauthenticated plaintext.

## Sign and verify data

A signature lets anyone holding a public key confirm that the holder of the
matching private key produced a message, and that the message was not
changed afterward. Use it to let readers verify an exported article came
from you, or to check a payload before you act on it.

```bit
import { randomBytes, ed25519PublicKey, ed25519Sign, ed25519Verify } from "std/crypto"

// A 32-byte random seed IS the private key. Keep it secret; publish only
// ed25519PublicKey(seed).
fn newIdentity(): []byte {
  return randomBytes(32)
}

fn signExport(seed: []byte, article: string): []byte {
  return ed25519Sign(seed, []byte(article))
}

fn verifyExport(seed: []byte, article: string, sig: []byte): bool {
  return ed25519Verify(ed25519PublicKey(seed), []byte(article), sig)
}
```

Ed25519 is the default: fast, small keys and signatures, and no parameters to
get wrong. `ecdsaSign`/`ecdsaVerify` (NIST curves) and the RSA-PKCS1v15/PSS
functions exist for interop with systems that require them.

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
import { newSha256, digest } from "std/crypto"

fn contentHash(body: string): []byte {
  return digest(newSha256(), []byte(body))
}
```

`newSha256` returns a `Hash`, the streaming interface every digest in this
module satisfies: call `write` any number of times and `sum` when you are
done, or use `digest` for the common single-buffer case. `Blake3`
(`newBlake3`/`blake3Hash`) is faster on large inputs and also supports keyed
hashing and a variable-length output; `Blake2b`, SHA-512, SHA-3, and the
legacy SHA-1 and MD5 (interop only, never for anything security-relevant) are
also available. Content hashes are not secret, so comparing them with `==` is
fine; a MAC or password hash is different (see below).

## Security notes

**Compare secrets in constant time.** `==` on two byte slices can return as
soon as it finds the first differing byte, which leaks *where* two secrets
diverge. An attacker who can measure that timing can forge a valid MAC or
token one byte at a time. `ctEq` (and `hmacEqual`, an alias for it) always
scans the full length before deciding:

```bit
import { newSha256, digest, ctEq } from "std/crypto"

fn sameSecret(a: []byte, b: []byte): bool {
  return ctEq(digest(newSha256(), a), digest(newSha256(), b))
}
```

**Wipe key material when you are done with it.** `secureZero(b)` overwrites a
byte slice through a barrier the compiler cannot optimize away, unlike an
ordinary loop that a dead-store pass could drop.

**Skip the legacy algorithms for new work.** MD5 and SHA-1 are here only to
read data written by older systems; do not use them to protect anything new.
ECB block mode (`ecbEncryptBlock`) leaks patterns in the plaintext and should
almost never be reached for directly; use an AEAD cipher instead.

## Sharp edges

- **A nonce must never repeat under the same key.** For `AesGcm` (12-byte
  nonce) that means a counter, not a random draw, once you are encrypting
  more than a few million messages under one key; a repeated nonce leaks the
  authentication key and breaks confidentiality for every message that used
  it. `XChaChaPoly`'s 24-byte nonce is wide enough that a random draw is safe
  at any realistic volume.
- **A wrong key or nonce length panics, not fails.** `newXChaChaPoly`,
  `newGcm`, and friends validate the key length and return `T!` (fail on a
  bad key you got from outside your program, such as a config file); but
  `seal`/`open` panic on a wrong nonce length, because that is always a
  programming error, not bad external data.
- **`argon2Verify` and `bcryptVerify` return `false`, they never fail or
  panic,** for any malformed stored value. A corrupted database row reads as
  "wrong password", which is almost always what you want, but do not mistake
  it for "the hash was well-formed and just did not match".
- **Certificates and trust stores live in this module** (`Certificate`,
  `TrustStore`, `x509Parse`, `systemRoots`) because `std/tls` builds on them,
  but you reach for them directly only when inspecting or pinning a
  certificate outside of a TLS handshake; see [std/tls](/std/tls) for the
  usual case of connecting or serving over TLS.

## Where to go next

- [std/tls](/std/tls) for serving and dialing TLS connections, which uses
  this module's ciphers and certificates underneath.
- [std/hash](/std/hash) for CRC-32C, a fast non-cryptographic checksum for
  catching accidental corruption, not tampering.
- The Book's [Backups](/book/13-backups) chapter compresses, encrypts, and
  verifies an Inkwell backup end to end.

## Reference

Every exported name in `std/crypto`, grouped by area. The guide above covers
the common path through each group; this section is for finding the exact
signature of something you already know you need.

## Hashing

### `Hash`

The streaming digest interface every hash in this module satisfies: `write` any number of times, then `sum` when you are done. `reset` starts over, `size` is the digest length in bytes, and `blockSize` is the algorithm's internal block size.

### `digest(h: Hash, data: []byte): []byte`

Resets `h`, writes `data` once, and returns `h.sum()`. The convenience call for hashing one buffer in a single line.

### `newSha256(): Hash`

Starts a new SHA-256 hash.

### `newSha224(): Hash`

Starts a new SHA-224 hash, SHA-256's shorter sibling.

### `Sha256`

The concrete type `newSha256`/`newSha224` return as a `Hash`. You rarely name it directly; use `newSha256()` and the `Hash` interface.

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

### `newSha1(): Hash`

Starts a new SHA-1 hash. Kept for reading data written by older systems; do not use it to protect anything new.

### `newMd5(): Hash`

Starts a new MD5 hash. Kept for reading data written by older systems; do not use it to protect anything new.

### `newSha512(): Hash`

Starts a new SHA-512 hash.

### `newSha384(): Hash`

Starts a new SHA-384 hash, SHA-512's shorter sibling.

### `newSha512_256(): Hash`

Starts a new SHA-512/256 hash: SHA-512's internal state truncated to a 256-bit output.

### `Sha3`

The concrete SHA-3 type. Build one with `newSha3_256` and friends below, then use it through `write`/`sum` like any `Hash`.

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

### `newSha3_224(): Sha3`

Starts a new SHA3-224 hash.

### `newSha3_256(): Sha3`

Starts a new SHA3-256 hash.

### `newSha3_384(): Sha3`

Starts a new SHA3-384 hash.

### `newSha3_512(): Sha3`

Starts a new SHA3-512 hash.

### `Shake`

SHAKE, a hash whose output length you choose: `absorb` input, then `squeeze(n)` as many times as you like for `n` more bytes of output.

### `Shake.absorb(data: []byte)`

Feeds more data into the running SHAKE state. Call `squeeze` once you are done absorbing input.

### `Shake.squeeze(n: int): []byte`

Draws `n` more bytes of output from this SHAKE state. Call it again for more output; the stream continues from where the last call left off.

### `newShake128(): Shake`

Starts a new SHAKE128 hash.

### `newShake256(): Shake`

Starts a new SHAKE256 hash.

### `Blake2b`

The concrete BLAKE2b type. Build one with `newBlake2b`, then use it through `write`/`sum` like any `Hash`; it can also be keyed, for use as a MAC.

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

### `newBlake2b(outLen: int, key: []byte): Blake2b`

Starts a new BLAKE2b hash with output length `outLen` bytes, keyed with `key` (pass an empty slice for an unkeyed hash).

### `blake2b(data: []byte): []byte`

The one-shot BLAKE2b hash of `data`, 32 bytes long.

### `Blake2s`

BLAKE2b's sibling, tuned for 32-bit hardware. The same shape: `write`/`sum`/`reset`, and an optional key.

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

### `newBlake2s(outLen: int, key: []byte): Blake2s`

Starts a new BLAKE2s hash with output length `outLen` bytes, keyed with `key` (pass an empty slice for an unkeyed hash).

### `Blake3`

The concrete BLAKE3 type. Fast on large inputs; build one with `newBlake3` for plain hashing, or with the keyed and key-derivation constructors below.

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

### `newBlake3(): Blake3`

Starts a new, unkeyed BLAKE3 hash.

### `newBlake3Keyed(key: []byte): Blake3!`

Starts a new BLAKE3 hash keyed with `key` (32 bytes), for use as a MAC. Fails if `key` is not 32 bytes.

### `blake3KeyedHash(key: []byte, data: []byte): []byte!`

The one-shot keyed BLAKE3 hash of `data` under `key`. Fails if `key` is not 32 bytes.

### `newBlake3DeriveKey(context: string): Blake3`

Starts a BLAKE3 hash in key-derivation mode for the given `context` string, so its output is a key rather than a message digest.

### `blake3DeriveKey(context: string, keyMaterial: []byte): []byte`

Derives a key from `keyMaterial` in the given `context` using BLAKE3's key-derivation mode, in one call.

### `blake3Hash(data: []byte): []byte`

The one-shot, unkeyed BLAKE3 hash of `data`, 32 bytes long.

### `blake3Xof(data: []byte, n: int): []byte`

`n` bytes of BLAKE3's extendable output for `data`, in one call.

## MACs and key derivation

### `hmac(newHash: () => Hash, key: []byte, msg: []byte): []byte`

The HMAC of `msg` under `key`, using the hash `newHash` builds (for example `newSha256`). Use it to prove a message came from someone who holds `key`.

### `hmacEqual(a: []byte, b: []byte): bool`

Compares two MAC tags in constant time (an alias for `ctEq`, see [Compare secrets in constant time](#security-notes)). Always use this, never `==`, to check a MAC.

### `hkdf(newHash: () => Hash, salt: []byte, ikm: []byte, info: []byte, outLen: int): []byte!`

RFC 5869 HKDF: derives `outLen` bytes of key material from `ikm`, in one call. `salt` may be empty; `info` binds the output to how it will be used, so two different purposes never share a key.

### `hkdfExtract(newHash: () => Hash, salt: []byte, ikm: []byte): []byte`

HKDF's extract step alone: turns `ikm` into a single fixed-length pseudorandom key. Most programs call `hkdf` instead of this and `hkdfExpand` separately.

### `hkdfExpand(newHash: () => Hash, prk: []byte, info: []byte, outLen: int): []byte!`

HKDF's expand step alone: stretches an already-extracted key `prk` into `outLen` bytes bound to `info`. Most programs call `hkdf` instead.

### `pbkdf2(newHash: () => Hash, password: []byte, salt: []byte, iters: int, outLen: int): []byte`

PBKDF2 key derivation: stretches `password` and `salt` over `iters` rounds of the hash `newHash` builds, into `outLen` bytes. Prefer `argon2Hash` for new passwords; PBKDF2 is for interop.

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

Compares `a` and `b` for equality, always scanning the full length before deciding. Use this, never `==`, for any secret comparison - see [Compare secrets in constant time](#security-notes).

### `ctSelect(v: int, a: int, b: int): int`

Branchless select: returns `a` when `v == 1`, `b` when `v == 0`, without a conditional branch that could leak `v` through timing.

### `secureZero(b: []byte)`

Overwrites `b` with zeros through a barrier the compiler cannot optimize away, unlike an ordinary loop a dead-store pass could drop. Use it to wipe key material when you are done with it.

## Symmetric ciphers and AEAD

### `Aead`

The interface `seal`, `open`, `nonceSize`, and `overhead` every AEAD cipher below satisfies. See [Encrypt and decrypt data](#encrypt-and-decrypt-data).

### `AesCipher`

A key-scheduled AES block cipher (128, 192, or 256-bit key). It enciphers one 16-byte block at a time; use a mode below (`AesGcm`, `ctr`, `cbcEncrypt`) rather than this alone.

### `newAes(key: []byte): AesCipher!`

Builds an `AesCipher` from `key` (128, 192, or 256-bit AES key). Fails on a wrong key length.

### `AesCipher.encryptBlock(block: []byte): []byte`

Enciphers one 16-byte `block`, returning a fresh 16-byte ciphertext block.

### `AesCipher.decryptBlock(block: []byte): []byte`

Deciphers one 16-byte `block`, the inverse of `encryptBlock` under the same key.

### `AesCipher.encryptBlockInto(dst: []byte, block: []byte)`

Like `encryptBlock`, writing into the caller-owned buffer `dst` instead of returning a new one - for a hot loop that cannot allocate per block.

### `ctr(cipher: AesCipher, iv: []byte, data: []byte): []byte`

AES-CTR mode: encrypts or decrypts `data` under `cipher` with initialization vector `iv`. Not authenticated; prefer `AesGcm` unless you specifically need CTR.

### `cbcEncrypt(cipher: AesCipher, iv: []byte, data: []byte): []byte`

AES-CBC mode encryption of `data` under `cipher` with initialization vector `iv`. Not authenticated; prefer `AesGcm` unless you specifically need CBC.

### `cbcDecrypt(cipher: AesCipher, iv: []byte, data: []byte): []byte!`

AES-CBC mode decryption, the inverse of `cbcEncrypt`. Fails on a malformed ciphertext length.

### `ecbEncryptBlock(cipher: AesCipher, block: []byte): []byte`

Raw, single-block ECB encryption. Leaks patterns in the plaintext; almost never the right call directly - use an AEAD cipher instead.

### `AesGcm`

AES-GCM, an AEAD cipher with a 12-byte nonce. Build one with `newGcm`. See [Sharp edges](#sharp-edges) for its nonce requirement.

### `newGcm(key: []byte): AesGcm!`

Builds an `AesGcm` cipher from `key` (128 or 256-bit AES key). Fails on a wrong key length.

### `AesGcm.seal(nonce: []byte, plaintext: []byte, aad: []byte): []byte`

Encrypts and authenticates data under this cipher - see `Aead.seal`.

### `AesGcm.open(nonce: []byte, ciphertext: []byte, aad: []byte): []byte!`

Decrypts and checks data under this cipher - see `Aead.open`.

### `AesGcm.nonceSize(): int`

The nonce length this cipher requires, in bytes.

### `AesGcm.overhead(): int`

The number of extra bytes `seal` adds beyond the plaintext length.

### `AesGcmSiv`

AES-GCM-SIV, an AEAD cipher that stays safe even if a nonce repeats, at a performance cost over plain `AesGcm`. Build one with `newAesGcmSiv`.

### `newAesGcmSiv(key: []byte): AesGcmSiv!`

Builds an `AesGcmSiv` cipher from `key` (128 or 256-bit AES key). Fails on a wrong key length.

### `AesGcmSiv.seal(nonce: []byte, plaintext: []byte, aad: []byte): []byte`

Encrypts and authenticates data under this cipher - see `Aead.seal`.

### `AesGcmSiv.open(nonce: []byte, ciphertext: []byte, aad: []byte): []byte!`

Decrypts and checks data under this cipher - see `Aead.open`.

### `AesGcmSiv.nonceSize(): int`

The nonce length this cipher requires, in bytes.

### `AesGcmSiv.overhead(): int`

The number of extra bytes `seal` adds beyond the plaintext length.

### `ChaChaPoly`

ChaCha20-Poly1305, an AEAD cipher with a 12-byte nonce. Build one with `newChaChaPoly`; prefer `XChaChaPoly` unless you specifically need a 12-byte nonce.

### `newChaChaPoly(key: []byte): ChaChaPoly!`

Builds a `ChaChaPoly` cipher from `key` (32 bytes). Fails on a wrong key length.

### `ChaChaPoly.seal(nonce: []byte, plaintext: []byte, aad: []byte): []byte`

Encrypts and authenticates data under this cipher - see `Aead.seal`.

### `ChaChaPoly.open(nonce: []byte, ciphertext: []byte, aad: []byte): []byte!`

Decrypts and checks data under this cipher - see `Aead.open`.

### `ChaChaPoly.nonceSize(): int`

The nonce length this cipher requires, in bytes.

### `ChaChaPoly.overhead(): int`

The number of extra bytes `seal` adds beyond the plaintext length.

### `XChaChaPoly`

XChaCha20-Poly1305, an AEAD cipher with a 24-byte nonce, safe to pick at random. Build one with `newXChaChaPoly`. See [Encrypt and decrypt data](#encrypt-and-decrypt-data).

### `newXChaChaPoly(key: []byte): XChaChaPoly!`

Builds an `XChaChaPoly` cipher from `key` (32 bytes). Fails on a wrong key length.

### `XChaChaPoly.seal(nonce: []byte, plaintext: []byte, aad: []byte): []byte`

Encrypts and authenticates data under this cipher - see `Aead.seal`.

### `XChaChaPoly.open(nonce: []byte, ciphertext: []byte, aad: []byte): []byte!`

Decrypts and checks data under this cipher - see `Aead.open`.

### `XChaChaPoly.nonceSize(): int`

The nonce length this cipher requires, in bytes.

### `XChaChaPoly.overhead(): int`

The number of extra bytes `seal` adds beyond the plaintext length.

### `chacha20(key: []byte, nonce: []byte, counter: u32, data: []byte): []byte`

The raw ChaCha20 stream cipher underneath `ChaChaPoly`, not authenticated. Almost never called directly.

### `hchacha20(key: []byte, nonce16: []byte): []byte`

HChaCha20, the sub-key derivation `XChaChaPoly` uses internally to extend a 12-byte nonce to 24 bytes.

### `poly1305(key: []byte, msg: []byte): []byte`

The raw Poly1305 MAC of `msg` under `key`, underneath the ChaCha AEADs. Almost never called directly.

### `poly1305Verify(key: []byte, msg: []byte, tag: []byte): bool`

Checks a raw Poly1305 `tag` for `msg` under `key`, in constant time.

## Signing and key exchange

### `ed25519PublicKey(priv: []byte): []byte`

The public key matching the 32-byte private seed `priv`. Publish this; keep `priv` secret.

### `ed25519Sign(priv: []byte, msg: []byte): []byte`

Signs `msg` with the private seed `priv`. See [Sign and verify data](#sign-and-verify-data).

### `ed25519Verify(pub: []byte, msg: []byte, sig: []byte): bool`

Checks that `sig` is a valid Ed25519 signature of `msg` under public key `pub`.

### `EcdsaPublicKey`

An ECDSA public key on a given `Curve`.

### `EcdsaPrivateKey`

An ECDSA private key on a given `Curve`.

### `EcdsaSignature`

An ECDSA signature: its `r` and `s` components.

### `ecdsaGenerateKey(curve: Curve): EcdsaPrivateKey`

Generates a new random ECDSA private key on `curve`.

### `ecdsaPublicKey(curve: Curve, sec1: []byte): EcdsaPublicKey!`

Builds an `EcdsaPublicKey` on `curve` from raw point bytes. Fails on an invalid point.

### `ecdsaPrivateKey(curve: Curve, scalar: []byte): EcdsaPrivateKey!`

Builds an `EcdsaPrivateKey` on `curve` from a raw scalar. Fails on an invalid scalar.

### `ecdsaSign(priv: EcdsaPrivateKey, hash: []byte, newHash: () => Hash): EcdsaSignature!`

Signs a pre-hashed `hash` with `priv`, using `newHash` for the signature's internal randomness. Fails only on an unusable key.

### `ecdsaVerify(pub: EcdsaPublicKey, hash: []byte, sig: EcdsaSignature): bool`

Checks that `sig` is a valid ECDSA signature of pre-hashed `hash` under public key `pub`.

### `ecdsaSignatureToDer(sig: EcdsaSignature): []byte`

Encodes an `EcdsaSignature` as DER bytes, the form most interop wire formats expect.

### `ecdsaSignatureFromDer(der: []byte): EcdsaSignature!`

Decodes DER-encoded bytes back into an `EcdsaSignature`. Fails on malformed input.

### `RsaPublicKey`

An RSA public key: its modulus and public exponent.

### `RsaPrivateKey`

An RSA private key.

### `rsaSignPkcs1v15(priv: RsaPrivateKey, newHash: () => Hash, digestInfoPrefix: []byte, message: []byte): []byte!`

Signs `message` with `priv` using PKCS#1 v1.5 padding and the hash `newHash` builds. `digestInfoPrefix` identifies the hash algorithm in the signature - use `rsaDigestInfoSha256()` and friends below.

### `rsaVerifyPkcs1v15(pub: RsaPublicKey, newHash: () => Hash, digestInfoPrefix: []byte, message: []byte, sig: []byte): bool`

Checks a PKCS#1 v1.5 signature `sig` of `message` under public key `pub`, for the hash identified by `digestInfoPrefix`.

### `rsaSignPss(priv: RsaPrivateKey, newHash: () => Hash, message: []byte, saltLen: int): []byte!`

Signs `message` with `priv` using PSS padding and the hash `newHash` builds, with a `saltLen`-byte salt. PSS is the modern choice over PKCS#1 v1.5 for new signatures.

### `rsaVerifyPss(pub: RsaPublicKey, newHash: () => Hash, message: []byte, sig: []byte, saltLen: int): bool`

Checks a PSS signature `sig` of `message` under public key `pub`, with a `saltLen`-byte salt.

### `rsaEncryptOaep(pub: RsaPublicKey, newHash: () => Hash, message: []byte, label: []byte): []byte!`

Encrypts `message` to public key `pub` using OAEP padding and the hash `newHash` builds. `label` binds the ciphertext to a context; pass an empty slice when there is none. Prefer an AEAD cipher for new data; RSA encryption is for interop or wrapping a small key.

### `rsaDecryptOaep(priv: RsaPrivateKey, newHash: () => Hash, ciphertext: []byte, label: []byte): []byte!`

Decrypts `ciphertext` with private key `priv` using OAEP padding, the inverse of `rsaEncryptOaep`. Fails on a mismatched `label` or malformed ciphertext.

### `rsaEncryptPkcs1v15(pub: RsaPublicKey, message: []byte): []byte!`

Encrypts `message` to public key `pub` using PKCS#1 v1.5 padding, for interop. Prefer `rsaEncryptOaep` for new data.

### `rsaDecryptPkcs1v15(priv: RsaPrivateKey, ciphertext: []byte): []byte!`

Decrypts `ciphertext` with private key `priv` using PKCS#1 v1.5 padding, the inverse of `rsaEncryptPkcs1v15`.

### `rsaParsePublicKey(der: []byte): RsaPublicKey!`

Parses an `RsaPublicKey` from its standard SubjectPublicKeyInfo DER encoding. Fails on malformed input.

### `rsaParsePkcs1PublicKey(der: []byte): RsaPublicKey!`

Parses an `RsaPublicKey` from its older, RSA-specific PKCS#1 DER encoding. Fails on malformed input.

### `rsaParsePrivateKey(der: []byte): RsaPrivateKey!`

Parses an `RsaPrivateKey` from its standard PKCS#8 DER encoding. Fails on malformed input.

### `rsaParsePkcs1PrivateKey(der: []byte): RsaPrivateKey!`

Parses an `RsaPrivateKey` from its older, RSA-specific PKCS#1 DER encoding. Fails on malformed input.

### `rsaDigestInfoSha256(): []byte`

The DigestInfo prefix PKCS#1 v1.5 signing needs to identify SHA-256 as the hash used.

### `rsaDigestInfoSha384(): []byte`

The DigestInfo prefix PKCS#1 v1.5 signing needs to identify SHA-384 as the hash used.

### `rsaDigestInfoSha512(): []byte`

The DigestInfo prefix PKCS#1 v1.5 signing needs to identify SHA-512 as the hash used.

### `X25519Keypair`

An X25519 key exchange keypair: its private scalar and public point.

### `x25519GenerateKeypair(): X25519Keypair`

Generates a new random X25519 keypair.

### `x25519(scalar: []byte, uCoord: []byte): []byte`

The raw X25519 function: applies `scalar` to point `uCoord`. Most programs call `x25519SharedSecret` instead.

### `x25519Base(scalar: []byte): []byte`

Applies `scalar` to X25519's fixed base point, producing the matching public key.

### `x25519SharedSecret(scalar: []byte, uCoord: []byte): []byte!`

Computes the shared secret from your `scalar` and a peer's public `uCoord`. Fails if the result is the all-zero point, which means the peer's key was invalid.

### `X448Keypair`

An X448 key exchange keypair, X25519's equivalent at a higher security margin.

### `x448GenerateKeypair(): X448Keypair`

Generates a new random X448 keypair.

### `x448(scalar: []byte, uCoord: []byte): []byte`

The raw X448 function: applies `scalar` to point `uCoord`. Most programs call `x448SharedSecret` instead.

### `x448Base(scalar: []byte): []byte`

Applies `scalar` to X448's fixed base point, producing the matching public key.

### `x448SharedSecret(scalar: []byte, uCoord: []byte): []byte!`

Computes the shared secret from your `scalar` and a peer's public `uCoord`. Fails if the result is the all-zero point.

### `EcdhKeypair`

An ECDH key exchange keypair on a NIST curve.

### `ecdhnistGenerateKeypair(curve: Curve): EcdhKeypair`

Generates a new random ECDH keypair on `curve`.

### `ecdhnistSharedSecret(priv: []byte, peerPub: []byte, curve: Curve): []byte!`

Computes the ECDH shared secret from your private `priv` and a peer's public `peerPub`, on `curve`. Fails on an invalid peer key.

## Post-quantum

### `MlkemKeypair`

An ML-KEM (FIPS 203) key encapsulation keypair: its encapsulation key (public) and decapsulation key (private).

### `MlkemEncapsulated`

The result of `mlkemEncaps`: the shared secret and the ciphertext to send the other party.

### `mlkemKeygen(): MlkemKeypair`

Generates a new random ML-KEM keypair.

### `mlkemEncaps(ek: []byte): MlkemEncapsulated!`

Encapsulates a fresh shared secret to encapsulation key `ek`, returning it alongside the ciphertext to send. Fails on a malformed key.

### `mlkemDecaps(dk: []byte, ct: []byte): []byte`

Recovers the shared secret from ciphertext `ct` using decapsulation key `dk`.

### `mlkemKeygenDerand(d: []byte, z: []byte): MlkemKeypair`

Deterministic ML-KEM key generation from caller-supplied randomness, for testing. Pass real randomness in production - use `mlkemKeygen` there instead.

### `mlkemEncapsDerand(ek: []byte, m: []byte): MlkemEncapsulated!`

Deterministic ML-KEM encapsulation from caller-supplied randomness, for testing. Pass real randomness in production - use `mlkemEncaps` there instead.

### `mlkemEkSize: int`

The fixed byte size of an ML-KEM encapsulation key.

### `mlkemDkSize: int`

The fixed byte size of an ML-KEM decapsulation key.

### `mlkemCtSize: int`

The fixed byte size of an ML-KEM ciphertext.

### `mlkemSsSize: int`

The fixed byte size of an ML-KEM shared secret.

### `MldsaKeypair`

An ML-DSA (FIPS 204) signing keypair.

### `mldsaKeygen(): MldsaKeypair`

Generates a new random ML-DSA keypair.

### `mldsaSign(sk: []byte, msg: []byte): []byte`

Signs `msg` with ML-DSA secret key `sk`.

### `mldsaVerify(pk: []byte, msg: []byte, sig: []byte): bool`

Checks ML-DSA signature `sig` of `msg` under public key `pk`.

### `mldsaSignCtx(sk: []byte, msg: []byte, ctx: []byte): []byte`

Like `mldsaSign`, with an explicit context string binding the signature to how it will be used.

### `mldsaVerifyCtx(pk: []byte, msg: []byte, sig: []byte, ctx: []byte): bool`

Like `mldsaVerify`, checking a signature made with the matching context string.

### `mldsaKeygenSeed(seed: []byte): MldsaKeypair`

Deterministic ML-DSA key generation from a caller-supplied seed, for testing. Pass real randomness in production - use `mldsaKeygen` there instead.

## Certificates and trust

### `TrustStore`

A set of trust-anchor certificates. Build one from a PEM bundle with `fromPem`, from the operating system with `systemRoots`, or use `bundled` for a small built-in set.

### `fromPem(pem: string): TrustStore!`

Builds a `TrustStore` from every `CERTIFICATE` block in `pem`, in order.

### `TrustStore.verifyChain(leaf: Certificate, intermediates: []Certificate, hostname: string, nowUnix: int): ()!`

Verifies `leaf` against this store's trusted roots, for `hostname`, as of `nowUnix` (Unix seconds). Fails with the first problem found: hostname mismatch, expiry, a broken signature, or an unbuildable chain.

### `systemRoots(): TrustStore!`

The operating system's own certificate authority trust store. Fails if none is found on this host.

### `bundled(): TrustStore`

A small built-in set of public trust roots, for when no system trust store is available.

### `Certificate`

A parsed X.509 certificate. Build one with `x509Parse`.

### `x509Parse(der: []byte): Certificate!`

Parses `der` as a DER-encoded X.509 certificate. Fails on malformed input.

### `x509MatchHostname(cert: Certificate, hostname: string): bool`

Whether `cert` is valid for `hostname`, checking its subject and subject-alternative names.

### `x509VerifyChain(leaf: Certificate, intermediates: []Certificate, roots: []Certificate, hostname: string, nowUnix: int): ()!`

Verifies certificate `leaf` up through `intermediates` to a trusted root in `roots`, for `hostname`, as of `nowUnix`. `std/tls` calls this for you during a handshake.

### `x509VerifySignature(cert: Certificate, issuer: Certificate): bool`

Whether `issuer` signed `cert` - one link in a chain, checked in isolation.

### `x509KeyRSA: int`

The `Certificate.pubKeyAlg` value meaning the certificate's key is RSA.

### `x509KeyECDSA: int`

The `Certificate.pubKeyAlg` value meaning the certificate's key is ECDSA.

### `x509KeyEd25519: int`

The `Certificate.pubKeyAlg` value meaning the certificate's key is Ed25519.

## ASN.1 and DER

Low-level building blocks for reading and writing the DER encoding
certificates and keys use. Most programs reach for `x509Parse` or `pemDecode`
instead of these directly.

### `Element`

One parsed DER element: its tag class, tag number, and raw content bytes.

### `BitString`

The decoded content of a BIT STRING element. `unusedBits` (0 to 7) counts the padding bits in the final byte; `bytes` is the value.

### `asn1Parse(der: []byte): Element!`

Parses `der` as one top-level DER element. Fails on malformed input.

### `asn1Encode(e: Element): []byte`

Re-encodes a parsed `Element` back to DER bytes.

### `asn1Boolean(v: bool): Element`

Builds an `Element` holding a BOOLEAN.

### `asn1Integer(v: int): Element`

Builds an `Element` holding an INTEGER (fits in an `int`).

### `asn1BigInteger(mag: []byte): Element`

Builds an `Element` holding an INTEGER too large for an `int`, given as its big-endian magnitude.

### `asn1BitString(unusedBits: int, data: []byte): Element`

Builds an `Element` holding a BIT STRING.

### `asn1OctetString(data: []byte): Element`

Builds an `Element` holding an OCTET STRING.

### `asn1Null(): Element`

Builds an `Element` holding a NULL.

### `asn1Oid(arcs: []int): Element!`

Builds an `Element` holding an OBJECT IDENTIFIER from its dotted arcs.

### `asn1Utf8String(s: string): Element`

Builds an `Element` holding a UTF8String.

### `asn1PrintableString(s: string): Element`

Builds an `Element` holding a PrintableString.

### `asn1IA5String(s: string): Element`

Builds an `Element` holding an IA5String.

### `asn1UtcTime(s: string): Element`

Builds an `Element` holding a UTCTime.

### `asn1GeneralizedTime(s: string): Element`

Builds an `Element` holding a GeneralizedTime.

### `asn1Sequence(children: []Element): Element`

Builds an `Element` holding a SEQUENCE from its elements.

### `asn1Set(children: []Element): Element`

Builds an `Element` holding a SET from its elements.

### `asn1ExplicitTag(tag: int, inner: Element): Element`

Wraps `e` in an explicit context tag numbered `tagNum`, the DER convention for optional or choice fields.

### `asn1ImplicitTag(tag: int, inner: Element): Element`

Wraps `e` in an implicit context tag numbered `tagNum`, replacing its universal tag rather than nesting a new one.

### `asn1ReadBoolean(e: Element): bool!`

Reads `e` back out as a BOOLEAN. Fails if `e` is not that type or is malformed.

### `asn1ReadInteger(e: Element): int!`

Reads `e` back out as an INTEGER as an `int`. Fails if `e` is not that type or is malformed.

### `asn1ReadBigInteger(e: Element): []byte!`

Reads `e` back out as an INTEGER too large for an `int`, as its big-endian magnitude. Fails if `e` is not that type or is malformed.

### `asn1ReadBitString(e: Element): BitString!`

Reads `e` back out as a BIT STRING as a `BitString`. Fails if `e` is not that type or is malformed.

### `asn1ReadOctetString(e: Element): []byte!`

Reads `e` back out as an OCTET STRING. Fails if `e` is not that type or is malformed.

### `asn1ReadNull(e: Element): ()!`

Reads `e` back out as a NULL, checking only that it is present. Fails if `e` is not that type or is malformed.

### `asn1ReadOid(e: Element): []int!`

Reads `e` back out as an OBJECT IDENTIFIER as its dotted arcs. Fails if `e` is not that type or is malformed.

### `asn1ReadString(e: Element): string!`

Reads `e` back out as any of the text string types as a plain `string`. Fails if `e` is not that type or is malformed.

### `asn1ReadSequence(e: Element): []Element!`

Reads `e` back out as a SEQUENCE as its elements. Fails if `e` is not that type or is malformed.

### `asn1ReadSet(e: Element): []Element!`

Reads `e` back out as a SET as its elements. Fails if `e` is not that type or is malformed.

### `asn1ReadExplicit(e: Element, tag: int): Element!`

Reads `e` back out of an explicit context tag numbered `tagNum`, the inverse of `asn1ExplicitTag`. Fails if the tag does not match.

### `asn1OidString(arcs: []int): string`

Formats an object identifier's `arcs` as a dotted string, for example `"1.2.840.113549"`.

### `classUniversal: int`

One of DER's four ASN.1 tag classes, used with `asn1ExplicitTag`/`asn1ImplicitTag` and when reading an `Element`'s tag directly.

### `classApplication: int`

One of DER's four ASN.1 tag classes, used with `asn1ExplicitTag`/`asn1ImplicitTag` and when reading an `Element`'s tag directly.

### `classContext: int`

One of DER's four ASN.1 tag classes, used with `asn1ExplicitTag`/`asn1ImplicitTag` and when reading an `Element`'s tag directly.

### `classPrivate: int`

One of DER's four ASN.1 tag classes, used with `asn1ExplicitTag`/`asn1ImplicitTag` and when reading an `Element`'s tag directly.

### `tagBoolean: int`

The universal DER tag number for BOOLEAN.

### `tagInteger: int`

The universal DER tag number for INTEGER.

### `tagBitString: int`

The universal DER tag number for BIT STRING.

### `tagOctetString: int`

The universal DER tag number for OCTET STRING.

### `tagNull: int`

The universal DER tag number for NULL.

### `tagOid: int`

The universal DER tag number for OBJECT IDENTIFIER.

### `tagUtf8String: int`

The universal DER tag number for UTF8String.

### `tagSequence: int`

The universal DER tag number for SEQUENCE.

### `tagSet: int`

The universal DER tag number for SET.

### `tagPrintableString: int`

The universal DER tag number for PrintableString.

### `tagIA5String: int`

The universal DER tag number for IA5String.

### `tagUtcTime: int`

The universal DER tag number for UTCTime.

### `tagGeneralizedTime: int`

The universal DER tag number for GeneralizedTime.

## Big-integer and elliptic-curve building blocks

The arithmetic RSA, ECDSA, and ECDH are built from. Exported for advanced use
(implementing another curve-based scheme); reach for the signing and key
exchange functions above first.

### `Nat`

An arbitrary-precision non-negative integer, the type RSA, ECDSA, and ECDH build their arithmetic from.

### `bigintZero(): Nat`

The `Nat` value zero.

### `bigintFromU64(v: u64): Nat`

Builds a `Nat` from a 64-bit unsigned integer.

### `bigintToU64(n: Nat): u64!`

Converts a `Nat` to a 64-bit unsigned integer. Fails if the value does not fit.

### `bigintFromBytes(be: []byte): Nat`

Builds a `Nat` from its big-endian byte encoding.

### `bigintToBytes(n: Nat, outLen: int): []byte!`

Encodes a `Nat` as `n` big-endian bytes. Fails if the value does not fit in `n` bytes.

### `bigintIsZero(n: Nat): bool`

Whether a `Nat` is zero.

### `bigintBitLen(n: Nat): int`

The number of bits needed to represent a `Nat`, not counting leading zeros.

### `bigintCmp(a: Nat, b: Nat): int`

Compares two `Nat` values: negative, zero, or positive, the same convention as any three-way comparator.

### `bigintAdd(a: Nat, b: Nat): Nat`

Adds two `Nat` values.

### `bigintSub(a: Nat, b: Nat): Nat!`

Subtracts two `Nat` values. Fails if the result would be negative.

### `bigintMul(a: Nat, b: Nat): Nat`

Multiplies two `Nat` values.

### `bigintSqr(a: Nat): Nat`

Squares a `Nat` value, faster than `bigintMul` with itself.

### `QuotRem`

A division result: its `quot`ient and `rem`ainder.

### `bigintDivMod(a: Nat, b: Nat): QuotRem!`

Divides one `Nat` by another, returning the quotient and remainder. Fails on division by zero.

### `bigintMod(a: Nat, b: Nat): Nat!`

The remainder of one `Nat` divided by another. Fails on division by zero.

### `bigintGcd(a: Nat, b: Nat): Nat`

The greatest common divisor of two `Nat` values.

### `bigintModInverse(a: Nat, n: Nat): Nat!`

The modular inverse of a `Nat` modulo another. Fails if no inverse exists.

### `bigintModExp(base: Nat, exp: Nat, modN: Nat): Nat!`

Modular exponentiation, `base^exp mod modN`, in constant time - use this when `exp` is secret, such as an RSA private exponent.

### `bigintModExpPublic(base: Nat, exp: Nat, modN: Nat): Nat!`

Modular exponentiation, `base^exp mod modN`, faster than `bigintModExp` but not constant-time - use this only when `exp` is public.

### `Curve`

A NIST elliptic curve's parameters. Build one with `nistecP256` or `nistecP384`.

### `Point`

A point on a `Curve`.

### `nistecP256(): Curve`

The NIST P-256 curve.

### `nistecP384(): Curve`

The NIST P-384 curve.

### `nistecIsOnCurve(curve: Curve, point: Point): bool`

Whether `p` is a valid point on `curve`.

### `nistecScalarBaseMult(curve: Curve, scalar: Nat): Point`

Multiplies `curve`'s fixed base point by scalar `k`, producing the matching public point.

### `nistecScalarMult(curve: Curve, point: Point, scalar: Nat): Point!`

Multiplies point `p` by scalar `k` on `curve`. Fails if `p` is not on the curve.

### `nistecPointEncode(curve: Curve, point: Point, compressed: bool): []byte!`

Encodes a curve point as bytes, compressed when `compressed` is true.

### `nistecPointDecode(curve: Curve, data: []byte): Point!`

Decodes bytes back into a point on `curve`. Fails if the bytes do not encode a valid point.

### `fe25519FromBytes(s: []byte): []u64`

Decodes a Curve25519 field element from its byte encoding.

### `fe25519ToBytes(f: []u64): []byte`

Encodes a Curve25519 field element as bytes.

### `fe25519Add(f: []u64, g: []u64): []u64`

Adds two Curve25519 field elements.

### `fe25519Sub(f: []u64, g: []u64): []u64`

Subtracts two Curve25519 field elements.

### `fe25519Mul(f: []u64, g: []u64): []u64`

Multiplies two Curve25519 field elements.

### `fe25519Sqr(f: []u64): []u64`

Squares a Curve25519 field element, faster than `fe25519Mul` with itself.

### `fe25519Mul121666(f: []u64): []u64`

Multiplies a Curve25519 field element by the curve constant 121666, a step in the X25519 ladder.

### `fe25519Invert(z: []u64): []u64`

The multiplicative inverse of a Curve25519 field element.

## Hardware acceleration diagnostics

Report whether a fast hardware code path is active on this host. Informational
only: every function above dispatches to the fast path automatically when it
is available, and falls back to a software path when it is not.

### `hwAvailable(): bool`

Whether any relevant hardware acceleration is available on this host. Every function above dispatches to the fast path automatically; this is informational only.

### `hwAes(): bool`

Whether AES hardware instructions are active for this process.

### `hwAvailableAes(): bool`

Whether AES hardware instructions are available on this host.

### `hwPmull(): bool`

Whether the carry-less multiply instruction GCM's authentication uses is active for this process.

### `hwAvailableGhash(): bool`

Whether the carry-less multiply instruction GCM's authentication uses is available on this host.

### `hwSha2(): bool`

Whether SHA-2 hardware instructions are active for this process.

### `hwAvailableSha256(): bool`

Whether SHA-2 hardware instructions are available on this host.

## Specification

RFC 9106 (Argon2), RFC 7914 (scrypt), RFC 8018 (PBKDF2), RFC 5869 (HKDF), RFC
8439 (ChaCha20-Poly1305), RFC 8032 (Ed25519), RFC 7468 (PEM), RFC 5280
(X.509), FIPS 203 (ML-KEM), and FIPS 204 (ML-DSA) are the standards this
module implements.
