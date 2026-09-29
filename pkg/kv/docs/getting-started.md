# Getting started

A local task tracker needs somewhere to keep its tasks between runs. A
database server is overkill for a single-user, offline-first program, and a
flat file forces you to parse the whole thing back into memory before you can
look anything up by id. `kv` is the middle ground: one file on disk, an
ordered key-value store inside it, no server to install or run.

<!-- doctest: per-block -->

## Install

```json
{
  "dependencies": {
    "kv": "bitlang.org/pkg/kv@v0.1.1"
  }
}
```

## The simplest thing that works

`open(path)` opens a database file, creating it if it does not already
exist. A value is any `@json` class; `store.collection<Task>()` gives you a
typed collection named after the class (`Task` -> `"task"`). Store the first
task under an id you choose and read it straight back:

```bit
import { open } from "kv"

@json class Task {
  title: string,
}

fn main(): ()! {
  let store = open("tasks.kv")?
  let tasks = store.collection<Task>()

  tasks.set(1, Task{ title = "Pack for the trip" })?
  let t = tasks.get(1)?
  println(t.title)
}
```

Every call above ran in its own transaction: `set` opened one, wrote the
record, and committed before returning; `get` did the same for the read.
There is no `close` to remember - the file is only ever locked for the
duration of one call.

## Choosing a collection name

`store.collection<Task>()` names the collection after the class:
`snake_case`, never pluralized, so `Task` becomes `"task"` and a class like
`OrderLine` becomes `"order_line"`. Give it your own name instead - as a
second argument, or with `@collection("...")` on the class itself:

```bit
import { open } from "kv"

@json class Task {
  title: string,
}

@json @collection("done") class ArchivedTask {
  title: string,
}

fn main(): ()! {
  let store = open("tasks.kv")?
  let tasks = store.collection<Task>("backlog")   // overrides "task"
  let archived = store.collection<ArchivedTask>() // named "done"

  tasks.set(1, Task{ title = "Pack for the trip" })?
  archived.set(1, ArchivedTask{ title = "Book flights" })?
}
```

Two collections never collide on a key even if you give them the same id:
each one carves out its own slice of the file, keyed by its own name.

## What `get` does when there is nothing there

`get` fails, rather than returning a zero value, when the id has no record -
so a missing task cannot be silently mistaken for an empty one:

```bit
import { open } from "kv"

@json class Task {
  title: string,
}

fn main(): ()! {
  let store = open("tasks.kv")?
  let tasks = store.collection<Task>()

  tasks.get(999) catch e {
    println("no task 999: ${e.message()}")
    return
  }
}
```

Next: [Transactions](transactions.md), for writing several tasks at once and
what happens when one of them is bad.
