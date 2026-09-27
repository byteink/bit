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
import { open } from "redis"

fn main(): ()! {
  let c = open("rediss://:secret@cache.internal:6380/2?timeout=2s&pool=4")?
  c.set("greeting", "hello")?
  let v = c.get("greeting")?
  match (v) {
    Some(s) => println(s)
    None => println("(nil)")
  }
  c.close()
  return
}
```

## `connect(Options)`: the fields a URL has no room for

A self-signed CA for a test server, or turning certificate verification off
entirely, are not things a URL should carry. `connect` takes an `Options`
directly - every field has a default, so `Options{ host = "cache" }` is a
complete, working configuration:

```bit
import { connect, Options } from "redis"
import { readFile } from "std/fs"

fn main(): ()! {
  let c = connect(
    Options{
      host = "cache.internal", port = 6380, password = "secret",
      tls = true, tlsRootCa = readFile("ca.pem")?,
    },
  )?
  c.ping()?
  c.close()
  return
}
```

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
