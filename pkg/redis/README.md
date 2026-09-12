# pkg/redis

A RESP2 client for Redis (and RESP2-protocol-compatible servers), written in
Bit over `std/net`.

## Install

```json
{
  "dependencies": {
    "redis": "bitlang.org/pkg/redis@v0.1.0"
  }
}
```

## Usage

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
  c.close()
  return
}
```

The full method surface, the RESP2 wire format, and what this package does
not implement (RESP3, pipelining, pub/sub, cluster) are in
[`docs/`](docs/README.md).

For how first-party packages in this repository are laid out, gated,
versioned and released, see [`pkg/README.md`](../README.md).
