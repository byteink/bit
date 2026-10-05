# Sign in with GitHub, or any OAuth 2.0 provider

Inkwell's authors keep their drafts on GitHub already, so they ask for "Sign in
with GitHub". GitHub, Discord, Slack and plenty of others speak plain OAuth 2.0:
they hand your server an access token, not an ID token, so
[`OidcStrategy`](oidc.md) has nothing to verify. `OAuth2Strategy` runs the same
redirect flow and then asks the provider's own profile API who the user is.

## Two routes, and one function that knows the provider

You supply three things the package cannot guess: the provider's two endpoints,
your client id and secret, and a `ProfileFetch`, the function that turns an
access token into an `Identity`. Every provider's profile document looks
different, so that function is yours; it is usually ten lines.

```bit
import { App, Config, MemoryStore, unauthorized } from "web"
import {
  Identity,
  OAuth2Endpoints,
  OAuth2Options,
  OAuth2Strategy,
  ProfileFetch,
  currentIdentity,
} from "auth"
import { TlsConfig } from "std/tls"
import { Client, Header } from "std/http"
import { fromPem } from "std/crypto"
import { Json, jsonAsInt, jsonAsString, jsonGet, jsonParse } from "std/json"
import { isSome, unwrap } from "std/core"

// GitHub's `GET /user` answer: a stable numeric `id` and a `login`.
fn githubIdentity(body: string): Identity! {
  let doc = jsonParse(body)?
  let id = jsonGet(doc, "id")
  if (!isSome(id) || !isSome(jsonAsInt(unwrap(id)))) {
    fail newError("github: profile has no numeric id")
  }
  let login = jsonGet(doc, "login")
  if (!isSome(login) || !isSome(jsonAsString(unwrap(login)))) {
    fail newError("github: profile has no login")
  }
  return Identity{
    id = "github:${unwrap(jsonAsInt(unwrap(id)))}",
    claims = Json.JsonString(unwrap(jsonAsString(unwrap(login)))),
  }
}

fn githubProfile(tls: TlsConfig): ProfileFetch {
  let f: ProfileFetch = (token) => {
    let headers = []Header{
      Header{ name = "Authorization", value = "Bearer " + token },
      Header{ name = "Accept", value = "application/json" },
    }
    let res = Client(tls = tls).requestWith("GET", "https://api.github.com/user", headers, "")?
    if (res.status != 200) {
      fail newError("github: profile request answered ${res.status}")
    }
    return githubIdentity(res.body)?
  }
  return f
}

// `rootsPem` is your deployment's trusted CA bundle; this package never
// guesses one.
fn github(rootsPem: string): OAuth2Strategy! {
  let tls = TlsConfig(fromPem(rootsPem)?)
  let endpoints = OAuth2Endpoints{
    authorize = "https://github.com/login/oauth/authorize",
    token = "https://github.com/login/oauth/access_token",
    profile = githubProfile(tls),
  }
  return OAuth2Strategy(
    endpoints,
    "your-client-id",
    "your-client-secret",
    "https://app.example.com/auth/github/callback",
    OAuth2Options{ scopes = ["read:user"], tls = Option.Some(tls) },
  )?
}

fn build(rootsPem: string): App! {
  let app = App(Config{ secret = "change-me", sessions = MemoryStore(10_000) })
  let gh = github(rootsPem)?

  app.get("/auth/github", (c) => gh.beginAuthorization(c))
  app.get("/auth/github/callback", (c) => {
    let who: Identity = gh.authenticate(c)?
    return c.redirect("/me")
  })

  app.get("/me", (c) => {
    let identity: Identity = currentIdentity(c) catch _ {
      fail unauthorized()
    }
    return c.text(identity.id)
  })
  return app
}
```

`beginAuthorization` stores a random `state` and a PKCE verifier on the user's
session and redirects to GitHub. `authenticate` is the other half: the route
GitHub sends the browser back to. It checks the `state`, exchanges the code,
calls your `ProfileFetch` with the access token, regenerates the session id and
stores the `Identity` exactly as the password and OpenID Connect logins do, so
`/me` does not care which one ran. Because `OAuth2Strategy` has `name()` and
`authenticate(c)`, it is also a `Strategy` you can hand to `requireAuth`.

## What it checks so you do not have to

- **`state` is single use.** It is read back from the session once and compared
  in constant time before anything else happens. A missing, wrong or replayed
  callback gets the same 401 and never reaches the token endpoint.
- **PKCE, always.** The verifier is 43 characters from 32 random bytes and the
  challenge is its SHA-256 (`S256`). The plain method does not exist here, and a
  confidential client gets PKCE too: a stolen code is useless without the
  verifier that never left your server.
- **Exact redirect.** `redirectUri` is sent as given, and the provider must have
  the same string registered.
- **Bearer only.** A token response whose `token_type` is anything but `Bearer`
  (in any letter case) is refused instead of being sent as a Bearer token.

## Client authentication

By default the client secret travels in an `Authorization: Basic` header, the
form every provider must accept. A few providers want `client_id` and
`client_secret` in the request body instead; `ClientAuth.Post` switches to that.
A client with an empty secret, such as a command-line tool, sends only its
`client_id` and relies on PKCE alone.

```bit
import { ClientAuth } from "auth"

fn discordOptions(tls: TlsConfig): OAuth2Options {
  return OAuth2Options{
    scopes = ["identify", "email"],
    tls = Option.Some(tls),
    clientAuth = ClientAuth.Post,
    name = "discord",
  }
}
```

`name` is what `Strategy.name()` returns and part of the session keys, so GitHub
and Discord can both be configured on one app without one flow overwriting the
other's `state`. It defaults to `oauth2`.

## Providers that say who they are

A provider that supports issuer identification puts an `iss` parameter on the
callback. That is the defence against a mix-up attack, where a hostile provider
you also trust makes your app send another provider's code to it. Set `issuer`
to the value the provider documents and the callback must carry exactly that
`iss`; a missing one is refused too, because that is how the attack hides.
Leave it empty for a provider that sends none, as GitHub does.

```bit
fn withIssuer(tls: TlsConfig): OAuth2Options {
  return OAuth2Options{
    scopes = ["read:user"],
    tls = Option.Some(tls),
    issuer = "https://idp.example.com",
  }
}
```

## When the provider says no

An author who clicks "Cancel" on GitHub is sent back with `error=access_denied`,
and a token endpoint can refuse a code with a JSON error such as `invalid_grant`.
Both arrive as an `OAuth2Error`. Its `kind` is an `OAuth2ErrorKind`, its `code`
the provider's exact word, and `description` and `uri` carry the provider's own
text for your logs. `message()` never repeats that text, so it is safe in a
response. A user's refusal and a rejected code are a 401; a provider that is
down or misconfigured is a 502.

```bit
import { OAuth2Error, OAuth2ErrorKind } from "auth"

fn callbackRoute(app: App, gh: OAuth2Strategy) {
  app.get("/auth/github/callback", (c) => {
    gh.authenticate(c) catch e {
      let (oe, ok) = e.(OAuth2Error)
      if (ok && oe.kind == OAuth2ErrorKind.AccessDenied) {
        return c.redirect("/login?cancelled=1")
      }
      fail e
    }
    return c.redirect("/me")
  })
}
```

## Mistakes that fail at construction

`OAuth2Strategy(...)` returns an error, so the app does not start, for each of
these:

- an authorize or token URL that is not `https`;
- a `redirectUri` that is not `https` (plain `http` is accepted only for
  `localhost`, `127.0.0.1` and `[::1]`), that has a `#` fragment, or that hides a
  different host behind a user-info part;
- an empty `clientId`, or no `profile` on the endpoints;
- a scope that is empty or holds a space, quote or backslash;
- no `tls` and no `tokenFetch`;
- an `issuer` that is not `https`.

Scopes may be left empty; the request then carries no `scope`, which is what a
provider with a fixed scope wants. Providers that need one will answer
`invalid_scope`, which surfaces as an `OAuth2Error`.

## Testing your routes

`tokenFetch` stands in for the token endpoint, the same seam
[`OidcOptions.tokenFetch`](testing.md) is, and your `ProfileFetch` is already a
function you can replace. Nothing touches the network.

```bit
import { TokenFetch } from "auth"

fn fakeProvider(): OAuth2Strategy! {
  let token: TokenFetch = (url, headers, body) => {
    return "{\"access_token\":\"at-1\",\"token_type\":\"Bearer\"}"
  }
  let profile: ProfileFetch = (accessToken) => {
    return Identity{ id = "github:1", claims = Json.JsonString("ada") }
  }
  let endpoints = OAuth2Endpoints{
    authorize = "https://github.com/login/oauth/authorize",
    token = "https://github.com/login/oauth/access_token",
    profile = profile,
  }
  return OAuth2Strategy(
    endpoints,
    "test-client",
    "test-secret",
    "http://localhost:8080/auth/github/callback",
    OAuth2Options{ tokenFetch = token },
  )?
}
```

Pass `fakeProvider()` where the real one was built and the same two routes run
unchanged. A real `state` still has to come back, so a test calls the begin route
first and replays the `state` it put in the redirect.

## When not to use it

If the provider publishes an OpenID Connect discovery document and returns an ID
token, use [`OidcStrategy`](oidc.md): it verifies the token's signature and
claims, which a profile call cannot. Reach for `OAuth2Strategy` when there is no
ID token to verify.

Next: [Security model](security.md), for the one thing this package cannot
check: the TLS roots your token exchange trusts.
