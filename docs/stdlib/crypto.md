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

### Hashing

| Symbol | What it is |
| --- | --- |
| `Hash` | The streaming interface every digest satisfies: `write`, `sum`, `reset`, `size`, `blockSize`. |
| `digest(h: Hash, data: []byte): []byte` | Reset `h`, write `data`, return `h.sum()`. |
| `newSha256(): Hash`, `newSha224(): Hash` | SHA-256 and SHA-224. |
| `newSha1(): Hash` | SHA-1. Legacy interop only. |
| `newMd5(): Hash` | MD5. Legacy interop only. |
| `newSha512(): Hash`, `newSha384(): Hash`, `newSha512_256(): Hash` | The SHA-512 family. |
| `Sha256` | The concrete SHA-256/224 type `newSha256`/`newSha224` return as `Hash`. Rarely named directly. |
| `Sha3`, `newSha3_224(): Sha3`, `newSha3_256(): Sha3`, `newSha3_384(): Sha3`, `newSha3_512(): Sha3` | SHA-3, fixed output lengths. |
| `Shake`, `newShake128(): Shake`, `newShake256(): Shake` | SHAKE, an extendable-output hash: `absorb` input, then `squeeze(n)` for `n` bytes of output. |
| `Blake2b`, `newBlake2b(outLen: int, key: []byte): Blake2b`, `blake2b(data: []byte): []byte` | BLAKE2b, optionally keyed; `blake2b` is the one-shot 32-byte convenience. |
| `Blake2s`, `newBlake2s(outLen: int, key: []byte): Blake2s` | BLAKE2s, the 32-bit-optimized variant. |
| `Blake3`, `newBlake3(): Blake3` | BLAKE3, fast on large inputs. |
| `Blake3.finalize(n: int): []byte` | Draw `n` bytes from the hash as an extendable-output stream, beyond the default 32-byte `sum()`. |
| `newBlake3Keyed(key: []byte): Blake3!`, `blake3KeyedHash(key: []byte, data: []byte): []byte!` | Keyed BLAKE3 (a MAC), streaming and one-shot. |
| `newBlake3DeriveKey(context: string): Blake3`, `blake3DeriveKey(context: string, keyMaterial: []byte): []byte` | BLAKE3 in key-derivation mode. |
| `blake3Hash(data: []byte): []byte` | One-shot 32-byte BLAKE3 hash. |
| `blake3Xof(data: []byte, n: int): []byte` | `n` bytes of BLAKE3 extendable output. |

### MACs and key derivation

| Symbol | What it is |
| --- | --- |
| `hmac(newHash: () => Hash, key: []byte, msg: []byte): []byte` | HMAC of `msg` under `key`, using the hash `newHash` builds. |
| `hmacEqual(a: []byte, b: []byte): bool` | Constant-time tag comparison; an alias for `ctEq`. |
| `hkdf(newHash: () => Hash, salt: []byte, ikm: []byte, info: []byte, outLen: int): []byte!` | RFC 5869 HKDF: extract then expand in one call. |
| `hkdfExtract(newHash: () => Hash, salt: []byte, ikm: []byte): []byte` | HKDF's extract step alone. |
| `hkdfExpand(newHash: () => Hash, prk: []byte, info: []byte, outLen: int): []byte!` | HKDF's expand step alone. |
| `pbkdf2(newHash: () => Hash, password: []byte, salt: []byte, iters: int, outLen: int): []byte` | PBKDF2 key derivation. Prefer Argon2id for new passwords. |

### Password hashing

| Symbol | What it is |
| --- | --- |
| `argon2Hash(password: []byte, salt: []byte, t: int, m: int, p: int, outLen: int): string` | Hash a password, returning a self-describing PHC string. |
| `argon2Verify(password: []byte, encoded: string): bool` | Check a password against an `argon2Hash` string. |
| `argon2id`, `argon2i`, `argon2d(password, salt, secret, ad, t, m, p, outLen): []byte` | The raw Argon2 variants `argon2Hash` builds on. |
| `bcryptHash(password: []byte, cost: int): string`, `bcryptVerify(password: []byte, encoded: string): bool` | bcrypt, for interop with systems that require it. |
| `scrypt(password: []byte, salt: []byte, N: int, r: int, p: int, outLen: int): []byte!` | scrypt key derivation. |

### Randomness

| Symbol | What it is |
| --- | --- |
| `randomBytes(n: int): []byte` | `n` cryptographically secure random bytes. |
| `randomU64(): uint` | A uniformly random 64-bit value. |
| `randomUintBelow(n: uint): uint` | A uniformly random value in `[0, n)`, free of modulo bias. |
| `fillRandom(buf: []byte)` | Overwrite `buf` in place with secure random bytes. |

### Encoding

| Symbol | What it is |
| --- | --- |
| `encodeHex(b: []byte): string`, `encodeHexUpper(b: []byte): string`, `decodeHex(s: string): []byte!` | Hex encode/decode. |
| `encodeBase64(b: []byte): string`, `decodeBase64(s: string): []byte!` | Standard base64 with padding. |
| `encodeBase64Url(b: []byte): string`, `decodeBase64Url(s: string): []byte!` | URL-safe base64, no padding. |
| `encodeBase32(b: []byte): string`, `decodeBase32(s: string): []byte!` | Base32. |
| `PemBlock`, `pemEncode(label: string, der: []byte): string`, `pemDecode(pem: string): []PemBlock!` | RFC 7468 PEM text framing around DER bytes. |

### Constant-time helpers

| Symbol | What it is |
| --- | --- |
| `ctEq(a: []byte, b: []byte): bool` | Constant-time byte-slice equality. Use for any secret comparison. |
| `ctSelect(v: int, a: int, b: int): int` | Branchless select: `a` when `v == 1`, `b` when `v == 0`. |
| `secureZero(b: []byte)` | Wipe `b` to zero through an un-elidable barrier. |

### Symmetric ciphers and AEAD

| Symbol | What it is |
| --- | --- |
| `Aead` | The interface `seal`/`open`/`nonceSize`/`overhead` every AEAD cipher below satisfies. |
| `AesCipher`, `newAes(key: []byte): AesCipher!` | A key-scheduled AES block cipher (128/192/256-bit key). Use a mode below, not this alone. |
| `AesCipher.encryptBlock(block: []byte): []byte`, `AesCipher.decryptBlock(block: []byte): []byte` | Encipher or decipher one 16-byte block. |
| `AesCipher.encryptBlockInto(dst: []byte, block: []byte)` | Like `encryptBlock`, into a caller-owned buffer, for a hot loop that cannot allocate per block. |
| `ctr(cipher: AesCipher, iv: []byte, data: []byte): []byte` | AES-CTR mode. Not authenticated; prefer `AesGcm`. |
| `cbcEncrypt(cipher: AesCipher, iv: []byte, data: []byte): []byte`, `cbcDecrypt(cipher, iv, data): []byte!` | AES-CBC mode. Not authenticated; prefer `AesGcm`. |
| `ecbEncryptBlock(cipher: AesCipher, block: []byte): []byte` | Raw single-block ECB. Leaks plaintext patterns; almost never the right call directly. |
| `AesGcm`, `newGcm(key: []byte): AesGcm!` | AES-GCM AEAD, 12-byte nonce. |
| `AesGcmSiv`, `newAesGcmSiv(key: []byte): AesGcmSiv!` | AES-GCM-SIV: an AEAD that stays safe even if a nonce repeats, at a performance cost. |
| `ChaChaPoly`, `newChaChaPoly(key: []byte): ChaChaPoly!` | ChaCha20-Poly1305 AEAD, 12-byte nonce. |
| `XChaChaPoly`, `newXChaChaPoly(key: []byte): XChaChaPoly!` | XChaCha20-Poly1305 AEAD, 24-byte nonce (safe to pick at random). |
| `chacha20(key: []byte, nonce: []byte, counter: u32, data: []byte): []byte` | The raw ChaCha20 stream cipher underneath `ChaChaPoly`. Not authenticated. |
| `hchacha20(key: []byte, nonce16: []byte): []byte` | HChaCha20, the sub-key derivation `XChaChaPoly` uses to extend the nonce. |
| `poly1305(key: []byte, msg: []byte): []byte`, `poly1305Verify(key: []byte, msg: []byte, tag: []byte): bool` | The raw Poly1305 MAC underneath the ChaCha AEADs. |

### Signing and key exchange

| Symbol | What it is |
| --- | --- |
| `ed25519PublicKey(priv: []byte): []byte`, `ed25519Sign`, `ed25519Verify` | Ed25519 signing from a 32-byte seed. The default choice. |
| `EcdsaPublicKey`, `EcdsaPrivateKey`, `EcdsaSignature` | ECDSA key and signature types. |
| `ecdsaGenerateKey(curve: Curve): EcdsaPrivateKey`, `ecdsaPublicKey`, `ecdsaPrivateKey` | Build or parse ECDSA keys. |
| `ecdsaSign(priv, hash, newHash): EcdsaSignature!`, `ecdsaVerify(pub, hash, sig): bool` | Sign and verify a pre-hashed message. |
| `ecdsaSignatureToDer(sig): []byte`, `ecdsaSignatureFromDer(der): EcdsaSignature!` | DER encoding for an ECDSA signature. |
| `RsaPublicKey`, `RsaPrivateKey` | RSA key types. |
| `rsaSignPkcs1v15`, `rsaVerifyPkcs1v15`, `rsaSignPss`, `rsaVerifyPss` | RSA signing, PKCS#1 v1.5 and PSS padding. |
| `rsaEncryptOaep`, `rsaDecryptOaep`, `rsaEncryptPkcs1v15`, `rsaDecryptPkcs1v15` | RSA encryption. Prefer an AEAD cipher for new data; RSA encryption is for interop or wrapping a small key. |
| `rsaParsePublicKey`, `rsaParsePkcs1PublicKey`, `rsaParsePrivateKey`, `rsaParsePkcs1PrivateKey` | Parse RSA keys from DER. |
| `rsaDigestInfoSha256(): []byte`, `rsaDigestInfoSha384(): []byte`, `rsaDigestInfoSha512(): []byte` | The DigestInfo prefix PKCS#1 v1.5 signing needs for each hash. |
| `X25519Keypair`, `x25519GenerateKeypair(): X25519Keypair` | An X25519 key exchange keypair. |
| `x25519(scalar: []byte, uCoord: []byte): []byte`, `x25519Base(scalar): []byte`, `x25519SharedSecret(scalar, uCoord): []byte!` | The X25519 function and its shared-secret wrapper. |
| `X448Keypair`, `x448GenerateKeypair(): X448Keypair`, `x448`, `x448Base`, `x448SharedSecret` | The X448 equivalent, a higher security margin. |
| `EcdhKeypair`, `ecdhnistGenerateKeypair(curve: Curve): EcdhKeypair`, `ecdhnistSharedSecret(priv, peerPub, curve): []byte!` | ECDH key exchange on a NIST curve. |

### Post-quantum

| Symbol | What it is |
| --- | --- |
| `MlkemKeypair`, `MlkemEncapsulated`, `mlkemKeygen(): MlkemKeypair` | ML-KEM (FIPS 203) key encapsulation keys. |
| `mlkemEncaps(ek: []byte): MlkemEncapsulated!`, `mlkemDecaps(dk: []byte, ct: []byte): []byte` | Encapsulate and decapsulate a shared secret. |
| `mlkemKeygenDerand`, `mlkemEncapsDerand` | Deterministic variants for testing; pass real randomness in production. |
| `mlkemEkSize`, `mlkemDkSize`, `mlkemCtSize`, `mlkemSsSize` | Fixed byte sizes of the encapsulation key, decapsulation key, ciphertext, and shared secret. |
| `MldsaKeypair`, `mldsaKeygen(): MldsaKeypair` | ML-DSA (FIPS 204) signing keys. |
| `mldsaSign(sk: []byte, msg: []byte): []byte`, `mldsaVerify(pk: []byte, msg: []byte, sig: []byte): bool` | Sign and verify. |
| `mldsaSignCtx`, `mldsaVerifyCtx` | The same, with an explicit context string. |
| `mldsaKeygenSeed(seed: []byte): MldsaKeypair` | Deterministic key generation for testing; pass real randomness in production. |

Pair ML-KEM with X25519 as a hybrid until post-quantum cryptography alone has
more field experience; `std/tls`'s `X25519MLKEM768` group does exactly that.

### Certificates and trust

| Symbol | What it is |
| --- | --- |
| `TrustStore`, `fromPem(pem: string): TrustStore!` | A set of trust-anchor certificates; build one from a PEM bundle. |
| `TrustStore.verifyChain(leaf, intermediates, hostname, nowUnix): ()!` | Verify a leaf certificate against this store's roots. |
| `systemRoots(): TrustStore!` | The operating system's own CA trust store. |
| `bundled(): TrustStore` | A small built-in set of public roots, for when no system store is available. |
| `Certificate`, `x509Parse(der: []byte): Certificate!` | A parsed X.509 certificate and its DER parser. |
| `x509MatchHostname(cert: Certificate, hostname: string): bool` | Whether `cert` is valid for `hostname`. |
| `x509VerifyChain(leaf, intermediates, roots, hostname, nowUnix): ()!` | Verify a certificate chain up to a trusted root. `std/tls` calls this for you. |
| `x509VerifySignature(cert: Certificate, issuer: Certificate): bool` | Whether `issuer` signed `cert`. |
| `x509KeyRSA`, `x509KeyECDSA`, `x509KeyEd25519` | The `Certificate.pubKeyAlg` discriminants. |

### ASN.1 / DER

Low-level building blocks for reading and writing the DER encoding
certificates and keys use. Most programs reach for `x509Parse` or `pemDecode`
instead of these directly.

| Symbol | What it is |
| --- | --- |
| `Element`, `BitString` | A parsed DER element, and the BIT STRING payload type. |
| `asn1Parse(der: []byte): Element!`, `asn1Encode(e: Element): []byte` | Parse and re-encode DER. |
| `asn1Boolean`, `asn1Integer`, `asn1BigInteger`, `asn1BitString`, `asn1OctetString`, `asn1Null`, `asn1Oid`, `asn1Utf8String`, `asn1PrintableString`, `asn1IA5String`, `asn1UtcTime`, `asn1GeneralizedTime`, `asn1Sequence`, `asn1Set`, `asn1ExplicitTag`, `asn1ImplicitTag` | Build one `Element` of each ASN.1 type. |
| `asn1ReadBoolean`, `asn1ReadInteger`, `asn1ReadBigInteger`, `asn1ReadBitString`, `asn1ReadOctetString`, `asn1ReadNull`, `asn1ReadOid`, `asn1ReadString`, `asn1ReadSequence`, `asn1ReadSet`, `asn1ReadExplicit` | Read a typed value back out of an `Element`. |
| `asn1OidString(arcs: []int): string` | Format an OID's arcs as a dotted string. |
| `classUniversal`, `classApplication`, `classContext`, `classPrivate` | The four ASN.1 tag classes. |
| `tagBoolean`, `tagInteger`, `tagBitString`, `tagOctetString`, `tagNull`, `tagOid`, `tagUtf8String`, `tagSequence`, `tagSet`, `tagPrintableString`, `tagIA5String`, `tagUtcTime`, `tagGeneralizedTime` | The universal tag numbers. |

### Big-integer and elliptic-curve building blocks

The arithmetic RSA, ECDSA, and ECDH are built from. Exported for advanced use
(implementing another curve-based scheme); reach for the signing and key
exchange functions above first.

| Symbol | What it is |
| --- | --- |
| `Nat` | An arbitrary-precision non-negative integer. |
| `bigintZero`, `bigintFromU64`, `bigintToU64`, `bigintFromBytes`, `bigintToBytes` | Build and convert. |
| `bigintIsZero`, `bigintBitLen`, `bigintCmp` | Inspect. |
| `bigintAdd`, `bigintSub`, `bigintMul`, `bigintSqr` | Arithmetic. |
| `QuotRem`, `bigintDivMod`, `bigintMod` | Division and remainder. |
| `bigintGcd`, `bigintModInverse` | Greatest common divisor and modular inverse. |
| `bigintModExp`, `bigintModExpPublic` | Modular exponentiation; `bigintModExp` runs in constant time for a secret exponent, `bigintModExpPublic` is faster for a public one. |
| `Curve`, `Point`, `nistecP256(): Curve`, `nistecP384(): Curve` | A NIST curve and a point on it. |
| `nistecIsOnCurve`, `nistecScalarBaseMult`, `nistecScalarMult`, `nistecPointEncode`, `nistecPointDecode` | Curve-point arithmetic and encoding. |
| `fe25519FromBytes`, `fe25519ToBytes`, `fe25519Add`, `fe25519Sub`, `fe25519Mul`, `fe25519Sqr`, `fe25519Mul121666`, `fe25519Invert` | Curve25519 field arithmetic underneath `x25519`. |

### Hardware acceleration diagnostics

Report whether a fast hardware code path is active on this host. Informational
only: every function above dispatches to the fast path automatically when it
is available, and falls back to a software path when it is not.

| Symbol | What it is |
| --- | --- |
| `hwAvailable(): bool` | Any relevant hardware acceleration is available on this host. |
| `hwAes(): bool`, `hwAvailableAes(): bool` | AES hardware instructions. |
| `hwPmull(): bool`, `hwAvailableGhash(): bool` | Carry-less multiply, used by GCM's authentication. |
| `hwSha2(): bool`, `hwAvailableSha256(): bool` | SHA-2 hardware instructions. |

## Specification

RFC 9106 (Argon2), RFC 7914 (scrypt), RFC 8018 (PBKDF2), RFC 5869 (HKDF), RFC
8439 (ChaCha20-Poly1305), RFC 8032 (Ed25519), RFC 7468 (PEM), RFC 5280
(X.509), FIPS 203 (ML-KEM), and FIPS 204 (ML-DSA) are the standards this
module implements.
