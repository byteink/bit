# Share sessions across servers

A login should still work when a second Inkwell server receives the next
request. Store sessions in Redis so servers using the same `REDIS_URL` and
`APP_SECRET` share login state.

## Keep the browser's cookie

Start the [finished app](README.md#run-the-finished-app), register a user,
then keep the cookie returned by login:

```sh
curl -X POST http://localhost:8080/v1/auth/register \
  -H 'Content-Type: application/json' \
  -d '{"username":"writer","email":"writer@example.test","password":"correct horse battery"}'
curl -c /tmp/inkwell-cookies -X POST http://localhost:8080/v1/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"username":"writer","password":"correct horse battery"}'
curl -b /tmp/inkwell-cookies http://localhost:8080/v1/me
```

Run another app instance on a different `PORT` with the same database,
Redis and secrets. Send the same cookie to its `/v1/me` route. It returns the
same signed-in user. These requests exercise cookie sessions; the app's
separate `/v1/auth/token` routes issue bearer tokens.

## Give the app a shared store

The existing [main.bit](inkwell/main.bit) passes the adapter to the web
configuration. This excerpt belongs inside `buildAppFromDb`, where `cfg`
and `redis` are already available:

```text
  let app = App(
    Config{
      secret = cfg.secret, host = cfg.host, port = cfg.port, sessions = InkwellSessionStore(redis),
    },
  )
```

`InkwellSessionStore` implements the web package's `SessionStore` contract.
The browser receives an opaque session id, never the stored user or role
values. The app keeps those values in Redis. Login rotates the id; logout
destroys it.

The complete adapter is [redis-session.bit](inkwell/redis-session.bit).
Its `load` method returns the data, its version, and its revocation indexes.
`compareAndSet` accepts a write only at the version the caller read. A stale
writer receives `session compare-and-set conflict` instead of overwriting
a newer session. Rotation and destruction also update the Redis record in
one operation, so an old writer cannot bring a logged-out session back.

## Keep values small and check what comes back

A shared store reads values written by other processes. Check their shape
rather than treating every Redis string as a valid session. These exact
helpers come from the adapter; the Bit blocks on this page form one module.
They encode only string values and apply the same limits on writes and
reads:

```bit
import { Json, JsonEntry, jsonAsString } from "std/json"
import { jsonParse as sessionParse, jsonEncode as sessionEncode, jsonAsObject as sessionObject } from "std/json"

fn sessionMapWrite(values: map<string, string>, indexed: bool): string! {
  if (len(values) > 64) {
    fail newError("inkwell: session map exceeds 64 entries")
  }
  let entries = []JsonEntry(0)
  for (key, value) of values {
    if (indexed && (len(key) == 0 || len(value) == 0)) {
      fail newError("inkwell: session index key and value must be non-empty")
    }
    entries = append(entries, JsonEntry{ key = key, value = Json.JsonString(value) })
  }
  let encoded = sessionEncode(Json.JsonObject(entries))
  if (len(encoded) > 65536) {
    fail newError("inkwell: encoded session map exceeds 65536 bytes")
  }
  return encoded
}
```

The `indexed` map holds values used for bulk revocation. Its keys and values
must be nonempty. The helper rejects more than 64 entries or more than
65,536 encoded bytes before the adapter sends a write to Redis.

The matching reader checks the byte limit before parsing, then checks both
the object shape and each value:

```bit
fn sessionMapRead(encoded: string): map<string, string>! {
  if (len(encoded) > 65536) {
    fail newError("inkwell: Redis session map exceeds 65536 bytes")
  }
  let object = sessionObject(sessionParse(encoded)?)
  if (!isSome(object)) {
    fail newError("inkwell: Redis session map is not an object")
  }
  let entries = unwrap(object)
  if (len(entries) > 64) {
    fail newError("inkwell: Redis session map exceeds 64 entries")
  }
  let values = map<string, string>()
  for entry of entries {
    let value = jsonAsString(entry.value)
    if (!isSome(value)) {
      fail newError("inkwell: Redis session value is not a string")
    }
    values[entry.key] = unwrap(value)
  }
  return values
}
```

For example, an array in place of an object fails with
`inkwell: Redis session map is not an object`. A non-string member fails
with `inkwell: Redis session value is not a string`. Neither is treated as
a missing login.

## Revoke a session on either server

Use the same cookie against the second server to log out, then return to
the first server's `/v1/me` route. It no longer accepts that session:

```sh
curl -b /tmp/inkwell-cookies -X POST http://localhost:8081/v1/auth/logout
curl -b /tmp/inkwell-cookies http://localhost:8080/v1/me
```

The adapter keeps revocation markers so an earlier request cannot recreate
the destroyed session. It also supports revocation by subject while
preserving the session excluded from that operation. Expired sessions are
ignored on access and cleaned in bounded batches. Redis supplies the expiry
clock, so different app clocks do not extend a session's lifetime.

## Keep session storage durable

Use a dedicated Redis instance with persistence and
`maxmemory-policy noeviction`. Evicting or losing session records can discard
the revocation markers that protect logout. A Redis outage returns an error;
the app does not silently create an in-memory session.

This adapter accepts at most 10,000 active sessions and revocation markers
together. Reaching a limit fails explicitly rather than evicting another
user's protection. Use the simpler in-memory store only when a single
process and losing sessions on restart fit your application.

[redis-session.test.bit](inkwell/redis-session.test.bit) checks concurrent
writes, rotation, expiry and revocation. The app-level cross-server check
lives in [appredis.test.bit](inkwell/appredis.test.bit). For the cookie API,
see [Sessions and logging in](11-sessions-and-logging-in.md). Next,
[Find articles by their words](28-full-text-search.md).
