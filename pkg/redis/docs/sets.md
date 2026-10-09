# Sets

<!-- doctest: per-block -->

Inkwell articles carry tags: `bit`, `redis`, `howto`. You could keep them in
one comma-separated string, but then adding a tag means reading the string,
checking for a duplicate, and writing it back, and "which articles share a
tag" means parsing every string. A Redis set is an unordered collection of
unique strings: adding the same tag twice is a no-op, membership is one
call, and the server can intersect or merge whole sets for you.

```bit
import { open } from "redis"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let tags = r.sset("article:1:tags")
  let added = tags.add("bit", "redis", "bit")?
  println("${added} new tags") // 2, the second "bit" was already there
  let all = tags.members()?
  println("${len(all)} tags in total")
  r.close()
  return
}
```

`r.sset(key)` is a cheap value, `{client, key}` - call it again any time you
need the same set. It is `sset`, not `set`, because `r.set(key, value)` is
already the plain string command.

## Adding, removing and asking

```bit
import { open } from "redis"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let tags = r.sset("article:1:tags")
  tags.add("bit", "redis", "howto")?

  let removed = tags.remove("howto", "draft")?
  println("${removed} removed") // 1, "draft" was never in the set

  if (tags.has("bit")?) {
    println("tagged bit")
  }
  let flags = tags.hasMany("bit", "go", "redis")?
  println("${flags[0]} ${flags[1]} ${flags[2]}") // true false true

  let size = tags.len()?
  println("${size} tags")
  r.close()
  return
}
```

- `add(...members): i64` - `SADD`, the number of members that were new.
- `remove(...members): i64` - `SREM`, the number actually removed; absent
  members do not count.
- `has(member): bool` - `SISMEMBER`.
- `hasMany(...members): []bool` - `SMISMEMBER`, one answer per member, in
  the order you asked, in one round trip.
- `members(): []string` - `SMEMBERS`, every member in no particular order. A
  missing key is an empty list, not an error.
- `len(): i64` - `SCARD`, `0` for a missing key.

`members()` returns the whole set at once. For a set that can grow large,
use `scan()` below instead.

## Taking members out

A "featured article" rotation picks a few articles at random, and a work
queue hands each item out exactly once:

```bit
import { open } from "redis"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let queue = r.sset("inkwell:to-publish")
  queue.add("a1", "a2", "a3", "a4")?

  let peek = queue.random(2)?
  println("${len(peek)} candidates, still in the set")

  let next = queue.pop()?
  println("publishing ${next[0]}")
  let batch = queue.pop(2)?
  println("${len(batch)} more taken")

  queue.move("inkwell:published", "a4")?
  r.close()
  return
}
```

- `random(count = 1): []string` - `SRANDMEMBER`, leaves the set alone. A
  negative count allows repeats: `random(-5)` returns five members, some
  possibly the same.
- `pop(count = 1): []string` - `SPOP`, removes and returns up to `count`
  members. The result is always a list, an empty one when the set is empty.
- `move(dest, member): bool` - `SMOVE`, `true` when `member` was in this set
  and is now in `dest`.

## Combining sets

Tags are most useful when you can ask questions across articles. Which tags
do two articles share? Which tags appear on either? Which tags does the
first have that the second lacks?

```bit
import { open } from "redis"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let first = r.sset("article:1:tags")
  let second = r.sset("article:2:tags")
  first.add("bit", "redis", "howto")?
  second.add("bit", "redis", "web")?

  let shared = first.inter("article:2:tags")?
  println("${len(shared)} shared") // bit, redis
  let either = first.union("article:2:tags")?
  println("${len(either)} in total") // bit, redis, howto, web
  let only = first.diff("article:2:tags")?
  println("only on the first: ${only[0]}") // howto
  r.close()
  return
}
```

The handle's own key is always the first source, and the other keys follow:
`first.diff("article:2:tags")` is `SDIFF article:1:tags article:2:tags`, the
order that matters for a difference.

- `inter(...others): []string` - `SINTER`.
- `union(...others): []string` - `SUNION`.
- `diff(...others): []string` - `SDIFF`.

Each takes any number of other keys. With none, you get this set's own
members back.

### Keeping the result

To keep a result instead of reading it, the `Store` forms write it to a
destination key and return how many members it holds. The destination is
replaced, never merged into:

```bit
import { open } from "redis"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let first = r.sset("article:1:tags")
  first.add("bit", "redis", "howto")?
  r.sset("article:2:tags").add("bit", "redis", "web")?

  let common = first.interStore("tags:common", "article:2:tags")?
  let everything = first.unionStore("tags:all", "article:2:tags")?
  let unique = first.diffStore("tags:only-first", "article:2:tags")?
  println("${common} shared, ${everything} total, ${unique} only on the first")
  r.close()
  return
}
```

- `interStore(dest, ...others): i64` - `SINTERSTORE`.
- `unionStore(dest, ...others): i64` - `SUNIONSTORE`.
- `diffStore(dest, ...others): i64` - `SDIFFSTORE`.

### Counting without fetching

"How many tags do these articles share?" does not need the tags themselves.
`interCard` takes the other keys as a list, then an optional limit:

```bit
import { open } from "redis"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let first = r.sset("article:1:tags")
  first.add("bit", "redis", "howto")?
  r.sset("article:2:tags").add("bit", "redis", "web")?

  let shared = first.interCard(["article:2:tags"])?
  println("${shared} shared tags")

  // Stop counting at 1: enough to answer "do they share anything?".
  let any = first.interCard(["article:2:tags"], 1)?
  println("${any}")
  r.close()
  return
}
```

`interCard(others: []string, limit = 0): i64` - `SINTERCARD`. A `limit` of
`0` means no limit. A positive `limit` stops counting early, which is cheaper
on a huge intersection when you only need to know it is at least that big.

## Walking a large set

`scan(pattern = "", count = 0)` returns an iterator over the members. It
fetches one page at a time as you consume it, so a million-member set never
sits in memory whole:

```bit
import { open } from "redis"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let tags = r.sset("tags:all")
  for tag of tags.scan("re*", 100)? {
    println(tag)
  }

  let it = tags.scan()
  match (it.next()?) {
    Some(first) => println("first: ${first}")
    None => println("(empty)")
  }
  r.close()
  return
}
```

`pattern` filters members on the server (`SSCAN`'s own `MATCH`); `count` is a
hint for how many members to fetch per round trip, not a promise. The
iterator's `next(): Option<string>!` returns `Option.None` once the cursor has
come all the way round. Small sets can come back in a single page whatever
`count` says.

`next()` is fallible because every page is a network read: a dropped
connection, a timeout or a server error on page 5 comes back as a
`RedisError`, never a panic. That is why the loop is written `for tag of
it?` and sits in a function that returns `()!`; the error leaves the loop the
way `?` does anywhere else.

A scan is not a snapshot: a member added or removed while you iterate may or
may not be seen, and a member can be returned more than once. If you need a
consistent view, use `members()` or run the work in a transaction. There is no
queued version of `scan()`, because a cursor is several round trips and a
pipeline's `Future` only ever resolves one.

## Pipelines and transactions

Every method above except `scan` also exists on the queued view
`pipeline.sset(key)` and `tx.sset(key)`, returning a `Future` instead of the
value:

```bit
import { open, Future } from "redis"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let p = r.pipeline()
  let tags = p.sset("article:3:tags")
  let added = tags.add("bit", "redis")
  let size = tags.len()
  let known = tags.has("bit")
  p.exec()?
  println("${added.get()?} added, ${size.get()?} in the set, bit: ${known.get()?}")

  let count = r.transaction<Future<i64>>(["article:3:tags"], (tx) => {
    tx.sset("article:3:tags").add("howto")
    return tx.sset("article:3:tags").len()
  })?
  println("${count.get()?} tags after the transaction")
  r.close()
  return
}
```

## Reading a set inside a transaction

`tx.sset(key)` only queues, so it cannot answer "is this member already
there?" before you decide what to write. `tx.read.sset(key)` is the immediate
view of the same set, run now on the transaction's own connection, between
`WATCH` and `MULTI`. If another client changes a watched key first, the
transaction retries and your body runs again with fresh reads:

```bit
import { open } from "redis"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let key = "article:3:tags"
  r.transaction<()>([key], (tx) => {
    if (!tx.read.sset(key).has("howto")?) {
      tx.sset(key).add("howto")
    }
    return
  })?
  r.close()
  return
}
```

Use `tx.read` only for reads. A write such as `tx.read.sset(key).add(...)`
would run immediately, outside the transaction's `MULTI`/`EXEC`, so it fails
with `RedisError.Invalid`; queue it with `tx.sset(key)`.

## Sharp edges

- `pop` and `random` always send a count, so even `pop()` returns a list
  of one, not a bare string. An empty set gives an empty list.
- A missing key behaves as an empty set everywhere: `members()` is `[]`,
  `len()` is `0`, `has` is `false`. `add` creates the key and removing the
  last member deletes it.
- Members are strings. Store numbers as their text form, and compare them
  that way.
- Using a set command on a key that holds another type (a string, a hash)
  fails with a `RedisError` carrying the server's `WRONGTYPE` message.

## Next

See [Hashes](hashes.md) for field/value records, [Strings and keys](strings-and-keys.md)
for `del` and key expiry, and [Connecting](connecting.md) for pool sizing,
timeouts and TLS.
