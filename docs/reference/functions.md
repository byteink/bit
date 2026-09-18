# Functions

<!-- doctest: per-block -->

[Classes](classes.md) gave every stored link its own `Link`, but the code
that names it is still typed in by hand:

```bit ignore
links["abc123"] = Link{ url: "https://example.com", created: 0, hits: 0 }
```

A real shortener cannot ask someone to invent a code. It needs something
that turns a number into one.

## The simplest version

A function is declared with `fn`. Every parameter needs a type, and so does
the result, unless the function returns nothing:

```bit
const alphabet: string = "abcdefghijklmnopqrstuvwxyz0123456789"

fn shortCode(n: int): string {
  let out = []byte(0)
  let x = n
  while (x > 0 || len(out) == 0) {
    out = append(out, alphabet[x % len(alphabet)])
    x = x / len(alphabet)
  }
  return string(out)
}
```

`shortCode` reads off one base-36 digit at a time from `alphabet` until `n`
runs out, lowest digit first. `shortCode(12345)` is `"7sj"`; the
`|| len(out) == 0` keeps the loop running at least once, so `shortCode(0)`
still returns `"a"` instead of an empty string.

Leaving out a parameter's type is not something the function body can fix
later; it fails before the body is even checked:

```bit ignore
fn shortCode(n): string {
  return "x"
}
// error[E0021]: expected a type, found ')'
```

## Generating a batch

A single `shortCode` call is fine for one link. A bulk import needs many at
once, so `shortCode` grows a companion that takes as many numbers as it's
given. A parameter written `...name: T` collects every remaining argument
into a `[]T`:

```bit
const alphabet: string = "abcdefghijklmnopqrstuvwxyz0123456789"

fn shortCode(n: int): string {
  let out = []byte(0)
  let x = n
  while (x > 0 || len(out) == 0) {
    out = append(out, alphabet[x % len(alphabet)])
    x = x / len(alphabet)
  }
  return string(out)
}

fn shortCodes(...ns: int): []string {
  let out = []string(0)
  for n of ns {
    out = append(out, shortCode(n))
  }
  return out
}

fn demo() {
  let a = shortCodes(1, 2, 3) // individual arguments
  let batch = []int{ 4, 5, 6 }
  let b = shortCodes(...batch) // spread an existing slice instead
}
```

A variadic parameter must be last, and a call either passes individual
arguments or spreads one slice with `...` - never both.

## Sorting the batch with a closure

The batch comes back in call order, not a useful order. `std/sort`'s
`sorted` takes the slice and a comparison function, and hands back a sorted
copy:

```bit
import { sorted } from "std/sort"

const alphabet: string = "abcdefghijklmnopqrstuvwxyz0123456789"

fn shortCode(n: int): string {
  let out = []byte(0)
  let x = n
  while (x > 0 || len(out) == 0) {
    out = append(out, alphabet[x % len(alphabet)])
    x = x / len(alphabet)
  }
  return string(out)
}

// Generates a code for every number in `ns` and remembers which number made
// each one, so the codes can later be put back in that order.
fn shortCodesFor(ns: []int): (map<string, int>, []string) {
  let byCode = map<string, int>()
  let codes = []string(0)
  for n of ns {
    let c = shortCode(n)
    byCode[c] = n
    codes = append(codes, c)
  }
  return byCode, codes
}

fn demo() {
  let (byCode, codes) = shortCodesFor([]int{ 300, 5, 42 })
  // (a: string, b: string) => byCode[a] < byCode[b] is an arrow function -
  // a function value written inline. It closes over `byCode` from the
  // enclosing scope, so `sorted` can compare codes by the number that made
  // them without knowing anything about `byCode` itself.
  let byNumber = sorted(codes, (a: string, b: string) => byCode[a] < byCode[b])
  // byNumber is ["f", "gb", "mi"] - 5, 42, 300 in that order.
}
```

`shortCodesFor` also shows a function returning more than one value: the
result type is a tuple, `(map<string, int>, []string)`, and `let (byCode,
codes) = ...` unpacks it.

An arrow function with a `=> expression` body returns that expression
directly. A `=> { ... }` body works like an ordinary function and needs its
own `return`.

## The real use case

Stage 03 of the shortener puts `shortCode` to work: a `Link` still holds the
URL, but the map key comes from `shortCode` instead of from a human.

```bit
class Link {
  export url: string,
  export created: i64,
  export hits: int,
}

const alphabet: string = "abcdefghijklmnopqrstuvwxyz0123456789"

fn shortCode(n: int): string {
  let out = []byte(0)
  let x = n
  while (x > 0 || len(out) == 0) {
    out = append(out, alphabet[x % len(alphabet)])
    x = x / len(alphabet)
  }
  return string(out)
}

fn main() {
  let links = map<string, Link>()
  let code = shortCode(12345)
  links[code] = Link{ url = "https://example.com", created = 0, hits = 0 }

  let l = links[code]
  println("${code} -> ${l.url} (hits=${l.hits})")
}
// 7sj -> https://example.com (hits=0)
```

## Control flow

Function bodies use the usual forms. `if`/`else` conditions and `while` and
C-style `for` headers are parenthesized; every body is a brace block:

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
fn firstEven(xs: []int): int {
  for x of xs {
    if (x % 2 != 0) {
      continue
    }
    return x
  }
  return -1
}

fn total(counts: map<string, int>): int {
  let sum = 0
  for (k, v) of counts {
    sum += v
  }
  return sum
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

`shortCode` above always draws from the same 36-character alphabet. A test
that wants to force collisions on a tiny alphabet has to copy the whole
function just to change one argument every other caller was happy with.

Give the trailing parameter a default instead, so most calls can leave it out.
The default has to be a literal, written right where the parameter is
declared - not a reference to some other constant:

```bit
fn code(n: int, chars: string = "abcdefghijklmnopqrstuvwxyz0123456789"): string {
  let out = []byte(0)
  let x = n
  while (x > 0 || len(out) == 0) {
    out = append(out, chars[x % len(chars)])
    x = x / len(chars)
  }
  return string(out)
}

fn main() {
  println(code(12345))       // default alphabet
  println(code(12345, "01")) // caller opts into a smaller one
}
// 7sj
// 10011100000011
```

A method's trailing parameter takes a default exactly the same way - a call
through `l.describe()` omits it just as `code(12345)` does above:

```bit
class LinkStats {
  export url: string
  export created: i64
  export hits: int

  export describe(label: string = "link"): string {
    return "${label}: ${this.url} (hits=${this.hits})"
  }
}

fn main() {
  let l = LinkStats{ url = "https://example.com", created = 0, hits = 3 }
  println(l.describe())
  println(l.describe("short URL"))
}
// link: https://example.com (hits=3)
// short URL: https://example.com (hits=3)
```

A non-literal default is rejected outright, never evaluated once at the call
site - `chars: string = someFunc()` does not compile. Once one parameter
carries a default, every parameter after it needs one too: a call short of
its positional prefix could never reach a required parameter past an optional
one, so `fn f(a: int = 1, b: int)` is rejected on the declaration itself, not
on some future call.

## Sharp edges

A bare expression is only a valid statement when it can have an effect on
its own - a call, a channel receive, or an error-propagation chain. A stray
`a + b` with the result thrown away is a compile error, which catches typos
that meant to call something:

```bit ignore
fn oops(a: int, b: int) {
  a + b // error: expression statement has no effect
}
```

## When not to reach for a function

If a value's behaviour only ever makes sense together with that value's own
data, a method on a class reads better than a free function taking the
value as its first argument - see [Classes](classes.md).

## Next

[Interfaces](interfaces.md): the shortener's storage is still a bare `map`,
which means every future change to how links are stored has to touch
`main` directly. Next: hiding that behind a `Store`.
