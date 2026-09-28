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
import { dial, newTlsConfig } from "std/tls"
import { systemRoots, bundled } from "std/crypto"

fn fetchHomepage(host: string): string! {
  let roots = systemRoots() catch _ {
    bundled()
  }
  let cfg = newTlsConfig(roots)
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

`listen` takes a certificate and matching private key in PEM and runs the
server side of the handshake for every connection it accepts.

```bit
import { listen, newTlsConfig, emptyTrustStore } from "std/tls"

fn serveOnce(port: int, certPem: string, keyPem: string): ()! {
  let cfg = newTlsConfig(emptyTrustStore())
  cfg.certPem = certPem
  cfg.keyPem = keyPem
  let ln = listen("127.0.0.1", port, cfg)?
  let conn = ln.accept()?
  conn.write([]byte("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"))?
  conn.close()
  ln.close()
  return
}
```

A server does not verify a client's identity, so its `TlsConfig` needs no
trust store; `emptyTrustStore()` fills the field. Set `cfg.alpn` to the
protocol names you support (`["h2", "http/1.1"]`, say) and read what the
client picked back with `conn.alpnProtocol()`.

## Trust stores and certificates

A trust store is the set of certificate authorities you are willing to
believe. `std/crypto` builds one three ways: `systemRoots()` (the OS bundle),
`bundled()` (a built-in fallback), or `fromPem(pem)` (your own pinned roots,
for a private PKI or a test fixture). Pass whichever one fits into
`newTlsConfig`.

Once connected, inspect who you are actually talking to with
`peerCertificates()`, which returns the chain as raw DER, end-entity
certificate first:

```bit
import { dial, newTlsConfig } from "std/tls"
import { systemRoots, x509Parse } from "std/crypto"

fn peerSubject(host: string, port: int): string! {
  let cfg = newTlsConfig(systemRoots()?)
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

## Security notes

**Never set `insecureSkipVerify: true` outside a test.** It turns off both
chain and hostname verification, so the connection is still encrypted but no
longer proves who you are talking to; it exists for pinned replay and local
testing, never for a shipped client.

**Only TLS 1.3 is implemented.** `TlsConfig.minVersion` is a floor, not a
ceiling: leave it at its default and a connection is always TLS 1.3, the
version with no known downgrade or renegotiation attacks that plagued 1.2 and
earlier.

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
- **`listen` fails immediately if `certPem` or `keyPem` is empty**, rather
  than failing later on the first connection.
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

## Reference

Every exported name in `std/tls`, grouped by area. `dial`, `listen`,
`client`, `TlsConfig`, `TlsConn`, and `TlsListener` are the path almost every
program needs; the rest is the TLS 1.3 engine underneath them, exported for
building custom tooling (a test harness, a protocol embedding TLS
differently, like QUIC) directly against the handshake.

### Connecting and serving

| Symbol | What it is |
| --- | --- |
| `TlsConfig` | `roots`, `insecureSkipVerify`, `alpn`, `serverName`, `minVersion`, `nowUnix`, `certPem`, `keyPem`: shared by `dial` and `listen`. |
| `newTlsConfig(roots: TrustStore): TlsConfig` | A secure-by-default client config: verification on, TLS 1.3. |
| `emptyTrustStore(): TrustStore` | A trust store with no roots, for a server config (which never verifies a peer). |
| `dial(host: string, port: int, config: TlsConfig): TlsConn!` | Open a TCP connection to `host:port` and run the client handshake. |
| `dialDeadline(host: string, port: int, config: TlsConfig, deadlineNs: int): TlsConn!` | `dial` with a deadline on the whole connect-plus-handshake. |
| `client(conn: NetConn, host: string, config: TlsConfig): TlsConn!` | Run the client handshake over an already-open `std/net` connection. |
| `TlsConn` | An established connection. |
| `TlsConn.read(n: int): []byte!`, `TlsConn.write(b: []byte): ()!` | Read up to `n` plaintext bytes; write plaintext that leaves encrypted. |
| `TlsConn.close()`, `TlsConn.shutdown()` | Close the connection; `shutdown` also sends a TLS close-notify alert. |
| `TlsConn.handshake(): ()!` | Run the handshake now if it has not run yet (a no-op after `dial`, needed after `accept`). |
| `TlsConn.alpnProtocol(): string`, `TlsConn.cipherSuiteId(): int` | The negotiated ALPN protocol and cipher-suite code point. |
| `TlsConn.peerCertificates(): [][]byte` | The peer's certificate chain as raw DER, end-entity first. |
| `TlsConn.peerIp(): string!` | The peer's IPv4 address, forwarded from the underlying socket. |
| `TlsConn.setDeadline(deadlineNs: int)`, `TlsConn.deadlineNs(): int`, `TlsConn.readTimedOut(): bool` | Per-connection read/write deadline. |
| `TlsListener`, `listen(host: string, port: int, config: TlsConfig): TlsListener!` | A listening socket; `config.certPem`/`keyPem` are required. |
| `TlsListener.accept(): TlsConn!` | Accept the next TCP connection. The handshake runs lazily; see [Sharp edges](#sharp-edges). |
| `TlsListener.port(): int!`, `TlsListener.isClosed(): bool`, `TlsListener.close()` | Inspect and close the listener. |
| `tlsVersion13: int` | The TLS 1.3 wire version code point, the only version this module speaks. |

### Cipher suites

| Symbol | What it is |
| --- | --- |
| `CipherSuite` | A suite descriptor: id, name, key/IV/tag/hash lengths. |
| `TLS_AES_128_GCM_SHA256`, `TLS_AES_256_GCM_SHA384`, `TLS_CHACHA20_POLY1305_SHA256` | The three mandatory TLS 1.3 suite code points. |
| `tlsSuiteById(id: int): CipherSuite!` | Look up a suite by its wire code point. |
| `tlsSuitePreference(): []CipherSuite` | The suites this module offers, strongest first. |
| `tlsSuiteNewAead(suite: CipherSuite, key: []byte): Aead!`, `tlsSuiteNewHash(suite: CipherSuite): Hash` | Build the live cipher or hash for a suite. |

### Key exchange groups

| Symbol | What it is |
| --- | --- |
| `TlsGroup` | `X25519`, `Secp256r1`, `Secp384r1`, `X25519MLKEM768` (the post-quantum hybrid, offered first by default). |
| `GroupKeypair`, `GroupResponse` | An initiator's key-exchange state and a responder's answer to it. |
| `tlsGroupGenerate(g: TlsGroup): GroupKeypair` | Generate an initiator's ephemeral key share for `g`. |
| `tlsGroupComputeShared(g: TlsGroup, priv: []byte, peerKeyShare: []byte): []byte!` | An initiator's shared secret once the peer's share arrives. |
| `tlsGroupResponder(g: TlsGroup, peerKeyShare: []byte): GroupResponse!` | A responder's key share and shared secret in one call. |
| `tlsGroupCodepoint(g: TlsGroup): u64`, `tlsGroupFromCodepoint(cp: u64): TlsGroup!` | Convert to and from the IANA wire code point. |

### Key schedule (RFC 8446, key schedule section)

The HKDF-based secret derivation the handshake runs internally, exported for
building a compatible implementation of your own. A normal client or server
never calls these.

| Symbol | What it is |
| --- | --- |
| `TranscriptHash`, `newTranscript(newHash: () => Hash): TranscriptHash` | A running hash over every handshake message seen so far. |
| `TranscriptHash.update(data: []byte)`, `TranscriptHash.sum(): []byte` | Absorb a message; read the transcript hash so far. |
| `hkdfExpandLabel`, `deriveSecret` | The two HKDF-Expand-Label building blocks every secret below is derived with. |
| `earlySecret`, `handshakeSecret`, `masterSecret` | The three key-schedule stages, in order. |
| `clientHandshakeTrafficSecret`, `serverHandshakeTrafficSecret`, `clientApplicationTrafficSecret`, `serverApplicationTrafficSecret`, `exporterMasterSecret`, `resumptionMasterSecret` | The traffic and exporter secrets derived from the handshake and master secrets. |
| `trafficKey`, `trafficIV` | The AEAD key and IV derived from a traffic secret. |
| `finishedKey`, `finishedMac` | The Finished message MAC. |
| `binderKey`, `clientEarlyTrafficSecret`, `earlyExporterMasterSecret`, `resumptionPsk` | The 0-RTT / PSK resumption secrets. |

### Handshake messages

The wire types and codecs for every TLS 1.3 handshake message, and the
extensions carried inside them. Exported for tooling that parses or
generates raw handshake traffic; `dial`/`listen` already speak this wire
format for you.

| Symbol | What it is |
| --- | --- |
| `handshakeType(msg: []byte): int!` | The handshake message type byte of an encoded message. |
| `ClientHello`, `encodeClientHello`, `parseClientHello` | The ClientHello message and its codec. |
| `ServerHello`, `encodeServerHello`, `parseServerHello`, `isHelloRetryRequest` | The ServerHello message, its codec, and whether it is a HelloRetryRequest. |
| `EncryptedExtensions`, `encodeEncryptedExtensions`, `parseEncryptedExtensions` | The EncryptedExtensions message and its codec. |
| `CertificateEntry`, `Certificate`, `encodeCertificate`, `parseCertificate` | The Certificate message (a chain of DER entries) and its codec. |
| `CertificateRequest`, `encodeCertificateRequest`, `parseCertificateRequest` | The (unused by this module's client) CertificateRequest message and its codec. |
| `CertificateVerify`, `encodeCertificateVerify`, `parseCertificateVerify` | The CertificateVerify message and its codec. |
| `Finished`, `encodeFinished`, `parseFinished` | The Finished message and its codec. |
| `NewSessionTicket`, `encodeNewSessionTicket`, `parseNewSessionTicket` | The session-resumption ticket message and its codec. |
| `Extension`, `KeyShareEntry` | A generic extension, and one entry of a key_share extension. |
| `extServerName`, `parseServerName` | The SNI extension. |
| `extALPN`, `parseALPN` | The ALPN extension. |
| `extSupportedGroups`, `parseSupportedGroups` | The supported_groups extension. |
| `extSignatureAlgorithms`, `parseSignatureAlgorithms` | The signature_algorithms extension. |
| `extSupportedVersionsClient`, `parseSupportedVersionsClient`, `extSupportedVersionsServer`, `parseSupportedVersionsServer` | The supported_versions extension, client and server shapes. |
| `extKeyShareClient`, `parseKeyShareClient`, `extKeyShareServer`, `parseKeyShareServer` | The key_share extension, client and server shapes. |

### Record layer

| Symbol | What it is |
| --- | --- |
| `recordAlert`, `recordHandshake`, `recordApplicationData` | The three TLS record content-type codes. |
| `RecordKeys`, `newRecordKeys(suite: CipherSuite, secret: []byte): RecordKeys!` | The AEAD, key, and IV for one direction of record protection. |
| `RecordKeys.seal(plaintext: []byte, contentType: int): []byte!`, `RecordKeys.open(record: []byte): RecordPlaintext!` | Protect and recover one record, advancing the sequence number. |
| `RecordKeys.keyUpdate(): ()!` | Advance to the next traffic key (RFC 8446's key update). |
| `RecordKeys.sequence(): int`, `RecordKeys.nonce(): []byte` | The current sequence number and the AEAD nonce it produces. |
| `RecordPlaintext` | One decrypted record: `content` and its `contentType`. |

### Session resumption (0-RTT, RFC 8446)

| Symbol | What it is |
| --- | --- |
| `PskIdentity` | One pre_shared_key entry offered by a resuming client. |
| `TlsTicketStore`, `newTicketStore(): TlsTicketStore` | A server-side store of issued tickets, keyed by ticket bytes. |
| `SessionTicket`, `newSessionTicket(nst: NewSessionTicket, conn: TlsClientConn): SessionTicket` | A client-side ticket saved after a connection closes. |
| `tlsClientStartResume(...)` | Start a client handshake offering a saved `SessionTicket`. |

### Low-level handshake drivers

The sans-I/O state machines `dial`/`listen`/`TlsConn` are built on: they
consume and produce handshake bytes without touching a socket. Reach for
these directly only when embedding the handshake in a transport this module
does not already drive (for example over QUIC).

| Symbol | What it is |
| --- | --- |
| `TlsClientHandshake`, `tlsClientStart(config: TlsClientConfig): TlsClientHandshake!`, `tlsClientStartExts` | The client-side state machine and its starting points. |
| `TlsClientHandshake.clientHelloMessage(): []byte` | The encoded ClientHello to send first. |
| `TlsClientHandshake.processServerFlight(flight: []byte): TlsClientStep!` | Feed the server's response flight; returns a retry step or the completed connection. |
| `TlsClientHandshake.processServerHelloMessage`, `.clientReadHandshake`, `.peerEncryptedExtensions()` | Lower-level steps `processServerFlight` composes, for driving the handshake message by message. |
| `TlsClientHandshake.clientHandshakeSecret()`, `.serverHandshakeSecret()`, `.clientApplicationSecret()`, `.serverApplicationSecret()`, `.exporterSecret()`, `.pskWasAccepted(): bool` | The handshake's derived secrets, once it has completed. |
| `TlsClientConfig`, `newTrustStore(rootsPem: string): TrustStore!` | The lower-level client configuration and a PEM-to-trust-store helper. |
| `TlsClientStep`, `TlsClientConn` | One step of the client handshake, and the completed connection state. |
| `TlsClientConn.sealApp(plaintext: []byte): []byte!`, `.openApp(record: []byte): RecordPlaintext!` | Protect and recover one application-data record. |
| `TlsClientConn.resumptionSecret()`, `.exporterSecret()` | The connection's resumption and exporter secrets, for issuing a `SessionTicket` or deriving external key material. |
| `TlsServerHandshake`, `tlsServerStart(config: TlsServerConfig): TlsServerHandshake!`, `tlsServerStartExts` | The server-side state machine and its starting points. |
| `TlsServerHandshake.processClientHello(flight: []byte): TlsServerStep!` | Feed the ClientHello flight; returns a HelloRetryRequest step or the ServerHello-plus-auth flight to send. |
| `TlsServerHandshake.processClientFinished(flight: []byte): TlsServerConn!` | Feed the client's Finished flight, completing the handshake. |
| `TlsServerHandshake.processClientHelloMessage`, `.processClientFinishedMessage` | Lower-level, message-at-a-time equivalents of the two calls above, used for QUIC. |
| `TlsServerHandshake.pskWasAccepted()`, `.earlyDataWasAccepted()`, `.earlyDataReceived(): []byte` | Whether resumption or 0-RTT early data was accepted, and the early data itself. |
| `TlsServerHandshake.clientHandshakeSecret()`, `.serverHandshakeSecret()`, `.clientApplicationSecret()`, `.serverApplicationSecret()`, `.exporterSecret()` | The handshake's derived secrets, once it has completed. |
| `TlsServerConfig`, `newTlsServerConfig(certChainPem: string, keyPem: string, alpn: []string): TlsServerConfig!` | The lower-level server configuration and its PEM-loading constructor. |
| `TlsServerStep`, `TlsServerConn` | One step of the server handshake, and the completed connection state. |
| `TlsServerConn.sealApp(plaintext: []byte): []byte!`, `.openApp(record: []byte): RecordPlaintext!` | Protect and recover one application-data record. |
| `TlsServerConn.issueTicket(): []byte!` | Issue a new session ticket for resumption on a later connection. |
| `TlsServerConn.resumptionSecret()`, `.exporterSecret()` | The connection's resumption and exporter secrets. |
| `TlsServerQuicFlight` | A server handshake flight shaped for delivery over QUIC rather than TLS records. |

### Constants

| Symbol | What it is |
| --- | --- |
| `versionTls12`, `versionTls13` | The TLS 1.2 and 1.3 wire version code points (1.2 is recognized only to reject it). |
| `hsClientHello`, `hsServerHello`, `hsNewSessionTicket`, `hsEncryptedExtensions`, `hsCertificate`, `hsCertificateRequest`, `hsCertificateVerify`, `hsFinished` | The handshake message type bytes. |
| `extTypeServerName`, `extTypeSupportedGroups`, `extTypeSignatureAlgorithms`, `extTypeALPN`, `extTypeSupportedVersions`, `extTypeKeyShare` | The extension type codes the `ext*`/`parse*` functions above encode and read. |
| `sigEcdsaSecp256r1Sha256`, `sigEcdsaSecp384r1Sha384`, `sigRsaPssRsaeSha256`, `sigRsaPssRsaeSha384`, `sigRsaPssRsaeSha512`, `sigEd25519` | The signature_algorithms code points this module offers and accepts. |
| `groupSecp256r1`, `groupSecp384r1`, `groupX25519`, `groupX448` | The supported_groups wire code points for the classical curves. |

## Specification

RFC 8446 (TLS 1.3) and RFC 7468 (PEM) are the standards this module
implements.
