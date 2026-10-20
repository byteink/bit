# Share sessions across servers

A login should still work when a second Inkwell server receives the next
request. Inkwell stores sessions in Redis instead of a process-local map,
so servers using the same `REDIS_URL` and `APP_SECRET` share login state.

## Keep the browser's cookie

Start the [finished app](README.md#run-the-finished-app), register a user,
then keep the cookie returned by login:

```sh
curl -X POST http://localhost:8080/auth/register \
  -H 'Content-Type: application/json' \
  -d '{"username":"writer","email":"writer@example.test","password":"correct horse battery"}'
curl -c /tmp/inkwell-cookies -X POST http://localhost:8080/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"username":"writer","password":"correct horse battery"}'
curl -b /tmp/inkwell-cookies http://localhost:8080/me
```

Run another app instance on a different `PORT` with the same database,
Redis and secrets. Send the same cookie to its `/me` route. It returns the
same signed-in user. Logging out through either instance revokes that
session for both.

The browser receives an opaque session id, never the stored user or role
values. Login rotates the id. Concurrent updates compare versions; a stale
writer receives an error instead of overwriting a newer session or bringing
back a logged-out one. The adapter also supports revocation by subject and
preserves the session excluded from a bulk revocation.

## Keep session storage durable

Use a dedicated Redis instance with persistence and `maxmemory-policy
noeviction`. Evicting or losing session records can discard the revocation
markers that stop stale writers from reviving logged-out sessions. A Redis
outage propagates an error; the app does not silently create an in-memory
session or treat the outage as a missing login.

This guide's store accepts at most 10,000 active sessions and revocation
markers together. Each session's data and index maps hold at most 64
entries and 65,536 encoded bytes. Reaching a limit fails explicitly rather
than evicting another user's protection. Expired sessions are ignored on
access and cleaned in bounded batches.

[redis-session.bit](inkwell/redis-session.bit) implements the current
`SessionStore` contract; [redis-session.test.bit](inkwell/redis-session.test.bit)
checks concurrent writes, rotation, expiry and revocation. The app-level
cross-server check lives in [appredis.test.bit](inkwell/appredis.test.bit).
For a single-process experiment without durable sessions, see the
[session guide](11-sessions-and-logging-in.md). Next, [Find articles by their words](28-full-text-search.md).
