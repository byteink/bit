# pkg/kv

An embedded, ordered key-value store: one file on disk, no server to run, no
network round trip. Reads and writes go through a single transaction API, and
every commit is crash-safe.

## Compiler requirement

Requires a Bit compiler newer than the released 0.25.0. `create` opens the
database file exclusively through `std/fs/secure`'s `createExclusive`, which
has not shipped in a release yet. With 0.25.0 or older, a build fails at
compile time with "cannot find symbol createExclusive" (E0045), never
silently. `bit.json` has no field for a minimum compiler version, so this is
stated here rather than enforced.

## Install

```json
{
  "dependencies": {
    "kv": "bitlang.org/pkg/kv@v0.1.0"
  }
}
```

## Usage

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

Transactions, rollback, and the typed `Collection` layer with secondary
indexes are in [`docs/`](docs/README.md).

For how first-party packages in this repository are laid out, gated,
versioned and released, see [`pkg/README.md`](../README.md).
