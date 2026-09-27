# Shipping a single binary

Inkwell now has routes, migrations, sessions, middleware, tests and a clean
shutdown. What is left is turning it into something you can actually run
somewhere else: one file, built once, with nothing to install alongside it
- and a container image with nothing in it beyond that one file.

<!-- doctest: per-block -->

## Building the binary

[Ship a single binary](../../../docs/guides/ship-a-single-binary.md) covers
`bit build` in full; this is the one command Inkwell's own image runs.
`bit build <dir>` builds the module rooted at `<dir>` and writes an
executable named after `bit.json`'s `"name"` field:

```
$ bit build pkg/web/guides/inkwell --target x86_64-linux -o inkwell
$ file inkwell
inkwell: ELF 64-bit LSB executable, x86-64, statically linked
```

`--target x86_64-linux` cross-compiles for a Linux container from any
machine, macOS included - nobody needs a Linux box to build the image that
runs on one. The result is a static binary: no `libc.so`, no `bit` runtime
to install beside it, nothing else in its dependency chain to go missing
inside a minimal container.

## A `FROM scratch` image

Because the binary is static, the image needs nothing underneath it -
`scratch` is Docker's literal empty base, zero bytes, not even a shell:

```
FROM scratch
COPY inkwell /inkwell
EXPOSE 8080
ENTRYPOINT ["/inkwell"]
```

```
$ docker build -t inkwell:latest .
$ docker images inkwell
REPOSITORY   TAG       SIZE
inkwell      latest    <the binary's own size, nothing added>
```

There is no shell in the image to `docker exec` into and no package
manager to patch - the smallest possible attack surface, and the whole
reason `scratch` is worth reaching for instead of a slim Linux base image.
The tradeoff is the one thing `scratch` cannot provide on its own: TLS root
certificates for outbound HTTPS calls, and time zone data, if the program
needs either. Inkwell needs neither today - it only serves plain HTTP
behind a load balancer that terminates TLS - but a program that calls out
to a third-party HTTPS API needs its CA bundle copied in alongside the
binary.

## Configuration by environment

A container image is built once and run many times, against a different
database on every one of them - staging, production, a developer's own
throwaway instance. Inkwell reads every setting it needs from the
environment exactly once, at startup, the way [Configuration](../docs/configuration.md)
already established for `pkg/web`'s own `Config`:

```bit
import { env, envOr } from "std/os"
import { parseInt } from "std/strings"

export class AppConfig {
  export databaseUrl: string,
  export secret: string,
  export host: string,
  export port: int,
}

fn mustEnv(name: string): string! {
  let v = env(name)
  if (len(v) == 0) {
    fail newError("${name} is not set - export it before starting the app")
  }
  return v
}

export fn loadConfig(): AppConfig! {
  let databaseUrl = mustEnv("DATABASE_URL")?
  let secret = mustEnv("APP_SECRET")?
  let host = envOr("HOST", "127.0.0.1")
  let port = parseInt(envOr("PORT", "8080"))?
  return AppConfig{ databaseUrl = databaseUrl, secret = secret, host = host, port = port }
}
```

`DATABASE_URL` and `APP_SECRET` fail loudly, naming the missing variable,
rather than starting an app whose secret is `""`. `HOST` and `PORT` fall
back to sane local defaults, since only a real deployment needs to override
them:

```
$ docker run -e DATABASE_URL=postgres://... -e APP_SECRET=$(openssl rand -hex 32) \
    -p 8080:8080 inkwell:latest
inkwell: applied 5 migration(s)
```

Nothing about the image itself changes between environments - only the
environment variables handed to `docker run` do.

## Where these numbers come from

`pkg/web` publishes a benchmark comparing it against gin, express, bun,
Spring Boot and ASP.NET Core on plaintext and JSON, at
[`pkg/web/bench/RESULTS.md`](../bench/RESULTS.md). Every number in that
file is generated, never hand-edited, by
[`pkg/web/bench/run.sh`](../bench/run.sh): one warmup rep plus five
rotated, round-robin reps per framework, medians taken from the middle
three, both frameworks' response bodies proven byte-identical before
anything is timed, and the load generator's own CPU headroom checked so no
row is quietly bound by the tool measuring it rather than the server being
measured. The table in that file always names the exact Bit commit and
toolchain version it was generated from - read the number there, at its own
commit, rather than repeating one here that will be stale by the next
release.

## What we built

Eighteen parts in, Inkwell is a blogging API with users, articles, tags and
comments, sessions, authorization, pagination, transactions, tests against
a real database, health and readiness routes, a clean shutdown on
`SIGTERM`/`SIGINT`, and now a single static binary you can hand to any
`x86_64-linux` machine, or wrap in an image with nothing else in it.

## Where to go next

This closes season 1. Season 2 picks up the features a production API
needs beyond CRUD and auth: file uploads and object storage, sending
email, background and scheduled jobs, caching and sessions in Redis, and
full-text search. Season 3 covers real-time and scale - WebSockets,
concurrency, connection pooling, multi-tenancy. Season 4 covers running it
for real - structured logging, tracing, metrics, migrations in production,
Kubernetes and zero-downtime deploys.

[Getting started](../docs/getting-started.md) is the doorway back into the
reference docs for any one piece covered along the way; the [pkg/web
README](../README.md) is the map of everything the package ships.

Previous: [Operations](17-operations.md).
