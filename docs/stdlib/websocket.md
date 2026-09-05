# std/websocket

The RFC 6455 WebSocket handshake, frame codec, and close protocol, over a
plain-TCP `std/net` connection.

A WebSocket connection begins life as an ordinary `std/http` request: accept it
and read it the normal way, then hand the exchange and the parsed request to
`upgrade` once it looks like a WebSocket handshake (`Upgrade: websocket`) — this
module never parses a request line itself. `upgrade` takes ownership of the
exchange's connection (`Exchange.hijack`, `std/http`) and returns a `Conn` for
framing from then on; `Exchange.respond` must not be called on the same
exchange afterward. The client side is symmetric: `dial` opens a plain TCP
connection and performs the client handshake itself, given a bare
host/port/path the same way `std/net`'s own `dial` takes a bare host/port — no
URL parsing here.

Origin policy is the caller's decision, not this module's (RFC 6455 §4.2.1
makes checking it optional and application-specific): call `upgrade` only
after checking `header(req.headers, "Origin")` (`std/http`) yourself. A caller
that does not care can call `upgrade` unconditionally.

Every frame read is bounded before its payload is read, never after
(`Limits.maxFrameBytes`), and every reassembled message is bounded the same
way across fragments (`Limits.maxMessageBytes`, `Limits.maxFragments`) — the
length in a frame header is attacker controlled and, unmasked, unbounded up to
2^63.

Per-message compression (permessage-deflate, RFC 7692) is out of scope. TLS
(`wss://`) is not supported in this version — the same intentional limit
`std/net` documents for itself.

Outgoing messages are never fragmented by this module — every
`sendText`/`sendBinary` call is a single, unfragmented frame, which is a fully
RFC-conformant choice (fragmentation is a sender's option, never a receiver's
requirement). Incoming fragmented messages ARE reassembled by `receive`, since
a peer's fragmentation choice is not this module's to make.

<!-- doctest: per-block -->

## Handshake

### `upgrade(ex: Exchange, req: Request, limits: Limits): Conn!`

Completes the server-side handshake on `ex`/`req` — a request `Exchange.read()`
already returned, checked to look like a WebSocket upgrade — and returns a
`Conn` ready for `sendText`/`sendBinary`/`receive`. Takes ownership of `ex`'s
connection (`Exchange.hijack`, `std/http`): do not call `ex.respond` afterward,
on success or failure alike; a failure here means the caller still owns `ex`
and should answer it (e.g. `ex.respond(respond(400, ""))`).

Fails when the request is not a valid upgrade: wrong method, a missing or
wrong `Connection`/`Upgrade` header, an unsupported `Sec-WebSocket-Version`, or
a `Sec-WebSocket-Key` that does not decode to 16 bytes.

```bit
import { Exchange, Request } from "std/http"
import { upgrade, defaultLimits, Conn } from "std/websocket"

fn accept(ex: Exchange, req: Request): Conn! {
  return upgrade(ex, req, defaultLimits())?
}
```

### `dial(host: string, port: int, path: string, limits: Limits): Conn!`

Opens a plain-TCP client connection to `host:port`, performs the client
handshake for `path`, and returns a `Conn` ready for
`sendText`/`sendBinary`/`receive`. Takes a bare host/port the same way
`std/net`'s own `dial` does — no URL parsing here; a caller with a `ws://` URL
splits it first.

Fails when the TCP connection cannot be opened, the handshake response is not
`101 Switching Protocols`, or `Sec-WebSocket-Accept` does not match what
`acceptKey` derives from the key this client sent — the one check that proves
the peer ran the real handshake rather than echoing headers back.

```bit
import { dial, defaultLimits, Conn } from "std/websocket"

fn connect(host: string, port: int): Conn! {
  return dial(host, port, "/chat", defaultLimits())?
}
```

### `acceptKey(clientKey: string): string`

The value that must appear as `Sec-WebSocket-Accept`, derived from the
client's `Sec-WebSocket-Key` (RFC 6455 §1.3, §4.2.2 item 5.4): SHA-1 of the
key concatenated with the fixed GUID `258EAFA5-E914-47DA-95CA-C5AB0DC85B11`,
base64-encoded. `upgrade` and `dial` both call this internally; a caller
verifying a handshake by hand is the only reason to call it directly.

---

## Limits

The bounds every `upgrade`/`dial` caller must set. None is disableable by
passing zero — a zero limit rejects every frame or message that would
otherwise use it, the same policy `std/http`'s multipart `Limits` uses, and
for the same reason: the peer's declared lengths are never trusted before they
are checked against these.

### `Limits`

Four fields: `maxFrameBytes` (a single frame's payload, checked against the
frame header's declared length before that many bytes are read off the wire),
`maxMessageBytes` (a complete message's payload, summed across every
fragment as they arrive), `maxFragments` (how many fragments one message may
be split into), and `closeTimeoutNs` (how long `Conn.close()` waits for the
peer's own close frame, in nanoseconds, before closing the socket regardless).

### `defaultLimits(): Limits`

Reasonable defaults: a 1 MiB single frame, a 4 MiB reassembled message, at
most 1024 fragments per message, a 5-second close wait.

```bit
import { defaultLimits } from "std/websocket"

fn limits(): int {
  return defaultLimits().maxFrameBytes
}
```

---

## Messages

### `Message`

A complete, reassembled application message: `kind` (one of `MessageText`,
`MessageBinary` or `MessageClose`), `code` (meaningful only for
`MessageClose` — the status code the peer's close frame carried, or
`closeNoStatus` if it carried none), and `data` (the message body for
text/binary, or the close reason, already validated as UTF-8, for close).

### `MessageText: int`

Tags a `Message` whose `data` is a complete text message.

### `MessageBinary: int`

Tags a `Message` whose `data` is a complete binary message.

### `MessageClose: int`

Tags a `Message` returned for a peer's close frame. `code` and `data` carry
the close status and reason.

---

## Connection

`upgrade` (server) and `dial` (client) both return a `Conn`.

### `Conn`

The live connection. `sendText`/`sendBinary`/`ping` write one frame each;
`receive` reads the next complete message, reassembling fragments and
answering ping/close frames transparently (§5.5.2, §5.5.3) — a caller never
sees a ping or an in-progress fragment, only a finished `Message`.

### `Conn.sendText(text: string): ()!`

Sends `text` as one complete, unfragmented text frame. Fails rather than
sending invalid UTF-8 — the same rule this module enforces on the way in
(§8.1 applies symmetrically to both directions).

### `Conn.sendBinary(data: []byte): ()!`

Sends `data` as one complete, unfragmented binary frame.

### `Conn.ping(payload: string): ()!`

Sends a ping carrying `payload`, answered by the peer with a pong carrying
the same bytes (§5.5.2). Fails if `payload` exceeds the 125-byte
control-frame limit.

### `Conn.receive(): Message!`

Reads the next complete message. Pings are answered with a matching pong and
never returned; a peer close frame is answered with this side's own close
frame and returned as `MessageClose`, exactly the same shape a self-initiated
`close()` reaches from the other direction — the close protocol is a
handshake, not a disconnect, and either side may start it. Fails, and marks
the connection closed, on a malformed frame or a read past the connection's
end.

### `Conn.close(code: int, reason: string): ()!`

Sends a close frame carrying `code`/`reason`, then waits up to
`limits.closeTimeoutNs` for the peer's own close frame before closing the
socket — a close the peer never answers still ends the connection, just once
the wait elapses rather than the instant the reply arrives. A second call is a
no-op: the close frame was already sent. Fails if `reason` exceeds 123 bytes
or is not valid UTF-8.

```bit
import { Conn, closeNormal } from "std/websocket"

fn echo(c: Conn): ()! {
  let msg = c.receive()?
  c.sendText(msg.data)?
  c.close(closeNormal, "bye")?
}
```

---

## Close codes

RFC 6455 §7.4.1 status codes this module can send or report. Only the ones
this implementation actually uses; the registry has more.

### `closeNormal: int`

Normal closure — the purpose for which the connection was established has
been fulfilled.

### `closeGoingAway: int`

An endpoint is going away, such as a server shutting down or a browser
navigating away from the page.

### `closeProtocolError: int`

The peer is terminating the connection due to a protocol error.

### `closeUnsupportedData: int`

The endpoint received a data type it cannot accept.

### `closeNoStatus: int`

Reserved: never sent on the wire. `receive` reports it in `Message.code`
when the peer's close frame carried no status code at all (an empty payload
is legal — RFC 6455 §7.1.5).

### `closeInvalidPayload: int`

The endpoint received data inconsistent with the type of message (e.g.
non-UTF-8 data within a text message).

### `closePolicyViolation: int`

The endpoint received a message that violates its policy.

### `closeMessageTooBig: int`

The endpoint received a message too big to process — a single frame over
`maxFrameBytes`, a reassembled message over `maxMessageBytes`, or a message
split into more than `maxFragments` fragments.

### `closeInternalError: int`

The server is terminating the connection because it encountered an
unexpected condition.
