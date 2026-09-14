# Variables

Say you are building a link shortener. The first thing it needs is somewhere
to keep the mapping from a short code to the URL it stands for. That
somewhere is a binding, and Bit gives you two ways to make one.

## The shortest thing that works

```bit
fn shorten() {
  let links = map<string, string>()
  links["abc123"] = "https://example.com"
  println("abc123 -> ${links["abc123"]}")
}
```

`let` declares `links` and gives it a starting value. `map<string, string>()`
makes an empty map; you don't write its type again because Bit infers it from
the call. `links["abc123"] = ...` stores into it, and `links` has to be `let`,
not `const`, because storing into a map means changing what `links` holds.

Run this and it prints `abc123 -> https://example.com`. This is exactly
`docs/examples/shortener/01_map.bit`.

## `let` vs `const`

`let` bindings can be reassigned. `const` bindings cannot:

```bit
fn baseUrlDemo() {
  const baseUrl = "https://lnk.to"
  let visits = 0
  visits = visits + 1  // fine: visits is let
  // baseUrl = "https://x.to" // error: const cannot be reassigned
}
```

The shortener's base domain never changes once the program starts, so it is a
`const`. The count of visits a link has seen does, so it is a `let`. Reach for
`const` first; only switch to `let` once you actually need to reassign, so the
signature of the binding tells the next reader which ones can change.

Try to reassign a `const` and the compiler stops you before the program runs:

```
error[E0062]: cannot assign to 'baseUrl': declared 'const'
```

## Zero values

What does `links["zzz999"]` give you before you have stored anything under
that key? Not an error. A map read that misses returns the **zero value** of
the value type, `""` for a `string`:

```bit
fn missingCode(): string {
  let links = map<string, string>()
  return links["zzz999"] // "" - the zero value of string, not an error
}
```

Every type has a zero value: numbers are `0`, `bool` is `false`, `string` is
`""`. It is what a `let` gets when you declare it without giving it one:

```bit
fn declared() {
  let hits: int    // 0, no initializer needed once you annotate the type
  let ready: bool  // false
}
```

This is also the sharp edge to watch for: a missing key and a key whose value
really is `""` look identical when you just read `links[code]`. If you need to
tell the two apart, use the two-result index form covered on
[Types](types.md#maps).

## Declaration vs assignment

`let` and `const` **declare** a binding that does not exist yet. `=` on its
own **assigns** to one that already exists:

```bit
fn rename() {
  let code = "abc123"
  code = "xyz789" // assigns; code already exists
  // let code = "xyz789" would redeclare it, which only matters inside a
  // new block: it shadows the outer one instead of erroring
}
```

## When not to use `let`

If a value is set once and never changes for the life of the program, like the
shortener's base domain or a fixed retry limit, `const` says so directly.
Using `let` for it is not wrong, but it makes every reader re-check whether it
ever changes, and it silently gives up the compiler's guarantee that it will
not.

## Reference: the rest of binding syntax

The shortener does not need the rest of this yet, but you will hit it once you
write more than one function.

### Multiple bindings and destructuring

```bit
fn unpack(): (int, int) {
  let a = 1, b = 2           // two bindings, one statement
  let (lo, hi) = bounds()    // destructure a tuple result
  let (_, second) = bounds() // _ discards; it can never be read
  return lo, hi
}

fn bounds(): (int, int) { return 0, 10 }
```

### Compound assignment, increment, decrement

```bit
fn accumulate() {
  let total = 0
  total += 5 // total = total + 5
  total *= 2
  total <<= 1

  let n = 0
  n++
  n--
}
```

`=`, `+=`, `++` and friends are statements, never expressions - `x = (y = 1)`
does not compile.

### Comments

```bit
// line comment: runs to end of line

/* block comment: does not nest;
   the first */ // closes it
```

### Statement terminators (semicolons)

Statements end with `;`, but you almost never type one; the lexer inserts them
at line ends. The rule: to continue a statement onto the next line, end the
line with something that is not a value - a binary operator, a comma, an
opening bracket, `=`, `=>`, `.`, or `<-`.

```bit
import { newBuilder } from "std/strings"

fn continuation() {
  let total = 1 +      // ends with '+', continues
              2 + 3

  let s = newBuilder(). // ends with '.', continues
            write("a").
            write("b").
            toString()
}
```

Keep an opening brace on the same line as the construct it opens, or a
semicolon is inserted before it:

```bit
fn braces(ready: bool) {
  if (ready) { // correct: the brace opens on the construct's own line
    println("work")
  }
}
```

## Next

The shortener now stores codes and URLs, but only because you already know
what `map<string, string>` and `${...}` mean. Those belong to Bit's type
system: read [Types](types.md) next.
