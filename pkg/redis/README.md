# pkg/redis

Your leaderboard needs player names, changing scores and a quick top ten.
Redis stores names in a hash and keeps scores ordered in a sorted set, so
you can read the board without sorting every player yourself.

This client uses RESP3 by default and falls back to RESP2 for older servers.

## Install

`bit add bitlang.org/pkg/redis@^0.4.0` writes:

```json
{
  "dependencies": {
    "redis": "bitlang.org/pkg/redis@^0.4.0"
  }
}
```

## Start a leaderboard

```bit
import { open } from "redis"
import { Hour } from "std/time"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  r.set("leaderboard:season", "autumn", ttl = 24 * Hour, ifAbsent = false, ifExists = false)?
  let p = r.pipeline()
  let names = p.hash("leaderboard:names").set(map<string, string>{ "ada": "Ada" })
  let score = p.zset("leaderboard:scores").add("ada", 1200.0)
  p.exec()?
  names.get()?
  score.get()?
  for entry of r.zset("leaderboard:scores").top(10)? {
    let name = r.hash("leaderboard:names").get(entry.member)?
    println("${unwrapOr(name, entry.member)}: ${entry.score}")
  }
  r.close()
  return
}
```

Run the example against a local Redis server. `set` takes a duration in
nanoseconds; `Hour` supplies that unit. The pipeline queues the two writes,
then `exec` makes their results available through `get`.

Continue with the [leaderboard guide](docs/README.md). It covers connections,
names, scores, [pipelines and transactions](docs/pipelines-and-transactions.md)
and [handling errors](docs/errors.md). Cluster routing is not supported.

For how first-party packages in this repository are laid out, gated,
versioned and released, see [`pkg/README.md`](../README.md).
