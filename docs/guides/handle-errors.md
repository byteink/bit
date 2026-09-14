# Handle errors without exceptions

A function that can fail says so in its return type, and every place it can
fail is a `?` or a `catch` you can see at the call site. There is no `try`
block hiding an exit three functions up the stack.

<!-- doctest: per-block -->

## The shortest failing function

A fallible function returns `T!` - either an ok value of type `T`, or an
error. `fail` produces the error; `return` produces the ok value.

```bit
fn parsePort(s: string): int! {
  let n = 0
  let i = 0
  if (len(s) == 0) {
    fail newError("empty port")
  }
  while (i < len(s)) {
    let c = int(s[i])
    if (c < 48 || c > 57) {
      fail newError("not a digit: ${s}")
    }
    n = n * 10 + (c - 48)
    i = i + 1
  }
  if (n < 0 || n > 65535) {
    fail newError("port out of range: ${n}")
  }
  return n
}

fn main(): ()! {
  let port = parsePort("8080")?
  println("port = ${port}")
  return
}
```

Running it prints:

```
port = 8080
```

## Passing failure up: `?`

`?` on a fallible expression either unwraps the ok value, or - if it is an
error - returns immediately from the enclosing function with that same
error. `main` has to be fallible itself (`fn main(): ()!`) for `?` to be
legal inside it, which is what makes the block above compile.

## Handling failure locally: `catch`

`catch` stops the error at the call site instead of passing it up. Two
shapes: `expr catch default` for "use this instead", and
`expr catch e { ... }` when you need to look at the error.

```bit
fn parsePort(s: string): int! {
  let n = 0
  let i = 0
  if (len(s) == 0) {
    fail newError("empty port")
  }
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

fn main(): ()! {
  let good = parsePort("8080")?
  println("port = ${good}")

  let bad = parsePort("abc") catch e {
    println("fallback after: ${e.message()}")
    0
  }
  println("bad = ${bad}")
  return
}
```

That prints:

```
port = 8080
fallback after: not a digit: abc
bad = 0
```

A `catch e { ... }` block runs `e.message()` to read the error text, and its
last expression becomes the value `catch` evaluates to - here, `0`. The block
can also `return`, `fail` again, `panic`, `break` or `continue` instead of
producing a value, when recovering means leaving the function rather than
substituting a default.

## Cleanup that must run either way: `defer`

`defer call` schedules `call` to run when the function returns, on every
path - success, an early `fail`, or a `?` that propagated. It runs in
last-in-first-out order, which is why a paired open/close reads top to
bottom in the order things actually happen.

```bit
import { open, create } from "std/fs"

fn copyFile(src: string, dst: string): ()! {
  let f = open(src)?
  defer f.close()
  let g = create(dst)?
  defer g.close()
  g.write(f.readAll()?)?
  return
}
```

If `create(dst)` fails, `f.close()` still runs - `defer` was already
registered before that line could fail.

## When a value should never be an error: `panic`

`fail` is for a caller who might reasonably recover: a bad password, a
missing file, a malformed request. `panic` is for a broken invariant - a bug,
not an expected outcome. It has no error type and nothing catches it locally;
it aborts the program (or the task, if `std/runtime`'s `runRecovering`
installed a boundary) with a message and a stack trace on stderr.

```bit
fn mustPositive(n: int): int {
  assert(n > 0, "n must be positive")
  return n
}
```

`assert` panics with its message when the condition is false. Reach for it
to check a precondition your own code broke, never for input from outside
the program - that belongs to `fail`.

## Sharp edges

- `defer` does not run on a panic. A panic aborts immediately with no
  unwinding, so a lock or a temp file that must be released before the
  process can die has to be released before the call that might panic, not
  after it in a `defer`.
- The error type in `?` must be assignable to the enclosing function's own
  error type. Mixing a custom error type into a function whose signature
  says plain `T!` is a compile error at the `?`, naming both types.
- `T!` with nothing after `!` is `T ! error`, the default error type built
  from `newError(...)`. Write `T ! MyError` when a caller needs to branch on
  which specific failure happened, not just read a message.

## What to read next

[std/fs](../stdlib/fs.md) and [std/http](../stdlib/http.md) are full of
functions returning `T!` you will actually call. For the language rules this
page only summarizes, see the [Errors reference](../reference/errors.md).
