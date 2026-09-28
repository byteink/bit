# Authorization

<!-- doctest: deps auth postgres orm -->

Inkwell now knows *who* is calling, but not what they are allowed to do: any
logged-in user can edit or delete any article, including someone else's, and
anyone can invent a new tag. This part adds two rules: an author may only
change their own articles, and creating a tag is admin-only.

Authentication answers "who is this". Authorization answers "what may they
do", and it is a different question: `currentUserId` from
[chapter 24](11-sessions-and-logging-in.md) already answers the first one on
every request. This chapter is only ever about the second.

## The role a user carries

[Chapter 23](10-registering-users-and-hashing-passwords.md)'s `User` has a
`role` column, `"author"` or `"admin"`. Login (chapter 24) puts that role on
the session as a claim, right alongside the user's id, so a protected route
can read it back with no second database query:

```bit
import { Ctx, forbidden, unauthorized } from "web"
import { parseInt } from "std/strings"

const adminRole = "admin"
const sessionUserIdKey = "inkwell:userId"
const sessionRoleKey = "inkwell:role"

fn currentUserId(c: Ctx): i64! {
  let raw = c.session()?.get(sessionUserIdKey)
  if (len(raw) == 0) {
    fail unauthorized()
  }
  return parseInt(raw)?
}

fn currentRole(c: Ctx): string! {
  return c.session()?.get(sessionRoleKey)
}
```

## Two rules, two small functions

Every authorization check in Inkwell is one of these two shapes, so they are
written once and reused everywhere they apply.

**Owner or admin**: the caller is the resource's own author, or has the
admin role. Used on updating and deleting an article, and on deleting a
comment.

```bit
fn requireOwnerOrAdmin(c: Ctx, ownerId: i64): ()! {
  let uid = currentUserId(c)?
  if (uid == ownerId) {
    return
  }
  let role = currentRole(c)?
  if (role != adminRole) {
    fail forbidden("you may only modify your own resource")
  }
}
```

**Admin only**: no ownership check at all, because the resource has no
single owner. Used on creating a tag, since the tag list is shared,
editorial vocabulary, not any one author's property.

```bit
fn requireAdmin(c: Ctx): ()! {
  let role = currentRole(c)?
  if (role != adminRole) {
    fail forbidden("admin role required")
  }
}
```

Both fail with `forbidden()`, `403 Forbidden`, never `401`: the caller is
authenticated (`currentUserId`/`currentRole` already proved that, or the
request would have failed earlier), the problem is what they are allowed to
do, not who they are.

## Guarding an article's own routes

```bit
import { Res, badRequest, notFound } from "web"
import { Data } from "orm"
import { Value, sqlReqInt } from "std/sql"
import { Json, JsonEntry } from "std/json"

@json class UpdateArticleInput {
  title: string,
  body: string,
}

@json class ArticleView {
  id: i64,
  title: string,
  body: string,
  authorId: i64,
}

fn findArticleAuthorId(db: Data, id: i64): i64! {
  let rows = db.query("select author_id from articles where id = $1", [Value.Int(id)])?
  defer rows.close()
  if (!rows.next()?) {
    fail notFound("no article with that id")
  }
  return sqlReqInt(rows, rows.columns(), "author_id")?
}

fn updateArticle(c: Ctx, db: Data): Res! {
  let id = parseInt(c.param("id")) catch _ {
    fail badRequest("id must be an integer")
  }
  let authorId = findArticleAuthorId(db, id)?
  requireOwnerOrAdmin(c, authorId)?
  let input = c.body<UpdateArticleInput>()?
  db.exec(
    "update articles set title = $1, body = $2 where id = $3",
    [Value.Text(input.title), Value.Text(input.body), Value.Int(id)],
  )?
  return c.json(ArticleView{ id = id, title = input.title, body = input.body, authorId = authorId })
}
```

The shape repeats for `DELETE /articles/:id` and for `DELETE
/comments/:id`: load enough of the row to know its owner, then call
`requireOwnerOrAdmin` before touching anything, never after. A check run
after the write is not a check, it is an audit log.

## Guarding tag creation

```bit
import { App } from "web"

@json class CreateTagInput {
  name: string,
}

fn createTag(c: Ctx, db: Data): Res! {
  requireAdmin(c)?
  let input = c.body<CreateTagInput>()?
  let rows = db.query("insert into tags (name) values ($1) returning id", [Value.Text(input.name)])?
  defer rows.close()
  rows.next()?
  let newId = sqlReqInt(rows, rows.columns(), "id")?
  return c.created("${newId}")
}

export fn mountTags(app: App, db: Data) {
  app.post("/tags", (c) => createTag(c, db))
}
```

`c.body<CreateTagInput>()` still runs before `requireAdmin`'s failure would
be reached if the two were swapped, so the order above matters: check who is
allowed, before spending any work on what they sent.

## Try it

Register two users (chapter 23) and log each in (chapter 24) into its own cookie
jar. `owner` posts an article; `intruder` tries to edit it:

```
$ curl -si -b intruder-cookies.txt -X PUT http://127.0.0.1:8089/articles/1 \
    -H 'Content-Type: application/json' \
    -d '{"title":"hijacked","body":"x"}'
```

```
HTTP/1.1 403 Forbidden
Content-Type: application/json

{"error":{"code":"forbidden","message":"Forbidden","detail":"you may only modify your own resource"}}
```

The article's own author can:

```
$ curl -si -b owner-cookies.txt -X PUT http://127.0.0.1:8089/articles/1 \
    -H 'Content-Type: application/json' \
    -d '{"title":"edited","body":"y"}'
```

```
HTTP/1.1 200 OK
Content-Type: application/json

{"data":{"id":1,"title":"edited","slug":"hello-inkwell-a1b2c3d4","body":"y","authorId":1,"authorUsername":"owner","tags":[]}}
```

A plain author cannot create a tag:

```
$ curl -si -b owner-cookies.txt -X POST http://127.0.0.1:8089/tags \
    -H 'Content-Type: application/json' \
    -d '{"name":"bit"}'
```

```
HTTP/1.1 403 Forbidden
Content-Type: application/json

{"error":{"code":"forbidden","message":"Forbidden","detail":"admin role required"}}
```

Inkwell has no route that grants the admin role; a real deployment sets it
during onboarding or through a separate internal tool. For this last check,
promote `owner` directly in the database:

```
$ docker exec inkwell-postgres psql -U postgres -d inkwell \
    -c "update users set role = 'admin' where username = 'owner'"
```

Log `owner` in again so the new role lands on a fresh session, then:

```
$ curl -si -b owner-cookies.txt -X POST http://127.0.0.1:8089/tags \
    -H 'Content-Type: application/json' \
    -d '{"name":"bit"}'
```

```
HTTP/1.1 201 Created
Content-Length: 0
Content-Type: text/plain; charset=utf-8
Location: /tags/1
```

(Every response above also carries Inkwell's own security and rate-limit
headers, [chapter 26](13-middleware.md)'s subject; they are trimmed here to
keep the point visible.)

## What we built

Two small, reusable checks, `requireOwnerOrAdmin` and `requireAdmin`, both
reading the role chapter 24's login already put on the session, both failing
`403` before a handler does any work it should not have done. Every route
that changes an article, a comment, or the tag list in Inkwell now calls one
of them. Next, this part turns to the middleware every route in the app
shares: logging, CORS, security headers, and rate limits.

Previous: [Sessions and logging in](11-sessions-and-logging-in.md).
Next: [Middleware: logging, CORS, security headers, rate limits](13-middleware.md).
