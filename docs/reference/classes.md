# Classes

A class groups named fields under one type name and gives them behavior with
methods attached via an explicit receiver. (Spec: §10.4, §10.5, §12.2, §13.3,
§13.4, §14.6.)

## A class is a reference type {#reference-type}

This is the one fact that drives everything else in this chapter, so it comes
first rather than being left for an example to reveal: **a class is
heap-allocated, and assigning a class value copies the handle, not the
fields.** That is reference semantics, like a TypeScript or Java object -
unlike a Go or C `struct`, which copies its fields on assignment.

```bit
class Point { x: f64; y: f64 }

fn classes() {
  let p = Point{ x: 1.0, y: 2.0 }   // keyed literal, always type-prefixed
  let q = Point{ x: 3.0 }           // y omitted -> zero value 0.0
  let shared = p                    // copies the handle, not the fields
  shared.x = 9.0                    // p.x is now 9.0 too - same object
}
```

Two consequences follow directly:

- **Every class value is an allocation.** A composite literal - and even a
  zeroed `let p: Point` with no initializer - puts a live object on the heap
  for the collector to track and eventually reclaim (see
  [Memory management](types.md#memory-management)). Building a class value
  inside a hot loop, even one you discard immediately, is real allocation
  work; an array, a tuple, or a primitive in the same loop costs nothing,
  because those are value types (see
  [Value vs reference semantics](types.md#value-vs-reference-semantics)).
- **Passing a class to a function shares it**, the same way passing a slice or
  a map does - a function that mutates a field mutates the caller's object
  (see [Methods](#methods) below). To get an independent copy, write and call
  your own `clone()` method; there is no built-in deep copy.

## Declaring a class

```bit
class User {
  export name: string    // visible to other modules
  age: int                // module-private
}
```

- A field marked `export` is visible outside the module; an unmarked field is
  module-private. Export the class itself with `export class User { ... }` -
  see [Modules](modules.md#visibility-with-export) for the full visibility
  model, including exporting a method.
- Fields are ordered; that order is both the composite-literal positional
  order and the memory layout order (subject to the compiler's alignment
  padding).

## Composite literals {#composite-literals}

A class literal is **always** prefixed by its type name -
`Point{ x: 1.0, y: 2.0 }`, never a bare `{ ... }`. This is what removes the
block-versus-literal ambiguity: a `{` in statement position is always a block,
never a class literal. Fields are keyed and order-independent; any field left
out of a literal takes its type's zero value.

```bit
fn composite() {
  let a = User{ age: 30, name: "Ada" }   // keyed - order doesn't matter
  let b = User{ name: "Grace" }          // age omitted -> zero value 0
}
```

A foreign class's unexported fields cannot appear in a literal built outside
its own module, the same restriction `export` places on plain field access.

### Field shorthand

A field key with no `: value` is shorthand for a value with the same name:
`User{ name, age }` means `User{ name: name, age: age }`, reusing a binding
already in scope. Shorthand and keyed fields mix freely in one literal, and
field order stays irrelevant either way - shorthand does not make the literal
positional (§12.2).

```bit
fn shorthandLiteral() {
  let name = "Ada"
  let age = 30
  let a = User{ name, age }         // shorthand for User{ name: name, age: age }
  let b = User{ age: 42, name }     // shorthand and keyed mix; order irrelevant
}
```

There is still no positional form - `User{ 30, "Ada" }` is rejected, shorthand
or not:

```bit ignore
let bad = User{ 30, "Ada" }   // rejected - a bare value never means a position
```

`bit fmt` preserves the shorthand exactly as written; it never expands
`User{ name }` to `User{ name: name }`.

## Fields that are themselves a class

A class field whose own type is a class has no zero value, so it **must** be
given a value - a null handle would be a `nil` written into a slot that
promises a live object.

```bit ignore
class Inner { xs: []u32 }
class Outer { a: int, b: Inner }

let bad = Outer{ a: 1 }              // E0083 - `b` omitted
let alsoBad: Outer                   // E0083 - no initializer
let orThis = []Outer(2)              // E0083 - `[]T(n)` means n zero values
let good = Outer{ a: 1, b: Inner{} } // fine; `Inner` has no class-typed field
let empty = []Outer(0)               // fine; asks for no zero values
```

Every other field type stays omittable, including an inline `[N]T`, because
their zero value really is zero bits.

The same fact rules out a **cycle** of class-typed fields, at any length -
there is no way to build one, because every step obliges another:

```bit ignore
class Node { v: int, next: Node }   // E0047 - one hop
class A { b: B }                    // E0047 - A -> B -> A
class B { a: A }
```

The layout would be fine - a class field is one handle, so nothing here is
infinitely large. It is that no value of the type exists to write. Break the
cycle with any type that has an empty or `nil` state; `Option<T>` is the
idiomatic one:

```bit
class ListNode { v: int, next: Option<ListNode> }   // linked list
class TreeNode { v: int, kids: []TreeNode }         // a slice terminates too
class TrieNode { next: map<rune, TrieNode> }        // and so does a map
```

A map whose value type is such a class is still fine to build, insert into,
iterate and delete from. Only reading a **missing** key needs a zero value, so
that one read panics - the two-result form, which exists to ask whether a key
is there, does not:

```bit ignore
let m = map<int, Outer>{}
m[1] = Outer{ a: 1, b: Inner{} }   // fine
let good = m[1]                    // fine - the key is there
let (v, ok) = m[7]                 // fine - ok is false, do not read v
let bad = m[7]                     // panics: 'Outer' has no zero value
```

## Methods {#methods}

A method is a function with a receiver written before its name. The receiver
type must be a class or type alias declared in the same module. Because
classes are reference types (see [above](#reference-type)), a method that
mutates a field mutates the caller's value directly - there is no pointer
receiver syntax to opt into that.

```bit
class Counter { n: int }

fn (c: Counter) increment() {
  c.n += 1                     // mutates the caller's Counter
}

fn (c: Counter) value(): int {
  return c.n
}

fn useCounter() {
  let c = Counter{ n: 0 }
  c.increment()
  let v = c.value()            // 1
}
```

Export a method the same way as a function, by placing `export` before its
`fn` keyword (see [Modules](modules.md#visibility-with-export)).

## Interfaces

A class satisfies an interface automatically once it has all of the
interface's methods with matching signatures - there is no `implements`
clause to write. See [Interfaces](interfaces.md) for structural satisfaction,
type assertions, and comparing interface values.

## Comparability {#comparability}

Two class values compare with `==`/`!=` **field-wise**, not by handle: two
separately built values with equal fields are equal, even though assignment
between them would have shared a handle instead of copying one.

```bit
class Money { cents: int }

fn comparableMoney() {
  let a = Money{ cents: 500 }
  let b = Money{ cents: 500 }
  let sameFields = a == b        // true - fields compare equal
  let alias = a
  let sameHandle = a == alias    // also true, but for the same reason
}
```

A class is comparable only if every field is; a class holding a slice, a map,
or a function value is not. See
[Comparability](types.md#comparability) for the rule across every type, not
just classes.
