# Strings and keys

<!-- doctest: per-block -->

A cache that only ever overwrites is easy. A real one needs to expire
entries, refuse to clobber a value someone else just wrote, and let a
background job walk every key without blocking the server for a second.
`Client.set`/`get` cover the plain case; the rest of this page is the
options and commands that cover the other three.

```bit
import { open } from "redis"
import { Second } from "std/time"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let wrote = r.set("session:abc", "user:1", ttl = 60 * Second, ifAbsent = true, ifExists = false)?
  if (!wrote) {
    println("session:abc already existed")
  }
  let v = r.get("session:abc")?
  match (v) {
    Some(s) => println(s)
    None => println("(no session)")
  }
  r.close()
  return
}
```

`set(key, value, ttl = 0, ifAbsent = false, ifExists = false): bool` -
`ttl` is nanoseconds (`std/time.Second`/`Millisecond`), sent as `PX`;
`ttl == -1` means `KEEPTTL` (keep whatever TTL the key already had, if any) -
a numeric sentinel rather than a fifth `keepTtl` parameter, since a class or
a fifth argument would push this call past this package's own
five-parameter readability line. `ifAbsent`/`ifExists` are `NX`/`XX`.
Returns `true` when the key was actually written, `false` only when
`ifAbsent`/`ifExists` refused it.

## Reading the old value with `setGet`

`set`'s return value answers "did it write" - to get the value a key held
*before* the write, in the same round trip, use `setGet` instead. It takes
the identical options and returns `Option<string>` (`None` if the key had
no previous value):

```bit
import { open } from "redis"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let previous = r.setGet("counter:reset", "0")?
  match (previous) {
    Some(v) => println("was ${v}")
    None => println("was unset")
  }
  r.close()
  return
}
```

## `r.str(key)`: reading and writing part of a string

```bit
import { open } from "redis"
import { Second } from "std/time"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let s = r.str("greeting")
  s.append("Hello")?
  s.append(", world")?
  let sub = s.getRange(0, 4)? // "Hello"
  println(sub)
  let n = s.strLen()? // 12
  println("${n}")

  let read = s.getEx(30 * Second)?
  match (read) {
    Some(v) => println(v)
    None => println("(unset)")
  }
  r.close()
  return
}
```

- `getEx(ttl = 0, persist = false): Option<string>` - `GETEX`, reads the
  value and optionally changes its TTL in the same round trip.
- `getDel(): Option<string>` - `GETDEL`, reads and removes the key
  atomically.
- `append(value): i64` - `APPEND`, returns the length after appending.
- `strLen(): i64` - `STRLEN`, `0` for a missing key.
- `getRange(start, stop): string` - `GETRANGE`, a 0-indexed inclusive
  substring; a negative index counts from the end.
- `setRange(offset, value): i64` - `SETRANGE`, overwrites starting at
  `offset`, zero-padding the gap if `offset` is past the current length.
- `lcs(otherKey): string` / `lcsLen(otherKey): i64` - `LCS`, the longest
  common subsequence of two keys' values (or just its length).

`r.counter(key).incrByFloat(delta): f64` (`INCRBYFLOAT`) lives on the
counter handle, not here - see [Commands](commands.md) for the rest of the
counter surface; it reads as "grow this counter" on the same key
`incr`/`incrBy` already use.

## `r.keys()`: operating across many keys

`SCAN`, `MGET`, `TTL` and friends do not belong to any one key, so they
live on a namespace handle instead of a per-key one:

```bit
import { open } from "redis"
import { Second } from "std/time"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let k = r.keys()

  k.mset(map<string, string>{ "a": "1", "b": "2" })?
  let values = k.getMany("a", "b", "missing")?
  println("${len(values)} results")

  k.expire("a", 60 * Second)?
  let ttl = k.ttl("a")?
  match (ttl) {
    Remaining(ns) => println("${ns / Second}s left")
    NoExpiry => println("no expiry")
    NoKey => println("no such key")
  }
  r.close()
  return
}
```

- `unlink(...keys)` / `touch(...keys): i64` - `UNLINK` (non-blocking
  delete), `TOUCH` (bump recency without reading).
- `expire`/`pexpire`/`expireAt`/`pexpireAt(key, ttl, when = ""): bool` - the
  full `EXPIRE` family; `when` is `"NX"`, `"XX"`, `"GT"` or `"LT"`, empty
  for no condition. `Client.expire(key, seconds)` still exists for the
  plain case with no condition.
- `ttl`/`pttl(key): Ttl` - an enum (`NoKey`, `NoExpiry`, `Remaining(ns)`,
  nanoseconds) rather than Redis's own `-2`/`-1`/N-seconds sentinels.
- `persist(key): bool` - `PERSIST`, clears the TTL.
- `keyType(key): KeyType` - `TYPE`, one of `KeyNone`, `KeyString`,
  `KeyList`, `KeySet`, `KeyZset`, `KeyHash`, `KeyStream`.
- `rename(src, dst)` / `renameNx(src, dst): bool` - `RENAME`/`RENAMENX`.
- `copy(src, dst, replace, db): bool` - `COPY`; pass `db = -1` for "same
  database as the source key" (a required argument, not a default - see
  the sharp edges below).
- `randomKey(): Option<string>` - `RANDOMKEY`, `None` on an empty database.
- `objectEncoding(key): string` - `OBJECT ENCODING`.
- `getMany(...keys): []Option<string>` / `mset(fields)` /
  `msetNx(fields): bool` - `MGET`/`MSET`/`MSETNX`.

## Walking the whole keyspace with `scan`

```bit
import { open } from "redis"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  for key of r.keys().scan("session:*")? {
    println(key)
  }
  r.close()
  return
}
```

`scan(pattern = "", count = 0, keyType = "")` returns an iterator whose
`next(): Option<string>!` fetches a new page only when the current one runs
out; a page that fails to arrive is returned as a `RedisError`, hence `for key
of it?`. `pattern` filters key names server-side (`SCAN`'s own `MATCH`),
`count` is a hint for how many keys to fetch per round trip, and `keyType`
(`"string"`, `"hash"`, ...) filters by `TYPE`. There is no queued/pipelined
version: a cursor is several round trips, and a pipeline's `Future<T>` only
ever resolves one.

## Reading inside a transaction

`tx.str(key)` and `tx.keys()` only queue. `tx.read.str(key)` and
`tx.read.keys()` are the immediate views of the same handles, run now on the
transaction's own connection, between `WATCH` and `MULTI`. If another client
changes a watched key first, the transaction retries and your body runs again
with fresh reads:

```bit
import { open } from "redis"
import { Second } from "std/time"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let key = "session:7"
  r.transaction<()>([key], (tx) => {
    match (tx.read.keys().ttl(key)?) {
      NoExpiry => { tx.keys().expire(key, 60 * Second) }
      _ => {}
    }
    if (tx.read.str(key).strLen()? == 0) {
      tx.str(key).append("new")
    }
    return
  })?
  r.close()
  return
}
```

The reads (`strLen`, `getRange`, `lcs`, `lcsLen` on `str`; `ttl`, `pttl`,
`keyType`, `randomKey`, `objectEncoding`, `getMany` and `scan` on `keys`) work
through `tx.read`. A write such as `tx.read.str(key).append(...)` would run
immediately, outside the transaction's `MULTI`/`EXEC`, so it fails with
`RedisError.Invalid`; queue it with `tx.str(key)` or `tx.keys()`.

## Sharp edges

- `set`/`setGet`'s `ttl` is nanoseconds, sent as `PX` milliseconds - not
  seconds. `ttl == -1` means `KEEPTTL`, `ttl == 0` (the default) sends
  neither flag, clearing any TTL the key already had, matching plain
  `SET`'s own behavior.
- `copy`'s `db` has no default (a parameter default must be a literal
  token, and `-1` is a unary-minus expression, not one) - pass `-1`
  explicitly for "same database".
- `getRange`/`strLen`/`lcs` never fail on a missing key; they return `""`,
  `0` and `""` respectively, matching Redis's own behavior for an absent
  string.
- A named-argument call must still supply every parameter, defaulted ones
  included - defaults only apply to a purely positional call: `r.set(k, v,
  ttl = 60 * Second, ifAbsent = true)` alone does not compile today - add
  `ifExists = false` too, or drop to a fully positional call.

## Next

See [Commands](commands.md) for `Client`'s plain-string `get`/`set` and the
rest of the always-on method surface, and [Hashes](hashes.md) for the
sibling per-field TTL family this page's `Ttl` enum mirrors.
