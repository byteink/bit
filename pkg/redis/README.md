# pkg/redis

A Redis client, written in Bit over `std/net`/`std/tls`. RESP3 by default
(`HELLO 3`), falling back to RESP2 automatically against a server that does
not know `HELLO`.

## Install

`bit add bitlang.org/pkg/redis@^0.4.0` writes:

```json
{
  "dependencies": {
    "redis": "bitlang.org/pkg/redis@^0.4.0"
  }
}
```

## Usage

```bit
import { open } from "redis"

fn main(): ()! {
  let c = open("redis://:secret@127.0.0.1:6379/0")?
  c.set("greeting", "hello")?
  let v = c.get("greeting")?
  match (v) {
    Some(s) => println(s)
    None => println("(nil)")
  }
  c.close()
  return
}
```

The full method surface, the connection URL and `Options`, and what this
package does not implement (cluster) are in
[`docs/`](docs/README.md).

For how first-party packages in this repository are laid out, gated,
versioned and released, see [`pkg/README.md`](../README.md).
