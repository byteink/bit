# Sign in with Google

<!-- doctest: deps auth orm -->

An Inkwell reader may want to use their Google account instead of creating
another password. The app already has a local user and session model; the
Google callback needs to connect the returned identity to that same model,
so article ownership keeps working.

Use the [finished app](README.md#run-the-finished-app) with its database,
migrations and required token settings. Google sign-in is optional. If any
of its three settings is empty, both Google routes return `404`.

## Configure the return address

Create an OAuth client for a web application in your Google Cloud project.
Configure the consent screen and register an authorized redirect URI that
matches `GOOGLE_REDIRECT_URL` exactly, including scheme, host, port and path.
Google documents the [client and redirect setup](https://developers.google.com/identity/openid-connect/openid-connect#settingup);
a mismatch produces `redirect_uri_mismatch`.

For an app running locally on port 8080, register
`http://127.0.0.1:8080/v1/auth/google/callback`, then set:

```text
export GOOGLE_CLIENT_ID='your-client-id.apps.googleusercontent.com'
export GOOGLE_CLIENT_SECRET='your-client-secret'
export GOOGLE_REDIRECT_URL='http://127.0.0.1:8080/v1/auth/google/callback'
```

Use HTTPS for a deployed application and register that deployment's callback
instead. Keep the secret on the server. Restart Inkwell after changing these
values: [`loadConfig`](inkwell/config.bit) reads them once at startup.

Open `http://127.0.0.1:8080/v1/auth/google` in your browser. After Google's
consent step, the browser returns to `/v1/auth/google/callback`. Successful
application code returns `204 No Content`, so there is no welcome page.
Visit `/v1/me` in the same browser to fetch the local public user.

This is the intended configured flow. Local signed callback fixtures check
account binding, and the disabled-route test checks `404`. A real Google
browser round trip remains a deployment check.

## Build the provider when the route needs it

These declarations come from [`config.bit`](inkwell/config.bit) and
[`auth.bit`](inkwell/auth.bit). The Bit blocks on this page form one module;
the imports supply names normally shared by the app's source files.

```bit
import { Ctx, Res, conflict, notFound, unauthorized } from "web"
import { Identity, OidcOptions, OidcStrategy, Provider, beginAuthorization, handleCallback } from "auth"
import { Db, UniqueViolation, classify } from "orm"
import { isSome, unwrap } from "std/core"
import { systemRoots } from "std/crypto"
import { jsonAsBool, jsonAsString, jsonGet } from "std/json"
import { now } from "std/time"
import { TlsConfig } from "std/tls"

const sessionUserIdKey = "inkwell:userId"
const sessionRoleKey = "inkwell:role"

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

fn googleConfigured(cfg: AppConfig): bool {
  return len(cfg.googleClientId) > 0 &&
    len(cfg.googleClientSecret) > 0 &&
    len(cfg.googleRedirectUrl) > 0
}

fn buildGoogleStrategy(cfg: AppConfig): OidcStrategy! {
  let sys = systemRoots()?
  let tls = TlsConfig(sys)
  return OidcStrategy(
    Provider.Google,
    cfg.googleClientId,
    cfg.googleClientSecret,
    cfg.googleRedirectUrl,
    OidcOptions{ tls = Option.Some(tls) },
  )?
}

fn googleBegin(c: Ctx, cfg: AppConfig): Res! {
  if (!googleConfigured(cfg)) {
    fail notFound()
  }
  return beginAuthorization(buildGoogleStrategy(cfg)?, c)?
}
```

`systemRoots` supplies the operating system's trusted certificate roots for
Google's HTTPS endpoints. `Provider.Google` discovers those endpoints when
`OidcStrategy` is constructed. Building it on request lets Inkwell start and
serve its other routes even when Google cannot be reached. A configured
Google request still fails if discovery or certificate verification fails.

The default scopes are `openid email profile`. `beginAuthorization` returns
the redirect and keeps the state, nonce and code verifier needed for the
return trip. Keep the browser's session cookie throughout that trip.
`OidcStrategy` describes a two-request flow; it is not a one-call password
or bearer `Strategy` to place inside `requireAuth`.

## Connect the callback to a local user

Inkwell keeps local users separate from Google identities. Apply the
`CreateGoogleIdentities` migration with `bit migrate` before starting the app.
It creates a composite primary key on `issuer` and `subject`, plus a foreign
key to `users.id`. Existing users remain unlinked.

The model in [`users.bit`](inkwell/users.bit) records that binding:

```bit
@table("users") @timestamps class User {
  id: i64,
  username: string,
  email: string,
  passwordHash: string,
  // "author" or "admin" - checked by auth.bit's `requireAdmin`/`isOwner`.
  role: string,
  createdAt: i64,
  updatedAt: i64,
}

@table("google_identities") class GoogleIdentity {
  @id
  issuer: string
  @id
  subject: string
  userId: i64
}

fn newUser(username: string, email: string, passwordHash: string, role: string): User {
  let stamp = now().ns
  return User{
    id = 0, username = username, email = email, passwordHash = passwordHash, role = role,
    createdAt = stamp, updatedAt = stamp,
  }
}
```

The callback requires a JSON boolean `email_verified: true` before any account
query. It then uses the verified token's issuer and subject, never its email,
to find a binding. A known identity keeps its original local user when the
email changes. For a new identity, the user and binding are inserted in one
transaction. A username, email or identity collision rolls back both writes
and returns `409`; it never attaches to an existing password account.

These helpers in [`auth.bit`](inkwell/auth.bit) implement that order.
`newUser` constructs the same `User` registration inserts, including timestamps;
the empty password hash gives a Google-created user no password login.

```bit
fn verifiedGoogleEmail(identity: Identity): string! {
  let verified = jsonGet(identity.claims, "email_verified")
  if (!isSome(verified)) {
    fail unauthorized("Google email must be verified")
  }
  let flag = jsonAsBool(unwrap(verified))
  if (!isSome(flag) || !unwrap(flag)) {
    fail unauthorized("Google email must be verified")
  }
  return googleClaim(identity, "email")?
}

fn googleClaim(identity: Identity, key: string): string! {
  let field = jsonGet(identity.claims, key)
  if (!isSome(field)) {
    fail unauthorized("Google identity carries no '${key}' claim")
  }
  let value = jsonAsString(unwrap(field))
  if (!isSome(value) || unwrap(value) == "") {
    fail unauthorized("Google identity carries no '${key}' string")
  }
  return unwrap(value)
}

fn findOrCreateGoogleUser(db: Db, identity: Identity): User! {
  let email = verifiedGoogleEmail(identity)?
  let issuer = googleClaim(identity, "iss")?
  let subject = googleClaim(identity, "sub")?
  let result = []User{ newUser(email, email, "", "author") }
  db.tx((tx) => {
    let found = tx.table<GoogleIdentity>().where("issuer", issuer).where("subject", subject).first()?
    if (isSome(found)) {
      result[0] = tx.table<User>().find(unwrap(found).userId)?
      return
    }
    // Unique usernames/emails reject collisions; a matching email never grants ownership.
    let user = tx.table<User>().insert(result[0])?
    tx.table<GoogleIdentity>().insert(
      GoogleIdentity{ issuer = issuer, subject = subject, userId = user.id },
    )?
    result[0] = user
  }) catch e {
    let cause = classify(e, "users")
    let (_, duplicate) = cause.(UniqueViolation)
    if (duplicate) {
      fail conflict("that username, email or provider identity is already registered")
    }
    fail cause
  }
  return result[0]
}
```

Now the callback can reuse Inkwell's session keys:

```bit
fn googleCallback(c: Ctx, db: Db, cfg: AppConfig): Res! {
  if (!googleConfigured(cfg)) {
    fail notFound()
  }
  return googleCallbackWith(c, db, buildGoogleStrategy(cfg)?)?
}

fn googleCallbackWith(c: Ctx, db: Db, strategy: OidcStrategy): Res! {
  let identity = handleCallback(strategy, c)?
  let u = findOrCreateGoogleUser(db, identity)?
  let session = c.session()?
  session.set(sessionUserIdKey, "${u.id}")
  session.set(sessionRoleKey, u.role)
  return c.noContent()
}
```

`googleCallbackWith` takes the existing `OidcStrategy` value so local tests
can supply signed tokens through its public `tokenFetch` seam. Production
builds the Google strategy as before. Both paths call the same `handleCallback`
for signature, issuer, audience, nonce, state and PKCE checks. Only after those
checks and local account validation does the app set its user id and role.

These route registrations are excerpted from `mountAuth`, where `app`, `db`
and `cfg` already exist. Here `app: Routes` is the `/v1` group passed by
`main.bit`; the paths below are relative to that group:

```text
app.get("/auth/google", (c) => googleBegin(c, cfg))
app.get("/auth/google/callback", (c) => googleCallback(c, db, cfg))
```

## Keep account linking explicit

Google documents [the ID token's identity claims](https://developers.google.com/identity/openid-connect/openid-connect#obtainuserinfo):
`sub` stays with the account, while email can change. Inkwell stores that
subject together with the verified issuer. A verified email permits a new
account; it does not prove ownership of an existing local account.

Inkwell has no account-link route. A collision returns `409`; the reader can
continue with their existing password. Do not backfill provider identities
from users' email addresses, including older Google-created rows. A future
link flow must verify the local account and require explicit consent.

## Check what can be checked without Google

The test `GET /v1/auth/google is disabled (404) when Google sign-in is not configured`
in [`app.test.bit`](inkwell/app.test.bit) keeps the feature optional. With
the PostgreSQL setup from [Testing the API](16-testing-the-api.md), run:

```text
bit test pkg/web/guides/inkwell
```

[`google.test.bit`](inkwell/google.test.bit) drives the actual callback with a
local signed provider fixture. It covers missing, false and nonboolean email
verification, local username collisions, unchanged password login and stable
issuer/subject binding after an email change. They also check transaction
rollback after a binding insert fails, and the real foreign key. The auth package separately
tests its OIDC callback verification. Neither suite needs Google credentials
or performs a real Google redirect.
A configured deployment still needs the browser round trip described above,
including checking `/v1/me` after the callback.

## Sharp edges

Google sign-in creates an Inkwell cookie session. It does not return the
access/refresh pair from the previous chapters, and Google's ID token is not
an Inkwell bearer access token.

`POST /v1/auth/logout` ends the local session only. It does not sign the browser
out of Google, so a later Google sign-in may complete without another
password prompt. See the [package's OIDC guide](../../auth/docs/oidc.md)
for the provider flow and logout behavior.

Keep password login when your users need to sign in without Google, or when
you do not need an external identity provider. Leaving the Google settings
empty keeps the rest of Inkwell usable.

Previous: [Refresh tokens](35-refresh-tokens.md).
Next: [Idempotency keys](40-idempotency-keys.md).
