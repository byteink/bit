# Verify an email address and recover a password

Registration tells Inkwell which address an author submitted. It does not prove
that the author can read that mailbox. A forgotten password needs a similar
proof, but a link for one task must never authorize the other.

Use the finished app's existing verification and reset routes. Each accepts a
short-lived, single-use token delivered to the address already bound to the
account. The [welcome-email chapter](22-sending-email.md) sets up the worker
and development relay used here.

## Configure the pages that receive the links

Start with the [finished app's settings](README.md#run-the-finished-app),
PostgreSQL, Redis and the relay from the previous chapter. Configure trusted
pages before starting the worker:

```sh
cd pkg/web/guides/inkwell
export VERIFY_EMAIL_URL=http://localhost:8080/confirm
export RESET_PASSWORD_URL=http://localhost:8080/reset
bit migrate
bit run main.bit
```

These URL values describe pages that you supply. Inkwell does not serve a
confirmation or password-reset page at those paths. Your page reads the token
query parameter and asks the recipient to confirm or choose a new password.
Simply opening a link must not submit it: mail scanners may visit links before
the recipient does.

[`loadConfig`](inkwell/config.bit) reads the settings once. Both URLs use
`verifyLink` from the [auth package](../../auth/docs/email-verification.md):
HTTPS is required, except for HTTP localhost or loopback development pages.
A URL must have a host and no query, fragment or credentials. Use your own
configured address, never a request's `Host` header, to build a link.
Welcome mail requires `VERIFY_EMAIL_URL`; password-reset mail also requires
`RESET_PASSWORD_URL`. An unconfigured reset request fails with
`inkwell: password reset mail is not configured`.

## Confirm a newly registered author

With the worker running, register a fresh account:

```sh
curl --fail-with-body http://127.0.0.1:8080/v1/auth/register \
  -H 'Content-Type: application/json' \
  -d '{"username":"verified-author","email":"author@example.test","password":"development-password"}'
```

The response is `201`. Inspect the development relay for the welcome message
and its verification link. After the recipient chooses to confirm, submit
the link's token to the real API route, replacing the placeholder below:

```sh
curl --fail-with-body http://127.0.0.1:8080/v1/auth/verify-email \
  -H 'Content-Type: application/json' \
  -d '{"token":"TOKEN_FROM_THE_VERIFICATION_EMAIL"}'
```

A valid token returns `204`. Submitting it again returns `401` with
`invalid verification token`. Unknown, expired, wrong-purpose and
changed-address tokens have the same response. Verification checks the
account's current address before marking it verified; the token cannot
verify another account. A link expires after 24 hours.

Neither the registration response nor the public user representation contains
the usable token. Older welcome jobs without a link still send their original
welcome message; they do not acquire a new verification link later. A resend
route and the confirmation page are separate work, not part of this example.

## Keep token consumption and the account update together

The application's [`verifyEmail`](inkwell/auth.bit) uses this transaction:

```text
  db.tx((tx) => {
    inkwellVerification(tx, (_, _, _) => {})?.confirm(input.token)?
  })
```

The excerpt stops before the handler's error mapping. Its
`inkwellVerification` helper composes `EmailVerification` and `OneTimeTokens`
with the app's [`InkwellOneTimeTxStore`](inkwell/accounttokens.bit).
`EmailVerification` checks the token's purpose, expiry and current address.
The store atomically removes the matching token row. The verification callback
conditionally marks that same account and unchanged address.

These operations use the same PostgreSQL transaction. A store or account-update
failure rolls them back together; the handler does not report success after a
partial confirmation. The client sees `401` for an invalid token. Other store
errors remain errors and pass through the app's normal HTTP error handling.

The app stores only a SHA-256 token digest in PostgreSQL. Tokens come from the
auth package's cryptographic one-time-token generator, rather than a timestamp,
username or hand-built identifier. The purpose separates email verification
from password reset even though both use the same store.

## Request a password-reset link

Ask for a reset by email address. This endpoint does not require an existing
login session:

```sh
curl --fail-with-body http://127.0.0.1:8080/v1/auth/forgot-password \
  -H 'Content-Type: application/json' \
  -d '{"email":"author@example.test"}'
```

After enqueueing the job, the endpoint returns the same `204` for a known or
unknown account. The queue payload contains only the submitted email address.
The worker looks up the account; an unknown address sends no message. A known
account receives a usable reset link, replacing its previous reset link.
That link expires after one hour. A queue failure is still an error; `204`
does not mean that SMTP delivery has finished.

After choosing a replacement password on your reset page, submit the reset
token and password:

```sh
curl --fail-with-body http://127.0.0.1:8080/v1/auth/reset-password \
  -H 'Content-Type: application/json' \
  -d '{"token":"TOKEN_FROM_THE_RESET_EMAIL","password":"replacement-password"}'
```

Success returns `204`. An invalid, expired, used or changed-address token
returns `401` with `invalid password reset token`. A verification link cannot
be used here: the reset handler redeems only the `password-reset` purpose.

These are the complete body declarations from [auth.bit](inkwell/auth.bit),
with their validation import. Save them as `verification-inputs.bit` and run
`bit check verification-inputs.bit` to check the same input types:

```bit
import { minLen } from "web"

@json class VerifyEmailInput { token: string }

@json class ResetPasswordInput {
  token: string
  @minLen(8)
  password: string
}
```

The reset route decodes this body before consuming the token. The existing
eight-character password minimum therefore rejects a short replacement without
spending a valid reset link. The handler hashes the accepted password using
the auth package's `hashPassword`, rather than storing the submitted password.

Inside one PostgreSQL transaction it redeems the token, updates only the bound
account whose address still matches, revokes other reset links for that account
and revokes its refresh credentials. If any step fails, the transaction rolls
back. A non-token failure becomes `inkwell: password reset failed`, which the
normal HTTP error handler hides behind its generic server-error response.

Reset does not provide global logout. Existing cookie sessions keep their
current expiry and logout behavior. Already issued access JWTs remain usable
for their remaining lifetime, at most 900 seconds. New login attempts must use
the replacement password.

## Treat mail and its queue as bearer-link custody

A digest in PostgreSQL cannot itself be submitted as the token. The outgoing
message and the queued welcome payload in Redis necessarily contain the usable
verification link. Reset delivery also needs the usable link when the worker
sends it. Restrict access to mail, Redis and their backups; do not copy tokens
into public JSON or application logs. The app's mail wrapper keeps
relay-reflected token links out of worker failure messages.

Registration commits its account and verification digest before enqueueing
welcome mail. PostgreSQL and Redis do not share a transaction: enqueue failure
can leave the account and digest saved while the request reports an error.
Retrying registration can then return a conflict. Queue delivery can repeat,
and Redis durability determines whether pending mail survives a restart. This
example supplies neither a transactional outbox nor exactly-once delivery.

Use these flows when the existing trusted-page, worker and relay policies fit
your deployment. If your deployment needs global session revocation or stronger
delivery guarantees, implement and test those requirements separately instead
of treating a `204` response as that guarantee.

Previous: [Send a welcome email after registration](22-sending-email.md).
Continue with the existing [nightly article digest](25-scheduled-jobs.md), or
return to [Build an API with Bit](README.md).
