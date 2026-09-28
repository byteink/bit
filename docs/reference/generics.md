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
