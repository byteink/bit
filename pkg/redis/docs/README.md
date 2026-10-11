# Build a leaderboard with Redis

Players submit scores, the board shows their names, and repeated submissions
need a limit. Start with the [README example](../README.md), then grow that
same board one step at a time.

1. [Connect](connecting.md) once and share the client; choose a URL or TLS options.
2. [Strings and keys](strings-and-keys.md) store the season and its expiry.
3. [Hashes](hashes.md) map player ids to display names.
4. [Sorted sets](sorted-sets.md) update scores and read the top ten.
5. [Pipelines and transactions](pipelines-and-transactions.md) batch independent writes or check a limit before committing an update.
6. [Scripting](scripting.md) builds a sliding-window rate limit using the server's clock.
7. [Handle errors](errors.md) when the server refuses a command or a connection fails.

A pipeline saves round trips; it does not make a group of commands atomic.
Use a watched transaction when an update depends on a value you read, or a
short script when the whole decision must run on the server. The pages below
cover the other structures you can add as the application grows.

| Chapter | Covers |
| ------- | ------ |
| [Connecting](connecting.md) | Opening a connection, the `command()` escape hatch, closing it |
| [Commands](commands.md) | Basic `Client` methods and raw command replies |
| [Pipelines and transactions](pipelines-and-transactions.md) | Queued results, custom commands, watched reads and retries |
| [Errors](errors.md) | Typed failures, messages and safe retry decisions |
| [Lists](lists.md) | `r.list(key)`: queues and stacks, `popAny`, `move`, blocking pops, reads inside a transaction |
| [Streams](streams.md) | `r.stream(key)`: an event log, consumer groups, claiming a dead worker's entries, `XINFO` |
| [Hashes](hashes.md) | `r.hash(key)`: fields, counters, `scan`, field expiry, reads inside a transaction |
| [Sets](sets.md) | `r.sset(key)`: members, set algebra, `scan`, reads inside a transaction |
| [Sorted sets](sorted-sets.md) | `r.zset(key)`: leaderboards, ranges by rank, score or name, blocking pops, combining boards |
| [Locations, unique counts and bitmaps](geo-hll-bitmaps.md) | `r.geo(key)`, `r.hll(key)`, `r.bitmap(key)`: nearby search, HyperLogLog counts, `BITOP`, `BITFIELD` |
| [Seen, trending and percentiles](probabilistic.md) | `r.bloom(key)`, `r.cuckoo(key)`, `r.cms(key)`, `r.topk(key)`, `r.tdigest(key)`: has this been seen, how often, the top items, p99 latency |
| [Similar players and per-round scores](vectors-and-arrays.md) | `r.vset(key)`, `r.array(key)`: nearest-neighbour search with attribute filters, sparse `u64`-indexed arrays, cursors, rings, `ARGREP`, `AROP` |
| [Searching articles](search.md) | `r.search(index)`: the Query Engine: schema builder, typed queries, `FT.SEARCH` options, JSON documents, vector KNN and hybrid queries, `FT.AGGREGATE` and cursors, aliases, suggestions, spellcheck, synonyms |
| [Articles as JSON documents](json.md) | `r.json(key)`: paths, writing a part, counters and flags in place, arrays, several articles at once, reads inside a transaction |
| [Strings and keys](strings-and-keys.md) | `set`/`get` options, `r.str(key)`, `r.keys()`: TTLs, `TYPE`, `RENAME`, `SCAN`, reads inside a transaction |
| [Requests per minute: time series](timeseries.md) | `r.timeseries(key)`, `r.timeseriesMulti()`: samples, counting, aggregated ranges, label filters, grouping, compaction rules |
| [Pub/sub](pubsub.md) | `r.subscribe`, `psubscribe`, `ssubscribe`: live score updates, adding and removing channels, reconnects, a slow reader, `publish` and `PUBSUB` |
| [Scripting](scripting.md) | `Script`: EVALSHA with automatic load, `Fn` and `Functions`, scripts in pipelines, read-only scripts |
| [RESP2](resp.md) | The wire protocol: `Reply`, nil vs. empty, errors, what is not implemented |
