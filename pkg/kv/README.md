# pkg/kv

An embedded, ordered key-value store: one file on disk, no server to run, no
network round trip. `open` is the only entry point; every value is a plain
`@json` class, and every write is crash-safe.

## Compiler requirement

Requires a Bit compiler newer than the released 0.25.0. `open` creates the
database file exclusively through `std/fs/secure`'s `createExclusive`, which
has not shipped in a release yet. With 0.25.0 or older, a build fails at
compile time with "cannot find symbol createExclusive" (E0045), never
silently. `bit.json` has no field for a minimum compiler version, so this is
stated here rather than enforced.

## Install

`bit add bitlang.org/pkg/kv@v0.2.1` writes:

```json
{
  "dependencies": {
    "kv": "bitlang.org/pkg/kv@v0.2.1"
  }
}
```

## Usage

```bit
import { open } from "kv"

@json class User {
  name: string,
  email: string,
}

@json @collection("sessions") class Session { // your own name
  userId: i64,
  token: string,
}

fn main(): ()! {
  let store = open("app.db")?

  let users = store.collection<User>()       // named "user"
  let sessions = store.collection<Session>() // named "sessions"

  users.set(1, User{ name = "Sara", email = "sara@example.com" })?
  let sara = users.get(1)?
  let everyone = users.all()?
  users.delete(1)?

  store.tx((t) => {
    t.collection<User>().set(2, User{ name = "Omar", email = "omar@example.com" })?
    t.collection<Session>().set(2, Session{ userId = 2, token = "abc" })?
  })?
}
```

`set`/`get`/`delete`/`all` take an `i64` id you choose and run in their own
transaction when called outside `store.tx`; every write inside one
`store.tx((t) => {...})` block commits or rolls back together. Getting
started, transactions, and the secondary-index layer are in
[`docs/`](docs/README.md).

For how first-party packages in this repository are laid out, gated,
versioned and released, see [`pkg/README.md`](../README.md).
