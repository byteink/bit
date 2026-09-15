# pkg/orm docs

| Chapter | Covers |
| ------- | ------ |
| [Data](data.md) | The `Data` interface, why an ORM function takes it instead of `Pool`, and the transaction call shapes |
| [Naming](naming.md) | Mapping a `@table` class's field names to SQL table and column names |
| [Schema](schema.md) | Declaring and altering tables, columns, indexes and foreign keys as an intent tree, never SQL text |
| [Dialect](dialect.md) | Rendering that intent tree to real DDL behind a `SchemaDialect` interface, `Postgres` first |
| [Query](query.md) | The find chain: where/whereIn/whereNull/whereLike/orderBy/limit/offset, with a compile-time check on a string-literal column name |
| [Write](write.md) | `save`, `delete` and `upsert`: INSERT vs UPDATE decided by the persisted flag, never the primary key, and why 0 rows matched is an error |
| [Errors](errors.md) | Turning a driver's constraint-violation error into a typed, catchable cause via `classify`, decided from SQLSTATE, never message text |
