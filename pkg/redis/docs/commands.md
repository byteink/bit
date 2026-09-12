# Commands

The full set of named methods on `Client`, each a thin wrapper over
`command()` ([Connecting](connecting.md)) that checks the reply shape and
returns a plain Bit value instead of a raw `Reply`.

```bit
import { connect } from "redis"

fn main(): ()! {
  let c = connect("127.0.0.1", 6379)?
  c.set("greeting", "hello")?
  let v = c.get("greeting")?
  match (v) {
    Some(s) => println(s)
    None => println("(nil)")
  }
  let removed = c.del(["greeting"])?
  println("${removed}")
  c.close()
  return
}
```

- `get(key): Option<string>!` - `Option.None` on a cache miss, never
  `Option.Some("")`.
- `set(key, value): ()!`
- `del(keys): i64!` - the number of keys actually removed.
- `exists(keys): i64!` - the number of the given keys that exist.
- `expire(key, seconds): bool!` - `true` if the key exists and the timeout
  was set.
- `ping(): string!` - the server's reply text (normally `"PONG"`).
- `command(args): Reply!` - the generic escape hatch described in
  [Connecting](connecting.md); every method above is built on it.

A `-ERR ...` reply raises a `fail` from whichever method produced it, same as
any other failure. See [RESP2](resp.md) for the reply shapes these methods
match against and what nil means on the wire.
