# pkg/redis docs

| Chapter | Covers |
| ------- | ------ |
| [Connecting](connecting.md) | Opening a connection, the `command()` escape hatch, closing it |
| [Commands](commands.md) | The full named method surface on `Client` |
| [Hashes](hashes.md) | `r.hash(key)`: fields, counters, `scan`, field expiry |
| [Strings and keys](strings-and-keys.md) | `set`/`get` options, `r.str(key)`, `r.keys()`: TTLs, `TYPE`, `RENAME`, `SCAN` |
| [RESP2](resp.md) | The wire protocol: `Reply`, nil vs. empty, errors, what is not implemented |
