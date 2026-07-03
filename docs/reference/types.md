# Types

Bit is statically typed with strong inference. Types are compared
**structurally**, not by name: two types are identical when their shape matches
(§14.1). This chapter covers the built-in types, literals, composites, structs,
conversions, and operators. (Spec: §5.4–§5.8, §11, §12.2–§12.9, §13.3, §14.)

## Primitive types

- Signed integers: `i8 i16 i32 i64`
- Unsigned integers: `u8 u16 u32 u64`
- Floats: `f32 f64` (IEEE-754)
- `bool` — `true` or `false`
- `string` — immutable UTF-8; indexing yields a `byte`, `len(s)` is byte length
- Aliases: `int` = `i64`, `uint` = `u64`, `byte` = `u8`, `rune` = `i32`

Sizes are fixed on every target, so behavior is deterministic across platforms.

```bit
function primitives() {
  let a: i32 = 42
  let b: u8 = 255
  let c: f64 = 3.14
  let ok: bool = true
  let s: string = "héllo"     // UTF-8; len(s) counts bytes
}
```

## Literals

```bit
function literals() {
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

```bit
import { println } from "std/io"

function greet(name: string, n: int) {
  println("hi ${name}, you have ${n} messages")
}
```

## Composite types

### Slices `[]T`

A growable reference view over a backing array. Build with a literal, or
allocate a zeroed slice with the constructor form.

```bit
function slices() {
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
function arrays() {
  let a = [3]int{1, 2, 3}     // length must match N
  let b: [4]bool              // zeroed: all false
}
```

### Maps `map<K,V>`

Hash map, reference type; `K` must be comparable. A missing key reads as the
zero value of `V`; the two-result index form reports presence.

```bit
function maps() {
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

```bit
function tuples(): (int, string) {
  let pair = (1, "one")
  let first = pair.0
  let second = pair.1
  return first, second
}
```

### Function and channel types

```bit
function higherOrder(f: (int) => int, x: int): int {
  return f(x)
}

function makeChan(): chan<int> {
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

function structs() {
  let p = Point{ x: 1.0, y: 2.0 }   // keyed literal, always type-prefixed
  let q = Point{ x: 3.0 }           // y omitted -> zero value 0.0
  let shared = p                    // copies the handle
  shared.x = 9.0                    // p.x is now 9.0 too (reference semantics)
}
```

Methods attach behavior to a struct; see [Functions](functions.md#methods).

## Type aliases

`type` introduces another spelling for a type. Aliases are **transparent** — the
alias and its target are the same type (there are no nominal newtypes in v0.1).

```bit
type Celsius = f64
type IntPair = (int, int)
type Transform = (int) => int

function freezing(): Celsius {
  return 0.0            // Celsius and f64 are identical types
}
```

## Conversions {#conversions}

There are **no implicit numeric conversions** (not even widening). Convert
explicitly by using a type in call position. Untyped constant literals are the
only values that adapt to context automatically (§15.4).

```bit
function conversions() {
  let n: i32 = 5
  let wide = i64(n)          // explicit widening, required
  let f = f64(n)             // int -> float
  let s = string('A')        // rune -> string
  let bytes = []byte("hi")   // string -> []byte (copy)
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
function operators(a: int, b: int): int {
  let masked = a & 0xFF
  let shifted = a << 2
  let ok = a > 0 && b > 0     // short-circuits
  return masked + shifted
}
```

## Arithmetic and overflow

- Unsigned arithmetic is modular (wraps).
- Signed overflow **traps in debug builds** and **wraps** (two's complement) in
  release builds — deterministic either way.
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
implicit — composite literals, constructors, closures, `append` growth, and
boxing an interface value all allocate. Every reachable object stays live and
unreachable objects are eventually reclaimed; object identity is stable for the
object's lifetime. There are no finalizers in v0.1 — use `defer` (see
[Errors](errors.md#deferred-cleanup-with-defer)) for deterministic cleanup.

## Comparability

- Numbers, `bool`, `string`, `rune` compare with `==`/`!=`; numbers and strings
  also order with `< <= > >=`.
- Arrays, tuples, and structs are comparable if all their elements/fields are.
- Slices, maps, and functions compare only against `nil`.
- Map keys must be a comparable type, or it is a compile error.
