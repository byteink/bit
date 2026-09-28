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

`dialQuic` opens a connection and completes the handshake; `acceptQuic` does the
server side on an already-bound socket, for one connection. A connection carries
any number of bidirectional streams: `openStream`/`acceptStream` open one, `write`
queues bytes, `finish` marks the send side done, `read` pulls reassembled bytes
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
byte is acknowledged; `reset` abandons unsent data and tells the peer to stop
expecting the rest. Do not call `reset` after a `finish` on the same stream is
already in flight - the two are mutually exclusive endings for the same send side.

**This implementation is deliberately narrow.** NewReno congestion control only (no
CUBIC/BBR); connection migration is connection-id basics only, with no path
validation; one connection per socket from `acceptQuic` (use `listenQuic` for many
clients on one socket); AES-128-GCM + X25519 only.

## When not to use it directly

If you are building an HTTP service, use [`pkg/web`](/packages/web) or
[`std/http3`](http3.md): they run HTTP/3 over this transport and give you the
plain request/handler API. Reach for `std/quic` only when your protocol is not
HTTP.

## Reference

### Transport / connection

| | |
|---|---|
| `dialQuic(host, port, serverName): Conn!` | open a connection and complete the handshake |
| `acceptQuic(sock, certChainPem, keyPem): Conn!` | accept one connection on a bound socket |
| `listenQuic(sock, certChainPem, keyPem): Listener!` | bind a listener for many concurrent connections |
| `Listener.accept(): Conn!` | accept the next established connection |
| `Listener.stopAccepting()` | stop admitting new connections; existing ones are unaffected |
| `Conn.peerIp(): string` | the peer address the handshake established (frozen for the connection's life; `""` if unknown) |
| `Conn.openStream(): Stream!` | open a client-initiated bidirectional stream |
| `Conn.acceptStream(): Stream!` | accept the next peer-initiated stream |
| `Conn.setIdleTimeout(ns: int)` | how long to tolerate silence before giving up (default 30s) |
| `Conn.close()` | send CONNECTION_CLOSE (code 0) and stop |
| `Conn.closeWithCode(code: int)` | as `close`, with an application error code |
| `Stream.write(data: []byte): ()!` | queue outbound data |
| `Stream.finish(): ()!` | mark the send side done, block until acknowledged |
| `Stream.reset(code: int): ()!` | abandon the send side (RESET_STREAM); fire-and-forget |
| `Stream.stopSending(code: int): ()!` | ask the peer to stop sending on this stream |
| `Stream.read(): StreamChunk!` | read the next reassembled inbound chunk |
| `Stream.id(): int` | the stream's id |
| `StreamChunk { data, fin, reset, resetCode }` | one inbound take; `reset` set on a peer RESET_STREAM |

### Frames

The frame codec (RFC 9000): `Frame` covers every QUIC v1 frame kind, and every
protocol number is a variable-length integer.

| | |
|---|---|
| `encodeVarint(v): []byte`, `decodeVarint(data): u64!`, `varintSize(v): int` | the variable-length integer codec |
| `AckRange { gap, rangeLength }`, `AckFrame { largest, delay, firstRange, ranges, ecn, ect0, ect1, ce }` | an ACK frame and its ranges |
| `StreamFrame { id, offset, data, hasOffset, hasLength, fin }` | a STREAM frame |
| `Frame` | every v1 frame kind as one sum type (`Padding(n)`, `Ping`, `Crypto(offset, data)`, `ConnectionClose`, `ApplicationClose`, ...) |
| `encodeFrame(f): []byte`, `encodeFrames(frames): []byte` | encode one or many frames |
| `parseFrames(data): []Frame!` | parse every frame in a payload |

### Packet protection

Key derivation, AEAD sealing, and header protection (RFC 9001) for the packets
that carry the frames above.

| | |
|---|---|
| `quicVersion1`, `longInitial` `longZeroRtt` `longHandshake` `longRetry` | QUIC v1 and the long-header packet types |
| `PacketKeys { key, iv, hp }` | one direction's AEAD key, IV, and header-protection key |
| `initialSalt(): []byte` | the fixed QUIC v1 Initial salt |
| `expandLabel(secret, label, length): []byte` | TLS 1.3 HKDF-Expand-Label as QUIC uses it |
| `deriveInitialSecret(dcid)`, `clientInitialSecret(dcid)`, `serverInitialSecret(dcid)` | the Initial secret ladder |
| `deriveKeys(secret): PacketKeys` | key/iv/hp from a traffic secret |
| `clientInitialKeys(dcid): PacketKeys`, `serverInitialKeys(dcid): PacketKeys` | Initial keys derived end to end from a connection id |
| `packetNumberLength(pn, largestAcked): int`, `encodePacketNumber(pn, pnLength): []byte` | packet-number encoding |
| `packetNonce(iv, pn): []byte` | the AEAD nonce for a packet number |
| `protectPayload(keys, pn, header, payload): []byte!`, `unprotectPayload(keys, pn, header, ciphertext): []byte!` | seal/open a packet payload |
| `headerSample(protectedPayload, pnLength): []byte!` | the header-protection sample |
| `aesHeaderMask(hpKey, sample): []byte!`, `chachaHeaderMask(hpKey, sample): []byte!` | the AES-ECB and ChaCha20 header-protection masks |
| `applyHeaderProtection(packet, pnOffset, mask): ()!`, `removeHeaderProtection(packet, pnOffset, mask): int!` | apply/remove header protection in place |
| `LongHeader { ... }`, `parseLongHeader(packet): LongHeader!` | the invariant long-header fields |
| `encodeInitialHeader(...)` | the unprotected Initial header (the AEAD additional data) |
| `ShortHeader { ... }`, `encodeShortHeader(...)`, `parseShortHeader(packet, dcidLen): ShortHeader!` | the 1-RTT short header |
| `retryIntegrityTag(odcid, retryWithoutTag): []byte!`, `verifyRetry(odcid, fullRetry): bool!` | the Retry integrity tag |
| `encodeVersionNegotiation(dcid, scid, versions): []byte`, `isVersionNegotiation(packet): bool` | Version Negotiation packets |

### QUIC-TLS

The seam between QUIC and [`std/tls`](tls.md)'s record-bypass handshake: transport
parameters, per-level key derivation, and CRYPTO-frame carriage.

```bit
import {
  defaultTransportParameters, encodeTransportParameters, levelKeys, updateSecret,
  cryptoFrames, reassembleCryptoFrames, PacketKeys,
} from "std/quic"
import { Hash, newSha256 } from "std/crypto"

fn sha256(): Hash { return newSha256() }

// Our transport parameters, as the quic_transport_parameters extension body.
fn myParameters(): []byte {
  let tp = defaultTransportParameters()
  tp.initialMaxData = 1048576
  tp.initialMaxStreamsBidi = 100
  return encodeTransportParameters(tp)
}

// The 1-RTT packet keys for one direction, and the next secret after a key update.
fn oneRttKeys(secret: []byte): PacketKeys {
  return levelKeys(sha256, secret, 16)
}

fn rollForward(secret: []byte): []byte {
  return updateSecret(sha256, secret)
}

// Carry a handshake message in CRYPTO frames and reassemble it in order.
fn carry(handshake: []byte): []byte! {
  let frames = cryptoFrames(handshake, 0, 1000)
  return reassembleCryptoFrames(frames, 65536)?
}
```

| | |
|---|---|
| `quicTransportParametersExtension` | the TLS extension codepoint (0x0039) carrying the parameters below |
| `TransportParameters { ... }`, `defaultTransportParameters(): TransportParameters` | the parameters an endpoint sends its peer, seeded with RFC defaults |
| `encodeTransportParameters(tp): []byte`, `decodeTransportParameters(data): TransportParameters!` | codec for the extension body |
| `EncryptionLevel` (`Initial`, `Handshake`, `OneRtt`) | the three packet-protection levels |
| `levelPacketType(level): int` | the long-header type for a level (-1 for `OneRtt`) |
| `levelKeys(newHash, secret, keyLen): PacketKeys` | Handshake/1-RTT keys from a TLS traffic secret |
| `LevelKeyPair { client, server }`, `levelKeyPair(newHash, clientSecret, serverSecret, keyLen): LevelKeyPair` | both directions' keys for one level |
| `updateSecret(newHash, secret): []byte` | the next-generation 1-RTT secret for a key update |
| `nextKeyPhase(keyPhase): bool` | the key-phase bit after a key update |
| `cryptoFrames(data, startOffset, maxChunk): []Frame` | chunk a handshake byte stream into CRYPTO frames |
| `CryptoAssembler`, `newCryptoAssembler(maxLen): CryptoAssembler` | reassembler for out-of-order CRYPTO fragments |
| `CryptoAssembler.insert(offset, fragment): ()!` | record one received fragment |
| `CryptoAssembler.contiguous(): []byte`, `.contiguousLen(): int` | the contiguous reassembled prefix |
| `reassembleCryptoFrames(frames, maxLen): []byte!` | reassemble a set of CRYPTO frames directly |

Specification: RFC 9000 (transport), RFC 9001 (TLS/packet protection).
