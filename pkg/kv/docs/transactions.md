# Transactions

The task tracker rarely has just one thing to write. Importing a batch of
tasks, or adding one task while canceling another, needs several writes to
either all land or none do - a crash or a bad entry halfway through a batch
import must not leave the database half-updated.

<!-- doctest: per-block -->

## Several writes, one commit

Everything inside one `db.write` block commits together. Add three tasks and
cancel one of them, all before the block returns:

```bit
import { createDb, encodeInt } from "kv"

fn main(): ()! {
  let db = createDb("tasks.kv")?
  db.write((tx) => {
    tx.put(encodeInt(1), []byte("Pack for the trip"))?
    tx.put(encodeInt(2), []byte("Buy plane tickets"))?
    tx.put(encodeInt(3), []byte("Cancel the paper delivery"))?
    tx.delete(encodeInt(3))?
  })?

  db.write((tx) => {
    let titles = tx.scan(encodeInt(1), encodeInt(4))?
    for title of titles {
      println(string(title))
    }
  })?

  db.close()
}
```

`tx.scan(lo, hi)` returns the values for every key in `[lo, hi)`, in key
order - which is exactly ascending task id order here, because `encodeInt`
preserves it. The canceled task never shows up: the `put` and the `delete`
that undoes it happened in the same block as the two that stayed.

## What a failing block does

There is no `begin`, `commit` or `rollback` to call - see
[Propagating with `?`](../../../docs/reference/errors.md) for why an
early-return API like that is a real hazard, not just a style preference.
`db.write` commits on a normal return and rolls back on anything else: a
propagated error, an explicit `fail`, or a panic. Nothing the block wrote
becomes visible until it returns normally.

```bit
import { Tx, createDb, encodeInt } from "kv"

fn addTask(tx: Tx, id: i64, title: string): ()! {
  if (len(title) == 0) {
    fail newError("kv-tasks: a task needs a title")
  }
  tx.put(encodeInt(id), []byte(title))?
}

fn main(): ()! {
  let db = createDb("tasks.kv")?
  db.write((tx) => {
    addTask(tx, 1, "Pack for the trip")?
  })?

  db.write((tx) => {
    addTask(tx, 2, "Buy plane tickets")?
    addTask(tx, 3, "")?
  }) catch e {
    println("import failed: ${e.message()}")
  }

  db.write((tx) => {
    let titles = tx.scan(encodeInt(1), encodeInt(4))?
    for title of titles {
      println(string(title))
    }
  })?

  db.close()
}
```

Task 2 never appears: it was written in the same block as task 3's bad,
empty title, so the whole block rolled back and task 1 is still the only
thing committed.

Next: [Indexes](indexes.md), for looking tasks up by something other than
their id.
