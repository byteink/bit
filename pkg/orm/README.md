# bitlang.org/pkg/orm

An ORM for `std/sql`, built on `@table` (SPEC section 10.5's class attribute)
and the descriptor it synthesizes. This package is under active development
(epic #5050); today it exports `Data`, the interface every ORM function is
written against instead of a concrete `Pool`.

## Install

```json
{
  "dependencies": {
    "orm": "bitlang.org/pkg/orm@v0.1.0"
  }
}
```

## Usage

```bit
import { Data } from "orm"
import { Value } from "std/sql"

// Written once, against Data instead of a concrete Pool: runs standalone
// (its own transaction per statement) or inside a caller's `pool.tx(...)`
// block (one transaction for the whole call), with no second version.
fn transfer(db: Data, fromId: i64, toId: i64, amt: i64): ()! {
  db.exec("update accounts set balance = balance - ${amt} where id = ${fromId}", []Value(0))?
  db.exec("update accounts set balance = balance + ${amt} where id = ${toId}", []Value(0))?
}
```

See [`docs/data.md`](docs/data.md) for `Data` and the call sites (`pool`
alone, `pool.tx(...)`, `pool.txValue<T>(...)`).

For how first-party packages in this repository are laid out, gated,
versioned and released, see [`pkg/README.md`](../README.md).
