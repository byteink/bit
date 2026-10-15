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
`http://127.0.0.1:8080/auth/google/callback`, then set:

```text
export GOOGLE_CLIENT_ID='your-client-id.apps.googleusercontent.com'
export GOOGLE_CLIENT_SECRET='your-client-secret'
export GOOGLE_REDIRECT_URL='http://127.0.0.1:8080/auth/google/callback'
```

Use HTTPS for a deployed application and register that deployment's callback
instead. Keep the secret on the server. Restart Inkwell after changing these
values: [`loadConfig`](inkwell/config.bit) reads them once at startup.

Open `http://127.0.0.1:8080/auth/google` in your browser. After Google's
consent step, the browser returns to `/auth/google/callback`. Successful
application code returns `204 No Content`, so there is no welcome page.
Visit `/me` in the same browser to fetch the local public user.

This is the intended configured flow. The app's automated test only checks
the unconfigured `404`; it does not exercise a live Google login.

## Build the provider when the route needs it

These declarations come from [`config.bit`](inkwell/config.bit) and
[`auth.bit`](inkwell/auth.bit). The Bit blocks on this page form one module;
the imports supply names normally shared by the app's source files.

```bit
import { Ctx, Res, conflict, notFound, unauthorized } from "web"
import { OidcOptions, OidcStrategy, Provider, beginAuthorization, handleCallback } from "auth"
import { Db, UniqueViolation, classify } from "orm"
import { isSome, unwrap } from "std/core"
import { systemRoots } from "std/crypto"
import { jsonDecString, jsonGet } from "std/json"
import { now } from "std/time"
import { TlsConfig } from "std/tls"

const sessionUserIdKey = "inkwell:userId"
const sessionRoleKey = "inkwell:role"

export class AppConfig {
  export databaseUrl: string,
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

Inkwell uses the same user table and insertion function as registration.
These are actual declarations from [`users.bit`](inkwell/users.bit) and
[`auth.bit`](inkwell/auth.bit), with source comments omitted:

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

fn insertUser(db: Db, username: string, email: string, passwordHash: string, role: string): User! {
  let stamp = now().ns
  return db.table<User>().insert(
    User{
      id = 0, username = username, email = email, passwordHash = passwordHash, role = role,
      createdAt = stamp, updatedAt = stamp,
    },
  ) catch e {
    let cause = classify(e, "users")
    let (_, ok) = cause.(UniqueViolation)
    if (ok) {
      fail conflict("that username or email is already registered")
    }
    fail cause
  }
}

fn findOrCreateGoogleUser(db: Db, email: string): User! {
  let found = db.table<User>().where("username", email).first()?
  if (isSome(found)) {
    return unwrap(found)
  }
  return insertUser(db, email, email, "", "author")?
}
```

The helper looks up `username` using the returned email. If no matching
username exists, it inserts an author whose username and email are that
email. The empty password hash marks an account without a local password;
it does not create an empty password that password login will accept.

Now the callback can reuse Inkwell's session keys:

```bit
fn googleCallback(c: Ctx, db: Db, cfg: AppConfig): Res! {
  if (!googleConfigured(cfg)) {
    fail notFound()
  }
  let identity = handleCallback(buildGoogleStrategy(cfg)?, c)?
  let emailField = jsonGet(identity.claims, "email")
  if (!isSome(emailField)) {
    fail unauthorized("Google identity carries no 'email' claim")
  }
  let email = jsonDecString(unwrap(emailField), "identity.claims.email")?
  let u = findOrCreateGoogleUser(db, email)?
  let session = c.session()?
  session.set(sessionUserIdKey, "${u.id}")
  session.set(sessionRoleKey, u.role)
  return c.noContent()
}
```

`handleCallback` validates the return trip and ID token, regenerates the
session id and stores the package identity. The app then looks up or creates
its own `User` and writes the local user id and role into the session keys
that article handlers already read. It does not regenerate the session again.

These route registrations are excerpted from `mountAuth`, where `app`, `db`
and `cfg` already exist:

```text
app.get("/auth/google", (c) => googleBegin(c, cfg))
app.get("/auth/google/callback", (c) => googleCallback(c, db, cfg))
```

## Know the account-linking limit

A validated ID token and a verified email address are different checks. This
callback only requires an `email` string; it does not check `email_verified`
or persist Google's stable `sub` as a provider identity. Google documents
[the ID token's identity claims](https://developers.google.com/identity/openid-connect/openid-connect#obtainuserinfo)
and advises using `sub`, rather than email, to identify an account.

If an existing local username equals that email, this helper uses that row.
If an existing row has the same email under a different username, the insert
hits the users table's unique constraint and returns
`that username or email is already registered`. An email change can also
select a different local account. Decide how to verify and link provider
identities before using this course app's mapping for production accounts.

The app reports a missing email claim as
`Google identity carries no 'email' claim`. It does not fall back to an
unverified field from the request or create an anonymous author.

## Check what can be checked without Google

The test `GET /auth/google is disabled (404) when Google sign-in is not configured`
in [`app.test.bit`](inkwell/app.test.bit) keeps the feature optional. With
the PostgreSQL setup from [Testing the API](16-testing-the-api.md), run:

```text
bit test pkg/web/guides/inkwell
```

The auth package also tests callback verification with a mock provider.
Those tests do not test Inkwell's user mapping or a real Google redirect.
A configured deployment still needs the browser round trip described above,
including checking `/me` after the callback.

## Sharp edges

Google sign-in creates an Inkwell cookie session. It does not return the
access/refresh pair from the previous chapters, and Google's ID token is not
an Inkwell bearer access token.

`POST /auth/logout` ends the local session only. It does not sign the browser
out of Google, so a later Google sign-in may complete without another
password prompt. See the [package's OIDC guide](../../auth/docs/oidc.md)
for the provider flow and logout behavior.

Keep password login when your users need to sign in without Google, or when
you do not need an external identity provider. Leaving the Google settings
empty keeps the rest of Inkwell usable.

Previous: [Refresh tokens](35-refresh-tokens.md).
Next: [Idempotency keys](40-idempotency-keys.md).
