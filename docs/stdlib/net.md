# std/net

Non-blocking TCP over green threads. A connection that waits for bytes parks the
green thread reading it and leaves its OS thread free, so the idiomatic "one
green thread per connection" server costs one `Task` per connection, not one OS
thread. Every operation that can fail returns `T!` - propagate with `?` or handle
with `catch`.

Addresses are dotted-quad IPv4 literals (`"127.0.0.1"`), not hostnames: there is
no name resolution yet. There is also no TLS - put a terminating proxy in front
before exposing a public port.

<!-- doctest: per-block -->

## Listening

### `Listener`

A listening socket. The only thing you do with it is `accept`; it is not a
`Conn`.

### `listen(host: string, port: int): Listener!`

Binds a listening socket to `host:port`. Pass port `0` to let the kernel choose a
free port, then read it back with `port()` - the reliable way to bind in a test,
since choosing a number yourself races every other process on the machine.

### `Listener.port(): int!`

The port the listener is actually bound to. Meaningful even when `0` was
requested - that is how you learn the kernel's choice.

### `Listener.accept(): Conn!`

Waits for the next connection and returns it. Parks the calling green thread; the
OS thread goes and runs something else meanwhile.

### `Listener.close()`

Stops listening and releases the port.

```bit
import { listen, Listener, Conn } from "std/net"
import { toUpper } from "std/strings"

// Accept `n` connections, uppercase one request on each, and close.
fn serve(l: Listener, n: int): ()! {
  let i = 0
  while (i < n) {
    let c = l.accept()?
    let req = c.read(4096)
    c.write(toUpper(req))?
    c.close()
    i = i + 1
  }
  l.close()
}
```

## Connecting

### `Conn`

One end of an established connection. Read, write, close.

### `dial(host: string, port: int): Conn!`

Connects to `host:port`. A refused connection fails here, at `dial`, not later at
the first write - the failure is reported where it happened.

### `Conn.read(max: int): string`

Reads up to `max` bytes, parking until some arrive or, once `setDeadline` has
armed this connection, until the deadline elapses - bounded exactly like
`readDeadline`. An empty result means either the peer closed (an orderly end
of stream, the condition that ends a read loop) or the deadline elapsed
first; `read`'s return type has no room for a distinct error the way
`readDeadline`'s does, so the two collapse to the same `""`. Call
`readTimedOut()` right after to tell them apart when it matters.

### `Conn.readTimedOut(): bool`

Whether the `read()` call just before this one returned `""` because this
side's own deadline elapsed, rather than the peer closing cleanly. Every
`read()` call overwrites it, so it is meaningful only right after one -
meaningless before the first `read()` on this `Conn`.

### `Conn.write(s: string): ()!`

Writes all of `s`, parking until every byte is written or, once
`setDeadline` has armed this connection, until the deadline elapses -
bounded exactly like `writeDeadline`, and it fails with the same "write
timed out" message. A short write is retried internally, so on success this
wrote every byte.

### `Conn.readAll(): string`

Reads until the peer closes and returns everything. Only safe against a peer that
actually closes; a keep-alive protocol needs its own framing layer instead.

### `Conn.peerIp(): string!`

The peer's address as a dotted quad, `"127.0.0.1"`. IPv4 only, like every other
address in this module.

Fails rather than returning a placeholder when there is no peer to name: a `Conn`
you have already closed, one whose peer hung up hard, or a peer whose address
family is not IPv4. Code that logs or rate-limits by address needs to see that
difference, since a sentinel string would bucket every unknown peer together.

### `Conn.close()`

Closes this end of the connection.

```bit
import { dial } from "std/net"

// One request, one response, over a fresh connection.
fn roundTrip(port: int, msg: string): string! {
  let c = dial("127.0.0.1", port)?
  c.write(msg)?
  let reply = c.readAll()
  c.close()
  return reply
}
```

### `Conn.shutdown()`

Shuts both directions of the connection down without releasing the fd, so the
number cannot be reused by a later `dial`/`listen`/`accept` until `close`
follows. Idempotent.

Use this, not `close`, to unblock a green thread of yours already parked in a
`read` on this same `Conn` from another thread. Closing the fd does not wake a
parked read - nothing in this runtime lets one thread interrupt another's
blocked read, and closing tears the descriptor down without notifying the
read's wait registration. Shutting the socket down instead is a real state
transition on the still-open descriptor, which the kernel reports as newly
readable - the wakeup a bare `close` does not produce. Call this, then wait for
the parked reader to observe the resulting empty read/error and return, and
only then call `close`.

## Deadlines

A server that accepts and never answers parks `dial`/`read`/`write` forever -
these give a caller a bound instead. `deadlineNs` is an ABSOLUTE monotonic
nanosecond deadline (`std/time`'s `monotonic().ns` plus a budget), not a
duration - resolve it once and it covers connect, write and read together,
never restarting per call.

### `dialDeadline(host: string, port: int, deadlineNs: int): Conn!`

Like `dial`, but bounded by `deadlineNs` rather than parking forever. The
returned `Conn` remembers `deadlineNs`, so `readDeadline`/`writeDeadline` on
it reuse the same value automatically.

### `Conn.setDeadline(deadlineNs: int)`

Sets (or, with `0`, clears) the absolute deadline that bounds every read and
write on this connection from now on - `read`, `write`, `readDeadline`,
`readDeadlineInto` and `writeDeadline` alike, Go's `net.Conn.SetDeadline`
contract. Does not reach back to bound a `dial`/`dialDeadline` connect
already completed.

### `Conn.deadline(): int`

The absolute monotonic deadline this connection's reads and writes are bounded
by, or `0` for none. The `deadlineNs` state itself is private to `std/net`;
this is the way a layer built on top of a `Conn` (`std/tls`, `std/http`) reads
the deadline it must thread through its own waits, instead of inventing a
second one.

### `Conn.readDeadline(max: int): string!`

Like `read`, but bounded by the connection's deadline. An empty result is a
clean close, exactly like `read` - an orderly end of stream, never an error.
A timeout is a `fail` whose message names it, so the two are never
confusable: a value back (even `""`) was never on the timeout path.

### `Conn.readDeadlineInto(buf: []byte, max: int): int!`

`readDeadline` allocates a fresh buffer on every call. A server that reads
thousands of requests over one connection pays for that allocation on every
one of them. `readDeadlineInto` reads into a buffer the caller owns and keeps.
It returns how many bytes landed at `buf[0:n]`, with `0` for a clean close,
and fails exactly as `readDeadline` does on a timeout or a read error.

It reads at most `max` bytes, and never more than `len(buf)` whatever `max`
says. Take the bytes out before the next call, because that call overwrites
them:

```bit
import { Conn } from "std/net"

// One buffer for the whole connection, not one per read.
fn echoLines(c: Conn): ()! {
  let buf = []byte(4096)
  while (true) {
    let n = c.readDeadlineInto(buf, len(buf))?
    if (n == 0) {
      return
    }
    c.writeDeadline(string(buf[0:n]))?
  }
}
```

### `Conn.writeDeadline(s: string): ()!`

Like `write`, but bounded by the connection's deadline.

```bit
import { dialDeadline } from "std/net"
import { monotonic } from "std/time"

// One request, bounded to 500ms total for connect + write + read - a server
// that accepts and never answers gets a `fail`, not an indefinite park.
fn boundedRoundTrip(port: int, msg: string): string! {
  let deadline = monotonic().ns + 500 * 1000000
  let c = dialDeadline("127.0.0.1", port, deadline)?
  c.writeDeadline(msg)?
  let reply = c.readDeadline(4096)?
  c.close()
  return reply
}
```

## One green thread per connection

`accept` in a loop, `spawn` a handler per connection: a slow client cannot delay
the next accept, because the handler runs on its own green thread.

```bit
import { listen, Listener, Conn } from "std/net"

fn handle(c: Conn, done: chan<int>) {
  let req = c.read(4096)
  c.write(req) catch e {
    c.close()
    done <- 0
    return
  }
  c.close()
  done <- len(req)
}

fn echoServer(l: Listener, n: int, done: chan<int>): ()! {
  let i = 0
  while (i < n) {
    let c = l.accept()?
    spawn handle(c, done)
    i = i + 1
  }
}
```

## Datagrams (UDP)

Connectionless: no accept, no dial. Bind a socket and send or receive datagrams
straight off it, each carrying its own address.

### `UdpSocket`

A bound UDP socket. Send to any address, receive from any address, over the one
socket.

### `Datagram`

One received datagram: its `data`, and the `host`/`port` it came from. The sender
address is what a server replies to - there is no connection to reply over.

### `udpBind(host: string, port: int): UdpSocket!`

Binds a datagram socket to `host:port`. As with `listen`, port `0` lets the
kernel choose one; read it back with `port()`.

### `UdpSocket.port(): int!`

The port this socket is bound to. Meaningful even when `0` was requested.

### `UdpSocket.send(host: string, port: int, data: string): ()!`

Sends one datagram to `host:port`. All-or-nothing - a datagram is never partially
sent, so success means every byte went.

### `UdpSocket.recv(max: int): Datagram!`

Receives the next datagram, up to `max` bytes, parking until one arrives. The
result carries the sender's address. A zero-length datagram is legal and is not
an error - unlike a TCP read, empty here does not mean "closed".

### `UdpSocket.close()`

Closes the socket.

```bit
import { udpBind, UdpSocket } from "std/net"
import { toUpper } from "std/strings"

// Echo `n` datagrams back, uppercased, to whoever sent them.
fn echo(s: UdpSocket, n: int): ()! {
  let i = 0
  while (i < n) {
    let d = s.recv(1024)?
    s.send(d.host, d.port, toUpper(d.data))?
    i = i + 1
  }
  s.close()
}
```

## Name resolution

### `resolve(host: string): string!`

Resolves a hostname to an IPv4 address (a dotted quad), using the first
nameserver in `/etc/resolv.conf`. A dotted-quad argument comes back unchanged, so
it is safe on an address that may already be numeric. A records only - no IPv6,
no search domains, no caching. `dial` and `udpBind` take numeric addresses, so
resolve first:

```bit
import { dial, resolve, Conn } from "std/net"

fn connectByName(host: string, port: int): Conn! {
  return dial(resolve(host)?, port)?
}
```
