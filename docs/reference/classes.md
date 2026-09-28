# Classes

<!-- doctest: per-block -->

A draft is more than a title. It has a title, a body, and tags, and code that
handles one draft should handle all three at once. That is what a class is
for.

## Declaring one

```bit
class Draft {
  export title: string,
  export body: string,
  export tags: []string,
}

fn main() {
  let d = Draft{ title = "Notes on Bit", body = "Bit is...", tags = []string{ "bit" } }
  println("${d.title}: ${len(d.body)} byte(s), ${len(d.tags)} tag(s)")
}
```

`class Draft { ... }` declares the shape: named fields, each with a type.
`export` on a field means code outside this module can read and write it;
leave it off and only this module can. `Draft{ title = ..., ... }` is a
**composite literal**: it always starts with the type name, so a `{` at the
start of a statement is never ambiguous between a literal and a plain block.
`d.title` reads a field with `.`.

## Zero values

Leave a field out of a literal and it gets its type's zero value:

```bit
class Draft {
  export title: string,
  export body: string,
  export tags: []string,
}

fn newDraft(title: string): Draft {
  return Draft{ title = title } // body: "", tags: nil, filled in automatically
}
```

A class is unusual among zero values: `let d: Draft` with no literal at all
is still a live, usable value, not a crash waiting to happen.

## Reference semantics

A class is a reference type, the same category `map` and `string` are in.
Assigning a class value copies the handle, not the fields:

```bit
class Draft {
  export title: string,
  export views: int,
}

fn main() {
  let d = Draft{ title = "Notes on Bit", views = 0 }
  let same = d // copies the handle, not the fields
  same.views = 1
  println("${d.views}") // 1 - d and same are the same Draft
}
```

## Methods

A function that always needs a `Draft` to act on belongs on the class itself,
as a **method**, written inside the class body with the reserved receiver
`this`:

```bit
class Draft {
  export title: string
  export views: int

  export recordView() {
    this.views = this.views + 1
  }
}

fn main() {
  let d = Draft{ title = "Notes on Bit", views = 0 }
  d.recordView()
  d.recordView()
  println("views: ${d.views}") // 2
}
```

Because classes are reference types, `d.recordView()` mutates `d` itself, the
same `d` every other reference to it sees. A method can only be added to a
class declared in the same module.

## Sharp edge: a class literal always needs its type name

```bit ignore
let bad = { title = "x" } // this is a block, not a Draft
```

There is no bare `{ ... }` class literal, on purpose: it is what keeps `{` at
the start of a statement unambiguous with an ordinary block.

## Default field values

```bit
class Settings {
  pageSize: int = 20,
  theme: string = "light",
}

fn main() {
  let a = Settings{}                // pageSize 20, theme "light"
  let b = Settings{ pageSize = 50 } // pageSize 50, theme still defaulted
  println("${a.pageSize} ${b.pageSize}")
}
```

A field whose own type is a class is rebuilt fresh at every construction site
that omits it: two values that both omit that field never share the same
inner object.

## Readonly fields

A field marked `readonly` can be set only in a composite literal:

```bit
class Timestamp {
  export readonly seconds: int,
}

fn main() {
  let t = Timestamp{ seconds = 5 }
  println("${t.seconds}") // 5
}
```

```bit ignore
t.seconds = 0 // error[E0114]: 'readonly' forbids reassigning the field
```

## Comparability

Two class values compare with `==`/`!=` field by field, not by handle: two
separately built values with equal fields are equal, even though assigning
one to the other would have shared a handle instead.

## `@json` and `@job`

A class marked `@json` can encode and decode itself as JSON; see the stdlib
`json` reference. A class marked `@json` and `@job("name")` gets a stable
name a background-job queue can dispatch by, before any instance exists - see
[Static Methods](static-methods.md) for why.

## Next

A draft's id is still typed in by hand. [Functions](functions.md) covers
generating one.
