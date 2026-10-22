# Encrypt data and verify signatures

Inkwell encrypts its backups and checks who signed imported data. Start with
authenticated encryption, then choose the signature format your sender uses.

<!-- doctest: per-block -->

## Encrypt and decrypt data

An AEAD cipher (an authenticated cipher: one call both encrypts your data and
produces a tag proving it was not tampered with) is the right tool whenever
you need to keep data secret and be sure nobody altered it while it was out
of your hands, for example a drafts backup written to a shared disk.

`std/crypto` has two: `XChaChaPoly` (a 24-byte nonce, safe to pick at random)
and `AesGcm` (a 12-byte nonce, which needs a counter or a very low volume of
messages per key to stay unique - see [Sharp edges](../crypto.md#sharp-edges)). Reach for
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

AES-GCM, an AEAD cipher with a 12-byte nonce. `AesGcm(key)` builds one from a 16, 24, or 32-byte key and fails on any other length. See [Sharp edges](../crypto.md#sharp-edges) for its nonce requirement.

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

Read the [crypto safety notes](../crypto.md#security-notes) before using these
operations, or return to the [crypto guide](../crypto.md).
