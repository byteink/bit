# Pub/sub

<!-- doctest: per-block -->

A match is on and the scoreboard page must change the moment a goal goes in,
without every browser polling the database. Redis pub/sub is built for this:
the service that records a goal publishes it on a channel, and every process
that cares is subscribed to that channel and hears it at once.

```bit
import { open } from "redis"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let live = r.subscribe("scores:match:41")?

  let heard = r.publish("scores:match:41", "Lions 1 - 0 Tigers")?
  println("${heard} subscriber heard it") // 1

  for msg of live {
    println("${msg.channel}: ${msg.payload}") // scores:match:41: Lions 1 - 0 Tigers
    break
  }
  live.close()
  r.close()
  return
}
```

`r.subscribe("scores:match:41")` returns once the server has confirmed the
subscription, so a `publish` on the next line is never missed. `publish`
returns how many subscribers received the message, `0` when nobody was
listening. `for msg of live` waits for each message in turn; every `msg` is a
`Message` with the `channel` it arrived on and its `payload`.

A subscription is its own connection. A connection that is subscribed cannot
run other commands, so `subscribe` never takes one from the pool: it dials a
dedicated connection with the same `Options` the client was opened with, and
`close()` gives it back. The client itself stays free to `publish` and run
every other command meanwhile.

## Following several matches at once

A scoreboard shows every match of a tournament, and new matches appear while
it runs. `psubscribe` takes glob patterns instead of channel names, and a
`Message` from it names the pattern that matched in `pattern`.

```bit
import { open } from "redis"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let board = r.psubscribe("scores:match:*")?

  r.publish("scores:match:42", "Wolves 0 - 0 Bears")?
  match (board.next()) {
    Some(msg) => {
      println("${msg.channel}: ${msg.payload}") // scores:match:42: Wolves 0 - 0 Bears
      match (msg.pattern) {
        Some(p) => println("matched ${p}") // matched scores:match:*
        None => println("(a channel subscription)")
      }
    }
    None => println("subscription closed")
  }
  board.close()
  r.close()
  return
}
```

`next()` is what `for msg of` calls: it blocks for the next message and
returns `None` once the subscription is closed and drained.

## Changing what you follow

A visitor opens a second match in another tab: the same subscription should
start following it, with no second connection. `add` subscribes to more
names and `remove` drops some; both return once the server confirmed, and
skip names that are already (or not) subscribed. `names()` lists what the
subscription follows now.

```bit
import { open } from "redis"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let live = r.subscribe("scores:match:41")?

  live.add("scores:match:42", "scores:match:41")?
  println("${len(live.names())} channels") // 2, the duplicate is skipped

  live.remove("scores:match:41")?
  let heard = r.publish("scores:match:41", "Lions 2 - 0 Tigers")?
  println("${heard} subscribers on match 41") // 0, removed

  live.close()
  r.close()
  return
}
```

One subscription follows one kind of name: channels from `subscribe`,
patterns from `psubscribe`, shard channels from `ssubscribe`. `add` and
`remove` work on that kind.

## Waiting for scores beside something else

`for msg of live` is enough when the subscription is all a task does. A
service that also has to notice a shutdown signal or a timer wants
`messages()`, the same stream as a channel, so `select` can wait on it beside
the others.

```bit
import { open } from "redis"
import { after, Second } from "std/time"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let live = r.subscribe("scores:match:41")?
  r.publish("scores:match:41", "Lions 3 - 0 Tigers")?

  let quiet = after(2 * Second)
  let running = true
  while (running) {
    select {
      case msg = <- live.messages():
        println(msg.payload) // Lions 3 - 0 Tigers
      case _ = <- quiet:
        println("no goals for 2s")
        running = false
    }
  }
  live.close()
  r.close()
  return
}
```

The channel closes exactly when `next()` would return `None`.

## Sharded channels

On a cluster, a normal `publish` is sent to every node. `ssubscribe` and
`spublish` use sharded channels: the message stays on the shard that owns the
channel. They work the same way on a single server.

```bit
import { open } from "redis"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let live = r.ssubscribe("scores:final")?
  let heard = r.spublish("scores:final", "Lions win")?
  println("${heard} shard subscriber") // 1
  match (live.next()) {
    Some(msg) => println(msg.payload) // Lions win
    None => println("closed")
  }
  live.close()
  r.close()
  return
}
```

## Seeing who is listening

The `PUBSUB` commands report the server's current subscriptions: which
channels have a subscriber, how many subscribers each has, and how many
patterns are in use.

```bit
import { open } from "redis"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let live = r.subscribe("scores:match:41")?
  let board = r.psubscribe("scores:match:*")?
  let shard = r.ssubscribe("scores:final")?

  let active = r.pubsubChannels("scores:match:*")?
  println("${len(active)} active") // 1
  let counts = r.pubsubNumSub("scores:match:41", "scores:match:99")?
  println("${counts["scores:match:41"]} and ${counts["scores:match:99"]}") // 1 and 0
  let patterns = r.pubsubNumPat()?
  println("${patterns} patterns") // 1
  let shards = r.pubsubShardChannels()?
  println("${len(shards)} shard channel") // 1
  let shardCounts = r.pubsubShardNumSub("scores:final")?
  println("${shardCounts["scores:final"]} shard subscriber") // 1

  live.close()
  board.close()
  shard.close()
  r.close()
  return
}
```

`pubsubChannels` and `pubsubShardChannels` take an optional glob pattern.

## When the connection drops

A restart, a failover or a network blip drops the subscriber's connection.
The subscription redials with exponential backoff and jitter (100 ms
doubling to 5 s, at most ten attempts), then subscribes to everything again,
and the iterator keeps going as if nothing happened. **Messages published
while the connection was down are lost**: Redis pub/sub does not replay. A
scoreboard shrugs that off; a system that cannot miss a message uses a
[stream](streams.md) instead.

When all ten attempts fail, the subscription ends: `next()` returns `None`
and `failure()` says why. `failure()` is `None` after a plain `close()`.

```bit
import { open } from "redis"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let live = r.subscribe("scores:match:41")?
  for msg of live {
    println(msg.payload)
  }
  match (live.failure()) {
    Some(e) => println("lost the server: ${e.message()}")
    None => println("closed")
  }
  r.close()
  return
}
```

## A reader that falls behind

A page that renders slower than goals arrive must not grow memory without
bound, and it must not stall the connection either: Redis disconnects a
subscriber that stops reading. A subscription keeps the newest messages in a
buffer of `Options.subscribeBuffer` (256 by default). When the buffer is
full, the **oldest** message is discarded, and `dropped()` counts how many
were.

```bit
import { Options, connect } from "redis"
import { sleep, Millisecond } from "std/time"

fn main(): ()! {
  let r = connect(Options{ subscribeBuffer = 2 })?
  let live = r.subscribe("scores:match:41")?
  r.publish("scores:match:41", "1-0")?
  r.publish("scores:match:41", "2-0")?
  r.publish("scores:match:41", "3-0")?
  while (live.dropped() < 1) {
    sleep(10 * Millisecond)
  }
  println("${live.dropped()} dropped") // 1, the oldest goal
  match (live.next()) {
    Some(msg) => println(msg.payload) // 2-0
    None => println("closed")
  }
  live.close()
  r.close()
  return
}
```
