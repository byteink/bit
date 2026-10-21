# Cache article lists in Redis

Repeated visits to the same Inkwell article page should not repeat the same
database query. Keep each page in Redis for 30 seconds, then change its cache
key when an article changes.

<!-- doctest: deps redis -->

## Read a page twice

Start the [finished app](README.md#run-the-finished-app), then request the
same list twice:

```sh
curl 'http://localhost:8080/v1/articles?limit=10&page=1&sort=newest'
curl 'http://localhost:8080/v1/articles?limit=10&page=1&sort=newest'
```

The first request queries PostgreSQL. The second returns the cached page
with the same data and pagination metadata. Change `page=1` to `page=2`;
that request must get a different page rather than reusing the first body.

## Give each query its own key

A key must distinguish every query setting that changes the response.
These imports, constants and helper come from
[articles.bit](inkwell/articles.bit). The Bit blocks on this page form one
module.

```bit
import { Ctx } from "web"
import { Client as RedisClient } from "redis"
import { join } from "std/strings"
import { Sha256 as CacheSha256, digest as cacheDigest, encodeHex as cacheHex } from "std/crypto"

const articleCacheGeneration = "{inkwell:articles}:generation"

fn articleCacheKey(c: Ctx, generation: i64): string {
  let fields = []string(0)
  for name of ["q", "author", "limit", "page", "sort"] {
    let value = c.query(name)
    fields = append(fields, "${len(value)}:${value}")
  }
  let hash = cacheHex(cacheDigest(CacheSha256(), []byte(join(fields, "|"))))
  return "{inkwell:articles}:${generation}:${hash}"
}
```

Search text, author, limit, page and sort each contribute to the key. The
length before each value keeps a separator inside a query value from
making two different lists of fields look identical. The generation names
the current version of the article list.

## Fill a missing page and set its lifetime

The existing `cachedArticles` handler first reads the generation and asks
Redis for that key. A hit becomes the JSON response. A miss runs the normal
`listArticles` handler, encodes its result, and stores it with a lifetime.

This is the complete handler from `articles.bit`, shown as an excerpt
because it uses that file's `listArticles`, response wrapper and imports:

```text
fn cachedArticles(c: Ctx, db: Db, redis: RedisClient): Res! {
  let generation = redis.counter(articleCacheGeneration).get()?
  let key = articleCacheKey(c, generation)
  match (redis.get(key)?) {
    Some(body) => return c.json(CachedArticlePage{ value = cacheJsonParse(body)? })
    None => {}
  }
  let result = listArticles(c, db)?
  let body = [""]
  result.mapValue((value) => {
    body[0] = cacheJsonEncode(value)
    return value
  })
  if (!redis.set(key, body[0], ttl = articleCacheTtl)?) {
    fail newError("inkwell: article cache write was refused")
  }
  return result
}
```

The same file sets `articleCacheTtl` to `30 * CacheSecond`. A failed write
returns `inkwell: article cache write was refused`; it is not reported as
a successful cache fill. Cached pages contain only the public article
fields returned by the normal list route. Session IDs, credentials and
per-viewer authentication data are never part of a cached page.

## Make a write start a new generation

Deleting a key is not enough: a request already querying PostgreSQL could
write an old result after that deletion. Inkwell advances the generation
instead. Its helper is small:

```bit
fn invalidateArticles(redis: RedisClient): ()! {
  redis.counter(articleCacheGeneration).incr()?
}
```

Successful `POST /v1/articles`, `PUT /v1/articles/:id` and `DELETE /v1/articles/:id`
call this helper after changing the database. The next list request reads
the new generation and queries PostgreSQL. A request already filling an
older generation can finish, but later requests will not use its old key.
Its 30-second lifetime releases that entry without a full key scan.

Try reading a list, publishing an article, then reading the same list again.
The new article appears without waiting for the old page's lifetime to end.
Authorization still runs on every write. The app's
[appredis.test.bit](inkwell/appredis.test.bit) checks hits, query separation
and invalidation through all three write routes.

## Handle Redis failures

Redis errors fail the request. An invalidation error can occur after the
database committed a write: the caller receives an error even though the
article changed. An older cached page can remain until its 30-second
lifetime ends. PostgreSQL and Redis do not commit these changes together.
Read the article detail route to inspect its current state. Use an
idempotency key when retrying a publish request.

Direct database changes also bypass route invalidation. Do not use a cached
list as an authoritative ledger or as an authorization decision. Keep a
query uncached when every response must reflect the latest committed row.
Next, [Share sessions across servers](27-sessions-in-redis.md).
