# std/jwt

JSON Web Signatures (RFC 7515), registered claim validation (RFC 7519), and
JWKS key selection (RFC 7517). Every cryptographic primitive is `std/crypto`'s
own (HMAC-SHA256, RSA PKCS#1 v1.5, ECDSA P-256, Ed25519) — this module is the
JOSE format and validation layer on top, not a second implementation of any
primitive.

Four algorithms: `HS256`, `RS256`, `ES256`, `EdDSA`. `alg: none` has no
representation anywhere in this module and cannot be reached by
configuration — the classic JWT vulnerability. The verifying party always
supplies the expected algorithm as the shape of the key it passes
(`VerifyKey`'s variants); the token's own `alg` header can only be compared
against that expectation, never used to select behaviour, which is what
closes the RS256-to-HS256 algorithm-confusion attack.

<!-- doctest: per-block -->

## Signing and verifying

```bit
import { SigningKey, VerifyKey, sign, verify } from "std/jwt"
import { Json, JsonEntry, jsonGet, jsonAsString } from "std/json"

fn run(): ()! {
  let secret = []byte("a shared secret at least this long")
  let payload = Json.JsonObject([JsonEntry{ key: "sub", value: Json.JsonString("alice") }])

  let token = sign(SigningKey.Hs256Key(secret), payload)?
  let got = verify(token, VerifyKey.Hs256Key(secret))?
  let sub = jsonAsString(unwrap(jsonGet(got, "sub")))
  println(unwrapOr(sub, ""))
}

fn main() {
  run() catch e {
    println("failed: ${e.message()}")
  }
}
```

### `SigningKey`

An algorithm and its private key material, together: `Hs256Key([]byte)` (the
shared HMAC secret), `Rs256Key(RsaPrivateKey)`, `Es256Key(EcdsaPrivateKey)`,
`Ed25519Key([]byte)` (the 32-byte private seed). Build the RSA/ECDSA payloads
with `std/crypto`'s own key parsers/constructors, or `es256PrivateKey` below.

### `VerifyKey`

The verifying counterpart of `SigningKey`: `Hs256Key([]byte)`, `Rs256Key(RsaPublicKey)`,
`Es256Key(EcdsaPublicKey)`, `Ed25519Key([]byte)`. Which variant you pass to
`verify`/`verifyToken` **is** the algorithm you are willing to accept — there
is no separate algorithm argument that a token could disagree with.

### `signAlgName(key: SigningKey): string`

The JOSE `alg` name (`"HS256"`, `"RS256"`, `"ES256"`, `"EdDSA"`) a signing key
implies.

### `verifyAlgName(key: VerifyKey): string`

The JOSE `alg` name a verification key implies.

### `es256PublicKey(sec1: []byte): EcdsaPublicKey!`

The ES256 public key for the P-256 SEC1 point `sec1` (uncompressed or
compressed). Fixes the curve to P-256, so a caller cannot end up with a
P-384 key under the ES256 label.

### `es256PrivateKey(scalar: []byte): EcdsaPrivateKey!`

The ES256 private key for the big-endian scalar `scalar`.

### `es256PublicKeyFromCoords(x: []byte, y: []byte): EcdsaPublicKey!`

The ES256 public key built from raw JWK `x`/`y` coordinates (32 bytes each).

### `ecdsaSigToRaw(sig: EcdsaSignature): []byte!`

An ECDSA signature as the JWS raw `R || S` encoding (RFC 7518 §3.4) — never
the ASN.1/DER form.

### `ecdsaSigFromRaw(raw: []byte): EcdsaSignature!`

The inverse of `ecdsaSigToRaw`. Fails on any length other than 64 bytes.

### `sign(key: SigningKey, payload: Json): string!`

Sign `payload` as a compact JWS (`header.payload.signature`, base64url). The
header is always `{"alg":"<key's own algorithm>","typ":"JWT"}`.

### `verify(token: string, key: VerifyKey): Json!`

Verify `token`'s signature under `key` and return its payload. Rejects a
malformed token (wrong segment count, empty signature segment, non-URL-safe
base64), an `alg` header that disagrees with `key`'s algorithm, or an invalid
signature. The payload is decoded only after the signature has already been
accepted — no standard-claim validation; see `verifyToken`.

## Claim validation

```bit
import { VerifyKey, defaultClaimsOptions, verifyToken } from "std/jwt"

fn checkIt(token: string, key: VerifyKey, nowUnixSeconds: int): ()! {
  let opts = defaultClaimsOptions(nowUnixSeconds)
  let payload = verifyToken(token, key, opts)?
}

fn main() {}
```

### `ClaimsOptions`

`{ now: int, leewaySeconds: int, expectedIss: Option<string>, expectedAud: Option<string> }`.
`now` is the caller's own clock (Unix seconds) — never read from `std/time`
internally, so validation is deterministic and testable. `expectedIss`/
`expectedAud` default to `None`, meaning that check is skipped entirely.

### `defaultClaimsOptions(now: int): ClaimsOptions`

`ClaimsOptions` for `now` with a 60-second leeway and no `iss`/`aud` check.

### `validateClaims(payload: Json, opts: ClaimsOptions): ()!`

Validates `exp`, `nbf`, `iat` (each checked against `opts.now` with
`opts.leewaySeconds` skew) and, when set, `iss`/`aud`. Each violation fails
with its own distinct message.

### `verifyToken(token: string, key: VerifyKey, opts: ClaimsOptions): Json!`

`verify` followed by `validateClaims`, in that order.

## JWKS

```bit
import { VerifyKey, parseJwks, jwksFindByKid } from "std/jwt"

fn selectKey(doc: string, kid: string): VerifyKey! {
  let jwks = parseJwks(doc)?
  return jwksFindByKid(jwks, kid)?
}

fn main() {}
```

### `Jwk`

One key set entry: `{ kid: string, key: VerifyKey }`. `kid` is `""` when the
JWK carries none.

### `Jwks`

A parsed key set: `{ keys: []Jwk }`.

### `parseJwks(json: string): Jwks!`

Parse a `{"keys":[...]}` document. Supports `kty` values `RSA`, `EC`
(`crv: "P-256"` only), `OKP` (`crv: "Ed25519"` only), and `oct`. Fails on any
entry it cannot decode rather than silently skipping it.

### `jwksFindByKid(jwks: Jwks, kid: string): VerifyKey!`

The key whose `kid` equals `kid`. Fails when no entry matches.

### `refreshJwks(json: string): Jwks!`

Re-parses a JWKS document — the refresh entry point. Fetching one over the
network, and scheduling when to call this, are the caller's responsibility.
