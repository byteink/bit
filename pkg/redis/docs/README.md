# pkg/redis docs

| Chapter | Covers |
| ------- | ------ |
| [Connecting](connecting.md) | Opening a connection, the `command()` escape hatch, closing it |
| [Commands](commands.md) | The full named method surface on `Client` |
| [Hashes](hashes.md) | `r.hash(key)`: fields, counters, `scan`, field expiry |
| [RESP2](resp.md) | The wire protocol: `Reply`, nil vs. empty, errors, what is not implemented |
