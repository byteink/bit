# Functions

<!-- doctest: per-block -->

A draft's id is still typed in by hand. A function turns a number into one.

## The simplest version

A function is declared with `fn`. Every parameter needs a type, and so does
the result, unless the function returns nothing:

```bit
const alphabet: string = "abcdefghijklmnopqrstuvwxyz0123456789"

fn draftId(n: int): string {
  let out = []byte(0)
  let x = n
  while (x > 0 || len(out) == 0) {
    out = append(out, alphabet[x % len(alphabet)])
    x = x / len(alphabet)
  }
  return string(out)
}

fn main() {
  println(draftId(12345)) // 7sj
}
```

Leaving out a parameter's type fails before the body is even checked:

```bit ignore
fn draftId(n): string {
  return "x"
}
// error[E0021]: expected a type, found ')'
```

## Variadics

A parameter written `...name: T` collects every remaining argument into a
`[]T`:

```bit
fn tagLine(...tags: string): string {
  let out = ""
  for t of tags {
    out = out + "#" + t + " "
  }
  return out
}

fn main() {
  println(tagLine("bit", "notes")) // individual arguments
  let ts = []string{ "draft", "log" }
  println(tagLine(...ts)) // spread an existing slice instead
}
```

A variadic parameter must be last, and a call either passes individual
arguments or spreads one slice with `...`, never both.

## Arrow functions and multiple return values

```bit
import { sorted } from "std/sort"

fn main() {
  let titles = []string{ "Zebra", "Apple", "Mango" }
  let byLength = sorted(titles, (a: string, b: string) => len(a) < len(b))
  for t of byLength {
    println(t)
  }
}
```

An arrow function with a `=> expression` body returns that expression
directly. A `=> { ... }` body works like an ordinary function and needs its
own `return`. A function can also return more than one value as a tuple:
`fn range(): (int, int) { return 0, 10 }`, unpacked with
`let (lo, hi) = range()`.

## Control flow

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

fn sumUpTo(n: int): int {
  let total = 0
  let i = 0
  while (i <= n) {
    total += i
    i += 1
  }
  return total
}
```

`for ... of` walks a collection by value; over a map it gives back a
`(key, value)` pair each time. `break` exits the innermost loop and
`continue` skips to the next iteration:

```bit
fn firstTagged(drafts: map<string, []string>, tag: string): string {
  for (id, tags) of drafts {
    for t of tags {
      if (t != tag) {
        continue
      }
      return id
    }
  }
  return ""
}
```

`switch` picks the first matching case, with no fallthrough, and a case can
list several values:

```bit
fn dayKind(day: int): string {
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

## Optional parameters

Give a trailing parameter a default so most calls can leave it out. The
default has to be a literal, written where the parameter is declared:

```bit
fn excerpt(body: string, maxLen: int = 80): string {
  if (len(body) <= maxLen) {
    return body
  }
  return body[0:maxLen] + "..."
}

fn main() {
  println(excerpt("a short body"))    // default maxLen
  println(excerpt("a short body", 5)) // caller opts into a smaller one
}
```

Once one parameter carries a default, every parameter after it needs one
too: a call short of its positional prefix could never reach a required
parameter past an optional one.

## Sharp edge

A bare expression is only a valid statement when it can have an effect on
its own - a call, a channel receive, or an error-propagation chain:

```bit ignore
fn oops(a: int, b: int) {
  a + b // error: expression statement has no effect
}
```

## Next

[Interfaces](interfaces.md): drafts are stored in a bare map today, which
means every future change to storage has to touch the caller directly.
