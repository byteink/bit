# std/quic

QUIC v1 packet protection (RFC 9001) and the frame codec (RFC 9000), built in Bit
on top of [`std/crypto`](crypto.md). This module is the cryptographic and wire-format
core of QUIC — it derives the Initial keys, protects and unprotects packets, and
serializes frames — but it is deliberately *not* a transport: there is no connection
state machine, no flow control, no loss recovery, and no congestion control here.
Those layers sit above and drive these primitives.

The module has two halves. **Packet protection** (`packet.bit`) derives keys with the
TLS 1.3 HKDF ladder, seals payloads with AES-128-GCM under a packet-number-derived
nonce, and masks headers with an AES-ECB or raw-ChaCha20 key stream — the same
verified `std/crypto` primitives, never a second copy of the cryptography. **Frames**
(`frames.bit`) encode and decode QUIC's variable-length integers and every v1 frame.

Everything composes cleanly: `std/quic` reproduces the RFC 9001 Appendix A sample
packets byte-for-byte and round-trips every frame through its own decoder.

<!-- doctest: per-block -->

## Frames

A QUIC packet payload is a sequence of frames, and every number in the protocol — a
length, offset, stream id, or error code — is a variable-length integer (RFC 9000
§16): the top two bits of the first byte give the encoded length (1, 2, 4, or 8
bytes) and the rest is the value, big-endian. `Frame` is a sum type over every frame
RFC 9000 §19 defines; the codec is pure and strict — malformed input is rejected with
a fallible `!`, never guessed at.

### `encodeVarint(v: u64): []byte`

The shortest QUIC variable-length integer encoding of `v` (RFC 9000 §16). `v` must fit
in 62 bits. For example, 494,878,333 encodes to the four-byte `9d7f3e7d`.

```bit
import { encodeVarint } from "std/quic"

function example(): []byte {
  return encodeVarint(494878333)
}
```

### `decodeVarint(data: []byte): u64!`

Decode the variable-length integer at the start of `data`, ignoring any trailing
bytes. Accepts non-minimal encodings, so both `25` and `4025` decode to 37. Fails on
an empty slice or a length that runs past the end.

```bit
import { decodeVarint } from "std/quic"

function example(data: []byte): u64! {
  return decodeVarint(data)?
}
```

### `varintSize(v: u64): int`

The number of bytes `encodeVarint` will use for `v` (1, 2, 4, or 8) — for sizing a
buffer up front without encoding twice.

```bit
import { varintSize } from "std/quic"

function example(): int {
  return varintSize(15293)
}
```

### `AckRange`

One ACK Range (RFC 9000 §19.3.1): a `gap` of unacknowledged packets and a
`rangeLength` of acknowledged ones, both relative varints in descending order.

```bit
import { AckRange } from "std/quic"

function example(): AckRange {
  return AckRange{ gap: 1, rangeLength: 4 }
}
```

### `AckFrame`

An ACK frame (RFC 9000 §19.3): the largest acknowledged packet number, the ack delay,
the first range, the additional gap/range pairs, and — when `ecn` is set — the three
ECN counters.

```bit
import { AckFrame, AckRange } from "std/quic"

function example(): AckFrame {
  return AckFrame{
    largest: 10,
    delay: 3,
    firstRange: 2,
    ranges: [AckRange{ gap: 1, rangeLength: 4 }],
    ecn: false,
    ect0: 0,
    ect1: 0,
    ce: 0,
  }
}
```

### `StreamFrame`

A STREAM frame (RFC 9000 §19.8). The `hasOffset`, `hasLength`, and `fin` flags select
the OFF/LEN/FIN bits of the type: with `hasLength` clear, the data runs to the end of
the packet.

```bit
import { StreamFrame } from "std/quic"

function example(data: []byte): StreamFrame {
  return StreamFrame{
    id: 4,
    offset: 8,
    data: data,
    hasOffset: true,
    hasLength: true,
    fin: true,
  }
}
```

### `Frame`

One QUIC v1 frame (RFC 9000 §19), a sum over every frame type. `Padding(n)` is a run
of `n` PADDING bytes; `ConnectionClose` is the transport variant (type 0x1c) and
`ApplicationClose` the application variant (type 0x1d).

```bit
import { Frame } from "std/quic"

function example(data: []byte): Frame {
  return Frame.Crypto(0, data)
}
```

### `encodeFrame(f: Frame): []byte`

The wire encoding of a single frame (RFC 9000 §19).

```bit
import { Frame, encodeFrame } from "std/quic"

function example(): []byte {
  return encodeFrame(Frame.Ping)
}
```

### `encodeFrames(frames: []Frame): []byte`

The concatenated wire encoding of `frames`, in order.

```bit
import { Frame, encodeFrames } from "std/quic"

function example(): []byte {
  return encodeFrames([Frame.Ping, Frame.HandshakeDone])
}
```

### `parseFrames(data: []byte): []Frame!`

Parse every frame in `data`, in order, until the buffer is exactly consumed. Fails on
an unknown frame type or any field that runs past the end.

```bit
import { Frame, parseFrames } from "std/quic"

function example(data: []byte): []Frame! {
  return parseFrames(data)?
}
```

## Packet protection

Packet protection has three stages, mirroring RFC 9001 §5. Key derivation turns the
client's Destination Connection ID into the Initial key, IV, and header-protection
key. Payload protection seals the frames with AES-128-GCM under a nonce formed from
the IV and packet number. Header protection masks the first byte's low bits and the
packet number with a key stream sampled from the ciphertext. The Retry integrity tag
and Version Negotiation packet round out what an endpoint needs before the transport
layer takes over.

### `quicVersion1`

QUIC version 1 (RFC 9000 §15), `0x00000001`.

```bit
import { quicVersion1 } from "std/quic"

function example(): int {
  return quicVersion1
}
```

### `longInitial`

The long-header type value for an Initial packet (RFC 9000 §17.2.2), `0`.

```bit
import { longInitial } from "std/quic"

function example(): int {
  return longInitial
}
```

### `longZeroRtt`

The long-header type value for a 0-RTT packet (RFC 9000 §17.2.3), `1`.

```bit
import { longZeroRtt } from "std/quic"

function example(): int {
  return longZeroRtt
}
```

### `longHandshake`

The long-header type value for a Handshake packet (RFC 9000 §17.2.4), `2`.

```bit
import { longHandshake } from "std/quic"

function example(): int {
  return longHandshake
}
```

### `longRetry`

The long-header type value for a Retry packet (RFC 9000 §17.2.5), `3`.

```bit
import { longRetry } from "std/quic"

function example(): int {
  return longRetry
}
```

### `PacketKeys`

The AES-128-GCM key (16 bytes), IV (12 bytes), and header-protection key (16 bytes)
for one direction of one encryption level.

```bit
import { PacketKeys, deriveKeys } from "std/quic"

function example(secret: []byte): PacketKeys {
  return deriveKeys(secret)
}
```

### `initialSalt(): []byte`

The QUIC v1 Initial salt (RFC 9001 §5.2), the fixed non-secret value mixed into the
Initial-secret extraction.

```bit
import { initialSalt } from "std/quic"

function example(): []byte {
  return initialSalt()
}
```

### `expandLabel(secret: []byte, label: string, length: int): []byte`

TLS 1.3 HKDF-Expand-Label over SHA-256, as QUIC uses it (RFC 9001 §5.1): expand
`secret` to `length` bytes bound to `"tls13 " + label`. Use it to derive keys for a
non-Initial suite, such as the 32-byte ChaCha20-Poly1305 key.

```bit
import { expandLabel } from "std/quic"

function example(secret: []byte): []byte {
  return expandLabel(secret, "quic key", 16)
}
```

### `deriveInitialSecret(dcid: []byte): []byte`

The Initial secret common to both directions (RFC 9001 §5.2): `HKDF-Extract(
initial_salt, dcid)` over the client's Destination Connection ID.

```bit
import { deriveInitialSecret } from "std/quic"

function example(dcid: []byte): []byte {
  return deriveInitialSecret(dcid)
}
```

### `clientInitialSecret(dcid: []byte): []byte`

The client Initial traffic secret (RFC 9001 §5.2): `HKDF-Expand-Label(initial,
"client in", "", 32)`.

```bit
import { clientInitialSecret } from "std/quic"

function example(dcid: []byte): []byte {
  return clientInitialSecret(dcid)
}
```

### `serverInitialSecret(dcid: []byte): []byte`

The server Initial traffic secret (RFC 9001 §5.2): `HKDF-Expand-Label(initial,
"server in", "", 32)`.

```bit
import { serverInitialSecret } from "std/quic"

function example(dcid: []byte): []byte {
  return serverInitialSecret(dcid)
}
```

### `deriveKeys(secret: []byte): PacketKeys`

The AES-128-GCM key/iv/hp derived from a traffic `secret` (RFC 9001 §5.1): "quic key"
(16 bytes), "quic iv" (12), and "quic hp" (16).

```bit
import { PacketKeys, deriveKeys } from "std/quic"

function example(secret: []byte): PacketKeys {
  return deriveKeys(secret)
}
```

### `clientInitialKeys(dcid: []byte): PacketKeys`

The keys that protect the client's Initial packets, derived end to end from the
client-chosen `dcid`.

```bit
import { PacketKeys, clientInitialKeys } from "std/quic"

function example(dcid: []byte): PacketKeys {
  return clientInitialKeys(dcid)
}
```

### `serverInitialKeys(dcid: []byte): PacketKeys`

The keys that protect the server's Initial packets, derived from the same client
`dcid`.

```bit
import { PacketKeys, serverInitialKeys } from "std/quic"

function example(dcid: []byte): PacketKeys {
  return serverInitialKeys(dcid)
}
```

### `packetNumberLength(pn: u64, largestAcked: int): int`

The smallest packet-number encoding length (1..4 bytes) for `pn` given the peer's
`largestAcked` (RFC 9000 §17.1). Pass a negative `largestAcked` when nothing has been
acknowledged yet.

```bit
import { packetNumberLength } from "std/quic"

function example(): int {
  return packetNumberLength(42, -1)
}
```

### `encodePacketNumber(pn: u64, pnLength: int): []byte`

The `pnLength`-byte big-endian truncation of packet number `pn` (RFC 9000 §17.1).

```bit
import { encodePacketNumber } from "std/quic"

function example(): []byte {
  return encodePacketNumber(42, 2)
}
```

### `packetNonce(iv: []byte, pn: u64): []byte`

The AEAD nonce for packet number `pn` (RFC 9001 §5.3): the IV with `pn` (big-endian,
right-aligned) XOR'd into its low bytes.

```bit
import { packetNonce } from "std/quic"

function example(iv: []byte): []byte {
  return packetNonce(iv, 42)
}
```

### `protectPayload(keys: PacketKeys, pn: u64, header: []byte, payload: []byte): []byte!`

Seal `payload` under `keys` for packet number `pn` (RFC 9001 §5.3): AES-128-GCM with
nonce `IV ^ pn` and `header` as additional data, returning the ciphertext with the
16-byte tag appended.

```bit
import { PacketKeys, protectPayload } from "std/quic"

function example(keys: PacketKeys, header: []byte, payload: []byte): []byte! {
  return protectPayload(keys, 0, header, payload)?
}
```

### `unprotectPayload(keys: PacketKeys, pn: u64, header: []byte, ciphertext: []byte): []byte!`

Open the protected `ciphertext` (payload ‖ tag) under `keys` for packet number `pn`,
authenticating `header`. Fails without returning plaintext if the tag does not verify.

```bit
import { PacketKeys, unprotectPayload } from "std/quic"

function example(keys: PacketKeys, header: []byte, ciphertext: []byte): []byte! {
  return unprotectPayload(keys, 0, header, ciphertext)?
}
```

### `headerSample(protectedPayload: []byte, pnLength: int): []byte!`

The 16-byte header-protection sample from a protected payload (RFC 9001 §5.4.2), taken
4 bytes past the packet-number field. Fails if the payload is too short.

```bit
import { headerSample } from "std/quic"

function example(protectedPayload: []byte): []byte! {
  return headerSample(protectedPayload, 4)?
}
```

### `aesHeaderMask(hpKey: []byte, sample: []byte): []byte!`

The 5-byte AES header-protection mask (RFC 9001 §5.4.3): AES-ECB of the 16-byte
`sample` under `hpKey`, truncated to 5 bytes. For the AES-GCM suites.

```bit
import { aesHeaderMask } from "std/quic"

function example(hpKey: []byte, sample: []byte): []byte! {
  return aesHeaderMask(hpKey, sample)?
}
```

### `chachaHeaderMask(hpKey: []byte, sample: []byte): []byte!`

The 5-byte ChaCha20 header-protection mask (RFC 9001 §5.4.4): the counter is
`sample[0..4]` (little-endian) and the nonce `sample[4..16]`. For ChaCha20-Poly1305.

```bit
import { chachaHeaderMask } from "std/quic"

function example(hpKey: []byte, sample: []byte): []byte! {
  return chachaHeaderMask(hpKey, sample)?
}
```

### `applyHeaderProtection(packet: []byte, pnOffset: int, mask: []byte): ()!`

Apply header protection to a full packet buffer in place, for sending (RFC 9001
§5.4.1). `pnOffset` is the start of the packet number; `mask` is the 5-byte mask.

```bit
import { applyHeaderProtection } from "std/quic"

function example(packet: []byte, pnOffset: int, mask: []byte): ()! {
  applyHeaderProtection(packet, pnOffset, mask)?
}
```

### `removeHeaderProtection(packet: []byte, pnOffset: int, mask: []byte): int!`

Remove header protection from a full packet buffer in place, for receiving, and return
the recovered packet-number length (RFC 9001 §5.4.1).

```bit
import { removeHeaderProtection } from "std/quic"

function example(packet: []byte, pnOffset: int, mask: []byte): int! {
  return removeHeaderProtection(packet, pnOffset, mask)?
}
```

### `LongHeader`

The invariant long-header fields (RFC 9000 §17.2): the packet type, version, and the
Destination and Source Connection IDs.

```bit
import { LongHeader, parseLongHeader } from "std/quic"

function example(packet: []byte): LongHeader! {
  return parseLongHeader(packet)?
}
```

### `encodeInitialHeader(version: int, dcid: []byte, scid: []byte, token: []byte, length: u64, pn: u64, pnLength: int): []byte`

The unprotected Initial-packet header through the packet number (RFC 9000 §17.2.2),
which is exactly the AEAD additional data for `protectPayload`.

```bit
import { encodeInitialHeader } from "std/quic"

function example(dcid: []byte, scid: []byte): []byte {
  return encodeInitialHeader(1, dcid, scid, []byte(0), 1200, 0, 4)
}
```

### `parseLongHeader(packet: []byte): LongHeader!`

The invariant long-header fields of `packet` (RFC 9000 §17.2). Reads byte 0, the
version, and the two connection IDs, stopping before the type-specific fields.

```bit
import { LongHeader, parseLongHeader } from "std/quic"

function example(packet: []byte): LongHeader! {
  return parseLongHeader(packet)?
}
```

### `ShortHeader`

The short-header (1-RTT) fields recovered after header protection is removed (RFC 9000
§17.3): the spin and key-phase bits, the connection ID, and the packet-number length.

```bit
import { ShortHeader, parseShortHeader } from "std/quic"

function example(packet: []byte): ShortHeader! {
  return parseShortHeader(packet, 8)?
}
```

### `encodeShortHeader(dcid: []byte, pn: u64, pnLength: int, spinBit: bool, keyPhase: bool): []byte`

The unprotected short-header (1-RTT) bytes through the packet number (RFC 9000 §17.3),
the AEAD additional data for a 1-RTT packet.

```bit
import { encodeShortHeader } from "std/quic"

function example(dcid: []byte): []byte {
  return encodeShortHeader(dcid, 42, 2, false, false)
}
```

### `parseShortHeader(packet: []byte, dcidLen: int): ShortHeader!`

The short-header fields of `packet` given the connection's `dcidLen` (RFC 9000 §17.3),
which a short header does not carry on the wire. Call after `removeHeaderProtection`.

```bit
import { ShortHeader, parseShortHeader } from "std/quic"

function example(packet: []byte): ShortHeader! {
  return parseShortHeader(packet, 8)?
}
```

### `retryIntegrityTag(odcid: []byte, retryWithoutTag: []byte): []byte!`

The 16-byte Retry integrity tag (RFC 9001 §5.8): AES-128-GCM over the Retry Pseudo-
Packet built from `odcid` (the Original Destination Connection ID) and the Retry packet
with its trailing tag removed.

```bit
import { retryIntegrityTag } from "std/quic"

function example(odcid: []byte, retryWithoutTag: []byte): []byte! {
  return retryIntegrityTag(odcid, retryWithoutTag)?
}
```

### `verifyRetry(odcid: []byte, fullRetry: []byte): bool!`

Whether the trailing integrity tag of `fullRetry` is valid for `odcid` (RFC 9001
§5.8), compared in constant time.

```bit
import { verifyRetry } from "std/quic"

function example(odcid: []byte, fullRetry: []byte): bool! {
  return verifyRetry(odcid, fullRetry)?
}
```

### `encodeVersionNegotiation(dcid: []byte, scid: []byte, versions: []int): []byte`

A Version Negotiation packet (RFC 9000 §17.2.1): a long header with version 0 that
lists the server's supported `versions`, echoing the client's connection IDs.

```bit
import { encodeVersionNegotiation } from "std/quic"

function example(dcid: []byte, scid: []byte): []byte {
  return encodeVersionNegotiation(dcid, scid, [1])
}
```

### `isVersionNegotiation(packet: []byte): bool`

Whether `packet` is a Version Negotiation packet (RFC 9000 §17.2.1): a long header
whose 32-bit version field is zero.

```bit
import { isVersionNegotiation } from "std/quic"

function example(packet: []byte): bool {
  return isVersionNegotiation(packet)
}
```
## QUIC-TLS

QUIC does not run TLS 1.3 over a TLS record layer (RFC 9001). Instead it carries
the raw handshake *messages* inside CRYPTO frames and derives its own packet-
protection keys from the TLS traffic secrets under QUIC-specific HKDF labels. This
section is that seam: the `quic_transport_parameters` TLS extension codec, the
per-encryption-level key derivation and key update, and CRYPTO-frame carriage. It
builds on the [key schedule](tls.md) in `std/tls` (it reuses that module's
`hkdfExpandLabel`) but touches no TLS record.

A full client↔server handshake runs on `std/tls`'s record-bypass handshake mode
(its `tlsClientStartExts` / `tlsServerStartExts` entrypoints and message-level
drivers, in [std/tls › QUIC handshake mode](tls.md#quic-handshake-mode)): carry
each handshake message in CRYPTO frames across the Initial and Handshake levels,
key each level from the exposed traffic secrets with `levelKeys` (or `levelKeyPair`
for both directions at once), and reach 1-RTT on both sides — with the TLS
certificate, CertificateVerify, and Finished verification all still enforced.

```bit
import {
  defaultTransportParameters,
  encodeTransportParameters,
  levelKeys,
  updateSecret,
  cryptoFrames,
  reassembleCryptoFrames,
  PacketKeys,
} from "std/quic"
import { Hash, newSha256 } from "std/crypto"

// The negotiated suite's hash as a `() => Hash`.
function sha256(): Hash { return newSha256() }

// Our transport parameters, as the quic_transport_parameters extension body.
function myParameters(): []byte {
  let tp = defaultTransportParameters()
  tp.initialMaxData = 1048576
  tp.initialMaxStreamsBidi = 100
  return encodeTransportParameters(tp)
}

// The 1-RTT packet keys for one direction from its application traffic secret,
// and the next secret after a key update (re-derive the key/iv, keep the hp).
function oneRttKeys(secret: []byte): PacketKeys {
  return levelKeys(sha256, secret, 16)
}

function rollForward(secret: []byte): []byte {
  return updateSecret(sha256, secret)
}

// Carry a handshake message in CRYPTO frames and reassemble it in order.
function carry(handshake: []byte): []byte! {
  let frames = cryptoFrames(handshake, 0, 1000)
  return reassembleCryptoFrames(frames, 65536)?
}
```

### `quicTransportParametersExtension: int`

The TLS 1.3 extension codepoint (0x0039) carrying the QUIC transport parameters
(RFC 9001 §8.2). Its extension_data is exactly what `encodeTransportParameters`
produces.

### `TransportParameters`

The QUIC transport parameters an endpoint sends its peer (RFC 9000 §18.2): the
flow-control limits, timeouts, and connection ids. Integer parameters hold their
RFC default (see `defaultTransportParameters`); the byte-string parameters are
empty when absent, and `disableActiveMigration` is a present-means-true flag.

### `defaultTransportParameters(): TransportParameters`

A `TransportParameters` filled with the RFC 9000 §18.2 defaults (the non-zero
defaults for `maxUdpPayloadSize`, `ackDelayExponent`, `maxAckDelay`, and
`activeConnectionIdLimit`, everything else zero or empty). Start here, set the
parameters that differ, and encode: the codec omits anything left at its default.

### `encodeTransportParameters(tp: TransportParameters): []byte`

Encode `tp` as the `quic_transport_parameters` extension body (RFC 9000 §18.2):
the id/len/value list in ascending-id order, omitting every parameter equal to
its default so the wire form is minimal and canonical.

### `decodeTransportParameters(data: []byte): TransportParameters!`

Decode a `quic_transport_parameters` extension body (RFC 9000 §18.2) into a
`TransportParameters` seeded with the RFC defaults, so an omitted parameter keeps
its default. Unknown parameter ids are skipped. Fails on a length past the buffer,
a malformed integer value, or trailing bytes.

### `EncryptionLevel`

The three packet-protection encryption levels of a QUIC connection (RFC 9001 §2):
`Initial`, `Handshake`, and `OneRtt` — the last being the only level subject to
key update.

### `levelPacketType(level: EncryptionLevel): int`

The long-header packet type that carries `level` (RFC 9000 §17.2): 0 for Initial,
2 for Handshake. `OneRtt` is carried in a short-header packet, which has no
long-header type, so it returns -1.

### `levelKeys(newHash: () => Hash, secret: []byte, keyLen: int): PacketKeys`

The packet-protection key/iv/hp for a Handshake or 1-RTT level, derived from a TLS
traffic `secret` (RFC 9001 §5.1) with the QUIC labels "quic key", "quic iv" (12
bytes), and "quic hp". `keyLen` is the AEAD key length (16 for AES-128-GCM, 32 for
AES-256-GCM and ChaCha20-Poly1305), and the hp key is the same length. `newHash`
is the negotiated suite's hash. Initial keys instead come from `clientInitialKeys`.

### `LevelKeyPair`

Both directions' packet-protection keys for one non-Initial encryption level (RFC
9001 §5.1) — the unit an endpoint installs for the Handshake or 1-RTT level.
`client` protects the client's packets, `server` the server's.

### `levelKeyPair(newHash: () => Hash, clientSecret: []byte, serverSecret: []byte, keyLen: int): LevelKeyPair`

Derive both directions' keys for a non-Initial level from the endpoint TLS traffic
secrets (RFC 9001 §5.1): `clientSecret` is the client's handshake- or
application-traffic secret and `serverSecret` the server's, as exposed by the
`std/tls` record-bypass handshake. Both peers, deriving from the same pair of
secrets, obtain byte-identical keys — the check that a QUIC-TLS handshake reached
a level.

```bit
import { levelKeyPair, LevelKeyPair } from "std/quic"
import { Hash, newSha256 } from "std/crypto"

// The negotiated suite's hash as a `() => Hash`.
function suite(): Hash { return newSha256() }

// Both directions' 1-RTT keys from the client and server application secrets that
// the std/tls record-bypass handshake exposed.
function oneRtt(clientSecret: []byte, serverSecret: []byte): LevelKeyPair {
  return levelKeyPair(suite, clientSecret, serverSecret, 16)
}
```

### `updateSecret(newHash: () => Hash, secret: []byte): []byte`

The next-generation 1-RTT secret for a key update (RFC 9001 §6.1):
`HKDF-Expand-Label(secret, "quic ku", "", Hash.length)`. Re-derive the AEAD key
and iv from the result with `levelKeys`; the header-protection key is not updated.

### `nextKeyPhase(keyPhase: bool): bool`

The key-phase bit after a key update (RFC 9001 §6.3) — it toggles, so a peer can
tell which key generation protected a packet. The bit itself is carried in the
short header (`encodeShortHeader`).

### `cryptoFrames(data: []byte, startOffset: u64, maxChunk: int): []Frame`

Chunk a handshake byte stream into CRYPTO frames (RFC 9000 §19.6), each at most
`maxChunk` bytes, the first at `startOffset` and each subsequent one at the
running offset. Ready to place in a packet payload with `encodeFrame`.

### `CryptoAssembler`

A reassembler for the CRYPTO stream (RFC 9000 §19.6): it accepts received CRYPTO
fragments in any order, with gaps and overlapping retransmits, and yields the
contiguous ordered byte stream. Build one with `newCryptoAssembler`.

### `newCryptoAssembler(maxLen: int): CryptoAssembler`

A fresh `CryptoAssembler` that accepts data up to `maxLen` bytes total — a bound
on offset + length across all fragments, so a hostile offset cannot force an
unbounded allocation.

### `CryptoAssembler.insert(offset: u64, fragment: []byte): ()!`

Insert one CRYPTO fragment: `fragment` bytes at stream `offset` (RFC 9000 §19.6).
Records the bytes and extends the readable prefix. Overlapping retransmits are
allowed only if they carry identical bytes; a mismatch, or a fragment past
`maxLen`, fails.

### `CryptoAssembler.contiguous(): []byte`

The contiguous handshake bytes reassembled so far — the ordered stream from offset
0 up to the first gap. Grows as later `insert`s fill earlier gaps.

### `CryptoAssembler.contiguousLen(): int`

The length of the contiguous reassembled prefix — `len(contiguous())` without
materializing the slice.

### `reassembleCryptoFrames(frames: []Frame, maxLen: int): []byte!`

Reassemble the CRYPTO frames in `frames` into the contiguous handshake byte stream
(RFC 9000 §19.6), ignoring non-CRYPTO frames. Frames may be in any order and may
overlap; the result is the ordered prefix up to the first gap. `maxLen` bounds the
buffer. Fails on an over-limit offset or a conflicting overlap.
