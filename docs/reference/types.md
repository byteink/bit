# Types

<!-- doctest: per-block -->

Every value has a type. `map<string, string>` on [Variables](variables.md) is
a type itself: a hash table keyed by one type, holding another.

## Strings and interpolation

```bit
fn main() {
  let title = "Notes on Bit"
  let author = "Ada"
  println("${title} by ${author}")
}
```

`string` is immutable UTF-8 text. An interpreted string (double-quoted) can
embed an expression with `${ ... }`; the result is converted to text and
spliced in. Interpolation works on any primitive and on anything with a
`show(): string` method; interpolating a value with no obvious text form,
like a slice or a map itself, is a compile error, not a runtime surprise.

## Maps {#maps}

`map<K, V>` needs a `K` you can compare with `==`. Build one empty, or with
values already in it:

```bit
fn main() {
  let empty = map<string, string>()
  let seeded = map<string, string>{ "draft-1": "Notes on Bit" }
  let title = seeded["draft-1"]   // "Notes on Bit"
  let miss = seeded["missing"]    // "" - the zero value, not an error
  let (v, ok) = seeded["missing"] // ok is false: tells "" apart from missing
  println("${title} ${miss} ${ok}")
}
```

A map is a reference type: assigning it, or passing it to a function, shares
the same underlying table rather than copying it.

```bit
fn setTitle(titles: map<string, string>, id: string, title: string) {
  titles[id] = title // mutates the caller's map, no return value needed
}
```

## Primitive types

- Signed integers: `i8 i16 i32 i64`; unsigned: `u8 u16 u32 u64`
- Floats: `f32 f64` (IEEE-754)
- `bool` - `true` or `false`
- `string` - immutable UTF-8; indexing yields a `byte`, `len(s)` is byte length
- Aliases: `int` = `i64`, `uint` = `u64`, `byte` = `u8`, `rune` = `i32`

```bit
fn main() {
  let a: i32 = 42
  let b: u8 = 255
  let c: f64 = 3.14
  println("${a} ${b} ${c}")
}
```

## Slices, arrays, tuples

Slices `[]T` (growable), arrays `[N]T` (fixed length, copied on assignment),
and tuples `(T1, T2, ...)` (grouped returns):

```bit
fn main() {
  let tags = []string{ "bit", "notes" } // slice literal
  let zeros = []int(4)                  // length 4, all zero
  let fixed = [3]int{ 1, 2, 3 }         // array: value type, copied
  println("${len(tags)} tag(s), ${len(zeros)} zero(s), ${fixed[0]} first")
}
```

## Conversions

There are no implicit numeric conversions, not even widening. Convert
explicitly with a type in call position:

```bit
fn main() {
  let n: i32 = 5
  let wide = i64(n)        // explicit widening, required
  let bytes = []byte("hi") // string -> []byte (copy)
  let back = string(bytes) // []byte -> string (copy)
  println("${wide} ${back}")
}
```

## Value vs. reference semantics

| Category | Types | On assignment / passing |
| -------- | ----- | ------------------------ |
| Value | numbers, `bool`, arrays, tuples | deep copy |
| Reference | `string`, slices, `map<K,V>`, classes, functions | copy of the reference (shared data) |

`string` is a reference type but deeply immutable, so sharing it is never
observable.

## Comparability

Numbers, `bool`, `string` and `rune` compare with `==`/`!=`; numbers and
strings also order with `< <= > >=`. Slices and maps compare only against
`nil`. A map key must be a comparable type.

## Next

A `map<string, string>` can only hold a title per id. [Classes](classes.md)
gives a draft a shape of its own.
