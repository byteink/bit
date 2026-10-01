# Generics

<!-- doctest: per-block -->

Inkwell wants to count things: how many drafts carry a tag, how many were
written by each author. That is the same counting logic every time,
differing only in what you count by. A generic type lets you write it once
and use it for any key.

## The simplest thing that works

```bit
class Counter<T> {
  counts: map<T, int>
  export bump(key: T): int {
    this.counts[key] = this.counts[key] + 1
    return this.counts[key]
  }
  export get(key: T): int {
    return this.counts[key]
  }
}

fn counter<T>(): Counter<T> {
  return Counter<T>{ counts = map<T, int>() }
}

fn main() {
  let byTag = counter<string>()
  byTag.bump("bit")
  byTag.bump("bit")
  println("bit seen ${byTag.get("bit")} time(s)")
}
```

`<T>` after `class Counter` declares a type parameter. Inside the class body,
`T` stands for whatever type this particular counter ends up holding, so
`counts: map<T, int>` and `key: T` are real, checked types. Ask for a
`Counter<string>` and `bump` only accepts strings, checked at every call
site.

## Where the type argument comes from

Most of the time you never write `<T>` at a call site; Bit infers it from
what you pass. `byTag.bump("bit")` already tells the compiler `T` is
`string`.

`counter<string>()` above is different: `counter<T>` takes no arguments, so
nothing at the call site says what `T` should be. Give it explicitly, once,
where you create the counter. Leaving it off is a compile error, not a
guess:

```
error[E0068]: cannot infer type parameter 'T'; give explicit type arguments
```

The rule in one line: if a type parameter shows up in a function's
*arguments*, Bit infers it from what you call with; if it only shows up in
the *return type*, you say it at the call site.

## Asking a type parameter for a capability

`Counter<T>` accepts any key because it never does anything with one except
hash it. A function that reads from a store is different: it has to call
`get`, so it must be able to say what a store is. Inkwell keeps drafts in one
store and tag labels in another, and wants one `fetch` for both.

A generic interface describes a store whatever it holds, and a bound on a type
parameter asks for it:

```bit
class Draft {
  title: string,
}

interface Store<T> {
  get(id: string): T,
}

class DraftStore {
  drafts: map<string, Draft>
  get(id: string): Draft {
    return this.drafts[id]
  }
}

class TagStore {
  labels: map<string, string>
  get(id: string): string {
    return this.labels[id]
  }
}

fn titleOf<S: Store<Draft>>(store: S, id: string): string {
  return store.get(id).title
}

fn fetch<T, S: Store<T>>(store: S, id: string): T {
  return store.get(id)
}

fn main() {
  let drafts = DraftStore{ drafts = map<string, Draft>() }
  drafts.drafts["d1"] = Draft{ title = "Notes on Bit" }
  let tags = TagStore{ labels = map<string, string>() }
  tags.labels["t1"] = "language"
  println(titleOf(drafts, "d1"))
  println(fetch(drafts, "d1").title)
  println(fetch(tags, "t1"))
}
```

`S: Store<Draft>` says "any type `S` whose `get` takes a string and returns a
`Draft`". Inside `titleOf`, `store.get(id)` is checked against that, and
`DraftStore` qualifies without ever mentioning `Store`, the same way it does
for the plain interfaces in [Interfaces](interfaces.md).

`fetch` bounds `S` by `Store<T>`, with `T` another of its own type
parameters. You never write `T` at the call: Bit works it out from what the
store's `get` returns. `fetch(drafts, "d1")` is a `Draft` and `fetch(tags,
"t1")` is a `string`, from one function.

The compiler generates one copy of `titleOf` and `fetch` for each store type
you call them with, and each copy calls the store's own `get` directly. A
function that takes the interface as a value, `fn titleOf(store: Store<Draft>)`,
is one copy that looks `get` up at runtime on every call. Both work. Reach for
the bound when the function sits on a hot path or when it must return the
store's own type of value, as `fetch` does; the value form is simpler when
neither matters.

### What the compiler says when it does not fit

A store whose `get` returns the wrong type is refused at the call, and the
message names the method that disagrees:

```text
error[E0051]: type argument 0 is 'TagStore', which does not satisfy the bound 'Store<Draft>'
  'TagStore.get' is (string) => string, but 'Store<Draft>' needs (string) => Draft
```

The same check covers a sibling: `fetch<Draft, TagStore>(tags, "t1")` writes
`T` as `Draft`, so `S` must be a `Store<Draft>`, and is refused for the same
reason.

A bound has to say which store it means. `S: Store` and `S: Store<Draft,
Draft>` are both `E0058`, because `Store` takes exactly one type argument:

```text
error[E0058]: 'Store' takes 1 type argument(s); a bound must write them, as 'Store<...>'
error[E0058]: 'Store' expects 1 type argument(s), found 2
```

## Why the store itself stays fixed on `Draft`

A `Counter<T>` lives beside the store, not inside it, and works for any key
type. A generic `MemoryStore<T>` holding any record type could work the same
way for its own methods, but a trait like `Existence` cannot: Bit keeps a
trait scoped to one concrete type, because its type parameters would have
nowhere unambiguous to come from. A store that reaches for a trait to get a
method for free stays fixed on one record type unless it writes that method
by hand instead.

## Next

The store still returns a `Draft` whether or not the id exists.
[Errors](errors.md) makes "no such draft" a real failure instead of an empty
one.
