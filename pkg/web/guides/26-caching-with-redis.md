# Cache article lists in Redis

Repeated visits to the same Inkwell article page should not repeat the same
database query. The list route keeps each page in Redis for 30 seconds and
invalidates it when an article changes.

## Read a page twice

Start the [finished app](README.md#run-the-finished-app), then request the
same list twice:

```sh
curl 'http://localhost:8080/articles?limit=10&page=1&sort=newest'
curl 'http://localhost:8080/articles?limit=10&page=1&sort=newest'
```

The first request queries PostgreSQL. The second returns the cached page
with the same data and pagination metadata. Search text, author, limit,
page and sort each contribute to the cache key. A different author or page
never reuses another query's cached body.

## Publish, edit and delete

Successful `POST /articles`, `PUT /articles/:id` and `DELETE /articles/:id`
advance the list-cache generation. The next list request uses the new
generation and queries PostgreSQL. A request already filling an older
generation cannot make that old page visible again after invalidation.

[articles.bit](inkwell/articles.bit) contains the read-through cache and the
three invalidation calls. Authorization still runs on every write. Cached
list pages contain only the same public article fields the uncached route
returns; sessions and identity data are never part of a cached page.

## Handle Redis failures

Redis errors fail the request. An invalidation error can occur after the
database committed a write: the caller receives an error even though the
article changed, and an older cached page can remain until its 30-second
TTL expires. This cache does not promise atomic commits across PostgreSQL
and Redis. Read the article detail route to inspect its current state;
use an idempotency key when retrying a publish request.

Direct database changes bypass route invalidation and can also remain
hidden by a cached list until its TTL expires. Do not use the cached list
as an authoritative ledger or as an authorization decision.

The integration checks in [appredis.test.bit](inkwell/appredis.test.bit)
prove cache hits, query separation and invalidation through all three write
routes. Next, [Share sessions across servers](27-sessions-in-redis.md).
