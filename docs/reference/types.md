# Types

The shortener's map needed two things spelled out: what a code looks like
and what a URL looks like. Both, for now, are `string`. And `map<string,
string>` itself is a type: a hash table keyed by one type, holding another.

## Strings

```bit
fn shorten() {
  let links = map<string, string>()
  links["abc123"] = "https://example.com"
  println("abc123 -> ${links["abc123"]}")
}
```

`string` in Bit is immutable UTF-8 text. `"abc123"` and
`"https://example.com"` are string literals. The interesting part is
`"abc123 -> ${links["abc123"]}"`: an interpreted string can embed an
expression with `${ ... }`, and the result is converted to text and spliced
in. This is **string interpolation**, and it is how the shortener prints its
first result without gluing pieces together by hand.

```bit
fn greetLink(code: string, url: string) {
  println("code ${code} points to ${url}")
}
```

Interpolation works on any primitive, and on anything that implements
`interface Show { show(): string }` (see [Classes](classes.md)). Interpolating
something with no obvious text form, like a slice or a map itself, is a
compile error, not a runtime surprise:

```bit ignore
let m = map<string, string>()
println("${m}") // error[E0073]: cannot interpolate a value of type 'map<string, string>'
```

Interpolate a field or an element instead, the way `links["abc123"]` does
above.

## Maps {#maps}

`map<K, V>` is a hash map: `K` has to be a type you can compare with `==`,
`string` here. Build one empty and fill it in, or build it with values
already in it:

```bit
fn mapBasics() {
  let empty = map<string, string>()
  let seeded = map<string, string>{ "abc123": "https://example.com" }
  let url = seeded["abc123"]     // "https://example.com"
  let miss = seeded["zzz999"]    // "" - the zero value, not an error
  let (v, ok) = seeded["zzz999"] // ok is false: this is how you tell "" from missing
}
```

A map is a reference type: assigning it to another variable, or passing it
into a function, shares the same underlying table rather than copying it.

```bit
fn addLink(links: map<string, string>, code: string, url: string) {
  links[code] = url // mutates the caller's map, no return value needed
}

fn buildLinks() {
  let links = map<string, string>()
  addLink(links, "abc123", "https://example.com")
  // links now has the entry addLink added
}
```

## Sharp edge: the zero value hides a missing key

Because a missed lookup returns `""` instead of failing, code that only
checks `if (links[code] != "")` cannot tell "no such code" from "this code's
URL happens to be empty". Use the two-result form, `let (v, ok) = links[code]`,
whenever that distinction matters; the plain form is for when you already
know the key is there.

## When not to use a bare map

A `map<string, string>` works as long as a link is just a URL. The moment a
link needs to carry more, when it was created, how many times it has been
visited, cramming those into the string value (say, comma-joined) is the
wrong move: nothing checks the shape, and every reader has to know the
convention. That is exactly the next step: see [Classes](classes.md).

## Reference: the rest of the type system

The shortener does not reach these yet. They are here for when it does.

### Primitive types

- Signed integers: `i8 i16 i32 i64`
- Unsigned integers: `u8 u16 u32 u64`
- Floats: `f32 f64` (IEEE-754)
- `bool` - `true` or `false`
- `string` - immutable UTF-8; indexing yields a `byte`, `len(s)` is byte length
- Aliases: `int` = `i64`, `uint` = `u64`, `byte` = `u8`, `rune` = `i32`

```bit
fn primitives() {
  let a: i32 = 42
  let b: u8 = 255
  let c: f64 = 3.14
  let ok: bool = true
}
```

### Other composite types

Slices `[]T` (growable), arrays `[N]T` (fixed length, copied on assignment),
and tuples `(T1, T2, ...)` (grouped returns) round out the built-in
composites:

```bit
fn slicesAndArrays() {
  let xs = []int{ 1, 2, 3 }     // slice literal
  let zeros = []int(4)          // length 4, all zero
  let fixed = [3]int{ 1, 2, 3 } // array: value type, copied on assignment
}
```

### Conversions

There are no implicit numeric conversions, not even widening. Convert
explicitly with a type in call position:

```bit
fn conversions() {
  let n: i32 = 5
  let wide = i64(n)        // explicit widening, required
  let bytes = []byte("hi") // string -> []byte (copy)
  let back = string(bytes) // []byte -> string (copy)
}
```

### Value vs reference semantics

| Category | Types | On assignment / passing |
| -------- | ----- | ------------------------ |
| Value | numbers, `bool`, arrays, tuples | deep copy |
| Reference | `string`, slices, `map<K,V>`, classes, functions | copy of the reference (shared data) |

`string` is a reference type but deeply immutable, so sharing it is never
observable.

### Comparability

Numbers, `bool`, `string` and `rune` compare with `==`/`!=`; numbers and
strings also order with `< <= > >=`. Slices and maps compare only against
`nil`. Map keys must be a comparable type.

### Specification

Bit's type system, its literals and its conversion rules are defined in the
language specification.

## Next

A `map<string, string>` can only hold a URL per code. The next step is giving
a link a shape of its own: read [Classes](classes.md).
