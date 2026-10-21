# API tokens with JWT

<!-- doctest: deps auth orm -->

Inkwell's browser signs in with a session cookie. A phone app or command-line
client needs a credential it can send with each API request instead. Give it
a short-lived access token after the same password check, then accept that
token on `/v1/api/me`.

Run the [finished app](README.md#run-the-finished-app) with its migrations and
register a user through [Registering users](10-registering-users-and-hashing-passwords.md).
Use that user's credentials to ask for tokens:

```text
curl -s http://127.0.0.1:8080/v1/auth/token \
  -H 'Content-Type: application/json' \
  -d '{"username":"ada","password":"correct horse battery"}'
```

Inkwell's response envelope puts `accessToken`, `refreshToken`, `tokenType`
and `expiresIn` under `data`. Send the access token with the next request:

```text
curl -i http://127.0.0.1:8080/v1/api/me \
  -H "Authorization: Bearer $ACCESS_TOKEN"
```

Set `ACCESS_TOKEN` to the returned value in your client. A good token returns
`200` with the public user under `data`; omitting it returns `401`.
These requests use the existing app. The Bit blocks below are declarations
copied from that app, with their imports supplied explicitly; read them
together as one module.

## Build one issuer and verifier

The [configuration](inkwell/config.bit) is passed into
[`buildAccessTokens`](inkwell/auth.bit), which creates both sides of the
access-token contract. `JWT_SECRET` is separate from `APP_SECRET`, the
session-cookie key. It must contain at least 32 bytes. `JWT_ISSUER` identifies
your deployment; `JWT_AUDIENCE` identifies the API accepting its tokens.
Missing values stop startup, as do an empty issuer or audience or a short key.

```bit
import { Ctx, Res } from "web"
import { AccessTokens, KeySet, RefreshTokens, Strategy, TokenOptions, currentIdentity } from "auth"
import { Db } from "orm"
import { Json, JsonEntry } from "std/json"
import { Jwk, SigningKey, VerifyKey } from "std/jwt"
import { parseInt } from "std/strings"

const accessTokenTtlSeconds = 900

export class AppConfig {
  export databaseUrl: string,
  export redisUrl: string,
  export secret: string,
  export host: string,
  export port: int,
  export jwtSecret: string,
  export jwtIssuer: string,
  export jwtAudience: string,
  export googleClientId: string,
  export googleClientSecret: string,
  export googleRedirectUrl: string,
}

fn buildAccessTokens(cfg: AppConfig): AccessTokens! {
  let key = []byte(cfg.jwtSecret)
  let keys = KeySet{
    signing = SigningKey.Hs256Key(key), signingKid = "inkwell",
    verify = []Jwk{ Jwk{ kid = "inkwell", key = VerifyKey.Hs256Key(key) } },
  }
  return AccessTokens(
    keys,
    TokenOptions{
      issuer = cfg.jwtIssuer, audience = cfg.jwtAudience, algorithm = "HS256",
      ttl = accessTokenTtlSeconds,
    },
  )?
}
```

The `inkwell` key id names the signing key and its verification entry. The
algorithm is fixed at `HS256`; a token cannot choose another algorithm for
the server. `AccessTokens` uses `std/jwt` and adds the access-token checks:
issuer, audience, expiry, required claims and the `at+jwt` header. Signing a
JSON payload alone would leave you responsible for those rules.

The token advertises a 900-second lifetime. Verification also allows the
package's default clock skew of 60 seconds. The [bearer-token guide](../../auth/docs/bearer-tokens.md)
explains these options and how to retain old verification keys during rotation.

## Keep the same user and password check

The handlers reuse the real [user declarations](inkwell/users.bit):

```bit
@table("users") @timestamps class User {
  id: i64,
  username: string,
  email: string,
  passwordHash: string,
  role: string,
  createdAt: i64,
  updatedAt: i64,
}

export fn findUserById(db: Db, id: i64): User! {
  return db.table<User>().find(id)?
}

export fn userClaims(u: User): Json {
  return Json.JsonObject([JsonEntry{ key = "role", value = Json.JsonString(u.role) }])
}

export @json class PublicUser {
  id: i64,
  username: string,
  role: string,
}

export fn toPublicUser(u: User): PublicUser {
  return PublicUser{ id = u.id, username = u.username, role = u.role }
}

export fn parseId(s: string): i64! {
  return parseInt(s)?
}
```

The `role` claim comes from the saved user, never the request body. The public
response leaves out the password hash.

`mountAuth` gives `issueTokens` the same `PasswordStrategy(userLookup(db))`
used by password login. The handler authenticates that request, starts a
refresh-token family and returns both credentials:

```bit
export @json class TokenResponse {
  accessToken: string,
  refreshToken: string,
  tokenType: string,
  expiresIn: int,
}

fn tokenResponse(access: string, refresh: string): TokenResponse {
  return TokenResponse{
    accessToken = access, refreshToken = refresh, tokenType = "Bearer",
    expiresIn = accessTokenTtlSeconds,
  }
}

fn issueTokens(
  c: Ctx,
  db: Db,
  tokens: RefreshTokens,
  strategy: Strategy,
  access: AccessTokens,
): Res! {
  let identity = strategy.authenticate(c)?
  let u = findUserById(db, parseId(identity.id)?)?
  let refresh = tokens.issue("${u.id}")?
  return c.json(tokenResponse(access.issue("${u.id}", userClaims(u))?, refresh))
}
```

`expiresIn` describes the access token, not the refresh token. You need the
longer-lived credential only when renewing access; the next chapter follows
its storage and rotation.

## Guard only the API group

These lines are excerpted from [`mountAuth`](inkwell/auth.bit). They use its
existing `app: Routes`, `db`, `access`, `tokens` and password `strategy`
values. `main.bit` passes the `/v1` group as `app`, so these paths stay
relative to that prefix:

```text
let bearer = BearerStrategy(access)
app.post("/auth/token", (c) => issueTokens(c, db, tokens, strategy, access))
let api = app.group("/api")
api.use(requireAuth([bearer]))
api.get("/me", (c) => showApiMe(c, db))
```

`BearerStrategy` reads `Authorization`, verifies the access token and gives
`requireAuth` an identity. The handler reads that identity with
`currentIdentity`, then fetches the current public user:

```bit
fn showApiMe(c: Ctx, db: Db): Res! {
  let identity = currentIdentity(c)?
  let u = findUserById(db, parseId(identity.id)?)?
  return c.json(toPublicUser(u))
}
```

A browser cookie does not replace the bearer header on `/v1/api/me`. Conversely,
this group does not convert `/v1/articles` or `/v1/me` into bearer routes; those
still use Inkwell's session helpers. Authentication also does not replace the
ownership checks from [Authorization](12-authorization.md).

## Check the refusal as well as the success

The test `POST /v1/auth/token issues a bearer token, and GET /v1/api/me accepts it`
in [`app.test.bit`](inkwell/app.test.bit) checks issuance, the response
fields, refusal without a token and acceptance with the issued token. Run
the finished app's tests with the PostgreSQL setup from
[Testing the API](16-testing-the-api.md):

```text
bit test pkg/web/guides/inkwell
```

A refused bearer request carries `WWW-Authenticate: Bearer`; a bad token
adds `error="invalid_token"`. Inkwell's response middleware may wrap the
error body, so use the status and challenge to handle authentication failure.

## Sharp edges

Anyone holding the token can use it. Send it over HTTPS outside local
development and keep both credentials out of logs and URLs. A JWT signature
protects its contents from changes; it does not hide them.

Signing out of the browser destroys its cookie session. It does not revoke
an issued access token or refresh token. An access token remains usable
through its expiry and allowed clock skew. For immediate server-controlled
sign-out, the cookie session from [Sessions and logging in](11-sessions-and-logging-in.md)
is simpler; use tokens when the client needs this API credential flow.

Previous: [Generate the API document from its routes](33-generated-openapi.md).
Next: [Refresh tokens](35-refresh-tokens.md).
