# Indexes

`tx.scan` reads tasks back in id order, but the task tracker also needs to
ask "which tasks are urgent" without walking every task and checking its
priority by hand. That is what a secondary index is for: a lookup by some
field other than the id, kept up to date automatically as tasks are saved
and removed.

<!-- doctest: per-block -->

## A typed collection with a declared index

Working in raw `[]byte` for every task gets old fast, and a hand-written
index has to be kept in sync with the records it indexes by hand too.
`Collection<T>` does both: it takes a `marshal`/`unmarshal` pair for `T`, and
`declareIndex` registers a closure that computes an index key from a `T` -
`save` then maintains that index in the same transaction as the record
itself, so the two can never be observed out of sync.

```bit
import { Collection, createDb, declareIndex, encodeInt, newCollection } from "kv"
import { Json, JsonEntry, jsonDecode, jsonEncode, jsonParse } from "std/json"

@json class Task {
  title: string,
  priority: i64,
}

fn marshalTask(t: Task): []byte {
  return []byte(jsonEncode(t.toJson()))
}

fn unmarshalTask(b: []byte): Task! {
  let j = jsonParse(string(b))?
  return jsonDecode<Task>(j)?
}

fn taskPriorityKey(t: Task): []byte {
  return encodeInt(t.priority)
}

fn main(): ()! {
  let db = createDb("tasks.kv")?
  let tasks = newCollection<Task>("tasks", marshalTask, unmarshalTask)
  declareIndex<Task>(tasks, "priority", taskPriorityKey)?

  db.write((tx) => {
    tasks.save(tx, encodeInt(1), Task{ title = "Pack for the trip", priority = 2 })?
    tasks.save(tx, encodeInt(2), Task{ title = "Buy plane tickets", priority = 1 })?
    tasks.save(tx, encodeInt(3), Task{ title = "Water the plants", priority = 2 })?
  })?

  db.write((tx) => {
    let urgent = tasks.by(tx, "priority", encodeInt(1))?
    for t of urgent {
      println("urgent: ${t.title}")
    }
    let all = tasks.all(tx)?
    println("${len(all)} task(s) total")
  })?

  db.close()
}
```

`tasks.by(tx, "priority", encodeInt(1))` returns every task whose
`taskPriorityKey` encodes to `1` - just "Buy plane tickets" here. `all(tx)`
ignores the index entirely and returns every saved task, the same way
`tx.scan` did in the previous chapter, just already unmarshaled back into
`Task` values.

## The database survives a restart

The task tracker's whole point is that a task saved today is still there
tomorrow. `openDb` reopens an existing file - declare the same collection and
the same index again (nothing about either is stored on disk, only the
records and their index entries are) and carry on:

```bit
import { Collection, createDb, declareIndex, encodeInt, newCollection, openDb } from "kv"
import { Json, JsonEntry, jsonDecode, jsonEncode, jsonParse } from "std/json"

@json class Task {
  title: string,
  priority: i64,
}

fn marshalTask(t: Task): []byte {
  return []byte(jsonEncode(t.toJson()))
}

fn unmarshalTask(b: []byte): Task! {
  let j = jsonParse(string(b))?
  return jsonDecode<Task>(j)?
}

fn taskPriorityKey(t: Task): []byte {
  return encodeInt(t.priority)
}

fn openTasks(): Collection<Task> {
  let tasks = newCollection<Task>("tasks", marshalTask, unmarshalTask)
  return tasks
}

fn main(): ()! {
  let db = createDb("tasks.kv")?
  let tasks = openTasks()
  declareIndex<Task>(tasks, "priority", taskPriorityKey)?
  db.write((tx) => {
    tasks.save(tx, encodeInt(1), Task{ title = "Pack for the trip", priority = 2 })?
  })?
  db.close()

  // The app restarts; nothing above is held in memory anymore.
  let reopened = openDb("tasks.kv")?
  let reopenedTasks = openTasks()
  declareIndex<Task>(reopenedTasks, "priority", taskPriorityKey)?
  reopened.write((tx) => {
    let t = reopenedTasks.get(tx, encodeInt(1))?
    println(t.title)
    reopenedTasks.delete(tx, encodeInt(1))?
  })?
  reopened.write((tx) => {
    let remaining = reopenedTasks.all(tx)?
    println("${len(remaining)} task(s) left")
  })?
  reopened.close()
}
```

`Collection.get` fails the same way `Tx.get` does when the id has no record.
`Collection.delete` removes the record and every index entry it had in one
step - a completed task disappears from both `all()` and any `by()` lookup
that used to match it.
