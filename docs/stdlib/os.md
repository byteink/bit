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

## Running a child process

### `run(path: string, args: []string): int`

Runs `path` as a child process with `args` as its argument vector - the
runtime supplies `argv[0]` itself, so `args` holds arguments only, never the
program name. The child is always exec'd directly, never through a shell, so
nothing in `args` is ever reinterpreted as shell syntax. It inherits this
process's environment and this process's stdout/stderr. Returns the child's
exit code, or `-1` if it could not be spawned.

There is no way to capture the child's output through this function - only
its exit status. Route output through a temp file and `readFile` until this
module grows a capture variant.

```bit
import { run } from "std/os"

fn buildStep(): bool {
  return run("/usr/bin/make", ["-C", "vendor"]) == 0
}
```

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
