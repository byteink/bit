# std/tls

Transport Layer Security 1.3 (RFC 8446), built from scratch in Bit on top of
[`std/crypto`](crypto.md). The module is layered: the **named groups** and their
`key_share` plumbing derive the (EC)DHE shared secret; the **cipher suites** bind
the negotiated AEAD, hash, and KDF; the **key schedule** is the HKDF ladder that
turns the pre-shared key and shared secret into every connection key; and the
**handshake messages** are the strict, hostile-input-safe wire encoders and
decoders the client and server halves are assembled from. Every piece composes
the verified `std/crypto` primitives rather than carrying a second copy of the
cryptography.

<!-- doctest: per-block -->

## Named groups

A named group is the (EC)DHE or KEM parameter set a TLS 1.3 handshake uses to
agree on a shared secret. `std/tls` supports four, each with its IANA
`NamedGroup` codepoint:

| Group | Codepoint | Kind | Reference |
|---|---|---|---|
| `x25519` | `0x001d` | X25519 ECDHE | RFC 7748 |
| `secp256r1` | `0x0017` | NIST P-256 ECDHE | RFC 8446 §4.2.7 |
| `secp384r1` | `0x0018` | NIST P-384 ECDHE | RFC 8446 §4.2.7 |
| `X25519MLKEM768` | `0x11ec` | ML-KEM-768 + X25519 hybrid | draft-ietf-tls-ecdhe-mlkem-05 |

The classical groups are symmetric Diffie-Hellman: each side generates an
ephemeral keypair and computes the shared secret from the peer's public share.
`X25519MLKEM768` is a post-quantum **hybrid** - a key-encapsulation mechanism, so
its two roles differ (the client publishes an ML-KEM encapsulation key; the
server encapsulates to it rather than generating a second keypair).

### `TlsGroup`

The supported named groups: `TlsGroup.X25519`, `TlsGroup.Secp256r1`,
`TlsGroup.Secp384r1`, and `TlsGroup.X25519MLKEM768`. A value of this type is
always one of these four, so group selection is total and cannot be invalid.

### `tlsGroupCodepoint(g: TlsGroup): u64`

The group's IANA `NamedGroup` codepoint, as it appears on the wire (e.g.
`0x11ec` for `X25519MLKEM768`). Use it to serialize a `supported_groups` or
`key_share` entry.

### `tlsGroupFromCodepoint(cp: u64): TlsGroup!`

The inverse of `tlsGroupCodepoint`: the `TlsGroup` a wire codepoint denotes, or
a failure if the codepoint is not one this implementation supports. Use it when
parsing a peer's advertised groups.

## Key exchange

A TLS 1.3 key exchange has three operations, split across the two roles. The
initiator (client) generates an ephemeral share; the responder (server) answers
that share and, in the same step, derives the shared secret; the initiator then
finishes from the responder's share. Both sides arrive at the identical secret,
which is fed to the TLS key schedule (HKDF) as input keying material.

```bit
import {
  TlsGroup,
  tlsGroupGenerate,
  tlsGroupResponder,
  tlsGroupComputeShared,
} from "std/tls"

// A full ephemeral key exchange for `group`: the client generates a share, the
// server answers it, and the client derives the same secret from the server's
// share. Returns the client's copy of the shared secret.
fn exchange(group: TlsGroup): []byte! {
  let client = tlsGroupGenerate(group)
  let response = tlsGroupResponder(group, client.keyShare)?
  return tlsGroupComputeShared(group, client.priv, response.keyShare)?
}
```

### `GroupKeypair`

An initiator's ephemeral key-exchange state. `priv` is the secret to retain
(the private scalar for a classical group, or `decapsulation_key ‖ x25519_priv`
for the hybrid); `keyShare` is the public value to send in the `key_share`
extension.

### `GroupResponse`

A responder's answer to an initiator's share. `keyShare` is the value to send
back; `shared` is the derived raw shared secret. For a KEM the two are produced
together (encapsulation yields both at once).

### `tlsGroupGenerate(g: TlsGroup): GroupKeypair`

Generate the initiator's ephemeral `key_share` for group `g` and the private
state to keep. Never fails - every group is a fresh keygen with no peer input to
reject. For the hybrid this generates both an ML-KEM-768 keypair and an X25519
keypair, packing the wire share as `ek ‖ x25519_pub` (1216 bytes).

### `tlsGroupComputeShared(g: TlsGroup, priv: []byte, peerKeyShare: []byte): []byte!`

The initiator's shared secret, from its retained `priv` state and the
responder's `peerKeyShare`. Fails if the peer's share is malformed or rejected
(an all-zero X25519 output or an invalid EC point - the contributory-behaviour
checks TLS requires). For the hybrid, the returned 64 bytes are
`mlkem_shared_secret ‖ x25519_shared_secret`.

### `tlsGroupResponder(g: TlsGroup, peerKeyShare: []byte): GroupResponse!`

The responder's one-shot answer to an initiator's `peerKeyShare` for group `g`:
the `key_share` to send back plus the derived shared secret. Fails if the
initiator's share is malformed or rejected. For classical groups this is
generate-then-compute; for the hybrid it encapsulates to the client's ML-KEM
encapsulation key and runs X25519, returning `ciphertext ‖ x25519_pub` (1120
bytes) as its share.

## The X25519MLKEM768 hybrid

The hybrid concatenates an ML-KEM-768 KEM with an X25519 ECDH so the handshake
stays secure if either primitive holds. Its byte layout follows
draft-ietf-tls-ecdhe-mlkem-05 exactly, and the concatenation **order** is the
single most common hybrid interop bug: `X25519MLKEM768` deliberately places the
ML-KEM part **first**, reversing the generic hybrid naming convention.

| Value | Layout | Size | Section |
|---|---|---|---|
| client `key_share` | `mlkem768_ek ‖ x25519_pub` | 1184 + 32 = 1216 | §4.1 |
| server `key_share` | `mlkem768_ct ‖ x25519_pub` | 1088 + 32 = 1120 | §4.2 |
| shared secret | `mlkem_ss ‖ x25519_ss` | 32 + 32 = 64 | §4.3 |

There is exactly one ML-KEM keypair - the client's. The client sends its
encapsulation key; the server encapsulates to it (producing the ciphertext and
the ML-KEM shared secret) and runs its own X25519 half; the client decapsulates
the ciphertext and runs the matching X25519 half. Both sides concatenate ML-KEM
first, then X25519, to reach the same 64-byte secret.

## Cipher suites

The TLS 1.3 cipher-suite registry (RFC 8446 §B.4, §9.1). A `CipherSuite` is a
pure descriptor - a code point, its registered name, and the four lengths a
record layer needs (AEAD key, the fixed 12-byte nonce, the tag, and the HKDF /
transcript-hash digest). Two builders turn a descriptor into live primitives:
`tlsSuiteNewAead` keys the suite's `Aead` from raw bytes and `tlsSuiteNewHash`
returns its `Hash`, both as `std/crypto` interfaces, so the handshake never
names AES-GCM versus ChaCha20-Poly1305 or SHA-256 versus SHA-384.

Only the three mandatory suites are registered. RFC 8446 §9.1 requires
`TLS_AES_128_GCM_SHA256` and recommends `TLS_AES_256_GCM_SHA384` and
`TLS_CHACHA20_POLY1305_SHA256`; TLS 1.3 removed every CBC/RC4/static-RSA suite,
so this is the whole modern set. `tlsSuitePreference` returns them strongest
first.

```bit
import { tlsSuitePreference, tlsSuiteNewAead, tlsSuiteNewHash } from "std/tls"

// Seal one record under the server's most-preferred suite. `key` and `nonce`
// come from the TLS 1.3 key schedule; `hashLen` (via the suite's `Hash`) sizes
// the transcript hash the same schedule feeds. `open` verifies-then-decrypts
// symmetrically and never returns unauthenticated bytes.
fn sealRecord(key: []byte, nonce: []byte, record: []byte, aad: []byte): []byte! {
  let suite = tlsSuitePreference()[0]
  let aead = tlsSuiteNewAead(suite, key)?
  let transcript = tlsSuiteNewHash(suite) // SHA-256 or SHA-384, per the suite
  transcript.write(record)
  return aead.seal(nonce, record, aad)
}
```

### `CipherSuite`

A TLS 1.3 cipher-suite descriptor: `id` (the IANA code point), `name` (its
registered string), `keyLen`/`ivLen`/`tagLen` (the AEAD's key, fixed record
nonce, and tag sizes), and `hashLen` (the suite's HKDF / transcript-hash digest
length). Obtain one from `tlsSuiteById` or `tlsSuitePreference` rather than a
struct literal, so every field stays consistent with the code point.

### `TLS_AES_128_GCM_SHA256: int`

The code point `0x1301`: AES-128-GCM with SHA-256. The one suite every TLS 1.3
implementation must support (RFC 8446 §9.1).

### `TLS_AES_256_GCM_SHA384: int`

The code point `0x1302`: AES-256-GCM with SHA-384.

### `TLS_CHACHA20_POLY1305_SHA256: int`

The code point `0x1303`: ChaCha20-Poly1305 with SHA-256.

### `tlsSuiteById(id: int): CipherSuite!`

The descriptor for code point `id`, or a failure if `id` is not one of the three
mandatory TLS 1.3 suites (this registry holds no legacy suites).

### `tlsSuitePreference(): []CipherSuite`

The registry's server preference order, strongest first, following OpenSSL's
default TLS 1.3 suites: AES-256-GCM, then ChaCha20-Poly1305, then AES-128-GCM. A
fresh slice each call, so a caller may reorder or filter it in place.

### `tlsSuiteNewAead(suite: CipherSuite, key: []byte): Aead!`

Key the suite's AEAD from `key`, returned as the `Aead` interface. Fails if `key`
is not the suite's `keyLen`, so a mis-sized key is a clean error rather than a
panic inside the underlying cipher constructor. The AEAD is fresh; the caller
owns the key material.

### `tlsSuiteNewHash(suite: CipherSuite): Hash`

A fresh `Hash` for the suite's transcript / HKDF digest - SHA-384 for
`TLS_AES_256_GCM_SHA384` (48-byte output), SHA-256 for the other two.

## Key schedule

The schedule is three `HKDF-Extract` rungs - Early, Handshake, Master - each one
mixing in a new input and feeding a family of `Derive-Secret` outputs, with the
two rungs joined by `Derive-Secret(., "derived", "")`:

```
PSK  -> Extract -> Early Secret
              Derive-Secret("derived")
ECDHE -> Extract -> Handshake Secret -> c/s hs traffic
              Derive-Secret("derived")
0    -> Extract -> Master Secret     -> c/s ap traffic, exporter, resumption
```

Every function is generic over the negotiated cipher suite's hash and takes a
hash *constructor* (`() => Hash`, e.g. `newSha256` or `newSha384`), asking it for
its own digest size rather than hard-coding one. A leaf traffic secret is then
unrolled into an AEAD `key` and `iv`, and - for the Finished message - a
`finished_key` MAC key, all by `HKDF-Expand-Label`.

The `TranscriptHash` accumulator keeps the running hash of the handshake
messages; its digest at each checkpoint is the `context` bound into the traffic
secrets and the Finished MAC.

```bit
import { Hash, newSha256 } from "std/crypto"
import { TranscriptHash, earlySecret, handshakeSecret } from "std/tls"
import { clientHandshakeTrafficSecret, trafficKey, trafficIV, finishedMac } from "std/tls"

// SHA-256 as the suite hash, wrapped as a `() => Hash`.
fn suite(): Hash { return newSha256() }

// From the ECDHE shared secret and the running transcript, derive the client's
// handshake write key and nonce, and the key that authenticates its Finished.
fn clientHandshake(ecdhe: []byte, t: TranscriptHash): []byte {
  let early = earlySecret(suite, []byte(0))          // no PSK: all-zero IKM
  let hs = handshakeSecret(suite, early, ecdhe)
  let chs = clientHandshakeTrafficSecret(suite, hs, t.sum())
  let key = trafficKey(suite, chs, 16)               // AES-128 key
  let iv = trafficIV(suite, chs, 12)                 // AEAD nonce
  let fin = finishedMac(suite, chs, t.sum())         // Finished verify_data
  return key
}
```

### `TranscriptHash`

The running hash of the handshake messages seen so far. One accumulator is fed
each message in wire order and read at every checkpoint; the `context` bound into
the traffic secrets and Finished MACs is its digest at that point.

### `newTranscript(newHash: () => Hash): TranscriptHash`

A fresh transcript accumulator over the suite hash built by `newHash`. Its digest
before any `update` is `Hash("")`, the empty transcript the inter-stage "derived"
secrets use.

### `TranscriptHash.update(data: []byte)`

Absorb one handshake message (full wire bytes, header included) into the running
transcript, in the order the messages appear on the wire.

### `TranscriptHash.sum(): []byte`

`Transcript-Hash` of the messages absorbed so far. Non-destructive: later
`update`s extend the same transcript, so this may be read at every checkpoint.

### `hkdfExpandLabel(newHash: () => Hash, secret: []byte, label: string, context: []byte, len: int): []byte`

`HKDF-Expand-Label` (RFC 8446 §7.1): expand `secret` to `len` bytes bound to the
`tls13 `-prefixed `label` and the `context`. The building block of every other
derivation in the schedule.

### `deriveSecret(newHash: () => Hash, secret: []byte, label: string, transcriptHash: []byte): []byte`

`Derive-Secret` (RFC 8446 §7.1): a full-digest-length child secret bound to the
handshake transcript - `HKDF-Expand-Label(secret, label, transcriptHash,
Hash.length)`.

### `earlySecret(newHash: () => Hash, psk: []byte): []byte`

The Early Secret, `HKDF-Extract(0, PSK)`. Pass an empty `psk` when there is no
pre-shared key; it becomes `HashLen` zero bytes, as the RFC requires.

### `handshakeSecret(newHash: () => Hash, early: []byte, ecdhe: []byte): []byte`

The Handshake Secret, `HKDF-Extract(Derive-Secret(early, "derived", ""), ECDHE)` -
mixes in the (EC)DHE shared secret. The handshake traffic secrets derive from it.

### `masterSecret(newHash: () => Hash, handshake: []byte): []byte`

The Master Secret, `HKDF-Extract(Derive-Secret(handshake, "derived", ""), 0)`.
The application, exporter, and resumption secrets derive from it.

### `clientHandshakeTrafficSecret(newHash: () => Hash, handshake: []byte, transcriptHash: []byte): []byte`

`Derive-Secret(handshake, "c hs traffic", ClientHello..ServerHello)` - the
client's handshake-record protection secret.

### `serverHandshakeTrafficSecret(newHash: () => Hash, handshake: []byte, transcriptHash: []byte): []byte`

`Derive-Secret(handshake, "s hs traffic", ClientHello..ServerHello)` - the
server's handshake-record protection secret.

### `clientApplicationTrafficSecret(newHash: () => Hash, master: []byte, transcriptHash: []byte): []byte`

`Derive-Secret(master, "c ap traffic", ClientHello..server Finished)` - the
initial client application-data secret.

### `serverApplicationTrafficSecret(newHash: () => Hash, master: []byte, transcriptHash: []byte): []byte`

`Derive-Secret(master, "s ap traffic", ClientHello..server Finished)` - the
initial server application-data secret.

### `exporterMasterSecret(newHash: () => Hash, master: []byte, transcriptHash: []byte): []byte`

`Derive-Secret(master, "exp master", ClientHello..server Finished)`, the root of
the exported-keying-material interface (RFC 8446 §7.5).

### `resumptionMasterSecret(newHash: () => Hash, master: []byte, transcriptHash: []byte): []byte`

`Derive-Secret(master, "res master", ClientHello..client Finished)`, from which
per-ticket resumption PSKs are computed.

### `trafficKey(newHash: () => Hash, secret: []byte, keyLen: int): []byte`

The AEAD write key for a traffic secret (RFC 8446 §7.3): `HKDF-Expand-Label(secret,
"key", "", keyLen)`. `keyLen` is the cipher's key size (16 for AES-128, 32 for
AES-256 / ChaCha20).

### `trafficIV(newHash: () => Hash, secret: []byte, ivLen: int): []byte`

The AEAD write nonce for a traffic secret (RFC 8446 §7.3): `HKDF-Expand-Label(secret,
"iv", "", ivLen)`. `ivLen` is 12 for every TLS 1.3 AEAD; it is XORed with the
record sequence number.

### `finishedKey(newHash: () => Hash, baseKey: []byte): []byte`

The Finished MAC key (RFC 8446 §4.4.4): `HKDF-Expand-Label(baseKey, "finished",
"", Hash.length)`, where `baseKey` is the sender's handshake traffic secret.

### `finishedMac(newHash: () => Hash, baseKey: []byte, transcriptHash: []byte): []byte`

The Finished message's `verify_data` (RFC 8446 §4.4.4): `HMAC(finishedKey(baseKey),
transcriptHash)`. The receiver recomputes it over its own transcript and compares
in constant time to authenticate the whole handshake.

The four functions below fill out the branches that hang off the Early Secret
rung when a pre-shared key is in play (RFC 8446 §7.1) - session resumption and
0-RTT (see [Session resumption and 0-RTT](#session-resumption-and-0-rtt)) never
change the ladder itself; `handshakeSecret`/`masterSecret` above are already
generic over `early`, only what feeds it and what is derived from it early
differs.

### `binderKey(newHash: () => Hash, early: []byte): []byte`

`binder_key` (RFC 8446 §7.1): `Derive-Secret(early, "res binder", "")`. Keys the
Finished-shaped MAC (`finishedMac`) that binds a ClientHello's `pre_shared_key`
identity to the PSK it claims. Only the resumption-PSK label is implemented -
this module has no external-PSK API.

### `clientEarlyTrafficSecret(newHash: () => Hash, early: []byte, clientHello1Hash: []byte): []byte`

`client_early_traffic_secret` (RFC 8446 §7.1): `Derive-Secret(early, "c e traffic",
clientHello1Hash)`. Protects the client's 0-RTT early application data and the
`end_of_early_data` message that closes it out.

### `earlyExporterMasterSecret(newHash: () => Hash, early: []byte, clientHello1Hash: []byte): []byte`

`early_exporter_master_secret` (RFC 8446 §7.1, §7.5): `Derive-Secret(early,
"e exp master", clientHello1Hash)`. The exporter root for 0-RTT data, valid
before the handshake completes and so without the full handshake's
forward-secrecy guarantee.

### `resumptionPsk(newHash: () => Hash, resumptionMasterSecret: []byte, ticketNonce: []byte): []byte`

The PSK a `NewSessionTicket`'s `nonce` derives from a connection's
resumption_master_secret (RFC 8446 §4.6.1): `HKDF-Expand-Label(
resumptionMasterSecret, "resumption", ticketNonce, Hash.length)`. Each ticket a
server issues carries its own nonce, so the same resumption_master_secret
yields a distinct, unlinkable PSK per ticket.


The wire encoding of the TLS 1.3 handshake (RFC 8446 §4): the `Handshake`
framing and a typed encoder/decoder for every message a 1-RTT exchange carries.
This is the byte layer the client and server halves of the protocol are built
from - it does no cryptography and drives no connection, it only turns handshake
messages to and from bytes.

Each message maps to a struct with exported fields. `encode*` serializes one
into a complete Handshake-framed message (the one-byte type, the three-byte
length, then the body); `parse*` is the strict inverse. Parsing is written for
hostile input: every `parse*` returns `T!`, a declared length that runs past the
buffer fails, and a message - or extension block, certificate list, or extension
body - with bytes left over is rejected rather than best-guessed.

An `Extension` is generic: a two-byte type and its raw body bytes. A message
never interprets the extensions it carries, so any extension round-trips
byte-for-byte, whether or not this module has a typed helper for it. The typed
`ext*` builders and `parse*` readers interpret the bodies of the extensions a
handshake negotiates over - server name, ALPN, supported versions, supported
groups, key share, and signature algorithms.

```bit
import {
  ClientHello, Extension, KeyShareEntry,
  encodeClientHello, parseClientHello,
  extServerName, parseServerName,
  extSupportedVersionsClient, extKeyShareClient,
  handshakeType, hsClientHello, versionTls13, groupX25519,
} from "std/tls"

// Build a minimal TLS 1.3 ClientHello, serialize it, and read it back.
fn demo(): string! {
  let exts = []Extension(0)
  exts = append(exts, extServerName("example.com"))
  exts = append(exts, extSupportedVersionsClient([versionTls13]))
  let shares = []KeyShareEntry(0)
  shares = append(shares, KeyShareEntry{ group: groupX25519, keyExchange: []byte(32) })
  exts = append(exts, extKeyShareClient(shares))

  let hello = ClientHello{
    legacyVersion: 0x0303,
    random: []byte(32),
    sessionId: []byte(0),
    cipherSuites: [0x1301],
    extensions: exts,
  }
  let wire = encodeClientHello(hello)

  if (handshakeType(wire)? != hsClientHello) {
    fail newError("not a ClientHello")
  }
  let back = parseClientHello(wire)?
  return parseServerName(back.extensions[0])?
}
```

## Handshake messages

### `handshakeType(msg: []byte): int!`

The message type of a Handshake-framed message - its first byte - without
decoding the body. Fails on an empty buffer. Dispatch on it to pick the right
`parse*` before you know which message you hold.

### `Extension`

One TLS extension: a two-byte `extType` and its raw body `data`. Generic by
design, so a message round-trips any extension byte-identically; the typed
`ext*`/`parse*` helpers interpret `data` for the extensions that carry it.

### `KeyShareEntry`

One key-share offer: a named `group` and the raw `keyExchange` (public key)
bytes for it. The value the `key_share` extension carries.

### `ClientHello`

A ClientHello: `legacyVersion` (0x0303), a 32-byte `random`, the legacy
`sessionId`, the offered `cipherSuites`, and `extensions`. The single null
compression method TLS 1.3 mandates is implicit - written on encode, required on
decode.

### `encodeClientHello(ch: ClientHello): []byte`

The Handshake-framed encoding of `ch`. `ch.random` must be 32 bytes.

### `parseClientHello(msg: []byte): ClientHello!`

Parse a Handshake-framed ClientHello, rejecting a wrong type, a non-TLS-1.3
compression list, or trailing bytes.

### `ServerHello`

A ServerHello: like `ClientHello` but with a single selected `cipherSuite` and
no compression list. A HelloRetryRequest shares this framing - detect it with
`isHelloRetryRequest`.

### `encodeServerHello(sh: ServerHello): []byte`

The Handshake-framed encoding of `sh`. `sh.random` must be 32 bytes.

### `parseServerHello(msg: []byte): ServerHello!`

Parse a Handshake-framed ServerHello (or HelloRetryRequest), rejecting a
non-zero compression method or trailing bytes.

### `isHelloRetryRequest(sh: ServerHello): bool`

Whether `sh` is a HelloRetryRequest: its `random` equals the RFC 8446
SHA-256("HelloRetryRequest") sentinel.

### `EncryptedExtensions`

The EncryptedExtensions message: the server's responses to the ClientHello's
non-security extensions, its only field a list of `extensions`.

### `encodeEncryptedExtensions(ee: EncryptedExtensions): []byte`

The Handshake-framed encoding of `ee`.

### `parseEncryptedExtensions(msg: []byte): EncryptedExtensions!`

Parse a Handshake-framed EncryptedExtensions.

### `CertificateEntry`

One entry of a certificate chain: the raw `cert` (a DER-encoded X.509
certificate) and its per-certificate `extensions`.

### `Certificate`

A Certificate message: an opaque `certRequestContext` (empty in a server's
initial handshake) and the chain of `entries`, end-entity certificate first.

### `encodeCertificate(c: Certificate): []byte`

The Handshake-framed encoding of `c`.

### `parseCertificate(msg: []byte): Certificate!`

Parse a Handshake-framed Certificate.

### `CertificateVerify`

A CertificateVerify message: the signature `algorithm` and the `signature` over
the handshake transcript.

### `encodeCertificateVerify(cv: CertificateVerify): []byte`

The Handshake-framed encoding of `cv`.

### `parseCertificateVerify(msg: []byte): CertificateVerify!`

Parse a Handshake-framed CertificateVerify.

### `Finished`

A Finished message: the `verifyData` HMAC over the transcript, its length fixed
by the negotiated hash.

### `encodeFinished(f: Finished): []byte`

The Handshake-framed encoding of `f`. The whole body is `verifyData`.

### `parseFinished(msg: []byte): Finished!`

Parse a Handshake-framed Finished; the whole body is the verify data.

### `NewSessionTicket`

A NewSessionTicket message (RFC 8446 §4.6.1): a resumption ticket with its
`lifetime` seconds, the `ageAdd` obfuscation value, a `nonce`, the opaque
`ticket`, and `extensions`.

### `encodeNewSessionTicket(t: NewSessionTicket): []byte`

The Handshake-framed encoding of `t`.

### `parseNewSessionTicket(msg: []byte): NewSessionTicket!`

Parse a Handshake-framed NewSessionTicket.

## Extensions

The `ext*` builders return an `Extension` ready to place in a message's
`extensions`; the `parse*` readers take one back apart. `supported_versions` and
`key_share` differ between ClientHello and ServerHello, so each has a `Client`
and a `Server` form.

### `extServerName(host: string): Extension`

A `server_name` (SNI) extension naming a single `host_name` host.

### `parseServerName(e: Extension): string!`

The host of a `server_name` extension's first `host_name` entry. Fails on any
other name type or on trailing bytes.

### `extALPN(protocols: []string): Extension`

An ALPN extension offering `protocols` in order (e.g. `["h2", "http/1.1"]`).

### `parseALPN(e: Extension): []string!`

The protocol names of an ALPN extension, in order.

### `extSupportedGroups(groups: []int): Extension`

A `supported_groups` extension listing the named `groups` offered.

### `parseSupportedGroups(e: Extension): []int!`

The named groups of a `supported_groups` extension.

### `extSignatureAlgorithms(schemes: []int): Extension`

A `signature_algorithms` extension listing the `schemes` offered.

### `parseSignatureAlgorithms(e: Extension): []int!`

The schemes of a `signature_algorithms` extension.

### `extSupportedVersionsClient(versions: []int): Extension`

A ClientHello `supported_versions` extension offering `versions` (a one-byte-
length list). Offer `[versionTls13]` for TLS 1.3.

### `parseSupportedVersionsClient(e: Extension): []int!`

The versions of a ClientHello `supported_versions` extension.

### `extSupportedVersionsServer(version: int): Extension`

A ServerHello `supported_versions` extension carrying the single selected
`version` (two bare bytes, no list).

### `parseSupportedVersionsServer(e: Extension): int!`

The selected version of a ServerHello `supported_versions` extension. Fails
unless it is exactly two bytes.

### `extKeyShareClient(entries: []KeyShareEntry): Extension`

A ClientHello `key_share` extension carrying the offered `entries` (a
length-prefixed list).

### `parseKeyShareClient(e: Extension): []KeyShareEntry!`

The entries of a ClientHello `key_share` extension.

### `extKeyShareServer(entry: KeyShareEntry): Extension`

A ServerHello `key_share` extension carrying the single selected `entry` (no
list prefix).

### `parseKeyShareServer(e: Extension): KeyShareEntry!`

The selected entry of a ServerHello `key_share` extension.

## Constants

### `versionTls12: int`

TLS 1.2 (0x0303) - the ClientHello/ServerHello `legacy_version`.

### `versionTls13: int`

TLS 1.3 (0x0304) - the value carried in `supported_versions`.

### `hsClientHello: int`

HandshakeType client_hello (1).

### `hsServerHello: int`

HandshakeType server_hello (2), also a HelloRetryRequest's framing.

### `hsNewSessionTicket: int`

HandshakeType new_session_ticket (4).

### `hsEncryptedExtensions: int`

HandshakeType encrypted_extensions (8).

### `hsCertificate: int`

HandshakeType certificate (11).

### `hsCertificateVerify: int`

HandshakeType certificate_verify (15).

### `hsFinished: int`

HandshakeType finished (20).

### `extTypeServerName: int`

ExtensionType server_name (0) - SNI.

### `extTypeSupportedGroups: int`

ExtensionType supported_groups (10).

### `extTypeSignatureAlgorithms: int`

ExtensionType signature_algorithms (13).

### `extTypeALPN: int`

ExtensionType application_layer_protocol_negotiation (16) - ALPN.

### `extTypeSupportedVersions: int`

ExtensionType supported_versions (43).

### `extTypeKeyShare: int`

ExtensionType key_share (51).

### `sigEcdsaSecp256r1Sha256: int`

SignatureScheme ecdsa_secp256r1_sha256 (0x0403).

### `sigEcdsaSecp384r1Sha384: int`

SignatureScheme ecdsa_secp384r1_sha384 (0x0503).

### `sigRsaPssRsaeSha256: int`

SignatureScheme rsa_pss_rsae_sha256 (0x0804).

### `sigRsaPssRsaeSha384: int`

SignatureScheme rsa_pss_rsae_sha384 (0x0805).

### `sigRsaPssRsaeSha512: int`

SignatureScheme rsa_pss_rsae_sha512 (0x0806).

### `sigEd25519: int`

SignatureScheme ed25519 (0x0807).

### `groupSecp256r1: int`

NamedGroup secp256r1 (0x0017).

### `groupSecp384r1: int`

NamedGroup secp384r1 (0x0018).

### `groupX25519: int`

NamedGroup x25519 (0x001d).

### `groupX448: int`

NamedGroup x448 (0x001e).
## Record layer

The record layer (RFC 8446 §5) is the frame every TLS message travels in. Once
traffic keys exist, each record is an AEAD-protected `TLSCiphertext`: its outer
`opaque_type` is always `application_data(23)` and the true content type moves
inside the sealed body, `content ‖ real_content_type ‖ zero_padding`. Protection
is deterministic - the per-record nonce is the fixed traffic IV XORed with the
64-bit record sequence number, and the AEAD's additional data is exactly the
five-byte record header. Sequence numbers are **per direction** and reset to zero
on every key change, so a read context and a write context each keep their own
counter.

`RecordKeys` binds one direction's key, IV, sequence counter, and cipher suite.
`seal` protects an outbound fragment (≤ 2^14 octets); `open` recovers an inbound
one, rejecting any record whose ciphertext exceeds 2^14 + 256 octets or whose AEAD
tag fails - a failed `open` is fatal (`bad_record_mac`) and is never retried.
`keyUpdate` re-derives the direction's key and IV from the next
application-traffic secret (RFC 8446 §7.2) and rewinds the counter to zero. Both
sides are keyed from a traffic secret produced by the [key schedule](#key-schedule).

```bit
import { tlsSuiteById, TLS_AES_128_GCM_SHA256 } from "std/tls"
import { newRecordKeys, recordApplicationData } from "std/tls"

// Protect one outbound fragment and recover it, both contexts keyed from the
// same application-traffic secret (one per direction in a real connection).
fn roundtrip(secret: []byte, msg: []byte): []byte! {
  let suite = tlsSuiteById(TLS_AES_128_GCM_SHA256)?
  let writer = newRecordKeys(suite, secret)?
  let reader = newRecordKeys(suite, secret)?

  let record = writer.seal(msg, recordApplicationData)?   // TLSCiphertext on the wire
  let opened = reader.open(record)?                        // -> content + content type
  writer.keyUpdate()?                                      // rotate key, reset sequence to 0
  return opened.content
}
```

### `RecordKeys`

One direction's record-protection state: the negotiated suite, current traffic
secret, keyed AEAD, fixed IV, and the monotonic sequence number. Its fields are
private - build one with `newRecordKeys` and mutate it only through the methods,
so the sequence number can never desynchronise from the nonce it feeds.

### `RecordPlaintext`

The result of `open`: the recovered `content: []byte` and the `contentType: int`
that was hidden inside the protected record.

### `newRecordKeys(suite: CipherSuite, secret: []byte): RecordKeys!`

A record-protection context for one direction, from its traffic `secret` and the
negotiated `suite`. Unrolls the secret into the AEAD key and fixed IV via
HKDF-Expand-Label and keys the suite's AEAD; the sequence number starts at zero.
Fails only if the suite rejects the derived key length.

### `RecordKeys.seal(plaintext: []byte, contentType: int): []byte!`

Protect `plaintext` as a `TLSCiphertext` record carrying inner `contentType`,
returning the full on-the-wire record (five-byte header ‖ AEAD output) and
advancing the sequence number. Fails if the fragment exceeds the 2^14 plaintext
cap. No padding is added.

### `RecordKeys.open(record: []byte): RecordPlaintext!`

Recover the inner content of a protected `record` (full on-the-wire bytes, header
included) and advance the sequence number. Fails - fatally, with no retry - on a
truncated header, an over-long ciphertext (> 2^14 + 256), a header/length
mismatch, or an AEAD authentication failure (`bad_record_mac`).

### `RecordKeys.keyUpdate(): ()!`

Advance this direction to its next traffic key (RFC 8446 §7.2): derive
`application_traffic_secret_{N+1}` with `HKDF-Expand-Label(secret, "traffic upd",
"", Hash.length)`, re-derive the key and IV from it, and reset the sequence number
to zero. Fails only if the suite rejects the re-derived key length.

### `RecordKeys.sequence(): int`

This direction's current record sequence number - the counter the next `seal` or
`open` will use, `0` on a fresh context or just after `keyUpdate`.

### `RecordKeys.nonce(): []byte`

The AEAD nonce the next `seal`/`open` will use: the fixed IV XORed with the
current sequence number. Exposed for diagnostics and to observe nonce progression
across records.

### `recordAlert: int`

Inner content type alert (21).

### `recordHandshake: int`

Inner content type handshake (22) - the type carried by protected handshake
records such as EncryptedExtensions, Certificate, and Finished.

### `recordApplicationData: int`

Inner content type application_data (23), and the fixed outer `opaque_type` of
every protected record.
## Client handshake

The 1-RTT client half of the protocol (RFC 8446), assembled from the pieces
above. It is **sans-I/O**: the handshake owns no sockets, so the caller drives it
by shuttling flights of raw record bytes, over a TCP stream, an in-memory pipe, or
a recorded trace alike. Server authentication is the security core and is always
enforced - the certificate chain is verified against a caller-supplied
[`TrustStore`](#-truststore-) and the SNI hostname, the server's CertificateVerify
signature is checked over the RFC 8446 §4.4.3 signed content, and the server
Finished MAC is checked in constant time; any failure aborts the handshake.
`insecureSkipVerify` drops only the chain + hostname checks (for pinned-key or
trace-replay callers), never the signature or the MAC.

```bit
import { TlsClientConfig, tlsClientStart, TlsClientConn } from "std/tls"

// A complete client handshake over a caller-provided record transport: `send`
// writes one of our flights, `recv` yields the server's next flight. The retry
// loop resends after a HelloRetryRequest; the returned connection carries the
// application-traffic keys.
fn handshake(config: TlsClientConfig, send: ([]byte) => ()!, recv: () => []byte!): TlsClientConn! {
  let h = tlsClientStart(config)?
  send(h.hello)?
  let step = h.processServerFlight(recv()?)?
  while (step.retry) {
    send(step.outbound)?
    step = h.processServerFlight(recv()?)?
  }
  send(step.outbound)?
  return h.connection()?
}
```

### `TrustStore`

The set of trusted root certificates a server chain is verified up to (RFC 8446
§4.4.2). Its `roots` are parsed X.509 certificates (`std/crypto`'s `Certificate`);
build one from a PEM bundle with `newTrustStore`, or from already-parsed roots via
the struct literal.

### `newTrustStore(rootsPem: string): TrustStore!`

A `TrustStore` from a PEM bundle of one or more `CERTIFICATE` blocks - the usual
system-roots format. Fails on malformed PEM, a certificate the X.509 parser
rejects, or a bundle with no `CERTIFICATE` block.

```bit
import { newTrustStore, TrustStore } from "std/tls"

// Parse a PEM roots bundle into a trust store for a client config.
fn roots(pem: string): TrustStore! {
  return newTrustStore(pem)?
}
```

### `TlsClientConfig`

A client handshake configuration: `serverName` (the SNI host and the name the
certificate must match), `alpn` (protocols offered, preferred first), `trust` (the
roots to verify against), `insecureSkipVerify` (skip chain + hostname only),
`nowUnix` (the time for certificate validity), `groups` (named groups offered,
preferred first), `keyShareGroups` (the subset of `groups` to actually send a
key_share for - empty means all; a group offered but not shared is what a server
requests via HelloRetryRequest), `suites` (cipher suites offered - empty means all
three mandatory suites), and the advanced `clientHelloOverride` /
`ephemeralOverride` (an exact ClientHello and pinned ephemeral keypairs, for
deterministic replay).

### `tlsClientStart(config: TlsClientConfig): TlsClientHandshake!`

Start a handshake: build the ClientHello (or adopt `config.clientHelloOverride`),
seed the transcript, and expose the ClientHello record to send as `hello`. Fails
only if the default record context cannot be built.

```bit
import { newTrustStore, TlsClientConfig, tlsClientStart, TlsGroup, GroupKeypair } from "std/tls"

// Configure a client that authenticates against a PEM root bundle and offers the
// post-quantum hybrid plus X25519, then start the handshake. `h.hello` is the
// first flight to send.
fn begin(rootsPem: string): []byte! {
  let config = TlsClientConfig{
    serverName: "example.com",
    alpn: ["h2", "http/1.1"],
    trust: newTrustStore(rootsPem)?,
    insecureSkipVerify: false,
    nowUnix: 1700000000,
    groups: [TlsGroup.X25519MLKEM768, TlsGroup.X25519],
    keyShareGroups: []TlsGroup(0),
    suites: []int(0),
    clientHelloOverride: []byte(0),
    ephemeralOverride: []GroupKeypair(0),
  }
  let h = tlsClientStart(config)?
  return h.hello
}
```

### `TlsClientHandshake`

The in-progress client handshake. Its only public surface is `hello` (the
ClientHello record to send first) and the two methods below; everything else is
derived as the handshake advances.

### `TlsClientHandshake.processServerFlight(flight: []byte): TlsClientStep!`

Process one server flight of raw record bytes. Returns a `retry` step on a
HelloRetryRequest (resend `outbound`, then feed the next flight) or a `done` step
carrying the client Finished to send. Fails - fatally - on any parse error or
authentication failure (bad certificate chain, CertificateVerify signature, or
server Finished MAC).

### `TlsClientHandshake.connection(): TlsClientConn!`

The completed connection, valid once `processServerFlight` returned a `done` step.
Fails if called before the handshake has finished.

```bit
import { TlsClientHandshake, TlsClientConn } from "std/tls"

// Feed the server's flight to a started handshake and, once it reports done,
// take the application connection.
fn finish(h: TlsClientHandshake, serverFlight: []byte): TlsClientConn! {
  let step = h.processServerFlight(serverFlight)?
  if (!step.done) {
    fail newError("handshake needs another round")
  }
  return h.connection()?
}
```

### `TlsClientStep`

One step of the client handshake from `processServerFlight`: `retry` (a
HelloRetryRequest was received - resend `outbound`), `done` (the handshake
completed - `outbound` is the client Finished to send), and `outbound` (the
record(s) to send now).

### `TlsClientConn`

A completed client connection: the negotiated parameters and the two
application-data record contexts. Obtain it from `TlsClientHandshake.connection`.

### `TlsClientConn.cipherSuiteId(): int`

The negotiated cipher suite's IANA code point.

### `TlsClientConn.alpnProtocol(): string`

The ALPN protocol the server selected, or "" if none was negotiated.

### `TlsClientConn.peerCertificates(): [][]byte`

The server's certificate chain as raw DER, end-entity certificate first.

### `TlsClientConn.exporterSecret(): []byte`

The exporter_master_secret (RFC 8446 §7.5), the root for exported keying material
bound to this handshake.

### `TlsClientConn.resumptionSecret(): []byte`

The resumption_master_secret (RFC 8446 §7.1), from which a server-issued ticket's
PSK is computed.

### `TlsClientConn.sealApp(plaintext: []byte): []byte!`

Seal `plaintext` as one outbound application_data record under the client's
application-traffic key, advancing its sequence number. Fails if the fragment
exceeds the 2^14 record limit.

### `TlsClientConn.openApp(record: []byte): RecordPlaintext!`

Open one inbound protected record under the server's application-traffic key,
returning the recovered content and its inner type - `recordHandshake` for a
post-handshake message (NewSessionTicket / KeyUpdate), `recordApplicationData` for
caller data. Fails fatally on an authentication failure.

```bit
import { TlsClientConn } from "std/tls"

// Send a request and read the response over a live connection.
fn roundtrip(conn: TlsClientConn, request: []byte): []byte! {
  let record = conn.sealApp(request)?
  let reply = conn.openApp(record)?
  return reply.content
}
```

## Server handshake

The 1-RTT server half - the mirror of the client. It negotiates a cipher suite and
a named group from the ClientHello, answers with a ServerHello key_share (or a
HelloRetryRequest when the client shared no acceptable group), sends its
authentication flight (EncryptedExtensions, its Certificate chain, a
CertificateVerify signed with the server's private key, and Finished) under the
handshake-traffic key, then verifies the client Finished MAC in constant time
before switching to application-traffic keys. The certificate chain and RSA key
are loaded from PEM by `newTlsServerConfig`; CertificateVerify is signed with
RSA-PSS (`rsa_pss_rsae_sha256`).

```bit
import { TlsServerConfig, tlsServerStart, TlsServerConn } from "std/tls"

// A complete server handshake over a caller-provided record transport: `send`
// writes one of our flights, `recv` yields the client's next flight. The retry
// loop follows a HelloRetryRequest; the returned connection carries the
// application-traffic keys.
fn serve(config: TlsServerConfig, send: ([]byte) => ()!, recv: () => []byte!): TlsServerConn! {
  let s = tlsServerStart(config)?
  let step = s.processClientHello(recv()?)?
  while (step.retry) {
    send(step.outbound)?
    step = s.processClientHello(recv()?)?
  }
  send(step.outbound)?
  return s.processClientFinished(recv()?)?
}
```

### `TlsServerConfig`

A server handshake configuration: the certificate `chain` (raw DER, end-entity
certificate first), the RSA private `key` matching the leaf, the supported `alpn`
protocols (preference order), the acceptable key-exchange `groups` (preference
order), and the acceptable cipher `suites` (preference order). Build one from PEM
with `newTlsServerConfig`.

### `newTlsServerConfig(certChainPem: string, keyPem: string, alpn: []string): TlsServerConfig!`

A `TlsServerConfig` from PEM: `certChainPem` is one or more concatenated
`CERTIFICATE` blocks (end-entity first), `keyPem` is the leaf's RSA private key as
a `PRIVATE KEY` (PKCS#8) or `RSA PRIVATE KEY` (PKCS#1) block, and `alpn` is the
supported protocol list. Groups and suites default to the full supported sets.
Fails on malformed PEM, an empty chain, or an unreadable key.

```bit
import { newTlsServerConfig, TlsServerConfig } from "std/tls"

// Load a server's leaf certificate and RSA key from PEM, offering HTTP/2 + 1.1.
fn configure(certPem: string, keyPem: string): TlsServerConfig! {
  return newTlsServerConfig(certPem, keyPem, ["h2", "http/1.1"])?
}
```

### `tlsServerStart(config: TlsServerConfig): TlsServerHandshake!`

Start a server handshake. The returned state produces no output until the first
ClientHello is fed to `processClientHello`.

### `TlsServerHandshake`

The in-progress server handshake. Drive it with `processClientHello` then
`processClientFinished`.

### `TlsServerHandshake.processClientHello(flight: []byte): TlsServerStep!`

Process a ClientHello flight. Returns a `retry` step carrying a HelloRetryRequest
when the client shared no acceptable group, or a step whose `outbound` is the
ServerHello followed by the encrypted authentication flight. Fails on any parse
error, an absent common suite or group, or a signing failure.

### `TlsServerHandshake.processClientFinished(flight: []byte): TlsServerConn!`

Verify the client Finished and complete the handshake, returning the application
connection. Fails on a parse error or a Finished MAC that does not match in
constant time.

```bit
import { tlsServerStart, TlsServerConfig, TlsServerConn } from "std/tls"

// Complete a handshake with no HelloRetryRequest: one ClientHello, then the
// client Finished.
fn accept(config: TlsServerConfig, clientHello: []byte, clientFinished: []byte): TlsServerConn! {
  let s = tlsServerStart(config)?
  let step = s.processClientHello(clientHello)?
  if (step.retry) {
    fail newError("client needs a HelloRetryRequest")
  }
  return s.processClientFinished(clientFinished)?
}
```

### `TlsServerStep`

One step from `processClientHello`: `retry` (a HelloRetryRequest was produced -
send `outbound` and feed the next ClientHello) and `outbound` (the record(s) to
send now - the HelloRetryRequest, or the ServerHello plus the encrypted flight).

### `TlsServerConn`

A completed server connection: the negotiated parameters and the two
application-data record contexts. Obtain it from `processClientFinished`.

### `TlsServerConn.cipherSuiteId(): int`

The negotiated cipher suite's IANA code point.

### `TlsServerConn.alpnProtocol(): string`

The ALPN protocol negotiated with the client, or "" if none.

### `TlsServerConn.exporterSecret(): []byte`

The exporter_master_secret (RFC 8446 §7.5) for exported keying material.

### `TlsServerConn.resumptionSecret(): []byte`

The resumption_master_secret (RFC 8446 §7.1) for issuing session tickets.

### `TlsServerConn.sealApp(plaintext: []byte): []byte!`

Seal `plaintext` as one outbound application_data record under the server's
application-traffic key, advancing its sequence number. Fails if the fragment
exceeds the 2^14 record limit.

### `TlsServerConn.openApp(record: []byte): RecordPlaintext!`

Open one inbound protected record under the client's application-traffic key,
returning the recovered content and its inner type. Fails fatally on an
authentication failure.

```bit
import { TlsServerConn } from "std/tls"

// Read one client request and reply over a live connection.
fn respond(conn: TlsServerConn, incoming: []byte): []byte! {
  let request = conn.openApp(incoming)?
  return conn.sealApp(request.content)?
}
```

## Session resumption and 0-RTT

Session resumption (RFC 8446 §2.3, §4.6.1) lets a client skip certificate-based
authentication on a later connection to the same server by presenting a PSK
derived from an earlier handshake instead. A server that finishes a handshake
may call `TlsServerConn.issueTicket` to hand the client an opaque ticket, sealed
as a post-handshake record exactly like any other message `TlsClientConn.openApp`
recovers as a `recordHandshake`-typed record. The client bundles the ticket with
the connection's `resumptionSecret()` into a `SessionTicket` (via
`newSessionTicket`) and, on a later connection, drives `tlsClientStartResume`
instead of `tlsClientStart`. That builds a ClientHello carrying
`psk_key_exchange_modes` (PSK with (EC)DHE, `psk_dhe_ke` - this module does not
implement the no-DHE `psk_ke` mode) and `pre_shared_key` (the ticket as the
offered identity, with a binder proving possession of the PSK the ticket
derives). The server validates the binder and, on success, skips Certificate
and CertificateVerify entirely - the PSK already authenticates the connection.

**0-RTT early data is replayable.** An attacker who captures a ClientHello plus
its early-data flight can replay it verbatim, and the server has no way to tell
a replay from the original: RFC 8446 §8 gives servers only mitigations
(single-use tickets, ClientHello recording within a short window), never a
guarantee, and this module implements neither. An application **must** treat
any request that might arrive as 0-RTT data as safe to execute more than once
(idempotent) - a `GET`, never a fund transfer. `TlsServerHandshake.earlyDataReceived`
exists to let a caller apply exactly that discipline; the module cannot enforce
it for you.

### `PskIdentity`

One `pre_shared_key` identity entry: the opaque ticket bytes (`identity`) and
the client's (obfuscated) estimate of how long ago it received the ticket
(`obfuscatedTicketAge`). `tlsClientStartResume` always sends an
`obfuscatedTicketAge` of 0 - this module does not track wall-clock ticket age,
a valid if maximally conservative value on the wire.

### `SessionTicket`

What a client keeps, after a connection closes, to attempt resumption on a
later one: the raw ticket and nonce a `NewSessionTicket` carried, the
connection's resumption_master_secret, and enough of the original connection's
parameters (`suiteId`, `alpn`) to rebuild a compatible offer. Build one with
`newSessionTicket`; store it however the caller likes - in memory, keyed by
server name, is enough for most uses. No persistence or session-cache
abstraction is built in.

### `newSessionTicket(nst: NewSessionTicket, conn: TlsClientConn): SessionTicket`

A `SessionTicket` from a `NewSessionTicket` message and the connection it
arrived on.

### `TlsTicketStore`

A server-lifetime store of issued tickets. Every handshake driven from the same
`TlsServerConfig` shares one store (`newTlsServerConfig` gives each config its
own), so a ticket issued on one connection can be redeemed on a later,
independent one.

### `newTicketStore(): TlsTicketStore`

An empty ticket store. `newTlsServerConfig` already creates one per config; call
this directly only when building a `TlsServerConfig` by hand.

### `TlsServerConn.issueTicket(): []byte!`

Issue a `NewSessionTicket` for this connection: mint fresh ticket and nonce
bytes, record the session (resumption secret, suite, whether 0-RTT is allowed
on it - `TlsServerConfig.allowEarlyData` at the time of the original handshake)
in the connection's ticket store, and return the sealed post-handshake record
to send. The caller decides when - and whether - to call this, same as
`sealApp`; a server that never calls it simply never offers resumption.

### `tlsClientStartResume(config: TlsClientConfig, session: SessionTicket, earlyData: []byte): TlsClientHandshake!`

Start a client handshake attempting session resumption with `session`, the
PSK-DHE mode, and - when `earlyData` is non-empty - 0-RTT early application
data sent speculatively in the same flight as the ClientHello, before the
server has replied at all. The server may still decline the PSK entirely
(falling back to a fresh handshake - detect this via `pskWasAccepted()` once
connected) or accept the PSK but decline early data (`earlyDataAccepted` stays
false on the resulting `TlsClientHandshake`); in the latter case the caller
must resend `earlyData` itself as ordinary application data once connected -
this module does not buffer or auto-retry it.

### `TlsClientHandshake.pskWasAccepted(): bool`

Whether the server accepted the PSK this handshake offered - meaningful only
after `processServerFlight` has processed the ServerHello. False for a
handshake that never called `tlsClientStartResume`, and also false when the
server declined the PSK and fell back to a fresh handshake (Certificate
included).

### `TlsServerHandshake.pskWasAccepted(): bool`

The server-side mirror of `TlsClientHandshake.pskWasAccepted`. Meaningful once
`processClientHello` has run.

### `TlsServerHandshake.earlyDataWasAccepted(): bool`

Whether this handshake accepted the client's 0-RTT early data. When true,
`earlyDataReceived()` holds it.

### `TlsServerHandshake.earlyDataReceived(): []byte`

The 0-RTT early application data this handshake decrypted, concatenated in the
order the client sent it. Empty unless `earlyDataWasAccepted()`. **Replayable -
see this section's opening caveat** - treat it as safe to process more than
once before acting on it.

```bit
import {
  TlsServerConn, TlsClientConn, TlsClientConfig, TlsClientHandshake,
  SessionTicket, tlsClientStartResume, newSessionTicket, parseNewSessionTicket,
} from "std/tls"

// After a full handshake, hand the client a ticket to resume with later.
fn issue(serverConn: TlsServerConn): []byte! {
  return serverConn.issueTicket()?
}

// The client stores the ticket, then later resumes with it - optionally
// attempting 0-RTT by passing early application data (must be idempotent).
fn storeAndResume(
  clientConn: TlsClientConn,
  ticketRecord: []byte,
  config: TlsClientConfig,
): TlsClientHandshake! {
  let pt = clientConn.openApp(ticketRecord)?
  let nst = parseNewSessionTicket(pt.content)?
  let session = newSessionTicket(nst, clientConn)
  return tlsClientStartResume(config, session, []byte(0))?
}
```

## QUIC handshake mode

QUIC does not run TLS over the TLS record layer (RFC 9001 §4): it carries the
plaintext handshake **messages** inside its own CRYPTO frames and protects them
with QUIC packet protection instead. This mode drives the very same client and
server state machines at the handshake-message level - no `RecordKeys.seal`/`open`
and no five-byte record framing - and exposes the traffic secrets so
[`std/quic`](quic.md) can key each encryption level. It is purely additive: the
record-mode entrypoints and every record-mode behaviour are untouched.

Server authentication is **not** relaxed here. The client still verifies the
certificate chain and hostname against its [`TrustStore`](#-truststore-) (unless
`insecureSkipVerify`), the CertificateVerify signature, and the server Finished
MAC in constant time; the server still verifies the client Finished MAC. The
`Exts` entrypoints add extensions to the ClientHello / EncryptedExtensions - QUIC
uses this to carry the `quic_transport_parameters` extension (RFC 9001 §8.2).

```bit
import { tlsClientStartExts, TlsClientConfig, Extension } from "std/tls"

// Drive the client half of a QUIC handshake at the message level (RFC 9001). `tp`
// is the quic_transport_parameters extension. The ClientHello (from
// `clientHelloMessage`) goes in Initial-level CRYPTO frames; after the server's
// ServerHello and Handshake flight, the returned client Finished goes in
// Handshake-level CRYPTO frames. The secrets exposed on `h` key the QUIC levels.
fn quicClientHandshake(config: TlsClientConfig, tp: Extension, serverHello: []byte, serverFlight: []byte): []byte! {
  let h = tlsClientStartExts(config, [tp])?
  let retry = h.processServerHelloMessage(serverHello)?
  if (len(retry) > 0) {
    fail newError("HelloRetryRequest: resend the ClientHello, then read the next ServerHello")
  }
  return h.clientReadHandshake(serverFlight)?
}
```

### `tlsClientStartExts(config: TlsClientConfig, extraExts: []Extension): TlsClientHandshake!`

Start a client handshake exactly like `tlsClientStart`, but add `extraExts` to the
ClientHello's extension list. QUIC passes the `quic_transport_parameters`
extension here; with an empty `extraExts` it is byte-for-byte `tlsClientStart`.
The `clientHelloOverride` path ignores `extraExts`.

### `TlsClientHandshake.clientHelloMessage(): []byte`

The ClientHello handshake **message** (RFC 8446 §4.1.2) - the plaintext bytes for
Initial-level CRYPTO frames, exactly what `hello` wraps in a record without the
five-byte record header.

### `TlsClientHandshake.processServerHelloMessage(shMsg: []byte): []byte!`

Feed the server's ServerHello message (plaintext, from Initial-level CRYPTO
frames). On a HelloRetryRequest it returns the resent ClientHello message to
carry in a new Initial flight; otherwise it derives the handshake-traffic secrets
and returns an empty slice. Fails on a parse error, an unoffered suite/group, or a
second HelloRetryRequest.

### `TlsClientHandshake.clientReadHandshake(stream: []byte): []byte!`

Consume the server's Handshake-level messages - EncryptedExtensions, Certificate,
CertificateVerify, Finished - as one plaintext `stream` (reassembled from
Handshake-level CRYPTO frames), and return the client Finished **message** to
carry in a Handshake-level CRYPTO frame. Runs the full security core: it verifies
the certificate chain + hostname (unless `insecureSkipVerify`), the
CertificateVerify signature, and the server Finished MAC, then derives the
application-traffic secrets. Fails fatally on any parse or authentication failure.

### `TlsClientHandshake.peerEncryptedExtensions(): []Extension`

The server's EncryptedExtensions, as parsed during `clientReadHandshake` - QUIC
reads the peer's `quic_transport_parameters` (codepoint `0x0039`) from here. Empty
until the auth flight has been consumed.

### `TlsClientHandshake.cipherSuiteId(): int`

The negotiated cipher suite's IANA code point, valid once a (non-HRR) ServerHello
has been processed. Used to pick the suite hash and key length when deriving each
QUIC encryption level's keys.

### `TlsClientHandshake.clientHandshakeSecret(): []byte`

The client_handshake_traffic_secret (RFC 8446 §7.1), derived after the
ServerHello. `std/quic` keys the client's Handshake-level packets from it.

### `TlsClientHandshake.serverHandshakeSecret(): []byte`

The server_handshake_traffic_secret (RFC 8446 §7.1), derived after the
ServerHello. `std/quic` keys the server's Handshake-level packets from it.

### `TlsClientHandshake.clientApplicationSecret(): []byte`

The client_application_traffic_secret_0 (RFC 8446 §7.1), derived after the server
Finished by `clientReadHandshake`. `std/quic` keys the client's 1-RTT packets from
it.

### `TlsClientHandshake.serverApplicationSecret(): []byte`

The server_application_traffic_secret_0 (RFC 8446 §7.1), derived after the server
Finished by `clientReadHandshake`. `std/quic` keys the server's 1-RTT packets from
it.

### `TlsClientHandshake.exporterSecret(): []byte`

The exporter_master_secret (RFC 8446 §7.5), derived by `clientReadHandshake` - the
root of exported keying material bound to this handshake.

### `tlsServerStartExts(config: TlsServerConfig, extraExts: []Extension): TlsServerHandshake!`

Start a server handshake exactly like `tlsServerStart`, but add `extraExts` to the
EncryptedExtensions the server sends. QUIC answers with its
`quic_transport_parameters` extension here; with an empty `extraExts` it is
byte-for-byte `tlsServerStart`.

### `TlsServerQuicFlight`

One QUIC server output flight from `processClientHelloMessage`. `retry` means a
HelloRetryRequest was produced: `serverHello` is the HRR message (Initial-level
CRYPTO) and `handshake` is empty. Otherwise `serverHello` is the ServerHello
message (Initial-level CRYPTO) and `handshake` is the concatenated
EncryptedExtensions ‖ Certificate ‖ CertificateVerify ‖ Finished (Handshake-level
CRYPTO), all plaintext messages.

### `TlsServerHandshake.processClientHelloMessage(chMsg: []byte): TlsServerQuicFlight!`

Process the client's ClientHello message (plaintext, from Initial-level CRYPTO
frames). Negotiates the suite and group; on success it derives the handshake- and
application-traffic secrets and returns the ServerHello plus the plaintext
authentication flight, and on an unshareable group it returns a HelloRetryRequest.
Fails on a parse error, an absent common suite/group, or a signing failure.

### `TlsServerHandshake.processClientFinishedMessage(finMsg: []byte): TlsServerConn!`

Verify the client Finished message (plaintext, from a Handshake-level CRYPTO
frame) and complete the handshake, returning the application connection. Runs the
same constant-time MAC check as record mode. Fails on a parse error or a Finished
MAC that does not match.

### `TlsServerHandshake.cipherSuiteId(): int`

The negotiated cipher suite's IANA code point, valid once a ClientHello has been
processed.

### `TlsServerHandshake.clientHandshakeSecret(): []byte`

The client_handshake_traffic_secret (RFC 8446 §7.1), derived once the server
flight is produced.

### `TlsServerHandshake.serverHandshakeSecret(): []byte`

The server_handshake_traffic_secret (RFC 8446 §7.1), derived once the server
flight is produced.

### `TlsServerHandshake.clientApplicationSecret(): []byte`

The client_application_traffic_secret_0 (RFC 8446 §7.1), derived once the server
flight is produced.

### `TlsServerHandshake.serverApplicationSecret(): []byte`

The server_application_traffic_secret_0 (RFC 8446 §7.1), derived once the server
flight is produced.

### `TlsServerHandshake.exporterSecret(): []byte`

The exporter_master_secret (RFC 8446 §7.5), derived once the server flight is
produced.

## Public API

The high-level, socket-driving API most callers reach for: `dial` for a client,
`listen` + `accept` for a server, and a `TlsConn` whose `read`/`write` speak
plaintext over the TLS record layer of an underlying [`std/net`](net.md)
connection. It ties the sans-I/O handshakes above to real sockets - record
framing, flight boundaries, and the partial-record buffering a byte stream forces
are all handled internally. Only TLS 1.3 is spoken.

### `tlsVersion13: int`

The TLS 1.3 wire version codepoint (`0x0304`), the default and only value
`TlsConfig.minVersion` may name.

### `TlsConfig`

The configuration shared by `dial` and `listen`. `roots` is the trust anchor set
a client verifies the server chain against; `insecureSkipVerify` turns off
certificate-chain and hostname verification when true (its zero value, `false`,
is the `newTlsConfig` default and verifies); `alpn` is the ALPN protocol list;
`serverName` is the SNI host and the name the certificate must match;
`minVersion` is the version floor (an omitted `0` is clamped to `tlsVersion13`
by `dial`/`listen`); `nowUnix` is the clock for certificate-validity checks; and
`certPem`/`keyPem` are the server's certificate chain and private key, required
by `listen`.

**Security note.** `insecureSkipVerify` true DISABLES server authentication: the
connection then proves only that the peer holds the CertificateVerify key and
completes the Finished MAC, not that it is the host it claims to be. Its zero
value is `false`, so an omitted field or a hand-built struct literal still
verifies. Set `insecureSkipVerify: true` only for tests or pinned-key scenarios.

### `newTlsConfig(roots: TrustStore): TlsConfig`

A `TlsConfig` that verifies servers against `roots`, secure by default:
`insecureSkipVerify` is false and `minVersion` is TLS 1.3. The recommended
constructor - a raw struct literal is just as safe now, since every omitted
field defaults to its zero value and the zero value of `insecureSkipVerify` is
"verify".

### `emptyTrustStore(): TrustStore`

A `TrustStore` with no roots, for a server config (which never verifies a peer) or
a deliberately insecure client - the cases `newTrustStore`, which rejects an empty
root set, cannot serve.

### `dial(host: string, port: int, config: TlsConfig): TlsConn!`

Connect to `host:port` over TCP and run the TLS 1.3 client handshake to
completion, returning a `TlsConn`. `host` is resolved through the system resolver
(a dotted quad passes straight through) and is the default SNI. Verifies the
server's certificate chain and hostname against `config.roots` unless
`config.insecureSkipVerify` is true. Fails on a connect, resolve, or
handshake/verification error.

### `listen(host: string, port: int, config: TlsConfig): TlsListener!`

Bind a TLS listener on `host:port`. `config.certPem` and `config.keyPem` (the
server's certificate chain and matching private key, PEM) are required. `port`
may be `0` to let the kernel choose one - read it back with `port()`.

### `TlsListener.accept(): TlsConn!`

Accept the next connection and run the TLS 1.3 server handshake to completion,
returning its `TlsConn`. Fails on an accept or handshake error.

### `TlsListener.port(): int!`

The port the listener is bound to - meaningful even when `0` was requested.

### `TlsListener.close()`

Close the listening socket.

### `TlsConn.read(n: int): []byte!`

Up to `n` decrypted application bytes, buffering any surplus from a record for the
next call. Post-handshake handshake records (e.g. NewSessionTicket) are skipped.
An empty result is end of stream - a clean socket close or a TLS `close_notify`.
Fails on a record that fails authentication.

### `TlsConn.write(b: []byte): ()!`

Write all of `b` as one or more `application_data` records, splitting at the
2^14-octet plaintext limit. Fails on a socket write error.

### `TlsConn.close()`

Close the underlying socket. Idempotent. No `close_notify` alert is sent.

### `TlsConn.alpnProtocol(): string`

The ALPN protocol negotiated during the handshake, or `""` if none.

### `TlsConn.cipherSuiteId(): int`

The negotiated cipher suite's IANA code point.

### `TlsConn.peerCertificates(): [][]byte`

The peer's certificate chain as raw DER, end-entity first - the server's chain on
a client connection, empty on a server connection (client certificates are not
requested).

```bit
import { dial, listen, newTlsConfig, newTrustStore, emptyTrustStore } from "std/tls"

// Client: dial a host, verifying its certificate against a PEM root bundle, send
// a request, and read the reply.
fn fetch(rootsPem: string, host: string, request: []byte): []byte! {
  let cfg = newTlsConfig(newTrustStore(rootsPem)?)   // verification on by default
  cfg.serverName = host
  cfg.alpn = ["http/1.1"]
  let conn = dial(host, 443, cfg)?
  conn.write(request)?
  let reply = conn.read(4096)?
  conn.close()
  return reply
}

// Server: listen with a certificate chain and key, accept one connection, and
// echo a single message back.
fn echoOnce(certPem: string, keyPem: string): ()! {
  let cfg = newTlsConfig(emptyTrustStore())
  cfg.certPem = certPem
  cfg.keyPem = keyPem
  cfg.alpn = ["http/1.1"]
  let l = listen("127.0.0.1", 8443, cfg)?
  let conn = l.accept()?
  let msg = conn.read(1024)?
  conn.write(msg)?
  conn.close()
  l.close()
}
```
