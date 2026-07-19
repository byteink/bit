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

function usage() {
  println("usage: ${arg(0)} <input>")
}

function inputPath(): string {
  if (argc() < 2) {
    usage()
    return ""
  }
  return arg(1)
}

function echoArgs() {
  println(join(args(), " "))
}
```

## Environment variables

### `env(name: string): string`

The value of `name`, or `""` when it is unset. An unset variable and one set to
the empty string are indistinguishable — use `envOr` when that matters.

### `envOr(name: string, fallback: string): string`

The value of `name`, or `fallback` when it is unset.

```bit
import { env, envOr } from "std/os"

function editor(): string {
  return envOr("EDITOR", "vi")
}

function isDebug(): bool {
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

Prefer this over `arg(0)`, which is only what the caller passed — it may be a
bare name, a path relative to a working directory that has since changed, or
simply wrong. Treat an empty result as "unknown" and fall back; never treat it
as a path.

```bit
import { selfExe } from "std/os"
import { dir } from "std/path"

// The directory holding this program's own data files.
function assetDir(): string {
  let exe = selfExe()
  if (len(exe) == 0) {
    return "."
  }
  return "${dir(dir(exe))}/share"
}
```

## Exiting

### `exit(code: int)`

Ends the process immediately with `code`. Deferred statements do not run and
buffered `std/io` writers are not flushed — flush before calling.

Returning from `main` is the ordinary way to exit; `exit` is for the cases where
you are deep in a call stack and there is nothing to return to.

```bit
import { exit } from "std/os"
import { stdout } from "std/io"

function die(msg: string) {
  let w = stdout()
  w.writeLine("fatal: ${msg}")
  w.flush() // exit will not do this for us
  exit(1)
}
```
