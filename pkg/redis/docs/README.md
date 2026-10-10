# pkg/redis docs

| Chapter | Covers |
| ------- | ------ |
| [Connecting](connecting.md) | Opening a connection, the `command()` escape hatch, closing it |
| [Commands](commands.md) | The full named method surface on `Client` |
| [Lists](lists.md) | `r.list(key)`: queues and stacks, `popAny`, `move`, blocking pops, reads inside a transaction |
| [Streams](streams.md) | `r.stream(key)`: an event log, consumer groups, claiming a dead worker's entries, `XINFO` |
| [Hashes](hashes.md) | `r.hash(key)`: fields, counters, `scan`, field expiry, reads inside a transaction |
| [Sets](sets.md) | `r.sset(key)`: members, set algebra, `scan`, reads inside a transaction |
| [Sorted sets](sorted-sets.md) | `r.zset(key)`: leaderboards, ranges by rank, score or name, blocking pops, combining boards |
| [Locations, unique counts and bitmaps](geo-hll-bitmaps.md) | `r.geo(key)`, `r.hll(key)`, `r.bitmap(key)`: nearby search, HyperLogLog counts, `BITOP`, `BITFIELD` |
| [Articles as JSON documents](json.md) | `r.json(key)`: paths, writing a part, counters and flags in place, arrays, several articles at once, reads inside a transaction |
| [Strings and keys](strings-and-keys.md) | `set`/`get` options, `r.str(key)`, `r.keys()`: TTLs, `TYPE`, `RENAME`, `SCAN`, reads inside a transaction |
| [Pub/sub](pubsub.md) | `r.subscribe`, `psubscribe`, `ssubscribe`: live score updates, adding and removing channels, reconnects, a slow reader, `publish` and `PUBSUB` |
| [Scripting](scripting.md) | `Script`: EVALSHA with automatic load, `Fn` and `Functions`, scripts in pipelines, read-only scripts |
| [RESP2](resp.md) | The wire protocol: `Reply`, nil vs. empty, errors, what is not implemented |
