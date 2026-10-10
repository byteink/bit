# Lists

<!-- doctest: per-block -->

Inkwell publishes articles in the background: a writer hits "publish" and the
request returns at once, while a worker renders the page, pings the feeds and
updates the index. The handoff is a queue. You could keep it in a table and
poll it, but then two workers race for the same row and an idle worker burns
queries asking "anything yet?". A Redis list is an ordered sequence of
strings you can add to and take from at either end. Taking from an empty list
can wait for the next item instead of polling, and each item goes to exactly
one worker.

```bit
import { open } from "redis"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let queue = r.list("inkwell:publish")
  let waiting = queue.push("article:41", "article:42")?
  println("${waiting} jobs waiting") // 2

  match (queue.popFront()?) {
    Some(job) => println("publishing ${job}") // article:41
    None => println("nothing to do")
  }
  r.close()
  return
}
```

`r.list(key)` is a cheap value, `{runner, key}` - call it again any time you
need the same list. A list is created by the first push and disappears when
its last element is taken.

## Which end is which

A list reads head to tail, like an array. `push` adds at the tail and `pop`
takes from the tail; `pushFront` and `popFront` work the head. So a queue is
`push` in and `popFront` out, and a stack (an undo history, say) is `push` and
`pop`. Where one call needs to name an end, it takes a `ListEnd`:
`ListEnd.Front` or `ListEnd.Back`.

```bit
import { open } from "redis"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let queue = r.list("inkwell:publish")

  queue.push("article:43", "article:44")?
  // A rush job goes to the head, in front of everything already waiting.
  queue.pushFront("article:99")?

  let all = queue.all()?
  println("${len(all)} queued, first is ${all[0]}") // article:99

  // Only if the list is already there: a retry list nobody created stays absent.
  let retry = r.list("inkwell:publish:retry")
  let added = retry.pushIfExists("article:41")?
  retry.pushFrontIfExists("article:42")?
  println("${added} added to the retry list") // 0, it does not exist
  r.close()
  return
}
```

- `push(...values): i64` - `RPUSH`, adds each value at the tail in order and
  returns the new length.
- `pushFront(...values): i64` - `LPUSH`. Each value goes on the head in turn,
  so `pushFront("a", "b")` leaves `b` first.
- `pushIfExists(...values): i64` and `pushFrontIfExists(...values): i64` -
  `RPUSHX` and `LPUSHX`. They add only when the list already exists and
  return `0`, creating nothing, when it does not. They are separate methods
  because a variadic parameter must be last, so no `bool` option can follow it.

## Taking items out

```bit
import { open } from "redis"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let queue = r.list("inkwell:publish")
  queue.push("a1", "a2", "a3", "a4", "a5")?

  match (queue.popFront()?) {
    Some(job) => println("took ${job}") // a1
    None => println("empty")
  }
  let batch = queue.popFrontMany(2)?
  println("${len(batch)} more: ${batch[0]}, ${batch[1]}") // a2, a3

  let newest = unwrapOr(queue.pop()?, "none")
  println("newest was ${newest}") // a5
  let last = queue.popMany(5)?
  println("${len(last)} left") // 1, asking for more than there is returns what there is
  r.close()
  return
}
```

- `popFront(): Option<string>` and `pop(): Option<string>` - `LPOP` and `RPOP`,
  `Option.None` when the list is empty or missing.
- `popFrontMany(count): []string` and `popMany(count): []string` - the
  `count` form of the same commands, an empty list when there is nothing.

The single and the counted pop are two methods because their results differ
(`Option<string>` against `[]string`), and Bit has no overloading.

### From the first non-empty list

A worker that serves several queues in priority order wants "the first item
from the first list that has one". `popAny` does that over this list and any
others, taking up to `count` items from `end`:

```bit
import { open, ListEnd } from "redis"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let urgent = r.list("inkwell:publish:urgent")
  r.list("inkwell:publish").push("a1", "a2", "a3")?

  let got = urgent.popAny(ListEnd.Front, ["inkwell:publish"], 2)?
  match (got) {
    Some(popped) => println("${popped.key} gave ${len(popped.values)}: ${popped.values[0]}")
    None => println("every queue is empty")
  }
  r.close()
  return
}
```

`popAny(end, others = [], count = 1): Option<PoppedMany>` is `LMPOP`. The
handle's own key is checked first, then `others` in order. A `PoppedMany`
carries `key`, the list that answered, and `values`, what was taken. `None`
means every list was empty.

## Reading

```bit
import { open } from "redis"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let queue = r.list("inkwell:publish")
  queue.push("a1", "a2", "a3", "a4")?

  let size = queue.len()?
  let next = queue.range(0, 1)?
  println("${size} waiting, next two: ${next[0]}, ${next[1]}")

  match (queue.index(-1)?) {
    Some(newest) => println("newest is ${newest}")
    None => println("empty")
  }
  let everything = queue.all()?
  println("${len(everything)} in all")
  r.close()
  return
}
```

- `len(): i64` - `LLEN`, `0` for a missing key.
- `range(start, stop): []string` - `LRANGE`. `stop` is inclusive, and a
  negative index counts from the tail, so `range(0, -1)` is everything.
- `all(): []string` - `range(0, -1)`.
- `index(at): Option<string>` - `LINDEX`, `None` past either end.

`range` and `all` copy the whole range into memory. A queue with a million
waiting jobs wants `range(0, 99)`, not `all()`.

## Editing in place

Lists are not only queues. An article's revision history is a list you
correct and trim:

```bit
import { open } from "redis"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let history = r.list("article:41:history")
  history.push("draft", "review", "review", "published", "typo-fix")?

  history.set(0, "outline")?
  let size = history.insert("published", "approved")?
  println("${size} entries") // 6, "approved" is now just before "published"
  history.insert("published", "announced", after = true)?

  let dropped = history.remove("review", 1)?
  println("${dropped} removed") // 1, the first of the two

  // Keep only the newest three.
  history.trim(-3, -1)?
  println("${len(history.all()?)} kept")
  r.close()
  return
}
```

- `set(at, value): ()` - `LSET`. Fails with a `RedisError` when `at` is out of
  range or the key is missing.
- `insert(pivot, value, after = false): i64` - `LINSERT`. Puts `value` before
  the first `pivot` (after it with `after = true`) and returns the new length,
  `-1` when `pivot` is not in the list, `0` when the list does not exist.
- `remove(value, count = 0): i64` - `LREM`. A positive `count` removes that
  many matches from the head, a negative one from the tail, `0` removes every
  match. Returns how many were removed.
- `trim(start, stop): ()` - `LTRIM`, keeps only that inclusive range, with the
  same negative indexes as `range`. A list trimmed to nothing is deleted.

## Finding a value

```bit
import { open } from "redis"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let history = r.list("article:41:history")
  history.push("edit", "review", "edit", "review", "edit")?

  match (history.position("edit")?) {
    Some(at) => println("first edit at ${at}") // 0
    None => println("never edited")
  }
  match (history.position("edit", rank = -1)?) {
    Some(at) => println("last edit at ${at}") // 4
    None => println("never edited")
  }
  let reviews = history.positions("review")?
  println("${len(reviews)} reviews, at ${reviews[0]} and ${reviews[1]}")
  let early = history.positions("edit", count = 2, maxLen = 4)?
  println("${len(early)} edits among the first four")
  r.close()
  return
}
```

- `position(value, rank = 0, maxLen = 0): Option<i64>` - `LPOS`, the index of the
  first match. `rank` `2` is the second match, a negative `rank` searches from
  the tail, `0` is the default. `maxLen` above `0` gives up after that many
  elements.
- `positions(value, count = 0, rank = 0, maxLen = 0): []i64` - `LPOS` with
  `COUNT`, up to `count` indexes, `0` meaning every match. Empty when there is
  no match.

## Moving an item between lists

A worker that pops a job and crashes loses it. The reliable shape is to move
the job to a "processing" list as it is taken, and delete it from there once it
is done:

```bit
import { open, ListEnd } from "redis"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let queue = r.list("inkwell:publish")
  let working = r.list("inkwell:publishing")
  queue.push("a1", "a2")?

  match (queue.move("inkwell:publishing", ListEnd.Front, ListEnd.Back)?) {
    Some(job) => {
      println("working on ${job}")
      working.remove(job, 1)?
    }
    None => println("nothing to do")
  }
  r.close()
  return
}
```

`move(dest, fromEnd, toEnd): Option<string>` is `LMOVE`: it takes one element
from `fromEnd` of this list and puts it on `toEnd` of `dest`, atomically, and
returns it. `None` when this list is empty. A list can be moved onto itself to
rotate it.

## Waiting for work

A worker should not poll. The blocking pops wait until an item arrives:

```bit
import { open } from "redis"
import { Second } from "std/time"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let queue = r.list("inkwell:publish")

  while (true) {
    match (queue.blockPopFront(5 * Second)?) {
      Some(popped) => println("publishing ${popped.value}")
      None => println("idle for 5s, checking for shutdown")
    }
    // The newest job instead, from the tail, waiting at most a second.
    match (queue.blockPop(1 * Second)?) {
      Some(popped) => println("publishing ${popped.value} from ${popped.key}")
      None => println("nothing newer")
    }
  }
  return
}
```

`blockPopFront(timeout, others = [])` is `BLPOP` and `blockPop` is `BRPOP`
(from the tail). Both return `Option<Popped>`: `Popped` carries `value`, the
item, and `key`, the list it came from, which matters once you pass `others`
to wait on several lists at once; the handle's own key has priority.

`timeout` is in nanoseconds, like every duration in this package (`Second`,
`Millisecond`). `0` waits forever. **A timeout is `Option.None`, never an
error**, so the loop above is the whole retry logic. A timeout below one
millisecond is sent as one millisecond, never as `0`, so a tiny wait cannot
turn into a forever wait. A negative timeout is refused by the server with a
`RedisError`.

```bit
import { open, ListEnd } from "redis"
import { Second } from "std/time"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let queue = r.list("inkwell:publish")

  // The reliable queue, waiting: move to "processing" as the job is taken.
  match (queue.blockMove("inkwell:publishing", ListEnd.Front, ListEnd.Back, 2 * Second)?) {
    Some(job) => println("working on ${job}")
    None => println("no job within 2s")
  }

  // Up to ten jobs from the first of three queues that has any.
  let got = queue.blockPopAny(ListEnd.Front, 2 * Second, ["inkwell:retry", "inkwell:slow"], 10)?
  match (got) {
    Some(popped) => println("${len(popped.values)} jobs from ${popped.key}")
    None => println("every queue stayed empty for 2s")
  }
  r.close()
  return
}
```

- `blockMove(dest, fromEnd, toEnd, timeout): Option<string>` - `BLMOVE`, `move`
  that waits.
- `blockPopAny(end, timeout, others = [], count = 1): Option<PoppedMany>` -
  `BLMPOP`, `popAny` that waits.

### A blocked call does not use the pool

Each blocking call opens its own connection and closes it when it returns, so
workers waiting on empty queues cannot leave `get` and `set` without a
connection, whatever `pool=` says. The cost is a dial and handshake per call.
For `rediss://` that includes loading the trust store, so set `tlsRootCa` (see
[Connecting](connecting.md)) if you block often over TLS. The read deadline is
`timeout` plus the connection's `timeout=` (`commandTimeout`), so a block never
trips it, and `timeout = 0` has no deadline at all.

A blocking call is never retried: a pop that failed on the wire may or may not
have taken its element, and running it twice could lose a job.

## Pipelines and transactions

Every command above except the four blocking ones also exists on the queued
view `pipeline.list(key)` and `tx.list(key)`, returning a `Future` instead of the
value:

```bit
import { open, Future } from "redis"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let p = r.pipeline()
  let queue = p.list("inkwell:publish")
  let pushed = queue.push("a1", "a2", "a3")
  let head = queue.popFront()
  let size = queue.len()
  p.exec()?
  println("${pushed.get()?} pushed, ${size.get()?} left after popping")
  match (head.get()?) {
    Some(job) => println("popped ${job}")
    None => println("nothing popped")
  }

  let count = r.transaction<Future<i64>>(["inkwell:publish"], (tx) => {
    tx.list("inkwell:publish").pushFront("a0")
    return tx.list("inkwell:publish").len()
  })?
  println("${count.get()?} waiting after the transaction")
  r.close()
  return
}
```

The blocking pops have no queued form. A pipeline writes every command
back to back under one `commandTimeout`, so a blocked pop would stall the rest
of the batch and be cut off at that timeout. Inside `MULTI` the server never
blocks at all: a blocking pop there behaves like the plain one. Use `popFront`
in a transaction and the immediate handle for a real wait.

## Reading a list inside a transaction

`tx.list(key)` only queues, so it cannot answer "how many jobs are waiting?"
before you decide what to push. `tx.read.list(key)` is the immediate view of
the same list, run now on the transaction's own connection, between `WATCH`
and `MULTI`. If another client changes a watched key first, the transaction
retries and your body runs again with fresh reads:

```bit
import { open } from "redis"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let key = "inkwell:publish"
  r.transaction<()>([key], (tx) => {
    if (tx.read.list(key).len()? < 100) {
      tx.list(key).push("a9")
    }
    return
  })?
  r.close()
  return
}
```

The reads (`range`, `all`, `len`, `index`, `position`, `positions`) work
through `tx.read`. A write such as `tx.read.list(key).push(...)` would run
immediately, outside the transaction's `MULTI`/`EXEC`, so it fails with
`RedisError.Invalid`, and so does a blocking pop, because the transaction's
connection cannot wait: queue the write with `tx.list(key)`.

## Sharp edges

- `push` and `popFront` make a queue; `push` and `pop` make a stack. Mixing
  the head and tail names up reverses your queue, so pick one pair and keep it.
- A missing key behaves as an empty list: `len()` is `0`, `all()` is `[]`,
  `pop()` is `None`. Taking the last element deletes the key.
- `popFront` hands the item to you and forgets it. A worker that crashes after
  it returns loses the job; use `move` or `blockMove` to a processing list when
  that matters.
- `index`, `set` and `range` near the head are cheap; the middle of a very long
  list is a linear walk. Use `position` and `remove` on lists you keep short.
- A list command on a key that holds another type fails with a `RedisError`
  carrying the server's `WRONGTYPE` message.

## Next

See [Sets](sets.md) for unordered unique collections, [Sorted sets](sorted-sets.md)
for a queue ordered by priority (it has its own blocking pops),
[Strings and keys](strings-and-keys.md) for `del` and key expiry, and
[Connecting](connecting.md) for pool sizing, timeouts and TLS.
