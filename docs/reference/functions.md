# Functions

Functions are declared with `fn` and are first-class values. This chapter also
covers the control-flow statements that live in function bodies. A method is
different: it is declared in the class body with the implicit `this`
receiver, not with a top-level `fn` - see [Methods](classes.md#methods) in
the Classes chapter. (Spec: §10.3, §12.4, §12.8, §13.1.)

## Declaring functions

A named function requires a type on every parameter and, unless it returns
nothing, on the result. This keeps checking modular and diagnostics precise.

```bit
fn add(a: int, b: int): int {
  return a + b
}

fn log(msg: string) { // no result type -> returns nothing (void)
  // ...
}
```

The result type follows `:`. Omitting it means the function returns nothing.

### Multiple return values

Return several values as a tuple; the result type is a tuple type.

```bit
fn divmod(a: int, b: int): (int, int) {
  return a / b, a % b
}

fn useIt() {
  let (q, r) = divmod(17, 5) // q = 3, r = 2
}
```

## Parameters, variadics, and spread

A variadic parameter (`...name: T`) must be last and has type `[]T` inside the
body. Callers pass zero or more `T` arguments, or spread a `[]T` with `...`.
Exactly one spread is allowed, and you cannot mix individual args with a spread.

```bit
fn sum(...xs: int): int {
  let total = 0
  for x of xs {
    total += x
  }
  return total
}

fn callers() {
  let a = sum(1, 2, 3) // individual args
  let nums = []int{ 4, 5, 6 }
  let b = sum(...nums) // spread a slice
}
```

## Named arguments

A call may name its arguments instead of relying on position: `name =
expression`, after any positional arguments. This is only legal for a direct
call to a named function or method - not through a function value - and each
parameter may be supplied once, by position or by name. (Spec: §12.11.)

```bit
fn serve(app: string, port: int, tls: bool) {
  // ...
}

fn serveCallers() {
  serve("web", 3000, true)                    // positional
  serve(app = "web", port = 3000, tls = true) // fully named
  serve("web", port = 3000, tls = true)       // positional prefix, then named
}
```

## First-class functions and arrow functions

Functions are values. Arrow functions are concise anonymous functions; their
parameter and return types are inferred from context when omitted.

```bit
import { mapped } from "std/seq"

fn transform(xs: []int): []int {
  // `mapped` is a free function, not a method: slices have no methods, and
  // `map` is a reserved word (the map type).
  return mapped<i64, i64>(xs, (x: i64) => x * 2)
}

fn explicit(): (int, int) => int {
  return (a: int, b: int) => a + b // explicit types
}

fn withBlock(): (int) => int {
  return (x: int) => { // block body uses return
    let y = x * x
    return y + 1
  }
}
```

A `=> expression` body returns that expression; a `=> { ... }` block body uses
`return`.

## Control flow

### `if` / `else`

The condition is parenthesized; the body is always a brace block.

```bit
fn classify(n: int): string {
  if (n < 0) {
    return "negative"
  } else if (n == 0) {
    return "zero"
  } else {
    return "positive"
  }
}
```

### `while`

```bit
fn countdown(n: int) {
  while (n > 0) {
    n -= 1
  }
}
```

### `for`

Two documented forms: C-style counting and `for ... of` over a collection or
channel. An empty `for { }` loops forever. (The grammar also reserves a
`for ident in expr` form; its semantics are not yet fixed in the spec, so it is
not documented here - this reference will add it when the spec does.)

```bit
fn loops(xs: []int, m: map<string, int>) {
  for (let i = 0; i < len(xs); i++) { // C-style
    // ...
  }

  for v of xs { // value iteration
    // ...
  }

  for (k, val) of m { // key/value iteration over a map
    // ...
  }
}
```

`break` exits the innermost loop; `continue` skips to the next iteration.

```bit
fn firstEven(xs: []int): int {
  for x of xs {
    if (x % 2 != 0) {
      continue
    }
    return x
  }
  return -1
}
```

### `switch`

An optional subject expression; each `case` may list several values. There is no
implicit fallthrough.

```bit
fn name(day: int): string {
  switch (day) {
    case 0, 6:
      return "weekend"
    case 1, 2, 3, 4, 5:
      return "weekday"
    default:
      return "invalid"
  }
}
```

A subject-less `switch { case cond: ... }` chooses the first true case, replacing
an `if`/`else` ladder.

## Expression statements

A bare expression is a valid statement only when it can have a standalone effect:
a function call, a channel receive, or an error-propagation (`?`) chain. A lone
`a + b` statement is a compile error, which catches mistakes.

```bit
fn effects() {
  println("side effect") // ok: a call
  // 1 + 2                 // error: no effect
}
```
