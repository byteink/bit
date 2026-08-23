# Variables

Bit has two ways to introduce a binding: `let` for mutable variables and
`const` for immutable ones. Both infer their type from the initializer, so you
rarely write a type annotation. (Spec: §10.1, §13.2, §13.4, §15.1.)

## `let` and `const`

```bit
let count = 0          // mutable, inferred type int
const limit = 100      // immutable, inferred type int

fn tick() {
  count = count + 1    // ok: let is mutable
  // limit = 200       // error: const cannot be reassigned
}
```

`let` bindings can be reassigned; `const` bindings cannot. A top-level `const`
must be a compile-time constant (§15.4); a `const` inside a function is just a
single-assignment immutable binding and may hold any expression.

## Type annotations

Annotate with `: type` when you want a specific type or declare without an
initializer. A `let` with no initializer is set to the type's **zero value**, so
the annotation is then required.

```bit
fn demo() {
  let name: string = "bit"   // explicit type, redundant here
  let score: int             // no initializer -> zero value 0
  let ready: bool            // -> false
  let ratio = 3.0            // inferred f64 (float default type)
}
```

If both an annotation and an initializer are present, the initializer must be
assignable to the annotated type (§14.2). No implicit numeric conversion
happens, so `let x: i64 = anI32Value` is an error - convert explicitly (see
[Types](types.md#conversions)).

## Zero values

Every binding without an initializer is deterministically zeroed (§13.4):

- numbers → `0`, `bool` → `false`, `string` → `""`
- arrays and tuples → each element zeroed
- classes → a live instance with every field zeroed (classes are references but
  a zeroed class is usable, not `nil`)
- slices, maps, channels, functions, interfaces → `nil`

One exception, and it is the only one: a class that has a **class-typed field**
has no zero value, so it cannot be declared without an initializer and a literal
cannot leave that field out. Both are `E0083`. A class is a reference, so zero
bits in such a field would be a null rather than a live instance - see
[Classes](classes.md#reference-type).

```bit
class Point { x: f64; y: f64 }

fn origin(): Point {
  let p: Point       // {x: 0.0, y: 0.0}, ready to use
  return p
}
```

## Declaration vs assignment

`let`/`const` **declare** a new binding; `=` **assigns** to one that already
exists. There is no `:=`. To shadow a name in an inner scope, declare it again.

```bit
fn scope() {
  let x = 1
  {
    let x = 2     // a new binding shadows the outer x in this block
    x = 3         // assigns to the inner x
  }
  // x is 1 again here
}
```

## Multiple bindings and destructuring

Declare several bindings at once, and destructure a tuple positionally with a
tuple pattern. `_` is the **blank identifier**: it discards a value and may
never be read.

```bit
fn unpack(): (int, int) {
  let a = 1, b = 2                 // two bindings in one statement
  let (lo, hi) = bounds()          // destructure a tuple result
  let (_, second) = bounds()       // discard the first element
  return lo, hi
}

fn bounds(): (int, int) { return 0, 10 }
```

## Assignment statements

Assignment is a statement, never an expression, so `=` cannot appear inside an
expression. Multi-assignment evaluates every right-hand side before assigning,
which makes swaps clean:

```bit
fn swap() {
  let a = 1, b = 2
  a, b = b, a          // simultaneous: a is now 2, b is 1
}
```

Compound assignment operators combine an operation with a store and require a
single target and value:

```bit
fn accumulate() {
  let total = 0
  total += 5           // total = total + 5
  total *= 2
  total <<= 1
}
```

Increment and decrement are statements too, not expressions:

```bit
fn counterDemo() {
  let n = 0
  n++
  n--
}
```

## Comments

```bit
// line comment: runs to end of line

/* block comment: does not nest;
   the first */ // closes it
```

## Statement terminators (semicolons)

Statements end with `;`, but you almost never type one - the lexer inserts them
at line ends (§7). The practical rule: **to continue a statement onto the next
line, end the line with something that is not a value** - a binary operator, a
comma, an opening bracket, `=`, `=>`, `.`, or `<-`.

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

Keep an opening brace on the same line as the construct it opens, or a semicolon
is inserted before it:

```bit
fn braces(ready: bool) {
  if (ready) {         // correct: the brace opens on the construct's own line
    println("work")
  }
}
```
