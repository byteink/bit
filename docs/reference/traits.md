# Traits

<!-- doctest: per-block -->

`Store` is about to gain a third method: "does this draft exist?" without
needing the whole `Draft` back. Every future `Store` implementation would
otherwise need the exact same one-liner, copied by hand, with no way to keep
the copies in sync. A trait writes the method once and gives it to every
class that needs it.

## Declaring one

A trait member is either **required** - a signature with no body, which the
using class must supply - or **provided** - it has a body, and every using
class gets it for free:

```bit
class Draft {
  export title: string,
}

trait Existence {
  load(id: string): Draft                                          // required
  exists(id: string): bool { return len(this.load(id).title) > 0 } // provided
}
```

`exists` is written once, against `this.load(id)`. It does not know or care
which class ends up supplying `load`.

## Using it

A class pulls a trait in with `use`, as a statement inside the class body:

```bit
class Draft {
  export title: string,
}

trait Existence {
  load(id: string): Draft
  exists(id: string): bool { return len(this.load(id).title) > 0 }
}

class MemoryStore {
  use Existence

  drafts: map<string, Draft>
  export save(id: string, d: Draft) {
    this.drafts[id] = d
  }
  export load(id: string): Draft {
    return this.drafts[id]
  }
}

fn main() {
  let s = MemoryStore{ drafts = map<string, Draft>() }
  println("${s.exists("d1")}") // false: use Existence supplied exists for free
  s.save("d1", Draft{ title = "Notes on Bit" })
  println("${s.exists("d1")}") // true
}
```

`MemoryStore` never writes `exists` itself. `use Existence` injects it, using
the `load` that `MemoryStore` already has. An injected method counts toward
interface satisfaction exactly like one the class wrote by hand, so `Store`
can add `exists` to its own signature without `MemoryStore` changing at all.

## Sharp edges

A trait is not a type. It cannot be a variable's type, a parameter type, a
field type, or a type-assertion target - a function that needs "anything
with an `exists` method" declares an interface instead:

```bit ignore
fn needsExistence(t: Existence) { } // error[E0105]: trait 'Existence' cannot be used as a type
```

A class that `use`s a trait but never supplies a required method fails at
the class, naming both the missing method and the trait that needs it:

```bit ignore
class BrokenStore {
  use Existence
} // error[E0104]: class 'BrokenStore' does not supply 'load', required by trait 'Existence'
```

Two `use`d traits providing the same method, with neither overridden by the
class, is also a compile error rather than a silent pick of one. A method the
class declares itself always wins over one a trait would otherwise supply.

## When not to reach for a trait

If only one class will ever need the behaviour, write the method on that
class directly. A trait pays off once a second class needs the same method.

## Next

[Generics](generics.md): the store only holds a `Draft`. Counting things by
any kind of key at all needs a type that is not fixed to one record.
