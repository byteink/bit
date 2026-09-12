# The request

`Ctx` carries everything a handler reads about the request it was given:
route params, the query string, headers, the client address, and the body.
This chapter covers all of it, ending with the two-layer defense against a
client setting a field it should never be able to reach.

## The client address

`c.peer()` is the address of the socket the request arrived on, recorded when
the connection was accepted, and `""` for a request that never came off a
socket (one built by hand, or an in-process `App.handle` call). It reads no
request header and never will: `X-Forwarded-For`, `X-Real-IP` and `Forwarded`
are client-supplied strings, so keying a rate limit, a ban or an audit record
on one keys it on whatever the caller chose to send.

Behind a reverse proxy, `c.peer()` is therefore the proxy's address, which is
correct rather than a bug - trusting a forwarding header is only sound when
the proxy is known to overwrite it and the app is unreachable except through
that proxy, and both are facts about a deployment this package cannot know.
The one place this package reads a forwarding header on request is
`byForwardedIp(hops)`, covered in [Operational middleware](operations.md)'s
rate-limiting section, which the app asks for by name and tells how deep its
proxy chain runs; it keys a rate limit and never changes what `c.peer()`
itself returns.

## Route params, query and headers

```bit
import { Ctx, Res } from "web"

fn showUser(c: Ctx): Res! {
  let id = c.param("id")
  let expand = c.query("expand")
  let auth = c.header("Authorization")
  return c.text("${id} ${expand} ${auth}")
}
```

`c.param` reads a captured route segment (see [Routing](routing.md));
`c.query` and `c.header` return `""` when the key is absent, and
`c.headers(name)` returns every value for a header that may repeat.

## Write an input type. That is the protection.

Binding client JSON straight into the type that reaches your database is
**mass assignment**: given a `User` class with `isAdmin: bool`, a client that
posts `{"name":"Ali","isAdmin":true}` has made itself an admin, and no line of
the handler looks wrong. So declare a type for the input, carrying only the
fields a client is allowed to set, and map across explicitly:

```bit
import { Ctx, Res } from "web"
import { Json, JsonEntry } from "std/json"

@json class NewUser {
  name: string,
  email: string,
}

fn createUser(c: Ctx): Res! {
  let input = c.body<NewUser>()?
  return c.created(input.name)
}
```

`NewUser` has no `id` and no `isAdmin`, so no payload can reach either -
whatever the unknown-field policy below says. Rejecting unknown fields is the
**second** layer; the first is that the field does not exist on the bound
type. The type argument (`<NewUser>`) is never optional - it appears only in
the result, so a bare `c.body()` has nothing to infer it from and is a
compile error.

## Unknown fields are a 400 by default

An unknown key in the body is refused, with a response naming the field
(`json: unknown key 'isAdmin'`) rather than silently dropped - a dropped
field and an accepted field are indistinguishable to whoever sent it, so a
client would go on believing it set something it did not.

The app-level default is `Config.rejectUnknownFields` (`true`, see
[Configuration](configuration.md)). A single route overrides it with
`bodyWith`, the only way to be lenient - there is no global switch that turns
the check off invisibly:

```
let row = c.bodyWith<Legacy>(Bind{ unknown: Unknown.Ignore })?
```

`Ignore` drops at most 32 unknown keys and then answers 400 - dropping them is
a retry per key, so an unbounded version would be quadratic work on a body an
attacker chose.

## Every failure names what is wrong

| the request | status | body |
|---|--:|---|
| body over `Config.maxBody` | 413 | `web: request body is 4096 byte(s), over the 1000000-byte cap` |
| `Content-Type` is not JSON, or absent | 415 | `web: Content-Type 'text/plain' is not JSON; this route reads application/json` |
| body does not parse | 400 | `web: request body is not valid JSON: ...` |
| a required field is absent | 400 | `json: missing key 'email'` |
| a field has the wrong type | 400 | `json: 'age': expected an integer, found a string` |
| a key no field claims, under `Reject` | 400 | `json: unknown key 'isAdmin'` |
| a failure inside a nested object | 400 | `json: 'addr.zip': expected an integer, found a string` |

A nested failure names the full dotted path (`addr.zip`, `stops[1].city`),
never the leaf - a leaf name in a nested document does not say where.
`Content-Type` is matched on the media type alone (parameters and case do not
matter), and any `+json` structured syntax suffix is treated as JSON.

`c.rawBody()` and `c.bodyJson()` are the escape hatches for a payload that is
not a class - the unparsed bytes and the parsed `Json` tree, respectively -
and both carry the same 413/415/parse-error behavior as `c.body<T>()`.

`Config.maxBody` bounds what this framework will **parse**; the read itself
is bounded separately by `std/http` (32 MiB by default), so a body over the
server's own budget never reaches a `Ctx` at all and is answered 400 before
this package sees it.

## Validating the body

Binding checks the **shape** and answers 400; validation checks the
**values** and answers 422. A `422` is something to show a user - a `400`
says "I could not read this" and is not.

Rules go on the field as attributes, which are ordinary function calls
(`@minLen(3)` on `name` is `minLen(this.name, 3)`), plus an optional
`validate()` method for cross-field rules no per-field attribute can express:

```bit
import { Ctx, Res, minLen, maxLen, email, unprocessable } from "web"
import { Json, JsonEntry } from "std/json"

@json class Signup {
  @minLen(3)
  @maxLen(12)
  name: string

  @email
  email: string

  password: string
  confirm: string

  export validate(): ()! {
    if (this.password != this.confirm) {
      fail unprocessable("password and confirm must match")
    }
  }
}

fn signup(c: Ctx): Res! {
  let input = c.body<Signup>()?
  return c.created(input.name)
}
```

Both `validateFields()` (synthesized from the attributes) and `validate()`
run, and their failures are reported together, each field named - a form is
not corrected one message per round trip. A type with neither member binds
with no validation and no error; that is a type with no rules, not a mistake.

The rules this package ships: `@minLen(n)`/`@maxLen(n)` (string length, in
characters), `@min(n)`/`@max(n)` (`i64` range), `@email`, `@url`, `@uuid`, and
`@nonEmpty`. There is no registry - export a fallible function and its name
is an attribute:

```bit
import { unprocessable } from "web"
import { Json, JsonEntry } from "std/json"

export fn iban(v: string): ()! {
  if (len(v) < 15) {
    fail unprocessable("must be an IBAN")
  }
}

@json class Payment {
  @iban
  account: string
}
```

`@iban` works with no change to this package and no change to the compiler.
A rule that fails with anything other than an `HttpError` (`unprocessable`
and the other constructors in [Errors](errors.md)) is a 500 with the message
logged and never sent - a validator that called into a database and failed
cannot paste a connection string into a 422.

Next: [The response](response.md), for building what a handler returns.
