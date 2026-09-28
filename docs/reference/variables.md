# Variables

<!-- doctest: per-block -->

A binding gives a value a name. Bit has two: `let`, which can be reassigned,
and `const`, which cannot.

## `let` and `const`

```bit
fn main() {
  const title = "Notes on Bit"
  let views = 0
  views = views + 1 // fine: views is let
  // title = "x" // error: const cannot be reassigned
  println("${title}: ${views} view(s)")
}
```

A draft's title never changes once you have written it down; a view count
does. Reach for `const` first, and switch to `let` only once you need to
reassign, so the binding itself tells the next reader whether it can change.

Reassigning a `const` is a compile error, not a runtime one:

```
error[E0062]: cannot assign to 'title': declared 'const'
```

## Declaring vs. assigning

`let` and `const` declare a binding that does not exist yet. `=` on its own
assigns to one that already exists:

```bit
fn rename() {
  let id = "draft-1"
  id = "draft-2" // assigns; id already exists
}
```

`let id = "draft-2"` inside a new block does not reassign the outer `id`; it
declares a second one that shadows it for the rest of that block.

## Zero values

A `let` declared without a value gets its type's **zero value**: `0` for
numbers, `false` for `bool`, `""` for `string`. A map read that misses a key
returns the zero value of the map's value type, not an error:

```bit
fn missingTitle(): string {
  let titles = map<string, string>()
  return titles["missing-id"] // "" - the zero value, not an error
}
```

This is a sharp edge: a missing key and a key whose value really is `""` look
identical through `titles[id]` alone. The two-result form on
[Types](types.md#maps) tells them apart.

## Multiple bindings and destructuring

```bit
fn main() {
  let a = 1, b = 2          // two bindings, one statement
  let (lo, hi) = range()    // destructure a tuple result
  let (_, second) = range() // _ discards; it can never be read
  println("${a} ${b} ${lo} ${hi} ${second}")
}

fn range(): (int, int) { return 0, 10 }
```

## Compound assignment, increment, decrement

```bit
fn main() {
  let total = 0
  total += 5 // total = total + 5
  total *= 2

  let n = 0
  n++
  n--
  println("${total} ${n}")
}
```

`=`, `+=`, `++` and friends are statements, never expressions: `x = (y = 1)`
does not compile.

## Comments and statement terminators

```bit
// a line comment, runs to end of line
/* a block comment, does not nest */

fn continuation() {
  let total = 1 + // a line ending in an operator continues
    2 +
    3
  println("${total}")
}
```

Statements end with `;`, inserted automatically at line ends. To continue a
statement onto the next line, end that line with something that cannot be a
complete value: a binary operator, a comma, an opening bracket, `=`, `=>`,
`.`, or `<-`. Keep an opening brace on the same line as the construct it
opens, or a semicolon is inserted before it.

## Next

[Types](types.md) covers what `map<string, string>` and `${...}` above
actually mean.
