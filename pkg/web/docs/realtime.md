# WebSockets, SSE and streaming

<!-- doctest: per-block -->

A `(Ctx) => Res!` handler answers with exactly one status, one
`Content-Type` and one body, then the connection closes. That is the right
shape for almost every route, and the wrong one for three things a real app
still needs: live comments over a WebSocket, a server-sent-events feed a
browser subscribes to, and a response whose body is too large to build as
one string before sending it. All three need the connection to stay open
past that first reply, on the app's own terms.

`c.hijack()` is how a route reaches it: it hands you the raw connection and
walks the framework off it for the rest of that connection's life. Nothing
downstream runs again - no middleware, no `Res`, nothing this package would
otherwise write for you. You take over the wire, so you write the response
line and headers yourself from here, or use `wsUpgrade`/`newSSE`/`newStream`
below, which do it for you in the one shape each protocol needs.

## One serving path

`App.listen()` and `App.serve()` already support it - nothing extra to
start. What a route needs is registering itself with `.hijackable()`, the
same chained call `.name()` already is:

```bit
import { App, Config } from "web"

fn main(): ()! {
  let app = App(Config{ secret = "change-me-in-production" })
  app.get("/ws/comments", (c) => {
    let conn = c.hijack()?
    // ... talk to conn directly, or wrap it with wsUpgrade/newSSE/newStream ...
    return c.noContent()
  }).hijackable()
  app.listen()?
}
```

`.hijackable()` costs an app that never calls it nothing: `App.listen()`/
`App.serve()` keep serving every OTHER route over `std/http`'s ordinary
keep-alive connections exactly as before. The moment ANY route on the app
is marked, though, the WHOLE app switches to answering one request per
connection - a WebSocket, an SSE feed or a stream all keep their connection
open for as long as the handler runs, so there is no way yet to keep
reusing a connection for a plain request while also being ready to hand a
later one on it over. A service mixing a high-throughput plain API with a
realtime feature at real scale should put them on separate `App`s (and
separate ports) for that reason, until that limitation closes (tracked
internally, not a promise on any timeline).

## WebSockets: live comments

A comment thread's "someone else posted" feed is the running example: a
client opens a socket on an article, and every message anyone sends on that
article is broadcast to everyone else watching it.

The simplest thing that works is an echo, so start there:

```bit
import { Ctx, Res, wsUpgrade } from "web"
import { defaultLimits } from "std/websocket"

fn echo(c: Ctx): Res! {
  let conn = wsUpgrade(c, defaultLimits())?
  while (true) {
    let msg = conn.receive()?
    conn.sendText(msg.data)?
  }
}
```

`wsUpgrade` does the RFC 6455 handshake and hands back a connection with
`sendText`/`sendBinary`/`receive`. `receive()` blocks until the next
complete message arrives - reassembling a fragmented one, answering a ping
with a pong - so the loop above only ever sees a finished `Message`. A peer
closing the socket makes `receive()` fail, which ends the loop and the
route's own `while (true)` the same way any other `?` failure would.

Broadcasting to every OTHER connection on the same article needs somewhere
to keep them. `wsUpgrade` gives you a connection, not a registry - the
registry is your app's, the same way a `SessionStore` is:

```bit
import { Ctx, Res, wsUpgrade } from "web"
import { Conn as WsConn, defaultLimits, MessageClose } from "std/websocket"
import { Mutex, newMutex } from "std/sync"

class Room {
  mu: Mutex,
  conns: []WsConn,
}

fn newRoom(): Room {
  return Room{ mu = newMutex(), conns = []WsConn(0) }
}

fn join(r: Room, c: WsConn) {
  r.mu.lock()
  r.conns = append(r.conns, c)
  r.mu.unlock()
}

fn broadcast(r: Room, text: string) {
  r.mu.lock()
  let conns = r.conns
  r.mu.unlock()
  for conn of conns {
    conn.sendText(text) catch _ {
      // a dead peer is that peer's problem, never the broadcaster's
    }
  }
}

fn articleComments(c: Ctx, room: Room): Res! {
  let conn = wsUpgrade(c, defaultLimits())?
  join(room, conn)
  while (true) {
    let msg = conn.receive()?
    if (msg.kind == MessageClose) {
      return c.noContent()
    }
    broadcast(room, msg.data)
  }
}
```

Register one `Room` per article id (a `map<string, Room>` behind its own
`Mutex`, or a row your database already has) and close over it the same way
a database handle is closed over today:
`app.get("/articles/:id/comments", (c) => articleComments(c,
roomFor(c.param("id")))).hijackable()` - the `.hijackable()` on the end is
what tells `App.listen()`/`App.serve()` this app needs the accept loop that
keeps a connection reachable for `wsUpgrade`; see "One serving path" above.

## Server-sent events: a live feed a browser subscribes to

SSE is one-directional - the server pushes, the browser's `EventSource`
never writes back - which makes it the simpler of the two for anything that
is a feed rather than a conversation: a build's log lines, a job's progress,
a dashboard's ticking numbers.

```bit
import { Ctx, Res, newSSE } from "web"

fn buildProgress(c: Ctx): Res! {
  let sse = newSSE(c)?
  sse.send("status", "started")?
  sse.sendData("42%")?
  sse.send("status", "done")?
  sse.close()?
  return c.noContent()
}
```

`newSSE` hijacks the connection and writes the response `text/event-stream`
needs: `Content-Type: text/event-stream`, `Cache-Control: no-cache` (a
reconnecting `EventSource` must never be served a cached stream) and
`Connection: keep-alive`. `send(event, data)` frames a named event a
browser's `addEventListener("status", ...)` matches; `sendData(data)` frames
an anonymous one `onmessage` reads. Both split a multi-line `data` into one
`data:` field per line, the framing WHATWG's spec asks for - you never
write `event:`/`data:` by hand.

A real feed does not know its last event in advance; it loops for as long
as it has something to report, and `close()` is what ends the client's
`EventSource` cleanly instead of leaving it to time out and reconnect.

## Streaming a response over 100 MB

A report, an export, a large file: building the whole body as one `string`
first means holding all of it in memory before the first byte reaches the
client, and it means the client waits for the whole thing before seeing
any of it. `newStream` sends it as HTTP/1.1 chunked - a sequence of pieces,
each written and flushed the moment you call `write`, with no total length
declared up front:

```bit
import { Ctx, Res, Header, newStream } from "web"

fn exportRows(c: Ctx, rows: []string): Res! {
  let stream = newStream(c, 200, "text/csv", []Header(0))?
  for row of rows {
    stream.write(row + "\n")?
  }
  stream.close()?
  return c.noContent()
}
```

`Stream` holds no buffer: `write` sends exactly the bytes you pass it, once,
and forgets them. A loop that reads its rows from a database cursor or a
file a chunk at a time, rather than loading `rows` into memory first, is
what actually keeps a multi-gigabyte export's memory flat - `newStream`
only guarantees it will not make an already-bounded loop unbounded.

## Sharp edges

**A hijacked connection has no `Res`.** `c.text(...)`, `c.json(...)`, every
`Ctx` response helper builds a `Res` the framework would frame as an
ordinary reply - but hijacking already took the connection over, so none of
that reaches the wire. Do everything the client should see through the
connection `hijack()`/`wsUpgrade`/`newSSE`/`newStream` gave you; the `c.
noContent()` a hijacking handler returns exists only to satisfy `Res!`'s
return type and is discarded.

**Calling `hijack()` twice on one request fails.** So does calling it on a
`Ctx` built by `app.handle()` (the in-process test seam) or on a route that
never called `.hijackable()` - both name what to do instead in the error
message.

**No middleware runs after a hijack**, including your own: CORS, CSRF,
compression, request logging, all of it wraps the ordinary response path.
A route that needs a check before it upgrades (an auth cookie, an
`Origin` allowlist) makes that check itself, before calling `wsUpgrade`.

**TLS, HTTP/2 and HTTP/3 do not support hijacking yet.** `App.listenTls()`/
`App.serveTls()` serve every ordinary route the same way `listen()` does,
but `c.hijack()`/`wsUpgrade`/`newSSE`/`newStream` all fail on a request that
arrived over any of them - the error names why. A WebSocket, an SSE feed or
a stream served today needs plain `App.listen()`/`App.serve()`, behind a
TLS-terminating proxy if the deployment needs TLS at all.

## When not to use this

An ordinary request/response - even a large JSON page, even one that takes
a while to build - almost never needs `hijack()`. Reach for it only when the
client and server genuinely need the connection to outlive one reply:
a live update, a subscription, or a body too large to hold in memory once.

Next: [Middleware](middleware.md), for composing behavior around a request.
