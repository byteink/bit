# Build an API with Bit

A course in eighteen parts. You build Inkwell, a small blogging API with
users, articles, tags and comments, using [`pkg/web`](../README.md). Every
part starts from a problem, adds one idea to solve it, and ends with a
`curl` command you can run against your own copy. By part 18 you have a
tested, configured service that starts from a single binary and talks to a
real PostgreSQL database.

The course is modeled on wanago.io's "API with NestJS" series: small,
verified steps rather than a wall of finished code. Each part links to the
next, and you can always jump back to this index. The finished app,
including its integration tests against real PostgreSQL, lives at
[`guides/inkwell/`](inkwell/) in this package's source - read it whenever
you want to see where a part's trimmed example is headed.

## Parts

1. [First endpoint](01-first-endpoint.md)
2. [Routing and route groups](02-routing-and-route-groups.md)
3. [Request bodies and validation](03-request-bodies-and-validation.md)
4. [Errors and consistent responses](04-errors-and-consistent-responses.md)
5. [Configuration](05-configuration.md)
6. [Connecting to PostgreSQL](06-connecting-to-postgresql.md)
7. [Tables and migrations with pkg/orm](07-tables-and-migrations-with-pkg-orm.md)
8. [Querying and CRUD](08-querying-and-crud.md)
9. [Relationships](09-relationships.md)
10. [Registering users and hashing passwords](10-registering-users-and-hashing-passwords.md)
11. [Sessions and logging in](11-sessions-and-logging-in.md)
12. [Authorization](12-authorization.md)
13. [Middleware: logging, CORS, security headers, rate limits](13-middleware.md)
14. [Pagination, filtering and sorting](14-pagination-filtering-and-sorting.md)
15. [Transactions](15-transactions.md)
16. [Testing the API](16-testing-the-api.md)
17. [Operations: health, graceful shutdown](17-operations.md)
18. [Shipping a single binary](18-shipping-a-single-binary.md)

Start with [part 1](01-first-endpoint.md).
