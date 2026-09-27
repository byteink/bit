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

## Shutting down cleanly

A process only ever stops two ways: the OS kills it outright (no code runs
after that, ever) or something inside the program calls `exit`. Neither lets
an external `docker stop`, `kubectl delete pod` or a developer's Ctrl-C run
any code first - `SIGTERM`/`SIGINT` just end the process. `waitForSignal`
gives a program a third option: block a green thread until one of those
signals arrives, and run your own shutdown logic before the process ends.

### `waitForSignal(sigs: []Signal): Signal`

Blocks the calling green thread until the process receives one of `sigs`,
and returns which one arrived. Start every listener on its own green thread
first, then wait for the signal, then shut down:

```bit
import { waitForSignal, Signal } from "std/os"

fn main() {
  // ... start listeners, background work, etc. on their own green threads ...

  let _ = waitForSignal([Signal.Term, Signal.Int])
  print("shutting down\n")
  // ... close listeners, drain in-flight work, flush writers ...
}
```

A signal not in `sigs` never returns from the call - it is silently
re-waited. Windows delivers `Signal.Int` for Ctrl-C and `Signal.Term` for
Ctrl-Break, a console close or a logoff/shutdown event
(`SetConsoleCtrlHandler`); there is no narrower Windows equivalent of
`SIGKILL` to worry about missing.

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
  w.writeLine("fatal: ${msg}")
  w.flush() // exit will not do this for us
  exit(1)
}
```
