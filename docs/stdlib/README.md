# The Bit standard library

One page per module. Every symbol a module exports has a section here — a build
step compares these pages against what the compiler reports as exported
(`bit doc <module>`), and fails if one is missing. Every ```` ```bit ```` example
below is compiled by the test suite, so none of it can quietly rot.

| Module | Import | What it is for |
|---|---|---|
| [core](core.md) | *(none — the prelude)* | `println`, `Option`, `Result`, `newError` |
| [io](io.md) | `"std/io"` | Buffered readers and writers |
| [fs](fs.md) | `"std/fs"` | Files and directories |
| [path](path.md) | `"std/path"` | Lexical path handling |
| [strings](strings.md) | `"std/strings"` | Searching, building, UTF-8 runes |
| [seq](seq.md) | `"std/seq"` | `mapped`, `filter`, `reduce` over slices |
| [math](math.md) | `"std/math"` | `f64` maths and integer helpers |
| [time](time.md) | `"std/time"` | Clocks, durations, sleeping |
| [os](os.md) | `"std/os"` | Arguments, environment, exit |
| [net](net.md) | `"std/net"` | TCP, UDP, and DNS over green threads |
| [http](http.md) | `"std/http"` | HTTP/1.1 server and client |
| [crypto](crypto.md) | `"std/crypto"` | The `Hash` streaming digest contract |
| [tls](tls.md) | `"std/tls"` | TLS 1.3 groups, cipher suites, key schedule, handshake, record |
| [uuid](uuid.md) | `"std/uuid"` | UUID v4/v5/v7, parse/format |
| [http2](http2.md) | `"std/http2"` | HPACK + HTTP/2 frame layer |
| [quic](quic.md) | `"std/quic"` | QUIC v1 packet protection + frames |
| [http3](http3.md) | `"std/http3"` | QPACK field compression |
| [testing](testing.md) | `"std/testing"` | Assertions for `bit test` |

## Conventions

**Everything that can fail says so.** A fallible function returns `T!`. There are
no exceptions and no error codes hidden in return values — propagate with `?`, or
handle with `catch`. See [errors](../reference/errors.md).

**Absence is a type, not a null.** A function that may find nothing returns
`Option<T>`.

**Slices have no methods.** Operations on them are free functions taking the
slice first: `filter(xs, pred)`, never `xs.filter(pred)`.

**Structs are reference types**, so a method mutates the receiver in place. This
is why `w.write(s)` needs no reassignment, and why an unflushed `Writer` loses
data.

**Durations are `int` nanoseconds**, built from the unit constants in
[time](time.md): `500 * Millisecond`.

## Looking things up

`bit doc <module-dir>` prints a module's exported symbols with their signatures,
straight from the compiler:

```
$ bit doc stdlib/path
const Separator string
function base (string) => string
function dir (string) => string
...
```

`bit doc --json` prints the same as JSON, for tooling.
