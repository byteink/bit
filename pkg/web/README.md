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

## The client address

`c.peer()` is the address of the socket the request arrived on, recorded by
`std/http` when the connection was accepted, and `""` for a `Request` that
never came off a socket (one built by hand, an in-process `App.handle` call, or
the HTTP/3 path). It reads no request header and never will: `X-Forwarded-For`,
`X-Real-IP` and `Forwarded` are client-supplied strings, so keying a rate
limit, a ban or an audit record on one keys it on whatever the caller chose to
send. Behind a reverse proxy `c.peer()` is therefore the proxy, which is
correct rather than a bug — preferring a forwarding header is only sound when
the proxy is known to overwrite it and the app cannot be reached except through
that proxy, and both are facts about a deployment that this package cannot
know. Handling them belongs in an opt-in middleware configured with the
operator's trusted proxy list; no such middleware ships yet, and until one
does, `c.peer()` is the only address here that a client cannot forge. The one
place this package will read a forwarding header is `byForwardedIp(hops)` below,
which the app asks for by name and tells how deep its proxy chain is; it keys a
rate limit and does not change what `c.peer()` returns.

## Rate limiting

```
app.use(rateLimit(Limit{
  requests: 100,
  window: 60,
  by: byIp,
  store: MemoryCounter(),
}))

login.use(rateLimit(Limit{ requests: 5, window: 300, by: byIp, store: counter }))
```

Every request the limiter serves carries `RateLimit-Limit`,
`RateLimit-Remaining` and `RateLimit-Reset` (the IETF draft names, which is what
current tooling reads). A refused one is **429** with `Retry-After`, in seconds,
and no body.

### You supply the counter store. There is no default.

`Limit.store` has no default and `rateLimit()` panics at registration when it is
absent — the same rule, for the same reason, as `Config.sessions`. An
in-process counter is correct on one server and silently wrong behind a load
balancer, where each of N servers permits the whole quota and a limit of 100
becomes 100N with nothing anywhere to indicate it.

`MemoryCounter()` ships and is **single-process only**. It is for development,
tests, and a service that really does run as one process; it has no sweeper, so
a key never seen again holds two integers until the process exits. A store that
must be shared or must bound its own memory implements `RateStore`:

```
interface RateStore {
  incr(key: string, ttl: i64): i64!    // add one, create at 1, return the new value
  count(key: string): i64!             // the current value, 0 when absent
}
```

That is `INCR` plus `GET`, so a plain key-value store implements it with no
server-side script. `incr` must not extend an existing counter's life: a bucket
dies `ttl` seconds after it was created, or the window stops sliding.

### The window slides

Two adjacent fixed buckets, with the older weighted by how much of it is still
inside the trailing window. A fixed window would let a client spend the whole
quota in the last instant of one window and the whole quota again in the first
instant of the next — twice the configured burst, at the boundary, every time.

A rejected request still counts. The increment is one atomic store operation, so
two concurrent requests cannot both read the same count and both be admitted;
the price is that a client which keeps hammering extends its own lockout.

### Keys

| `by` | keyed on | reads a header |
|---|---|---|
| `byIp` | `c.peer()`, the socket address | no |
| `bySession` | the session id, or `c.peer()` when there is no established session | no |
| `byForwardedIp(hops)` | `X-Forwarded-For`, `hops` entries from the trusted end | yes, deliberately |

`byIp` is the default choice and reads nothing a client can set. Behind a
reverse proxy it is the proxy's address, so every client behind that proxy
shares one bucket — which is why `byForwardedIp(hops)` exists.

`hops` is the number of proxies between the client and this server, and it is
required rather than a flag on `byIp` because there is no safe default for it.
With `hops: 2` and a chain `client -> P1 -> P2 -> app`, the list this server
sees ends `..., client, P1`, so the client is at `len - hops` and everything an
attacker prepended sits to the left of it and cannot move it. Counting from the
left instead is the classic vulnerability: the leftmost entry is the one the
client controls completely. **Set `hops` to the real depth of your proxy
chain.** A list shorter than `hops` did not come through that chain, and falls
back to `c.peer()` rather than to anything the header claimed.

`bySession` keys on the session only when the cookie hits the session store. An
absent, expired, destroyed or forged cookie is anonymous and is counted on the
socket address — otherwise a client sending a fresh random cookie each time
would mint a fresh bucket each time. It fails, naming `Config.sessions`, when no
session store is configured.

### A store outage does not refuse traffic

A failing store is logged through the app's sink (`Config.logs`, stderr when
none is set) and the request is **served**. Failing closed would turn a counter
outage into an outage of the app the limiter protects, and a rate limit is a
mitigation rather than an authentication boundary. What it never does is fail
open quietly: every store failure writes a line naming the operation and the
store's own message.

### Two limiters sharing one store

A bucket key carries the policy (`requests/window`), so the app-wide `100/60`
limiter and the `5/300` login limiter above do not share counters even on one
store. Two registrations with the **same** policy, the same store and the same
key function still do share one, and count together. Give them separate stores
until an explicit per-limit namespace lands.

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

## Validating the body

Binding checks the **shape** — every field present, every field the right type —
and answers 400 when it is wrong. Validation checks the **values**, and answers
422. The two statuses are worth keeping apart: 400 says "I could not read this",
422 says "I read it and the values are unacceptable", and only the second is
something to show a user.

### Rules go on the field

```
@json class Signup {
  @minLen(3)
  @maxLen(12)
  name: string

  @email
  email: string

  password: string
  confirm: string

  // Cross-field rules, which no per-field attribute can express.
  export validate(): ()! {
    if (this.password != this.confirm) {
      fail unprocessable("password and confirm must match")
    }
  }
}
```

An attribute is a call to an ordinary function: `@minLen(3)` on `name` is
`minLen(this.name, 3)`. The compiler collects them into a `validateFields()` on
the class, and `c.body` runs it, then `validate()` if the type has one. **Both
run, and their failures are reported together** — a form is not corrected one
message per round trip.

```
POST /signup   {"name":"ab","email":"a@b.co","password":"p","confirm":"q"}
422            {"status":422,"error":"must be at least 3 character(s); password and confirm must match"}
```

A type with neither member binds with no validation and no error. That is a type
with no rules, not a mistake.

### The rules this package ships

| rule | on | passes when |
|---|---|---|
| `@minLen(n)` / `@maxLen(n)` | `string` | the value is at least / at most `n` **characters** (not bytes) |
| `@min(n)` / `@max(n)` | `i64` | the value is at least / at most `n` |
| `@email` | `string` | one `@`, a domain with an interior dot, no whitespace |
| `@httpUrl` | `string` | an absolute `http://` or `https://` URL with a host |
| `@uuid` | `string` | canonical `8-4-4-4-12` hex, either case |
| `@nonEmpty` | `string` | something is left after trimming whitespace |

Lengths and values are named apart (`minLen` vs `min`) because Bit has no
overloading, so `@min(3)` on a string is a compile error with an obvious fix
rather than a rule that measured the wrong thing.

`@httpUrl` and not `@url`: this package already exports `url()`, the href scheme
allowlist, and one module cannot hold two.

### Anyone can add a rule

There is no registry and no list of known rules. Export a fallible function and
its name is an attribute:

```
export fn iban(v: string): ()! {
  if (!validIban(v)) {
    fail unprocessable("must be an IBAN")
  }
}

@json class Payment {
  @iban
  account: string
}
```

`@iban` works with no change to this package and no change to the compiler, and
`@ibna` is an ordinary `E0040 undefined name`. That is the reason the design is
attributes over a fixed rule set.

### A rule decides what the client may read

The framework's rule for errors applies here unchanged: a failure that satisfies
`HttpError` — which `unprocessable(...)` and the other constructors return — has
its message sent. A rule that fails with anything else is a **500 with the
message logged and never sent**, so a validator that called into a database and
failed cannot paste a connection string into a 422.

### What this does not do yet

Two limits, both in the compiler's synthesis of `validateFields()` and both
tracked by #4572:

- **Two failing attributes report one message.** The synthesized method
  propagates the first failure, so `name` being too short hides a malformed
  `email` until it is fixed. A field rule and a cross-field rule are still
  reported together, since those are two separate calls.
- **A message cannot name its field.** The call passes the field's value and
  nothing else, so neither the rule nor this package knows which field it ran
  on. Until that changes, put the field in your own rule's message when it
  matters.
