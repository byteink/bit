# pkg/web

A web framework for Bit: a radix-trie router, `App`/`Group` with scoped
middleware, a `Ctx` carrying the parsed request, `Res` helpers, an HTML node
tree with escaping, sessions, and the middleware set (`logger`, `cors`,
`csrf`, `static`, `compress`, `secureHeaders`).

Versioning, tags and the release procedure for every first-party package are in
[`pkg/README.md`](../README.md).

## Install

```json
{
  "dependencies": {
    "web": "bitlang.org/pkg/web@v0.1.0"
  }
}
```

## Reading the request body

### Write an input type. That is the protection.

Binding client JSON straight into the type that reaches your database is **mass
assignment**, and it is the reason this part of the framework exists. Given

```
@json class User {
  id: i64,
  name: string,
  email: string,
  isAdmin: bool,
}
```

a client that posts `{"name":"Ali","isAdmin":true}` into a `User` has made
itself an admin, and no line of the handler looks wrong.

So declare a type for the input, carrying only the fields a client is allowed
to set, and map across explicitly:

```
@json class NewUser {
  name: string,
  email: string,
}

fn createUser(c: Ctx): Res! {
  let input = c.body((j) => jsonDecode<NewUser>(j))?
  let row = User{
    id: 0,
    name: input.name,
    email: input.email,
    isAdmin: false,      // written by us, never reachable from the payload
  }
  return c.created("${insertUser(row)?}")
}
```

`NewUser` has no `id` and no `isAdmin`, so no payload can reach either —
whatever the unknown-field policy says. Rejecting unknown fields, below, is the
**second** layer; the first is that the field does not exist on the bound type.

### Unknown fields are a 400 by default

An unknown key in the body is refused, with a response naming the field:

```
POST /users   {"name":"Ali","email":"a@b.c","isAdmin":true}
400            {"status":400,"error":"json: unknown key 'isAdmin'"}
```

Not a silent drop, on purpose: a dropped field and an accepted field are
indistinguishable to whoever sent it, so a client would go on believing it set
something it did not.

The app-level default is `Config.rejectUnknownFields`, which is `true`:

```
let app = App(Config{ secret: mySecret, rejectUnknownFields: true })
```

A single route overrides it with `bodyWith`, and this is the only way to be
lenient — there is no global switch that turns the check off in review-invisible
fashion:

```
fn importLegacy(c: Ctx): Res! {
  let row = c.bodyWith(Bind{ unknown: Unknown.Ignore }, (j) => jsonDecode<Legacy>(j))?
  return c.json(row)
}
```

`Bind{}` with the field omitted means `Reject`. `Ignore` drops at most 32
unknown keys and then answers 400 — dropping them is a retry per key, so an
unbounded version would be quadratic work on a body an attacker chose.

### Every failure names what is wrong

| the request | status | body |
|---|--:|---|
| body over `Config.maxBody` | 413 | `web: request body is 4096 byte(s), over the 1000000-byte cap` |
| `Content-Type` is not JSON, or absent | 415 | `web: Content-Type 'text/plain' is not JSON; this route reads application/json` |
| body does not parse | 400 | `web: request body is not valid JSON: ...` |
| a required field is absent | 400 | `json: missing key 'email'` |
| a field has the wrong type | 400 | `json: 'age': expected an integer, found a string` |
| a key no field claims, under `Reject` | 400 | `json: unknown key 'isAdmin'` |
| a failure inside a nested object | 400 | `json: 'addr.zip': expected an integer, found a string` |

A nested failure names the **full dotted path** (`addr.zip`, `stops[1].city`),
never the leaf: a leaf name in a nested document does not say where.

`Content-Type` is matched on the media type alone, so parameters and case do
not matter (`Application/JSON; charset=utf-8`), and any `+json` structured
syntax suffix (`application/vnd.api+json`) is JSON.

### The rest of the surface

```
c.body(decode): T!                 // bind under the app-level policy
c.bodyWith(bind, decode): T!       // bind under a per-call policy
c.bodyJson(): Json!                // the parsed tree, for a payload that is not a class
c.rawBody(): string!               // the unparsed bytes, capped
```

`c.bodyJson()` and `c.rawBody()` carry the same 413, and `bodyJson()` the same
415 and parse error, so nothing in this package reads a body without them.

### Why the decoder is an argument

`c.body((j) => jsonDecode<NewUser>(j))` names the type once — `T` is inferred
from the arrow — but it is more than `c.body<NewUser>()` would be, which is
what #3877 specified. The type argument has to sit at the call site because
`jsonDecode<T>` is specialised by a rewrite that runs before type checking, so
it cannot see through a generic wrapper (#4563). When that is fixed the
parameter goes and the call becomes `c.body<NewUser>()?`; nothing else about
the behaviour above changes.

### What the size cap does not do

`Config.maxBody` bounds what this framework will **parse**. It is not a bound
on what was read: `std/http` reads a `Content-Length` body with no limit of its
own, so the bytes are already in memory before any `Ctx` exists (#4565).
