# Commands

<!-- doctest: per-block -->

Your leaderboard needs a command this client has not named yet. Start with
the named methods when they fit: they check the reply and return a Bit
value. Use `command()` when you need the server's raw reply, then decode
the shape that command promises.

```bit
import { open, asOptString, InfoSection } from "redis"

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
  let server = c.info(InfoSection.Server)?
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
- `info(section = InfoSection.Default): string ! RedisError` - the server's
  `INFO` report as raw `name:value` lines (`redis_version:7.2.4`, ...).
  `InfoSection` has a variant for every section and group the server
  documents (`Server`, `Memory`, `Keyspace`, `All`, `Everything`, ...), so a
  mistyped name does not compile; `Module(name)` is the one free-form case,
  for a module-defined section. `Default` sends plain `INFO`. RESP3 answers
  `INFO` as a verbatim string; `info` hands back its text either way.
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

## Decode a captured reply

Before adding a custom command, save the reply shapes you expect and check
your decoder without a server. Here the saved board has player names,
scores and missing profiles. The same helpers accept the replies from
`command()` or a custom `Cmd` decoder.

```bit
import {
  Reply, asBool, asDouble, asInts, asMap, asOk, asOptStrings,
  asScanPage, asScored, asStrings, pairUp, replyItems,
} from "redis"

fn main(): ()! {
  let names = Reply.Array(
    Option.Some(
      [
        Reply.Bulk(Option.Some("ada")), Reply.Bulk(Option.Some("Ada")),
      ],
    ),
  )
  let scores = Reply.Array(
    Option.Some(
      [
        Reply.Bulk(Option.Some("ada")), Reply.Bulk(Option.Some("1200")),
      ],
    ),
  )
  let profiles = Reply.Array(
    Option.Some(
      [
        Reply.Bulk(Option.Some("Ada")), Reply.Null,
      ],
    ),
  )
  let members = Reply.Array(Option.Some([Reply.Bulk(Option.Some("ada"))]))

  assert(asBool(Reply.Int(1), "EXISTS")?)
  assert(asDouble(Reply.Double(1200.0), "ZSCORE")? == 1200.0)
  let counts = asInts(Reply.Array(Option.Some([Reply.Int(1)])), "HPEXPIRE")?
  assert(counts[0] == 1)
  let found = asMap(names, "HGETALL")?
  let (name, present) = found["ada"]
  assert(present && name == "Ada")
  asOk(Reply.Simple("OK"), "SET")?
  let optional = asOptStrings(profiles, "MGET")?
  assert(optional[0] == Option.Some("Ada") && optional[1] == Option.None)
  let page = Reply.Array(Option.Some([Reply.Bulk(Option.Some("0")), members]))
  let (cursor, players) = asScanPage(page, "SSCAN")?
  assert(cursor == "0" && players[0] == "ada")
  let ranked = asScored(scores, "ZRANGE")?
  assert(ranked[0].member == "ada" && ranked[0].score == 1200.0)
  assert(asStrings(members, "SMEMBERS")?[0] == "ada")
  let entries = pairUp(replyItems(names, "HGETALL")?, "HGETALL")?
  assert(len(entries) == 1)
  println("captured leaderboard replies decoded")
  return
}
```

`asMap` accepts a RESP3 map or alternating keys and values from RESP2.
`asScored` accepts nested member/score pairs or the flat RESP2 form shown
here. `asOptStrings` keeps a missing value separate from an empty string.
`asScanPage` returns the cursor and one page; cursor `"0"` ends the scan.

Use `replyItems` and `pairUp` when you need the original `Reply` values
instead of strings. `pairUp` refuses an odd number of elements. A decoder
that sees the wrong shape fails with `RedisError.Unexpected`; pass the
command name so the error identifies the operation. `asOk` checks for a
simple-string reply and discards its text.

## Where to go next

[Strings and keys](strings-and-keys.md), [Hashes](hashes.md),
[Pub/sub](pubsub.md) (`publish`, `subscribe` and the `PUBSUB` commands),
[Sorted sets](sorted-sets.md) and
[Locations, unique counts and bitmaps](geo-hll-bitmaps.md) and
[Seen, trending and percentiles](probabilistic.md) each build on
`command()` for a specific Redis data type; [Connecting](connecting.md) covers the pool, timeouts and
TLS these methods run over.

[Requests per minute: time series](timeseries.md) covers the `TS.*` commands behind `r.timeseries(key)`.

[Similar players and per-round scores](vectors-and-arrays.md) covers the `V*` commands behind `r.vset(key)` and the `AR*` commands behind `r.array(key)`.

[Searching articles](search.md) covers the `FT.*` commands behind `r.search(index)`.
