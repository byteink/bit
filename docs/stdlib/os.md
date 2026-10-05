# std/os

The process's own environment: its arguments, its environment variables, and how
it stops.

<!-- doctest: per-block -->

## Command-line arguments

`arg(0)` is the program's own path, as the OS passed it. The first real argument
is `arg(1)`, so a program with no arguments has `argc() == 1`.

### `argc(): int`

How many arguments the process received, including the program name.

### `arg(i: int): string`

Argument `i`, or `""` when `i` is out of range. Never panics.

### `args(): []string`

Every argument, program name first.

```bit
import { argc, arg, args } from "std/os"
import { join } from "std/strings"

fn usage() {
  println("usage: ${arg(0)} <input>")
}

fn inputPath(): string {
  if (argc() < 2) {
    usage()
    return ""
  }
  return arg(1)
}

fn echoArgs() {
  println(join(args(), " "))
}
```

## Environment variables

### `env(name: string): string`

The value of `name`, or `""` when it is unset. An unset variable and one set to
the empty string are indistinguishable - use `envOr` when that matters.

### `envOr(name: string, fallback: string): string`

The value of `name`, or `fallback` when it is unset.

```bit
import { env, envOr } from "std/os"

fn editor(): string {
  return envOr("EDITOR", "vi")
}

fn isDebug(): bool {
  return env("BIT_DEBUG") != ""
}
```

## The home directory

### `homeDir(): string!`

Inkwell keeps its drafts folder and its credentials under the user's home, so it
needs to know where that is on every OS. `homeDir` looks, in this order, at
`HOME`, then `USERPROFILE`, then `HOMEDRIVE` + `HOMEPATH` (just `HOMEPATH`
is taken to be on `C:`), then the OS user database (`/etc/passwd`, matched by the
real uid, else by `USER`/`LOGNAME`). The first non-empty answer wins, which is
the order the AWS SDKs use to find `~/.aws`.

When none of them names a home it fails with `HomeDirError`; it never returns
`""`, so a path built from the result cannot silently land in the current
directory.

```bit
import { homeDir, HomeDirError } from "std/os"

fn draftsDir(): string! {
  return "${homeDir()?}/.inkwell/drafts"
}

fn describeHome(): string {
  let h = homeDir() catch e {
    let he = e.(HomeDirError)
    return he.message()
  }
  return h
}
```

### `HomeDirError`

The error `homeDir` fails with.

### `HomeDirError.message(): string`

One sentence naming the sources that were empty: `HOME`, `USERPROFILE`,
`HOMEDRIVE` + `HOMEPATH` and the user database.

## The host name

### `hostname(): string!`

Inkwell's mail server introduces itself to the receiving server with `EHLO <name>`,
and when the sender has no domain of its own the right name is the machine's.
`hostname` is that name: the one the `hostname` command prints, without a domain.
It is `gethostname(2)` on macOS, the `nodename` that `uname(2)` reports on
Linux and the DNS host name (`GetComputerNameExW`) on Windows.

It fails with `HostnameError` rather than hand back something wrong: when the OS
cannot report a name, when the name is longer than 255 bytes (it is never
returned cut short) and when it is empty, so a caller never holds a silent `""`.

```bit
import { hostname, HostnameError } from "std/os"

// What to say after EHLO: the machine's own name, else "localhost".
fn helloName(): string {
  return hostname() catch "localhost"
}

fn describeHost(): string {
  let h = hostname() catch e {
    return e.(HostnameError).message()
  }
  return h
}
```

### `HostnameError`

The error `hostname` fails with.

### `HostnameError.message(): string`

`hostname: ` followed by what failed: no name reported or one over 255 bytes, or
an empty name.

## The running executable

### `selfExe(): string`

The absolute path of the running executable, with symlinks resolved, or the
empty string when the platform cannot report it.

Resolving symlinks is what makes this usable for locating an installed
program's own files: a tool is typically installed as a symlink into `PATH`,
and the symlink's directory is not the install root.

Prefer this over `arg(0)`, which is only what the caller passed - it may be a
bare name, a path relative to a working directory that has since changed, or
simply wrong. Treat an empty result as "unknown" and fall back; never treat it
as a path.

```bit
import { selfExe } from "std/os"
import { dir } from "std/path"

// The directory holding this program's own data files.
fn assetDir(): string {
  let exe = selfExe()
  if (len(exe) == 0) {
    return "."
  }
  return "${dir(dir(exe))}/share"
}
```

Running a child process is [`std/process`](process.md), not here.

Catching the signal a deployment sends on shutdown (`SIGTERM`/`SIGINT`) is
[`std/signal`](signal.md), a separate module - not here.

## Exiting

### `exit(code: int)`

Ends the process immediately with `code`. Deferred statements do not run and
buffered `std/io` writers are not flushed - flush before calling.

Returning from `main` is the ordinary way to exit; `exit` is for the cases where
you are deep in a call stack and there is nothing to return to.

```bit
import { exit } from "std/os"
import { stdout } from "std/io"

fn die(msg: string) {
  let w = stdout()
  // Nowhere better to report a failed write than the stream that just failed.
  w.writeLine("fatal: ${msg}") catch _ {}
  w.flush() catch _ {} // exit will not do this for us
  exit(1)
}
```
