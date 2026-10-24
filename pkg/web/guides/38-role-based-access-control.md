# Restrict administrative routes by role

<!-- doctest: deps auth orm -->

A signed-in author should be able to write articles without gaining access to
administrative routes. Inkwell already records a role at sign-in. Reuse that
session value to protect one administrative user lookup, before its handler
parses an id or asks PostgreSQL for a row.

Use the [finished app](README.md#run-the-finished-app), with its database,
Redis, migrations and required session and token settings. The route in this
chapter is already mounted at `GET /v1/admin/users/:id`.

## Read a public profile as an administrator

Use an existing administrator account provisioned through your deployment's
trusted account-management process. Registration creates authors; Inkwell
provides no HTTP endpoint for granting administrative roles. Use your account's
actual username and password, and replace `1` with an existing user's id:

```sh
curl --fail-with-body -c admin.cookies http://127.0.0.1:8080/v1/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"username":"existing-admin","password":"ADMIN_PASSWORD"}'
curl -i -b admin.cookies http://127.0.0.1:8080/v1/admin/users/1
```

Successful login returns `204` and saves the session cookie. The allowed lookup
returns `200` with the public `id`, `username` and `role` inside the app's normal
response envelope. It does not expose the account's email or password hash.

Keep this cookie jar separate from an author's jar. Session cookies are
credentials; protect them as you protect a password.

## Reuse the role check

The implementation comes from [`auth.bit`](inkwell/auth.bit). These imports
supply the names shared by the app's module; the constants and three functions
below match its existing source. The Bit block forms one module for the guide's
code checks.

```bit
import { Ctx, HttpError, forbidden } from "web"

const adminRole = "admin"
const sessionRoleKey = "inkwell:role"

export fn currentRole(c: Ctx): string! {
  return c.session()?.get(sessionRoleKey)
}

export fn requireRole(c: Ctx, roles: []string): ()! {
  let role = currentRole(c)?
  for allowed of roles {
    if (role != "" && role == allowed) {
      return
    }
  }
  fail forbidden("role required")
}

export fn requireAdmin(c: Ctx): ()! {
  requireRole(c, [adminRole]) catch e {
    let (http, ok) = e.(HttpError)
    if (ok && http.status() == 403) {
      fail forbidden("admin role required")
    }
    fail e
  }
}
```

`currentRole(c)` reads the value stored under `inkwell:role` in this session.
`requireRole(c, roles)` permits an exact, nonempty match from the supplied list.
`requireAdmin(c)` reuses that rule and keeps its established error detail,
`admin role required`.

Choose a list for the operation you are protecting. For example,
`requireRole(c, ["editor", "admin"])` accepts either of those exact strings;
it does not create either role or change an account. An empty list denies
every caller, including an administrator.

The helper's decisions are deliberate:

| Session role | Allowed roles | Result |
| --- | --- | --- |
| `admin` | `["admin"]` | Allowed |
| `author` | `["admin"]` | `403`, `role required` |
| Missing or empty | `["admin"]` | `403`, `role required` |
| `Admin` | `["admin"]` | `403`, `role required` |
| `admin` | `[]` | `403`, `role required` |
| Empty | `[""]` | `403`, `role required` |

Case matters: `Admin` and `administrator` do not match `admin`. A name in an
allow-list is not a pattern or a prefix.

## Understand where the session role comes from

[Sessions and logging in](11-sessions-and-logging-in.md) establishes the
password-login flow. The current `login` handler in
[`auth.bit`](inkwell/auth.bit) verifies credentials, regenerates the session,
and copies the verified identity's role into the app's own session key:

```text
fn login(c: Ctx, strategy: Strategy): Res! {
  let identity = strategy.authenticate(c)?
  let session = c.session()?
  session.regenerate()?
  session.set(sessionUserIdKey, identity.id)
  let role = jsonGet(identity.claims, "role")
  if (isSome(role)) {
    session.set(sessionRoleKey, jsonDecString(unwrap(role), "identity.claims.role")?)
  }
  return c.noContent()
}
```

This is an excerpt from the running app, where `Strategy` and the JSON helpers
are already imported. It shows which value authorizes the later request.
A client cannot obtain an administrative session by adding a role to the
registration JSON or by choosing a different cookie filename.

The [Google callback](36-sign-in-with-google.md#connect-the-callback-to-a-local-user)
also stores the bound local account's role in these same session keys. In both
flows the role is a snapshot taken at sign-in. Changing a database row does not
rewrite existing sessions or add a role lookup on each request. A new sign-in
reads the account again.

## Authorize before querying the user

[`mountUsers`](inkwell/users.bit) registers both the public lookup and the
administrative lookup. `main.bit` passes the existing `/v1` route group to this
function, so the paths below are relative to that group:

```text
export fn mountUsers(app: Routes, db: Db) {
  let group = app.group("/users")
  group.get("/:id", (c) => showUser(c, db))
  app.get("/admin/users/:id", (c) => {
    requireRole(c, [adminRole])?
    return showUser(c, db)
  })
}
```

`requireRole` runs before `showUser`. A forbidden caller receives `403` before
id parsing or any user query. This remains true even if the id is malformed or
the database connection is unavailable.

After authorization, the existing lookup keeps its normal errors:

```text
fn showUser(c: Ctx, db: Db): Res! {
  let id = parseId(c.param("id")) catch _ {
    fail badRequest("id must be an integer")
  }
  let u = findUserById(db, id) catch _ {
    fail notFound("no user with that id")
  }
  return c.json(toPublicUser(u))
}
```

An allowed caller with `not-an-id` gets `400`, `id must be an integer`. An
allowed caller requesting an unknown id gets `404`, `no user with that id`.
Authorization does not turn a forbidden request into a way to test whether an
account exists.

The result uses the same public shape as `GET /v1/users/:id`:

```text
export @json class PublicUser {
  id: i64,
  username: string,
  role: string,
}

export fn toPublicUser(u: User): PublicUser {
  return PublicUser{ id = u.id, username = u.username, role = u.role }
}
```

The administrative route protects access to this operation. Its response still
contains only `id`, `username` and `role`. Email, password hashes and tokens stay
out of the response.

## Check the denied requests

Sign in as an existing author using a separate cookie jar, then try the same
real route:

```sh
curl --fail-with-body -c author.cookies http://127.0.0.1:8080/v1/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"username":"existing-author","password":"AUTHOR_PASSWORD"}'
curl -i -b author.cookies http://127.0.0.1:8080/v1/admin/users/1
```

The author gets `403`, `role required`. An anonymous request also gets `403`:

```sh
curl -i http://127.0.0.1:8080/v1/admin/users/1
```

These commands exercise cookie-session authorization. A bearer access token
belongs to the [token-protected API](34-api-tokens-with-jwt.md); an
`Authorization` header does not populate this route's session role.

[`rbac.test.bit`](inkwell/rbac.test.bit) checks the real route and helper rules.
It covers admin access, exact role-list membership, empty and missing roles,
case mismatches, public serialization, invalid and unknown ids. A closed-database
control verifies that a denied caller cannot reach a user query.

## Keep ownership checks separate

A role check answers whether a role may perform an operation. An author editing
an article also needs to own that article. Allowing every `author` through
`requireRole` would not prove ownership.

Use the existing `requireOwnerOrAdmin(c, ownerId)` for those operations, as
[Authorization](12-authorization.md#guarding-an-articles-own-routes) describes.
It allows the resource's owner or an administrator and preserves the existing
`you may only modify your own resource` error for another author. Its missing
user-id path can return `401`; the role-only administrative lookup above returns
`403` for a missing role.

## Choose the right boundary

Use role-list checks for shared operations such as administrative lookup or
editorial tools. Keep ownership checks for a user's articles and comments.
Neither helper supplies immediate role revocation or a general permission engine.
Keep session expiry and logout in your authorization design.

The public user lookup remains public and uses the same serializer. Adding an
administrative route does not make private account fields suitable for a public
response.

Next: [Make a retry safe with an idempotency key](40-idempotency-keys.md).
Back to [Build an API with Bit](README.md#chapters).
