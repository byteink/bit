# Interfaces

<!-- doctest: per-block -->

Storing drafts in a bare `map<string, Draft>` works until storage needs to
become a real database. Swapping it out means rewriting every place that
touches the map, unless the caller never knew it was a map in the first
place. An interface names what a store can do without naming what it is.

## Declaring one

```bit
class Draft {
  export title: string,
}

interface Store {
  save(id: string, d: Draft),
  load(id: string): Draft,
}
```

`Store` lists two method signatures and nothing else: no bodies, and no
fields yet ([Requiring a field](#requiring-a-field) adds those). Anything
with both methods, with matching parameter and return types, can
stand in for a `Store`. There is no `implements Store` to write; Bit checks
this where a value is used as a `Store`, not where the class is declared:

```bit
class Draft {
  export title: string,
}

interface Store {
  save(id: string, d: Draft),
  load(id: string): Draft,
}

class MemoryStore {
  drafts: map<string, Draft>
  export save(id: string, d: Draft) {
    this.drafts[id] = d
  }
  export load(id: string): Draft {
    return this.drafts[id]
  }
}

fn main() {
  let store: Store = MemoryStore{ drafts = map<string, Draft>() }
  store.save("d1", Draft{ title = "Notes on Bit" })
  println("${store.load("d1").title}")
}
```

`MemoryStore` never mentions `Store` in its own declaration. It satisfies
`Store` by having a `save` and a `load` with the right signatures. A future
`PostgresStore` would satisfy the same interface the same way, and callers
would not need to change at all.

## Requiring a field

A `Store` that audits writes needs to know who is writing. Asking every
caller for a `userId(): string` method means each user type grows a
one-line getter. When the information is already a field, the interface
can ask for the field:

```bit
class Draft {
  export title: string,
}

interface Editor {
  id: string,
  roles: []string,
}

class Author {
  export id: string,
  export roles: []string,
  export drafts: []Draft,
}

fn audit(by: Editor, action: string) {
  println("${by.id} (${len(by.roles)} roles) ${action}")
}

fn main() {
  let ana = Author{ id = "ana", roles = ["writer"], drafts = []Draft(0) }
  audit(ana, "saved a draft")
}
```

`id: string` is a field requirement. `Author` satisfies it the same way it
satisfies a method: by having a field with that name and the identical type,
with nothing to declare. `audit` reads `by.id` and `by.roles` like fields of
a class. An interface can mix fields and methods in one declaration.

Three rules decide whether a class qualifies:

- The type must match exactly. An `id: i64` field does not satisfy
  `id: string`.
- The field has to be visible. An `export`ed field satisfies the requirement
  from any module. A field without `export` satisfies it only for an
  interface declared in the same module, since it is private to that module
  and the interface would otherwise hand its value to every other one.
- A method named `id()` is not a field named `id`.

When a class fails, the error names the field:

```bit ignore
class Row {
  export id: i64,
}

fn demo() {
  let by: Editor = Row{ id = 1 } // error[E0041]: ... 'Row.id' is i64, but 'Editor' needs id: string
}
```

The requirement is read-only through the interface. Writing `by.id = "x"`,
`by.id += "x"` or `by.id++` is `E0114`, the same error a `readonly` class
field gives. Assign on the concrete value (`ana.id = "x"`) instead.

## Reading one field by name: `__field`

Bit has no reflection, so an interface cannot ask "give me the field called
`team`" of a class it has never seen. A package that stores a policy as text
(`"team": "$user.team"`) needs exactly that. Declare a method named `__field`
in an interface and the compiler writes it for every class in the program:

```bit
import { Json, jsonAsString } from "std/json"

interface Attributes {
  __field(name: string): Option<Json>,
}

class Author {
  export id: string,
  export team: string,
  export drafts: int,
  secret: string,
}

fn attribute(a: Attributes, name: string): string {
  return match (a.__field(name)) {
    Some(j) => unwrapOr(jsonAsString(j), "not text")
    None => "none"
  }
}

fn main() {
  let ana = Author{ id = "ana", team = "sport", drafts = 3, secret = "s" }
  println(attribute(ana, "team"))
  println(attribute(ana, "drafts"))
  println(attribute(ana, "secret"))
}
```

`Author` writes no `__field`: it is a chain of `if (name == "team")` tests over
its `export`ed fields, so a lookup allocates at most the one `Json` value it
returns and never serializes the object. The result is `Some` for a string, an
integer, a float, a bool, a payload-free enum declared in the same module (its
variant name) and a slice of any of those. It is `None` for an unknown name, an
unexported field, a nested class, a map or an `Option` field: a nested object
has no flat value to return, and the member never reaches into a class that did
not ask for it.

The member exists only in a program that declares an interface with a method
named `__field`, so every other program is unchanged. Declaring a method named
`__field` yourself is **E0311**, because a hand-written one would satisfy such
an interface by name alone. The name is hidden from `bit doc` like every
`__` member.

## Comparing whole values: `__sameValue`, `__valueHash`, `__snapshot`

`a == b` on a class that holds a slice is a compile error (E0052): a slice has
no value equality, so there is no answer to give. That is awkward the moment you
want to remember work by the whole value of an object. Say Inkwell caches the
rendered page of a draft: if the cache key were only the title, an edit to the
tags would keep serving the old page. Three members, written for you, make the
whole value the key:

```bit
class Author {
  id: string,
  roles: []string,
}

class Draft {
  title: string,
  tags: []string,
  author: Author,
  reviewer: Option<string>,
  words: map<string, int>,
}

fn main() {
  let a = Draft{
    title = "Hello", tags = ["intro", "news"], author = Author{ id = "ana", roles = ["editor"] },
    reviewer = Option.Some("bo"), words = map<string, int>{ "hello": 1, "world": 2 },
  }
  let b = Draft{
    title = "Hello", tags = ["intro", "news"], author = Author{ id = "ana", roles = ["editor"] },
    reviewer = Option.Some("bo"), words = map<string, int>{ "world": 2, "hello": 1 },
  }
  println("same: ${a.__sameValue(b)}")
  println("same hash: ${a.__valueHash() == b.__valueHash()}")

  let kept = a.__snapshot()
  a.tags[0] = "changed"
  println("copy unchanged: ${kept.__sameValue(b)}")
  println("original differs: ${!a.__sameValue(b)}")
}
```

- `x.__sameValue(y)` is true when every field is equal. A slice is equal when it
  has the same length and equal elements, a map when it has the same keys with
  equal values, an `Option` when both are `None` or both hold equal values, an
  enum with payloads when it is the same variant with equal payloads, and a
  nested class by these same rules. A float compares by its bits, so a `NaN`
  field equals itself. A `decimal` compares by value, so `1.0` equals `1.00`.
- `x.__valueHash()` is a `u64`. Values that are `__sameValue` have the same
  hash, whatever order a map yields its entries in. Different values usually
  differ, but two may collide, so a cache compares with `__sameValue` after a
  hash match. The hash starts from the same per-program seed the built-in maps
  use, so it is not a number to store or send anywhere.
- `x.__snapshot()` is a deep copy: a later change to `x`, to one of its slices,
  maps or nested classes, never reaches the copy.

Comparing and hashing allocate nothing. Only `__snapshot` allocates, for the
fresh slices and maps it returns.

A class gets the three members when every field is a string, a number, a bool, a
float, a `decimal`, an enum, a slice, a map or an `Option` of these, or a class
that qualifies itself. A map key must be a string, an integer, a bool or an enum
without payloads. An enum with payloads must be declared in the same module as
the class, with no type parameters and no variant that contains itself.

A class with a field of any other kind (a function, an interface, a channel, a
generic class, a tuple, or an enum that breaks the rules above) has none of the
three. Calling one is **E0313**, and the message names the first field in the
way. Declaring a method with one of these names yourself is **E0312**, because a
hand-written one would satisfy an interface requiring it by name alone.

The members exist only in a program that names one of them, so every other
program is unchanged. They are hidden from `bit doc` like every `__` member.

## The built-in `error` interface

Bit's own `error` type is declared the same way:

```bit
interface error { message(): string }
```

Any type with a `message(): string` method is an `error`. See
[Errors](errors.md).

## Sharp edges

A `Store`-typed variable only offers what `Store` declares:

```bit ignore
fn demo(store: Store) {
  println("${store.drafts}") // error[E0057]: no field or method 'drafts' on this type
}
```

Narrowing a `Store` value back to a concrete type is a type assertion, `.()`.
The two-result form reports whether it worked; the one-result form panics if
it did not:

```bit
class Draft {
  export title: string,
}

interface Store {
  save(id: string, d: Draft),
  load(id: string): Draft,
}

class MemoryStore {
  drafts: map<string, Draft>
  export save(id: string, d: Draft) {
    this.drafts[id] = d
  }
  export load(id: string): Draft {
    return this.drafts[id]
  }
}

fn demo(store: Store) {
  let (m, ok) = store.(MemoryStore) // ok is false if store isn't a MemoryStore
  if (ok) {
    println("${len(m.drafts)} draft(s)")
  }
}
```

The target of `.()` also has to be a class: only a class carries methods, so
only a class can be the concrete type behind an interface value.

## When not to reach for an interface

If only one store will ever exist, `MemoryStore` alone is simpler and just as
correct. An interface earns its place once something genuinely needs to
vary.

## Next

[Traits](traits.md): `Store` is about to grow a third method, and every
implementation would otherwise write the same one-liner to get it.
