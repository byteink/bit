# RESP2

The wire protocol underneath every command: how a command is encoded, how a
reply is decoded, and the one distinction the codec exists to get right - a
nil reply is not the same value as an empty one.

`Reply` is a 5-variant sum type: `Simple(string)`, `Err(string)`, `Int(i64)`,
`Bulk(Option<string>)`, `Array(Option<[]Reply>)`. `Bulk` and `Array` carry
`Option` because RESP has a distinct wire form for "no value" - a cache
miss, a blocking pop that timed out - that is not the same thing as an empty
string or an empty array: `$-1\r\n` (a null bulk string) decodes to
`Bulk(Option.None)`, while `$0\r\n\r\n` (a real, present, empty string)
decodes to `Bulk(Option.Some(""))`. `*-1\r\n` and `*0\r\n` are the same
distinction for arrays. Conflating null with empty is the classic RESP
client defect this package exists not to repeat.

`encodeCommand(args): string` and `decodeReply(source, buf): (Reply, string)!`
are exported directly, independent of `Client`, so a caller can run the
codec against its own byte source - anything with a
`readUp(n: int): string!` method, no interface name to import:

```bit
import { encodeCommand, decodeReply } from "redis"

class fixedSource {
  data: string
  readUp(n: int): string! {
    return this.data
  }
}

fn main(): ()! {
  let wire = encodeCommand(["GET", "missing"])
  println(wire)

  let (reply, _) = decodeReply(fixedSource{ data: "\$-1\r\n" }, "")?
  match (reply) {
    Bulk(v) => {
      match (v) {
        Some(s) => println(s)
        None => println("(nil)")
      }
    }
    _ => println("unexpected reply")
  }
  return
}
```

An `Err` reply (`-ERR ...\r\n` on the wire) decodes to `Reply.Err(string)`
like any other reply - `decodeReply` itself never fails on it. `Client`
raises it: every method checks its `Reply` and turns an `Err` into a `fail`
carrying the server's message, prefixed `"redis: "` (`client.bit`'s
`checkError`), so a caller sees a command failure the same way it sees a
connection failure - as an `error` from `?` or `catch`.

## Not implemented

Only RESP2 is implemented. The following are out of scope for this package
as it stands:

- **RESP3** - Redis 6+'s `HELLO 3` push types, maps, doubles, big numbers.
- **Pipelining** - each `command()` call writes one command and reads one
  reply; there is no batching of multiple commands onto the wire before
  reading their replies back.
- **Pub/sub** - `SUBSCRIBE`/`PUBLISH` and the out-of-band message stream
  they require.
- **Cluster** - `MOVED`/`ASK` redirection and multi-node topology.

A server that requires any of these is out of scope for this package.
