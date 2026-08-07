# Errors

Bit uses **result-style error values with explicit propagation**, not
exceptions. A fallible function returns either an ok value or an error;
propagation is the single postfix operator `?`, and handling is the local
`catch` expression. Control flow stays visible - every early exit is a `?` or
`fail` you can see. Unrecoverable bugs use `panic`. (Spec: §18.)

## Fallible functions

A result type carrying the `!` marker is fallible. `T!` is shorthand for
`T ! error` (the default error type); `T ! E` names a concrete error type; `()!`
returns nothing or an error.

```bit ignore
function readAll(path: string): string! { }           // string OR error
function fetch(url: string): Response ! HttpError { } // custom error type
function run(): ()! { }                               // nothing OR error
```

(Signatures only - the bodies are empty and `Response`/`HttpError` stand in for
your own types, so this block is not doc-tested.)

The value of a fallible function is a built-in result; you cannot construct it by
hand, only via `return` (ok) and `fail` (err).

## Producing results

- `return v` in a fallible function wraps `v` as the **ok** result. `return`
  alone in a `()!` function returns ok-void.
- `fail e` returns the **err** result carrying `e`. Like `return`, it terminates
  the function.

```bit
import { readFile } from "std/fs"

// A tiny decimal parser, so this page's examples are real code.
function toInt(s: string): int! {
  if (len(s) == 0) {
    fail newError("empty number")
  }
  let n = 0
  let i = 0
  while (i < len(s)) {
    let c = int(s[i])
    if (c < 48 || c > 57) {
      fail newError("not a digit: ${s}")
    }
    n = n * 10 + (c - 48)
    i = i + 1
  }
  return n
}

function parsePort(s: string): int! {
  let n = toInt(s)?
  if (n < 0 || n > 65535) {
    fail newError("port out of range")   // err result
  }
  return n                               // ok result
}
```

`error("...")` builds a value satisfying the predeclared `error` interface (see
[Interfaces](interfaces.md#the-error-interface)).

## Propagating with `?`

Postfix `?` evaluates a fallible expression: if it is err, the enclosing function
immediately returns that err; if ok, `?` evaluates to the unwrapped value. `?` is
legal only inside a fallible function, and the propagated error type must be
assignable to the enclosing function's error type.

```bit
function loadCount(path: string): int! {
  let text = readFile(path)?     // returns early on a read error
  return parsePort(text)?        // returns early on a parse error
}
```

## Handling with `catch`

`catch` consumes a fallible value locally. Two forms:

- `expr catch default` - evaluates to the ok value, or to `default` (of type `T`)
  if err. The error is discarded.
- `expr catch e { ... }` - binds the error to `e` in a block; the block must
  either produce a `T` (its final expression) or divert control with `return`,
  `fail`, `panic`, `break`, or `continue`.

```bit
struct Config { export port: int }

function defaults(): Config {
  return Config{ port: 8080 }
}

function parseConfig(text: string): Config! {
  return Config{ port: parsePort(text)? }
}

function (c: Config) valid(): bool {
  return c.port > 0
}

function loadConfig(path: string): Config! {
  let text = readFile(path)?
  let cfg = parseConfig(text) catch e {
    println("bad config: ${e.message()}")
    return defaults()                            // recover with a default
  }
  if (!cfg.valid()) {
    fail newError("config failed validation")
  }
  return cfg
}

function quickCount(path: string): int {
  return loadCount(path) catch 0                 // fall back to 0 on any error
}
```

## Deferred cleanup with `defer`

`defer call` schedules a call to run when the enclosing function returns by any
path - normal `return`, `fail`, or `?` propagation - in last-in-first-out order.
Arguments are evaluated at the `defer` statement, not at execution time. This
gives deterministic resource release without finalizers.

```bit
import { open, create } from "std/fs"

function copyFile(src: string, dst: string): ()! {
  let f = open(src)?
  defer f.close()             // runs on every exit path below
  let g = create(dst)?
  defer g.close()
  g.write(f.readAll())?
  return
}
```

Deferred calls do **not** run on a panic path: a panic aborts the process
immediately, with no unwinding of any kind. Cleanup that must happen before the
process can die - releasing a lock, deleting a temp file - has to run
explicitly, before the call that may panic.

## Panics

A panic is an immediate, unrecoverable abort with a message and stack trace to
stderr and a non-zero exit code. Panics are for programmer errors and broken
invariants, never for expected failures. Sources include:

- index or slice out of range; integer divide-by-zero; signed overflow in debug
  builds
- writing a `nil` map; send/close on a `nil` or closed channel; calling a `nil`
  function; a single-result type-assertion mismatch
- an explicit `panic(msg)`
- a failed `assert(cond)` or `assert(cond, msg)`

```bit
function mustPositive(n: int): int {
  assert(n > 0, "n must be positive")   // panics if the condition is false
  return n
}
```

There is **no `recover`** in v0.1: panics are fatal by design, which keeps
control flow free of hidden unwinding. Recoverable conditions must use the result
model above.
