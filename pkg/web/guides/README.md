# Build an API with Bit

Part 4 of [the Bit Book](../../../docs/book/README.md). The Book's first
three parts build Inkwell, a notes tool that runs on your laptop: drafts you
write, search and back up, stored in files. This part takes Inkwell online -
it becomes a blogging API with users, articles, tags and comments, using
[`pkg/web`](../README.md), and a draft becomes an article anyone can fetch
over HTTP. You do not need to have built the earlier chapters to follow this
one; it starts a fresh project of its own.

Each chapter follows the same shape as the rest of the Book: it starts
from a problem, adds one idea to solve it, and ends with a `curl` command you can run against your own copy. By the end you have a tested,
configured service that starts from a single binary and talks to a real
PostgreSQL database - covered in [Shipping](../../../docs/book/33-shipping.md),
which closes out Part 5.

Each chapter links to the next, and you can always jump back to this index.
The finished app, including its integration tests against real PostgreSQL,
lives at [`guides/inkwell/`](inkwell/) in this package's source - read it
whenever you want to see where a chapter's trimmed example is headed.

## Run the finished app

Set `DATABASE_URL` to your PostgreSQL database, `REDIS_URL` to a dedicated
Redis 7 or newer instance, and `APP_SECRET` to the
session-cookie secret. Access tokens use a separate `JWT_SECRET` of at least
32 bytes, plus required `JWT_ISSUER` and `JWT_AUDIENCE` values. Choose an issuer
that identifies your deployment and an audience that identifies this API.
Missing token settings or a short signing key stop startup.

The finished app mounts its existing API, including health and readiness,
under `/v1`; the generated document stays at `/openapi.json`. Early chapters
contain smaller standalone programs with their own unprefixed routes. Use
those paths when running that chapter, and `/v1` when running `inkwell/`.
[API versioning](32-api-versioning.md) explains the shared route mounts.

The finished app uses [`pkg/auth` bearer tokens](../../auth/docs/bearer-tokens.md)
for login and refresh. Older access tokens without the required issuer,
audience and access-token header are rejected; sign in again to get a new one.

### Give an article a cover image

Keep images in an S3-compatible bucket instead of sending each download
through the API. Create a private bucket, then add these settings before
starting the finished app:

```sh
export S3_ENDPOINT="https://YOUR_STORAGE_ENDPOINT"
export S3_BUCKET="YOUR_PRIVATE_BUCKET"
export S3_ACCESS_KEY_ID="YOUR_ACCESS_KEY"
export S3_SECRET_KEY="YOUR_SECRET_KEY"
export S3_REGION="us-east-1"
```

Use your bucket's actual signing region. Without the storage settings, the
other API routes work; a cover request that needs storage returns `503`.
Apply the app's migrations before restarting it, as for every schema change.
The new nullable cover column keeps existing articles readable.

Sign in and create an article first. Replace `42` with its id and use your
session cookie jar. Its author or an administrator can attach one PNG,
JPEG or WebP file, up to 2 MiB:

```sh
curl -i -b cookies.txt -F 'cover=@cover.png;type=image/png' \
  http://127.0.0.1:8080/v1/articles/42/cover
```

A successful upload returns `204`. The app checks the image signature,
ignores the submitted filename, and stores the object under a random key.
A malformed form or over-limit file returns `400`; a request body above
2 MiB plus 4 KiB of form overhead returns `413`. An unsupported or mismatched
image type returns `415`. Another author gets `403`, and an unsigned
request gets `401`, before its body reaches storage.

Anyone who can read the public article can read its cover. Follow its
short-lived signed redirect to download the object, or ask storage for a
byte range:

```sh
curl -L -o downloaded.png http://127.0.0.1:8080/v1/articles/42/cover
curl -L -H 'Range: bytes=0-7' http://127.0.0.1:8080/v1/articles/42/cover
```

The signed URL expires after five minutes. Storage serves the bytes and
ranges directly; the API keeps no download buffer. Missing or deleted
articles, and articles without a cover, return `404`.

Replacing a cover writes a fresh key and updates the article with its
existing optimistic revision check; a concurrent edit returns `412`.
After a failed save, the app locks and reads the current article before
cleanup. It removes the new object only when that row proves the object is
unreferenced. A lost database response can follow a committed write: if the
row points to the new key, or its state cannot be read, the object stays and
the original cause reaches the app's error handler. HTTP responses still
hide internal details with the normal generic `500`. A failed compensation
also remains an error. After a successful database update, the app deletes the old object. If that deletion fails, the request reports
an error while the new database reference remains valid. Retry only after
checking the article's current cover. The integration gate runs this flow
against its own PostgreSQL, Redis and SeaweedFS containers.

## Chapters

14. [First endpoint](01-first-endpoint.md)
15. [Routing and route groups](02-routing-and-route-groups.md)
16. [Request bodies and validation](03-request-bodies-and-validation.md)
17. [Errors and consistent responses](04-errors-and-consistent-responses.md)
18. [Configuration](05-configuration.md)
19. [Connecting to PostgreSQL](06-connecting-to-postgresql.md)
20. [Tables and migrations with pkg/orm](07-tables-and-migrations-with-pkg-orm.md)
21. [Querying and CRUD](08-querying-and-crud.md)
22. [Relationships](09-relationships.md)
23. [Registering users and hashing passwords](10-registering-users-and-hashing-passwords.md)
24. [Sessions and logging in](11-sessions-and-logging-in.md)
25. [Authorization](12-authorization.md)
26. [Middleware: logging, CORS, security headers, rate limits](13-middleware.md)
27. [Pagination, filtering and sorting](14-pagination-filtering-and-sorting.md)
28. [Transactions](15-transactions.md)
29. [Testing the API](16-testing-the-api.md)
30. [Operations: health, graceful shutdown](17-operations.md)
31. [Add a cover image to an article](19-file-uploads.md)
32. [Read a cover without buffering the download](20-serving-and-streaming-files.md)
33. [Keep cover bytes in object storage](21-object-storage.md)
34. [Run a nightly article digest](25-scheduled-jobs.md)
35. [Cache article lists in Redis](26-caching-with-redis.md)
36. [Share sessions across servers](27-sessions-in-redis.md)
37. [Find articles by their words](28-full-text-search.md)
38. [Keep deleted articles recoverable](29-soft-deletes.md)
39. [Refuse an edit based on an old article](30-optimistic-locking.md)
40. [Reuse an article until its representation changes](31-conditional-client-caching.md)
41. [Give the API a versioned address](32-api-versioning.md)
42. [Generate the API document from its routes](33-generated-openapi.md)
43. [API tokens with JWT](34-api-tokens-with-jwt.md)
44. [Refresh tokens](35-refresh-tokens.md)
45. [Sign in with Google](36-sign-in-with-google.md)
46. [Idempotency keys: retry a write without doing it twice](40-idempotency-keys.md)

Idempotency closes this part by making the app's two creating routes safe
to retry. Part 5 starts with [Background jobs](../../../docs/book/31-background-jobs.md)
and ends with [Shipping](../../../docs/book/33-shipping.md), which covers
building and running the finished binary for the ink CLI and this server.

Start with [chapter 14](01-first-endpoint.md).
