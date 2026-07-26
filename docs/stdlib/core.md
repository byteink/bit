# std/core - the prelude

Every module gets `std/core` without importing it. It holds the two container
types that stand in for null and for exceptions, and the one function you reach
for before anything else.

<!-- doctest: per-block -->

```bit
function greet(name: string) {
  println("hello, ${name}")
}
```

## Output

### `println(s: string)`

Writes `s` and a newline to standard output. Unbuffered, so it is safe to call
right before a panic; for many small writes, use a `std/io` `Writer` instead.

## Errors

Bit has no exceptions. A fallible function returns `T!`, and the error travels
as a value - see [errors](../reference/errors.md).

### `newError(msg: string): error`

Builds an `error` carrying `msg`. This is the constructor: there is no `error(...)`.
Read the text back with `e.message()`.

```bit
function halve(n: int): int! {
  if (n % 2 != 0) {
    fail newError("not even: ${n}")
  }
  return n / 2
}

function show(n: int) {
  let h = halve(n) catch e {
    println("failed: ${e.message()}")
    return
  }
  println("half is ${h}")
}
```

## `Option<T>` - a value, or nothing

### `Option`

`Option<T>` is `Some(T)` or `None`. It replaces the null pointer: a `T` is always
a `T`, and the possibility of absence is written into the type.

```bit
function firstEven(xs: []int): Option<int> {
  for x of xs {
    if (x % 2 == 0) {
      return Option.Some(x)
    }
  }
  return Option<int>.None
}

function report(xs: []int) {
  match (firstEven(xs)) {
    Some(v) => { println("found ${v}") }
    None => { println("none even") }
  }
}
```

A bare `None` carries nothing to infer `T` from, so annotate it -
`Option<int>.None` - unless the target type already says which `Option` it is.

### `isSome(o: Option<T>): bool`

Whether `o` holds a value.

### `isNone(o: Option<T>): bool`

Whether `o` is empty. Exactly `!isSome(o)`.

### `unwrap(o: Option<T>): T`

The contained value. **Panics** if `o` is `None` - use it only where `None` is a
bug, not a possibility.

### `unwrapOr(o: Option<T>, dflt: T): T`

The contained value, or `dflt` when there is none. The total version of `unwrap`.

```bit
function port(configured: Option<int>): int {
  return unwrapOr(configured, 8080)
}

function must(o: Option<int>): int {
  if (isNone(o)) {
    println("expected a value")
  }
  return unwrap(o)
}
```

## `Result<T, E>` - a value, or a reason

### `Result`

`Result<T, E>` is `Ok(T)` or `Err(E)`. Prefer `T!` for ordinary fallible
functions; reach for `Result` when the error type matters, or when you need to
store the outcome rather than propagate it.

### `isOk(r: Result<T, E>): bool`

Whether `r` holds a success value.

### `isErr(r: Result<T, E>): bool`

Whether `r` holds an error. Exactly `!isOk(r)`.

### `unwrapOk(r: Result<T, E>): T`

The success value. **Panics** on `Err`.

### `okOr(r: Result<T, E>, dflt: T): T`

The success value, or `dflt` on `Err`.

```bit
function parseFlag(s: string): Result<bool, string> {
  if (s == "yes") {
    return Result.Ok(true)
  }
  if (s == "no") {
    return Result.Ok(false)
  }
  return Result<bool, string>.Err("not a flag: ${s}")
}

function verbose(s: string): bool {
  return okOr(parseFlag(s), false)
}
```
