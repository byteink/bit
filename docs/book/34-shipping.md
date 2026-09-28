# Shipping

<!-- doctest: per-block -->

Inkwell works, is fast enough, and is tested. What is left is turning it
into something you can hand to a server: one file, built once, with nothing
else to install alongside it. This chapter builds both halves of Inkwell -
the `ink` command line tool from Parts 1 through 3, and the web server from
Part 4 -
the same way, because `bit build` does not care which one it is pointed at.

## Building the binary

`bit build <dir>` builds the module rooted at `<dir>` and writes an
executable named after `bit.json`'s `"name"` field:

```text
$ bit build ink
$ file ink
ink: Mach-O 64-bit executable arm64
```

For the server, the same command, pointed at a different directory, and
cross-compiled for a machine that is not the one building it:

```text
$ bit build inkwell-server --target x86_64-linux -o inkwell-server
$ file inkwell-server
inkwell-server: ELF 64-bit LSB executable, x86-64, statically linked
```

`--target x86_64-linux` cross-compiles for a Linux container from any
machine, including the macOS laptop you have been developing on - nobody
needs a Linux machine to build the image that runs on one. `bit build`
supports `x86_64-linux`, `aarch64-linux`, `x86_64-macos`, `aarch64-macos`
and `x86_64-windows` as `--target` values; the [Tools](../tools/build-and-run.md)
page lists every one. The result is a static binary: no shared C library to
install beside it, no Bit runtime to install separately, nothing else in
its dependency chain to go missing inside a minimal container.

## A `FROM scratch` image

Because the binary is static, its container image needs nothing underneath
it - `scratch` is Docker's literal empty base, zero bytes, not even a shell:

```text
FROM scratch
COPY inkwell-server /inkwell-server
EXPOSE 8080
ENTRYPOINT ["/inkwell-server"]
```

```text
$ docker build -t inkwell-server:latest .
$ docker images inkwell-server
REPOSITORY        TAG       SIZE
inkwell-server    latest    <the binary's own size, nothing added>
```

There is no shell in the image to open and no package manager to patch -
the smallest attack surface an image can have, and the reason `scratch` is
worth reaching for instead of a general-purpose Linux base image. The
tradeoff is the one thing `scratch` cannot provide on its own: TLS root
certificates for outbound HTTPS calls, and time zone data, if the program
needs either. Inkwell's server needs neither today - it only serves plain
HTTP behind a load balancer that terminates TLS - but a program that calls
out to a third-party HTTPS API needs its certificate bundle copied in
alongside the binary.

## Configuration by environment

A container image is built once and run many times, against a different
database on every one of them - staging, production, a developer's own
throwaway copy. The server reads every setting it needs from the
environment exactly once, at startup:

```bit
import { env, envOr } from "std/os"
import { parseInt } from "std/strings"

export class ServerConfig {
  export databaseUrl: string,
  export secret: string,
  export host: string,
  export port: int,
}

fn mustEnv(name: string): string! {
  let v = env(name)
  if (len(v) == 0) {
    fail newError("${name} is not set - export it before starting the server")
  }
  return v
}

export fn loadServerConfig(): ServerConfig! {
  let databaseUrl = mustEnv("DATABASE_URL")?
  let secret = mustEnv("APP_SECRET")?
  let host = envOr("HOST", "127.0.0.1")
  let port = parseInt(envOr("PORT", "8080"))?
  return ServerConfig{ databaseUrl = databaseUrl, secret = secret, host = host, port = port }
}
```

`DATABASE_URL` and `APP_SECRET` fail loudly, naming the missing variable,
rather than starting a server whose secret is an empty string. `HOST` and
`PORT` fall back to sane local defaults, since only a real deployment needs
to override them. Nothing about the image itself changes between
environments - only the environment variables handed to `docker run` do:

```text
$ docker run -e DATABASE_URL=postgres://... -e APP_SECRET=$(openssl rand -hex 32) \
    -p 8080:8080 inkwell-server:latest
inkwell-server: applied 5 migration(s)
```

The `ink` command line tool ships the same way, without a container: copy
the one binary `bit build ink` produced onto any machine of the target
architecture and run it. It has no environment variables to set - it reads
and writes files under the user's own home directory, the same as it always
has.

## What we built

Both halves of Inkwell now ship as one file each: `ink`, the command line
tool from Parts 1 through 3, and the web server from Part 4, cross-compiled
for whatever machine runs them and, for the server, wrapped in an image with
nothing in it beyond that one file.

Previous: [Making it fast](33-making-it-fast.md). This closes [the Bit
Book](README.md).
