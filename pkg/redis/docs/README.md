# pkg/redis docs

| Chapter | Covers |
| ------- | ------ |
| [Connecting](connecting.md) | Opening a connection, the `command()` escape hatch, closing it |
| [Commands](commands.md) | The full named method surface on `Client` |
| [Lists](lists.md) | `r.list(key)`: queues and stacks, `popAny`, `move`, blocking pops |
| [Streams](streams.md) | `r.stream(key)`: an event log, consumer groups, claiming a dead worker's entries, `XINFO` |
| [Hashes](hashes.md) | `r.hash(key)`: fields, counters, `scan`, field expiry |
| [Sets](sets.md) | `r.sset(key)`: members, set algebra, `scan`, reads inside a transaction |
| [Strings and keys](strings-and-keys.md) | `set`/`get` options, `r.str(key)`, `r.keys()`: TTLs, `TYPE`, `RENAME`, `SCAN` |
| [Scripting](scripting.md) | `Script`: EVALSHA with automatic load, `Fn` and `Functions`, scripts in pipelines, read-only scripts |
| [RESP2](resp.md) | The wire protocol: `Reply`, nil vs. empty, errors, what is not implemented |
