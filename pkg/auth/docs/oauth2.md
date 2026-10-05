# Sign in with GitHub, or any OAuth 2.0 provider

Inkwell's authors keep their drafts on GitHub already, so they ask for "Sign in
with GitHub". GitHub, Discord, Slack and plenty of others speak plain OAuth 2.0:
they hand your server an access token, not an ID token, so
[`OidcStrategy`](oidc.md) has nothing to verify. `OAuth2Strategy` runs the same
redirect flow and then asks the provider's own profile API who the user is.
For GitHub that last step is built in: `github(...)` returns the endpoints and
the profile call, and you supply your client id and secret.

## GitHub in one function

`github(...)` returns the `OAuth2Endpoints` for GitHub: its authorize and token
URLs, and a `ProfileFetch` that reads `GET /user` and `GET /user/emails` with
the headers GitHub's REST API asks for. Pass it to `OAuth2Strategy` with
`githubScopes`, which is `read:user user:email`: the first lets it read the
profile, the second the email addresses.

```bit
import { App, Config, MemoryStore, unauthorized } from "web"
import {
  GithubOptions,
  Identity,
  OAuth2Endpoints,
  OAuth2Options,
  OAuth2Strategy,
  currentIdentity,
  github,
  githubScopes,
} from "auth"
import { TlsConfig } from "std/tls"
import { fromPem } from "std/crypto"
import { jsonAsString, jsonGet } from "std/json"
import { isSome, unwrap } from "std/core"

// `rootsPem` is your deployment's trusted CA bundle; this package never
// guesses one.
fn githubStrategy(rootsPem: string): OAuth2Strategy! {
  let tls = TlsConfig(fromPem(rootsPem)?)
  let endpoints = github(GithubOptions{ tls = Option.Some(tls) })?
  return OAuth2Strategy(
    endpoints,
    "your-client-id",
    "your-client-secret",
    "https://app.example.com/auth/github/callback",
    OAuth2Options{ scopes = githubScopes, tls = Option.Some(tls), name = "github" },
  )?
}

// A claim of the Identity as text, "" when it is not there.
fn claim(identity: Identity, key: string): string {
  let v = jsonGet(identity.claims, key)
  if (!isSome(v)) {
    return ""
  }
  let s = jsonAsString(unwrap(v))
  if (!isSome(s)) {
    return ""
  }
  return unwrap(s)
}

fn build(rootsPem: string): App! {
  let app = App(Config{ secret = "change-me", sessions = MemoryStore(10_000) })
  let gh = githubStrategy(rootsPem)?

  app.get("/auth/github", (c) => gh.beginAuthorization(c))
  app.get("/auth/github/callback", (c) => {
    let who: Identity = gh.authenticate(c)?
    return c.redirect("/me")
  })

  app.get("/me", (c) => {
    let identity: Identity = currentIdentity(c) catch _ {
      fail unauthorized()
    }
    return c.text("${identity.id} ${claim(identity, "login")} ${claim(identity, "email")}")
  })
  return app
}
```

`beginAuthorization` stores a random `state` and a PKCE verifier on the user's
session and redirects to GitHub, which supports PKCE with `S256`. `authenticate`
is the other half: the route GitHub sends the browser back to. It checks the
`state`, exchanges the code, calls the profile step with the access token,
regenerates the session id and stores the `Identity` exactly as the password and
OpenID Connect logins do, so `/me` does not care which one ran. Because
`OAuth2Strategy` has `name()` and `authenticate(c)`, it is also a `Strategy` you
can hand to `requireAuth`.

## What the Identity holds

- **`id` is GitHub's numeric user id**, as a decimal string, such as `583231`.
  Never the login: a user can rename their login and someone else can then take
  the old one, so a login is not an identity. Key your users table on `id`.
- **`email` is the primary address, and only if GitHub has verified it.** GitHub
  lets anyone add an address they have not proven to their account, so an
  unverified one, or a verified one that is not the primary, is never returned;
  neither is the public `email` on the profile, which is whatever the user chose
  to show. When there is none, `email` is `""` and `email_verified` is `false`.
  `email_verified` is `true` exactly when `email` is set.
- **`login`, `name` and `avatar_url`** are strings; `name` is `""` when the user
  has not set one.

By default a sign-in whose account has no verified primary email fails with an
`Error`, because most apps key mail and account recovery on it. An app that does
not need one sets `requireVerifiedEmail = false` and gets the empty `email`.

## GitHub Enterprise Server

`enterpriseHost` points all three URLs at your server: the authorize URL
`https://HOST/login/oauth/authorize`, the token URL
`https://HOST/login/oauth/access_token` and the API under `https://HOST/api/v3`.
It is a bare host, with an optional port, and nothing else.

```bit
fn enterprise(tls: TlsConfig): OAuth2Endpoints! {
  return github(
    GithubOptions{
      enterpriseHost = "ghe.example.com",
      requireVerifiedEmail = false,
      tls = Option.Some(tls),
    },
  )?
}
```

A host with a scheme, a path, a query or userinfo is an `Error` when the app
starts: that string would be a URL the access token is sent to.

## Any other provider

For a provider with no preset you supply the same three things yourself: the
provider's two endpoints, your client id and secret, and a `ProfileFetch`, the
function that turns an access token into an `Identity`. Every provider's profile
document looks different, so that function is yours; it is usually ten lines.
Here is Discord's.

```bit
import { Client, Header } from "std/http"
import { Json, jsonAsInt, jsonParse } from "std/json"
import { ProfileFetch } from "auth"

// Discord's `GET /users/@me` answer: a stable `id` and a `username`.
fn discordIdentity(body: string): Identity! {
  let doc = jsonParse(body)?
  let id = jsonGet(doc, "id")
  if (!isSome(id) || !isSome(jsonAsString(unwrap(id)))) {
    fail newError("discord: profile has no id")
  }
  let name = jsonGet(doc, "username")
  if (!isSome(name) || !isSome(jsonAsString(unwrap(name)))) {
    fail newError("discord: profile has no username")
  }
  return Identity{
    id = "discord:${unwrap(jsonAsString(unwrap(id)))}",
    claims = Json.JsonString(unwrap(jsonAsString(unwrap(name)))),
  }
}

fn discordProfile(tls: TlsConfig): ProfileFetch {
  let f: ProfileFetch = (token) => {
    let headers = []Header{
      Header{ name = "Authorization", value = "Bearer " + token },
      Header{ name = "Accept", value = "application/json" },
    }
    let res = Client(tls = tls).requestWith("GET", "https://discord.com/api/users/@me", headers, "")?
    if (res.status != 200) {
      fail newError("discord: profile request answered ${res.status}")
    }
    return discordIdentity(res.body)?
  }
  return f
}

fn discordEndpoints(tls: TlsConfig): OAuth2Endpoints {
  return OAuth2Endpoints{
    authorize = "https://discord.com/oauth2/authorize",
    token = "https://discord.com/api/oauth2/token",
    profile = discordProfile(tls),
  }
}
```

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

`github(...)` fails the same way: an `enterpriseHost` that is not a bare host, or
no `tls` and no `apiFetch`. A request that GitHub refuses at sign-in time, such
as `/user/emails` answering 404 because the `user:email` scope was not asked
for, fails the sign-in with the status in the message and never the token.

Scopes may be left empty; the request then carries no `scope`, which is what a
provider with a fixed scope wants. Providers that need one will answer
`invalid_scope`, which surfaces as an `OAuth2Error`.

## Testing your routes

`tokenFetch` stands in for the token endpoint, the same seam
[`OidcOptions.tokenFetch`](testing.md) is, and `GithubOptions.apiFetch` stands in
for GitHub's API: it receives each URL and its headers and answers the body.
With both set no `tls` is needed and nothing touches the network.

```bit
import { GithubFetch, TokenFetch } from "auth"
import { contains } from "std/strings"

fn fakeGithub(): OAuth2Strategy! {
  let token: TokenFetch = (url, headers, body) => {
    return "{\"access_token\":\"at-1\",\"token_type\":\"Bearer\"}"
  }
  let api: GithubFetch = (url, headers) => {
    if (contains(url, "/user/emails")) {
      return "[{\"email\":\"ada@example.com\",\"primary\":true,\"verified\":true}]"
    }
    return "{\"id\":583231,\"login\":\"ada\",\"name\":\"Ada\"}"
  }
  return OAuth2Strategy(
    github(GithubOptions{ apiFetch = api })?,
    "test-client",
    "test-secret",
    "http://localhost:8080/auth/github/callback",
    OAuth2Options{ scopes = githubScopes, tokenFetch = token },
  )?
}
```

Pass `fakeGithub()` where the real one was built and the same two routes run
unchanged. A real `state` still has to come back, so a test calls the begin route
first and replays the `state` it put in the redirect.

## When not to use it

If the provider publishes an OpenID Connect discovery document and returns an ID
token, use [`OidcStrategy`](oidc.md): it verifies the token's signature and
claims, which a profile call cannot. Reach for `OAuth2Strategy` when there is no
ID token to verify, as there is not for GitHub.

Next: [Security model](security.md), for the one thing this package cannot
check: the TLS roots your token exchange trusts.
