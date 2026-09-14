# Traits

<!-- doctest: per-block -->

`Store` is about to gain a third method: something that asks "does this
code exist?" without needing the whole `Link` back. `MemoryStore` can
answer it in one line, built on `get` it already has:

```bit ignore
export has(code: string): bool {
  return len(this.get(code).url) > 0
}
```

That line is fine once. It stops being fine the moment a second store shows
up - every future `Store` implementation would need the exact same method,
copied by hand, with no way to keep the copies in sync. A trait writes the
method once and gives it to every class that needs it.

## Declaring one

A trait member is either **required** - a signature with no body, which the
using class must supply - or **provided** - it has a body, and every using
class gets it for free:

```bit
class Link {
  export url: string,
  export created: i64,
  export hits: int,
}

trait Existence {
  get(code: string): Link                                        // required: no body
  has(code: string): bool { return len(this.get(code).url) > 0 } // provided
}
```

`has` is written once, against `this.get(code)`. It doesn't know or care
which class ends up supplying `get`.

## Using it

A class pulls a trait in with `use`, as a statement of its own inside the
class body:

```bit
class Link {
  export url: string,
  export created: i64,
  export hits: int,
}

trait Existence {
  get(code: string): Link
  has(code: string): bool { return len(this.get(code).url) > 0 }
}

class MemoryStore {
  use Existence

  links: map<string, Link>
  export put(code: string, l: Link) {
    this.links[code] = l
  }
  export get(code: string): Link {
    return this.links[code]
  }
}
```

`MemoryStore` never writes `has` itself. `use Existence` injects it, using
the `get` that `MemoryStore` already has. If `MemoryStore` supplies `get`
but no `has`, that's exactly what the trait was for: `get` satisfies the
required half, and `has` arrives from the trait.

An injected method counts toward interface satisfaction exactly like one
the class wrote by hand, which is what lets `Store` add `has` to its own
signature without `MemoryStore` changing at all.

## The real use case

Stage 05 in full: `Store` now requires `has`, and `MemoryStore` gets it from
`Existence` instead of writing it twice.

```bit
class Link {
  export url: string,
  export created: i64,
  export hits: int,
}

const alphabet: string = "abcdefghijklmnopqrstuvwxyz0123456789"

fn shortCode(n: int): string {
  let out = []byte(0)
  let x = n
  while (x > 0 || len(out) == 0) {
    out = append(out, alphabet[x % len(alphabet)])
    x = x / len(alphabet)
  }
  return string(out)
}

trait Existence {
  get(code: string): Link                                        // required: no body
  has(code: string): bool { return len(this.get(code).url) > 0 } // provided
}

interface Store {
  put(code: string, l: Link),
  get(code: string): Link,
  has(code: string): bool,
}

class MemoryStore {
  use Existence

  links: map<string, Link>
  export put(code: string, l: Link) {
    this.links[code] = l
  }
  export get(code: string): Link {
    return this.links[code]
  }
}

fn memoryStore(): MemoryStore {
  return MemoryStore{ links: map<string, Link>() }
}

fn main() {
  let store: Store = memoryStore()
  let code = shortCode(12345)
  println("has ${code} before put: ${store.has(code)}")
  store.put(code, Link{ url: "https://example.com", created: 0, hits: 0 })

  let l = store.get(code)
  println("${code} -> ${l.url} (hits=${l.hits})")
  println("has ${code} after put: ${store.has(code)}")
}
// has 7sj before put: false
// 7sj -> https://example.com (hits=0)
// has 7sj after put: true
```

A second `Store` - a Postgres-backed one, say - would `use Existence` too
and never write `has` either.

## Sharp edges

A trait is not a type. It can't be a variable's type, a parameter type, a
field type, or a type-assertion target - a function that needs "anything
with a `has` method" declares an interface instead:

```bit ignore
fn needsExistence(t: Existence) { } // error[E0105]: trait 'Existence' cannot be used as a type
```

A class that `use`s a trait but never supplies a required method fails at
the class, naming both the missing method and the trait that needs it:

```bit ignore
class BrokenStore {
  use Existence
  links: map<string, Link>
} // error[E0104]: class 'BrokenStore' does not supply 'get', required by trait 'Existence'
```

Two `use`d traits providing the same method, with neither overridden by the
class, is also a compile error rather than a silent pick of one:

```bit ignore
class TwoTraits {
  use Existence, OtherExistence
} // error[E0120]: trait method conflict: 'Existence' and 'OtherExistence' both provide 'has'
```

A method the class declares itself always wins over one a trait would
otherwise supply, with no syntax to choose between them - so a class only
needs to write its own version when it wants to override, not to avoid a
conflict it doesn't have.

## When not to reach for a trait

If only one class will ever need the behaviour, write the method on that
class directly. A trait pays off once a second class needs the same
method - here, once a second `Store` shows up - not before.

## Next

[Generics](generics.md): the store still only holds a `Link`. The next
requirement is counting lookups by any kind of key at all, which needs a
type that isn't fixed to one record.
