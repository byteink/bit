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
| Encrypt data so only the key holder can read it | `XChaChaPoly` or `AesGcm` (both AEAD ciphers, see [Encrypt and decrypt data](#encrypt-and-decrypt-data)) |
| Sign data so anyone can verify who wrote it | `ed25519Sign` / `ed25519Verify` |
| Generate an unguessable id or token | `randomBytes` |
| Fingerprint content to detect changes | `Sha256` + `digest` |
| Compare two secrets (a token, a MAC) | `ctEq`, never `==` |
| Check a passkey's public key and signature | `parseCoseKey` / `coseVerify` (see [Check a passkey signature](#check-a-passkey-signature)) |

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
import { randomBytes, XChaChaPoly } from "std/crypto"

// The nonce travels with the ciphertext; only the 32-byte key is secret.
class Sealed {
  nonce: []byte,
  ciphertext: []byte,
}

fn encryptDraft(key: []byte, body: string): Sealed! {
  let cipher = XChaChaPoly(key)?
  let nonce = randomBytes(24)
  let ciphertext = cipher.seal(nonce, []byte(body), []byte(0))
  return Sealed{ nonce = nonce, ciphertext = ciphertext }
}

fn decryptDraft(key: []byte, sealed: Sealed): string! {
  let cipher = XChaChaPoly(key)?
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

## Check a passkey signature

When an Inkwell author signs in with a passkey, the browser hands the server
a public key once, at registration, and a signature on every sign-in after
it. The public key arrives as a COSE_Key: a CBOR map whose small integer keys
name the key type, the algorithm and the curve. `parseCoseKey` turns those
bytes into a `CoseKey` you can store and verify with, and `coseVerify` checks
one signature.

```bit
import { CoseKey, coseAlg, coseVerify, parseCoseKey } from "std/crypto"

// At registration: keep only a key this server can verify. ES256 (-7) is
// what most authenticators make; this server also takes ES384, EdDSA, RS256
// and PS256, and parseCoseKey has already refused everything else.
fn registerKey(credentialPublicKey: []byte): CoseKey! {
  let key = parseCoseKey(credentialPublicKey)?
  println("registered a key for alg ${coseAlg(key)}")
  return key
}

// At sign-in: the signature covers the authenticator data followed by the
// SHA-256 of the client data. WebAuthn sends ECDSA signatures in DER.
fn signedIn(key: CoseKey, authData: []byte, clientDataHash: []byte, sig: []byte): bool {
  let signed = []byte(0)
  for b of authData {
    signed = append(signed, b)
  }
  for b of clientDataHash {
    signed = append(signed, b)
  }
  return coseVerify(key, coseAlg(key), signed, sig) catch _ {
    return false
  }
}
```

`parseCoseKey` does all its checking up front, so a key that parses is a key
that verifies. It accepts these and nothing else:

| Key type | Curve | `alg` |
| --- | --- | --- |
| EC2 (`kty` 2) | P-256 (`crv` 1) | -7 ES256 |
| EC2 (`kty` 2) | P-384 (`crv` 2) | -35 ES384 |
| OKP (`kty` 1) | Ed25519 (`crv` 6) | -8 EdDSA |
| RSA (`kty` 3) | modulus 2048 to 8192 bits | -257 RS256 or -37 PS256 |

Anything else fails with an error that names what it found: `cose:
unsupported kty 4`, `cose: unsupported alg -36`, `cose: alg -35 does not fit
EC2 crv 1`. So do a coordinate of the wrong length, a point that is not on
the curve, an Ed25519 key that is not a point, a modulus under 2048 bits, an
RSA exponent that is even or under 17 bits, a missing `alg` (WebAuthn
requires it, and an RSA key is ambiguous without it), a label that appears
twice, and a key whose `key_ops` does not allow verify.

A key that carries a private parameter is refused too. A server that stored
one would be holding a secret by accident, and a credential public key never
has one.

`coseVerify` takes the `alg` you expect and refuses one that is not the
key's, so a signature made for one algorithm cannot be checked under another.
A signature that does not verify, or is not even well formed, is `false`, not
an error. ECDSA signatures are DER, as WebAuthn sends them; RFC 9053 puts raw
`r || s` on the wire in other COSE uses, and that form has to go through
`EcdsaSignature` and `ecdsaSignatureToDer` first.

The bytes may be in any valid CBOR encoding, not only the canonical one
authenticators write. They must be exactly one key: an attested credential
carries extension data after the key, so split it off first with
`decodePrefix` from [std/cbor](/std/cbor).

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
  let author = []byte("32 bytes of secret key material!")
  let keyed = Blake3(Blake3Mode.Keyed(author))?
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

`Blake3(Blake3Mode.Keyed(key))` is the one fallible digest constructor, because
BLAKE3 keys must be exactly 32 bytes; use `?` or `catch` on it.

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

## Security notes

**Compare secrets in constant time.** `==` on two byte slices can return as
soon as it finds the first differing byte, which leaks *where* two secrets
diverge. An attacker who can measure that timing can forge a valid MAC or
token one byte at a time. `ctEq` (and `hmacEqual`, an alias for it) always
scans the full length before deciding:

```bit
import { digest, ctEq, Sha256 } from "std/crypto"

fn sameSecret(a: []byte, b: []byte): bool {
  return ctEq(digest(Sha256(), a), digest(Sha256(), b))
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
- **A wrong key or nonce length panics, not fails.** `XChaChaPoly(key)`,
  `AesGcm(key)`, and friends validate the key length and return `T!` (fail on a
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

A BLAKE3 hasher, fast on large inputs. `Blake3()` is the plain hash; `Blake3(Blake3Mode.Keyed(key))?` is a MAC under a 32-byte key and fails on any other key length; `Blake3(Blake3Mode.DeriveKey(context))?` derives keys for the given context string. The constructor is fallible, so call it with `?` or `catch`.

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

Compares two MAC tags in constant time (an alias for `ctEq`, see [Compare secrets in constant time](#security-notes)). Always use this, never `==`, to check a MAC.

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

Compares `a` and `b` for equality, always scanning the full length before deciding. Use this, never `==`, for any secret comparison - see [Compare secrets in constant time](#security-notes).

### `ctSelect(v: int, a: int, b: int): int`

Branchless select: returns `a` when `v == 1`, `b` when `v == 0`, without a conditional branch that could leak `v` through timing.

### `secureZero(b: []byte)`

Overwrites `b` with zeros through a barrier the compiler cannot optimize away, unlike an ordinary loop a dead-store pass could drop. Use it to wipe key material when you are done with it.

## Symmetric ciphers and AEAD

### `Aead`

The interface `seal`, `open`, `nonceSize`, and `overhead` every AEAD cipher below satisfies. See [Encrypt and decrypt data](#encrypt-and-decrypt-data).

### `Aes`

A key-scheduled AES block cipher. `Aes(key)` builds one from a 16, 24, or 32-byte key (AES-128, -192 or -256) and fails on any other length. It enciphers one 16-byte block at a time; use a mode below (`AesGcm`, `ctr`, `cbcEncrypt`) rather than this alone.

### `Aes.encryptBlock(block: []byte): []byte`

Enciphers one 16-byte `block`, returning a fresh 16-byte ciphertext block.

### `Aes.decryptBlock(block: []byte): []byte`

Deciphers one 16-byte `block`, the inverse of `encryptBlock` under the same key.

### `Aes.encryptBlockInto(dst: []byte, block: []byte)`

Like `encryptBlock`, writing into the caller-owned buffer `dst` instead of returning a new one - for a hot loop that cannot allocate per block.

### `ctr(cipher: Aes, iv: []byte, data: []byte): []byte`

AES-CTR mode: encrypts or decrypts `data` under `cipher` with initialization vector `iv`. Not authenticated; prefer `AesGcm` unless you specifically need CTR.

### `cbcEncrypt(cipher: Aes, iv: []byte, data: []byte): []byte`

AES-CBC mode encryption of `data` under `cipher` with initialization vector `iv`. Not authenticated; prefer `AesGcm` unless you specifically need CBC.

### `cbcDecrypt(cipher: Aes, iv: []byte, data: []byte): []byte!`

AES-CBC mode decryption, the inverse of `cbcEncrypt`. Fails on a malformed ciphertext length.

### `ecbEncryptBlock(cipher: Aes, block: []byte): []byte`

Raw, single-block ECB encryption. Leaks patterns in the plaintext; almost never the right call directly - use an AEAD cipher instead.

### `AesGcm`

AES-GCM, an AEAD cipher with a 12-byte nonce. `AesGcm(key)` builds one from a 16, 24, or 32-byte key and fails on any other length. See [Sharp edges](#sharp-edges) for its nonce requirement.

### `AesGcm.seal(nonce: []byte, plaintext: []byte, aad: []byte): []byte`

Encrypts and authenticates data under this cipher - see `Aead.seal`.

### `AesGcm.open(nonce: []byte, ciphertext: []byte, aad: []byte): []byte!`

Decrypts and checks data under this cipher - see `Aead.open`.

### `AesGcm.sealInto(dst: []byte, nonce: []byte, plaintext: []byte, aad: []byte)`

`seal` allocates a new slice for every message. `sealInto` writes
`ciphertext ‖ tag` into a `dst` the caller owns, so a sender that seals
thousands of messages reuses one buffer. `dst` must be exactly
`len(plaintext) + 16` bytes (slice a larger buffer to size), and `plaintext`
may be `dst[0:len(plaintext)]` to seal in place. The nonce rules and panics are
those of `seal`: the nonce must be 12 bytes and must never repeat under one key.

```bit
import { AesGcm } from "std/crypto"

// Seal `msg` into the front of the caller's reusable `frame`.
fn sealFrame(c: AesGcm, nonce: []byte, msg: []byte, frame: []byte): []byte {
  let out = frame[0:len(msg) + c.overhead()]
  c.sealInto(out, nonce, msg, []byte(0))
  return out
}
```

### `AesGcm.sealFrame(frame: []byte, aadLen: int, nonce: []byte, body: []byte, n: int)`

A framed protocol sends `header ‖ ciphertext ‖ tag`, with the header as the
AAD. With `sealInto` the sender first copies the message body into the frame
and then slices the frame three ways, and each slice is an allocation.
`sealFrame` takes the frame and offsets instead: `frame[0:aadLen]` is the
AAD, the `n`-byte plaintext is `body` followed by the `n - len(body)` bytes
already at `frame[aadLen + len(body):aadLen + n]`, and `ciphertext ‖ tag`
overwrites `frame[aadLen:aadLen + n + 16]`. `body` may be
`frame[aadLen:aadLen + len(body)]` to seal in place; any other overlap with
the bytes written panics, as does a frame too short to hold the AAD, the
plaintext and the tag. The nonce rules and panics are those of `seal`.

```bit
import { AesGcm } from "std/crypto"

// Seal `msg` behind a 2-byte length header, with a type byte after it.
fn sealTyped(c: AesGcm, nonce: []byte, msg: []byte, frame: []byte): int {
  let n = len(msg) + 1
  frame[0] = byte(n >> 8)
  frame[1] = byte(n)
  frame[2 + len(msg)] = 0x17
  c.sealFrame(frame, 2, nonce, msg, n)
  return 2 + n + c.overhead()
}
```

### `AesGcm.openInto(dst: []byte, nonce: []byte, ciphertext: []byte, aad: []byte): ()!`

`open` allocates a new slice for every message. `openInto` writes the
plaintext into a `dst` the caller owns, which must be exactly
`len(ciphertext) - 16` bytes; `dst` may be
`ciphertext[0:len(ciphertext) - 16]` to open in place. The tag is checked
before a single byte of `dst` is written, so a failed open leaves `dst`
untouched and never exposes unauthenticated plaintext. It fails and panics as
`open` does.

```bit
import { AesGcm } from "std/crypto"

// Open in place: the plaintext replaces the front of `sealed`.
fn openFrame(c: AesGcm, nonce: []byte, sealed: []byte): []byte! {
  let plain = sealed[0:len(sealed) - c.overhead()]
  c.openInto(plain, nonce, sealed, []byte(0))?
  return plain
}
```

### `AesGcm.nonceSize(): int`

The nonce length this cipher requires, in bytes.

### `AesGcm.overhead(): int`

The number of extra bytes `seal` adds beyond the plaintext length.

### `AesGcmSiv`

AES-GCM-SIV, an AEAD cipher that stays safe even if a nonce repeats, at a performance cost over plain `AesGcm`. `AesGcmSiv(key)` builds one from a 16 or 32-byte key and fails on any other length.

### `AesGcmSiv.seal(nonce: []byte, plaintext: []byte, aad: []byte): []byte`

Encrypts and authenticates data under this cipher - see `Aead.seal`.

### `AesGcmSiv.open(nonce: []byte, ciphertext: []byte, aad: []byte): []byte!`

Decrypts and checks data under this cipher - see `Aead.open`.

### `AesGcmSiv.nonceSize(): int`

The nonce length this cipher requires, in bytes.

### `AesGcmSiv.overhead(): int`

The number of extra bytes `seal` adds beyond the plaintext length.

### `ChaChaPoly`

ChaCha20-Poly1305, an AEAD cipher with a 12-byte nonce. `ChaChaPoly(key)` builds one from a 32-byte key and fails on any other length; prefer `XChaChaPoly` unless you specifically need a 12-byte nonce.

### `ChaChaPoly.seal(nonce: []byte, plaintext: []byte, aad: []byte): []byte`

Encrypts and authenticates data under this cipher - see `Aead.seal`.

### `ChaChaPoly.open(nonce: []byte, ciphertext: []byte, aad: []byte): []byte!`

Decrypts and checks data under this cipher - see `Aead.open`.

### `ChaChaPoly.sealInto(dst: []byte, nonce: []byte, plaintext: []byte, aad: []byte)`

`seal` allocates a new slice for every message. `sealInto` writes
`ciphertext ‖ tag` into a `dst` the caller owns, so a sender that seals
thousands of messages reuses one buffer. `dst` must be exactly
`len(plaintext) + 16` bytes (slice a larger buffer to size), and `plaintext`
may be `dst[0:len(plaintext)]` to seal in place. The nonce rules and panics are
those of `seal`: the nonce must be 12 bytes and must never repeat under one key.

```bit
import { ChaChaPoly } from "std/crypto"

// Seal `msg` into the front of the caller's reusable `frame`.
fn sealFrame(c: ChaChaPoly, nonce: []byte, msg: []byte, frame: []byte): []byte {
  let out = frame[0:len(msg) + c.overhead()]
  c.sealInto(out, nonce, msg, []byte(0))
  return out
}
```

### `ChaChaPoly.sealFrame(frame: []byte, aadLen: int, nonce: []byte, body: []byte, n: int)`

A framed protocol sends `header ‖ ciphertext ‖ tag`, with the header as the
AAD. With `sealInto` the sender first copies the message body into the frame
and then slices the frame three ways, and each slice is an allocation.
`sealFrame` takes the frame and offsets instead: `frame[0:aadLen]` is the
AAD, the `n`-byte plaintext is `body` followed by the `n - len(body)` bytes
already at `frame[aadLen + len(body):aadLen + n]`, and `ciphertext ‖ tag`
overwrites `frame[aadLen:aadLen + n + 16]`. `body` may be
`frame[aadLen:aadLen + len(body)]` to seal in place; any other overlap with
the bytes written panics, as does a frame too short to hold the AAD, the
plaintext and the tag. The nonce rules and panics are those of `seal`.

```bit
import { ChaChaPoly } from "std/crypto"

// Seal `msg` behind a 2-byte length header, with a type byte after it.
fn sealTyped(c: ChaChaPoly, nonce: []byte, msg: []byte, frame: []byte): int {
  let n = len(msg) + 1
  frame[0] = byte(n >> 8)
  frame[1] = byte(n)
  frame[2 + len(msg)] = 0x17
  c.sealFrame(frame, 2, nonce, msg, n)
  return 2 + n + c.overhead()
}
```

### `ChaChaPoly.openInto(dst: []byte, nonce: []byte, ciphertext: []byte, aad: []byte): ()!`

`open` allocates a new slice for every message. `openInto` writes the
plaintext into a `dst` the caller owns, which must be exactly
`len(ciphertext) - 16` bytes; `dst` may be
`ciphertext[0:len(ciphertext) - 16]` to open in place. The tag is checked
before a single byte of `dst` is written, so a failed open leaves `dst`
untouched and never exposes unauthenticated plaintext. It fails and panics as
`open` does.

```bit
import { ChaChaPoly } from "std/crypto"

// Open in place: the plaintext replaces the front of `sealed`.
fn openFrame(c: ChaChaPoly, nonce: []byte, sealed: []byte): []byte! {
  let plain = sealed[0:len(sealed) - c.overhead()]
  c.openInto(plain, nonce, sealed, []byte(0))?
  return plain
}
```

### `ChaChaPoly.nonceSize(): int`

The nonce length this cipher requires, in bytes.

### `ChaChaPoly.overhead(): int`

The number of extra bytes `seal` adds beyond the plaintext length.

### `XChaChaPoly`

XChaCha20-Poly1305, an AEAD cipher with a 24-byte nonce, safe to pick at random. `XChaChaPoly(key)` builds one from a 32-byte key and fails on any other length. See [Encrypt and decrypt data](#encrypt-and-decrypt-data).

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

### `ed25519ParsePrivateKey(der: []byte): []byte!`

Reads the 32-byte seed out of a PKCS#8 Ed25519 private key (RFC 8410, RFC 5958 `OneAsymmetricKey`), the `PRIVATE KEY` PEM that `openssl genpkey -algorithm ed25519` writes. DER is read strictly: trailing data, an OID other than 1.3.101.112 (`ed25519: not an Ed25519 private key`), algorithm parameters, a key that is not 32 bytes, and a version above 1 all fail. A version 1 key may carry attributes and an embedded public key; if the public key is present it must be the one derived from the seed, else the call fails with `ed25519: the embedded public key does not match`. Error text never contains key bytes.

```bit
import { pemDecode, ed25519ParsePrivateKey, ed25519Sign } from "std/crypto"

// pem is the text of a key file made by `openssl genpkey -algorithm ed25519`.
fn signWithPemKey(pem: string, msg: []byte): []byte! {
  let blocks = pemDecode(pem)?
  if (len(blocks) != 1 || blocks[0].label != "PRIVATE KEY") {
    fail newError("expected one PRIVATE KEY block")
  }
  let seed = ed25519ParsePrivateKey(blocks[0].der)?
  return ed25519Sign(seed, msg)
}
```

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

### `ecdsaSign(priv: EcdsaPrivateKey, hash: []byte, alg: HashAlg): EcdsaSignature!`

Signs a pre-hashed `hash` with `priv`, using `alg` for the signature's internal randomness. Fails only on an unusable key.

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

### `rsaSignPkcs1v15(priv: RsaPrivateKey, alg: HashAlg, digestInfoPrefix: []byte, message: []byte): []byte!`

Signs `message` with `priv` using PKCS#1 v1.5 padding and the hash `alg` names. `digestInfoPrefix` identifies the hash algorithm in the signature - use `rsaDigestInfoSha256()` and friends below.

### `rsaVerifyPkcs1v15(pub: RsaPublicKey, alg: HashAlg, digestInfoPrefix: []byte, message: []byte, sig: []byte): bool`

Checks a PKCS#1 v1.5 signature `sig` of `message` under public key `pub`, for the hash identified by `digestInfoPrefix`.

### `rsaSignPss(priv: RsaPrivateKey, alg: HashAlg, message: []byte, saltLen: int): []byte!`

Signs `message` with `priv` using PSS padding and the hash `alg` names, with a `saltLen`-byte salt. PSS is the modern choice over PKCS#1 v1.5 for new signatures.

### `rsaVerifyPss(pub: RsaPublicKey, alg: HashAlg, message: []byte, sig: []byte, saltLen: int): bool`

Checks a PSS signature `sig` of `message` under public key `pub`, with a `saltLen`-byte salt.

### `rsaEncryptOaep(pub: RsaPublicKey, alg: HashAlg, message: []byte, label: []byte): []byte!`

Encrypts `message` to public key `pub` using OAEP padding and the hash `alg` names. `label` binds the ciphertext to a context; pass an empty slice when there is none. Prefer an AEAD cipher for new data; RSA encryption is for interop or wrapping a small key.

### `rsaDecryptOaep(priv: RsaPrivateKey, alg: HashAlg, ciphertext: []byte, label: []byte): []byte!`

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

### `CoseKey`

A verify key read from a COSE_Key: `Ec2(EcdsaPublicKey)` for a P-256 or P-384
key, `Okp([]byte)` for the 32-byte Ed25519 public key, and `Rsa(RsaPublicKey,
int)` for an RSA key with its alg (-257 or -37).

### `parseCoseKey(data: []byte): CoseKey!`

Decodes one COSE_Key map (RFC 9052 section 7) into a `CoseKey`. Fails on
CBOR that is truncated, malformed or followed by more bytes, on an unsupported
`kty`, `alg` or `crv`, an `alg` that does not fit the key type, a missing or
repeated label, a coordinate of the wrong length, a point off the curve, an
RSA modulus outside 2048 to 8192 bits, and any private parameter.

### `coseAlg(key: CoseKey): int`

The key's COSE algorithm number (-7, -35, -8, -37 or -257), for matching
against the algorithms a WebAuthn credential was asked for.

### `coseVerify(key: CoseKey, alg: int, message: []byte, signature: []byte): bool!`

Whether `signature` is valid for `message` under `key`. `alg` must be the
key's own. Fails on an unsupported `alg` or one the key does not carry; a bad
signature is `false`. ECDSA signatures are DER.

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
8439 (ChaCha20-Poly1305), RFC 8032 (Ed25519), RFC 9052 and RFC 9053 (COSE
keys), RFC 7468 (PEM), RFC 5280
(X.509), FIPS 203 (ML-KEM), and FIPS 204 (ML-DSA) are the standards this
module implements.
