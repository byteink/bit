# std/crypto

Hashing, passwords, encryption, signing, and secure random data, all built in
Bit with no dependency on OpenSSL or any other system library. Reach for it
whenever a program needs to protect data: checking a login, encrypting a
backup before it leaves the machine, signing something so a reader can prove
who wrote it, or generating an id nobody can guess.

<!-- doctest: per-block -->

Choose the task you are working on:

- [Hash passwords and fingerprint content](crypto/hashing.md).
- [Encrypt data and verify signatures](crypto/encryption-and-signatures.md).
- [Check certificates and encoded keys](crypto/certificates-and-primitives.md).

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
See the [full section](crypto/hashing.md#hash-a-password).
## Encrypt and decrypt data
See the [full section](crypto/encryption-and-signatures.md#encrypt-and-decrypt-data).
## Sign and verify data
See the [full section](crypto/encryption-and-signatures.md#sign-and-verify-data).
## Check a passkey signature
See the [full section](crypto/encryption-and-signatures.md#check-a-passkey-signature).
## Generate random tokens
See the [full section](crypto/hashing.md#generate-random-tokens).
## Fingerprint content
See the [full section](crypto/hashing.md#fingerprint-content).
### Name the hash with a `HashAlg`
See the [full section](crypto/hashing.md#name-the-hash-with-a-hashalg).
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

Every exported name in `std/crypto`, grouped by area. The task guides cover
the common path through each group; this section is for finding the exact
signature of something you already know you need.

## Hashing
See the [full section](crypto/hashing.md#hashing).
### `Hash`
See the [full section](crypto/hashing.md#hash).
### `HashAlg`
See the [full section](crypto/hashing.md#hashalg).
### `HashAlg.make(): Hash`
See the [full section](crypto/hashing.md#hashalg-make-hash).
### `digest(h: Hash, data: []byte): []byte`
See the [full section](crypto/hashing.md#digest-h-hash-data-byte-byte).
### `Sha256`
See the [full section](crypto/hashing.md#sha256).
### `Sha256Bits`
See the [full section](crypto/hashing.md#sha256bits).
### `Sha256.write(data: []byte)`
See the [full section](crypto/hashing.md#sha256-write-data-byte).
### `Sha256.sum(): []byte`
See the [full section](crypto/hashing.md#sha256-sum-byte).
### `Sha256.reset()`
See the [full section](crypto/hashing.md#sha256-reset).
### `Sha256.size(): int`
See the [full section](crypto/hashing.md#sha256-size-int).
### `Sha256.blockSize(): int`
See the [full section](crypto/hashing.md#sha256-blocksize-int).
### `Sha1`
See the [full section](crypto/hashing.md#sha1).
### `Sha1.write(data: []byte)`
See the [full section](crypto/hashing.md#sha1-write-data-byte).
### `Sha1.sum(): []byte`
See the [full section](crypto/hashing.md#sha1-sum-byte).
### `Sha1.reset()`
See the [full section](crypto/hashing.md#sha1-reset).
### `Sha1.size(): int`
See the [full section](crypto/hashing.md#sha1-size-int).
### `Sha1.blockSize(): int`
See the [full section](crypto/hashing.md#sha1-blocksize-int).
### `Md5`
See the [full section](crypto/hashing.md#md5).
### `Md5.write(data: []byte)`
See the [full section](crypto/hashing.md#md5-write-data-byte).
### `Md5.sum(): []byte`
See the [full section](crypto/hashing.md#md5-sum-byte).
### `Md5.reset()`
See the [full section](crypto/hashing.md#md5-reset).
### `Md5.size(): int`
See the [full section](crypto/hashing.md#md5-size-int).
### `Md5.blockSize(): int`
See the [full section](crypto/hashing.md#md5-blocksize-int).
### `Sha512`
See the [full section](crypto/hashing.md#sha512).
### `Sha512Bits`
See the [full section](crypto/hashing.md#sha512bits).
### `Sha512.write(data: []byte)`
See the [full section](crypto/hashing.md#sha512-write-data-byte).
### `Sha512.sum(): []byte`
See the [full section](crypto/hashing.md#sha512-sum-byte).
### `Sha512.reset()`
See the [full section](crypto/hashing.md#sha512-reset).
### `Sha512.size(): int`
See the [full section](crypto/hashing.md#sha512-size-int).
### `Sha512.blockSize(): int`
See the [full section](crypto/hashing.md#sha512-blocksize-int).
### `Sha3`
See the [full section](crypto/hashing.md#sha3).
### `Sha3Bits`
See the [full section](crypto/hashing.md#sha3bits).
### `Sha3.write(data: []byte)`
See the [full section](crypto/hashing.md#sha3-write-data-byte).
### `Sha3.sum(): []byte`
See the [full section](crypto/hashing.md#sha3-sum-byte).
### `Sha3.reset()`
See the [full section](crypto/hashing.md#sha3-reset).
### `Sha3.size(): int`
See the [full section](crypto/hashing.md#sha3-size-int).
### `Sha3.blockSize(): int`
See the [full section](crypto/hashing.md#sha3-blocksize-int).
### `Shake`
See the [full section](crypto/hashing.md#shake).
### `Shake.absorb(data: []byte)`
See the [full section](crypto/hashing.md#shake-absorb-data-byte).
### `Shake.squeeze(n: int): []byte`
See the [full section](crypto/hashing.md#shake-squeeze-n-int-byte).
### `ShakeSecurity`
See the [full section](crypto/hashing.md#shakesecurity).
### `Blake2b`
See the [full section](crypto/hashing.md#blake2b).
### `Blake2b.write(data: []byte)`
See the [full section](crypto/hashing.md#blake2b-write-data-byte).
### `Blake2b.sum(): []byte`
See the [full section](crypto/hashing.md#blake2b-sum-byte).
### `Blake2b.reset()`
See the [full section](crypto/hashing.md#blake2b-reset).
### `Blake2b.size(): int`
See the [full section](crypto/hashing.md#blake2b-size-int).
### `Blake2b.blockSize(): int`
See the [full section](crypto/hashing.md#blake2b-blocksize-int).
### `blake2b(data: []byte): []byte`
See the [full section](crypto/hashing.md#blake2b-data-byte-byte).
### `Blake2s`
See the [full section](crypto/hashing.md#blake2s).
### `Blake2s.write(data: []byte)`
See the [full section](crypto/hashing.md#blake2s-write-data-byte).
### `Blake2s.sum(): []byte`
See the [full section](crypto/hashing.md#blake2s-sum-byte).
### `Blake2s.reset()`
See the [full section](crypto/hashing.md#blake2s-reset).
### `Blake2s.size(): int`
See the [full section](crypto/hashing.md#blake2s-size-int).
### `Blake2s.blockSize(): int`
See the [full section](crypto/hashing.md#blake2s-blocksize-int).
### `Blake3`
See the [full section](crypto/hashing.md#blake3).
### `Blake3Mode`
See the [full section](crypto/hashing.md#blake3mode).
### `Blake3.write(data: []byte)`
See the [full section](crypto/hashing.md#blake3-write-data-byte).
### `Blake3.sum(): []byte`
See the [full section](crypto/hashing.md#blake3-sum-byte).
### `Blake3.reset()`
See the [full section](crypto/hashing.md#blake3-reset).
### `Blake3.size(): int`
See the [full section](crypto/hashing.md#blake3-size-int).
### `Blake3.blockSize(): int`
See the [full section](crypto/hashing.md#blake3-blocksize-int).
### `Blake3.finalize(n: int): []byte`
See the [full section](crypto/hashing.md#blake3-finalize-n-int-byte).
### `blake3KeyedHash(key: []byte, data: []byte): []byte!`
See the [full section](crypto/hashing.md#blake3keyedhash-key-byte-data-byte-byte).
### `blake3DeriveKey(context: string, keyMaterial: []byte): []byte`
See the [full section](crypto/hashing.md#blake3derivekey-context-string-keymaterial-byte-byte).
### `blake3Hash(data: []byte): []byte`
See the [full section](crypto/hashing.md#blake3hash-data-byte-byte).
### `blake3Xof(data: []byte, n: int): []byte`
See the [full section](crypto/hashing.md#blake3xof-data-byte-n-int-byte).
## MACs and key derivation
See the [full section](crypto/hashing.md#macs-and-key-derivation).
### `hmac(alg: HashAlg, key: []byte, msg: []byte): []byte`
See the [full section](crypto/hashing.md#hmac-alg-hashalg-key-byte-msg-byte-byte).
### `hmacEqual(a: []byte, b: []byte): bool`
See the [full section](crypto/hashing.md#hmacequal-a-byte-b-byte-bool).
### `hkdf(alg: HashAlg, salt: []byte, ikm: []byte, info: []byte, outLen: int): []byte!`
See the [full section](crypto/hashing.md#hkdf-alg-hashalg-salt-byte-ikm-byte-info-byte-outlen-int-byte).
### `hkdfExtract(alg: HashAlg, salt: []byte, ikm: []byte): []byte`
See the [full section](crypto/hashing.md#hkdfextract-alg-hashalg-salt-byte-ikm-byte-byte).
### `hkdfExpand(alg: HashAlg, prk: []byte, info: []byte, outLen: int): []byte!`
See the [full section](crypto/hashing.md#hkdfexpand-alg-hashalg-prk-byte-info-byte-outlen-int-byte).
### `pbkdf2(alg: HashAlg, password: []byte, salt: []byte, iters: int, outLen: int): []byte`
See the [full section](crypto/hashing.md#pbkdf2-alg-hashalg-password-byte-salt-byte-iters-int-outlen-int-byte).
## Password hashing
See the [full section](crypto/hashing.md#password-hashing).
### `argon2Hash(password: []byte, salt: []byte, t: int, m: int, p: int, outLen: int): string`
See the [full section](crypto/hashing.md#argon2hash-password-byte-salt-byte-t-int-m-int-p-int-outlen-int-string).
### `argon2Verify(password: []byte, encoded: string): bool`
See the [full section](crypto/hashing.md#argon2verify-password-byte-encoded-string-bool).
### `argon2id(password: []byte, salt: []byte, secret: []byte, ad: []byte, t: int, m: int, p: int, outLen: int): []byte`
See the [full section](crypto/hashing.md#argon2id-password-byte-salt-byte-secret-byte-ad-byte-t-int-m-int-p-int-outlen-int-byte).
### `argon2i(password: []byte, salt: []byte, secret: []byte, ad: []byte, t: int, m: int, p: int, outLen: int): []byte`
See the [full section](crypto/hashing.md#argon2i-password-byte-salt-byte-secret-byte-ad-byte-t-int-m-int-p-int-outlen-int-byte).
### `argon2d(password: []byte, salt: []byte, secret: []byte, ad: []byte, t: int, m: int, p: int, outLen: int): []byte`
See the [full section](crypto/hashing.md#argon2d-password-byte-salt-byte-secret-byte-ad-byte-t-int-m-int-p-int-outlen-int-byte).
### `bcryptHash(password: []byte, cost: int): string`
See the [full section](crypto/hashing.md#bcrypthash-password-byte-cost-int-string).
### `bcryptVerify(password: []byte, encoded: string): bool`
See the [full section](crypto/hashing.md#bcryptverify-password-byte-encoded-string-bool).
### `scrypt(password: []byte, salt: []byte, N: int, r: int, p: int, outLen: int): []byte!`
See the [full section](crypto/hashing.md#scrypt-password-byte-salt-byte-n-int-r-int-p-int-outlen-int-byte).
## Randomness
See the [full section](crypto/hashing.md#randomness).
### `randomBytes(n: int): []byte`
See the [full section](crypto/hashing.md#randombytes-n-int-byte).
### `randomU64(): uint`
See the [full section](crypto/hashing.md#randomu64-uint).
### `randomUintBelow(n: uint): uint`
See the [full section](crypto/hashing.md#randomuintbelow-n-uint-uint).
### `fillRandom(buf: []byte)`
See the [full section](crypto/hashing.md#fillrandom-buf-byte).
## Encoding
See the [full section](crypto/hashing.md#encoding).
### `encodeHex(b: []byte): string`
See the [full section](crypto/hashing.md#encodehex-b-byte-string).
### `encodeHexUpper(b: []byte): string`
See the [full section](crypto/hashing.md#encodehexupper-b-byte-string).
### `decodeHex(s: string): []byte!`
See the [full section](crypto/hashing.md#decodehex-s-string-byte).
### `encodeBase64(b: []byte): string`
See the [full section](crypto/hashing.md#encodebase64-b-byte-string).
### `decodeBase64(s: string): []byte!`
See the [full section](crypto/hashing.md#decodebase64-s-string-byte).
### `encodeBase64Url(b: []byte): string`
See the [full section](crypto/hashing.md#encodebase64url-b-byte-string).
### `decodeBase64Url(s: string): []byte!`
See the [full section](crypto/hashing.md#decodebase64url-s-string-byte).
### `encodeBase32(b: []byte): string`
See the [full section](crypto/hashing.md#encodebase32-b-byte-string).
### `decodeBase32(s: string): []byte!`
See the [full section](crypto/hashing.md#decodebase32-s-string-byte).
### `PemBlock`
See the [full section](crypto/hashing.md#pemblock).
### `pemEncode(label: string, der: []byte): string`
See the [full section](crypto/hashing.md#pemencode-label-string-der-byte-string).
### `pemDecode(pem: string): []PemBlock!`
See the [full section](crypto/hashing.md#pemdecode-pem-string-pemblock).
## Constant-time helpers
See the [full section](crypto/hashing.md#constant-time-helpers).
### `ctEq(a: []byte, b: []byte): bool`
See the [full section](crypto/hashing.md#cteq-a-byte-b-byte-bool).
### `ctSelect(v: int, a: int, b: int): int`
See the [full section](crypto/hashing.md#ctselect-v-int-a-int-b-int-int).
### `secureZero(b: []byte)`
See the [full section](crypto/hashing.md#securezero-b-byte).
## Symmetric ciphers and AEAD
See the [full section](crypto/encryption-and-signatures.md#symmetric-ciphers-and-aead).
### `Aead`
See the [full section](crypto/encryption-and-signatures.md#aead).
### `Aes`
See the [full section](crypto/encryption-and-signatures.md#aes).
### `Aes.encryptBlock(block: []byte): []byte`
See the [full section](crypto/encryption-and-signatures.md#aes-encryptblock-block-byte-byte).
### `Aes.decryptBlock(block: []byte): []byte`
See the [full section](crypto/encryption-and-signatures.md#aes-decryptblock-block-byte-byte).
### `Aes.encryptBlockInto(dst: []byte, block: []byte)`
See the [full section](crypto/encryption-and-signatures.md#aes-encryptblockinto-dst-byte-block-byte).
### `ctr(cipher: Aes, iv: []byte, data: []byte): []byte`
See the [full section](crypto/encryption-and-signatures.md#ctr-cipher-aes-iv-byte-data-byte-byte).
### `cbcEncrypt(cipher: Aes, iv: []byte, data: []byte): []byte`
See the [full section](crypto/encryption-and-signatures.md#cbcencrypt-cipher-aes-iv-byte-data-byte-byte).
### `cbcDecrypt(cipher: Aes, iv: []byte, data: []byte): []byte!`
See the [full section](crypto/encryption-and-signatures.md#cbcdecrypt-cipher-aes-iv-byte-data-byte-byte).
### `ecbEncryptBlock(cipher: Aes, block: []byte): []byte`
See the [full section](crypto/encryption-and-signatures.md#ecbencryptblock-cipher-aes-block-byte-byte).
### `AesGcm`
See the [full section](crypto/encryption-and-signatures.md#aesgcm).
### `AesGcm.seal(nonce: []byte, plaintext: []byte, aad: []byte): []byte`
See the [full section](crypto/encryption-and-signatures.md#aesgcm-seal-nonce-byte-plaintext-byte-aad-byte-byte).
### `AesGcm.open(nonce: []byte, ciphertext: []byte, aad: []byte): []byte!`
See the [full section](crypto/encryption-and-signatures.md#aesgcm-open-nonce-byte-ciphertext-byte-aad-byte-byte).
### `AesGcm.sealInto(dst: []byte, nonce: []byte, plaintext: []byte, aad: []byte)`
See the [full section](crypto/encryption-and-signatures.md#aesgcm-sealinto-dst-byte-nonce-byte-plaintext-byte-aad-byte).
### `AesGcm.sealFrame(frame: []byte, aadLen: int, nonce: []byte, body: []byte, n: int)`
See the [full section](crypto/encryption-and-signatures.md#aesgcm-sealframe-frame-byte-aadlen-int-nonce-byte-body-byte-n-int).
### `AesGcm.openInto(dst: []byte, nonce: []byte, ciphertext: []byte, aad: []byte): ()!`
See the [full section](crypto/encryption-and-signatures.md#aesgcm-openinto-dst-byte-nonce-byte-ciphertext-byte-aad-byte).
### `AesGcm.nonceSize(): int`
See the [full section](crypto/encryption-and-signatures.md#aesgcm-noncesize-int).
### `AesGcm.overhead(): int`
See the [full section](crypto/encryption-and-signatures.md#aesgcm-overhead-int).
### `AesGcmSiv`
See the [full section](crypto/encryption-and-signatures.md#aesgcmsiv).
### `AesGcmSiv.seal(nonce: []byte, plaintext: []byte, aad: []byte): []byte`
See the [full section](crypto/encryption-and-signatures.md#aesgcmsiv-seal-nonce-byte-plaintext-byte-aad-byte-byte).
### `AesGcmSiv.open(nonce: []byte, ciphertext: []byte, aad: []byte): []byte!`
See the [full section](crypto/encryption-and-signatures.md#aesgcmsiv-open-nonce-byte-ciphertext-byte-aad-byte-byte).
### `AesGcmSiv.nonceSize(): int`
See the [full section](crypto/encryption-and-signatures.md#aesgcmsiv-noncesize-int).
### `AesGcmSiv.overhead(): int`
See the [full section](crypto/encryption-and-signatures.md#aesgcmsiv-overhead-int).
### `ChaChaPoly`
See the [full section](crypto/encryption-and-signatures.md#chachapoly).
### `ChaChaPoly.seal(nonce: []byte, plaintext: []byte, aad: []byte): []byte`
See the [full section](crypto/encryption-and-signatures.md#chachapoly-seal-nonce-byte-plaintext-byte-aad-byte-byte).
### `ChaChaPoly.open(nonce: []byte, ciphertext: []byte, aad: []byte): []byte!`
See the [full section](crypto/encryption-and-signatures.md#chachapoly-open-nonce-byte-ciphertext-byte-aad-byte-byte).
### `ChaChaPoly.sealInto(dst: []byte, nonce: []byte, plaintext: []byte, aad: []byte)`
See the [full section](crypto/encryption-and-signatures.md#chachapoly-sealinto-dst-byte-nonce-byte-plaintext-byte-aad-byte).
### `ChaChaPoly.sealFrame(frame: []byte, aadLen: int, nonce: []byte, body: []byte, n: int)`
See the [full section](crypto/encryption-and-signatures.md#chachapoly-sealframe-frame-byte-aadlen-int-nonce-byte-body-byte-n-int).
### `ChaChaPoly.openInto(dst: []byte, nonce: []byte, ciphertext: []byte, aad: []byte): ()!`
See the [full section](crypto/encryption-and-signatures.md#chachapoly-openinto-dst-byte-nonce-byte-ciphertext-byte-aad-byte).
### `ChaChaPoly.nonceSize(): int`
See the [full section](crypto/encryption-and-signatures.md#chachapoly-noncesize-int).
### `ChaChaPoly.overhead(): int`
See the [full section](crypto/encryption-and-signatures.md#chachapoly-overhead-int).
### `XChaChaPoly`
See the [full section](crypto/encryption-and-signatures.md#xchachapoly).
### `XChaChaPoly.seal(nonce: []byte, plaintext: []byte, aad: []byte): []byte`
See the [full section](crypto/encryption-and-signatures.md#xchachapoly-seal-nonce-byte-plaintext-byte-aad-byte-byte).
### `XChaChaPoly.open(nonce: []byte, ciphertext: []byte, aad: []byte): []byte!`
See the [full section](crypto/encryption-and-signatures.md#xchachapoly-open-nonce-byte-ciphertext-byte-aad-byte-byte).
### `XChaChaPoly.nonceSize(): int`
See the [full section](crypto/encryption-and-signatures.md#xchachapoly-noncesize-int).
### `XChaChaPoly.overhead(): int`
See the [full section](crypto/encryption-and-signatures.md#xchachapoly-overhead-int).
### `chacha20(key: []byte, nonce: []byte, counter: u32, data: []byte): []byte`
See the [full section](crypto/encryption-and-signatures.md#chacha20-key-byte-nonce-byte-counter-u32-data-byte-byte).
### `hchacha20(key: []byte, nonce16: []byte): []byte`
See the [full section](crypto/encryption-and-signatures.md#hchacha20-key-byte-nonce16-byte-byte).
### `poly1305(key: []byte, msg: []byte): []byte`
See the [full section](crypto/encryption-and-signatures.md#poly1305-key-byte-msg-byte-byte).
### `poly1305Verify(key: []byte, msg: []byte, tag: []byte): bool`
See the [full section](crypto/encryption-and-signatures.md#poly1305verify-key-byte-msg-byte-tag-byte-bool).
## Signing and key exchange
See the [full section](crypto/encryption-and-signatures.md#signing-and-key-exchange).
### `ed25519PublicKey(priv: []byte): []byte`
See the [full section](crypto/encryption-and-signatures.md#ed25519publickey-priv-byte-byte).
### `ed25519Sign(priv: []byte, msg: []byte): []byte`
See the [full section](crypto/encryption-and-signatures.md#ed25519sign-priv-byte-msg-byte-byte).
### `ed25519Verify(pub: []byte, msg: []byte, sig: []byte): bool`
See the [full section](crypto/encryption-and-signatures.md#ed25519verify-pub-byte-msg-byte-sig-byte-bool).
### `ed25519ParsePrivateKey(der: []byte): []byte!`
See the [full section](crypto/encryption-and-signatures.md#ed25519parseprivatekey-der-byte-byte).
### `EcdsaPublicKey`
See the [full section](crypto/encryption-and-signatures.md#ecdsapublickey).
### `EcdsaPrivateKey`
See the [full section](crypto/encryption-and-signatures.md#ecdsaprivatekey).
### `EcdsaSignature`
See the [full section](crypto/encryption-and-signatures.md#ecdsasignature).
### `ecdsaGenerateKey(curve: Curve): EcdsaPrivateKey`
See the [full section](crypto/encryption-and-signatures.md#ecdsageneratekey-curve-curve-ecdsaprivatekey).
### `ecdsaPublicKey(curve: Curve, sec1: []byte): EcdsaPublicKey!`
See the [full section](crypto/encryption-and-signatures.md#ecdsapublickey-curve-curve-sec1-byte-ecdsapublickey).
### `ecdsaPrivateKey(curve: Curve, scalar: []byte): EcdsaPrivateKey!`
See the [full section](crypto/encryption-and-signatures.md#ecdsaprivatekey-curve-curve-scalar-byte-ecdsaprivatekey).
### `ecdsaSign(priv: EcdsaPrivateKey, hash: []byte, alg: HashAlg): EcdsaSignature!`
See the [full section](crypto/encryption-and-signatures.md#ecdsasign-priv-ecdsaprivatekey-hash-byte-alg-hashalg-ecdsasignature).
### `ecdsaVerify(pub: EcdsaPublicKey, hash: []byte, sig: EcdsaSignature): bool`
See the [full section](crypto/encryption-and-signatures.md#ecdsaverify-pub-ecdsapublickey-hash-byte-sig-ecdsasignature-bool).
### `ecdsaSignatureToDer(sig: EcdsaSignature): []byte`
See the [full section](crypto/encryption-and-signatures.md#ecdsasignaturetoder-sig-ecdsasignature-byte).
### `ecdsaSignatureFromDer(der: []byte): EcdsaSignature!`
See the [full section](crypto/encryption-and-signatures.md#ecdsasignaturefromder-der-byte-ecdsasignature).
### `RsaPublicKey`
See the [full section](crypto/encryption-and-signatures.md#rsapublickey).
### `RsaPrivateKey`
See the [full section](crypto/encryption-and-signatures.md#rsaprivatekey).
### `rsaSignPkcs1v15(priv: RsaPrivateKey, alg: HashAlg, digestInfoPrefix: []byte, message: []byte): []byte!`
See the [full section](crypto/encryption-and-signatures.md#rsasignpkcs1v15-priv-rsaprivatekey-alg-hashalg-digestinfoprefix-byte-message-byte-byte).
### `rsaVerifyPkcs1v15(pub: RsaPublicKey, alg: HashAlg, digestInfoPrefix: []byte, message: []byte, sig: []byte): bool`
See the [full section](crypto/encryption-and-signatures.md#rsaverifypkcs1v15-pub-rsapublickey-alg-hashalg-digestinfoprefix-byte-message-byte-sig-byte-bool).
### `rsaSignPss(priv: RsaPrivateKey, alg: HashAlg, message: []byte, saltLen: int): []byte!`
See the [full section](crypto/encryption-and-signatures.md#rsasignpss-priv-rsaprivatekey-alg-hashalg-message-byte-saltlen-int-byte).
### `rsaVerifyPss(pub: RsaPublicKey, alg: HashAlg, message: []byte, sig: []byte, saltLen: int): bool`
See the [full section](crypto/encryption-and-signatures.md#rsaverifypss-pub-rsapublickey-alg-hashalg-message-byte-sig-byte-saltlen-int-bool).
### `rsaEncryptOaep(pub: RsaPublicKey, alg: HashAlg, message: []byte, label: []byte, mgfAlg: Option<HashAlg> = Option.None): []byte!`
See the [full section](crypto/encryption-and-signatures.md#rsaencryptoaep-pub-rsapublickey-alg-hashalg-message-byte-label-byte-mgfalg-option-hashalg-option-none-byte).
### `rsaDecryptOaep(priv: RsaPrivateKey, alg: HashAlg, ciphertext: []byte, label: []byte, mgfAlg: Option<HashAlg> = Option.None): []byte!`
See the [full section](crypto/encryption-and-signatures.md#rsadecryptoaep-priv-rsaprivatekey-alg-hashalg-ciphertext-byte-label-byte-mgfalg-option-hashalg-option-none-byte).
### `rsaEncryptPkcs1v15(pub: RsaPublicKey, message: []byte): []byte!`
See the [full section](crypto/encryption-and-signatures.md#rsaencryptpkcs1v15-pub-rsapublickey-message-byte-byte).
### `rsaDecryptPkcs1v15(priv: RsaPrivateKey, ciphertext: []byte): []byte!`
See the [full section](crypto/encryption-and-signatures.md#rsadecryptpkcs1v15-priv-rsaprivatekey-ciphertext-byte-byte).
### `rsaParsePublicKey(der: []byte): RsaPublicKey!`
See the [full section](crypto/encryption-and-signatures.md#rsaparsepublickey-der-byte-rsapublickey).
### `rsaParsePkcs1PublicKey(der: []byte): RsaPublicKey!`
See the [full section](crypto/encryption-and-signatures.md#rsaparsepkcs1publickey-der-byte-rsapublickey).
### `rsaParsePrivateKey(der: []byte): RsaPrivateKey!`
See the [full section](crypto/encryption-and-signatures.md#rsaparseprivatekey-der-byte-rsaprivatekey).
### `rsaParsePkcs1PrivateKey(der: []byte): RsaPrivateKey!`
See the [full section](crypto/encryption-and-signatures.md#rsaparsepkcs1privatekey-der-byte-rsaprivatekey).
### `rsaDigestInfoSha256(): []byte`
See the [full section](crypto/encryption-and-signatures.md#rsadigestinfosha256-byte).
### `rsaDigestInfoSha384(): []byte`
See the [full section](crypto/encryption-and-signatures.md#rsadigestinfosha384-byte).
### `rsaDigestInfoSha512(): []byte`
See the [full section](crypto/encryption-and-signatures.md#rsadigestinfosha512-byte).
### `CoseKey`
See the [full section](crypto/encryption-and-signatures.md#cosekey).
### `parseCoseKey(data: []byte): CoseKey!`
See the [full section](crypto/encryption-and-signatures.md#parsecosekey-data-byte-cosekey).
### `coseAlg(key: CoseKey): int`
See the [full section](crypto/encryption-and-signatures.md#cosealg-key-cosekey-int).
### `coseVerify(key: CoseKey, alg: int, message: []byte, signature: []byte): bool!`
See the [full section](crypto/encryption-and-signatures.md#coseverify-key-cosekey-alg-int-message-byte-signature-byte-bool).
### `X25519Keypair`
See the [full section](crypto/encryption-and-signatures.md#x25519keypair).
### `x25519GenerateKeypair(): X25519Keypair`
See the [full section](crypto/encryption-and-signatures.md#x25519generatekeypair-x25519keypair).
### `x25519(scalar: []byte, uCoord: []byte): []byte`
See the [full section](crypto/encryption-and-signatures.md#x25519-scalar-byte-ucoord-byte-byte).
### `x25519Base(scalar: []byte): []byte`
See the [full section](crypto/encryption-and-signatures.md#x25519base-scalar-byte-byte).
### `x25519SharedSecret(scalar: []byte, uCoord: []byte): []byte!`
See the [full section](crypto/encryption-and-signatures.md#x25519sharedsecret-scalar-byte-ucoord-byte-byte).
### `X448Keypair`
See the [full section](crypto/encryption-and-signatures.md#x448keypair).
### `x448GenerateKeypair(): X448Keypair`
See the [full section](crypto/encryption-and-signatures.md#x448generatekeypair-x448keypair).
### `x448(scalar: []byte, uCoord: []byte): []byte`
See the [full section](crypto/encryption-and-signatures.md#x448-scalar-byte-ucoord-byte-byte).
### `x448Base(scalar: []byte): []byte`
See the [full section](crypto/encryption-and-signatures.md#x448base-scalar-byte-byte).
### `x448SharedSecret(scalar: []byte, uCoord: []byte): []byte!`
See the [full section](crypto/encryption-and-signatures.md#x448sharedsecret-scalar-byte-ucoord-byte-byte).
### `EcdhKeypair`
See the [full section](crypto/encryption-and-signatures.md#ecdhkeypair).
### `ecdhnistGenerateKeypair(curve: Curve): EcdhKeypair`
See the [full section](crypto/encryption-and-signatures.md#ecdhnistgeneratekeypair-curve-curve-ecdhkeypair).
### `ecdhnistSharedSecret(priv: []byte, peerPub: []byte, curve: Curve): []byte!`
See the [full section](crypto/encryption-and-signatures.md#ecdhnistsharedsecret-priv-byte-peerpub-byte-curve-curve-byte).
## Post-quantum
See the [full section](crypto/encryption-and-signatures.md#post-quantum).
### `MlkemKeypair`
See the [full section](crypto/encryption-and-signatures.md#mlkemkeypair).
### `MlkemEncapsulated`
See the [full section](crypto/encryption-and-signatures.md#mlkemencapsulated).
### `mlkemKeygen(): MlkemKeypair`
See the [full section](crypto/encryption-and-signatures.md#mlkemkeygen-mlkemkeypair).
### `mlkemEncaps(ek: []byte): MlkemEncapsulated!`
See the [full section](crypto/encryption-and-signatures.md#mlkemencaps-ek-byte-mlkemencapsulated).
### `mlkemDecaps(dk: []byte, ct: []byte): []byte`
See the [full section](crypto/encryption-and-signatures.md#mlkemdecaps-dk-byte-ct-byte-byte).
### `mlkemKeygenDerand(d: []byte, z: []byte): MlkemKeypair`
See the [full section](crypto/encryption-and-signatures.md#mlkemkeygenderand-d-byte-z-byte-mlkemkeypair).
### `mlkemEncapsDerand(ek: []byte, m: []byte): MlkemEncapsulated!`
See the [full section](crypto/encryption-and-signatures.md#mlkemencapsderand-ek-byte-m-byte-mlkemencapsulated).
### `mlkemEkSize: int`
See the [full section](crypto/encryption-and-signatures.md#mlkemeksize-int).
### `mlkemDkSize: int`
See the [full section](crypto/encryption-and-signatures.md#mlkemdksize-int).
### `mlkemCtSize: int`
See the [full section](crypto/encryption-and-signatures.md#mlkemctsize-int).
### `mlkemSsSize: int`
See the [full section](crypto/encryption-and-signatures.md#mlkemsssize-int).
### `MldsaKeypair`
See the [full section](crypto/encryption-and-signatures.md#mldsakeypair).
### `mldsaKeygen(): MldsaKeypair`
See the [full section](crypto/encryption-and-signatures.md#mldsakeygen-mldsakeypair).
### `mldsaSign(sk: []byte, msg: []byte): []byte`
See the [full section](crypto/encryption-and-signatures.md#mldsasign-sk-byte-msg-byte-byte).
### `mldsaVerify(pk: []byte, msg: []byte, sig: []byte): bool`
See the [full section](crypto/encryption-and-signatures.md#mldsaverify-pk-byte-msg-byte-sig-byte-bool).
### `mldsaSignCtx(sk: []byte, msg: []byte, ctx: []byte): []byte`
See the [full section](crypto/encryption-and-signatures.md#mldsasignctx-sk-byte-msg-byte-ctx-byte-byte).
### `mldsaVerifyCtx(pk: []byte, msg: []byte, sig: []byte, ctx: []byte): bool`
See the [full section](crypto/encryption-and-signatures.md#mldsaverifyctx-pk-byte-msg-byte-sig-byte-ctx-byte-bool).
### `mldsaKeygenSeed(seed: []byte): MldsaKeypair`
See the [full section](crypto/encryption-and-signatures.md#mldsakeygenseed-seed-byte-mldsakeypair).
## Certificates and trust
See the [full section](crypto/certificates-and-primitives.md#certificates-and-trust).
### `TrustStore`
See the [full section](crypto/certificates-and-primitives.md#truststore).
### `fromPem(pem: string): TrustStore!`
See the [full section](crypto/certificates-and-primitives.md#frompem-pem-string-truststore).
### `TrustStore.verifyChain(leaf: Certificate, intermediates: []Certificate, hostname: string, nowUnix: int): ()!`
See the [full section](crypto/certificates-and-primitives.md#truststore-verifychain-leaf-certificate-intermediates-certificate-hostname-string-nowunix-int).
### `systemRoots(): TrustStore!`
See the [full section](crypto/certificates-and-primitives.md#systemroots-truststore).
### `bundled(): TrustStore`
See the [full section](crypto/certificates-and-primitives.md#bundled-truststore).
### `Certificate`
See the [full section](crypto/certificates-and-primitives.md#certificate).
### `x509Parse(der: []byte): Certificate!`
See the [full section](crypto/certificates-and-primitives.md#x509parse-der-byte-certificate).
### `x509MatchHostname(cert: Certificate, hostname: string): bool`
See the [full section](crypto/certificates-and-primitives.md#x509matchhostname-cert-certificate-hostname-string-bool).
### `x509VerifyChain(leaf: Certificate, intermediates: []Certificate, roots: []Certificate, hostname: string, nowUnix: int): ()!`
See the [full section](crypto/certificates-and-primitives.md#x509verifychain-leaf-certificate-intermediates-certificate-roots-certificate-hostname-string-nowunix-int).
### `x509VerifyPath(leaf: Certificate, intermediates: []Certificate, roots: []Certificate, nowUnix: int): ()!`
See the [full section](crypto/certificates-and-primitives.md#x509verifypath-leaf-certificate-intermediates-certificate-roots-certificate-nowunix-int).
### `x509VerifySignature(cert: Certificate, issuer: Certificate): bool`
See the [full section](crypto/certificates-and-primitives.md#x509verifysignature-cert-certificate-issuer-certificate-bool).
### `x509KeyRSA: int`
See the [full section](crypto/certificates-and-primitives.md#x509keyrsa-int).
### `x509KeyECDSA: int`
See the [full section](crypto/certificates-and-primitives.md#x509keyecdsa-int).
### `x509KeyEd25519: int`
See the [full section](crypto/certificates-and-primitives.md#x509keyed25519-int).
## ASN.1 and DER
See the [full section](crypto/certificates-and-primitives.md#asn-1-and-der).
### `Element`
See the [full section](crypto/certificates-and-primitives.md#element).
### `BitString`
See the [full section](crypto/certificates-and-primitives.md#bitstring).
### `asn1Parse(der: []byte): Element!`
See the [full section](crypto/certificates-and-primitives.md#asn1parse-der-byte-element).
### `asn1Encode(e: Element): []byte`
See the [full section](crypto/certificates-and-primitives.md#asn1encode-e-element-byte).
### `asn1Boolean(v: bool): Element`
See the [full section](crypto/certificates-and-primitives.md#asn1boolean-v-bool-element).
### `asn1Integer(v: int): Element`
See the [full section](crypto/certificates-and-primitives.md#asn1integer-v-int-element).
### `asn1BigInteger(mag: []byte): Element`
See the [full section](crypto/certificates-and-primitives.md#asn1biginteger-mag-byte-element).
### `asn1BitString(unusedBits: int, data: []byte): Element`
See the [full section](crypto/certificates-and-primitives.md#asn1bitstring-unusedbits-int-data-byte-element).
### `asn1OctetString(data: []byte): Element`
See the [full section](crypto/certificates-and-primitives.md#asn1octetstring-data-byte-element).
### `asn1Null(): Element`
See the [full section](crypto/certificates-and-primitives.md#asn1null-element).
### `asn1Oid(arcs: []int): Element!`
See the [full section](crypto/certificates-and-primitives.md#asn1oid-arcs-int-element).
### `asn1Utf8String(s: string): Element`
See the [full section](crypto/certificates-and-primitives.md#asn1utf8string-s-string-element).
### `asn1PrintableString(s: string): Element`
See the [full section](crypto/certificates-and-primitives.md#asn1printablestring-s-string-element).
### `asn1IA5String(s: string): Element`
See the [full section](crypto/certificates-and-primitives.md#asn1ia5string-s-string-element).
### `asn1UtcTime(s: string): Element`
See the [full section](crypto/certificates-and-primitives.md#asn1utctime-s-string-element).
### `asn1GeneralizedTime(s: string): Element`
See the [full section](crypto/certificates-and-primitives.md#asn1generalizedtime-s-string-element).
### `asn1Sequence(children: []Element): Element`
See the [full section](crypto/certificates-and-primitives.md#asn1sequence-children-element-element).
### `asn1Set(children: []Element): Element`
See the [full section](crypto/certificates-and-primitives.md#asn1set-children-element-element).
### `asn1ExplicitTag(tag: int, inner: Element): Element`
See the [full section](crypto/certificates-and-primitives.md#asn1explicittag-tag-int-inner-element-element).
### `asn1ImplicitTag(tag: int, inner: Element): Element`
See the [full section](crypto/certificates-and-primitives.md#asn1implicittag-tag-int-inner-element-element).
### `asn1ReadBoolean(e: Element): bool!`
See the [full section](crypto/certificates-and-primitives.md#asn1readboolean-e-element-bool).
### `asn1ReadInteger(e: Element): int!`
See the [full section](crypto/certificates-and-primitives.md#asn1readinteger-e-element-int).
### `asn1ReadBigInteger(e: Element): []byte!`
See the [full section](crypto/certificates-and-primitives.md#asn1readbiginteger-e-element-byte).
### `asn1ReadBitString(e: Element): BitString!`
See the [full section](crypto/certificates-and-primitives.md#asn1readbitstring-e-element-bitstring).
### `asn1ReadOctetString(e: Element): []byte!`
See the [full section](crypto/certificates-and-primitives.md#asn1readoctetstring-e-element-byte).
### `asn1ReadNull(e: Element): ()!`
See the [full section](crypto/certificates-and-primitives.md#asn1readnull-e-element).
### `asn1ReadOid(e: Element): []int!`
See the [full section](crypto/certificates-and-primitives.md#asn1readoid-e-element-int).
### `asn1ReadString(e: Element): string!`
See the [full section](crypto/certificates-and-primitives.md#asn1readstring-e-element-string).
### `asn1ReadSequence(e: Element): []Element!`
See the [full section](crypto/certificates-and-primitives.md#asn1readsequence-e-element-element).
### `asn1ReadSet(e: Element): []Element!`
See the [full section](crypto/certificates-and-primitives.md#asn1readset-e-element-element).
### `asn1ReadExplicit(e: Element, tag: int): Element!`
See the [full section](crypto/certificates-and-primitives.md#asn1readexplicit-e-element-tag-int-element).
### `asn1OidString(arcs: []int): string`
See the [full section](crypto/certificates-and-primitives.md#asn1oidstring-arcs-int-string).
### `classUniversal: int`
See the [full section](crypto/certificates-and-primitives.md#classuniversal-int).
### `classApplication: int`
See the [full section](crypto/certificates-and-primitives.md#classapplication-int).
### `classContext: int`
See the [full section](crypto/certificates-and-primitives.md#classcontext-int).
### `classPrivate: int`
See the [full section](crypto/certificates-and-primitives.md#classprivate-int).
### `tagBoolean: int`
See the [full section](crypto/certificates-and-primitives.md#tagboolean-int).
### `tagInteger: int`
See the [full section](crypto/certificates-and-primitives.md#taginteger-int).
### `tagBitString: int`
See the [full section](crypto/certificates-and-primitives.md#tagbitstring-int).
### `tagOctetString: int`
See the [full section](crypto/certificates-and-primitives.md#tagoctetstring-int).
### `tagNull: int`
See the [full section](crypto/certificates-and-primitives.md#tagnull-int).
### `tagOid: int`
See the [full section](crypto/certificates-and-primitives.md#tagoid-int).
### `tagUtf8String: int`
See the [full section](crypto/certificates-and-primitives.md#tagutf8string-int).
### `tagSequence: int`
See the [full section](crypto/certificates-and-primitives.md#tagsequence-int).
### `tagSet: int`
See the [full section](crypto/certificates-and-primitives.md#tagset-int).
### `tagPrintableString: int`
See the [full section](crypto/certificates-and-primitives.md#tagprintablestring-int).
### `tagIA5String: int`
See the [full section](crypto/certificates-and-primitives.md#tagia5string-int).
### `tagUtcTime: int`
See the [full section](crypto/certificates-and-primitives.md#tagutctime-int).
### `tagGeneralizedTime: int`
See the [full section](crypto/certificates-and-primitives.md#taggeneralizedtime-int).
## Big-integer and elliptic-curve building blocks
See the [full section](crypto/certificates-and-primitives.md#big-integer-and-elliptic-curve-building-blocks).
### `Nat`
See the [full section](crypto/certificates-and-primitives.md#nat).
### `bigintZero(): Nat`
See the [full section](crypto/certificates-and-primitives.md#bigintzero-nat).
### `bigintFromU64(v: u64): Nat`
See the [full section](crypto/certificates-and-primitives.md#bigintfromu64-v-u64-nat).
### `bigintToU64(n: Nat): u64!`
See the [full section](crypto/certificates-and-primitives.md#biginttou64-n-nat-u64).
### `bigintFromBytes(be: []byte): Nat`
See the [full section](crypto/certificates-and-primitives.md#bigintfrombytes-be-byte-nat).
### `bigintToBytes(n: Nat, outLen: int): []byte!`
See the [full section](crypto/certificates-and-primitives.md#biginttobytes-n-nat-outlen-int-byte).
### `bigintIsZero(n: Nat): bool`
See the [full section](crypto/certificates-and-primitives.md#bigintiszero-n-nat-bool).
### `bigintBitLen(n: Nat): int`
See the [full section](crypto/certificates-and-primitives.md#bigintbitlen-n-nat-int).
### `bigintCmp(a: Nat, b: Nat): int`
See the [full section](crypto/certificates-and-primitives.md#bigintcmp-a-nat-b-nat-int).
### `bigintAdd(a: Nat, b: Nat): Nat`
See the [full section](crypto/certificates-and-primitives.md#bigintadd-a-nat-b-nat-nat).
### `bigintSub(a: Nat, b: Nat): Nat!`
See the [full section](crypto/certificates-and-primitives.md#bigintsub-a-nat-b-nat-nat).
### `bigintMul(a: Nat, b: Nat): Nat`
See the [full section](crypto/certificates-and-primitives.md#bigintmul-a-nat-b-nat-nat).
### `bigintSqr(a: Nat): Nat`
See the [full section](crypto/certificates-and-primitives.md#bigintsqr-a-nat-nat).
### `QuotRem`
See the [full section](crypto/certificates-and-primitives.md#quotrem).
### `bigintDivMod(a: Nat, b: Nat): QuotRem!`
See the [full section](crypto/certificates-and-primitives.md#bigintdivmod-a-nat-b-nat-quotrem).
### `bigintMod(a: Nat, b: Nat): Nat!`
See the [full section](crypto/certificates-and-primitives.md#bigintmod-a-nat-b-nat-nat).
### `bigintGcd(a: Nat, b: Nat): Nat`
See the [full section](crypto/certificates-and-primitives.md#bigintgcd-a-nat-b-nat-nat).
### `bigintModInverse(a: Nat, n: Nat): Nat!`
See the [full section](crypto/certificates-and-primitives.md#bigintmodinverse-a-nat-n-nat-nat).
### `bigintModExp(base: Nat, exp: Nat, modN: Nat): Nat!`
See the [full section](crypto/certificates-and-primitives.md#bigintmodexp-base-nat-exp-nat-modn-nat-nat).
### `bigintModExpPublic(base: Nat, exp: Nat, modN: Nat): Nat!`
See the [full section](crypto/certificates-and-primitives.md#bigintmodexppublic-base-nat-exp-nat-modn-nat-nat).
### `Curve`
See the [full section](crypto/certificates-and-primitives.md#curve).
### `Point`
See the [full section](crypto/certificates-and-primitives.md#point).
### `nistecP256(): Curve`
See the [full section](crypto/certificates-and-primitives.md#nistecp256-curve).
### `nistecP384(): Curve`
See the [full section](crypto/certificates-and-primitives.md#nistecp384-curve).
### `nistecIsOnCurve(curve: Curve, point: Point): bool`
See the [full section](crypto/certificates-and-primitives.md#nistecisoncurve-curve-curve-point-point-bool).
### `nistecScalarBaseMult(curve: Curve, scalar: Nat): Point`
See the [full section](crypto/certificates-and-primitives.md#nistecscalarbasemult-curve-curve-scalar-nat-point).
### `nistecScalarMult(curve: Curve, point: Point, scalar: Nat): Point!`
See the [full section](crypto/certificates-and-primitives.md#nistecscalarmult-curve-curve-point-point-scalar-nat-point).
### `nistecPointEncode(curve: Curve, point: Point, compressed: bool): []byte!`
See the [full section](crypto/certificates-and-primitives.md#nistecpointencode-curve-curve-point-point-compressed-bool-byte).
### `nistecPointDecode(curve: Curve, data: []byte): Point!`
See the [full section](crypto/certificates-and-primitives.md#nistecpointdecode-curve-curve-data-byte-point).
### `fe25519FromBytes(s: []byte): []u64`
See the [full section](crypto/certificates-and-primitives.md#fe25519frombytes-s-byte-u64).
### `fe25519ToBytes(f: []u64): []byte`
See the [full section](crypto/certificates-and-primitives.md#fe25519tobytes-f-u64-byte).
### `fe25519Add(f: []u64, g: []u64): []u64`
See the [full section](crypto/certificates-and-primitives.md#fe25519add-f-u64-g-u64-u64).
### `fe25519Sub(f: []u64, g: []u64): []u64`
See the [full section](crypto/certificates-and-primitives.md#fe25519sub-f-u64-g-u64-u64).
### `fe25519Mul(f: []u64, g: []u64): []u64`
See the [full section](crypto/certificates-and-primitives.md#fe25519mul-f-u64-g-u64-u64).
### `fe25519Sqr(f: []u64): []u64`
See the [full section](crypto/certificates-and-primitives.md#fe25519sqr-f-u64-u64).
### `fe25519Mul121666(f: []u64): []u64`
See the [full section](crypto/certificates-and-primitives.md#fe25519mul121666-f-u64-u64).
### `fe25519Invert(z: []u64): []u64`
See the [full section](crypto/certificates-and-primitives.md#fe25519invert-z-u64-u64).
## Hardware acceleration diagnostics
See the [full section](crypto/certificates-and-primitives.md#hardware-acceleration-diagnostics).
### `hwAvailable(): bool`
See the [full section](crypto/certificates-and-primitives.md#hwavailable-bool).
### `hwAes(): bool`
See the [full section](crypto/certificates-and-primitives.md#hwaes-bool).
### `hwAvailableAes(): bool`
See the [full section](crypto/certificates-and-primitives.md#hwavailableaes-bool).
### `hwPmull(): bool`
See the [full section](crypto/certificates-and-primitives.md#hwpmull-bool).
### `hwAvailableGhash(): bool`
See the [full section](crypto/certificates-and-primitives.md#hwavailableghash-bool).
### `hwSha2(): bool`
See the [full section](crypto/certificates-and-primitives.md#hwsha2-bool).
### `hwAvailableSha256(): bool`
See the [full section](crypto/certificates-and-primitives.md#hwavailablesha256-bool).
## Specification
See the [full section](crypto/certificates-and-primitives.md#specification).
