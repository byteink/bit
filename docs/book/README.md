# The Bit Book

You build Inkwell: a notes tool that starts as a program on your laptop and
ends as a web service with a database, background jobs and a release
pipeline. Every part adds one real thing Inkwell needs, and teaches the Bit
feature that thing needs along the way. By the end you have written a whole
working program, not read about one.

Each chapter is short and ends with something you can run. The real source
for Parts 1 to 3 lives at [`docs/book/ink/`](ink/): every code block in
those chapters is copied from those files, so it always compiles. Part 4's
source lives at [`pkg/web/guides/inkwell/`](../../pkg/web/guides/inkwell/).

Start with [chapter 1](01-hello-inkwell.md).

## Part 1: A notes tool on your laptop

Inkwell starts as a command you run in a terminal: it saves a note to a file
and finds it again later. No server, no database yet.

1. [Hello, Inkwell](01-hello-inkwell.md) - install check, `bit init`, run, build.
2. [Saving drafts](02-saving-drafts.md) - `ink new`, `ink list`: variables, functions, strings, files.
3. [What is a draft](03-what-is-a-draft.md) - the `Draft` class, the `Status` enum, `match`.
4. [When things go wrong](04-when-things-go-wrong.md) - errors, `!`, `?`, `catch`.
5. [Searching drafts](05-searching-drafts.md) - slices, maps, `for`, iterators, `std/regex`.
6. [Testing](06-testing.md) - `bit test`, test blocks, running tests.

## Part 2: Real data

Inkwell learns to read and write formats other programs use, and to keep
its drafts in a real database instead of one file per draft.

7. Settings file - `ink.toml` with `pkg/toml`, typed decoding.
8. Import and export - JSON and CSV.
9. Words and dates - word counts, reading time, time zones.
10. A real database - the `Store` interface, a SQL-backed store.

## Part 3: Doing many things at once

Inkwell indexes its drafts in parallel, watches for changes, and backs
itself up.

11. Indexing in parallel - `spawn`, channels, a worker pool.
12. Watching for changes - a long-running loop, timeouts, `select`, cancellation.
13. Backups - `std/compress`, `std/crypto`, `std/hash`.

## Part 4: Inkwell goes online

Your local Inkwell becomes a web service: drafts become articles, and
anyone can reach them over HTTP. This part is [Build an API with
Bit](../../pkg/web/guides/README.md), `pkg/web`'s own course - the app it
builds is named Inkwell too, on purpose: it is where Part 3's Inkwell ends
up.

14. [First endpoint](../../pkg/web/guides/01-first-endpoint.md)
15. [Routing and route groups](../../pkg/web/guides/02-routing-and-route-groups.md)
16. [Request bodies and validation](../../pkg/web/guides/03-request-bodies-and-validation.md)
17. [Errors and consistent responses](../../pkg/web/guides/04-errors-and-consistent-responses.md)
18. [Configuration](../../pkg/web/guides/05-configuration.md)
19. [Connecting to PostgreSQL](../../pkg/web/guides/06-connecting-to-postgresql.md)
20. [Tables and migrations with pkg/orm](../../pkg/web/guides/07-tables-and-migrations-with-pkg-orm.md)
21. [Querying and CRUD](../../pkg/web/guides/08-querying-and-crud.md)
22. [Relationships](../../pkg/web/guides/09-relationships.md)
23. [Registering users and hashing passwords](../../pkg/web/guides/10-registering-users-and-hashing-passwords.md)
24. [Sessions and logging in](../../pkg/web/guides/11-sessions-and-logging-in.md)
25. [Authorization](../../pkg/web/guides/12-authorization.md)
26. [Middleware](../../pkg/web/guides/13-middleware.md)
27. [Pagination, filtering and sorting](../../pkg/web/guides/14-pagination-filtering-and-sorting.md)
28. [Transactions](../../pkg/web/guides/15-transactions.md)
29. [Testing the API](../../pkg/web/guides/16-testing-the-api.md)
30. [Operations](../../pkg/web/guides/17-operations.md)

## Part 5: Running it for real

Inkwell is a real program now. The last part makes it fast, observable, and
easy to ship.

31. [Background jobs](31-background-jobs.md)
32. [Making it fast](32-making-it-fast.md)
33. [Shipping](33-shipping.md)

## Where things are defined

The Book teaches a concept once, at the moment Inkwell needs it, and links
to where it is defined for the full rules:

- [Language](/language) - every language construct, exact and short.
- [Standard library](/std) - what each `std/*` module is for.
- [Packages](/packages) - first-party packages like `pkg/web` and `pkg/toml`.
- [Tools](/tools) - the `bit` command: build, run, test, fmt, lint, add.

New to Bit? Start at [Get started](/get-started) before chapter 1: it
covers installing Bit, which this Book assumes is already done.
