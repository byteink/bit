# std/tls

TLS 1.3 over a TCP connection: dial a server and get back an encrypted byte
stream, or serve one. Reach for it when a program needs to talk securely over
the network itself; if you are building an HTTP API, `std/http` already
speaks TLS for you (pass it a certificate) and `pkg/web` builds on that, so
most programs never call this module directly.

<!-- doctest: per-block -->

## Dial a server

`dial` opens the TCP connection and runs the handshake in one call, verifying
the server's certificate chain against a trust store and checking its name
matches the host you asked for.

```bit
import { dial, TlsConfig } from "std/tls"
import { systemRoots, bundled } from "std/crypto"

fn fetchHomepage(host: string): string! {
  let roots = systemRoots() catch _ {
    bundled()
  }
  let cfg = TlsConfig(roots)
  let conn = dial(host, 443, cfg)?
  conn.write([]byte("GET / HTTP/1.1\r\nHost: ${host}\r\nConnection: close\r\n\r\n"))?
  let reply = conn.read(4096)?
  conn.close()
  return string(reply)
}
```

`systemRoots()` reads the operating system's CA bundle; `bundled()` is a
built-in fallback for a host without one (see [std/crypto](/std/crypto) for
both). `conn` behaves like any other stream: `write` sends plaintext that
goes out encrypted, `read(n)` returns up to `n` plaintext bytes, `close` ends
the connection. `client(conn, host, config)` does the same handshake over a
`std/net` connection you already opened, for example one wrapped in a proxy.

## Serve TLS

`listen` takes a `TlsServerConfig`, built from a certificate chain and its
matching private key in PEM plus the ALPN protocols you support, and runs the
server side of the handshake for every connection it accepts.

```bit
import { listen, TlsServerConfig } from "std/tls"

fn serveOnce(port: int, certPem: string, keyPem: string): ()! {
  let cfg = TlsServerConfig(certPem, keyPem, ["h2", "http/1.1"])?
  let ln = listen("127.0.0.1", port, cfg)?
  let conn = ln.accept()?
  conn.write([]byte("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"))?
  conn.close()
  ln.close()
  return
}
```

A server does not verify a client's identity, so it has no trust store: the
client side is `TlsConfig`, the server side is `TlsServerConfig`, and neither
carries fields the other ignores. The third argument lists the protocol names
you support, most preferred first (`[]` for none); read what the client picked
back with `conn.alpnProtocol()`. `TlsServerConfig` reads the PEM when you build
it, so a missing or malformed certificate or key fails there, not on the first
connection.

## Trust stores and certificates

A trust store is the set of certificate authorities you are willing to
believe. `std/crypto` builds one three ways: `systemRoots()` (the OS bundle),
`bundled()` (a built-in fallback), or `fromPem(pem)` (your own pinned roots,
for a private PKI or a test fixture). Pass whichever one fits to
`TlsConfig(roots)`.

Once connected, inspect who you are actually talking to with
`peerCertificates()`, which returns the chain as raw DER, end-entity
certificate first:

```bit
import { dial, TlsConfig } from "std/tls"
import { systemRoots, x509Parse } from "std/crypto"

fn peerSubject(host: string, port: int): string! {
  let cfg = TlsConfig(systemRoots()?)
  let conn = dial(host, port, cfg)?
  let chain = conn.peerCertificates()
  conn.close()
  let leaf = x509Parse(chain[0])?
  return leaf.subject
}
```

`x509Parse` and the `Certificate` type it returns live in
[std/crypto](/std/crypto), since they are also useful outside of TLS
(inspecting a certificate file, say); `x509MatchHostname` there is the same
check `dial` already runs for you against `config.serverName`.

## When the handshake fails

A failed handshake is a `HandshakeError`, and its `kind` tells you whether
trying again can help. `Verification` means the server's identity was not
proven (an untrusted or self-signed chain, a name the certificate does not
cover, an expired certificate): the server will present the same certificate
next time, so retrying only delays the answer. `Negotiation` means the two
sides could not agree, or the server broke the protocol (no shared cipher, an
alert, a malformed message): the same offer draws the same answer. `Io` means
the network failed under the handshake (a reset, a close mid-record, a
timeout): a later attempt can succeed.

```bit
import { dial, HandshakeError, HandshakeFailure, TlsConfig } from "std/tls"

fn worthRetrying(host: string, cfg: TlsConfig): bool {
  dial(host, 443, cfg) catch e {
    let (h, ok) = e.(HandshakeError)
    if (!ok) {
      return true
    }
    return h.kind == HandshakeFailure.Io
  }
  return false
}
```

A failure before the handshake starts (the host does not resolve, the TCP
connect is refused) is not a `HandshakeError`: it is the plain `std/net`
error, so the `ok` check above treats it as the network failure it is.
`message()` of a `HandshakeError` is the text the failure always had, so code
that only prints the error is unchanged.

## Security notes

**Never set `insecureSkipVerify: true` outside a test.** It turns off both
chain and hostname verification, so the connection is still encrypted but no
longer proves who you are talking to; it exists for pinned replay and local
testing, never for a shipped client.

**Only TLS 1.3 is implemented.** There is no version setting: every
connection is TLS 1.3, the version with no known downgrade or renegotiation
attacks that plagued 1.2 and earlier.

**Pin certificates with `fromPem`, not `insecureSkipVerify`.** If you need to
trust one specific server rather than the public CA system, build a
`TrustStore` from that server's own certificate PEM and use it as
`config.roots`; the connection still gets full chain and hostname checking,
just against a smaller trust set.

## Sharp edges

- **`TlsListener.accept()` returns before the handshake runs.** The TLS
  handshake happens lazily, on the first `read`, `write`, or explicit
  `handshake()` call on the connection it returns, so a client that opens the
  TCP connection and then stalls only blocks its own connection, never your
  accept loop. Call `handshake()` yourself first if you need
  `alpnProtocol()`/`peerCertificates()` before your first read or write.
- **`TlsServerConfig(...)` fails immediately if the certificate or key PEM is
  empty or malformed**, rather than failing later on the first connection.
- **A handshake failure surfaces from `read`/`write`/`handshake`, not from
  `dial`/`listen`/`accept`.** `dial` does run the handshake before returning,
  so a failed one does fail there; a server-side `accept()` cannot, since it
  has not run the handshake yet.
- **`dial` defaults `serverName` to its `host` argument.** Set
  `config.serverName` explicitly only when you are connecting to an IP
  address or a proxy and need the certificate checked against a different
  name.

## Where to go next

- [std/crypto](/std/crypto) for trust stores, certificates, and the ciphers
  this module uses underneath.
- [std/http](/std/http) to serve or call HTTPS instead of raw TLS bytes.
- [std/net](/std/net) for the plain TCP connections `dial`/`listen` build on.
- [pkg/web](/packages/web) to build a full web application; it configures TLS
  for you.

## Connecting and serving

`dial`, `listen`, `client`, `TlsConfig`, `TlsServerConfig`, `TlsConn`, and `TlsListener` are the
path almost every program needs; the rest of this reference is the TLS 1.3
engine underneath them, exported for building custom tooling directly against
the handshake.

### `TlsConfig`

`roots`, `insecureSkipVerify`, `alpn`, `serverName`, `nowUnix`: the client side of a connection, taken by `dial`, `dialDeadline` and `client`. A server uses `TlsServerConfig`.

### `TlsConfig(roots: TrustStore, serverName: string = "", alpn: []string = ..., insecureSkipVerify: bool = false, nowUnix: int = 0)`

A secure-by-default client config: verification on, TLS 1.3. `roots` is
required, and the rest are named only when you need them:
`TlsConfig(roots, serverName = host, alpn = ["h2"])`.

### `emptyTrustStore(): TrustStore`

A trust store with no roots, for a deliberately unverified client
(`insecureSkipVerify = true`).

### `dial(host: string, port: int, config: TlsConfig): TlsConn!`

Opens a TCP connection to `host:port` and runs the client handshake.

### `dialDeadline(host: string, port: int, config: TlsConfig, deadlineNs: int): TlsConn!`

Like `dial`, with a deadline on the whole connect-plus-handshake.

### `client(conn: Conn, host: string, config: TlsConfig): TlsConn!`

Runs the client handshake over an already-open `std/net` connection.

### `HandshakeFailure`

The three ways a client handshake fails: `Verification` (the server's
identity was not proven), `Negotiation` (no agreement, or a protocol
violation) and `Io` (the transport failed under the handshake).

### `HandshakeError`

What `dial`, `dialDeadline` and `client` fail with when the handshake itself
fails. `kind` is the `HandshakeFailure`; `message()` is the failure's text.
See "When the handshake fails" above.

### `HandshakeError.message(): string`

The text of the failure, as `dial` reported it before the error was typed.

### `TlsConn`

An established connection.

### `TlsConn.read(n: int): []byte!`

Reads up to `n` plaintext bytes.

### `TlsConn.write(b: []byte): ()!`

Writes plaintext; it leaves the connection encrypted.

### `TlsConn.readInto(buf: []byte, max: int): int!`

`read` returns a fresh slice on every call. `readInto` copies the next
plaintext into a buffer the caller owns and reuses: up to `max` bytes, never
more than `len(buf)`, landing at `buf[0:n]`. It allocates nothing in proportion
to the data, and `0` is the end of the stream, as an empty `read` is. Like
`read`, it runs the handshake first if that has not happened yet. The next
call overwrites `buf`, so take the bytes out before calling again. Use it
for a long stream or a per-request read loop:

```bit
import { TlsConn } from "std/tls"

// Count the bytes of a stream through one reused buffer.
fn countBytes(c: TlsConn): int! {
  let buf = []byte(4096)
  let total = 0
  let n = c.readInto(buf, len(buf))?
  while (n > 0) {
    total = total + n
    n = c.readInto(buf, len(buf))?
  }
  return total
}
```

### `TlsConn.close()`

Closes the connection.

### `TlsConn.shutdown()`

Closes the connection and also sends a TLS close-notify alert first.

### `TlsConn.handshake(): ()!`

Runs the handshake now if it has not run yet. A no-op after `dial`; needed after `accept` if you want `alpnProtocol`/`peerCertificates` before the first read or write.

### `TlsConn.alpnProtocol(): string`

The ALPN protocol the two sides negotiated.

### `TlsConn.cipherSuiteId(): int`

The negotiated cipher-suite code point.

### `TlsConn.peerCertificates(): [][]byte`

The peer's certificate chain as raw DER, end-entity certificate first.

### `TlsConn.peerIp(): string!`

The peer's IPv4 address, forwarded from the underlying socket.

### `TlsConn.setDeadline(deadlineNs: int)`

Sets a read/write deadline on this connection.

### `TlsConn.deadlineNs(): int`

The current read/write deadline.

### `TlsConn.readTimedOut(): bool`

Whether the last read stopped because the deadline passed.

### `TlsListener`

A listening socket serving one `TlsServerConfig`.

### `listen(host: string, port: int, config: TlsServerConfig): TlsListener!`

Binds a listening socket on `host:port` that runs the server handshake on every connection it accepts.

### `TlsListener.accept(): TlsConn!`

Accepts the next TCP connection. The handshake runs lazily; see [Sharp edges](#sharp-edges).

### `TlsListener.port(): int!`

The port this listener is bound to.

### `TlsListener.isClosed(): bool`

Whether `close` has already run on this listener.

### `TlsListener.close()`

Closes the listener.

### `tlsVersion13: int`

The TLS 1.3 wire version code point, the only version this module speaks.

## Cipher suites

### `CipherSuite`

A suite descriptor: id, name, key/IV/tag/hash lengths.

### `TLS_AES_128_GCM_SHA256: int`

The three mandatory TLS 1.3 suite code points.

### `TLS_AES_256_GCM_SHA384: int`

The three mandatory TLS 1.3 suite code points.

### `TLS_CHACHA20_POLY1305_SHA256: int`

The three mandatory TLS 1.3 suite code points.

### `tlsSuiteById(id: int): CipherSuite!`

Look up a suite by its wire code point.

### `tlsSuitePreference(): []CipherSuite`

The suites this module offers, strongest first.

### `tlsSuiteNewAead(suite: CipherSuite, key: []byte): Aead!`

Build the live cipher or hash for a suite.

### `tlsSuiteHash(suite: CipherSuite): HashAlg`

The suite's transcript and HKDF digest as a `HashAlg` (`HashAlg.Sha384` for TLS_AES_256_GCM_SHA384, `HashAlg.Sha256` for the other two). Every key-schedule function below takes it.

## Key exchange groups

### `TlsGroup`

`X25519`, `Secp256r1`, `Secp384r1`, `X25519MLKEM768` (the post-quantum hybrid, offered first by default).

### `GroupKeypair`

An initiator's key-exchange state and a responder's answer to it.

### `GroupResponse`

An initiator's key-exchange state and a responder's answer to it.

### `tlsGroupGenerate(g: TlsGroup): GroupKeypair`

Generate an initiator's ephemeral key share for `g`.

### `tlsGroupComputeShared(g: TlsGroup, priv: []byte, peerKeyShare: []byte): []byte!`

An initiator's shared secret once the peer's share arrives.

### `tlsGroupResponder(g: TlsGroup, peerKeyShare: []byte): GroupResponse!`

A responder's key share and shared secret in one call.

### `tlsGroupCodepoint(g: TlsGroup): u64`

Convert to and from the IANA wire code point.

### `tlsGroupFromCodepoint(cp: u64): TlsGroup!`

Convert to and from the IANA wire code point.

## Key schedule

### `TranscriptHash`

A running hash over every handshake message seen so far.

### `TranscriptHash(alg: HashAlg)`

A running hash over every handshake message seen so far, built from the suite's
hash (`HashAlg`); its digest before any `update` is the hash of the empty
string.

### `TranscriptHash.update(data: []byte)`

Absorb a message; read the transcript hash so far.

### `TranscriptHash.sum(): []byte`

Absorb a message; read the transcript hash so far.

### `hkdfExpandLabel(alg: HashAlg, secret: []byte, label: string, context: []byte, len: int): []byte`

The two HKDF-Expand-Label building blocks every secret below is derived with.

### `deriveSecret(alg: HashAlg, secret: []byte, label: string, transcriptHash: []byte): []byte`

The two HKDF-Expand-Label building blocks every secret below is derived with.

### `earlySecret(alg: HashAlg, psk: []byte): []byte`

The three key-schedule stages, in order.

### `handshakeSecret(alg: HashAlg, early: []byte, ecdhe: []byte): []byte`

The three key-schedule stages, in order.

### `masterSecret(alg: HashAlg, handshake: []byte): []byte`

The three key-schedule stages, in order.

### `clientHandshakeTrafficSecret(alg: HashAlg, handshake: []byte, transcriptHash: []byte): []byte`

The traffic and exporter secrets derived from the handshake and master secrets.

### `serverHandshakeTrafficSecret(alg: HashAlg, handshake: []byte, transcriptHash: []byte): []byte`

The traffic and exporter secrets derived from the handshake and master secrets.

### `clientApplicationTrafficSecret(alg: HashAlg, master: []byte, transcriptHash: []byte): []byte`

The traffic and exporter secrets derived from the handshake and master secrets.

### `serverApplicationTrafficSecret(alg: HashAlg, master: []byte, transcriptHash: []byte): []byte`

The traffic and exporter secrets derived from the handshake and master secrets.

### `exporterMasterSecret(alg: HashAlg, master: []byte, transcriptHash: []byte): []byte`

The traffic and exporter secrets derived from the handshake and master secrets.

### `resumptionMasterSecret(alg: HashAlg, master: []byte, transcriptHash: []byte): []byte`

The traffic and exporter secrets derived from the handshake and master secrets.

### `trafficKey(alg: HashAlg, secret: []byte, keyLen: int): []byte`

The AEAD key and IV derived from a traffic secret.

### `trafficIV(alg: HashAlg, secret: []byte, ivLen: int): []byte`

The AEAD key and IV derived from a traffic secret.

### `finishedKey(alg: HashAlg, baseKey: []byte): []byte`

The Finished message MAC.

### `finishedMac(alg: HashAlg, baseKey: []byte, transcriptHash: []byte): []byte`

The Finished message MAC.

### `binderKey(alg: HashAlg, early: []byte): []byte`

The 0-RTT / PSK resumption secrets.

### `clientEarlyTrafficSecret(alg: HashAlg, early: []byte, clientHello1Hash: []byte): []byte`

The 0-RTT / PSK resumption secrets.

### `earlyExporterMasterSecret(alg: HashAlg, early: []byte, clientHello1Hash: []byte): []byte`

The 0-RTT / PSK resumption secrets.

### `resumptionPsk(alg: HashAlg, resumptionMasterSecret: []byte, ticketNonce: []byte): []byte`

The 0-RTT / PSK resumption secrets.

## Handshake messages

### `handshakeType(msg: []byte): int!`

The handshake message type byte of an encoded message.

### `ClientHello`

The ClientHello message and its codec.

### `encodeClientHello(ch: ClientHello): []byte`

The ClientHello message and its codec.

### `parseClientHello(msg: []byte): ClientHello!`

The ClientHello message and its codec.

### `ServerHello`

The ServerHello message, its codec, and whether it is a HelloRetryRequest.

### `encodeServerHello(sh: ServerHello): []byte`

The ServerHello message, its codec, and whether it is a HelloRetryRequest.

### `parseServerHello(msg: []byte): ServerHello!`

The ServerHello message, its codec, and whether it is a HelloRetryRequest.

### `isHelloRetryRequest(sh: ServerHello): bool`

The ServerHello message, its codec, and whether it is a HelloRetryRequest.

### `EncryptedExtensions`

The EncryptedExtensions message and its codec.

### `encodeEncryptedExtensions(ee: EncryptedExtensions): []byte`

The EncryptedExtensions message and its codec.

### `parseEncryptedExtensions(msg: []byte): EncryptedExtensions!`

The EncryptedExtensions message and its codec.

### `CertificateEntry`

The Certificate message (a chain of DER entries) and its codec.

### `Certificate`

The Certificate message (a chain of DER entries) and its codec.

### `encodeCertificate(c: Certificate): []byte`

The Certificate message (a chain of DER entries) and its codec.

### `parseCertificate(msg: []byte): Certificate!`

The Certificate message (a chain of DER entries) and its codec.

### `CertificateRequest`

The (unused by this module's client) CertificateRequest message and its codec.

### `encodeCertificateRequest(cr: CertificateRequest): []byte`

The (unused by this module's client) CertificateRequest message and its codec.

### `parseCertificateRequest(msg: []byte): CertificateRequest!`

The (unused by this module's client) CertificateRequest message and its codec.

### `CertificateVerify`

The CertificateVerify message and its codec.

### `encodeCertificateVerify(cv: CertificateVerify): []byte`

The CertificateVerify message and its codec.

### `parseCertificateVerify(msg: []byte): CertificateVerify!`

The CertificateVerify message and its codec.

### `Finished`

The Finished message and its codec.

### `encodeFinished(f: Finished): []byte`

The Finished message and its codec.

### `parseFinished(msg: []byte): Finished!`

The Finished message and its codec.

### `NewSessionTicket`

The session-resumption ticket message and its codec.

### `encodeNewSessionTicket(t: NewSessionTicket): []byte`

The session-resumption ticket message and its codec.

### `parseNewSessionTicket(msg: []byte): NewSessionTicket!`

The session-resumption ticket message and its codec.

### `Extension`

A generic extension, and one entry of a key_share extension.

### `KeyShareEntry`

A generic extension, and one entry of a key_share extension.

### `extServerName(host: string): Extension`

The SNI extension.

### `parseServerName(e: Extension): string!`

The SNI extension.

### `extALPN(protocols: []string): Extension`

The ALPN extension.

### `parseALPN(e: Extension): []string!`

The ALPN extension.

### `extSupportedGroups(groups: []int): Extension`

The supported_groups extension.

### `parseSupportedGroups(e: Extension): []int!`

The supported_groups extension.

### `extSignatureAlgorithms(schemes: []int): Extension`

The signature_algorithms extension.

### `parseSignatureAlgorithms(e: Extension): []int!`

The signature_algorithms extension.

### `extSupportedVersionsClient(versions: []int): Extension`

The supported_versions extension, client and server shapes.

### `parseSupportedVersionsClient(e: Extension): []int!`

The supported_versions extension, client and server shapes.

### `extSupportedVersionsServer(version: int): Extension`

The supported_versions extension, client and server shapes.

### `parseSupportedVersionsServer(e: Extension): int!`

The supported_versions extension, client and server shapes.

### `extKeyShareClient(entries: []KeyShareEntry): Extension`

The key_share extension, client and server shapes.

### `parseKeyShareClient(e: Extension): []KeyShareEntry!`

The key_share extension, client and server shapes.

### `extKeyShareServer(entry: KeyShareEntry): Extension`

The key_share extension, client and server shapes.

### `parseKeyShareServer(e: Extension): KeyShareEntry!`

The key_share extension, client and server shapes.

## Record layer

### `recordAlert: int`

The three TLS record content-type codes.

### `recordHandshake: int`

The three TLS record content-type codes.

### `recordApplicationData: int`

The three TLS record content-type codes.

### `RecordKeys`

The AEAD, key, and IV for one direction of record protection.

### `RecordKeys(suite: CipherSuite, secret: []byte)!`

The AEAD, key, and IV for one direction of record protection, derived from the
direction's traffic secret. Fails only if the suite rejects the derived key
length.

### `RecordKeys.seal(plaintext: []byte, contentType: int): []byte!`

Protect and recover one record, advancing the sequence number.

### `RecordKeys.open(record: []byte): RecordPlaintext!`

Protect and recover one record, advancing the sequence number.

### `RecordKeys.keyUpdate(): ()!`

Advance to the next traffic key (RFC 8446's key update).

### `RecordKeys.sequence(): int`

The current sequence number and the AEAD nonce it produces.

### `RecordKeys.nonce(): []byte`

The current sequence number and the AEAD nonce it produces.

### `RecordPlaintext`

One decrypted record: `content` and its `contentType`.

## Session resumption

### `PskIdentity`

One pre_shared_key entry offered by a resuming client.

### `TlsTicketStore`

A server-side store of issued tickets, keyed by ticket bytes.

### `TlsTicketStore()`

An empty server-side store of issued tickets, keyed by ticket bytes.

### `SessionTicket`

A client-side ticket saved after a connection closes.

### `SessionTicket(nst: NewSessionTicket, conn: TlsClientConn)`

A client-side ticket saved after a connection closes, built from the
NewSessionTicket message and the connection it arrived on.

### `tlsClientStartResume(config: TlsClientConfig, session: SessionTicket, earlyData: []byte): TlsClientHandshake!`

Start a client handshake offering a saved `SessionTicket`.

## Low-level handshake drivers

### `TlsClientHandshake`

The client-side state machine and its starting points.

### `tlsClientStart(config: TlsClientConfig): TlsClientHandshake!`

The client-side state machine and its starting points.

### `tlsClientStartExts(config: TlsClientConfig, extraExts: []Extension): TlsClientHandshake!`

The client-side state machine and its starting points.

### `TlsClientHandshake.clientHelloMessage(): []byte`

The encoded ClientHello to send first.

### `TlsClientHandshake.processServerFlight(flight: []byte): TlsClientStep!`

Feed the server's response flight; returns a retry step or the completed connection.

### `TlsClientHandshake.processServerHelloMessage(shMsg: []byte): []byte!`

Lower-level steps `processServerFlight` composes, for driving the handshake message by message.

### `TlsClientHandshake.clientReadHandshake(stream: []byte): []byte!`

Lower-level steps `processServerFlight` composes, for driving the handshake message by message.

### `TlsClientHandshake.peerEncryptedExtensions(): []Extension`

Lower-level steps `processServerFlight` composes, for driving the handshake message by message.

### `TlsClientHandshake.clientHandshakeSecret(): []byte`

The handshake's derived secrets, once it has completed.

### `TlsClientHandshake.serverHandshakeSecret(): []byte`

The handshake's derived secrets, once it has completed.

### `TlsClientHandshake.clientApplicationSecret(): []byte`

The handshake's derived secrets, once it has completed.

### `TlsClientHandshake.serverApplicationSecret(): []byte`

The handshake's derived secrets, once it has completed.

### `TlsClientHandshake.exporterSecret(): []byte`

The handshake's derived secrets, once it has completed.

### `TlsClientHandshake.pskWasAccepted(): bool`

The handshake's derived secrets, once it has completed.

### `TlsClientConfig`

The lower-level client configuration. Its trust store is `std/crypto`'s
`TrustStore`; build one from PEM with `fromPem(pem)`.

### `TlsClientStep`

One step of the client handshake, and the completed connection state.

### `TlsClientConn`

One step of the client handshake, and the completed connection state.

### `TlsClientConn.sealApp(plaintext: []byte): []byte!`

Protect and recover one application-data record.

### `TlsClientConn.openApp(record: []byte): RecordPlaintext!`

Protect and recover one application-data record.

### `TlsClientConn.resumptionSecret(): []byte`

The connection's resumption and exporter secrets, for issuing a `SessionTicket` or deriving external key material.

### `TlsClientConn.exporterSecret(): []byte`

The connection's resumption and exporter secrets, for issuing a `SessionTicket` or deriving external key material.

### `TlsServerHandshake`

The server-side state machine and its starting points.

### `tlsServerStart(config: TlsServerConfig): TlsServerHandshake!`

The server-side state machine and its starting points.

### `tlsServerStartExts(config: TlsServerConfig, extraExts: []Extension): TlsServerHandshake!`

The server-side state machine and its starting points.

### `TlsServerHandshake.processClientHello(flight: []byte): TlsServerStep!`

Feed the ClientHello flight; returns a HelloRetryRequest step or the ServerHello-plus-auth flight to send.

### `TlsServerHandshake.processClientFinished(flight: []byte): TlsServerConn!`

Feed the client's Finished flight, completing the handshake.

### `TlsServerHandshake.processClientHelloMessage(chMsg: []byte): TlsServerQuicFlight!`

Lower-level, message-at-a-time equivalents of the two calls above, used for QUIC.

### `TlsServerHandshake.processClientFinishedMessage(finMsg: []byte): TlsServerConn!`

Lower-level, message-at-a-time equivalents of the two calls above, used for QUIC.

### `TlsServerHandshake.pskWasAccepted(): bool`

Whether resumption or 0-RTT early data was accepted, and the early data itself.

### `TlsServerHandshake.earlyDataWasAccepted(): bool`

Whether resumption or 0-RTT early data was accepted, and the early data itself.

### `TlsServerHandshake.earlyDataReceived(): []byte`

Whether resumption or 0-RTT early data was accepted, and the early data itself.

### `TlsServerHandshake.clientHandshakeSecret(): []byte`

The handshake's derived secrets, once it has completed.

### `TlsServerHandshake.serverHandshakeSecret(): []byte`

The handshake's derived secrets, once it has completed.

### `TlsServerHandshake.clientApplicationSecret(): []byte`

The handshake's derived secrets, once it has completed.

### `TlsServerHandshake.serverApplicationSecret(): []byte`

The handshake's derived secrets, once it has completed.

### `TlsServerHandshake.exporterSecret(): []byte`

The handshake's derived secrets, once it has completed.

### `TlsServerConfig`

The server configuration `listen` takes, and the one `tlsServerStart` drives the handshake from.

### `TlsServerConfig(certChainPem: string, keyPem: string, alpn: []string)!`

Loads the certificate chain and RSA private key from PEM. Fails on malformed
PEM, an empty chain, or a key it cannot read; groups and suites default to the
full supported sets.

### `TlsServerStep`

One step of the server handshake, and the completed connection state.

### `TlsServerConn`

One step of the server handshake, and the completed connection state.

### `TlsServerConn.sealApp(plaintext: []byte): []byte!`

Protect and recover one application-data record.

### `TlsServerConn.openApp(record: []byte): RecordPlaintext!`

Protect and recover one application-data record.

### `TlsServerConn.issueTicket(): []byte!`

Issue a new session ticket for resumption on a later connection.

### `TlsServerConn.resumptionSecret(): []byte`

The connection's resumption and exporter secrets.

### `TlsServerConn.exporterSecret(): []byte`

The connection's resumption and exporter secrets.

### `TlsServerQuicFlight`

A server handshake flight shaped for delivery over QUIC rather than TLS records.

### `TlsClientHandshake.connection(): TlsClientConn!`

The completed connection, once `processServerFlight` reports the handshake is done.

### `TlsClientHandshake.cipherSuiteId(): int`

The negotiated cipher-suite code point, once the handshake has reached that point.

### `TlsClientConn.cipherSuiteId(): int`

The negotiated cipher-suite code point.

### `TlsClientConn.alpnProtocol(): string`

The ALPN protocol the two sides agreed on.

### `TlsClientConn.peerCertificates(): [][]byte`

The peer's certificate chain as raw DER, end-entity certificate first.

### `TlsServerHandshake.cipherSuiteId(): int`

The negotiated cipher-suite code point, once the handshake has reached that point.

### `TlsServerConn.cipherSuiteId(): int`

The negotiated cipher-suite code point.

### `TlsServerConn.alpnProtocol(): string`

The ALPN protocol the two sides agreed on.

## Constants

### `versionTls12: int`

The TLS 1.2 and 1.3 wire version code points (1.2 is recognized only to reject it).

### `versionTls13: int`

The TLS 1.2 and 1.3 wire version code points (1.2 is recognized only to reject it).

### `hsClientHello: int`

The handshake message type bytes.

### `hsServerHello: int`

The handshake message type bytes.

### `hsNewSessionTicket: int`

The handshake message type bytes.

### `hsEncryptedExtensions: int`

The handshake message type bytes.

### `hsCertificate: int`

The handshake message type bytes.

### `hsCertificateRequest: int`

The handshake message type bytes.

### `hsCertificateVerify: int`

The handshake message type bytes.

### `hsFinished: int`

The handshake message type bytes.

### `extTypeServerName: int`

The extension type codes the `ext*`/`parse*` functions above encode and read.

### `extTypeSupportedGroups: int`

The extension type codes the `ext*`/`parse*` functions above encode and read.

### `extTypeSignatureAlgorithms: int`

The extension type codes the `ext*`/`parse*` functions above encode and read.

### `extTypeALPN: int`

The extension type codes the `ext*`/`parse*` functions above encode and read.

### `extTypeSupportedVersions: int`

The extension type codes the `ext*`/`parse*` functions above encode and read.

### `extTypeKeyShare: int`

The extension type codes the `ext*`/`parse*` functions above encode and read.

### `sigEcdsaSecp256r1Sha256: int`

The signature_algorithms code points this module offers and accepts.

### `sigEcdsaSecp384r1Sha384: int`

The signature_algorithms code points this module offers and accepts.

### `sigRsaPssRsaeSha256: int`

The signature_algorithms code points this module offers and accepts.

### `sigRsaPssRsaeSha384: int`

The signature_algorithms code points this module offers and accepts.

### `sigRsaPssRsaeSha512: int`

The signature_algorithms code points this module offers and accepts.

### `sigEd25519: int`

The signature_algorithms code points this module offers and accepts.

### `groupSecp256r1: int`

The supported_groups wire code points for the classical curves.

### `groupSecp384r1: int`

The supported_groups wire code points for the classical curves.

### `groupX25519: int`

The supported_groups wire code points for the classical curves.

### `groupX448: int`

The supported_groups wire code points for the classical curves.

## Specification

RFC 8446 (TLS 1.3) and RFC 7468 (PEM) are the standards this module
implements.
