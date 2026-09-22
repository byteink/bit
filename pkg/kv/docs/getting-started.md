# Getting started

A local task tracker needs somewhere to keep its tasks between runs. A
database server is overkill for a single-user, offline-first program, and a
flat file forces you to parse the whole thing back into memory before you can
look anything up in order. `kv` is the middle ground: one file on disk, an
ordered key-value store inside it, no server to install or run.

<!-- doctest: per-block -->

## Install

```json
{
  "dependencies": {
    "kv": "bitlang.org/pkg/kv@v0.1.0"
  }
}
```

## The simplest thing that works

`createDb(path)` makes a new database file. Every write goes through
`db.write`, a closure that gets a `Tx` to read and write with; `tx.put` and
`tx.get` take `[]byte` on both sides, key and value. Store the first task and
read it straight back:

```bit
import { createDb, encodeInt } from "kv"

fn main(): ()! {
  let db = createDb("tasks.kv")?
  db.write((tx) => {
    tx.put(encodeInt(1), []byte("Pack for the trip"))?
  })?

  db.write((tx) => {
    let title = tx.get(encodeInt(1))?
    println(string(title))
  })?

  db.close()
}
```

`db.write` takes a lock on the file for the whole block, so a second process
opening the same database has to wait its turn - even for a read like the
second block above. `db.close()` releases the file once you are done with it.

## What a key actually is

The task's id above wasn't stored as a raw `1` - it went through
`encodeInt`. A `kv` key is just bytes, and bytes compare left to right, so a
key built the wrong way sorts wrong: two's-complement `-1` would read as
bigger than `1` under plain byte comparison. `encodeInt`, `encodeFloat` and
`encodeString` fix that for the three scalar types a key is usually built
from, and each has a matching `decode*` to get the original value back:

```bit
import { decodeFloat, decodeInt, decodeString, encodeFloat, encodeInt, encodeString } from "kv"

fn main() {
  println("${decodeInt(encodeInt(42))}")
  println("${decodeFloat(encodeFloat(2.5))}")
  println(decodeString(encodeString("done")))
}
```

`encodeString` also escapes and terminates its output, so one string's
encoding is never a byte-for-byte prefix of another's - that matters once
keys start getting built by concatenating several encoded fields together,
which the indexes chapter does.

Next: [Transactions](transactions.md), for writing several tasks at once and
what happens when one of them is bad.
