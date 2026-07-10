# std/http

HTTP/1.1 over `std/net`, built entirely in Bit. A server accepts connections and
handles each on its own green thread; a client dials, sends one request, and
reads the response. Fallible calls return `T!` — propagate with `?` or handle
with `catch`.

Scope: plain HTTP (no TLS), one request per connection (`Connection: close`), no
chunked transfer encoding, no redirects. Headers are carried as a raw block and
read with `header()`.

<!-- doctest: per-block -->

## Messages

### `Request`

A parsed request: `method`, `path`, the raw `headers` block, and `body`. Read a
named header with `header(req.headers, "...")`.

### `Response`

A response: `status`, `contentType`, extra raw `headers`, and `body`. A server
fills in `Content-Length` and `Connection` for you.

### `header(block: string, name: string): string`

The value of header `name` in a raw header block, matched case-insensitively at a
line start, or `""` if absent.

### `ok(body: string): Response`

A `200 OK` response carrying `body` as UTF-8 text.

### `respond(status: int, body: string): Response`

A response with an explicit status and a text body.

```bit
import { Request, Response, ok, respond, header } from "std/http"

// Route a request to a response.
function route(req: Request): Response {
  if (req.path == "/health") {
    return ok("ok")
  }
  return respond(404, "not found")
}

function accepts(req: Request): string {
  return header(req.headers, "Accept")
}
```

## Server

Drive the server with an `accept()` loop, spawning a green thread per exchange so
a slow handler never delays the next accept.

### `Server`

A listening HTTP server.

### `Exchange`

One accepted request (`request`) together with the connection to answer it on.

### `serve(host: string, port: int): Server!`

Binds and starts listening on `host:port`. Port `0` lets the kernel choose one;
read it back with `port()`.

### `Server.port(): int!`

The port the server is bound to.

### `Server.accept(): Exchange!`

Accepts the next connection and reads its request, parking until a client
arrives.

### `Exchange.respond(res: Response): ()!`

Writes `res` to the connection and closes it.

### `Server.close()`

Stops listening.

```bit
import { serve, ok, Server, Exchange } from "std/http"

function handle(ex: Exchange): ()! {
  ex.respond(ok("hello from bit"))?
}

// Serve `n` requests, one green thread each.
function runServer(s: Server, n: int): ()! {
  let i = 0
  while (i < n) {
    let ex = s.accept()?
    spawn handle(ex)
    i = i + 1
  }
  s.close()
}
```

## Client

### `request(method: string, url: string, body: string): Response!`

Sends `method url` with an optional body and returns the response. The request
asks the server to close the connection, so the whole response is read to EOF.

### `get(url: string): Response!`

GETs `url`.

### `post(url: string, body: string): Response!`

POSTs `body` to `url`.

```bit
import { get, post, request, Response } from "std/http"

function fetchStatus(url: string): int! {
  let res = get(url)?
  return res.status
}

function submit(url: string, payload: string): string! {
  let res = post(url, payload)?
  return res.body
}

function head(url: string): Response! {
  return request("HEAD", url, "")?
}
```
