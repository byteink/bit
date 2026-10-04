# std/net

Non-blocking TCP over green threads. A connection that waits for bytes parks the
green thread reading it and leaves its OS thread free, so the idiomatic "one
green thread per connection" server costs one `Task` per connection, not one OS
thread. Every operation that can fail returns `T!` - propagate with `?` or handle
with `catch`.

Addresses are dotted-quad IPv4 literals (`"127.0.0.1"`), not hostnames: this
module does not resolve hostnames. It also has no TLS - put a terminating
proxy in front before exposing a public port.

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

### `Conn.writeBytes(b: []byte): ()!`

Like `write`, but takes bytes instead of a `string`: the same no-deadline
behavior (parks until every byte is written, however slowly the peer drains
it) and the same deadline-bound behavior once `setDeadline` has armed this
connection. Use it when the bytes are already a `[]byte` - building a wire
message straight into one, say - so writing them never allocates a `string`
just to throw it away at the socket.

```bit
import { listen, Listener, Conn } from "std/net"

// Frame `body` as "<n>\r\n<body>" and write it straight from the `[]byte`
// that framing built, no `string(...)` in between.
fn writeFramed(c: Conn, body: []byte): ()! {
  let head = "${len(body)}\r\n"
  let w = []byte(len(head) + len(body))
  let i = 0
  while (i < len(head)) {
    w[i] = head[i]
    i = i + 1
  }
  let j = 0
  while (j < len(body)) {
    w[len(head) + j] = body[j]
    j = j + 1
  }
  c.writeBytes(w)?
}
```

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

Resolves a hostname to an IPv4 address (a dotted quad), asking each nameserver
in `/etc/resolv.conf` in turn until one answers. A dotted-quad argument comes back unchanged, so
it is safe on an address that may already be numeric. A records only - no IPv6,
no search domains, no caching. `dial` and `udpBind` take numeric addresses, so
resolve first:

```bit
import { dial, resolve, Conn } from "std/net"

fn connectByName(host: string, port: int): Conn! {
  return dial(resolve(host)?, port)?
}
```

### `lookupTxt(name: string): []string!`

The TXT records of `name`: one entry per record, with the record's
character-strings joined in order and nothing between them (RFC 7208 section
3.3 and RFC 6376 section 3.6.2.2 both read a TXT value that way), as the raw
bytes the server sent. A name with no TXT record, NXDOMAIN included, gives an
empty list rather than an error. A timeout, a SERVFAIL and a malformed reply
fail, the last as `lookupTxt <name>: malformed reply`; a trailing dot on `name`
is accepted.

It asks the way `resolve` does: each nameserver in `/etc/resolv.conf` in turn,
each for at most the per-server share of `resolveBudgetMs`. A reply that does
not fit in a UDP datagram comes back truncated, and the lookup repeats the
query over TCP to the same server inside that same budget (RFC 7766), which a
2048-bit DKIM key needs. The TCP retry reaches IPv4 nameservers only; a
truncated reply from an IPv6 nameserver fails that server and the next is tried.
On Windows the runtime has no TXT lookup and the call fails with
`lookupTxt <name>: not supported on this platform`.

A mailer checks the key it published against the key it signs with:

```bit
import { lookupTxt } from "std/net"

fn publishedKey(selector: string, domain: string): string! {
  let records = lookupTxt("${selector}._domainkey.${domain}")?
  if (len(records) == 0) {
    fail newError("no DKIM record for ${selector} at ${domain}")
  }
  return records[0]
}
```

### `resolveBudgetMs(): int`

The longest `resolve` can take on this machine, in milliseconds: each
nameserver gets its full retry budget, so the figure grows with the number of
nameservers. Code that races a lookup against its own timer adds this to the
time it allows for connecting and transferring, so slow but successful DNS is
not mistaken for a timeout:

```bit
import { resolveBudgetMs } from "std/net"

fn fetchDeadlineMs(transferMs: int): int {
  return resolveBudgetMs() + transferMs
}
```

## Address literals

### `isIpv4Literal(s: string): bool`

Inkwell lets an operator point it at a storage endpoint, and a numeric host needs
different handling from a name (no virtual-host style bucket names, no
certificate name match). `isIpv4Literal` says whether `s` is an IPv4 address in
strict dotted-quad form: four decimal octets, 0 to 255, no leading zeros. The
shorthand forms `inet_aton` accepts (`"127.1"`, `"0x7f.0.0.1"`, `"0177.0.0.1"`,
`"2130706433"`) are not addresses here, so a host that is not canonical is never
silently treated as one.

### `isIpv6Literal(s: string): bool`

Whether `s` is an IPv6 address in RFC 4291 text form: eight groups of 1 to 4 hex
digits, or fewer with one `::` for the zeros, optionally ending in an IPv4 quad
(`"::ffff:192.0.2.1"`). Brackets and zone ids are not part of the address: strip
the `[` `]` of a URL host first, and a `"%eth0"` suffix is rejected.

```bit
import { isIpv4Literal, isIpv6Literal } from "std/net"

fn isNumericHost(host: string): bool {
  return isIpv4Literal(host) || isIpv6Literal(host)
}

fn storageUrl(host: string, bucket: string): string {
  if (isNumericHost(host)) {
    return "https://${host}/${bucket}"
  }
  return "https://${bucket}.${host}"
}
```

## International domain names

A mail address or a URL may carry a host a person typed in their own script:
`Bücher.Example`, `例子.广告`. DNS, SMTP and a TLS certificate carry only ASCII,
so the host has to become the A-label form (`xn--bcher-kva.example`) before it
goes on the wire, and an A-label has to become readable again before it goes on
screen. `idnaToAscii` and `idnaToUnicode` do both, the way browsers do
(UTS #46, non-transitional processing, which is what IDNA2008 also gives).

### `idnaToAscii(domain: string): string!`

The ASCII form of `domain`, ready for a resolver, a `Host` header or a
certificate name match. Each label is mapped (case folded, full-width forms
narrowed, ignorable code points dropped), normalized to NFC, validated and,
when it is not ASCII, encoded as `xn--` plus Punycode. `ß` stays `ß`
(`faß.de` is `xn--fa-hia.de`), the one place this differs from the older IDNA2003
processing, which wrote `fass.de`.

An ASCII domain that is already lowercase comes back as the very string passed
in, after one pass over its bytes, with no allocation. `Bücher.Example` goes
through the tables and takes a few microseconds.

The checks are the ones that keep a hostile name from passing for another: a
label may not begin or end with `-` or have `-` in its third and fourth
positions, may not begin with a combining mark, may use only the code points
IDNA allows (ASCII only as `a-z`, `0-9` and `-`), must follow the CONTEXTJ rule
for U+200C and U+200D, and, when any label of the domain is written right to
left, must follow the Bidi rule of RFC 5893. Then the DNS lengths: every label 1
to 63 octets and the domain at most 253.

A failure names the label and the rule, never a generic message:

```text
idna: label 'a b' contains the ASCII character U+0020, which UseSTD3ASCIIRules rejects
idna: label '-a' begins or ends with a hyphen
idna: label 'xn--abc-' is Punycode for an empty or all-ASCII label
```

A trailing root dot is an empty label and is an error here, because an empty
label has no valid DNS length; strip it first. `idnaToUnicode` keeps it.

### `idnaToUnicode(domain: string): string!`

The Unicode form of `domain`: every `xn--` label decoded and validated by the
same rules, the rest mapped and normalized. No DNS length is verified, so a
long or root-dotted name still reads back. Use it to show a host to a person,
never to compare two hosts: compare the `idnaToAscii` forms.

```bit
import { idnaToAscii, idnaToUnicode } from "std/net"

// The host a certificate or a resolver sees, from what the user typed.
fn wireHost(typed: string): string {
  return idnaToAscii(typed) catch e {
    print("not a valid host: ${e.message()}\n")
    ""
  }
}

fn main() {
  print(wireHost("Bücher.Example") + "\n")
  let shown = idnaToUnicode("xn--bcher-kva.example") catch ""
  print(shown + "\n")
}
```

Prints `xn--bcher-kva.example` and `bücher.example`. The functions are checked
against every line of Unicode's `IdnaTestV2.txt` for 17.0.0 (the 6391 cases for
`toUnicode` and `toAsciiN`).
