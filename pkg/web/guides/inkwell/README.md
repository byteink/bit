# Inkwell

Inkwell is the running blogging application used by the web guides. It stores
accounts and articles in PostgreSQL, and shares Redis between sessions, cached
responses and background jobs. Apply this directory's migrations before starting
the application.

## Send a welcome email after registration

A slow mail relay should not hold an HTTP registration request open. With mail
enabled, `POST /v1/auth/register` saves the user, enqueues `SendWelcomeEmail` through
the existing jobs queue, and returns `201`. The application's existing worker
delivers a plain-text welcome message addressed to that saved user. The same
worker still runs the nightly article digest.

First configure the application's existing `DATABASE_URL`, `REDIS_URL`,
`APP_SECRET`, `JWT_SECRET`, `JWT_ISSUER` and `JWT_AUDIENCE` settings. With those
services and a development SMTP relay already running, start from this directory:

```sh
export SMTP_HOST=127.0.0.1
export SMTP_PORT=1025
export SMTP_FROM=welcome@example.test
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

Email verification and password-reset routes are not implemented here;
a welcome message does not verify the recipient's address.
