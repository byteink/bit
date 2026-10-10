# Seen, trending and percentiles

<!-- doctest: per-block -->

Inkwell's game side has three questions that grow with its player count.
"Has this player been seen before?" is a set lookup, and the set gets big.
"Who are the top players this hour?" is a counter per player, and most of
them are never read. "What is the p99 latency of a move?" is a sort of every
latency you ever recorded. Redis 8 has a structure for each, built in. They
trade a small, known error for a fixed amount of memory:

- a **Bloom filter** (`r.bloom(key)`) answers "seen?" with no false negatives
  and a false-positive rate you choose;
- a **cuckoo filter** (`r.cuckoo(key)`) answers the same and can also forget
  an item;
- a **count-min sketch** (`r.cms(key)`) counts items, never undercounting;
- a **top-k** (`r.topk(key)`) keeps the k most frequent items;
- a **t-digest** (`r.tdigest(key)`) answers percentile questions about a
  stream of numbers.

```bit
import { open, BloomGrowth, counted } from "redis"

fn main(): ()! {
  let r = open("redis://localhost:6379")?

  let seen = r.bloom("game:seen")
  seen.reserve(0.01, 100000, BloomGrowth.Expansion(2))?
  let first = seen.add("ana")?
  println("new player: ${first}") // true

  let hour = r.topk("game:top:hour")
  hour.reserve(3)?
  hour.incrBy([counted("ana", 40), counted("bo", 25), counted("cy", 12)])?
  for entry of hour.list()? {
    println("${entry.item} ${entry.count}") // ana 40, bo 25, cy 12
  }

  let latency = r.tdigest("game:move:ms")
  latency.create()?
  latency.add(12.0, 15.0, 11.0, 240.0)?
  let p = latency.quantile(0.5, 0.99)?
  println("p50 ${p[0]} p99 ${p[1]}")
  r.close()
  return
}
```

The five accessors are cheap values, `{runner, key}`: call them again any
time you need the same key. All five answer in a pipeline and a transaction
(`p.bloom(key)`, `tx.topk(key)`, ...) with a `Future` per call, and
`tx.read.bloom(key)` reads inside a transaction. The structures are only
read-safe there; a write through `tx.read` is refused and you queue it with
`tx.<family>(key)`.

## Has this player been seen

A Bloom filter has a size, so you ask for it: `reserve(errorRate, capacity,
growth)` is `BF.RESERVE`. `errorRate` is the false-positive probability (0.01
is one in a hundred), `capacity` the number of items you expect. When the
filter fills, `BloomGrowth` says what happens: `Default` leaves it to the
server, `Expansion(n)` adds a sub-filter `n` times the last one, `NonScaling`
refuses to grow and makes adding past the capacity an error.

`add(item)` is `BF.ADD` and answers true when the item was new, false when it
was probably there already. `addMany(...items)` is `BF.MADD`, one answer per
item. `exists(item)` and `existsMany(...items)` ask without adding: false is
certain, true is "probably". `card()` is how many distinct items were added.

`insert(items, opts)` is `BF.INSERT`: `addMany` that creates the filter with
your own settings when the key is missing. `BloomInsertOptions` holds the
`capacity`, the `errorRate`, the `growth` and `noCreate`, which makes a
missing key the server's error instead.

```bit
import { open, BloomGrowth, BloomInsertOptions } from "redis"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let seen = r.bloom("game:seen:today")

  let opts = BloomInsertOptions{
    capacity = Option.Some(50000),
    errorRate = Option.Some(0.001),
    growth = BloomGrowth.NonScaling,
  }
  let fresh = seen.insert(["ana", "bo", "ana"], opts)?
  println("${fresh[0]} ${fresh[1]} ${fresh[2]}") // true true false

  let known = seen.existsMany("ana", "zed")?
  println("${known[0]} ${known[1]}")   // true false
  println("distinct: ${seen.card()?}") // 2

  let info = seen.info()?
  println("${info.items} of ${info.capacity}, ${info.filters} filter") // 2 of 50000
  match (info.expansion) {
    Some(n) => println("grows by ${n}")
    None => println("fixed size") // a non-scaling filter
  }
  r.close()
  return
}
```

`info()` is `BF.INFO` as a `BloomInfo`: `capacity`, `size` (bytes),
`filters`, `items` and `expansion`, which is `None` for a non-scaling filter.
The one-field form of `BF.INFO` is not wired; `info()` costs the same round
trip.

`scanDump(iterator)` and `loadChunk(iterator, data)` copy a filter, for a
backup or a move. Start at iterator 0; each `ScanChunk` has the next
`iterator` and some `data`. Hand both to `loadChunk` on the destination, and
stop when the iterator comes back 0.

```bit
import { open } from "redis"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let from = r.bloom("game:seen")
  let to = r.bloom("game:seen:copy")
  let it = 0
  while (true) {
    let chunk = from.scanDump(it)?
    if (chunk.iterator == 0) {
      break
    }
    to.loadChunk(chunk.iterator, chunk.data)?
    it = chunk.iterator
  }
  r.close()
  return
}
```

## Banned players: a filter that forgets

A Bloom filter cannot remove an item. When players get unbanned you want a
cuckoo filter. `reserve(capacity, opts)` is `CF.RESERVE`; the
`CuckooReserveOptions` are `bucketSize`, `maxIterations` and `expansion`, each
`None` for the server's default.

`add(item)` is `CF.ADD`: it stores the item again even if it is there (that is
what `count(item)` counts), and fails when the filter is full.
`addIfMissing(item)` is `CF.ADDNX` and answers true only when it stored.
`insert(items, opts)` and `insertIfMissing(items, opts)` are `CF.INSERT` and
`CF.INSERTNX` for several at once, with `CuckooInsertOptions` (`capacity`,
`noCreate`). Each item gets a `CuckooInsert`: `Added`, `Exists` (only
`insertIfMissing`) or `Full`, so a full filter is a value you can count, not a
crash halfway through.

`exists`, `existsMany`, `delete(item)` (`CF.DEL`, one copy, false when it
was not there) and `count(item)` read and remove. `info()` is a `CuckooInfo`.
`scanDump` and `loadChunk` work as for the Bloom filter.

```bit
import { open, CuckooReserveOptions, CuckooInsertOptions, CuckooInsert } from "redis"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let banned = r.cuckoo("game:banned")
  banned.reserve(10000, CuckooReserveOptions{ bucketSize = Option.Some(4) })?

  banned.add("mallory")?
  let added = banned.insertIfMissing(
    ["mallory", "trent"],
    CuckooInsertOptions{ capacity = Option.Some(10000) },
  )?
  match (added[0]) {
    Exists => println("mallory was banned already")
    _ => println("banned again")
  }
  println("trent banned: ${added[1] == CuckooInsert.Added}") // true

  let unbanned = banned.delete("mallory")?
  println("unbanned: ${unbanned}")                      // true
  println("still there: ${banned.exists("mallory")?}")  // false
  println("copies of trent: ${banned.count("trent")?}") // 1

  let info = banned.info()?
  println("${info.items} items, ${info.deleted} deleted, bucket ${info.bucketSize}")
  banned.addIfMissing("eve")?
  r.close()
  return
}
```

## How often, without a counter per player

A count-min sketch is a grid of counters: a width and a depth.
`create(size)` is `CMS.INITBYDIM` or `CMS.INITBYPROB`, one call with a
`CmsSize`: `Dims(width, depth)` sets the grid, `Bounds(error, probability)`
asks for an overestimate of at most `error` times the total with probability
`1 - probability`. `incrBy(items)` takes `Counted` pairs (`counted("ana", 3)`
builds one) and returns the new estimates, `query(...items)` reads them.
An estimate is never below the truth.

`merge(sources)` is `CMS.MERGE`: this sketch becomes the weighted sum of the
`CmsSource` list, each a key and a weight (1 by default). All of them need the
same width and depth. `info()` is a `CmsInfo` with the grid and the `count`
of every increment.

```bit
import { open, CmsSize, CmsSource, counted } from "redis"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let monday = r.cms("game:plays:mon")
  let tuesday = r.cms("game:plays:tue")
  let week = r.cms("game:plays:week")
  for sketch of [monday, tuesday, week] {
    sketch.create(CmsSize.Dims(2000, 7))?
  }
  monday.incrBy([counted("ana", 30), counted("bo", 4)])?
  tuesday.incrBy([counted("ana", 12)])?

  week.merge([CmsSource{ key = "game:plays:mon" }, CmsSource{ key = "game:plays:tue", weight = 2 }])?
  let est = week.query("ana", "bo", "zed")?
  println("${est[0]} ${est[1]} ${est[2]}") // 54 4 0

  let info = week.info()?
  println("${info.width} x ${info.depth}, ${info.count} increments")

  let sized = r.cms("game:plays:exact")
  sized.create(CmsSize.Bounds(0.001, 0.01))?
  r.close()
  return
}
```

## The top players this hour

A top-k keeps only the `k` most frequent items. `reserve(k, shape)` is
`TOPK.RESERVE`; a `TopKShape.Sized(width, depth, decay)` sets the counter
grid and the decay applied to a counter that loses its slot, `Default` leaves
it to the server. `add(...items)` counts each once and `incrBy(items)` adds a
count per item; both answer, per item, the item they pushed out of the top k,
or `None`. `query(...items)` says whether each is in the top k now,
`count(...items)` estimates a count, and `list()` is the current top k, most
frequent first, each with its count (`TOPK.LIST WITHCOUNT`; the plain item
list is `.item` off each entry). `info()` is a `TopKInfo`.

```bit
import { open, TopKShape, counted } from "redis"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let hour = r.topk("game:top:14h")
  hour.reserve(3, TopKShape.Sized(64, 5, 0.9))?

  let out = hour.add("ana", "bo", "cy", "di")?
  for pushed of out {
    match (pushed) {
      Some(name) => println("${name} fell out of the top 3")
      None => println("room left")
    }
  }
  hour.incrBy([counted("ana", 40), counted("di", 25)])?

  let in3 = hour.query("ana", "zed")?
  println("${in3[0]} ${in3[1]}") // true false
  let n = hour.count("ana")?
  println("ana about ${n[0]}")
  for entry of hour.list()? {
    println("${entry.item}: ${entry.count}")
  }
  let info = hour.info()?
  println("top ${info.k}, ${info.width} x ${info.depth}, decay ${info.decay}")
  r.close()
  return
}
```

## The p99 of a move

A t-digest keeps a few KB however many numbers you feed it, and is most exact
at the extremes, where latency questions live. `create(compression)` is
`TDIGEST.CREATE` (`None` is the server's 100; more is more exact and bigger),
`add(...values)` feeds it, `reset()` empties it.

`quantile(...fractions)` is the value at each fraction, so `quantile(0.99)` is
the p99. `cdf(...values)` is the reverse: the share of values at or below
each. `rank(...values)` counts the values below each one, `revRank` from the
top, and `byRank(...ranks)` / `byRevRank(...ranks)` return the value at a
rank. `min()` and `max()` are the extremes and `trimmedMean(low, high)` the
mean between two fractions, outliers cut.

An empty digest is not an error: `quantile`, `cdf`, `min`, `max` and
`trimmedMean` answer NaN (it is the only number that is not equal to itself,
so test `x != x`), and `rank` answers -2. A rank past the data gives
infinity from `byRank`. `merge(sources, opts)` folds other digests into this
key; `TDigestMergeOptions` has the result's `compression` and `overwrite` to
replace what the key held. `info()` is a `TDigestInfo`.

```bit
import { open, TDigestMergeOptions } from "redis"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let eu = r.tdigest("game:move:ms:eu")
  let us = r.tdigest("game:move:ms:us")
  let all = r.tdigest("game:move:ms")
  eu.create(Option.Some(200))?
  us.create()?
  all.create()?
  eu.add(12.0, 15.0, 11.0, 240.0, 14.0)?
  us.add(30.0, 33.0, 29.0)?

  let slow = eu.quantile(0.5, 0.99)?
  println("eu p50 ${slow[0]} p99 ${slow[1]}")
  let share = eu.cdf(20.0)?
  println("${share[0]} of eu moves took 20 ms or less")
  let below = eu.rank(20.0)?
  let top = eu.byRevRank(0)?
  println("${below[0]} faster, the slowest was ${top[0]}")
  println("trimmed mean ${eu.trimmedMean(0.1, 0.9)?}, ${eu.min()?} to ${eu.max()?}")

  all.merge(
    ["game:move:ms:eu", "game:move:ms:us"],
    TDigestMergeOptions{ compression = Option.Some(100) },
  )?
  let info = all.info()?
  println("${info.observations} moves, ${info.memoryUsage} bytes")
  let empty = us.revRank(1.0, 99.0)?
  println("${empty[0]} ${empty[1]}")
  let ranked = us.byRank(0)?
  println("${ranked[0]}")
  us.reset()?
  all.merge(["game:move:ms:eu"], TDigestMergeOptions{ overwrite = true })?
  r.close()
  return
}
```

## Where to go next

[Locations, unique counts and bitmaps](geo-hll-bitmaps.md) covers the other
approximate type, the HyperLogLog. [Commands](commands.md) lists the rest of
the method surface.
