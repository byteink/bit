# Classes

A class groups named fields under one type name and gives them behavior with
methods declared in the class body. (Spec: §10.4, §10.5, §12.2, §13.3, §13.4,
§14.6.)

## A class is a reference type {#reference-type}

This is the one fact that drives everything else in this chapter, so it comes
first rather than being left for an example to reveal: **a class is
heap-allocated, and assigning a class value copies the handle, not the
fields.** That is reference semantics, like a TypeScript or Java object -
unlike a Go or C `struct`, which copies its fields on assignment.

```bit
class Point { x: f64, y: f64 }

fn classes() {
  let p = Point{ x: 1.0, y: 2.0 } // keyed literal, always type-prefixed
  let q = Point{ x: 3.0 }         // y omitted -> zero value 0.0
  let shared = p                  // copies the handle, not the fields
  shared.x = 9.0                  // p.x is now 9.0 too - same object
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
  export name: string, // visible to other modules
  age: int,            // module-private
}
```

- A field marked `export` is visible outside the module; an unmarked field is
  module-private. Export the class itself with `export class User { ... }` -
  see [Modules](modules.md#visibility-with-export) for the full visibility
  model, including exporting a method.
- Fields are ordered; that order is the memory layout order (subject to the
  compiler's alignment padding).

## Default field values {#field-defaults}

A field may declare a default. It is used wherever the field is not given a
value, so a config class can ship the answer it wants rather than the answer
zero happens to be.

```bit
const kb = 1024

class Opts {
  port: int = 8080,
  host: string = "127.0.0.1",
  maxBody: int = 1000 * kb,
  tls: bool,
}

fn defaults(): int {
  let a = Opts{}             // port 8080, host "127.0.0.1", maxBody 1024000
  let b = Opts{ port: 3000 } // port 3000, the rest still defaulted
  return a.port + b.port
}
```

Every way of building the value agrees on the default, not just the composite
literal: `[]Opts(n)`, a bare `let p: Opts`, a map lookup that misses, and the
object an `init` starts from all carry it. A default is part of the type's zero
value, so a field declared once cannot mean two different things depending on
how the value was made.

The initializer is a **constant expression**, folded at compile time. It may
name a module-level `const`, including one imported from another module, and it
is evaluated where the field is declared - so a class can be declared in one
module and built with `Opts{}` in another. Because it is constant there is no
allocation and no ordering between fields, and a defaulted field costs exactly
what a spelled one costs at the construction site.

An initializer that is not constant is rejected:

```bit ignore
fn readPort(): int { return 8080 }

class Bad {
  port: int = readPort(), // E0064 - not a compile-time constant
}
```

A field whose own type is a class cannot have a default, because no class value
is a constant expression - see [Fields that are themselves a
class](#fields-that-are-themselves-a-class) below, whose rule this does not
change. Trait fields ([Traits](traits.md)) carry no default either.

## Field attributes {#field-attributes}

A field may carry attributes, written above it one per line. **An attribute is
sugar for a call to an ordinary fallible function**, found by ordinary name
lookup. The attribute name is the function name, the field's value is the first
argument, and the attribute's own arguments follow.

```bit
class lengthError {
  text: string
  message(): string { return this.text }
}

fn min(s: string, n: int): ()! {
  if (len(s) < n) {
    fail lengthError{ text: "too short" }
  }
}

fn max(s: string, n: int): ()! {
  if (len(s) > n) {
    fail lengthError{ text: "too long" }
  }
}

class NewUser {
  @min(3)
  @max(200)
  name: string
}
```

`@min(3)` on `name` means `min(this.name, 3)?`. Because any class with at least
one attributed field gets a synthesized member

```bit ignore
validateFields(): ()!
```

running those calls in declaration order, checking a value is one call:

```bit
fn check(u: NewUser): ()! {
  u.validateFields()?
}
```

The calls run fields top to bottom, attributes top to bottom within a field,
each propagating with `?` - so the first failure is the one you get.
`validateFields` is an ordinary exported member: callable from another module,
testable, and listed by `bit doc`.

There is **no registry and no plugin hook**. Any module that exports
`fn iban(s: string): ()!` makes `@iban` work wherever it is imported, with no
compiler change, and a misspelled `@emial` is the ordinary "undefined name"
error.

### The function an attribute names

It must be `fn name(v: T, ...): ()!`:

- **fallible** - an attribute reports by failing (`E0133` otherwise);
- **yielding unit** - its value is discarded (`E0134` otherwise);
- its **first parameter** must take the field's type (`E0135` otherwise).

Arguments are constant expressions, the same restriction a
[default value](#field-defaults) carries.

### `validateFields` is not `validate`

The name is deliberate. Cross-field rules - "B is required only when A is set" -
cannot be expressed as a per-field attribute, so they go in a hand-written
`validate()`, and the two are meant to compose:

```bit
class Signup {
  @min(3)
  name: string

  password: string
  confirm: string

  validate(): ()! {
    if (this.password != this.confirm) {
      fail lengthError{ text: "passwords differ" }
    }
  }
}

fn checkSignup(s: Signup): ()! {
  s.validateFields()?
  s.validate()?
}
```

A class that declares `validateFields` itself is an error naming both (`E0132`)
- one name, one definition.

### Where attributes are not allowed

Attributes on a class **method** are rejected (`E0131`): a method has no value
to pass. Trait fields ([Traits](traits.md)) carry none.

Function attributes (`@naked`, `@nosplit`, `@symbol`) are a different feature
that shares the spelling. Those three are compiler-known, are never resolved
through name lookup, and any other name on a `fn` is an error - there is no
function called `naked` anywhere. Field attributes are the exact opposite: the
compiler knows none of them by name.

`@key` is the one exception on the field side, and it is there because JSON
keys are data rather than behaviour - see [`@json`](#json) below.

## `@json` - a generated `toJson` {#json}

Mark a class `@json` and the compiler synthesises `toJson(): Json` from its
fields, so `jsonEncode(u.toJson())` works with no hand-written mapper and
adding a field updates the output automatically.

```bit
import { Json, JsonEntry, jsonEncode } from "std/json"

@json class Addr {
  city: string,
}

@json class Profile {
  id: i64
  name: string
  active: bool
  tags: []string
  nick: Option<string>
  @key("created_at")
  createdAt: string
  addr: Addr
}

fn encodeProfile(u: Profile): string {
  return jsonEncode(u.toJson())
}
```

The key is **the field name exactly as written** - `isAdmin` is `"isAdmin"`.
There is no case conversion, so the class and the payload read the same and
nobody translates between two spellings while debugging. `@key("...")` sets a
different key for an API that demands one; it takes exactly one string, and
none, two, or a non-string is an error naming the attribute and the field
(`E0140`) rather than a silent fallback.

The module has to import `Json` and `JsonEntry` from `"std/json"` - the
generated member is written in terms of both - and without them the class is
`E0142`, which names the import to add.

### What a field may be

A scalar, `string`, `bool`, `[]T`, `map<string, T>`, `Option<T>`, or a nested
class that itself carries `@json`. Inside those three containers `T` must be
one of the simple shapes or a nested `@json` class, never another container.
Anything else is `E0141`, naming the field and its type.

`@json` is refused on a generic class (`E0144`): the compiler decides each
field's shape from its written type, and a type parameter has none.

**An absent `Option<T>` emits its key with an explicit `null`.** It is not
omitted: a missing key and an explicit null are different to a client, and
choosing silently between them is how clients break.

### The mark is the consent

A class without `@json` has no `toJson` at all. That is the point: a generated
member on every class would expose a field the day someone adds one to an
internal type.

For the same reason `@json` never recurses into a class that did not opt in -
a field whose type is an unmarked class is `E0141`, naming both.

And a class carrying `@json` that also declares `toJson` itself is `E0138`,
naming both. If you want different output, declare a second class:

```bit
@json class Account {
  id: i64,
  email: string,
  pwHash: string,
}

@json class AccountView {
  id: i64,
  email: string,
}
```

That is strictly better than a custom `toJson` on `Account`, because a
generated one would ship `pwHash` the day someone added it - and the view
class says out loud which fields go over the wire.

### Reading it back

`jsonDecode<T>` is the other half. The compiler specialises it per call from the
same field list `@json` serializes, so the two agree by construction:

```bit
import { jsonParse, jsonDecode } from "std/json"

fn loadProfile(body: string): Profile! {
  return jsonDecode<Profile>(jsonParse(body)?)?
}
```

`T` has to be a class carrying `@json`; anything else is `E0145` at compile
time, naming the type and the mark, so an unspecialised call can never reach
run time.

**Every failure names the field, by its full path from the root** -
`addr.city`, `tags[3]` - and says which of four things went wrong: a missing
key for a field that is not an `Option`, a type mismatch naming what was
expected and what was found, an **unknown key** in the input, or nesting past
the decode depth bound. The error is a `JsonDecodeError`, whose `cause` is an
enum a caller can branch on rather than a string it has to scrape.

**An unknown key is reported, not ignored.** A dropped field and an accepted
field look identical to whoever sent the document, so the caller is told and
decides.

A key that is absent and a key present as `null` both decode an `Option<T>` to
`None`, and both are a missing key for a field that is not one. That is what
makes the round trip hold: `@json` writes an absent `Option` as an explicit
`null`, and a producer that omits the key instead still decodes.

The walk is **depth-bounded**. A `@json` class may be self-referential, so how
deep a decode recurses is decided by the input, not by the class - past the
bound it fails with the depth cause instead of exhausting the stack. The bound
is on the `Json` value, independent of any limit a parser applied: `jsonDecode`
takes a value, and one built in code never went through a parser at all.

## Readonly fields {#readonly-fields}

A field marked `readonly` may be set only in a composite literal, or inside
the declaring class's own `init` (SPEC §10.4) - any other assignment is
rejected, including from code in the class's own declaring module.

```bit
class Timestamp {
  export readonly ns: int,
}

class Sample {
  export readonly n: int

  init(start: int) {
    this.n = start // allowed: readonly is assignable inside its own 'init'
  }
}

fn buildReadonly() {
  let t = Timestamp{ ns: 5 }
  print("${t.ns}\n") // 5

  let s = Sample(9)
  print("${s.n}\n") // 9
}
```

```bit ignore
t.ns = 0 // rejected: E0114 - 'readonly' forbids reassigning the field
```

`readonly` is orthogonal to `export` - an unexported `readonly` field is
legal and meaningful, and stops even the declaring module from reassigning
it.

### `readonly` is shallow

`readonly` forbids reassigning the field itself; it says nothing about the
value that field refers to. On a class-typed field this is Java's `final` or
TypeScript's `readonly`:

```bit
class Box { export x: int }
class Wrapper { export readonly inner: Box }

fn mutateThroughReadonly() {
  let w = Wrapper{ inner: Box{ x: 1 } }
  w.inner.x = 99          // fine - mutates the Box 'inner' refers to, not 'inner' itself
  print("${w.inner.x}\n") // 99
}
```

Only `w.inner = anotherBox` is rejected. `w.inner.x = 99` reassigns a field
of the `Box` that `inner` refers to, not `inner` itself, so it is
unaffected.

## Composite literals {#composite-literals}

A class literal is **always** prefixed by its type name -
`Point{ x: 1.0, y: 2.0 }`, never a bare `{ ... }`. This is what removes the
block-versus-literal ambiguity: a `{` in statement position is always a block,
never a class literal. Fields are keyed and order-independent; any field left
out of a literal takes its [default value](#field-defaults) if it declares one,
and otherwise its type's zero value.

```bit
fn composite() {
  let a = User{ age: 30, name: "Ada" } // keyed - order doesn't matter
  let b = User{ name: "Grace" }        // age omitted -> zero value 0
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
  let a = User{ name, age }     // shorthand for User{ name: name, age: age }
  let b = User{ age: 42, name } // shorthand and keyed mix; order irrelevant
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
class ListNode { v: int, next: Option<ListNode> } // linked list
class TreeNode { v: int, kids: []TreeNode }       // a slice terminates too
class TrieNode { next: map<rune, TrieNode> }      // and so does a map
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

A method is a function attached to a class, declared **in the class body**
with the reserved receiver `this`:

```bit
class Counter {
  n: int

  bump(): int {
    this.n = this.n + 1
    return this.n
  }

  export doubled(): int {
    return this.n * 2
  }
}

fn useCounter() {
  let c = Counter{ n: 5 }
  let a = c.bump()    // 6, and c.n is now 6
  let b = c.doubled() // 12
}
```

- `this` is implicit - it never appears in the parameter list or the
  signature - and is typed as the enclosing class, `Counter` here.
- The receiver type must be a class or type alias declared in the **same
  module**: a method can only be added to a locally-declared type, never to a
  foreign or a builtin one.
- Because classes are reference types (see [above](#reference-type)), a
  method that mutates a field through `this` mutates the caller's value
  directly - there is no pointer-receiver syntax to opt into that. `bump()`
  above changes `c.n` for every reference to `c`, not a copy.
- `export` goes right before the method name, exactly like on a field (see
  [Modules](modules.md#visibility-with-export)). An unexported method, like
  `bump()` above, is callable only from code in the same module.
- A method may declare its own generic parameters (`scaled<T>(...)`),
  independently of any the class itself declares.
- Methods participate in structural interface satisfaction (§14.3) the same
  way regardless of form - see [Interfaces](interfaces.md).

### The removed explicit-receiver form

Before 0.2.0, Bit also supported an older form, written with the receiver
before the method name instead of inside the class body:

```bit ignore
fn (c: Counter) bump(): int {
  c.n = c.n + 1
  return c.n
}
```

This declared the same method as the in-body `bump()` above, and shared
every rule listed there - visibility, the restriction to the receiver's own
module, and reference-mutation behavior. It predated the in-body form and
was removed in 0.2.0: the compiler now rejects it with `error[E0103]`. Write
methods in the class body as shown above.

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
  let sameFields = a == b // true - fields compare equal
  let alias = a
  let sameHandle = a == alias // also true, but for the same reason
}
```

A class is comparable only if every field is; a class holding a slice, a map,
or a function value is not. See
[Comparability](types.md#comparability) for the rule across every type, not
just classes.
