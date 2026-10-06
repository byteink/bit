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

## Enum variant names {#enum-variant-names}

Storing a `Status` in a database column, a config file or a JSON document
means writing its variant as text, and reading it back means knowing which
texts are valid. Bit has no reflection, so without help every enum would
need its own hand-written `match` returning each name. Every enum whose
variants all carry no payload gets three members from the compiler instead:

```bit
enum Status { Draft, Published, Archived }

fn main() {
  let s = Status.Published
  println(s.__variantName())                     // Published
  println(Status.__variants().join(", "))        // Draft, Published, Archived
  println(Status.__variantAt(2).__variantName()) // Archived
}
```

`__variantName(): string` is an instance method that returns the variant's
identifier exactly as written. `static __variants(): []string` lists every
variant name in declaration order, and needs no value of the enum.
`static __variantAt(i: int): Status` goes the other way: it returns the
variant at index `i` of that same order, so a name found in `__variants()`
becomes a value again. An index outside `0..N-1` panics with a message naming
the enum and the index.

A function generic over any such enum binds them through an interface, and
reads the names off the type parameter, or builds a value from one (`T(i)` is
not allowed through a type parameter, so `__variantAt` is the way in):

```bit
interface Named {
  static __variants(): []string,
  static __variantAt(i: int): Self,
  __variantName(): string,
}

enum Status { Draft, Published, Archived }

fn pick<T: Named>(i: int): T {
  return T.__variantAt(i)
}

fn isValid<T: Named>(text: string): bool {
  for name of T.__variants() {
    if (name == text) {
      return true
    }
  }
  return false
}

fn label<T: Named>(v: T): string {
  return "status=${v.__variantName()}"
}

fn main() {
  println("${isValid<Status>("Draft")} ${isValid<Status>("Deleted")}")
  println(label(Status.Archived))
  println(label(pick<Status>(0)))
}
```

The names are the stored form, so reordering the enum's variants changes
`__variants()` and which variant `__variantAt(i)` returns for a given `i`, but
never what `__variantName()` returns for a given variant.

A few edges:

- An enum with any payload variant (`Circle(f64)`), a generic enum and an
  enum with no variants get none of the members; calling one is the ordinary
  "no field or method" error (E0057).
- Declaring a member named `__variantName`, `__variants` or `__variantAt` in an
  enum that would get them is **E0189**, naming the enum and the member. The
  names are reserved so a hand-written one can never hide the synthesized one
  from a generic bound.
- `__variantName` and `__variantAt` are comparison chains, linear in the
  number of variants. Call `__variants()` once and keep the slice when you
  need it in a loop.

## Static methods on an enum {#enum-statics}

A `Status` read back from a form field or a config file arrives as text, and
the code that turns the text into a `Status` belongs with the enum, not in a
free function that has to be found. A `static` method in the enum body is that
function: it belongs to the enum, has no `this`, and is called through the
enum's own name, exactly like a class's static method
([Static Methods](static-methods.md)).

```bit
enum Status {
  Draft
  Published
  Archived

  static parse(text: string): Status {
    if (text == "published") {
      return Status.Published
    }
    if (text == "archived") {
      return Status.Archived
    }
    return Status.fallback()
  }

  static fallback(): Status {
    return Status.Draft
  }

  label(): string {
    return match (this) {
      Draft => "draft"
      Published => "published"
      Archived => "archived"
    }
  }
}

fn main() {
  println(Status.parse("published").label()) // published
  println(Status.parse("oops").label())      // draft
}
```

`Status.parse` has the result type it declares (`Status`); a static is not a
variant, so the `match` in `label` is exhaustive with three arms and needs none
for `parse` or `fallback`. A static may call the enum's other statics, and
instance methods on any value it builds. `export static` makes it visible
outside the module, as for a class.

A generic enum's static is written through an instantiation or, when its
arguments bind the type parameters, through the bare name:

```bit
enum Lookup<T> {
  Missing
  Found(T)

  static just(v: T): Lookup<T> {
    return Lookup<T>.Found(v)
  }

  static none(): Lookup<T> {
    return Lookup<T>.Missing
  }

  static arity(): int {
    return 1
  }

  isFound(): bool {
    return match (this) {
      Missing => false
      Found(v) => true
    }
  }
}

fn main() {
  let a = Lookup.just(3)                   // T = int, from the argument
  let b = Lookup<string>.none()            // T written, nothing to infer it from
  println("${Lookup.arity()}")             // mentions no T: the bare name is enough
  println("${a.isFound()} ${b.isFound()}") // true false
}
```

`Lookup.none()` alone is **E0068**: no argument binds `T`, so the error names the
parameter and the written form.

`static` introduces a static method here, so a variant cannot be named `static`
(**E0191**). A method named `static` in the body is still allowed.

## Next

A `map<string, string>` can only hold a title per id. [Classes](classes.md)
gives a draft a shape of its own.
