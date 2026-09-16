# pkg/orm docs

| Chapter | Covers |
| ------- | ------ |
| [Data](data.md) | The `Data` interface, why an ORM function takes it instead of `Pool`, and the transaction call shapes |
| [Naming](naming.md) | Mapping a `@table` class's field names to SQL table and column names |
| [Schema](schema.md) | Declaring and altering tables, columns, indexes and foreign keys as an intent tree, never SQL text |
| [Dialect](dialect.md) | Rendering that intent tree to real DDL behind a `Dialect` interface, `Postgres` first |
| [MySQL](mysql.md) | The second `Dialect`: every place its DDL diverges from Postgres in one table, why every statement it renders is non-transactional, and why the migration runner has no lock on it |
| [JSON columns](json.md) | `t.json`/`t.addJson`: a `jsonb`/`json` column that normalises on write, `jsonColumnValue`/`jsonColumnRead`/`jsonColumnDecode<T>` for a `Json` tree or a `@json` class field, and why a SQL NULL and a JSON `null` stay distinct |
| [Enum columns](enum.md) | `enumColumnDef`: a `text` column with a CHECK constraint listing every variant by name, `enumColumnValue`/`enumColumnRead` for the round trip, and why reordering the enum emits nothing while renaming a variant's stored name does not |
| [Query](query.md) | The find chain: where/whereIn/whereNull/whereLike/orderBy/limit/offset, with a compile-time check on a string-literal column name |
| [Raw SQL and dynamic columns](raw.md) | `whereRaw`: a SQL fragment plus its own bound arguments. `orderByField`: a column name from outside your program, checked against an allowlist, never escaped |
| [Write](write.md) | `save`, `delete` and `upsert`: INSERT vs UPDATE decided by the persisted flag, never the primary key, and why 0 rows matched is an error |
| [Patch](patch.md) | `update`/`deleteMany`: writing or removing rows by a `where` clause with no instance loaded, for a single column or a bulk write |
| [Timestamps](timestamps.md) | `@timestamps`: filling `createdAt` on INSERT and `updatedAt` on every write, single or bulk |
| [Errors](errors.md) | Turning a driver's constraint-violation error into a typed, catchable cause via `classify`, decided from SQLSTATE, never message text |
| [Bulk insert](bulk.md) | `insertAll`: many rows in one statement, chunked at a computed placeholder limit, never one statement per row |
| [Keyset pagination](keyset.md) | `after`: `WHERE id > $n` instead of `OFFSET`, so a deep page costs what page 1 costs |
| [Relations](relation.md) | `hasMany`/`hasOne`/`belongsTo` and eager loading via `with()`, batched so N parent rows never issue more than one extra query per relation |
| [Many-to-many](manytomany.md) | `@manyToMany`, `manyToManyTable`, `manyToManyLoader` and `attach`/`detach`/`sync` on the join table, with the join table name always an explicit argument, never inferred |
| [Soft delete](softdelete.md) | `@softDelete`: `delete` marks a row instead of removing it, every ordinary read excludes it, `withTrashed`/`onlyTrashed`/`restore`/`forceDelete` opt in |
| [Optimistic locking](version.md) | `@version`: `save`'s UPDATE checks the old version and raises it by one, `StaleWriteError` when another write landed first, distinct from a row-not-found |
| [Row locking](locking.md) | `forUpdate`: `FOR UPDATE` blocks until a row is free, `SKIP LOCKED` never blocks and returns fewer rows than matched, refused outside a transaction and on `count()`/`exists()` |
| [Generate migrations](generate.md) | `generate`: diffs your `@table` entities against the live schema and writes a reviewed migration file, never applying anything and never inferring a rename |
| [Apply migrations](migrate.md) | `up`/`status`/`sql`/`down`: applies a checked-in migration registry against a live database, one transaction per migration with the ledger row inside it, an advisory lock around the whole run |
| [Testing](testing.md) | `withRollback`: run a test inside a transaction that always rolls back, even on success, so nothing it wrote is ever there to clean up; `make`/`create`/`Seq` build deterministic per-test rows |
