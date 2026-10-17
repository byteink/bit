# Refuse an edit based on an old article

<!-- doctest: per-block -->
<!-- doctest: deps orm postgres -->

Two authors open the same article. One saves a correction; the other saves
an older copy and erases it. Inkwell's update route requires a version in
`If-Match` so a stale edit fails instead of silently replacing newer work.

## What the current route accepts

`PUT /articles/:id` takes the session of the author or an admin, a JSON body,
and a bare integer `If-Match` value. This is the complete request-body type
from [`articles.bit`](inkwell/articles.bit):

```bit
import { Json, JsonEntry } from "std/json"

export @json class UpdateArticleInput {
  title: string,
  body: string,
}
```

The `Article` model has one `@version` field, `version: i64`. The
[migration in the previous chapter](29-soft-deletes.md#store-a-nullable-deletion-time)
adds its database column. `insertArticle` initializes a new article to version
`0`, and each successful repository update writes the next integer.

## Compare and change in one statement

The repository uses the version supplied by the caller in the UPDATE's
condition and writes that value plus one in the same statement. Only the
request whose old version still matches can change the row. A prior read
followed by an unconditional update would leave the race open.

Here is the complete `updateArticle` handler from
[`articles.bit`](inkwell/articles.bit). It uses the app's existing lookup,
authorization and view helpers, so this excerpt is shown as text:

```text
fn updateArticle(c: Ctx, db: Db): Res! {
  let id = parseId(c.param("id")) catch _ {
    fail badRequest("id must be an integer")
  }
  let existing = findArticleById(db, id) catch _ {
    fail notFound("no article with that id")
  }
  requireOwnerOrAdmin(c, existing.authorId)?
  let input = c.body<UpdateArticleInput>()?
  let ifMatch = c.header("If-Match")
  if (len(ifMatch) == 0) {
    fail badRequest("If-Match header is required")
  }
  let expectedVersion = parseInt(ifMatch) catch _ {
    fail badRequest("If-Match must be an integer version")
  }
  existing.title = input.title
  existing.body = input.body
  existing.updatedAt = now().ns
  existing.version = expectedVersion
  db.table<Article>().update(existing) catch e {
    let (_, stale) = e.(StaleWriteError)
    if (stale) {
      fail httpError(412, "the article changed since you last read it; reload and retry")
    }
    fail e
  }
  let refreshed = findArticleById(db, id)?
  return c.json(toArticleView(refreshed))
}
```

The handler sets `existing.version` to the client's value before calling
`update`. Using only the version it just loaded from the database would
protect the brief server-side race but miss edits made since the client
first opened the article.

`StaleWriteError` becomes HTTP `412` with the message
`the article changed since you last read it; reload and retry`. Other database
errors propagate. The route keeps its ownership check before any write.
The successful response reloads the article so it returns the saved content
and its new `version`. The public `GET /articles/:id` response also includes
that integer in `data.version`, alongside the existing article fields.

The ORM's [locking guide](../../orm/docs/locking.md) describes the version
check and the separate row-lock option.

## Exercise the stale and fresh cases

The test helper below is copied from
[`app.test.bit`](inkwell/app.test.bit). It sends a real request through the
same app dispatcher that serves HTTP:

```bit
import { App } from "web"
import { Request, Response } from "std/http"

fn putWithIfMatch(app: App, cookie: string, id: string, title: string, ifMatch: string): Response {
  let headers = "Content-Type: application/json\r\nCookie: ${cookie}\r\nIf-Match: ${ifMatch}"
  let body = "{\"title\":\"${title}\",\"body\":\"y\"}"
  return app.handle(
    Request{ method = "PUT", path = "/articles/${id}", headers = headers, body = body },
  )
}
```

The test named `PUT /articles/:id with a stale If-Match returns 412, and a fresh one succeeds`
creates a new article, submits version `99`, and checks for `412`. It then
submits that article's initial version, `0`, and checks for `200` and the saved
title. The test knows `0` from the insertion path; it does not discover it
through the article response. The test named `article responses supply the revision for an update, conflict, reload and retry`
uses `data.version` instead: it reads, updates, rejects the old revision,
reloads the saved article, and retries with the returned revision.

Fetch the article before editing it. Copy the integer from `data.version`
into `If-Match`, without quotes. Replace the id and session cookie with your own:

```text
curl -s http://127.0.0.1:8080/articles/42
# Read data.version from the response; this example receives 3.

curl -i -X PUT http://127.0.0.1:8080/articles/42 \
  -H 'Cookie: sid=YOUR_SESSION_COOKIE' \
  -H 'Content-Type: application/json' \
  -H 'If-Match: 3' \
  -d '{"title":"A corrected title","body":"The saved body."}'
```

The successful response returns version `4`. Another edit using `If-Match: 3`
fails with `412`.

Run the app tests against the migrated PostgreSQL database from
[Testing the API](16-testing-the-api.md):

```text
bit test pkg/web/guides/inkwell
```

## Reload before a retry

On `412`, fetch `GET /articles/:id` again. Show the current content so the
author can reconcile their edit, then submit the new `data.version` in
`If-Match`. A successful update returns the saved content and its next
version, which the editor can use for its next edit.

Do not guess an existing article's version or retry a stale edit blindly.
Reloading supplies the current revision; the author still decides how to
combine their changes with the newer content.

## Sharp edges

A missing header fails with `If-Match header is required`. A value that does
not parse as an integer fails with `If-Match must be an integer version`.
Both produce `400`. A missing or soft-deleted article produces `404` during
the initial lookup.

This handler accepts a bare integer. It does not implement quoted entity
tags, multiple validators or `If-Match: *`. The version check covers this
repository update; it does not make arbitrary raw SQL or related-row changes
part of the same revision policy.

Use optimistic checks for edits that can pause while a user reads or types.
When several database rows must change together, use a
[transaction](15-transactions.md); a single article version does not replace it.

Previous: [Keep deleted articles recoverable](29-soft-deletes.md).
Next: [API tokens with JWT](34-api-tokens-with-jwt.md).
