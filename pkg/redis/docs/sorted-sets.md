# Sorted sets

<!-- doctest: per-block -->

A leaderboard needs three things a plain list or hash cannot give you at
once: every entry stays ordered by score, you can ask "who's in the top
10" without re-sorting anything yourself, and you can ask "where does this
player rank" in one round trip. That is exactly what a Redis sorted set
is - a set of members, each carrying a floating-point score, kept in score
order server-side. `r.zset(key)` is the handle.

```bit
import { open } from "redis"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let board = r.zset("game:board")
  board.add("ada", 1200.0)?
  board.add("grace", 1500.0)?
  board.add("linus", 900.0)?

  let top = board.top(2)?
  for entry of top {
    println("${entry.member}: ${entry.score}")
  }
  r.close()
  return
}
```

`add(member, score)` sets a member's score, creating the set on first use.
`top(n)` is `[]Scored{ member, score }`, highest score first - `Scored` is
shared by every method that returns member/score pairs.

## Growing scores

A leaderboard's whole point is that scores change. `incrBy` adds to a
member's current score (creating it at 0 first if it is new); `card`
answers "how many players are on the board":

```bit
import { open } from "redis"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let board = r.zset("game:board")
  let newScore = board.incrBy("ada", 50.0)?
  println("ada's score is now ${newScore}")
  let players = board.card()?
  println("${players} players on the board")
  r.close()
  return
}
```

`score(member)` reads one member's current score (`Option<f64>`, `None`
for a player not on the board yet); `scores(...members)` reads several at
once, one `Option<f64>` per name, in the order you asked.

`rank(member, fromTop)` answers "where does this player stand", with their
score alongside it in the same round trip:

```bit
import { open } from "redis"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let board = r.zset("game:board")
  let placement = board.rank("ada", true)?
  match (placement) {
    Some(pair) => {
      let (rank, score) = pair
      println("ada is #${rank + 1} with ${score} points")
    }
    None => println("ada is not on the board")
  }
  r.close()
  return
}
```

`fromTop = true` ranks from the highest score down (`ZREVRANK`: rank 0 is
the leader); `false` ranks from the lowest up (`ZRANK`: rank 0 is the
last place).

## Conditional updates

`ZADD`'s options - only add a brand-new player, only raise a score, never
lower one - are a separate call, `addIf`, rather than five more parameters
on `add` itself, so the common call stays two arguments:

```bit
import { open, ZaddOptions } from "redis"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let board = r.zset("game:board")
  // A personal best only updates if the new score is actually higher.
  let changed = board.addIf("ada", 1100.0, ZaddOptions{ onlyIfHigher = true })?
  println("${changed} member(s) changed")
  r.close()
  return
}
```

`ZaddOptions` fields: `nx` (only if absent), `xx` (only if already present),
`onlyIfHigher`/`onlyIfLower` (`GT`/`LT`), `ch` (count updates too, not just
additions). `addMany(...pairs)` sets several members' scores in one round
trip, each a `Scored{ member, score }`. `incr(member, by)` is `ZADD`'s own
`INCR` mode (a second way to raise a score, distinct from `incrBy`'s
`ZINCRBY`, kept for parity with Redis's own command surface).

## Reading a range

Beyond "the top N", a leaderboard page usually wants "everyone scoring at
least 1000", or a specific page of results. `byScore` takes a `Bound<f64>`
for each end - `Inclusive`, `Exclusive` or `Unbounded` - so you can express
an open-ended or exclusive range without a magic sentinel score:

```bit
import { open, Bound, noLimit, limitTo } from "redis"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let board = r.zset("game:board")
  let qualified = board.byScore(Bound<f64>.Inclusive(1000.0), Bound<f64>.Unbounded, noLimit())?
  for entry of qualified {
    println("${entry.member} qualifies with ${entry.score}")
  }
  // Page 2, 10 results per page.
  let page2 = board.byScore(Bound<f64>.Unbounded, Bound<f64>.Unbounded, limitTo(10))?
  println("page 2 starts with ${len(page2)} result(s)")
  r.close()
  return
}
```

`noLimit()`/`limitTo(count)` build a `Limit` - required (not defaulted;
`bit check` refuses a class-typed default parameter value), covering the
two calls you actually need. `Limit{ offset = 20, count = 10 }` reaches any
page directly. `byLex` is the same shape over `Bound<string>`, for members
sharing one score and ordered alphabetically instead - it never returns
scores (Redis's own `BYLEX` restriction), so it answers `[]string`.
`countByScore`/`countByLex` answer just the count, for the same two range
shapes, without transferring every member.

`storeTop`/`storeByScore`/`storeByLex` write a range into ANOTHER sorted
set instead of returning it - a nightly "freeze today's top 100" snapshot:

```bit
import { open } from "redis"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let board = r.zset("game:board")
  let frozen = board.storeTop("game:board:snapshot", 100)?
  println("snapshot holds ${frozen} player(s)")
  r.close()
  return
}
```

## Removing players

`remove(...members)` drops specific players; `removeByRank`,
`removeByScore` and `removeByLex` drop a whole range at once - trimming a
board to its top 1000 by removing everyone ranked below it:

```bit
import { open } from "redis"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let board = r.zset("game:board")
  let trimmed = board.removeByRank(0, 0 - 1001)?
  println("trimmed ${trimmed} player(s) below the top 1000")
  r.close()
  return
}
```

`popMin`/`popMax` remove and return the lowest/highest-scoring members in
one call (`count`, default 1) - useful for draining a board rather than
just reading it. `popMinMany`/`popMaxMany` are the same operation through
`ZMPOP`'s own wire form, for parity with Redis's command surface.

## Waiting for a match

A sorted set doubles as a priority queue: `blockPopMin`/`blockPopMax` wait
(up to `timeoutNs`, `0` for forever) for a member to exist, then pop it -
useful for a "next match to referee" queue ordered by wait time:

```bit
import { open } from "redis"
import { Second } from "std/time"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let queue = r.zset("game:queue")
  let next = queue.blockPopMin(30 * Second)?
  match (next) {
    Some(entry) => println("next up: ${entry.member} (waiting since ${entry.score})")
    None => println("nobody queued within 30s")
  }
  r.close()
  return
}
```

`blockPopMinMany`/`blockPopMaxMany` are the same wait with a `count` (via
`ZMPOP`'s blocking form, `BZMPOP`), for draining several at once.

## Combining boards

`union`/`inter`/`diff` combine several sorted sets into a new result -
merging a daily and weekly leaderboard, or finding players on both:

```bit
import { open, Aggregate } from "redis"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let combined = r.zset("game:board:daily").union(
    ["game:board:weekly"],
    []f64(0),
    Aggregate.Sum,
  )?
  println("${len(combined)} player(s) across both boards")
  let bothDays = r.zset("game:board:daily").inter(["game:board:weekly"], []f64(0), Aggregate.Max)?
  println("${len(bothDays)} player(s) active on both days")
  r.close()
  return
}
```

`interCard(otherKeys, limit)` is `ZINTERCARD`: it counts the players on
every board without building the list, and a positive `limit` stops the
count there, which is enough for "are there at least 10?":

```bit
import { open } from "redis"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let both = r.zset("game:board:daily").interCard(["game:board:weekly"])?
  let atLeastTen = r.zset("game:board:daily").interCard(["game:board:weekly"], 10)?
  println("${both} on both boards, counted up to 10: ${atLeastTen}")
  r.close()
  return
}
```

`weights` scales each input set's scores before combining (`[]f64(0)` for
no weighting); `Aggregate` picks how a member's scores from several sets
combine (`Sum`, `Min` or `Max`). `unionStore`/`interStore`/`diffStore`
write the result into a destination key instead of returning it, the same
way `storeTop` does for a range.

## A random pick and a full scan

`randMember()` picks one member at random (`Option<string>`, `None` for an
empty board); `randMembers(count)` picks several, with their scores:

```bit
import { open } from "redis"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let board = r.zset("game:board")
  let lucky = board.randMembers(3)?
  for entry of lucky {
    println("drew ${entry.member}")
  }
  r.close()
  return
}
```

`scan()` returns a `ZsetScan` - a lazy cursor, safe to iterate over a
board with millions of players without blocking the server the way reading
the whole set at once would:

```bit
import { open } from "redis"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let board = r.zset("game:board")
  let it = board.scan()
  for entry of it? {
    println(entry.member)
  }
  r.close()
  return
}
```

`for entry of it?` calls `it.next(): Option<Scored>!` until it runs out.
A page fetch that fails (network, timeout, server error) comes back as the
error, so the loop returns it from `main` instead of ending early as if the
cursor were exhausted.

## Pipelines and transactions

Every method above has a queued twin on `p.zset(key)`/`tx.zset(key)`
(`Pipeline`/`Tx`, see [Commands](commands.md)), returning a `Future<T>`
instead of running immediately:

```bit
import { open } from "redis"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let p = r.pipeline()
  let topFuture = p.zset("game:board").top(5)
  p.exec()?
  let top = topFuture.get()?
  println("${len(top)} result(s)")
  r.close()
  return
}
```

### Reading the board inside a transaction

A bonus round pays only the players still outside the top three, and it must
decide on the board as it is at that moment. `tx.read.zset(key)` is the same
`Zset` as `r.zset(key)`, bound to the transaction's own connection, so its
reads run now and see the keys the transaction `WATCH`es. The reads are
`score`, `scores`, `rank`, `card`, `countByScore`, `countByLex`, `top`,
`bottom`, `byScore`, `byLex`, `union`, `inter`, `interCard`, `diff`, `randMember`,
`randMembers` and `scan`. The writes you decide on go through
`tx.zset(key)`, which queues them for `EXEC`. If another client changes a
watched key first, the transaction retries and the body runs again with fresh
reads.

```bit
import { open, Future } from "redis"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let key = "game:board"
  let paid = r.transaction<Future<f64>>([key], (tx) => {
    let leaders = tx.read.zset(key).top(3)?
    let bonus = 100.0
    for entry of leaders {
      if (entry.member == "linus") {
        bonus = 0.0
      }
    }
    return tx.zset(key).incrBy("linus", bonus)
  })?
  println("linus now has ${paid.get()?}")
  r.close()
  return
}
```

`tx.read` is for reads only. A write such as `tx.read.zset(key).add(...)` or
`tx.read.zset(key).incrBy(...)` would run immediately, outside the
transaction's `MULTI`/`EXEC`, so it fails with `RedisError.Invalid`; queue it
on `tx.zset(key)` instead. A blocking pop (`blockPopMin` and its kin) fails
the same way, because the pinned connection cannot wait.

## Sharp edges

A missing key behaves like an empty sorted set for every read (`card`
returns `0`, `top`/`byScore`/... return `[]Scored(0)`) and is created on
first write, the same convention every Redis collection type in this
package follows.

`byScore`/`byLex`'s `Bound<T>.Unbounded` picks the right infinity or
open-ended lex marker for whichever end you pass it to - `-inf`/`+inf` for
a score bound, `-`/`+` for a lex bound - so you never need to spell either
by hand.

## Specification

Every method here wraps one Redis command (`ZADD`, `ZRANGE`, `ZPOPMIN`,
`ZUNION`, `ZSCAN`, ...) - see [redis.io's command reference](https://redis.io/docs/latest/commands/)
for the wire-level behavior each one is built on.
