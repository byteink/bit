# Indexes

`tasks.all()` reads tasks back in id order, but the task tracker also needs
to ask "which tasks are urgent" without walking every task and checking its
priority by hand. That is what a secondary index is for: a lookup by some
field other than the id, kept up to date automatically as tasks are saved
and removed.

<!-- doctest: per-block -->

## Declaring an index

`declareIndex` registers a closure that computes an index key from a `T` -
every `set` on that collection from then on keeps the index in the same
transaction as the record itself, so the two can never be observed out of
sync. The closure's return value is a key built with `encodeInt`,
`encodeFloat` or `encodeString` - whichever matches the field's type, so the
index sorts (and matches ranges) the way the field's own values compare, not
the way their raw bytes happen to:

```bit
import { Collection, declareIndex, encodeString, open } from "kv"

@json class Task {
  title: string,
  status: string,
}

fn taskStatusKey(t: Task): []byte {
  return encodeString(t.status)
}

fn declareStatusIndex(tasks: Collection<Task>): ()! {
  declareIndex<Task>(tasks, "status", taskStatusKey)?
}

fn main(): ()! {
  let store = open("tasks.kv")?
  let tasks = store.collection<Task>()
  declareStatusIndex(tasks)?

  tasks.set(1, Task{ title = "Pack for the trip", status = "urgent" })?
  tasks.set(2, Task{ title = "Buy plane tickets", status = "done" })?
  tasks.set(3, Task{ title = "Water the plants", status = "urgent" })?

  let urgent = tasks.by("status", encodeString("urgent"))?
  for t of urgent {
    println("urgent: ${t.title}")
  }
  let all = tasks.all()?
  println("${len(all)} task(s) total")
}
```

`tasks.by("status", encodeString("urgent"))` returns every task whose
`taskStatusKey` encodes to `"urgent"` - "Pack for the trip" and "Water the
plants" here, in the order they were saved. `all()` ignores every index and
returns every saved task, in id order.

## A numeric index

`encodeInt`/`decodeInt` and `encodeFloat`/`decodeFloat` do the same job for
number-valued fields - the raw bytes of a negative number do not sort before
a positive one, so an index keyed by a plain cast would silently return
tasks in the wrong order. Index by priority instead of status:

```bit
import { Collection, declareIndex, decodeInt, encodeInt, open } from "kv"

@json class Task {
  title: string,
  priority: i64,
}

fn taskPriorityKey(t: Task): []byte {
  return encodeInt(t.priority)
}

fn declarePriorityIndex(tasks: Collection<Task>): ()! {
  declareIndex<Task>(tasks, "priority", taskPriorityKey)?
}

fn main(): ()! {
  let store = open("tasks.kv")?
  let tasks = store.collection<Task>()
  declarePriorityIndex(tasks)?

  tasks.set(1, Task{ title = "Pack for the trip", priority = 2 })?
  tasks.set(2, Task{ title = "Buy plane tickets", priority = 1 })?

  let top = tasks.by("priority", encodeInt(1))?
  println(top[0].title)
  println("${decodeInt(encodeInt(1))}")
}
```

## The database survives a restart

The task tracker's whole point is that a task saved today is still there
tomorrow. `open` reopens an existing file the same way it creates a new one
- declare the same index again (nothing about it is stored on disk, only the
records and their index entries are) and carry on:

```bit
import { Collection, declareIndex, encodeString, open } from "kv"

@json class Task {
  title: string,
  status: string,
}

fn taskStatusKey(t: Task): []byte {
  return encodeString(t.status)
}

fn openTasks(): Collection<Task>! {
  let store = open("tasks.kv")?
  let tasks = store.collection<Task>()
  declareIndex<Task>(tasks, "status", taskStatusKey)?
  return tasks
}

fn main(): ()! {
  let tasks = openTasks()?
  tasks.set(1, Task{ title = "Pack for the trip", status = "urgent" })?

  // The app restarts; nothing above is held in memory anymore.
  let reopened = openTasks()?
  let t = reopened.get(1)?
  println(t.title)
  reopened.delete(1)?
}
```

## Sharp edges

`declareIndex` has to be called again on every open, on every `Collection`
value - nothing about an index is stored on disk, only the records and the
index entries `set` wrote for them. Reopen a database and forget to
redeclare an index and `by()` on it returns nothing, silently: there is no
entry to find, not because none match, but because the index was never
rebuilt this run.

## Where to go next

[Getting started](getting-started.md) for `open` and `store.collection<T>()`
this chapter builds on, and [Transactions](transactions.md) for what happens
to `set`/`delete` when the surrounding `store.tx` block fails.
