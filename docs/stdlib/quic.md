# std/quic

Most programs never import `std/quic` directly. [`std/http3`](http3.md) and
[`pkg/web`](/packages/web) run their HTTP/3 traffic over it and speak QUIC for
you. This module is the transport underneath: it turns an unreliable UDP flow into
reliable, ordered, encrypted streams, built on [`std/crypto`](crypto.md) and
[`std/tls`](tls.md).

Reach for `std/quic` yourself when you want a QUIC-based protocol that is not
HTTP/3 - your own request/response or streaming protocol running over QUIC's
streams instead of TCP.

<!-- doctest: per-block -->

## Dialing, serving, and streams

`dialQuic` opens a connection, verifying the server's certificate against the
system trust roots (secure by default, like [`std/tls`](tls.md)'s own
`dial`), and completes the handshake; `acceptQuic` does the server side on an
already-bound socket, for one connection. A connection carries any number of
bidirectional streams: `openStream`/`acceptStream` open one, `write` queues
bytes, `finish` marks the send side done, `read` pulls reassembled bytes
until `fin`.

```bit
import { dialQuic, acceptQuic, Conn, Stream, StreamChunk } from "std/quic"
import { UdpSocket } from "std/net"

// Client: open a stream, send a request, read the reply to the end of stream.
fn request(host: string, port: int, req: []byte): []byte! {
  let conn = dialQuic(host, port, "example.com")?
  let s = conn.openStream()?
  s.write(req)?
  s.finish()?
  let reply = []byte(0)
  let done = false
  while (!done) {
    let chunk = s.read()?
    for b of chunk.data {
      reply = append(reply, b)
    }
    done = chunk.fin
  }
  conn.close()
  return reply
}

// Server: accept one connection on an already-bound UDP socket, take the client's
// stream, and drain it to the end.
fn serve(sock: UdpSocket, chainPem: string, keyPem: string): []byte! {
  let conn = acceptQuic(sock, chainPem, keyPem)?
  let s = conn.acceptStream()?
  let body = []byte(0)
  let done = false
  while (!done) {
    let chunk = s.read()?
    for b of chunk.data {
      body = append(body, b)
    }
    done = chunk.fin
  }
  return body
}
```

For a pinned CA, `insecureSkipVerify` in a test, or another custom TLS
config, use `dialQuicTls` - the same `getTls`/`requestTls` shape
[`std/http`](http.md) uses:

```bit
import { dialQuicTls, Conn } from "std/quic"
import { TlsConfig } from "std/tls"
import { TrustStore } from "std/crypto"

// Dial, pinning a specific CA instead of the system roots.
fn dialPinned(host: string, port: int, trust: TrustStore): Conn! {
  return dialQuicTls(host, port, host, TlsConfig(trust))?
}
```

A server that expects more than one client uses `listenQuic` instead of
`acceptQuic`: it owns the socket, demultiplexes every datagram to the right
connection by id, and hands back each established connection through
`Listener.accept()`.

## Sharp edges

**One connection idles out by default after 30s of silence.** Lower it with
`Conn.setIdleTimeout` if your protocol needs a vanished peer detected sooner - a
thread parked in `read`, `finish`, or `acceptStream` otherwise waits until the
timeout, or forever if you never set one and the peer never speaks again.

**A `finish`ed or `reset` send side cannot be reused.** `finish` blocks until every
byte is acknowledged; `reset` abandons unsent and unacknowledged data and tells the
peer to stop expecting the rest. A `reset` after a `finish` whose FIN is out but not
yet fully acknowledged still sends RESET_STREAM and stops the retransmissions
(RFC 9000 section 3.1); once everything is acknowledged, `reset` does nothing.

**This implementation is deliberately narrow.** NewReno congestion control only (no
CUBIC/BBR); connection migration is connection-id basics only, with no path
validation; one connection per socket from `acceptQuic` (use `listenQuic` for many
clients on one socket); AES-128-GCM + X25519 only.

## When not to use it directly

If you are building an HTTP service, use [`pkg/web`](/packages/web) or
[`std/http3`](http3.md): they run HTTP/3 over this transport and give you the
plain request/handler API. Reach for `std/quic` only when your protocol is not
HTTP.

## Connections and streams

### `dialQuic(host: string, port: int, serverName: string): Conn!`

Opens a connection to `host:port`, verifying the server's certificate
against the system trust roots (or the small bundled set if those are
unavailable) - secure by default, like `std/tls`'s own `dial` - and
completes the handshake before returning.

### `dialQuicTls(host: string, port: int, serverName: string, config: TlsConfig): Conn!`

Like `dialQuic`, with an explicit `std/tls` `TlsConfig` - a pinned CA,
`insecureSkipVerify` for tests, or another custom config.

### `acceptQuic(sock: UdpSocket, certChainPem: string, keyPem: string): Conn!`

Accepts one connection on the already-bound socket `sock`, using the given
certificate chain and private key, and completes the handshake. Serves
exactly one connection; use `listenQuic` for a socket that serves many
clients.

### `listenQuic(sock: UdpSocket, certChainPem: string, keyPem: string): Listener!`

Binds a listener on the already-bound socket `sock` that can accept many
concurrent connections, each identified by its own connection id. Returns
immediately; connections arrive through `Listener.accept`.

### `Listener`

A QUIC server listener owning one bound UDP socket, sorting incoming packets
to the right connection.

### `Listener.accept(): Conn!`

Blocks until the next connection finishes its handshake, then returns it.

### `Listener.stopAccepting()`

Stops admitting new connections. Connections already accepted are
unaffected.

### `Conn`

An established QUIC connection. Safe to use from many green threads at once.

### `Conn.peerIp(): string`

The peer's address, fixed for the life of the connection, or `""` if
unknown.

### `dialQuicTlsUntil(host: string, port: int, serverName: string, config: TlsConfig, wake: chan<int>): Conn!`

`dialQuicTls`, but a value on `wake` (capacity 1) ends the wait for the handshake with `Woken` and closes the connection being set up.

### `streamReadUntil(s: Stream, wake: chan<int>): StreamChunk!`

`Stream.read`, but a value on `wake` ends the wait with `Woken`.

### `streamFinishUntil(s: Stream, wake: chan<int>): ()!`

`Stream.finish`, but a value on `wake` ends the wait for the acknowledgements with `Woken`; the FIN stays queued and `Stream.reset` abandons it.

### `Woken`

What the three functions above fail with when their `wake` channel received a value first.

### `Conn.openStream(): Stream!`

Opens a new bidirectional stream from this side.

### `Conn.acceptStream(): Stream!`

Blocks until the peer opens a new stream, then returns it.

### `Conn.setIdleTimeout(ns: int)`

Sets how long, in nanoseconds, the connection tolerates silence from the
peer before giving up. The default is 30 seconds; lower it to detect a
vanished peer sooner.

### `Conn.close()`

Closes the connection with no application error code.

### `Conn.closeWithCode(code: int)`

Closes the connection, telling the peer the application error code `code`.

### `Stream`

One bidirectional stream on a `Conn`. Write and read independently in each
direction.

### `Stream.write(data: []byte): ()!`

Queues `data` to send on this stream.

### `Stream.finish(): ()!`

Marks this stream's send side done and blocks until the peer has
acknowledged every byte. A finished send side cannot be reused.

### `Stream.reset(code: int): ()!`

Abandons this stream's send side immediately, discarding any unsent data and
telling the peer to stop expecting the rest. Does not wait for
acknowledgment. Do not call this after `finish` on the same stream is
already in flight.

### `Stream.stopSending(code: int): ()!`

Asks the peer to stop sending on this stream, carrying `code` as the reason.

### `Stream.read(): StreamChunk!`

Blocks until the next reassembled chunk of inbound data is available, then
returns it.

### `Stream.id(): int`

This stream's id.

### `StreamChunk`

One inbound take from a stream: `data` is the bytes received, `fin` marks
the end of the stream, and `reset` (with `resetCode`) is set instead when
the peer abandoned its send side rather than finishing normally.

## Frames

A QUIC packet payload is a sequence of frames, and every number in the
protocol (a length, offset, stream id, or error code) is a variable-length
integer: the encoded length is 1, 2, 4, or 8 bytes depending on the value's
size.

### `encodeVarint(v: u64): []byte`

The shortest variable-length integer encoding of `v`. `v` must fit in 62
bits.

### `decodeVarint(data: []byte): u64!`

Decodes the variable-length integer at the start of `data`, ignoring any
trailing bytes. Fails on an empty slice or a length that runs past the end.

### `varintSize(v: u64): int`

The number of bytes `encodeVarint` will use for `v`, for sizing a buffer up
front.

### `AckRange`

One acknowledgment range: a `gap` of unacknowledged packets and a
`rangeLength` of acknowledged ones.

### `AckFrame`

An ACK frame: the largest acknowledged packet number in `largest`, the ack
delay, the first range, any additional gap/range pairs, and, when `ecn` is
set, the three ECN congestion counters.

### `StreamFrame`

A STREAM frame carrying part of a stream's data: `id`, `offset`, `data`, and
the `hasOffset`/`hasLength`/`fin` flags that say which fields are present on
the wire.

### `Frame`

One QUIC frame, covering every frame kind this module supports: padding, a
ping, an ack, resetting or stopping a stream, a piece of the handshake
(`Crypto`), a piece of a stream (`Stream`), flow-control updates, connection
management, and connection close.

### `encodeFrame(f: Frame): []byte`

The wire encoding of one frame.

### `encodeFrames(frames: []Frame): []byte`

The concatenated wire encoding of `frames`, in order.

### `parseFrames(data: []byte): []Frame!`

Parses every frame in `data`, in order, until the buffer is exactly
consumed. Fails on an unknown frame type or a field that runs past the end.

## Packet protection

Every QUIC packet is encrypted and its header partly hidden. This part of
the module derives the keys, encrypts and decrypts packet payloads, and
applies or removes header protection.

### `quicVersion1: int`

QUIC version 1.

### `longInitial: int`

The long-header packet type for an Initial packet, the first packet of a
connection.

### `longZeroRtt: int`

The long-header packet type for a 0-RTT packet.

### `longHandshake: int`

The long-header packet type for a Handshake packet.

### `longRetry: int`

The long-header packet type for a Retry packet.

### `PacketKeys`

One direction's packet-protection keys for one encryption level: the AEAD
`key`, the `iv`, and the header-protection key `hp`.

### `initialSalt(): []byte`

The fixed salt used to derive Initial packet keys, the same for every QUIC
v1 connection.

### `expandLabel(secret: []byte, label: string, length: int): []byte`

Expands `secret` to `length` bytes bound to `label`, the key-derivation
function every other key in this module builds on.

### `deriveInitialSecret(dcid: []byte): []byte`

The secret both directions' Initial keys descend from, derived from the
client's chosen destination connection id `dcid`.

### `clientInitialSecret(dcid: []byte): []byte`

The client's Initial traffic secret, derived from `dcid`.

### `serverInitialSecret(dcid: []byte): []byte`

The server's Initial traffic secret, derived from `dcid`.

### `deriveKeys(secret: []byte): PacketKeys`

The key, iv, and header-protection key derived from a traffic `secret`.

### `clientInitialKeys(dcid: []byte): PacketKeys`

The keys that protect the client's Initial packets, derived end to end from
`dcid`.

### `serverInitialKeys(dcid: []byte): PacketKeys`

The keys that protect the server's Initial packets, derived end to end from
`dcid`.

### `packetNumberLength(pn: u64, largestAcked: int): int`

The smallest number of bytes (1 to 4) needed to encode packet number `pn`
given the highest packet number the peer has acknowledged so far. Pass a
negative `largestAcked` when nothing has been acknowledged yet.

### `encodePacketNumber(pn: u64, pnLength: int): []byte`

The `pnLength`-byte encoding of packet number `pn`.

### `packetNonce(iv: []byte, pn: u64): []byte`

The AEAD nonce for packet number `pn`, combining it with `iv`.

### `protectPayload(keys: PacketKeys, pn: u64, header: []byte, payload: []byte): []byte!`

Encrypts `payload` under `keys` for packet number `pn`, authenticating
`header` alongside it. Returns the protected payload with its tag.

### `unprotectPayload(keys: PacketKeys, pn: u64, header: []byte, ciphertext: []byte): []byte!`

Decrypts `ciphertext` under `keys` for packet number `pn`, checking it
against `header`. Fails if the data was tampered with.

### `headerSample(protectedPayload: []byte, pnLength: int): []byte!`

The bytes sampled from an encrypted payload to compute the header-protection
mask. Fails if the payload is too short.

### `aesHeaderMask(hpKey: []byte, sample: []byte): []byte!`

The header-protection mask for an AES-based cipher suite, computed from
`hpKey` and `sample`.

### `chachaHeaderMask(hpKey: []byte, sample: []byte): []byte!`

The header-protection mask for the ChaCha20-Poly1305 cipher suite, computed
from `hpKey` and `sample`.

### `applyHeaderProtection(packet: []byte, pnOffset: int, mask: []byte): ()!`

Hides the packet number and header bits of `packet` in place using `mask`,
before sending.

### `removeHeaderProtection(packet: []byte, pnOffset: int, mask: []byte): int!`

Reveals the packet number and header bits of `packet` in place using
`mask`, on receipt, and returns the recovered packet-number length.

### `LongHeader`

The fields common to every long-header packet: the packet `typ`, the
`version`, and the source and destination connection ids.

### `parseLongHeader(packet: []byte): LongHeader!`

The long-header fields of `packet`. Fails if `packet` does not have a long
header or is truncated.

### `encodeInitialHeader(version: int, dcid: []byte, scid: []byte, token: []byte, length: u64, pn: u64, pnLength: int): []byte`

The unprotected bytes of an Initial packet's header, used as the
authenticated data when protecting its payload.

### `ShortHeader`

The fields of a short (1-RTT) header recovered after header protection is
removed: the spin and key-phase bits, the destination connection id, and the
packet-number length.

### `encodeShortHeader(dcid: []byte, pn: u64, pnLength: int, spinBit: bool, keyPhase: bool): []byte`

The unprotected bytes of a short header for packet number `pn` on
connection id `dcid`.

### `parseShortHeader(packet: []byte, dcidLen: int): ShortHeader!`

The short-header fields of `packet`, given the connection's known
destination-connection-id length `dcidLen`. Call this after
`removeHeaderProtection`.

### `retryIntegrityTag(odcid: []byte, retryWithoutTag: []byte): []byte!`

The integrity tag for a Retry packet, authenticating it against the original
destination connection id `odcid`.

### `verifyRetry(odcid: []byte, fullRetry: []byte): bool!`

Whether the trailing integrity tag of `fullRetry` is valid for `odcid`.

### `encodeVersionNegotiation(dcid: []byte, scid: []byte, versions: []int): []byte`

A Version Negotiation packet listing the server's supported `versions`, in
reply to a client request for a version this server does not support.

### `isVersionNegotiation(packet: []byte): bool`

Whether `packet` is a Version Negotiation packet.

## QUIC-TLS

The seam between QUIC and [`std/tls`](tls.md)'s handshake: transport
parameters, per-level key derivation, and carrying handshake bytes in CRYPTO
frames.

```bit
import {
  defaultTransportParameters, encodeTransportParameters, levelKeys, updateSecret,
  cryptoFrames, reassembleCryptoFrames, PacketKeys,
} from "std/quic"
import { HashAlg } from "std/crypto"

// Our transport parameters, as the quic_transport_parameters extension body.
fn myParameters(): []byte {
  let tp = defaultTransportParameters()
  tp.initialMaxData = 1048576
  tp.initialMaxStreamsBidi = 100
  return encodeTransportParameters(tp)
}

// The 1-RTT packet keys for one direction, and the next secret after a key update.
fn oneRttKeys(secret: []byte): PacketKeys {
  return levelKeys(HashAlg.Sha256, secret, 16)
}

fn rollForward(secret: []byte): []byte {
  return updateSecret(HashAlg.Sha256, secret)
}

// Carry a handshake message in CRYPTO frames and reassemble it in order.
fn carry(handshake: []byte): []byte! {
  let frames = cryptoFrames(handshake, 0, 1000)
  return reassembleCryptoFrames(frames, 65536)?
}
```

### `quicTransportParametersExtension: int`

The TLS extension codepoint that carries the transport parameters below.

### `TransportParameters`

The transport parameters an endpoint sends its peer during the handshake,
such as how much data and how many streams it will accept.

### `defaultTransportParameters(): TransportParameters`

Transport parameters filled with their default values. Start here and set
only the ones that differ.

### `encodeTransportParameters(tp: TransportParameters): []byte`

The extension body encoding of `tp`, omitting every parameter still at its
default.

### `decodeTransportParameters(data: []byte): TransportParameters!`

The transport parameters `data` encodes, starting from the defaults for
anything the peer omitted.

### `EncryptionLevel`

The three packet-protection levels a connection passes through: `Initial`,
`Handshake`, and `OneRtt`.

### `levelPacketType(level: EncryptionLevel): int`

The long-header packet type that carries `level`. Returns -1 for `OneRtt`,
which uses a short header instead.

### `levelKeys(alg: HashAlg, secret: []byte, keyLen: int): PacketKeys`

The packet-protection keys for a non-Initial level, derived from a TLS
traffic `secret`.

### `LevelKeyPair`

Both directions' keys for one non-Initial encryption level: `client` and
`server`.

### `levelKeyPair(alg: HashAlg, clientSecret: []byte, serverSecret: []byte, keyLen: int): LevelKeyPair`

Both directions' keys for one level, derived from the client and server TLS
traffic secrets.

### `updateSecret(alg: HashAlg, secret: []byte): []byte`

The next-generation 1-RTT secret for a key update. The header-protection key
is not updated; re-derive only the AEAD key and iv from the result.

### `nextKeyPhase(keyPhase: bool): bool`

The key-phase bit after a key update.

### `cryptoFrames(data: []byte, startOffset: u64, maxChunk: int): []Frame`

Splits the handshake bytes `data` into CRYPTO frames of at most `maxChunk`
bytes each, ready to place in a packet.

### `CryptoAssembler`

A reassembler for CRYPTO frames that may arrive out of order or overlap.
Build one with `CryptoAssembler(maxLen)`.

### `CryptoAssembler(maxLen: int)`

A fresh assembler that accepts data up to `maxLen` bytes total.

### `CryptoAssembler.insert(offset: u64, fragment: []byte): ()!`

Records one received fragment at `offset`.

### `CryptoAssembler.contiguous(): []byte`

The contiguous reassembled prefix received so far, starting from offset 0.

### `CryptoAssembler.contiguousLen(): int`

The length of the contiguous reassembled prefix.

### `reassembleCryptoFrames(frames: []Frame, maxLen: int): []byte!`

Reassembles a set of CRYPTO frames directly into the contiguous handshake
byte stream, without building a `CryptoAssembler` yourself.
