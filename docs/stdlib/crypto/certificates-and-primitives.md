# Check certificates and encoded keys

Inkwell must trust a signing certificate before it accepts the signed data.
Check the path first, then apply the identity and purpose your app requires.

<!-- doctest: per-block -->

## Certificates and trust

Inkwell can receive a signing certificate as well as connect to HTTPS servers.
A trusted certificate path answers who issued a certificate. The application
must also check the expected signer and permitted key use before it accepts a
document signature. A TLS connection additionally needs the server's DNS name
and server authentication purpose.

Save the signing certificate as DER in `inkwell-signer.der` and your configured
root certificates as PEM in `inkwell-roots.pem`. This complete program checks
that path at the current time and prints the certificate's subject:

```bit
import { fromPem, x509Parse, x509VerifyPath } from "std/crypto"
import { readFile } from "std/fs"
import { now, Second } from "std/time"

fn main(): ()! {
  let signer = x509Parse([]byte(readFile("inkwell-signer.der")?))?
  let trust = fromPem(readFile("inkwell-roots.pem")?)?
  x509VerifyPath(signer, [], trust.roots, now().ns / Second)?
  println(signer.subject)
}
```

`x509VerifyPath` checks certificate signatures, validity times, issuer CA and
key-use restrictions, critical extensions, name constraints and path lengths.
An issuer sent with the certificate is not a trust anchor. Supply intermediate
certificates in the second argument and select roots from your own policy.
Success does not authenticate the document or select the signer's identity or
purpose. Check those separately. For HTTPS, use `std/tls`, which calls
`x509VerifyChain` and keeps the DNS-name and server-purpose checks.

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

Whether `hostname` matches `cert`'s subject-alternative names. The subject common name is not used.

### `x509VerifyChain(leaf: Certificate, intermediates: []Certificate, roots: []Certificate, hostname: string, nowUnix: int): ()!`

Verifies certificate `leaf` up through `intermediates` to a trusted root in `roots`, for `hostname`, as of `nowUnix`. `std/tls` calls this for you during a handshake.

### `x509VerifyPath(leaf: Certificate, intermediates: []Certificate, roots: []Certificate, nowUnix: int): ()!`

Checks the trusted certificate path shown above. Your application selects the
leaf identity and purpose; this function does not apply TLS server policy.

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

Read the [crypto safety notes](../crypto.md#security-notes) before using these
operations, or return to the [crypto guide](../crypto.md).
