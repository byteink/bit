# Refresh tokens

<!-- doctest: deps auth orm -->

A phone should not ask for a password every time its access token expires.
It can exchange the refresh token from [API tokens with JWT](34-api-tokens-with-jwt.md)
for a new pair. Each exchange must retire the old refresh token, so a copied
credential cannot keep creating fresh access unnoticed.

Against the [finished app](README.md#run-the-finished-app), send the
`refreshToken` returned by `/v1/auth/token`:

```text
curl -s http://127.0.0.1:8080/v1/auth/token/refresh \
  -H 'Content-Type: application/json' \
  -d "{\"refreshToken\":\"$REFRESH_TOKEN\"}"
```

The `data` object holds a new `accessToken` and a new `refreshToken`. Replace
both saved values together. The new access token works on `/v1/api/me`; the old
refresh token must never be sent again.

## Keep the credential out of the database

Inkwell constructs `RefreshTokens(OrmRefreshStore(db))` once in
[`mountAuth`](inkwell/auth.bit). The package creates the random credential
and gives the store only its hash. Unlike the access token, the refresh token
is opaque: the client does not decode claims from it.

The real table declaration and conversions below are from that same file.
The Bit blocks on this page join into one module, with the imports the app
normally shares across its files:

```bit
import { Ctx, Res, unauthorized } from "web"
import { AccessTokens, InvalidRefreshToken, RefreshRecord, RefreshTokens } from "auth"
import { Db } from "orm"
import { isSome, unwrap } from "std/core"
import { Json, JsonEntry } from "std/json"
import { parseInt } from "std/strings"

const accessTokenTtlSeconds = 900

@table("refresh_tokens") class RefreshRow {
  id: i64,
  tokenHash: string,
  family: string,
  subject: string,
  expiresAt: i64,
  familyExpiresAt: i64,
  rotatedAt: i64,
  revoked: i64,
  data: string,
}

fn toRefreshRow(rec: RefreshRecord): RefreshRow {
  let revoked: i64 = 0
  if (rec.revoked) {
    revoked = 1
  }
  return RefreshRow{
    id = 0, tokenHash = rec.hash, family = rec.family, subject = rec.subject,
    expiresAt = rec.expiresAt, familyExpiresAt = rec.familyExpiresAt, rotatedAt = rec.rotatedAt,
    revoked = revoked, data = rec.data,
  }
}

fn toRefreshRecord(row: RefreshRow): RefreshRecord {
  return RefreshRecord{
    hash = row.tokenHash, family = row.family, subject = row.subject, expiresAt = row.expiresAt,
    familyExpiresAt = row.familyExpiresAt, rotatedAt = row.rotatedAt, revoked = row.revoked != 0,
    data = row.data,
  }
}
```

`family` names one login. Every replacement keeps that family and its final
expiry. `rotatedAt` records an exchange; `revoked` records a refusal for the
whole family or subject. A used row stays readable so the package can
recognize a replay, rather than treating it as an unknown credential.

Apply the app's migrations before serving requests. The migration
[`ReshapeRefreshTokens`](inkwell/migrations/2026_01_05_000001_reshape_refresh_tokens.bit)
creates a unique `token_hash` column and indexes `family` and `subject`.
It drops and recreates the older table: existing refresh credentials stop
working and their holders must sign in again.

## Make the exchange one database transaction

Here is the complete `OrmRefreshStore` from [`auth.bit`](inkwell/auth.bit),
with explanatory source comments left out:

```bit
class OrmRefreshStore {
  db: Db

  init(db: Db) {
    this.db = db
  }

  export insert(rec: RefreshRecord): ()! {
    this.db.table<RefreshRow>().insert(toRefreshRow(rec))?
  }

  export findByHash(hash: string): Option<RefreshRecord>! {
    let found = this.db.table<RefreshRow>().where("tokenHash", hash).first()?
    if (!isSome(found)) {
      return Option.None
    }
    return Option.Some(toRefreshRecord(unwrap(found)))
  }

  export rotate(oldHash: string, next: RefreshRecord, at: i64): bool! {
    let won = []bool{ false }
    this.db.tx((tx) => {
      let row = tx.table<RefreshRow>().where("tokenHash", oldHash)
      let n = row.where("rotatedAt", 0).where("revoked", 0).set("rotatedAt", at).updateAll()?
      if (n == 0) {
        return
      }
      tx.table<RefreshRow>().insert(toRefreshRow(next))?
      won[0] = true
    })?
    return won[0]
  }

  export revokeFamily(family: string): ()! {
    this.db.table<RefreshRow>().where("family", family).set("revoked", 1).updateAll()?
  }

  export revokeSubject(subject: string): ()! {
    this.db.table<RefreshRow>().where("subject", subject).set("revoked", 1).updateAll()?
  }
}
```

The conditional update is the decision. Only a row with `rotatedAt == 0`
and `revoked == 0` can win. In the same transaction, the winner inserts the
replacement. If that insert fails, the transaction rolls back the update.
The losing request inserts nothing.

A read followed by an unconditional update would let two requests both
accept the same old token. With PostgreSQL, a competing update rechecks its
condition after the first transaction commits, so it sees the rotation and
returns zero rows. `won` carries the result out of `db.tx`, whose closure
returns no value. See [Transactions](15-transactions.md) for that API.

## Return a new pair, or the same refusal

The route uses these unchanged user and response declarations from
[`users.bit`](inkwell/users.bit) and [`auth.bit`](inkwell/auth.bit):

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

export fn parseId(s: string): i64! {
  return parseInt(s)?
}

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
```

Now the real request and handler can stay small:

```bit
export @json class RefreshInput {
  refreshToken: string,
}

fn refreshTokenRoute(c: Ctx, db: Db, tokens: RefreshTokens, access: AccessTokens): Res! {
  let input = c.body<RefreshInput>()?
  let next = tokens.rotate(input.refreshToken) catch e {
    let (_, invalid) = e.(InvalidRefreshToken)
    if (invalid) {
      fail unauthorized("invalid refresh token")
    }
    fail e
  }
  let u = findUserById(db, parseId(next.subject)?)?
  return c.json(tokenResponse(access.issue("${u.id}", userClaims(u))?, next.token))
}
```

`mountAuth` registers this handler at `POST /v1/auth/token/refresh`, passing the
same database, refresh service and access-token service used for issuance.
It reloads the user before making the access token, so the current role goes
into the new claims.

Unknown, malformed, expired, revoked and already-rotated credentials all
produce `401` with `invalid refresh token`. A store failure propagates as a
server error; it is not disguised as a bad credential.

## A replay ends this login

After a successful exchange, send the old refresh token again. That request
gets `401`. Then try the new refresh token: it gets `401` too. The package
revokes the family because it cannot tell whether the author or a thief
presented the copy. Sign in again to start another family.

The app uses the package defaults: each token lives for 30 days, each login
has an absolute 90-day cap, and reuse has no grace period. Serialise refreshes
in your client. Concurrent tabs or a retry after a lost response can otherwise
revoke their own login. The [package refresh-token guide](../../auth/docs/refresh-tokens.md)
explains the lifetime and grace options.

## Check rotation against PostgreSQL

[`app.test.bit`](inkwell/app.test.bit) exercises successful rotation, replay
revocation, identical bad-token responses, a losing store rotation that
inserts nothing, and concurrent rotations with one winner. Use the database
setup from [Testing the API](16-testing-the-api.md), then run:

```text
bit test pkg/web/guides/inkwell
```

These tests cover the store the app actually uses, rather than substituting
an in-memory refresh store for PostgreSQL.

## Sharp edges

The refresh response is the only place you receive the new credential.
Only its hash is stored, so a lost response cannot be recovered by asking
the database for the token. Reauthenticate when the client loses it.

`/v1/auth/logout` only destroys Inkwell's cookie session. Although the store has
`revokeFamily` and `revokeSubject` for the package to call, Inkwell has no
refresh-token sign-out endpoint. Revoking a refresh family also leaves
already-issued access tokens valid until their own expiry and clock skew.

The app has no refresh-row cleanup job. Plan storage retention for a
long-running deployment; deleting used rows too early loses reuse detection.
Keep refresh tokens in protected client storage, never a URL or a log.
A browser talking only to this server can use its existing cookie session
and avoid managing a second credential lifecycle.

Previous: [API tokens with JWT](34-api-tokens-with-jwt.md).
Next: [Sign in with Google](36-sign-in-with-google.md).
