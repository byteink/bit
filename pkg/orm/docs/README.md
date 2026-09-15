# pkg/orm docs

| Chapter | Covers |
| ------- | ------ |
| [Data](data.md) | The `Data` interface, why an ORM function takes it instead of `Pool`, and the transaction call shapes |
| [Naming](naming.md) | Mapping a `@table` class's field names to SQL table and column names |
| [Schema](schema.md) | Declaring and altering tables, columns, indexes and foreign keys as an intent tree, never SQL text |
| [Query](query.md) | The find chain: where/whereIn/whereNull/whereLike/orderBy/limit/offset, with a compile-time check on a string-literal column name |
