# Serve JSON over HTTP

An HTTP handler in Bit is a plain function from `Request` to `Response`.
Decode the request body into a class, do the work, encode the result back to
JSON - no framework object sits between you and either step.

<!-- doctest: per-block -->

## The shortest complete server

```bit
import { serve, listenAndServeOn, respond, post, Server, Request, Response } from "std/http"
import { jsonEncode, jsonDecodeText, Json, JsonEntry } from "std/json"

@json class Task {
  id: i64,
  title: string,
  done: bool,
}

fn route(req: Request): Response {
  if (req.path != "/tasks") {
    return respond(404, "not found")
  }
  let task = jsonDecodeText<Task>(req.body) catch e {
    return respond(400, "bad request: ${e.message()}")
  }
  let saved = Task{ id: 1, title: task.title, done: true }
  return Response{
    status: 201,
    contentType: "application/json",
    headers: "",
    body: jsonEncode(saved.toJson()),
  }
}

fn serveForever(s: Server) {
  listenAndServeOn(s, route) catch e {
    print("server failed: ${e.message()}\n")
  }
}

fn main(): ()! {
  let s = serve("127.0.0.1", 0)?
  let port = s.port()?
  spawn serveForever(s)

  let res = post(
    "http://127.0.0.1:${port}/tasks",
    "{\"id\":0,\"title\":\"write the guide\",\"done\":false}",
  )?
  println("status = ${res.status}")
  println("body = ${res.body}")
  return
}
```

Running it prints:

```
status = 201
body = {"id":1,"title":"write the guide","done":true}
```

`@json class Task` makes the compiler synthesize `toJson(): Json` on `Task`,
matched by `jsonDecodeText<Task>` on the way in - both are built from the
same field list, so they agree by construction. `jsonEncode` turns the `Json`
value `toJson()` built into the compact text on the wire.

`serve(host, 0)` asks the kernel for a free port instead of a fixed one, and
`s.port()` reads back which one it chose - that is what makes a server you
can start and immediately talk to in the same process, without guessing a
port nobody else is using. In a real program you would call
`listenAndServe("0.0.0.0", 8080, route)` directly instead.

## Real requests hit `/` too

Add a route and a body-less response:

```bit
import { ok, respond, Request, Response } from "std/http"

fn route(req: Request): Response {
  if (req.path == "/health") {
    return ok("ok")
  }
  if (req.path == "/tasks") {
    return respond(404, "not implemented in this snippet")
  }
  return respond(404, "not found")
}
```

`ok(body)` is a `200` with `text/plain` - fine for a health check. For JSON,
build a `Response` literal the way the first example does and set
`contentType` yourself; there is no separate "JSON response" helper because
the fields are three lines to set directly.

## A malformed body

Send a document missing a field the class declares:

```bit
import { jsonDecodeText, Json, JsonEntry } from "std/json"

@json class Task {
  id: i64,
  title: string,
  done: bool,
}

fn decodeTask(body: string): Task! {
  return jsonDecodeText<Task>(body)?
}
```

Calling `decodeTask("{\"id\":1,\"title\":\"x\"}")` (no `done`) fails with:

```
json: missing key 'done'
```

That is exactly the string `e.message()` returns in the `catch` block above,
which is why the handler can turn it straight into the `400` body. An
`UnknownKey` in the input fails the same way in the other direction, by
default - reach for `jsonDecodeLenient<T>` instead of `jsonDecodeText<T>`
when a client sending an extra field the server does not know about yet
should not be a hard error.

## Sharp edges

- `jsonDecodeText<T>` and `jsonDecode<T>` both require `T` to be a class
  carrying `@json`. Passing any other type is a compile error, `E0145`,
  naming the type - not a runtime failure you discover in production.
- A class marked `@json` must import `Json` and `JsonEntry` from `std/json`,
  even if the handler never names either type directly - the compiler-written
  `toJson()` body refers to them. Leaving the import out is `E0142`, and the
  error names the exact import to add.
- The server handles each connection on its own green thread, and a green
  thread's stack is a fixed 64 KiB. A handler that recurses over
  request-shaped data (a nested JSON document, a comment tree) needs an
  explicit depth bound - see the stack-size section of the
  [Concurrency reference](../reference/concurrency.md#stack-size-and-what-happens-when-you-exceed-it).

## What to read next

[std/http](../stdlib/http.md) covers HTTPS, HTTP/2 and HTTP/3, form
uploads, and the client side in full. [std/json](../stdlib/json.md) covers
`jsonDecodeLenient`, pretty-printing, and the untyped `Json` tree for when
you do not want to declare a class at all. For the concurrency model behind
one green thread per connection, see [Run work in parallel](run-work-in-parallel.md).
