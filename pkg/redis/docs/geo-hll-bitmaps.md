# Locations, unique counts and bitmaps

<!-- doctest: per-block -->

Inkwell is growing three small features, and each one is awkward with the
commands you already have. Writers want to find other writers nearby for a
meetup: a sorted set of names has no idea what "within 30 km" means. The
article page wants to say "1,204 readers", counting each person once: a set of
every reader id costs memory for every reader, forever. The dashboard wants
"who read something today, and who read something every day this week": a set
per day answers it, at a hundred times the size.

Redis has a type for each. **Geospatial** keys store places and search by
distance. A **HyperLogLog** counts distinct things in 12 KB, with an error of
under one percent. A **bitmap** is a string used as a row of bits, one per
reader id, and bit arithmetic across rows answers the dashboard.

```bit
import { open, place, GeoFrom, GeoBy, GeoUnit } from "redis"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let writers = r.geo("inkwell:writers")
  writers.add([place("ana", 13.405, 52.52), place("bo", 13.0645, 52.3989)])?

  let near = writers.search(GeoFrom.Member("ana"), GeoBy.Radius(30.0, GeoUnit.Kilometers))?
  for hit of near {
    println(hit.member) // ana, bo
  }
  r.close()
  return
}
```

`r.geo(key)`, `r.hll(key)` and `r.bitmap(key)` are cheap values, `{client,
key}`: call them again any time you need the same key.

## Writers near you

`add(members, opts)` is `GEOADD`: a list of `GeoMember`, each a name and a
`Point{ lon, lat }`. `place(name, lon, lat)` builds one without the class
literal. It returns how many members were new; a member added again is moved.

A coordinate the server cannot store never leaves your program. Longitude
runs from -180 to 180 and latitude from -85.05112878 to 85.05112878; anything
else, or a NaN, fails `RedisError.Invalid` naming the value and the range, and
nothing is sent, not even the valid members next to it. Everything else the
server refuses still reaches you as the server's own error.

`GeoAddOptions` has the three `GEOADD` flags. `nx` adds only members that are
not there yet, `xx` updates only members that are, and `ch` makes the answer
count moved members as well as new ones.

```bit
import { open, place, GeoAddOptions } from "redis"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let writers = r.geo("inkwell:writers")
  writers.add([place("ana", 13.405, 52.52)])?

  // ana moved: the plain call counts 0 new members, ch counts the move.
  let moved = writers.add([place("ana", 13.5, 52.6)], GeoAddOptions{ ch = true })?
  println("${moved} changed") // 1

  // A new writer only counts when they are not there yet.
  let fresh = writers.add(
    [place("ana", 0.0, 0.0), place("cy", 9.99, 53.55)],
    GeoAddOptions{ nx = true },
  )?
  println("${fresh} added") // 1, ana stayed where she was
  r.close()
  return
}
```

Reading a place back: `pos(...members)` gives an `Option<Point>` per name,
`None` for one that is not there. `dist(a, b, unit)` is the distance between
two members, `None` when either is missing, in a `GeoUnit`: `Meters` (the
default), `Kilometers`, `Feet` or `Miles`. `hash(...members)` is the standard
11 character geohash, handy as a short cell name in a URL or a cache key.

```bit
import { open, GeoUnit } from "redis"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let writers = r.geo("inkwell:writers")

  let spots = writers.pos("ana", "nobody")?
  match (spots[0]) {
    Some(p) => println("ana is at ${p.lat}, ${p.lon}")
    None => println("ana has not told us")
  }
  println("${isNone(spots[1])}") // true

  match (writers.dist("ana", "bo", GeoUnit.Kilometers)?) {
    Some(km) => println("${km} km apart") // about 26.7
    None => println("one of them is not on the map")
  }
  println(unwrap(writers.hash("ana")?[0])) // u33dc0cppj0 for Berlin
  r.close()
  return
}
```

## Searching

`search(from, by, opts)` is `GEOSEARCH`. It takes three things, each typed:

- `from` is the centre: `GeoFrom.Member("ana")` for a writer already on the
  map, or `GeoFrom.At(Point{ lon = 13.4, lat = 52.5 })` for wherever the
  visitor is.
- `by` is the shape: `GeoBy.Radius(30.0, GeoUnit.Kilometers)` or
  `GeoBy.Box(width, height, unit)`.
- `opts` is `GeoSearchOptions`. `order` is `GeoOrder.Nearest` (nearest first),
  `Farthest` or `Unsorted`. `count` keeps that many results, and with
  `any = true` the server stops at the first `count` it finds instead of
  looking for the closest. `withDist`, `withHash` and `withCoord` ask for
  extras.

Each result is a `GeoHit`: its `member`, and `dist`, `hash` and `at` filled in
only when you asked for them (`Option`s, `None` otherwise). `dist` is in the
unit of the shape you searched with.

```bit
import {
  open, GeoFrom, GeoBy, GeoUnit, GeoOrder, GeoSearchOptions, GeoHit, Point,
} from "redis"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let writers = r.geo("inkwell:writers")

  // The three nearest writers to a visitor in Berlin, with how far each is.
  let visitor = GeoFrom.At(Point{ lon = 13.4, lat = 52.5 })
  let opts = GeoSearchOptions{ order = GeoOrder.Nearest, count = 3, withDist = true }
  let hits: []GeoHit = writers.search(visitor, GeoBy.Radius(300.0, GeoUnit.Kilometers), opts)?
  for h of hits {
    println("${h.member}: ${unwrap(h.dist)} km")
  }

  // Everyone in a 100 km square, with where they are.
  let square = GeoBy.Box(100.0, 100.0, GeoUnit.Kilometers)
  let located = writers.search(
    visitor,
    square,
    GeoSearchOptions{ withCoord = true, withHash = true },
  )?
  for h of located {
    println("${h.member} at ${unwrap(h.at).lat}, ${unwrap(h.at).lon}, cell ${unwrap(h.hash)}")
  }
  r.close()
  return
}
```

A search that finds nothing is an empty list, not an error. `GeoFrom.Member`
with a name that is not on the map is the server's error, since there is no
centre to search around, and `any = true` without a `count` fails `RedisError.Invalid`, the same
rule the server has.

`searchStore(dest, from, by, opts)` is `GEOSEARCHSTORE`: the same search, with
the result written to another key instead of returned, and the number of
members stored as the answer. Its `GeoStoreOptions` has the same `order`,
`count` and `any`, and `storeDist = true` stores each member's distance as its
score instead of its geohash. That is the way to keep "writers near the
Berlin meetup" for an hour without searching again.

```bit
import { open, GeoFrom, GeoBy, GeoUnit, GeoOrder, GeoStoreOptions } from "redis"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let writers = r.geo("inkwell:writers")

  let opts = GeoStoreOptions{ order = GeoOrder.Nearest, count = 10, storeDist = true }
  let kept = writers.searchStore(
    "inkwell:near:berlin",
    GeoFrom.Member("ana"),
    GeoBy.Radius(50.0, GeoUnit.Kilometers),
    opts,
  )?
  println("${kept} writers kept")

  // With storeDist the result is a sorted set of kilometres.
  let closest = r.zset("inkwell:near:berlin").bottom(1)?
  println("${closest[0].member} is ${closest[0].score} km away")
  r.expire("inkwell:near:berlin", 3600)?
  r.close()
  return
}
```

## Counting unique readers

`add(...elements)` records elements and says whether the estimate changed:
`true` the first time you see someone, `false` for a repeat. `count()` is the
estimated number of distinct elements, and `count(other, ...)` is the number
in the union of this key and the others, counting someone who read both only
once. A missing key counts 0. Adding and counting one article:

```bit
import { open } from "redis"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let readers = r.hll("inkwell:readers:article:41")

  let isNew = readers.add("user:7", "user:9")?
  println("${isNew}")                    // true
  println("${readers.add("user:7")?}")   // false, already counted
  println("${readers.count()?} readers") // 2
  r.close()
  return
}
```

The cost is 12 KB per key at most, however many readers. The price is the
estimate: the standard error is 0.81%, so a count of a million may read
990,000 or 1,010,000. For a handful of elements the answer is exact. An
element cannot be listed or removed afterwards; if you need either, use a set.

`merge(...sources)` is `PFMERGE`. It stores the union of the sources, and of
what the key already held, in this key. Merge each day's counter into a weekly
one and the weekly count is the number of distinct readers, with nobody
counted twice. Merging again later adds to it.

```bit
import { open } from "redis"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  r.hll("inkwell:readers:mon").add("user:1", "user:2", "user:3")?
  r.hll("inkwell:readers:tue").add("user:3", "user:4")?

  // Without storing anything: the union of two days.
  println("${r.hll("inkwell:readers:mon").count("inkwell:readers:tue")?}") // 4

  // Keep the week so far.
  let week = r.hll("inkwell:readers:week")
  week.merge("inkwell:readers:mon", "inkwell:readers:tue")?
  println("${week.count()?} readers this week") // 4
  r.close()
  return
}
```

A key that holds something other than a HyperLogLog (a plain string you set
yourself) fails `RedisError.WrongType` with the server's message.

## Daily active readers

A bitmap treats a string as a row of bits numbered from the left. Give every
reader a small integer id and let it be the bit number: `set(id, true)` marks
that reader, `get(id)` asks, and `set` returns what the bit was before, so one
call both marks the reader and tells you if this is their first visit today.
Ids run from 0 to 4,294,967,295; one outside that range fails
`RedisError.Invalid` before it is sent. Writing bit 1,000,000 makes the string
125 KB long, so keep ids dense.

`count(range)` is `BITCOUNT`, the number of set bits: the number of readers.
`pos(bit, range)` is `BITPOS`, the first bit equal to `bit`: the lowest id of
anyone who read, or the first free id. `BitRange.All` (the default) is the
whole string; `Bytes(start, end)` and `Bits(start, end)` pick a part in that
unit, end included, a negative number counting from the end; `From(start)` is
for `pos` alone.

```bit
import { open, BitRange } from "redis"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let today = r.bitmap("inkwell:active:2026-10-09")

  let seen = today.set(42, true)?
  if (seen) {
    println("back again")
  } else {
    println("first visit today")
  }
  today.set(7, true)?
  println("${today.get(42)?}") // true
  println("${today.get(43)?}") // false

  println("${today.count()?} readers")                                        // 2
  println("lowest id ${today.pos(true)?}")                                    // 7
  println("readers among ids 0 to 15: ${today.count(BitRange.Bytes(0, 1))?}") // 1
  println("in bits 8 to 63: ${today.count(BitRange.Bits(8, 63))?}")           // 1
  println("first id from byte 1: ${today.pos(true, BitRange.From(1))?}")      // 42
  r.close()
  return
}
```

One edge: `pos(false)` on a string of all ones answers one past the end (the length
in bits) when you gave no end, and -1 when you did. That is what makes
`pos(false)` "the first free id" for a full row, and why `BitRange.From(0)` and
`BitRange.Bytes(0, -1)` are not the same thing.

### Combining days

`op(operator, ...sources)` is `BITOP`. The handle's key is where the result
goes; the sources are the keys to combine. It answers the length of the stored
string in bytes. `BitOp` has all eight operators:

| `BitOp` | Bit is set in the result when it is set in... |
| ------- | --------------------------------------------- |
| `And` | every source |
| `Or` | at least one source |
| `Xor` | an odd number of sources |
| `Not` | the single source is clear (a bit flip) |
| `Diff` | the first source and none of the others |
| `Diff1` | at least one other source, but not the first |
| `AndOr` | the first source and at least one of the others |
| `One` | exactly one source |

`Diff`, `Diff1`, `AndOr` and `One` need a server 8.2 or newer; an older one
answers with its own error.

```bit
import { open, BitOp } from "redis"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let mon = "inkwell:active:mon"
  let tue = "inkwell:active:tue"
  let wed = "inkwell:active:wed"
  for id of [1, 2, 3] {
    r.bitmap(mon).set(id, true)?
  }
  for id of [2, 3, 4] {
    r.bitmap(tue).set(id, true)?
  }
  for id of [3, 5] {
    r.bitmap(wed).set(id, true)?
  }

  // Read something every day this week.
  let every = r.bitmap("inkwell:active:all-days")
  every.op(BitOp.And, mon, tue, wed)?
  println("${every.count()?} readers every day") // 1 (id 3)

  // Read on any day.
  let any = r.bitmap("inkwell:active:any-day")
  any.op(BitOp.Or, mon, tue, wed)?
  println("${any.count()?} readers this week") // 5

  // Came on Monday and never came back on Tuesday or Wednesday: churned.
  let gone = r.bitmap("inkwell:active:churned")
  gone.op(BitOp.Diff, mon, tue, wed)?
  println("${gone.count()?} churned") // 1 (id 1)

  // Joined after Monday: seen on a later day, not on Monday.
  let fresh = r.bitmap("inkwell:active:new")
  fresh.op(BitOp.Diff1, mon, tue, wed)?
  println("${fresh.count()?} new") // 2 (ids 4 and 5)

  // Monday readers who also came back later, and readers who came on one day only.
  let back = r.bitmap("inkwell:active:returned")
  back.op(BitOp.AndOr, mon, tue, wed)?
  let once = r.bitmap("inkwell:active:once")
  once.op(BitOp.One, mon, tue, wed)?
  println("${back.count()?} returned, ${once.count()?} came once") // 2, 3

  // Here on exactly one of Monday and Tuesday: ids 1 and 4.
  let swing = r.bitmap("inkwell:active:swing")
  swing.op(BitOp.Xor, mon, tue)?
  println("${swing.count()?} came on one of the two days") // 2

  // Not here on Monday, by flipping the bits.
  let absent = r.bitmap("inkwell:active:absent")
  absent.op(BitOp.Not, mon)?
  println("${absent.get(0)?}") // true, id 0 never read
  r.close()
  return
}
```

`Not` takes exactly one source and flips every bit of its whole bytes, so
the result also sets the unused bits at the end of the last byte; count it
over the ids you actually use. Giving it two sources is the server's error.
The result is as long as the longest source, shorter ones padded with zeros.

### Counters packed into one string

`BITFIELD` reads and writes whole integers of 1 to 64 bits at any bit
position, in one string, atomically. That packs a lot of small counters into
a few bytes. You build the command instead of writing it as text.
`bitfield()` starts an empty `BitFieldOps`. `get(type, at)`, `set(type, at,
value)` and `incrBy(type, at, delta)` each return a longer one, and the
reply is one `Option<i64>` per step, in order: `get` answers the value, `set`
the value that was there before, `incrBy` the new one.

- `type` is `BitType.Unsigned(8)` or `BitType.Signed(16)`: up to 63 bits
  unsigned, 64 signed. Bad widths fail `RedisError.Invalid` when the command
  is sent, not at the call that wrote them.
- `at` is `BitAt.Bit(n)`, bit number `n`, or `BitAt.Slot(n)`, the `n`th
  value of that width, so `Slot(3)` of an 8-bit type is bits 24 to 31.

```bit
import { open, bitfield, BitType, BitAt } from "redis"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let stats = r.bitmap("inkwell:stats:article:41")

  // Three one-byte counters in one three-byte string: views, likes, shares.
  let byteType = BitType.Unsigned(8)
  let counted = bitfield().incrBy(byteType, BitAt.Slot(0), 1).incrBy(byteType, BitAt.Slot(1), 5)
  let ops = counted.get(byteType, BitAt.Slot(2))
  let got = stats.bitfield(ops)?
  println("views ${unwrap(got[0])}, likes ${unwrap(got[1])}, shares ${unwrap(got[2])}")
  r.close()
  return
}
```

A one-byte counter wraps at 255 by default. `overflow(mode)` sets what the
`set` and `incrBy` steps AFTER it do when the value does not fit, with a
`BitOverflow`: `Wrap` goes around, `Sat` stops at the limit, and `Fail`
changes nothing and answers `None` for that step.

```bit
import { open, bitfield, BitType, BitAt, BitOverflow } from "redis"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let stats = r.bitmap("inkwell:stats:article:41")
  let byteType = BitType.Unsigned(8)

  stats.bitfield(bitfield().set(byteType, BitAt.Slot(0), 250))?

  // Saturate: 250 + 10 stops at 255.
  let capped = stats.bitfield(
    bitfield().overflow(BitOverflow.Sat).incrBy(byteType, BitAt.Slot(0), 10),
  )?
  println("${unwrap(capped[0])}") // 255

  // Fail: the counter is full, so the step answers None and nothing changes.
  let refused = stats.bitfield(
    bitfield().overflow(BitOverflow.Fail).incrBy(byteType, BitAt.Slot(0), 1),
  )?
  println("${isNone(refused[0])}") // true

  // Wrap, the default: 255 + 1 goes around to 0.
  let wrapped = stats.bitfield(
    bitfield().overflow(BitOverflow.Wrap).incrBy(byteType, BitAt.Slot(0), 1),
  )?
  println("${unwrap(wrapped[0])}") // 0
  r.close()
  return
}
```

`bitfieldRo(ops)` is `BITFIELD_RO`: the same builder, `get` steps only, safe
to send to a read replica. A `set`, `incrBy` or `overflow` in it fails
`RedisError.Invalid` before anything is sent.

```bit
import { open, bitfield, BitType, BitAt } from "redis"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let stats = r.bitmap("inkwell:stats:article:41")
  let views = stats.bitfieldRo(bitfield().get(BitType.Unsigned(8), BitAt.Slot(0)))?
  println("views ${unwrap(views[0])}")
  r.close()
  return
}
```

## In a pipeline

`p.geo(key)`, `p.hll(key)` and `p.bitmap(key)` on a `Pipeline` (and the same
on `tx` in a transaction) are `GeoBatch`, `HllBatch` and `BitmapBatch`: the
same methods and arguments, each returning a `Future`. A bad coordinate or
offset gives a `Future` that is already failed, so the error shows up when you
read it and nothing is queued. This is how to record a page view in all three
places in one round trip.

```bit
import { open, place, GeoFrom, GeoBy, GeoUnit, BitRange } from "redis"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let p = r.pipeline()
  let seen = p.hll("inkwell:readers:article:41").add("user:7")
  let active = p.bitmap("inkwell:active:2026-10-09").set(7, true)
  let placed = p.geo("inkwell:writers").add([place("ana", 13.405, 52.52)])
  let unique = p.hll("inkwell:readers:article:41").count()
  let today = p.bitmap("inkwell:active:2026-10-09").count(BitRange.All)
  let near = p.geo("inkwell:writers").search(
    GeoFrom.Member("ana"),
    GeoBy.Radius(10.0, GeoUnit.Kilometers),
  )
  p.exec()?
  println("${unique.get()?} unique, ${today.get()?} active, ${len(near.get()?)} writers nearby")
  println("${seen.get()?} ${active.get()?} ${placed.get()?}")
  r.close()
  return
}
```

## Sharp edges

- A geo key is a sorted set. `r.zset(key)` reads it, `TYPE` says `zset`, and a
  plain `zset.add` into it stores a score that is not a geohash, which
  `search` then reads as a place somewhere you did not intend.
- A distance is a great-circle estimate on a sphere, accurate to about 0.5%.
  Good for "who is nearby", not for surveying.
- The 11 character geohash from `hash` is the standard one. The integer in
  `GeoHit.hash` is the server's own 52 bit cell, a different number.
- `count` on a HyperLogLog is an estimate; `count` on a bitmap is exact.
- A bitmap grows to fit the highest bit you write, with zeros between. A
  sparse bitmap with one reader at id 4 billion is 512 MB.
- `BITFIELD` answers `None` only for a refused `incrBy` under
  `BitOverflow.Fail`. `get` and `set` always answer a number.

Where next: [Sorted sets](sorted-sets.md) for a leaderboard keyed by score,
[Sets](sets.md) for exact membership when you need the members back, and
[Strings and keys](strings-and-keys.md) for `expire`, `TYPE` and `SCAN`.
