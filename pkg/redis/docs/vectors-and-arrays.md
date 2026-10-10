# Similar players and per-round scores

<!-- doctest: per-block -->

Inkwell's game side wants two things a sorted set does badly. "Who plays like
ana?" is a nearest-neighbour question over a vector of numbers per player:
win rate, speed, how often they open with the same move. And "what did ana
score in round 7 of this game?" is a list you write at an arbitrary position,
where most positions are empty. Redis 8 has a type for each:

- a **vector set** (`r.vset(key)`) stores named vectors and finds the closest
  ones, optionally only among elements whose JSON attributes match a filter;
- an **array** (`r.array(key)`) is a sparse sequence addressed by a `u64`
  index, with an append cursor and a ring-buffer mode.

```bit
import { open, Vec, SimilarTo, SimilarOptions } from "redis"

fn main(): ()! {
  let r = open("redis://localhost:6379")?

  let players = r.vset("game:players")
  players.add("ana", Vec.Values([0.9, 0.1, 0.4]))?
  players.add("bo", Vec.Values([0.8, 0.2, 0.5]))?
  players.add("cy", Vec.Values([0.1, 0.9, 0.2]))?
  let hits = players.similar(SimilarTo.Element("ana"), SimilarOptions{})?
  for hit of hits {
    println("${hit.element} ${hit.score}") // ana 1, bo 0.99, cy 0.64 (Q8 rounds, so about)
  }

  let rounds = r.array("game:7:scores")
  rounds.set(u64(0), "12", "9", "30")?
  rounds.set(u64(1000000), "41")?
  println("${rounds.count()?} rounds played, last index ${rounds.length()? - u64(1)}")
  r.close()
  return
}
```

Both accessors are cheap values, `{runner, key}`. Both answer in a pipeline and
a transaction (`p.vset(key)`, `tx.array(key)`) with a `Future` per call, and
`tx.read.vset(key)` / `tx.read.array(key)` read inside a transaction; a write
through `tx.read` is refused, queue it with `tx.vset(key)`.

## Storing vectors

`add(element, vector, opts)` is `VADD`. It answers true when the element is
new and false when it existed and its vector was replaced. The vector is a
`Vec`: `Vec.Values([]f32)` for floats, `Vec.Fp32(blob)` for the raw
little-endian float32 bytes when you already have them.

`VectorAddOptions` holds the rest of `VADD`. `quant` is how the set stores
vectors, fixed when it is created: `VecQuant.Q8` (the server's default, one
byte per component), `VecQuant.NoQuant` (full floats, the most exact) or
`VecQuant.Bin` (one bit per component, the smallest). `reduce` projects every
vector down to that many dimensions at creation, `m` and `ef` tune the graph
the search walks (links per node, build effort), and `cas` runs the costly
part of the insert on a background thread.

`card()` is `VCARD`, `dim()` is `VDIM` (after any `reduce`), `isMember(e)` is
`VISMEMBER` and `remove(e)` is `VREM`. `emb(e)` is `VEMB`: the stored vector
as `[]f32`, de-quantized, or `None` for a missing element. `embRaw(e)` is
`VEMB ... RAW`: the quantization name, the bytes, the norm the vector had and,
for Q8, its range. `info()` is `VINFO` as a `VectorSetInfo`.

```bit
import { open, Vec, VecQuant, VectorAddOptions } from "redis"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let players = r.vset("game:players:exact")
  let opts = VectorAddOptions{ quant = VecQuant.NoQuant, m = Option.Some(16) }
  let fresh = players.add("ana", Vec.Values([0.9, 0.1, 0.4]), opts)?
  println("new: ${fresh}, ${players.card()?} player, ${players.dim()?} dimensions")

  match (players.emb("ana")?) {
    Some(v) => println("ana ${v[0]} ${v[1]} ${v[2]}")
    None => println("no ana")
  }
  match (players.embRaw("ana")?) {
    Some(raw) => println("${raw.quant}, ${len(raw.blob)} bytes, norm ${raw.norm}")
    None => println("no ana")
  }
  match (players.info()?) {
    Some(info) => println("${info.quantType}, ${info.size} elements, M ${info.hnswM}")
    None => println("no set")
  }
  println("member: ${players.isMember("ana")?}")
  players.remove("ana")?
  r.close()
  return
}
```

## Finding the closest

`similar(to, opts)` is `VSIM`. `to` is a `SimilarTo`: `Element(name)` for the
neighbours of a stored element, `Values([]f32)` or `Fp32(blob)` for a vector
you have in hand. The answer is a `[]Similar`, best first. Each `Similar` has
its `element` and its `score`, 1 for identical down to 0 for opposite; scores
are always requested, so there is no second call to get them. An element the
set does not hold is the server's error.

`SimilarOptions` is the rest of `VSIM`: `count` (10 by default), `epsilon`
(drop hits whose distance exceeds it, so `0.2` keeps scores above 0.8), `ef`
(search effort), `truth` (an exact scan instead of the graph, to measure how
good the approximation is) and `noThread` (keep the search on the main
thread). `withAttrs` fills `Similar.attrs` with each hit's attribute text.

```bit
import { open, Vec, SimilarTo, SimilarOptions } from "redis"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let players = r.vset("game:players")
  players.add("ana", Vec.Values([0.9, 0.1, 0.4]))?
  players.add("bo", Vec.Values([0.8, 0.2, 0.5]))?

  let close = players.similar(
    SimilarTo.Values([0.9, 0.1, 0.4]),
    SimilarOptions{ count = Option.Some(1), ef = Option.Some(100) },
  )?
  println("closest: ${close[0].element}")

  let tight = players.similar(
    SimilarTo.Element("ana"),
    SimilarOptions{ epsilon = Option.Some(0.1), truth = true, noThread = true },
  )?
  println("${len(tight)} players within 0.1")
  r.close()
  return
}
```

## Attributes and filters

An element can carry a JSON object, and `similar` can keep only the elements
whose attributes satisfy an expression. Store it with `setAttr(element,
value)`, which takes any `@json` class, or with `jsonAttrs(value)` into
`VectorAddOptions.attrs` when you add. `attr<T>(element)` reads it back into a
`T`; `attrJson(element)` and `setAttrJson(element, text)` are the same with the
text, and an empty text clears it. `setAttr` answers false for a missing
element.

The filter is `vattr(name)` plus a test: `is(text)` and `isNot(text)` for
strings; `eq`, `ne`, `gt`, `ge`, `lt`, `le` for numbers; `oneOf(...texts)` and
`has(text)` for a value in a list, or a list holding a value. Join tests with
`and`, `or` and `not`; they parenthesize for you. For anything else
(arithmetic, `%`), `rawVFilter(expr)` is the server's own expression.
`filterEf` caps how many candidates the filter may inspect before `similar`
gives up and returns what it has.

```bit
import {
  open, Vec, SimilarTo, SimilarOptions, jsonAttrs, vattr, rawVFilter, VectorAddOptions,
} from "redis"

@json class Player {
  team: string,
  level: i64,
}

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let players = r.vset("game:players:team")
  let ana = VectorAddOptions{ attrs = Option.Some(jsonAttrs(Player{ team = "red", level = 7 })) }
  players.add("ana", Vec.Values([0.9, 0.1, 0.4]), ana)?
  players.add("bo", Vec.Values([0.8, 0.2, 0.5]))?
  players.setAttr("bo", Player{ team = "blue", level = 3 })?

  let back = players.attr<Player>("bo")?
  println("bo is ${unwrap(back).team}")
  println(unwrap(players.attrJson("ana")?))

  let veterans = vattr("team").is("red").and(vattr("level").ge(5.0))
  let hits = players.similar(
    SimilarTo.Element("bo"),
    SimilarOptions{ filter = Option.Some(veterans), withAttrs = true, filterEf = Option.Some(200) },
  )?
  for hit of hits {
    println("${hit.element} ${hit.score} ${unwrapOr(hit.attrs, "")}")
  }

  let even = rawVFilter(".level % 2 == 1")
  let odd = players.similar(SimilarTo.Element("bo"), SimilarOptions{ filter = Option.Some(even) })?
  println("${len(odd)} players on an odd level")
  r.close()
  return
}
```

## Looking inside the graph

`links(element)` is `VLINKS`: the element's neighbours in the search graph,
one list per level, level 0 first; `linksScored(element)` adds each
neighbour's similarity as a `Scored`. `randomMember()` is `VRANDMEMBER`: one
element, `None` for an empty set, and `randomMembers(count)` several; a
negative count returns that many and may repeat elements.

```bit
import { open } from "redis"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let players = r.vset("game:players")
  match (players.links("ana")?) {
    Some(levels) => println("${len(levels[0])} neighbours at level 0")
    None => println("no ana")
  }
  match (players.linksScored("ana")?) {
    Some(levels) => println("${levels[0][0].member} ${levels[0][0].score}")
    None => println("no ana")
  }
  println("${unwrap(players.randomMember()?)}, ${len(players.randomMembers(-5)?)} samples")
  r.close()
  return
}
```

## Per-round scores in an array

An array is a list you can write anywhere. `set(index, ...values)` is `ARSET`:
it stores the values at `index`, `index + 1`, ... and answers how many it set.
`mset(...entries)` is `ARMSET`, an `ArEntry{index, value}` per slot. Reading
is `get(index)` and `mget(...indexes)`; a slot nothing was written to is
`None`, never an empty string. `getRange(start, end)` reads every slot between
two indexes inclusive, and backwards when `start > end`.

Indexes are `u64`, 0 through 2^64-2, and `length()` (`ARLEN`) is the highest
index plus one, so it can exceed what an `i64` holds: it is a `u64` too.
`count()` (`ARCOUNT`) is how many slots hold a value. `del(...indexes)` and
`delRange(...ranges)` (an `ArRange{start, end}` each) empty slots and answer
how many held a value.

`scan(start, end, limit)` is `ARSCAN`: the filled slots as `ArEntry`s, so a
sparse array is walked without visiting the holes.

```bit
import { open, ArEntry, ArRange } from "redis"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let rounds = r.array("game:8:scores")
  rounds.set(u64(0), "12", "9", "30")?
  rounds.mset(ArEntry{ index = u64(10), value = "44" }, ArEntry{ index = u64(11), value = "7" })?

  let one = rounds.get(u64(1))?
  let hole = rounds.get(u64(5))?
  println("${unwrap(one)} ${isNone(hole)}") // 9 true
  let three = rounds.mget(u64(0), u64(5), u64(2))?
  println("${len(three)} answers, the second is empty: ${three[1] == Option.None}")
  let back = rounds.getRange(u64(3), u64(0))?
  println("${len(back)} slots, newest index first")

  for entry of rounds.scan(u64(0), u64(100), Option.Some(3))? {
    println("round ${entry.index}: ${entry.value}")
  }
  println("${rounds.count()?} filled of ${rounds.length()?}")
  rounds.del(u64(0), u64(1))?
  rounds.delRange(ArRange{ start = u64(10), end = u64(11) })?
  r.close()
  return
}
```

## An append log, and a ring of recent scores

`insert(...values)` is `ARINSERT`: it writes at the array's cursor and answers
the index of the last value. `next()` (`ARNEXT`) is where the next insert
lands and `seek(index)` (`ARSEEK`) moves the cursor, which can be anywhere up
to 2^64-2. `lastItems(count, rev)` (`ARLASTITEMS`) returns the most recent
inserts, oldest first, or newest first with `rev`.

`ring(size, ...values)` is `ARRING`: the same append, but inside a window of
`size` slots, overwriting the oldest. It is the "last N scores" structure
with no trimming command.

```bit
import { open } from "redis"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let log = r.array("game:7:moves")
  let last = log.insert("e4", "e5", "Nf3")?
  println("last index ${last}, next ${log.next()?}")
  log.seek(u64(1))?
  log.insert("c5")?
  let oldest = log.lastItems(2)?
  let newest = log.lastItems(2, true)?
  println("oldest first ${unwrap(oldest[0])} ${unwrap(oldest[1])}")
  println("newest first ${unwrap(newest[0])} ${unwrap(newest[1])}")

  let recent = r.array("game:7:recent")
  recent.ring(3, "12", "9", "30", "44", "7")?
  let window = recent.getRange(u64(0), u64(2))?
  println("the window holds ${unwrap(window[0])} ${unwrap(window[1])} ${unwrap(window[2])}")
  r.close()
  return
}
```

## Searching and totalling

`grep(start, end, preds, opts)` is `ARGREP`: the indexes in a range whose value
satisfies the predicates, `grepValues` the same with the values. A predicate
is `ArPred.Exact(text)` (the whole value), `Match(text)` (a substring),
`Glob(pattern)` or `Re(regex)`. `ArGrepOptions` joins several predicates with
`combine` (`ArCombine.And` or `Or`), caps the answer with `limit` and ignores
case with `noCase`.

`aggregate(start, end, op)` is `AROP`: `ArOp.Sum`, `Min`, `Max` over numeric
values, `And`, `Or`, `Xor` over integers, `Match(text)` counts the values
equal to `text` and `Used` counts the filled slots. The answer is an `ArAgg`:
`Int`, `Float`, or `Empty` for a range with no `Min` or `Max`.

`info(full)` is `ARINFO` as an `ArInfo`; `full = true` adds the slice
statistics (`ArInfoFull`).

```bit
import { open, ArPred, ArGrepOptions, ArCombine, ArOp } from "redis"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let notes = r.array("game:7:notes")
  notes.set(u64(0), "fork", "Pin", "skewer", "pawn")?
  let hits = notes.grep(
    u64(0),
    u64(3),
    [ArPred.Glob("*k*"), ArPred.Exact("pawn")],
    ArGrepOptions{ combine = ArCombine.Or, limit = Option.Some(5), noCase = true },
  )?
  println("${len(hits)} notes match")
  for entry of notes.grepValues(u64(0), u64(3), [ArPred.Match("in")])? {
    println("${entry.index}: ${entry.value}")
  }

  let scores = r.array("game:7:totals")
  scores.set(u64(0), "12", "9", "30")?
  match (scores.aggregate(u64(0), u64(2), ArOp.Sum)?) {
    Int(n) => println("total ${n}")
    Float(f) => println("total ${f}")
    Empty => println("no scores")
  }
  let info = scores.info(true)?
  println("${info.count} filled, length ${info.len}, slices ${info.slices}")
  r.close()
  return
}
```

## Sharp edges

- Vector sets need Redis 8.0 or later and arrays 8.8 or later; an older server
  answers `unknown command`, surfaced as `RedisError.Server`.
- The search is approximate. `truth = true` runs the exact scan, slower, for
  checking recall.
- A set's quantization and `M` are fixed by its first `add`; a later `add`
  that asks for another is the server's error ("asked M value mismatch").
- `VDIM` on a missing key and `ARINFO` on a missing key are server errors;
  `VCARD`, `ARCOUNT` and `ARGET` answer 0 or `None`.
- `ARSET` at index 2^64-1 is refused; the highest index is 2^64-2.

## Where to go next

[Seen, trending and percentiles](probabilistic.md) covers the other
Redis 8 data structures. [Commands](commands.md) lists the method surface.
