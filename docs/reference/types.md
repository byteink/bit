# Types

Bit is statically typed with strong inference. Types are compared
**structurally**, not by name: two types are identical when their shape matches
(§14.1). This chapter covers the built-in types, literals, composites, structs,
conversions, and operators. (Spec: §5.4–§5.8, §11, §12.2–§12.9, §13.3, §14.)

## Primitive types

- Signed integers: `i8 i16 i32 i64`
- Unsigned integers: `u8 u16 u32 u64`
- Floats: `f32 f64` (IEEE-754)
- `bool` - `true` or `false`
- `string` - immutable UTF-8; indexing yields a `byte`, `len(s)` is byte length
- Aliases: `int` = `i64`, `uint` = `u64`, `byte` = `u8`, `rune` = `i32`

Sizes are fixed on every target, so behavior is deterministic across platforms.

```bit
fn primitives() {
  let a: i32 = 42
  let b: u8 = 255
  let c: f64 = 3.14
  let ok: bool = true
  let s: string = "héllo"     // UTF-8; len(s) counts bytes
}
```

## Literals

```bit
fn literals() {
  let dec = 1_000_000         // '_' separates digit groups
  let hex = 0xFF
  let oct = 0o755
  let bin = 0b1010
  let f = 6.022e23            // float needs '.', exponent, or 'p' for hex
  let r = 'A'                 // rune literal, type rune (i32)
  let esc = '\n'              // escapes: \n \r \t \\ \' \" \0 \xNN \u{...}
  let str = "line\ttab"       // interpreted string, escapes allowed
  let raw = `no \n escapes
spans lines`                  // raw string, verbatim bytes
  let nothing = nil           // zero value of any reference type
}
```

### String interpolation

An interpreted string embeds expressions with `${ ... }`; the value is converted
to `string`. Any type implementing `interface Show { show(): string }` works, as
do all primitives. Write `\$` for a literal dollar sign.

There is no universal `toString`: interpolating anything else - a slice, a map, a
channel, a function value, an `error`, or a struct/interface without `show` - is a
compile error (`E0073`). Interpolate a field, an element, or the result of a
method instead, or give the type a `show(): string` method.

```bit
fn greet(name: string, n: int) {
  println("hi ${name}, you have ${n} messages")
}
```

## Composite types

### Slices `[]T`

A growable reference view over a backing array. Build with a literal, or
allocate a zeroed slice with the constructor form.

```bit
fn slices() {
  let xs = []int{1, 2, 3}     // typed slice literal
  let ys = [4, 5, 6]          // bare list; element type inferred from context
  let zeros = []int(4)        // length 4, all zero
  let cap5 = []int(2, 5)      // length 2, capacity 5
  let head = xs[0:2]          // slicing; lo defaults to 0, hi to len
  let n = len(xs)
}
```

### Arrays `[N]T`

Fixed length `N`, a **value type** copied on assignment.

```bit
fn arrays() {
  let a = [3]int{1, 2, 3}     // length must match N
  let b: [4]bool              // zeroed: all false
}
```

### Maps `map<K,V>`

Hash map, reference type; `K` must be comparable. A missing key reads as the
zero value of `V`; the two-result index form reports presence.

```bit
fn maps() {
  let m = map<string, int>{ "a": 1, "b": 2 }
  let empty = map<string, int>()
  let x = m["a"]              // 1
  let missing = m["z"]        // 0 (zero value), no error
  let (v, ok) = m["z"]        // ok is false
}
```

### Tuples `(T1, T2, ...)`

Fixed heterogeneous group, a value type, used for grouped returns and
destructuring. Access by destructuring or by index `.0`, `.1`, …

```bit ignore
fn tuples(): (int, string) {
  let pair = (1, "one")
  let first = pair.0
  let second = pair.1
  return first, second
}
```

> Tuples are specified (§11.2) but not yet implemented; this block is not
> doc-tested.

### Function and channel types

```bit
fn higherOrder(f: (int) => int, x: int): int {
  return f(x)
}

fn makeChan(): chan<int> {
  return chan<int>()
}
```

## Structs

A struct groups named fields. Structs are **reference types** (like TypeScript
objects): assigning one copies the handle, and mutations are visible through
both. Fields marked `export` are visible outside the module (see
[Modules](modules.md)).

```bit
struct Point { x: f64; y: f64 }

struct User {
  export name: string    // visible to other modules
  age: int               // module-private
}

fn structs() {
  let p = Point{ x: 1.0, y: 2.0 }   // keyed literal, always type-prefixed
  let q = Point{ x: 3.0 }           // y omitted -> zero value 0.0
  let shared = p                    // copies the handle
  shared.x = 9.0                    // p.x is now 9.0 too (reference semantics)
}
```

Reference semantics have one consequence worth knowing up front: a struct field
whose own type is a struct **must** be given a value. It has no zero value,
because zero bits in a reference field is a null, not a live instance.

```bit ignore
struct Inner { xs: []u32 }
struct Outer { a: int, b: Inner }

let bad = Outer{ a: 1 }              // E0083 - `b` omitted
let alsoBad: Outer                   // E0083 - no initializer
let orThis = []Outer(2)              // E0083 - `[]T(n)` means n zero values
let good = Outer{ a: 1, b: Inner{} } // fine; `Inner` has no struct-typed field
let empty = []Outer(0)               // fine; asks for no zero values
```

Every other field type stays omittable, including an inline `[N]T`, because
their zero value really is zero bits.

The same fact rules out a **cycle** of struct-typed fields, at any length. There
is no way to build one, because every step obliges another:

```bit ignore
struct Node { v: int, next: Node }   // E0047 - one hop
struct A { b: B }                    // E0047 - A -> B -> A
struct B { a: A }
```

The layout would be fine (a struct field is one handle, so nothing here is
infinitely large). It is that no value of the type exists to write. Break the
cycle with any type that has an empty or `nil` state - `Option<T>` is the
idiomatic one:

```bit
struct ListNode { v: int, next: Option<ListNode> }   // linked list
struct TreeNode { v: int, kids: []TreeNode }         // a slice terminates too
struct TrieNode { next: map<rune, TrieNode> }        // and so does a map
```

A map whose value type is such a struct is still fine to build, insert into,
iterate and delete from. Only reading a **missing** key needs a zero value, so
that one read panics - and the two-result form, which exists to ask whether a
key is there, does not:

```bit ignore
let m = map<int, Outer>{}
m[1] = Outer{ a: 1, b: Inner{} }   // fine
let good = m[1]                    // fine - the key is there
let (v, ok) = m[7]                 // fine - ok is false, do not read v
let bad = m[7]                     // panics: 'Outer' has no zero value
```

Methods attach behavior to a struct; see [Functions](functions.md#methods).

## Type aliases

`type` introduces another spelling for a type. Aliases are **transparent** - the
alias and its target are the same type (there are no nominal newtypes in v0.1).

```bit
type Celsius = f64
type IntPair = (int, int)
type Transform = (int) => int

fn freezing(): Celsius {
  return 0.0            // Celsius and f64 are identical types
}
```

## Conversions {#conversions}

There are **no implicit numeric conversions** (not even widening). Convert
explicitly by using a type in call position. Untyped constant literals are the
only values that adapt to context automatically (§15.4).

```bit
fn conversions() {
  let n: i32 = 5
  let wide = i64(n)          // explicit widening, required
  let f = f64(n)             // int -> float
  let bytes = []byte("hi")   // string -> []byte (copy)
  let back = string(bytes)   // []byte -> string (copy)
  // let s = string('A')     // rune -> string: needs UTF-8 encoding, not yet

  let big: u8 = 200          // ok: untyped constant, representable in u8
  // let bad: u8 = 300       // error: 300 not representable in u8
}
```

## Operators and precedence

All binary operators are left-associative. Highest to lowest:

| Level | Operators | Kind |
| ----- | --------- | ---- |
| postfix | `f(...)` `a[i]` `a[lo:hi]` `a.b` `x?` | primary/postfix |
| unary | `!x` `-x` `+x` `~x` `<-c` | prefix |
| multiplicative | `* / % << >> &` | |
| additive | `+ - \| ^` | |
| comparison | `== != < <= > >=` | |
| logical and | `&&` | short-circuits |
| logical or | `\|\|` | short-circuits |

`&`, `|`, `^`, `~` are bitwise; `&&`, `||`, `!` are logical. There is no ternary
`?:` (use an `if`) and no address-of operator (Bit has no pointers). `?` is
error propagation, `<-` is channel send/receive (see [Errors](errors.md) and
[Concurrency](concurrency.md)).

```bit
fn operators(a: int, b: int): int {
  let masked = a & 0xFF
  let shifted = a << 2
  let ok = a > 0 && b > 0     // short-circuits
  return masked + shifted
}
```

## Arithmetic and overflow

- Unsigned arithmetic is modular (wraps).
- Signed overflow **wraps** (two's complement) in v0.1 — there is no build-mode
  flag. A debug build mode that traps on signed overflow instead is specified
  but not yet implemented (see [SPEC.md §13.5](../../spec/SPEC.md), task #3076).
- Integer divide or remainder by zero **panics**.
- Float division by zero yields ±∞ or NaN (no panic).
- Shift counts are taken modulo the operand's bit width.

## Value vs reference semantics

| Category | Types | On assignment / passing |
| -------- | ----- | ----------------------- |
| Value | numbers, `bool`, arrays `[N]T`, tuples | deep copy |
| Reference | `string`, slices `[]T`, `map<K,V>`, structs, interfaces, `chan<T>`, functions | copy of the reference (shared data) |

`string` is a reference type but deeply immutable, so sharing is unobservable.
The zero value of every reference type is `nil`.

## Memory management

Bit is **garbage collected** by a tracing collector linked into every binary.
There is no manual `free`, no use-after-free, and no double-free. Allocation is
implicit - composite literals, constructors, closures, `append` growth, and
boxing an interface value all allocate. Every reachable object stays live and
unreachable objects are eventually reclaimed; object identity is stable for the
object's lifetime. There are no finalizers in v0.1 - use `defer` (see
[Errors](errors.md#deferred-cleanup-with-defer)) for deterministic cleanup.

## Comparability

- Numbers, `bool`, `string`, `rune` compare with `==`/`!=`; numbers and strings
  also order with `< <= > >=`.
- Arrays, tuples, and structs are comparable if all their elements/fields are.
- Slices, maps, and functions compare only against `nil`.
- Map keys must be a comparable type, or it is a compile error.
