# Commands

The full set of named methods on `Client`, each a thin wrapper over
`command()` ([Connecting](connecting.md)) that checks the reply shape and
returns a plain Bit value instead of a raw `Reply`.

```bit
import { open, asOptString } from "redis"

fn main(): ()! {
  let c = open("redis://127.0.0.1:6379")?
  c.set("greeting", "hello")?
  let v = c.get("greeting")?
  match (v) {
    Some(s) => println(s)
    None => println("(nil)")
  }
  let removed = c.del(["greeting"])?
  println("${removed}")
  let server = c.info("server")?
  println(server)
  let doctor = asOptString(c.command(["MEMORY", "DOCTOR"])?, "MEMORY DOCTOR")?
  match (doctor) {
    Some(report) => println(report)
    None => println("(no report)")
  }
  c.close()
  return
}
```

- `get(key): Option<string> ! RedisError` - `Option.None` on a cache miss,
  never `Option.Some("")`.
- `set(key, value, ttl = 0, ifAbsent = false, ifExists = false): bool !
  RedisError` - `true` if the key was written; `ttl` is nanoseconds, sent
  as `PX`; `ifAbsent`/`ifExists` are `NX`/`XX`. `setGet` takes the same
  options and returns the key's previous value instead. See
  [Strings and keys](strings-and-keys.md) for the full option set and
  `r.str(key)`/`r.keys()`.
- `del(keys): i64 ! RedisError` - the number of keys actually removed.
- `exists(keys): i64 ! RedisError` - the number of the given keys that exist.
- `expire(key, seconds): bool ! RedisError` - `true` if the key exists and
  the timeout was set.
- `ping(): string ! RedisError` - the server's reply text (normally
  `"PONG"`).
- `info(section = ""): string ! RedisError` - the server's `INFO` report as
  raw `name:value` lines (`redis_version:7.2.4`, ...). Plain `INFO` with no
  section; `info("server")`, `info("memory")` and the other documented names
  narrow it. RESP3 answers `INFO` as a verbatim string; `info` hands back its
  text either way.
- `command(args): Reply ! RedisError` - the generic escape hatch described
  in [Connecting](connecting.md); every method above is built on it.

A command with no named method that answers a RESP3 verbatim string
(`LATENCY DOCTOR`, `MEMORY DOCTOR`) is read from its `command()` reply with
the exported decoder `asOptString`, as the example above does for
`MEMORY DOCTOR`.

A server error (`-ERR ...`, `-WRONGTYPE ...`) raises a typed `RedisError`
from whichever method produced it, matchable by variant
(`RedisError.WrongType`, `.Timeout`, ...). See [RESP2](resp.md) for the
reply shapes these methods match against and what nil means on the wire.

## Where to go next

[Strings and keys](strings-and-keys.md), [Hashes](hashes.md) and
[Sorted sets](sorted-sets.md) each build on `command()` for a specific
Redis data type; [Connecting](connecting.md) covers the pool, timeouts and
TLS these methods run over.
