# Errors

## Matching a server error

A server-side failure carries the server's own error code and SQLSTATE, but
the class that holds them is deliberately **not exported** - `adapter` stays
this package's only exported symbol, so a caller matches on a shape rather
than on a driver's concrete type, and still compiles after a driver swap:

```bit
import { Pool, Value } from "std/sql"

interface SqlError {
  message(): string
  errorCode(): int
  sqlState(): string
}

fn isDeadlock(db: Pool, sqlText: string): bool! {
  db.exec(sqlText, []Value(0)) catch e {
    let (my, ok) = e.(SqlError)
    if (ok && my.errorCode() == 1213) {
      return true
    }
    fail e
  }
  return false
}
```

`errorCode()` is the server's own number - `1062` duplicate key, `1213`
deadlock, and so on - and `sqlState()` is the five-character SQLSTATE with the
leading `#` stripped, such as `"23000"`. Matching on the number is what
survives a server upgrade; the English text behind `message()` changes between
versions and locales.

`errorCode()` and `sqlState()` come from the server's own `ERR` packet: a
0xFF marker, the two-byte code, `#` and the five-byte SQLSTATE, then the
message. A packet too short to hold them is reported as malformed rather than
parsed into zeros.

## `FatalError` and the connection pool

A failure that reaches the caller before anything was written to the socket -
a bad placeholder count, a duplicate-key `ERR` packet - leaves the connection
usable, and `std/sql.pool` hands it out again. A failure below the send - a
closed socket, a short read, a protocol desync - is reported through
`std/sql`'s `FatalError` marker instead, and the pool discards that connection
rather than reusing it. This package never has to name `FatalError` at a call
site: `transportError`, from `std/sql`, already implements it.
