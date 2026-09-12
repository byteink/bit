# Connecting

Open a connection to a Redis (or RESP2-compatible) server and run a first
command against it.

```bit
import { connect } from "redis"

fn main(): ()! {
  let c = connect("127.0.0.1", 6379)?
  let pong = c.ping()?
  println(pong)
  c.close()
  return
}
```

`connect(host, port): Client!` dials plain TCP - no auth, no TLS, the same
scope `std/net` itself has. Call `c.close()` once, when the caller is done
with the client; there is no connection pool underneath it.

Every named method on `Client` (see [Commands](commands.md)) is built on one
generic escape hatch:

```bit
import { connect } from "redis"

fn main(): ()! {
  let c = connect("127.0.0.1", 6379)?
  let reply = c.command(["PING"])?
  match (reply) {
    Simple(s) => println(s)
    _ => println("unexpected reply")
  }
  c.close()
  return
}
```

`command(args): Reply!` sends any command and returns its raw decoded
`Reply`, so a command this package has not named yet never blocks a caller.
A `-ERR ...` reply from the server surfaces as a `fail` from `command()` -
and from every named method built on it - the same as any other failure; a
caller distinguishes it from a connection error only by message.
