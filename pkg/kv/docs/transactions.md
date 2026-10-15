# Transactions

The task tracker rarely has just one thing to write. Importing a batch of
tasks, or adding one task while canceling another, needs several writes to
either all land or none do - a crash or a bad entry halfway through a batch
import must not leave the database half-updated.

<!-- doctest: per-block -->

## Several writes, one commit

Outside `store.tx`, every `Collection` call - `set`, `get`, `delete`, `all` -
opens and commits its own transaction, which is exactly right for one write
at a time but wrong for several that must land together. `store.tx((t) =>
{...})` runs the whole block as one transaction: every collection you get
from `t` (never from `store` directly, inside the block) writes into it, and
the block commits only once it returns normally.

```bit
import { open } from "kv"

@json class Task {
  title: string,
}

fn main(): ()! {
  let store = open("tasks.kv")?

  store.tx((t) => {
    let tasks = t.collection<Task>()
    tasks.set(1, Task{ title = "Pack for the trip" })?
    tasks.set(2, Task{ title = "Buy plane tickets" })?
    tasks.set(3, Task{ title = "Cancel the paper delivery" })?
    tasks.delete(3)?
  })?

  let tasks = store.collection<Task>()
  let all = tasks.all()?
  for t of all {
    println(t.title)
  }
}
```

The canceled task never shows up: the `set` and the `delete` that undoes it
happened in the same block as the two that stayed, and `all()` (outside the
block, its own fresh transaction) only ever sees a fully committed state.

## What a failing block does

There is no `begin`, `commit` or `rollback` to call - see
[Propagating with `?`](../../../docs/reference/errors.md) for why an
early-return API like that is a real hazard, not just a style preference.
`store.tx` commits on a normal return and rolls back on anything else: a
propagated error, an explicit `fail`, or a panic. Nothing the block wrote
becomes visible until it returns normally - across every collection it
touched, not just the one write that failed.

A `put` or `delete` error aborts that transaction even if the block catches
it. Later operations on that handle fail with the original error, and
`store.tx` returns the error without committing. Start another `store.tx`
on the same database to continue.

```bit
import { Tx, open } from "kv"

@json class Task {
  title: string,
}

fn addTask(t: Tx, id: i64, title: string): ()! {
  if (len(title) == 0) {
    fail newError("kv-tasks: a task needs a title")
  }
  t.collection<Task>().set(id, Task{ title = title })?
}

fn main(): ()! {
  let store = open("tasks.kv")?

  store.tx((t) => {
    addTask(t, 1, "Pack for the trip")?
  })?

  store.tx((t) => {
    addTask(t, 2, "Buy plane tickets")?
    addTask(t, 3, "")?
  }) catch e {
    println("import failed: ${e.message()}")
  }

  let tasks = store.collection<Task>()
  let all = tasks.all()?
  println("${len(all)} task(s) saved")
}
```

Task 2 never appears: it was written in the same block as task 3's bad,
empty title, so the whole block rolled back and task 1 is still the only
thing saved.

## The raw bytes underneath

Every `t` a `store.tx` block hands you is also the lower-level transaction
handle `Collection` itself is built on: `t.put(key, value)`, `t.get(key)`,
`t.delete(key)` and `t.scan(lo, hi)` work directly on `[]byte` keys and
values, in the same transaction as any collection you use alongside them.
Reach for this only when you need something `Collection` does not give you -
a key that is not one class's record, for instance. `encodeInt`,
`encodeFloat` and `encodeString` build a key that sorts the way the value it
encodes does (raw byte comparison does not, for a negative int or a
negative float); each has a matching `decode*`:

```bit
import { decodeInt, encodeInt, open } from "kv"

fn main(): ()! {
  let store = open("tasks.kv")?

  store.tx((t) => {
    t.put(encodeInt(-1), []byte("overdue marker"))?
  })?

  store.tx((t) => {
    let raw = t.get(encodeInt(-1))?
    println(string(raw))
    println("${decodeInt(encodeInt(-1))}")
  })?
}
```

## Observe committed changes

A second process can update the task tracker while a cache still holds its
old entries. `store.version()` reads the durable commit number, including
commits from other processes. It leaves an active transaction's root alone.
Every successful `tx` advances this number once, including a read-only block;
a failed or panicked block does not advance it.

Watch a raw key prefix when you need to invalidate only one part of a cache:

```bit
import { Change, Watcher, open } from "kv"

fn report(change: Change) {
  println("commit ${change.version}, resync everything: ${change.overflow}")
}

fn poll(watcher: Watcher): ()! {
  let change = watcher.next(100)?
  match (change) {
    Some(value) => report(value)
    None => println("no change")
  }
}

fn main(): ()! {
  let store = open("tasks.kv")?
  defer store.close()
  let watcher = store.watch([]byte("tasks/"), 10)?
  defer watcher.close()
  store.tx((t) => {
    t.put([]byte("tasks/1"), []byte("Pack for the trip"))?
  })?
  println("${store.version()?}")
  poll(watcher)?
}
```

On a new file this prints commit `1`, then reports that version with
`overflow = false`. The watcher copies the prefix, owns its reader handle,
and starts at the version captured when `watch` returns. Close it separately
from the store. Opening the reader or capturing its cursor can fail, so
`watch` is fallible. A positive polling interval and a nonnegative timeout
are required; both must fit the nanosecond clock range. A zero timeout makes
one attempt. No background thread runs: `next` polls until a match or its
timeout. If a writer owns the file lock, that attempt waits for the next poll.
An ordinary `version` read reports a busy-writer error instead of blocking.

Each change reports the newest observed version, rather than one event per
key. A successful put or a delete that removes a key records that key.
Writes outside the prefix advance the cursor without returning a change.
All commits since the cursor are checked, so later prefix misses cannot hide
an earlier matching write. A journal retains the last 1024 commits. Falling
further behind returns `overflow = true`, even if the retained keys do not
match: clear the whole cache and read its contents again.

The journal and tree share one durable meta-page flip. Its CRC-covered
format-1 extension uses previously reserved meta bytes; old data files stay
readable. Older writers clear this extension. A lost history range therefore
returns overflow, and the next current writer recovers obsolete journal
pages into its deferred free list. Live tree and free-list pages have
different first-byte tags from journal pages; embedded journal-looking user
values remain ordinary values. Recovery never reuses those pages before the
meta flip. No reserved application keys or side files hold the history.
Corrupt metadata or journal pages fail instead of reporting no change.
Versions through the largest signed 64-bit value remain readable; further
transactions fail before their block runs, rather than wrapping the counter.

Next: [Indexes](indexes.md), for looking tasks up by something other than
their id.
