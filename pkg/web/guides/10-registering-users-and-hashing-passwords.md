# Registering users and hashing passwords

<!-- doctest: deps auth postgres orm -->

Every article and comment in Inkwell needs an author, and right now nothing
stops one reader from posting as someone else: there is no notion of "who is
calling" at all. This part adds a `users` table and a `POST /auth/register`
route. The hard rule for the whole chapter: a password is never stored as
text you could read back.

## Install pkg/auth

`pkg/auth` requires `pkg/web` `^0.9.0`, already satisfied since
[chapter 14](01-first-endpoint.md):

```text
$ bit add bitlang.org/pkg/auth@v0.5.0
bit add: auth -> bitlang.org/pkg/auth@0.5.0 (2b3da0ae7c8df96c4f5af1380d0160e291175655)
```

## Why you never store the plain password

If Inkwell's database ever leaks, and one day some database somewhere does,
every password stored in it leaks with it. Because people reuse passwords,
that one leak turns into break-ins on other sites too. The fix is to never
have the plain password to leak: you run it through a one-way function and
store only the result. "One-way" means there is no function that turns the
result back into the password; the only way to check a guess is to run the
same function on the guess and compare outputs.

A plain hash function like SHA-256 is not enough by itself, because it is
*fast*, and an attacker who steals your hash table can try billions of
guesses a second on ordinary hardware. Inkwell uses **Argon2id**, a hashing
algorithm built to be slow and memory-hungry on purpose, so a stolen table
costs an attacker meaningfully more than a normal login costs you. `pkg/auth`
ships it as one function:

```bit
import { hashPassword } from "auth"
import { Json } from "std/json"

fn onRegister(password: string): string {
  return hashPassword(password)
}
```

`hashPassword` also salts the password (mixes in random bytes before
hashing) so two users who pick the same password never produce the same
stored hash, which stops an attacker from pre-computing a table of common
passwords and their hashes once and reusing it against every account.

## The users table

A `User` is a `pkg/orm` table like `Article` from
[Querying and CRUD](08-querying-and-crud.md). `id` is the key because it is
a field literally named `id`; `@table("users")` overrides the snake_case
default (`user`) because chapter 7's migration already created the table
under that name. `passwordHash` is the one column that never leaves the
server.

```bit
import { Db } from "orm"

@table("users") @timestamps class User {
  id: i64,
  username: string,
  email: string,
  passwordHash: string,
  // "author" or "admin" - see chapter 25, Authorization.
  role: string,
  createdAt: i64,
  updatedAt: i64,
}
```

`PublicUser` is the shape Inkwell actually sends back over the wire. It has
no `passwordHash` field, so there is nothing to forget to strip before a
response goes out:

```bit
export @json class PublicUser {
  id: i64,
  username: string,
  role: string,
}

fn toPublicUser(u: User): PublicUser {
  return PublicUser{ id = u.id, username = u.username, role = u.role }
}
```

## Validating the request body

`RegisterInput` is what `POST /auth/register` reads. `@minLen` runs before
the handler body ever sees the value, so a username or password that is too
short never reaches your code:

```bit
import { minLen } from "web"

export @json class RegisterInput {
  @minLen(3)
  username: string

  email: string

  @minLen(8)
  password: string
}
```

A request whose `username` or `password` is too short gets a `422
Unprocessable Entity` naming the field, before a single byte reaches the
database.

## The register route

Every `POST` route in Inkwell that creates a row goes through
`db.table<T>().insert(...)` ([Querying and CRUD](08-querying-and-crud.md)):
it writes every column but `id` and hands back the row with the database's
own generated id filled in, so there is no separate "read the generated id
back" step to write by hand.

```bit
import { App, Ctx, Res, conflict } from "web"
import { UniqueViolation, classify } from "orm"

fn register(c: Ctx, db: Db): Res! {
  let input = c.body<RegisterInput>()?
  let u = User{
    id = 0, username = input.username, email = input.email,
    passwordHash = hashPassword(input.password), role = "author", createdAt = 0, updatedAt = 0,
  }
  let saved = insertUser(db, u)?
  return c.created("${saved.id}").header("Location", "/users/${saved.id}")
}

fn insertUser(db: Db, u: User): User! {
  return db.table<User>().insert(u) catch e {
    let cause = classify(e, "users")
    let (_, ok) = cause.(UniqueViolation)
    if (ok) {
      fail conflict("that username or email is already registered")
    }
    fail cause
  }
}

export fn mountAuth(app: App, db: Db) {
  app.post("/auth/register", (c) => register(c, db))
}
```

`c.created(id)` answers `201 Created` with a `Location` header built from the
route that matched, and `classify` turns a duplicate `username`/`email` from
Postgres's own unique constraint into a `409 Conflict` your caller can act
on, rather than a raw database error.

## Try it

With Inkwell running against a real PostgreSQL:

```
$ curl -si -X POST http://127.0.0.1:8089/auth/register \
    -H 'Content-Type: application/json' \
    -d '{"username":"ada","email":"ada@example.test","password":"correct horse battery"}'
```

```
HTTP/1.1 201 Created
Content-Length: 0
Content-Type: text/plain; charset=utf-8
Location: /users/1
```

`c.created(id)` answers with no body: the `Location` header already says where the
new user lives, and there is nothing else a client needs back from a
registration. Registering the same username again is refused:

```
$ curl -si -X POST http://127.0.0.1:8089/auth/register \
    -H 'Content-Type: application/json' \
    -d '{"username":"ada","email":"ada2@example.test","password":"another password"}'
```

```
HTTP/1.1 409 Conflict
Content-Type: application/json

{"error":{"code":"conflict","message":"Conflict","detail":"that username or email is already registered"}}
```

And a password under 8 characters never reaches the database:

```
$ curl -si -X POST http://127.0.0.1:8089/auth/register \
    -H 'Content-Type: application/json' \
    -d '{"username":"grace","email":"grace@example.test","password":"short"}'
```

```
HTTP/1.1 422 Unprocessable Content
Content-Type: application/json

{"error":{"code":"unprocessable_entity","message":"password: must be at least 8 character(s)"}}
```

(Every response above also carries Inkwell's own security and rate-limit
headers, [chapter 26](13-middleware.md)'s subject; they are trimmed here to
keep the point visible.)

## What we built

A `users` table, a `PublicUser` shape that can never leak a password hash,
and a `POST /auth/register` route that hashes with Argon2id, validates the
body before touching the database, and turns a duplicate username or email
into a `409` a client can show to the user. Nobody can log in yet: that is
[chapter 24](11-sessions-and-logging-in.md).

Previous: [Relationships](09-relationships.md).
Next: [Sessions and logging in](11-sessions-and-logging-in.md).
