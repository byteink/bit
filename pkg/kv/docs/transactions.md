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

Next: [Indexes](indexes.md), for looking tasks up by something other than
their id.
