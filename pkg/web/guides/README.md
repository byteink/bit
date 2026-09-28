# Build an API with Bit

Part 4 of [the Bit Book](../../../docs/book/README.md). The Book's first
three parts build Inkwell, a notes tool that runs on your laptop: drafts you
write, search and back up, stored in files. This part takes Inkwell online -
it becomes a blogging API with users, articles, tags and comments, using
[`pkg/web`](../README.md), and a draft becomes an article anyone can fetch
over HTTP. You do not need to have built the earlier chapters to follow this
one; it starts a fresh project of its own.

Seventeen chapters, in the same shape as the rest of the Book: each one
starts from a problem, adds one idea to solve it, and ends with a `curl`
command you can run against your own copy. By the end you have a tested,
configured service that starts from a single binary and talks to a real
PostgreSQL database - covered in [Shipping](../../../docs/book/33-shipping.md),
which closes out Part 5.

Each chapter links to the next, and you can always jump back to this index.
The finished app, including its integration tests against real PostgreSQL,
lives at [`guides/inkwell/`](inkwell/) in this package's source - read it
whenever you want to see where a chapter's trimmed example is headed.

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

Part 4 ends there; [Shipping](../../../docs/book/33-shipping.md) covers
building and running the finished binary, for the ink CLI and this server
alike, as Part 5's close.

Start with [chapter 14](01-first-endpoint.md).
