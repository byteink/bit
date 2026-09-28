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

`Store` lists two method signatures and nothing else: no fields, no bodies.
Anything with both methods, with matching parameter and return types, can
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
