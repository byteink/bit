# Update a leaderboard with fewer round trips

<!-- doctest: per-block -->

Registering a player writes a display name and an initial score. Waiting for
each reply before sending the next command adds a network round trip even
though neither write needs the other's result. A pipeline queues both and
sends them together.

```bit
import { open, Future } from "redis"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let p = r.pipeline()
  let names: Future<i64> = p.hash("leaderboard:names").set(
    map<string, string>{ "ada": "Ada" },
  )
  let score = p.zset("leaderboard:scores").add("ada", 1200.0)
  p.exec()?
  println("${names.get()?} name fields added; ${score.get()?} new players")
  r.close()
  return
}
```

Queuing returns a `Future<T>` without contacting the server. Call `exec()`
before `get()`: reading a future before execution fails with `RedisError.Closed`.
Use a new pipeline for each batch. Do not queue more work into one you have
already executed.

The queued handles mirror the ordinary handles: `p.hash`, `p.zset` and
`p.counter` return futures where their immediate forms return values.
Pipelining does not make the writes atomic; another client can observe the
name before the score appears.

## Queue a custom command

The board also counts page views. `Cmd<T>` combines command arguments with
the function that decodes the reply. Its `readOnly` flag describes what the
command does; an increment writes, even though its result is an integer.

```bit
import { open, Cmd, asInt } from "redis"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let p = r.pipeline()
  let views = p.queue(
    Cmd<i64>{
      args = ["INCR", "leaderboard:views"],
      decode = (reply) => asInt(reply, "INCR"),
      readOnly = false,
    },
  )
  p.exec()?
  println("${views.get()?} leaderboard views")
  r.close()
  return
}
```

`asInt` accepts an integer reply and reports a typed error for another shape.
`queue` is also available inside a transaction. Use it when a named handle
does not provide the command you need, rather than building another client.

## Check a limit before changing a score

Independent writes fit a pipeline. A rule such as "Ada can update her score
three times today" needs a read followed by writes that still agree with that
read. A transaction watches the keys you list and tries again if another
client changes them before the commands commit.

```bit
import { open, Future, RedisError } from "redis"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let updates = "leaderboard:2026-10-12:ada:updates"
  let scores = "leaderboard:scores"
  let score = r.transaction<Future<f64>>([updates, scores], (tx) => {
    let used = tx.read.counter(updates).get()?
    if (used >= 3) {
      fail RedisError.Invalid("daily score update limit reached")
    }
    tx.counter(updates).incr()
    return tx.zset(scores).incrBy("ada", 50.0)
  })?
  println("Ada's committed score: ${score.get()?}")
  r.close()
  return
}
```

`tx.read` performs reads immediately on the transaction's connection.
`tx.counter` and `tx.zset` queue writes. The returned future belongs to the
successful attempt and is ready when `transaction` returns. Include every
key whose changes would invalidate your decision in the watched-key list.
Use your application's current date in the daily key, and expire old daily
keys when they are no longer needed.

The callback may run again after a watched-key conflict. Each attempt gets
fresh queued results; do not save an attempt's futures elsewhere. Keep email,
payments and other external effects outside the callback. After ten watched
conflicts, the client returns `RedisError.ExecAbort`.

## When a batch fails

If a pipeline receives a server error, it reads the remaining replies to
leave the connection usable, returns the first error and leaves its futures
unfilled. Some commands may already have succeeded. A transport failure can
also leave you unsure which writes ran; repeating the whole batch can repeat
them.

A transaction does not undo commands that fail during execution. Redis runs
the other queued commands, so validate inputs before queuing and handle the
error. A watched-key conflict is different: the queued writes did not run,
and the callback can safely reconsider its reads.

For a decision that belongs entirely on the server, use a short
[script](scripting.md), including the sliding-window rate-limit example.
Continue with [handling errors](errors.md) or [sorted sets](sorted-sets.md)
to read the updated board.
