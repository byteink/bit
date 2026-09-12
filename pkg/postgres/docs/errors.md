# Errors carry the SQLSTATE

A failure the server reported is a typed error, not a sentence. Ask it for
the shape you need, and decide what to do by `sqlState()`, never by parsing
the message text:

```bit
import { Pool, Value } from "std/sql"

interface SqlError { message(): string, sqlState(): string }

fn retry(): int! {
  return 0
}

fn execWithRetry(db: Pool, sql: string, params: []Value): int! {
  return db.exec(sql, params) catch e {
    let (pg, ok) = e.(SqlError)
    if (!ok || (pg.sqlState() != "40001" && pg.sqlState() != "40P01")) {
      fail e
    }
    retry()?
  }
}
```

`23505` is a unique violation and is not retryable; `40001` (serialization
failure) and `40P01` (deadlock detected) are. Telling them apart by message
text is how retry loops get written wrong.

Every exchange is drained to `ReadyForQuery`, so a statement that failed -
including one that failed halfway through a result set - leaves the
connection usable, and the next borrower from the pool never inherits a
half-read stream.
