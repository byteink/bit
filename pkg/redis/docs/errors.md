# Handle a refused score update

<!-- doctest: per-block -->

A score update can fail because the leaderboard key holds the wrong kind of
data, the server is unavailable, or your credentials cannot write it. Those
failures need different responses. Redis methods return a typed `RedisError`,
so you can handle the cause without searching its message text.

```bit
import { open, RedisError } from "redis"

fn updateScore(): ()!RedisError {
  let r = open("redis://localhost:6379")?
  let result = r.zset("leaderboard:scores").incrBy("ada", 50.0) catch e {
    r.close()
    fail e
  }
  println("Ada's score: ${result}")
  r.close()
  return
}

fn main() {
  updateScore() catch e {
    println(e.message())
    match (e) {
      WrongType(_) => println("Check which code wrote the leaderboard key.")
      NoAuth(_) => println("Check the connection credentials.")
      NoPerm(_) => println("Allow score updates for this Redis user.")
      _ => {
        if (e.retryable()) {
          println("The server may recover; first check whether the score changed.")
        }
      }
    }
  }
}
```

`message()` gives you readable context for a log. `WrongType` means the key
has the wrong Redis type; deleting it blindly can erase another feature's
data. Authentication and permission failures need configuration changes.
`Invalid` reports invalid input, `Unexpected` a reply with the wrong shape,
and `Protocol` a connection that did not speak the expected protocol.

## Decide what can be retried

`retryable()` is true for `Io`, `Timeout`, `Loading`, `Busy`, `TryAgain` and
`ClusterDown`. It classifies a condition that may clear. It does not tell you
whether the server already performed your command.

A lost reply to `incrBy` can follow a successful score change. Repeating the
write can award the points twice. The client retries eligible reads once on
a fresh connection, but does not automatically repeat writes. Return the
failure or reconcile the operation before retrying it.

You normally receive typed errors directly from the client. If another
component hands you a raw Redis server-error body, `fromServer` converts it
to the same variants. Pass the body without its leading protocol `-`.

```bit
import { fromServer } from "redis"

fn main() {
  let e = fromServer("LOADING Redis is loading the dataset in memory")
  println(e.message())
  assert(e.retryable())
  match (e) {
    Loading(_) => println("Wait for the server to finish loading.")
    _ => println("Handle the reported cause.")
  }
}
```

Unknown server codes remain `Server(code, message)` rather than disappearing.
Do not use `fromServer` on an arbitrary network error or an entire RESP reply;
it parses a server-error body, not the wire protocol.

Continue with [pipelines and transactions](pipelines-and-transactions.md)
for failures affecting several commands, or [connecting](connecting.md)
for connection timeouts and TLS.
