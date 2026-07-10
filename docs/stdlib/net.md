# std/net

Non-blocking TCP over green threads. A connection that waits for bytes parks the
green thread reading it and leaves its OS thread free, so the idiomatic "one
green thread per connection" server costs one `Task` per connection, not one OS
thread. Every operation that can fail returns `T!` — propagate with `?` or handle
with `catch`.

Addresses are dotted-quad IPv4 literals (`"127.0.0.1"`), not hostnames: there is
no name resolution yet. There is also no TLS — put a terminating proxy in front
before exposing a public port.

<!-- doctest: per-block -->

## Listening

### `Listener`

A listening socket. The only thing you do with it is `accept`; it is not a
`Conn`.

### `listen(host: string, port: int): Listener!`

Binds a listening socket to `host:port`. Pass port `0` to let the kernel choose a
free port, then read it back with `port()` — the reliable way to bind in a test,
since choosing a number yourself races every other process on the machine.

### `Listener.port(): int!`

The port the listener is actually bound to. Meaningful even when `0` was
requested — that is how you learn the kernel's choice.

### `Listener.accept(): Conn!`

Waits for the next connection and returns it. Parks the calling green thread; the
OS thread goes and runs something else meanwhile.

### `Listener.close()`

Stops listening and releases the port.

```bit
import { listen, Listener, Conn } from "std/net"
import { toUpper } from "std/strings"

// Accept `n` connections, uppercase one request on each, and close.
function serve(l: Listener, n: int): ()! {
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
the first write — the failure is reported where it happened.

### `Conn.read(max: int): string`

Reads up to `max` bytes, parking until some arrive. An empty result means the
peer closed: an orderly end of stream, and the condition that ends a read loop.

### `Conn.write(s: string): ()!`

Writes all of `s`. A short write is retried internally, so this either wrote every
byte or failed.

### `Conn.readAll(): string`

Reads until the peer closes and returns everything. Only safe against a peer that
actually closes; a keep-alive protocol needs its own framing layer instead.

### `Conn.close()`

Closes this end of the connection.

```bit
import { dial } from "std/net"

// One request, one response, over a fresh connection.
function roundTrip(port: int, msg: string): string! {
  let c = dial("127.0.0.1", port)?
  c.write(msg)?
  let reply = c.readAll()
  c.close()
  return reply
}
```

## One green thread per connection

`accept` in a loop, `spawn` a handler per connection: a slow client cannot delay
the next accept, because the handler runs on its own green thread.

```bit
import { listen, Listener, Conn } from "std/net"

function handle(c: Conn, done: chan<int>) {
  let req = c.read(4096)
  c.write(req) catch e {
    c.close()
    done <- 0
    return
  }
  c.close()
  done <- len(req)
}

function echoServer(l: Listener, n: int, done: chan<int>): ()! {
  let i = 0
  while (i < n) {
    let c = l.accept()?
    spawn handle(c, done)
    i = i + 1
  }
}
```
