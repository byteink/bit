# Reuse an article until its representation changes

An Inkwell reader opens the same article twice. Sending the full article
again wastes a response body when the reader already has the current copy.
The detail route supplies an entity tag, and the next GET can ask whether
that copy still matches.

## Fetch once, then revalidate

Start the [finished app](README.md#run-the-finished-app), and use the id of
an article you created. The [next chapter](32-api-versioning.md) explains
why its routes now start with `/v1`.

```sh
curl -i http://127.0.0.1:8080/v1/articles/42
```

A successful response includes a quoted `ETag` and this cache policy:

```text
Cache-Control: private, max-age=0, must-revalidate
```

Copy the complete quoted tag into the next request. Replace the example
value below with the tag you received:

```sh
curl -i http://127.0.0.1:8080/v1/articles/42 \
  -H 'If-None-Match: "COPY_THE_RECEIVED_TAG_HERE"'
```

If the selected article representation is unchanged, the response is `304`
with no body. It repeats the same `ETag` and cache policy. Your client reuses
its stored body. A different tag produces `200` with the current article.

`private` lets a browser keep the response without permitting a shared proxy
cache to reuse it for other readers. `max-age=0, must-revalidate` requires
checking before reuse. This matters because even this public read can carry
a session cookie.

## Tag the complete view

The tag is a SHA-256 digest of the JSON for `ArticleView`, not just the
article's database revision. That view includes the author's username and
the article's tags. A related name changing must invalidate the stored
representation even when `Article.version` stays the same.

These complete helpers use the same view shape and response APIs as
[articles.bit](inkwell/articles.bit):

```bit
import { Ctx, Res } from "web"
import { Sha256, digest, encodeHex } from "std/crypto"
import { Json, JsonEntry, jsonEncode } from "std/json"
import { hasPrefix, split, trimSpace } from "std/strings"

@json class TagView { id: i64, name: string }

@json class ArticleView {
  id: i64,
  title: string,
  slug: string,
  body: string,
  authorId: i64,
  authorUsername: string,
  version: i64,
  tags: []TagView,
}

fn articleTag(view: ArticleView): string {
  let body = jsonEncode(view.toJson())
  return "\"" + encodeHex(digest(Sha256(), []byte(body))) + "\""
}

fn articleTagMatches(raw: string, tag: string): bool {
  if (trimSpace(raw) == "*") {
    return true
  }
  for part of split(raw, ",") {
    let candidate = trimSpace(part)
    if (hasPrefix(candidate, "W/")) {
      candidate = candidate[2:]
    }
    if (candidate == tag) {
      return true
    }
  }
  return false
}

fn articleHeaders(response: Res, tag: string): Res {
  return response.header("ETag", tag).header("Cache-Control", "private, max-age=0, must-revalidate")
}

fn conditionalArticle(c: Ctx, view: ArticleView): Res! {
  let tag = articleTag(view)
  if (articleTagMatches(c.header("If-None-Match"), tag)) {
    return articleHeaders(c.status(304), tag)
  }
  return articleHeaders(c.json(view), tag)
}
```

The real `showArticle` first parses the id, loads a visible article and builds
its view, then performs this comparison. A missing or soft-deleted article
returns `404`, even with `If-None-Match: *`; the wildcard cannot manufacture
a representation. A weak tag such as `W/"received-tag"`, or a comma-separated
list containing the current tag, also matches on this GET.

## Keep read validation separate from editing

[Optimistic locking](30-optimistic-locking.md) still uses the bare integer
`data.version` in PUT's `If-Match` header. Do not send the quoted read ETag
there: that handler requires an integer and rejects a quoted digest.

This conditional GET still loads the article and its related values to
calculate the current tag. It saves the response body when unchanged;
it does not avoid the database read. The [Redis list cache](26-caching-with-redis.md)
serves a different purpose and does not supply this detail-route validator.

The app does not enable response compression. If you later add the web
compression middleware, it weakens strong entity tags when it transforms
the response, so clients can still revalidate the representation they kept.

Previous: [Refuse an edit based on an old article](30-optimistic-locking.md).
Next: [Give the API a versioned address](32-api-versioning.md).
