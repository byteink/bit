# Classes

A link is more than a URL. It has a URL, but it also has when it was created
and how many times someone has clicked it. Those three values always travel
together: every link has all three, and code that handles one link should
handle all three at once. That is what a class is for.

## The shortest thing that works

```bit
class Link {
  export url: string,
  export created: i64,
  export hits: int,
}

fn storeLink() {
  let links = map<string, Link>()
  links["abc123"] = Link{ url = "https://example.com", created = 0, hits = 0 }

  let l = links["abc123"]
  println("abc123 -> ${l.url} (hits=${l.hits})")
}
```

`class Link { ... }` declares the shape: three named fields, each with a
type. `export` on a field means code outside this module can read and write
it; leave it off and only this module can. `Link{ url = ..., created = ...,
hits = ... }` is a **composite literal**: it always starts with the type name,
so a `{` at the start of a statement is never ambiguous between a literal and
a plain block. `l.url` and `l.hits` read fields with `.`.

This is `docs/examples/shortener/02_class.bit`. The map is now
`map<string, Link>` instead of `map<string, string>`; everything else about
using a map is exactly what [Types](types.md#maps) already covered.

## Zero values

Leave a field out of a literal and it gets its type's zero value, the same
zero value [Variables](variables.md#zero-values) covers for a plain `let`:

```bit
fn freshLink(url: string): Link {
  return Link{ url = url } // created: 0, hits: 0, filled in automatically
}
```

A class is unusual among zero values: a `let l: Link` with no literal at all
is still a live, usable value, not a crash waiting to happen.

```bit
fn declaredLink() {
  let l: Link // {url: "", created: 0, hits: 0}, ready to read and write
}
```

## Reference semantics

A class is a reference type, the same category `map` and `string` are in
([Types](types.md#value-vs-reference-semantics)). Assigning a class value
copies the handle, not the fields:

```bit
fn sameLink() {
  let l = Link{ url = "https://example.com", created = 0, hits = 0 }
  let sameOne = l // copies the handle, not the fields
  sameOne.hits = 1
  // l.hits is 1 too - they are the same Link
}
```

This is what makes storing a `Link` in a map and then handing it to a
function useful: the function can update the link the caller sees, without
returning anything.

## Methods

A function that always needs a `Link` to act on belongs on the class itself,
as a **method**, written inside the class body with the reserved receiver
`this`:

```bit
class LinkStats {
  export url: string
  export created: i64
  export hits: int

  export recordHit() {
    this.hits = this.hits + 1
  }
}

fn visit() {
  let l = LinkStats{ url = "https://example.com", created = 0, hits = 0 }
  l.recordHit()
  l.recordHit()
  println("hits: ${l.hits}") // 2
}
```

`recordHit()` takes no explicit receiver parameter; `this` is implicit and is
typed as `LinkStats`. Because classes are reference types, `l.recordHit()`
mutates `l` itself, the same `l` every other reference to it sees, exactly
like `sameOne.hits = 1` did above. A method can only be added to a class
declared in the same module; there is no way to attach one to `Link` from
outside.

## The real use case

Put it together: a map of codes to links, each one tracking its own hit
count as it gets visited.

```bit
fn trackVisits() {
  let links = map<string, LinkStats>()
  links["abc123"] = LinkStats{ url = "https://example.com", created = 0, hits = 0 }

  let l = links["abc123"]
  l.recordHit()
  println("abc123 -> ${l.url} (hits=${l.hits})")
}
```

Because `links["abc123"]` and `l` share the same handle, `l.recordHit()`
updates the entry that is sitting in the map, with no need to write it back.

## Sharp edge: a class literal always needs its type name

There is no bare `{ ... }` class literal, on purpose: it is what keeps `{` at
the start of a statement unambiguous with an ordinary block.

```bit ignore
let bad = { url: "https://example.com" } // this is a block, not a Link
```

Write the type name every time, even when it seems obvious from context:
`Link{ url = "https://example.com" }`.

## When not to use a class

If a value is really just one thing, a URL by itself, a single count, a plain
map from code to URL, a class adds a name and an allocation for no benefit.
Reach for a class once you have two or more values that are only meaningful
together, the way `url`, `created` and `hits` are for a link.

## Reference: more class features

The shortener does not need these until later chapters introduce them.
They exist and are documented here so you are not surprised when you meet
them.

### Default field values

A field can declare a default, used wherever a literal or a zero value would
otherwise apply:

```bit
class Opts {
  port: int = 8080,
  host: string = "127.0.0.1",
}

fn defaults(): int {
  let a = Opts{}              // port 8080, host "127.0.0.1"
  let b = Opts{ port = 3000 } // port 3000, host still defaulted
  return a.port + b.port
}
```

A non-class field's default has to be a compile-time constant. A field
whose own type is a class can also declare a default; it works differently,
and is covered below in "Fields that are themselves a class".

### Composite literal field shorthand

A field key with no `: value` reuses a binding of the same name already in
scope:

```bit
fn shorthandLiteral() {
  let url = "https://example.com"
  let created = 0
  let l = Link{ url, created, hits = 0 } // same as url: url, created: created
}
```

### Readonly fields

A field marked `readonly` can be set only in a composite literal, or inside
the class's own `init`:

```bit
class Timestamp {
  export readonly ns: int,
}

fn buildReadonly() {
  let t = Timestamp{ ns = 5 }
  println("${t.ns}") // 5
}
```

```bit ignore
t.ns = 0 // error[E0114]: 'readonly' forbids reassigning the field
```

### Fields that are themselves a class

A field whose own type is a class has no zero value, because a `nil` there
would break the promise that a zeroed class is always usable. It must be
given a value everywhere a `Link`-shaped field could otherwise be omitted:

```bit ignore
class Inner { n: int }
class Outer { a: int, b: Inner }

let bad = Outer{ a = 1 }              // error[E0083]: 'b' omitted
let good = Outer{ a = 1, b = Inner{} } // fine
```

A class-typed field can still be omitted if it declares its own default,
written as a composite literal of its own type instead of a constant. Unlike
a non-class default, a class-typed one is **rebuilt fresh at every
construction site** that omits it, exactly as if the literal had been
spelled there - two values that both omit `b` get their own `Inner`, never
the same one:

```bit
class Inner {
  n: int = 1,
}

class Configured {
  export a: int,
  export b: Inner = Inner{ n = 1 },
}

fn separateDefaults(): int {
  let x = Configured{ a = 1 }
  let y = Configured{ a = 2 }
  x.b.n = 99
  return y.b.n // 1, not 99: x and y never shared the default
}
```

A shared default object was considered and rejected: it would make
`Configured{ a = 1 }.b` an alias of every other omission's `b`, with nothing
in `Configured{ a = 1 }` to suggest that. Mutating one caller's copy would
silently reach every other caller's.

### Comparability

Two class values compare with `==`/`!=` field by field, not by handle: two
separately built values with equal fields are equal, even though assigning
one to the other would have shared a handle instead.

### `@json`, attributes, and interfaces

A class can also be marked `@json` to generate JSON encoding and decoding,
carry field-validation attributes, and satisfy an interface automatically by
having its methods. These are covered on their own pages once the shortener
needs them: [Interfaces](interfaces.md) and the stdlib `json` reference.

### Specification

Class declarations, fields, zero values and composite literals are defined
in the language specification.

## Next

The shortener's links now carry real data, but every code is still typed in
by hand. Generating one is the next step: read [Functions](functions.md).
