# bitlang.org/pkg/jobs

Background jobs: a worker pool, retries with exponential backoff and full
jitter, a dead-letter list, and no default queue backend — you supply a
`Store` (a PostgreSQL one is planned; see Status below).

**Status: not yet released.** `@job`'s dispatch name is a `static` method
(#6081/#6091), and `static` methods are behind the compiler flag
`BIT_STATIC_METHODS=1` (default off) until epic #6160 flips it. Building or
testing this package needs that flag exported; it is not tagged as a
release until the flag is gone.

```bit ignore
@job("send-welcome")
@json
class SendWelcome {
  userId: i64,
}

fn main(): ()! {
  let q = open(store, Options{ workers = 4 })?
  q.register<SendWelcome>((job: SendWelcome) => {
    // send the email
  })
  q.enqueue(SendWelcome{ userId = 1 })?
  q.run()?
}
```

Dispatch goes through the class, never a typed string:
`register<T: Job>`/`enqueue<T: Job>` read `T`'s stable `@job` name off a
generic bound, built entirely at runtime with no reflection and no
compiler-generated cross-module table (epic #4023's 2026-09-27 owner
decision).

## Left for follow-up tickets (epic #4023)

- A PostgreSQL `Store` (`SELECT ... FOR UPDATE SKIP LOCKED`) and its live
  Docker gate — #6082's Store trait and its two in-tree test doubles
  (`jobs.test.bit`) are done; the concrete driver is not yet in this
  package.
- Cron scheduling (#6083).
- A Redis `Store`, once pkg/redis 0.2 ships (#6013).

## Docs

See `jobs.bit` for `Queue`/`Options`, `store.bit` for the `Store` trait a
backend implements, and `backoff.bit` for the retry delay.
