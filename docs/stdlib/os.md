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
