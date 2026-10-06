# pkg/orm docs

| Chapter | Covers |
| ------- | ------ |
| [Naming](naming.md) | Mapping a `@table` class's field names to SQL table and column names |
| [Schema](schema.md) | Declaring and altering tables, columns, indexes and foreign keys as an intent tree, never SQL text |
| [Dialect](dialect.md) | Rendering that intent tree to real DDL behind a `Dialect` interface, `Postgres` first |
| [MySQL](mysql.md) | The second `Dialect`: every place its DDL diverges from Postgres in one table, why every statement it renders is non-transactional, and why the migration runner has no lock on it |
| [JSON columns](json.md) | `t.json`/`t.addJson`: a `jsonb`/`json` column that normalises on write, `jsonColumnValue`/`jsonColumnRead`/`jsonColumnDecode<T>` for a `Json` tree or a `@json` class field, and why a SQL NULL and a JSON `null` stay distinct |
| [Enum columns](enum.md) | `enumColumnDef`: a `text` column with a CHECK constraint listing every variant by name, `enumColumnValue`/`enumColumnRead` for the round trip, and why reordering the enum emits nothing while renaming a variant's stored name does not |
| [Query](query.md) | `db.table<T>()`'s find chain: `where`/`orderBy`/`limit`/`offset`/`after`/`with`, `all`/`first`/`find`, with a compile-time check on a string-literal column name |
| [Raw SQL and transactions](raw.md) | `db.exec`/`db.query<T>` for a statement `Repo<T>` has no shape for, and `db.tx((tx) => { ... })?` for an all-or-nothing block |
| [Write](write.md) | `insert`/`update`/`delete` on `Repo<T>`, bulk writes (`insertAll`, `set().updateAll()`, `deleteAll`), and `@version` optimistic locking with `StaleWriteError` |
| [Timestamps](timestamps.md) | `@timestamps`: filling `createdAt` on INSERT and `updatedAt` on every write, single or bulk |
| [Errors](errors.md) | Turning a driver's constraint-violation error into a typed, catchable cause via `classify`, decided from SQLSTATE, never message text |
| [Relations](relation.md) | `hasMany`/`hasOne`/`belongsTo` a relation the compiler loads when you read it (explicit `with()` where it cannot trace the read), batched so N parent rows never issue more than one extra query per relation |
| [Many-to-many](manytomany.md) | `@manyToMany` and `Repo<T>.link`/`unlink` on the join table |
| [Soft delete](softdelete.md) | `@softDelete`: `delete` marks a row instead of removing it, every ordinary read excludes it, `withDeleted`/`restore`/`forceDelete` opt in |
| [Row locking](locking.md) | `tx.table<T>().lock(mode)`/`LockMode`: `Update` blocks until a row is free, `SkipLocked`/`NoWait` return or fail immediately instead of waiting, only reachable from inside a transaction |
| [Apply migrations](migrate.md) | `bit make migration`/`bit migrate`/`bit migrate status`/`bit migrate rollback`: one file per migration under `migrations/`, applied against a live database in file-name order with no hand-written registry, one transaction per migration with the ledger row inside it, an advisory lock around the whole run |
| [Check the schema in CI](check.md) | `check`: runs the identical diff `generate` runs and fails naming every disagreement, one line per line, instead of writing a file - column presence, type, and an enum column's CHECK drift |
| [Sync your database automatically](sync.md) | `open(url, Options{ synchronize = true })`: adds any table or column your `@table` classes declare and the live database is missing, in any environment - never drops or renames, a removed field only warns |
| [Logging](logging.md) | `Options.logger` and `QueryLog`: std/log records for every statement, a slow-query warning, a statement counter, and why a bound value never reaches a log line |
| [Testing](testing.md) | `withRollback`: run a test inside a transaction that always rolls back, even on success, so nothing it wrote is ever there to clean up; `make`/`create`/`Seq` build deterministic per-test rows |

`Data`, `Patch` and `Keyset pagination` merged into [Write](write.md) and
[Query](query.md) - `db.table<T>()` replaced the standalone `Data`
parameter, and `after()`/bulk writes cover what those pages taught on their
own. `Bulk insert` and `Optimistic locking` merged into
[Write](write.md) - `insertAll`/`set().updateAll()`/`deleteAll` and
`@version` are one page now, not three.
