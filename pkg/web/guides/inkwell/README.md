# Inkwell

Inkwell is the running blogging application used by the web guides. It stores
accounts and articles in PostgreSQL, and shares Redis between sessions, cached
responses and background jobs. Apply this directory's migrations before starting
the application.

## Send a welcome email after registration

A slow mail relay should not hold an HTTP registration request open. With mail
enabled, `POST /v1/auth/register` saves the user, enqueues `SendWelcomeEmail` through
the existing jobs queue, and returns `201`. The application's existing worker
delivers one plain-text welcome message with a verification link addressed to that saved user. The same
worker still runs the nightly article digest.

First configure the application's existing `DATABASE_URL`, `REDIS_URL`,
`APP_SECRET`, `JWT_SECRET`, `JWT_ISSUER` and `JWT_AUDIENCE` settings. With those
services and a development SMTP relay already running, start from this directory:

```sh
export SMTP_HOST=127.0.0.1
export SMTP_PORT=1025
export SMTP_FROM=welcome@example.test
export VERIFY_EMAIL_URL=http://localhost:8080/confirm
bit migrate
bit run main.bit
```

In another terminal, register an account:

```sh
curl --fail-with-body http://127.0.0.1:8080/v1/auth/register \
  -H 'Content-Type: application/json' \
  -d '{"username":"new-author","email":"author@example.test","password":"development-password"}'
```

The relay receives a message with subject `Welcome to Inkwell`. Registration
enqueues the message; run the application entry point to start its worker.

`SMTP_HOST` and `SMTP_FROM` both default to empty, which disables welcome mail.
Set both to enable it; a partial configuration fails startup. `SMTP_PORT` defaults
to `465` and must be between `1` and `65535`. Remote relays use implicit TLS with
certificate verification. Only the explicit loopback hosts `127.0.0.1` and `::1`
use cleartext for local development. SMTP credentials and STARTTLS submission are
not configured by this example.

The queue persists jobs in Redis and applies its ordinary retry and dead-letter
policy when delivery fails. Keep Redis durable if pending mail must survive a
restart. Saving the user in PostgreSQL and enqueueing in Redis are separate
operations: an enqueue failure returns an error even though the user may already
exist. This example does not provide a transactional outbox or exactly-once mail.

The configured `VERIFY_EMAIL_URL` is the trusted confirmation page, never a
request's Host header. It must be HTTPS (HTTP is allowed only for localhost or
loopback), with no query, fragment or credentials. The application validates it
when mail is enabled. Supply your own confirmation page at that URL: reading a
link must not change account state, because mail scanners may open links.
After the recipient chooses to confirm, the page submits the token from the link:

```sh
curl --fail-with-body http://127.0.0.1:8080/v1/auth/verify-email \
  -H 'Content-Type: application/json' \
  -d '{"token":"TOKEN_FROM_THE_EMAIL"}'
```

Previously queued welcome messages still deliver their original welcome text;
they do not gain a verification link retroactively.

The POST returns `204` once. Unknown, expired, used, wrong-purpose or changed-address
tokens all return `401` without marking an account. A link expires after 24 hours.
Only its SHA-256 digest is stored in PostgreSQL; the mail job in Redis necessarily
contains the usable link, so restrict Redis access and protect its backups. The
public user and registration responses never contain the token. Confirmation
consumes the token and marks its bound account inside one PostgreSQL transaction;
a store failure rolls both changes back. Registration commits the account and digest together before
queueing the mail. Invalid-address validation rolls both changes back. If enqueueing fails, the user and digest may remain, and retrying
registration can return a conflict. Resending verification mail is separate. The confirmation page itself is not supplied by this example.

## Recover a forgotten password

Set `RESET_PASSWORD_URL=https://inkwell.example.test/reset` to your trusted reset
page. It follows the same origin rules as `VERIFY_EMAIL_URL`. The page reads the
link token and submits a new password only after the user chooses to reset it.

```sh
curl --fail-with-body http://127.0.0.1:8080/v1/auth/forgot-password \
  -H 'Content-Type: application/json' -d '{"email":"author@example.test"}'
curl --fail-with-body http://127.0.0.1:8080/v1/auth/reset-password \
  -H 'Content-Type: application/json' \
  -d '{"token":"TOKEN_FROM_THE_RESET_EMAIL","password":"replacement-password"}'
```

Forgot-password returns the same `204` for known and unknown accounts after
queueing the same email-only job. The worker looks up the address; an unknown
address sends no mail. A known account receives one usable link, replacing its
previous reset link. Its digest expires after one hour. Reset validates the
existing eight-character minimum before consuming the token, updates only its
bound account and revokes other reset links and refresh credentials in one
PostgreSQL transaction. Invalid, expired, used or changed-address tokens return
`401`. Queue and store failures remain errors. PostgreSQL and Redis remain
separate, without an outbox or exactly-once delivery guarantee.

Existing cookie sessions retain their current expiry and logout behavior.
Already issued access JWTs remain valid for their remaining lifetime, at most
900 seconds; resetting a password does not provide global session logout.
Protect mail, Redis jobs and backups: the worker must send the usable link.
Tokens stay out of public JSON and worker failure logs.

## Restrict an administrative user lookup

Some routes need a role check before they read data. Inkwell stores the signed-in
account's role in its existing session. `requireRole(c, roles)` allows an exact
match from the supplied list; anonymous callers, missing roles and an empty list
are forbidden. Names are case-sensitive: `Admin` does not match `admin`.

The application mounts `GET /v1/admin/users/:id` with `requireRole(c, ["admin"])`
before the existing user lookup. A forbidden request cannot query a user. An
allowed request returns the same public `id`, `username` and `role` as
`GET /v1/users/:id`; email, password hashes and tokens stay private. Invalid IDs
still return `400`, and missing users return `404`.

With the application running as above, sign in using an existing administrator
account and request its public profile. Registration always creates authors;
this example does not provide an endpoint for granting administrative roles.

```sh
curl --fail-with-body -c admin.cookies http://127.0.0.1:8080/v1/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"username":"existing-admin","password":"ADMIN_PASSWORD"}'
curl --fail-with-body -b admin.cookies http://127.0.0.1:8080/v1/admin/users/1
```

Inside this application, use the same helper when a route accepts several roles:

```bit
fn mountEditorial(app: App) {
  app.get("/editorial", (c) => {
    requireRole(c, ["editor", "admin"])?
    return c.text("editorial access")
  })
}
```

The existing `requireAdmin` and owner-or-admin checks retain their behavior.
Role changes take effect after a new login; this change does not add live role
refresh. Authenticator enrollment is described below.

## Inspect article and comment changes

After applying the migrations, each article create, update, delete or cover
replacement and each comment create or delete writes an `audit_logs` row in
the same PostgreSQL transaction. The row stores the acting user's ID, the action, the target and the
creation time in Unix nanoseconds. An administrator's edit records the
administrator as the actor, even when another user owns the article.

Log in as the account registered above, then create an article:

```sh
curl --fail-with-body -c audit.cookies http://127.0.0.1:8080/v1/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"username":"new-author","password":"development-password"}'
curl --fail-with-body -i -b audit.cookies http://127.0.0.1:8080/v1/articles \
  -H 'Content-Type: application/json' \
  -d '{"title":"Audited article","body":"First draft","tags":[]}'
```

The article response returns a `Location` header ending in its ID. In PostgreSQL,
replace `1` below with that ID to inspect its history:

```sql
select actor_id, action, target, created_at
from audit_logs
where target = 'article/1'
order by id;
```

An article's actions are `article.create`, `article.update`, `article.delete` and
`article.cover`.
Comment actions are `comment.create` and `comment.delete`, with `comment/<id>`
targets. A rejected write adds no row. An audit insert error rolls back the
mutation; it is returned to the caller. Deleting an article records its soft
deletion; existing comment rows remain.
The target remains readable after deletion. The actor foreign key restricts user
deletion so that existing history survives.

Redis cache invalidation follows the database commit. A cache error can therefore
return an error after the mutation and its audit row have committed.

Successful cookie, initial-token and Google sign-ins add an `auth.login` row
with a `user/<id>` target. Inspect an account's history without copying its
credentials into a log:

```sql
select actor_id, action, target, created_at
from audit_logs
where target = 'user/1'
order by id;
```

A refused password or unverified Google address adds no sign-in event. If the
audit write fails, sign-in fails and the current request's session is locally
invalidated. Its provisional id is not sent in a new cookie, even if the
session store refuses deletion. That store error still propagates; remote
revocation is not confirmed, and a client that already knows a saved id may
still use it until the store revokes or expires it.
An initial refresh credential and its audit row share one PostgreSQL
transaction; failure rolls both back. Refresh rotation does not create a new
sign-in event. Audit rows contain account IDs, never passwords, bearer tokens
or authenticator secrets. The session store is separate: a later session or
response error can follow an audit commit.

For a cover replacement, object upload happens before the database transaction.
Old-object deletion and Redis invalidation happen after commit and can still
fail after the new article key and its `article.cover` audit row are stored.

## Add an authenticator before the next sign-in

A signed-in user sends their username and password to
`POST /v1/auth/2fa/enroll`. The JSON response contains `secret` and `uri`;
import the `otpauth://` URI into an authenticator, then send its `code` to
`POST /v1/auth/2fa/verify` using the cookie returned by enrollment. The account
requires a second factor only after that confirmation succeeds.

Both `/v1/auth/login` and `/v1/auth/token` then require the authenticator
code in `X-TOTP-Code`, with the usual `username` and `password` JSON body.
The password strategy keeps its strict credentials decoder. Each accepted code
can be used once. For example:

```sh
curl --fail-with-body http://127.0.0.1:8080/v1/auth/login \
  -H 'Content-Type: application/json' -H 'X-TOTP-Code: 123456' \
  -d '{"username":"ada","password":"your password"}'
```

Use a fresh authenticator code in place of `123456`. Attempts are
throttled; missing, invalid and reused codes issue neither an app session nor
a token. Google sign-in refuses accounts with TOTP enabled: use the password
and authenticator route. Confirmation revokes existing refresh tokens; already
issued short-lived access tokens keep their existing expiry.

Enrollment cannot replace a pending or enabled secret. Account recovery and
authenticator removal are separate future work. Store the secret as sensitive
account data, and serve provisioning only over HTTPS; the response is marked
`Cache-Control: no-store`.
