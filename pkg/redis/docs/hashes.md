# Hashes

<!-- doctest: per-block -->

A player profile has several fields (name, level, region) that belong
together and change independently of each other. You could keep each one as
its own string key (`user:1:name`, `user:1:level`, ...), but then reading a
profile is N round trips and deleting one means remembering every key by
hand. A Redis hash is a single key holding a field/value map, so the whole
profile moves as one unit.

```bit
import { open } from "redis"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let profile = r.hash("user:1")
  profile.set(map<string, string>{ "name": "Ada", "level": "12" })?
  let name = profile.get("name")?
  match (name) {
    Some(v) => println(v)
    None => println("(no name set)")
  }
  r.close()
  return
}
```

`r.hash(key)` is a cheap value, `{runner, key}` - call it again any time you
need the same hash, it never allocates a connection of its own.

## Reading and writing fields

```bit
import { open } from "redis"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let profile = r.hash("user:1")

  profile.setField("region", "eu-west")?
  let region = profile.getMany("region", "country")?
  match (region[0]) {
    Some(v) => println(v) // "eu-west"
    None => println("(unset)")
  }
  match (region[1]) {
    Some(v) => println(v)
    None => println("(unset)") // country was never set
  }

  let all = profile.all()?
  println("${len(all)} fields")

  let removed = profile.del("region")?
  println("${removed} field(s) removed")
  r.close()
  return
}
```

- `set(fields): i64` - `HSET`, the number of fields that were newly added
  (an overwrite of an existing field does not count).
- `setField(field, value): bool` - `true` when the field is new.
- `get(field): Option<string>` - `Option.None`, never `Option.Some("")`, when
  the field does not exist.
- `getMany(...fields): []Option<string>` - `HMGET`, one `Option<string>` per
  field, in the order you asked.
- `all(): map<string, string>` - `HGETALL`.
- `del(...fields): i64` - the number of fields actually removed.
- `has(field): bool` - `HEXISTS`.
- `setIfAbsent(field, value): bool` - `HSETNX`, `true` only if the field did
  not already exist.

## Counting inside a hash

A leaderboard's player profile can track stats right alongside the rest of
the record, without a separate counter key:

```bit
import { open } from "redis"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let profile = r.hash("user:1")

  let matches = profile.incrBy("matchesPlayed", 1)?
  let rating = profile.incrByFloat("rating", 2.5)?
  println("matches=${matches} rating=${rating}")
  r.close()
  return
}
```

`incrBy(field, delta): i64` is `HINCRBY`; `incrByFloat(field, delta): f64`
is `HINCRBYFLOAT`. Both create the field at 0 first if it does not exist yet,
the same convention `r.counter(key).incr()` uses.

## Inspecting a hash

```bit
import { open } from "redis"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let profile = r.hash("user:1")
  profile.set(map<string, string>{ "name": "Ada", "level": "12" })?

  let count = profile.len()?
  let keys = profile.keys()?
  let values = profile.values()?
  let nameLen = profile.strLen("name")?
  println("${count} fields, first key is ${keys[0]}, first value is ${values[0]}, 'name' is ${nameLen} bytes")

  let sample = profile.random(1)?
  println("a random field: ${sample[0]}")
  r.close()
  return
}
```

`len()` is `HLEN`; `keys()`/`values()` are `HKEYS`/`HVALS`; `strLen(field)`
is `HSTRLEN`. `random(count, withValues = false)` is `HRANDFIELD key count
[WITHVALUES]` - pass `withValues = true` to get `[field, value, field,
value, ...]` back instead of bare field names.

## Walking a large hash with `scan`

`all()` reads the whole hash in one round trip - fine for a profile, too
much for a hash with a million fields. `scan()` follows Redis's cursor
protocol lazily, one page at a time, and works with `for ... of`:

```bit
import { open } from "redis"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let profile = r.hash("user:1")
  profile.set(map<string, string>{ "name": "Ada", "level": "12" })?

  for pair of profile.scan()? {
    let (field, value) = pair
    println("${field} = ${value}")
  }
  r.close()
  return
}
```

`scan(pattern = "", count = 0)` returns an iterator whose `next(): Option<
(string, string)>!` fetches a new page only when the current one runs out.
A page that fails to arrive (a dropped connection, a timeout, a server error)
is returned as a `RedisError`, so the loop is `for pair of it?` inside a
function that returns `()!`. Pass `pattern` to filter field names server-side (`HSCAN`'s own `MATCH`),
and `count` as a hint for how many entries to fetch per round trip. There is no
queued/pipelined version of `scan()`: a cursor is several round trips, and a
pipeline's `Future<T>` only ever resolves one.

## Field expiry

Redis 7.4 added a TTL per hash field, not just per key - useful for, say, a
session token stored alongside the rest of a player's profile that should
expire on its own:

```bit
import { open } from "redis"
import { Second } from "std/time"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let profile = r.hash("user:1")
  profile.setField("sessionToken", "abc123")?

  profile.expire(["sessionToken"], 30 * Second)?
  let remaining = profile.ttl(["sessionToken"])?
  println("${remaining[0]}s left")

  profile.persist(["sessionToken"])?
  r.close()
  return
}
```

- `expire(fields, ttl, when = ""): []i64` - `HEXPIRE`; `pexpire` is the same
  in milliseconds (`HPEXPIRE`); `expireAt(fields, at, when = "")` takes an
  absolute Unix timestamp in nanoseconds (`std/time.now().ns`), not a
  relative TTL (`HEXPIREAT`). `ttl` is always nanoseconds
  (`std/time.Second`/`Millisecond`), converted to each command's own wire
  unit. `when` is one of `"NX"`, `"XX"`, `"GT"`, `"LT"` - empty means no
  condition.
- `ttl(fields)`/`pttl(fields): []i64` - `HTTL`/`HPTTL`, one entry per field:
  seconds (or milliseconds) remaining, `-1` if the field has no TTL, `-2` if
  the field does not exist. These are Redis's own sentinels, passed through
  unconverted.
- `persist(fields): []i64` - `HPERSIST`, clears the TTL; `1` per field that
  had one removed.
- `getEx(fields, ttl = 0, persist = false): []Option<string>` - `HGETEX`,
  reads fields and optionally changes their TTL in the same round trip.
- `setEx(fields, ttl, when = "", keepTtl = false): bool` - `HSETEX`, sets
  fields with a TTL attached; `when` is `"FNX"`/`"FXX"` here (only set if
  none/some of the fields already exist); `keepTtl` sends `KEEPTTL` instead
  of a new TTL.
- `getDel(...fields): []Option<string>` - `HGETDEL`, reads and removes
  fields atomically.

## Reading a hash inside a transaction

`tx.hash(key)` only queues, so it cannot answer "does this field exist yet?"
before you decide what to write. `tx.read.hash(key)` is the immediate view of
the same hash, run now on the transaction's own connection, between `WATCH`
and `MULTI`. If another client changes a watched key first, the transaction
retries and your body runs again with fresh reads:

```bit
import { open } from "redis"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let key = "user:1"
  r.transaction<()>([key], (tx) => {
    if (!tx.read.hash(key).has("region")?) {
      tx.hash(key).setField("region", "eu")
    }
    return
  })?
  r.close()
  return
}
```

Every read on `Hash` works through `tx.read`, `scan` included. A write such as
`tx.read.hash(key).setField(...)` would run immediately, outside the
transaction's `MULTI`/`EXEC`, so it fails with `RedisError.Invalid`; queue it
with `tx.hash(key)`.

## Sharp edges

- `get`/`getMany`/`getEx`/`getDel` all return `Option<string>`, never a bare
  `""`, so a field holding the empty string is never confused with a
  missing one.
- `set`'s return value counts NEW fields only - overwriting `"name"` with a
  different value again returns `0`, not `1`.
- A missing field's TTL methods return `-2`, not an error - checking a field
  that does not exist is not a failure, the same way `HTTL` itself treats
  it.

## Next

See [Commands](commands.md) for the plain-string command surface hashes sit
alongside, and [Connecting](connecting.md) for pool sizing, timeouts and TLS.
