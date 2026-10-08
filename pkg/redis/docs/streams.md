# Streams

<!-- doctest: per-block -->

Inkwell wants an activity feed: "article 41 published", "comment added",
"draft restored". Several things care about those events, and they care at
different speeds: the feed page wants the latest twenty, the search indexer
wants every event exactly once, and a newly deployed indexer wants to start
from the beginning. A list loses an event the moment one worker pops it. A
Redis stream is an append-only log: every event gets an id, stays until you
trim it, and any number of readers can walk it, either each on their own
position or together as a group that shares the work.

```bit
import { open, field } from "redis"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let events = r.stream("inkwell:events")
  let id = events.add([field("kind", "publish"), field("article", "41")])?
  println("appended ${id}") // 1700000000000-0

  for e of events.range()? {
    println("${e.id}: ${unwrapOr(e.get("kind"), "?")}")
  }
  r.close()
  return
}
```

`r.stream(key)` is a cheap value, `{client, key}`: call it again any time you
need the same stream. A stream is created by its first `add`. The id has two
parts, a millisecond timestamp and a counter, so ids sort in the order the
events happened.

## Entries and fields

An entry is an id and a list of fields. The server keeps the fields in the
order you gave them, and a name may repeat, so `Entry.fields` is an ordered
`[]Field` of `name` and `value`, not a map. `field(name, value)` builds one
without the class literal; `Entry.get(name)` finds the first field with that
name and returns `Option<string>`.

```bit
import { open, field, Field, Entry } from "redis"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let events = r.stream("inkwell:events")
  let fields: []Field = [
    field("kind", "comment"),
    field("article", "41"),
    Field{ name = "author", value = "ana" },
  ]
  events.add(fields)?

  let latest: []Entry = events.revRange(count = 1)?
  let e = latest[0]
  println("${e.id} has ${len(e.fields)} fields, first is ${e.fields[0].name}") // 3, kind
  match (e.get("author")) {
    Some(who) => println("by ${who}")
    None => println("anonymous")
  }
  r.close()
  return
}
```

- `add(fields, id = StreamId.Auto, trim = Trim.Off, approx = true, limit = 0): string` -
  `XADD`, returns the new id.
- `addIfExists(...): Option<string>` - `XADD .. NOMKSTREAM`: appends only when
  the stream is already there and returns `None`, creating nothing, when it
  is not. It is a separate method because its result type differs, the same
  split as `pushIfExists` on a list.
- `len(): i64` - `XLEN`.

## Positions: `StreamId`

Redis writes positions as `*`, `$`, `>`, `-`, `+`, `0` and `(1-5`, and each is
valid only in some commands. `StreamId` names them so nobody hand-writes
them:

| `StreamId` | On the wire | Means |
| ---------- | ----------- | ----- |
| `Auto` | `*` | let the server pick the id (`add`) |
| `Latest` | `$` | only what is added from now on (`read`, group `create`) |
| `Undelivered` | `>` | entries no one in the group has been given yet |
| `First` | `-` | the smallest possible id (a range start) |
| `Last` | `+` | the largest possible id (a range end) |
| `Zero` | `0` | the very beginning |
| `At(id)` | `id` | exactly this id |
| `After(id)` | `(id` | everything after this id (an exclusive range end) |

A command given a position it does not accept fails with the server's own
error; the client does not guess.

```bit
import { open, field, StreamId } from "redis"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let events = r.stream("inkwell:events")
  events.add([field("kind", "publish")], StreamId.At("1-1"))?
  events.add([field("kind", "comment")], StreamId.At("1-2"))?
  events.add([field("kind", "publish")], StreamId.At("1-3"))?

  let after = events.range(StreamId.After("1-1"), StreamId.Last)?
  println("${len(after)} entries after 1-1") // 2
  let window = events.range(StreamId.At("1-2"), StreamId.At("1-3"), count = 1)?
  println("${window[0].id}") // 1-2
  r.close()
  return
}
```

## Reading

`range(start = First, end = Last, count = 0)` is `XRANGE` and walks oldest to
newest; `revRange(end = Last, start = First, count = 0)` is `XREVRANGE`, newest
first, with the high end named first as the server does. `count` 0 means all.

`read(from = Zero, count = 0, block = -1)` is `XREAD` on this stream: the
entries after `from`. It is the call for a reader that keeps its own position
(remember the last id you saw, pass `StreamId.At(last)` next time). To follow
several streams at once, `readAny(from, others, count, block)` takes the
others as `Cursor{ key, from }` values and returns one `KeyedEntries` per
stream that had something.

```bit
import { open, field, StreamId, Cursor } from "redis"
import { Second } from "std/time"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let events = r.stream("inkwell:events")
  events.add([field("kind", "publish")])?
  r.stream("inkwell:audit").add([field("kind", "login")])?

  // Everything from both streams, from the start.
  let both = events.readAny(StreamId.Zero, [Cursor{ key = "inkwell:audit", from = StreamId.Zero }])?
  for k of both {
    println("${k.key}: ${len(k.entries)} entries")
  }

  // A live tail: wait up to 5 seconds for something newer than now.
  let fresh = events.read(StreamId.Latest, count = 10, block = 5 * Second)?
  println("${len(fresh)} new entries")
  r.close()
  return
}
```

### Blocking

`block` is a duration in nanoseconds (`Second`, `Millisecond` from
`std/time`). A negative value, the default, does not block. `0` waits
forever. When the wait ends with nothing, the result is an empty list, not an
error. The server counts whole milliseconds, so a positive block under 1ms is
sent as 1ms rather than `0`, which would mean forever.

A blocking call uses its own connection for the wait and closes it after, so
readers parked on quiet streams never use up the pool that `add` and `get`
share. Its read deadline is `block` plus the connection's `commandTimeout`,
so the usual timeout never cuts a block short. A `Pipeline` has no blocking
methods: a blocked read would stall every command queued behind it.

## Trimming and deleting

A stream grows until you cut it. `Trim` says how, and it is a type with two
payloads, not two options, because the server accepts one rule at a time:
`Trim.MaxLen(n)` keeps about the newest `n` entries and `Trim.MinId(id)` drops
entries older than `id`. `Trim.Off` is the default and means no trimming.

`approx` (default true) sends `~`, which lets the server drop whole internal
blocks at once. It is much cheaper, and the stream may keep a few more
entries than asked. Pass `approx = false` for an exact cap. `limit` bounds
the work one call does and needs `approx`; both mistakes fail
`RedisError.Invalid` before anything is sent.

```bit
import { open, field, Trim, StreamId, RefMode, DelStatus } from "redis"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let events = r.stream("inkwell:events")

  // Append and cap in one call: about the newest 10 000 events.
  events.add([field("kind", "publish")], trim = Trim.MaxLen(10000))?

  let dropped = events.trim(Trim.MinId("1700000000000-0"))?
  println("${dropped} old events dropped")

  let removed = events.del("1-1", "1-2")?
  println("${removed} deleted") // ids that were not there do not count

  // Redis 8.2 and later: say what happens to references held by consumer groups.
  let statuses = events.delete(["1-3", "9-9"], RefMode.AckedOnly)?
  for s of statuses {
    if (s == DelStatus.NotFound) {
      println("no such entry")
    }
  }
  r.close()
  return
}
```

- `trim(by, approx = true, limit = 0): i64` - `XTRIM`, the entries removed;
  `Trim.Off` is refused.
- `del(...ids): i64` - `XDEL`.
- `delete(ids, refs = RefMode.Keep): []DelStatus` - `XDELEX`. `RefMode.Keep`
  leaves the entry in each group's pending list, `Drop` removes it there too,
  and `AckedOnly` deletes it only once every group has acknowledged it. The
  answer per id is `Deleted`, `NotFound`, or `Retained` (not deleted, still
  referenced).

## Consumer groups

A group turns a stream into a work queue with memory. The group remembers
the last id it handed out; each consumer in it asks for entries nobody has
been given yet, so each entry goes to exactly one consumer. The entry stays
in the group's pending list until that consumer acknowledges it, which is
what lets you recover work from a worker that died.

`r.stream(key).group(name)` is the group handle, `.consumer(name)` a
consumer's. A consumer needs no registration: its first read creates it.

```bit
import { open, field, StreamId } from "redis"
import { Second } from "std/time"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let events = r.stream("inkwell:events")
  let indexer = events.group("indexer")

  // Safe at every start: true only for the call that made the group.
  // StreamId.Zero hands the whole existing log to the group, Latest only new events.
  let made = indexer.ensure(StreamId.Zero)?
  if (made) {
    println("group created")
  }

  let worker = indexer.consumer("indexer-1")
  while (true) {
    let batch = worker.read(count = 10, block = 5 * Second)?
    if (len(batch) == 0) {
      break
    }
    for e of batch {
      println("indexing ${e.id} ${unwrapOr(e.get("kind"), "?")}")
    }
    // Acknowledge only once the work is done.
    let ids = []string(0)
    for e of batch {
      ids = append(ids, e.id)
    }
    worker.ack(...ids)?
  }
  r.close()
  return
}
```

`Consumer.read(count = 0, block = -1, from = StreamId.Undelivered, noAck = false)`
is `XREADGROUP`. `noAck` skips the pending list, for events you can afford to
lose. With `from = StreamId.Zero` (or `At(id)`) it returns the consumer's own
pending entries instead of new ones: the restart path, "what was I doing when
I crashed". An entry deleted from the stream since comes back with no
fields.

- `Group.create(from = StreamId.Latest, mkStream = true)` - `XGROUP CREATE`.
  It fails `RedisError.Server("BUSYGROUP", ..)` when the group exists;
  `ensure(from)` is the same call that returns `false` instead.
- `Group.destroy(): bool` - `XGROUP DESTROY`.
- `Group.setId(to)` - `XGROUP SETID`: move the group's position, for example
  back to `StreamId.Zero` to replay everything.
- `Group.createConsumer(name): bool` and `Group.delConsumer(name): i64` -
  `XGROUP CREATECONSUMER` and `DELCONSUMER`. `delConsumer` returns how many
  pending entries the consumer held; they are dropped, so claim them first.
- `Group.ack(...ids): i64` and `Consumer.ack(...ids): i64` - `XACK`, how many
  of the ids were pending. `Group.ackDelete(ids, refs = RefMode.Keep):
  []DelStatus` is `XACKDEL`, acknowledge and delete in one step (Redis 8.2+).

## When a worker dies

A consumer that crashes leaves its entries pending, and no one else will be
given them. `claimStale(minIdle, count = 100, start = StreamId.Zero)` is
`XAUTOCLAIM`: it takes the entries that have sat unacknowledged for at least
`minIdle` (a duration) and gives them to the calling consumer. It returns an
`AutoClaimed`: the `entries` now yours, `deleted`, ids that were pending but
no longer exist, and `next`, the id to pass as `start` for the next page
(`0-0` when the scan is done).

```bit
import { open, StreamId } from "redis"
import { Second } from "std/time"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let indexer = r.stream("inkwell:events").group("indexer")
  let me = indexer.consumer("indexer-2")

  let start = StreamId.Zero
  while (true) {
    let page = me.claimStale(30 * Second, 100, start)?
    for e of page.entries {
      println("recovering ${e.id}")
      me.ack(e.id)?
    }
    if (page.next == "0-0") {
      break
    }
    start = StreamId.At(page.next)
  }
  r.close()
  return
}
```

To look before you take, `Group.pending()` answers a `PendingSummary` (the
`count`, the smallest and largest id, and a `PendingCount` of `consumer` and
`count` for each holder), and `pendingList(count, start = First, end = Last,
consumer = "", minIdle = 0)` returns `PendingEntry` values: `id`, `consumer`,
`idle` (a duration) and `deliveries`. `Consumer.pending(count = 100)` is that
list for one consumer. An entry delivered many times and never acknowledged is
usually a poison message; `deliveries` is how you notice.

The lower-level `Group.claim(consumer, minIdle, ids, force = false)` is
`XCLAIM` for ids you already chose, returning the entries; `claimIds` is the
same with only the ids back (`JUSTID`), and does not count as a new delivery.
`Group.autoClaim(consumer, minIdle, start, count)` is `claimStale` for a
consumer other than the caller.

```bit
import { open, StreamId } from "redis"
import { Second } from "std/time"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let indexer = r.stream("inkwell:events").group("indexer")

  let summary = indexer.pending()?
  println("${summary.count} pending")
  for held of summary.consumers {
    println("${held.consumer} holds ${held.count}")
  }

  let stuck = indexer.pendingList(10, minIdle = 60 * Second)?
  for p of stuck {
    if (p.deliveries > 5) {
      println("${p.id} delivered ${p.deliveries} times, idle ${p.idle / Second}s")
    }
  }

  let ids = []string(0)
  for p of stuck {
    ids = append(ids, p.id)
  }
  let mine = indexer.claim("indexer-3", 60 * Second, ids)?
  println("claimed ${len(mine)}")
  let moved = indexer.claimIds("indexer-3", 60 * Second, ids)?
  let swept = indexer.autoClaim("indexer-3", 60 * Second, StreamId.Zero, 50)?
  println("${len(moved)} ids, ${len(swept.entries)} swept, ${len(swept.deleted)} gone")
  r.close()
  return
}
```

## Looking inside: `XINFO`

`Stream.info()` returns a `StreamInfo`: `length`, `groups`, `lastGeneratedId`,
`entriesAdded` (every entry ever appended, deleted ones included),
`firstEntry` and `lastEntry` as `Option<Entry>`, and the internal
`radixTreeKeys`, `radixTreeNodes`, `maxDeletedEntryId` and
`recordedFirstEntryId`. `Stream.groups()` returns a `GroupInfo` per group
(`name`, `consumers`, `pending`, `lastDeliveredId`, `entriesRead`, `lag`) and
`Group.consumers()` a `ConsumerInfo` per consumer (`name`, `pending`, `idle`,
`inactive`). `lag` is how many entries the group has still to be given;
`None` when the server cannot tell.

```bit
import { open } from "redis"
import { Second } from "std/time"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let events = r.stream("inkwell:events")

  let info = events.info()?
  println("${info.length} entries, ${info.groups} groups, last id ${info.lastGeneratedId}")
  println("${info.entriesAdded} ever added, ${info.radixTreeKeys}/${info.radixTreeNodes} tree keys/nodes")
  println("deleted up to ${info.maxDeletedEntryId}, first recorded ${info.recordedFirstEntryId}")
  match (info.firstEntry) {
    Some(e) => println("oldest ${e.id}")
    None => println("empty")
  }
  if (isSome(info.lastEntry)) {
    println("newest ${unwrap(info.lastEntry).id}")
  }

  for g of events.groups()? {
    println("${g.name}: ${g.consumers} consumers, ${g.pending} pending, at ${g.lastDeliveredId}")
    println("read ${unwrapOr(g.entriesRead, 0)}, lag ${unwrapOr(g.lag, 0)}")
    for c of events.group(g.name).consumers()? {
      println("  ${c.name}: ${c.pending} pending, idle ${c.idle / Second}s")
      println("  inactive ${unwrapOr(c.inactive, 0) / Second}s")
    }
  }
  r.close()
  return
}
```

## In a pipeline

`p.stream(key)` on a `Pipeline` (and `tx.stream(key)` in a transaction) is a
`StreamBatch`: `add`, `len`, `range`, `revRange`, `del`, `trim` and
`ack(group, ...ids)`, each returning a `Future`. It has no blocking reads and
no group handles; use the immediate handle for those.

```bit
import { open, field, StreamId } from "redis"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let p = r.pipeline()
  let a = p.stream("inkwell:events").add([field("kind", "publish")])
  let b = p.stream("inkwell:events").add([field("kind", "comment")])
  let n = p.stream("inkwell:events").len()
  let tail = p.stream("inkwell:events").revRange(StreamId.Last, StreamId.First, 2)
  p.exec()?
  println("${a.get()?} ${b.get()?} ${n.get()?} ${len(tail.get()?)}")
  r.close()
  return
}
```

## Sharp edges

- `XREADGROUP` on a group that does not exist fails
  `RedisError.Server("NOGROUP", ..)`. Create it with `ensure` at start-up.
- `ensure(StreamId.Latest)` on a stream that is missing creates it empty
  (`mkStream`), so a worker may start before the first producer.
- An acknowledged entry is gone from the pending list but not from the
  stream. Trim or delete to reclaim the space.
- `claimStale` takes the entries that look dead, not the ones that are:
  choose `minIdle` longer than your slowest handler, or two workers will
  process one entry.
- Ids passed to `add` must be larger than the stream's last id; the server
  refuses an older one.

Where next: [Lists](lists.md) for a queue that forgets an item once it is
taken, [Connecting](connecting.md) for `commandTimeout` and the pool, and
[Commands](commands.md) for the full `Client` surface.
