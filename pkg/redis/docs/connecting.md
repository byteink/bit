# Connecting

<!-- doctest: per-block -->

A Redis instance usually needs a host, a password, a database index and
sometimes TLS - and in production you want a small pool of connections
shared across a program, not one connection reopened per request. `open`
takes all of that as one URL.

```bit
import { open } from "redis"

fn main(): ()! {
  let c = open("redis://localhost:6379")?
  let pong = c.ping()?
  println(pong)
  c.close()
  return
}
```

`open(url): Client ! RedisError` parses the URL, opens one connection to
validate it (so a wrong password or an unreachable host fails right here,
not on your first `get`), and returns a `Client` backed by a pool of up to
10 connections. Call `c.close()` once, when the caller is done with the
client - it closes the whole pool, not just one connection.

## The URL

```
redis://[user[:pass]@]host[:port][/db][?timeout=5s&pool=16&name=app]
rediss://...                                    # same, over TLS
```

- `user:pass` are percent-decoded. Redis's common case, a password with no
  ACL user, is `redis://:secret@host`.
- `/db` selects a database by index (`SELECT`) as part of connecting.
- `timeout=5s` (or `250ms`) sets both the connect timeout and the timeout on
  every command. `pool=16` sets the pool size. `name=app` is the name this
  connection shows up under in `CLIENT LIST` on the server.

```bit
import { connect, parseUrl } from "redis"

fn main(): ()! {
  let opts = parseUrl("rediss://:secret@cache.internal:6380/2?timeout=2s&pool=4")?
  println("${opts.host}:${opts.port}, database ${opts.db}")
  let c = connect(opts)?
  defer c.close()
  c.set("leaderboard:season", "autumn")?
  let v = c.get("leaderboard:season")?
  match (v) {
    Some(s) => println(s)
    None => println("(nil)")
  }
  return
}
```

`parseUrl` lets you inspect or change the options before connecting. It
validates the URL without opening a connection. Do not log the password.

## `connect(Options)`: the fields a URL has no room for

A self-signed CA for a test server, or turning certificate verification off
entirely, are not things a URL should carry. `connect` takes an `Options`
directly - every field has a default, so `Options{ host = "cache" }` is a
complete, working configuration:

```bit
import { connect, Options, tlsRootsFor } from "redis"
import { readFile } from "std/fs"

fn main(): ()! {
  let opts = Options{
    host = "cache.internal", port = 6380, password = "secret",
    tls = true, tlsRootCa = readFile("ca.pem")?,
  }
  let roots = tlsRootsFor(opts)?
  println("${len(roots.roots)} trusted certificate authorities")
  let c = connect(opts)?
  defer c.close()
  c.ping()?
  return
}
```

`tlsRootsFor` checks the selected trust store without contacting Redis.
With TLS enabled it parses your CA bundle, or loads the system roots when
you supplied none. A malformed CA bundle fails before you connect.
`connect` also performs this check, so call it separately only when you
need to inspect the trust store first.

`insecureSkipVerify: true` turns certificate verification off - never the
default, and named for exactly what it does.

## What happens during connect

Each physical connection in the pool runs `HELLO 3` (optionally with `AUTH`
and `CLIENT SETNAME`), then `SELECT` if the URL or `Options` named a
non-zero database. A server that does not know `HELLO` - an older Redis, or
one with it renamed away - falls back to plain `AUTH`/`CLIENT SETNAME` over
RESP2 automatically; everything else about the client works the same either
way.

## Failures and reconnecting

Every method returns `T ! RedisError` (see [Commands](commands.md) for the
variants). A read - `get`, `exists`, `ping` - that fails because the
connection itself was bad (closed, timed out) is retried once on a fresh
connection automatically. A write - `set`, `del`, `expire` - never is:
retrying a write you cannot confirm ran could run it twice.

The generic escape hatch is still here for a command this package has not
named yet:

```bit
import { open } from "redis"

fn main(): ()! {
  let c = open("redis://localhost:6379")?
  let reply = c.command(["PING"])?
  match (reply) {
    Simple(s) => println(s)
    _ => println("unexpected reply")
  }
  c.close()
  return
}
```

`command(args): Reply ! RedisError` sends any command and returns its raw
decoded, RESP3-attribute-unwrapped `Reply`. A `-ERR ...`/`-WRONGTYPE ...`
reply surfaces as a typed `RedisError`, not a raw string - match on it the
same way you would any other failure from this package.

## Run custom reads through the pool or one leased connection

Use a custom `Cmd` when your leaderboard needs a reply decoder of its own.
`poolRunner` shares the client's pool and retry policy. To keep a read on a
leased connection, borrow one with `withConn` and build a `pinnedRunner`
inside its callback:

```bit
import { open, Cmd, asOptString, poolRunner, pinnedRunner } from "redis"
import { Second } from "std/time"

fn main(): ()! {
  let c = open("redis://localhost:6379")?
  defer c.close()
  let season = Cmd<Option<string>>{
    args = ["GET", "leaderboard:season"],
    decode = (reply) => asOptString(reply, "GET"),
    readOnly = true,
  }
  let pooled = poolRunner(c).runCmd(season)?
  let pinned = c.withConn<Option<string>>((conn) => {
    let runner = pinnedRunner(conn, Second)
    return runner.runCmd(season)?
  })?
  println("pooled season: ${unwrapOr(pooled, "(none)")}")
  println("leased season: ${unwrapOr(pinned, "(none)")}")
  return
}
```

`withConn` releases the lease when the callback returns or fails, closing
an unusable connection; keep the pinned runner inside that callback. It
does not retry a failed read. `pinnedRunner` takes a command timeout in
nanoseconds and refuses a `Cmd` whose `readOnly` flag is false. Use the
client's named methods for ordinary reads and a [transaction](pipelines-and-transactions.md)
when writes depend on what you read. Sharing a connection alone does not
make the two reads agree if another client changes the key between them.

## Own one physical connection

Use `open` for ordinary pooled access. When you need one physical
connection without a pool, `dialConn` connects and completes the handshake.
You own the returned connection, so close it when finished:

```bit
import { dialConn, parseUrl, tlsRootsFor, pinnedRunner, Cmd, asOptString } from "redis"

fn main(): ()! {
  let opts = parseUrl("redis://localhost:6379")?
  let roots = tlsRootsFor(opts)?
  let conn = dialConn(opts, roots)?
  defer conn.close()
  let season = pinnedRunner(conn, opts.commandTimeout).runCmd(
    Cmd<Option<string>>{
      args = ["GET", "leaderboard:season"],
      decode = (reply) => asOptString(reply, "GET"),
      readOnly = true,
    },
  )?
  println("season: ${unwrapOr(season, "(none)")}")
  return
}
```

`close` is idempotent. The connection has one owner; serialize its commands
and disposal. The deferred close also runs if a command fails. A directly
dialed connection does not reconnect or retry automatically.

The connection passed to a `withConn` callback is borrowed from the client.
Do not close it yourself or keep it after the callback returns. Let
`withConn` release its lease and `Client.close` shut down the pool.
