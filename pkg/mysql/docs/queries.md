# Queries

`std/sql` hands a driver the caller's SQL text and an ordered `[]Value`
separately, and this package keeps them separate all the way to the socket - no
code path here concatenates a value into SQL text.

## Placeholder rewriting

`std/sql` numbers placeholders `$1`, `$2`, ...; MySQL's wire protocol takes
positional `?`. This driver rewrites one into the other before anything is
sent:

```bit
import { Pool, Value } from "std/sql"

fn byId(db: Pool, id: string): Value! {
  let rows = db.query("select name from users where id = $1", [Value.Text(id)])?
  defer rows.close()
  rows.next()?
  return rows.value(0)
}
```

The rewrite is a scanner, not a `replace` call, because MySQL can hide a `$1`
inside a string literal, a backtick or double-quoted identifier, or a `#`,
`-- ` or `/* */` comment - and a misfire that turns one of those into a `?`
shifts every following parameter by one position with no error at all. A
reused placeholder (`where a = $1 or b = $1`) is one parameter written twice on
the wire; a gap (`$1, $3`) still needs three values supplied, since `$3` is
unreachable without them.

## `query`, `exec` and `prepare`

`Conn.query` picks its wire protocol from the rewritten placeholder count: a
statement with none goes out as `COM_QUERY`, one round trip, and its columns
all come back as `Value.Text` regardless of their real type. A statement with
parameters goes through `COM_STMT_PREPARE`/`COM_STMT_EXECUTE`, which binds
values server-side in the binary protocol and reports each column's real type
(`Value.Int`, `Value.Float`, `Value.Text`, `Value.Blob`) - see
[Limitations](limitations.md) for where that typing is still incomplete.
`Conn.exec` always takes the prepared path, even with nothing to bind, because
only the binary protocol's OK packet carries an affected-row count the text
protocol's own result-set framing would otherwise hide.

`Conn.prepare` returns a `Stmt` that can be run more than once. Set
`Datasource.statementCache` above 0 to keep prepared statements across calls
on the same connection, evicted FIFO once the cache is full; it is off by
default because every cached statement holds server-side memory and a table
lock reference for the connection's whole life.

**Transactions are not yet implemented.** `Conn.begin` fails, naming the
tracking epic; see [Limitations](limitations.md).

## The single-packet limit

A bound statement that would exceed 16,777,215 bytes on the wire - the
protocol's multi-packet payload form - fails naming its size rather than being
split across packets or silently truncated.
