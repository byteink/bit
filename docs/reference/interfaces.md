# Interfaces

<!-- doctest: per-block -->

Stage 03 of the shortener stores links in a bare `map<string, Link>`, and
`main` talks to that map directly:

```bit ignore
let links = map<string, Link>()
links[code] = Link{ url = "https://example.com", created = 0, hits = 0 }
let l = links[code]
```

That works until the map needs to become a real database. Swapping it out
means finding every place `main` touches `links` and rewriting it - unless
`main` never knew it was a map in the first place. An interface names what a
store can do without naming what it is.

## Declaring one

```bit
class Link {
  export url: string,
  export created: i64,
  export hits: int,
}

interface Store {
  put(code: string, l: Link),
  get(code: string): Link,
}
```

`Store` lists two method signatures and nothing else - no fields, no
bodies. Anything that has both methods, with matching parameter and return
types, can stand in for a `Store`. There is no `implements Store` to write;
Bit checks this where a value is used as a `Store`, not where the class is
declared:

```bit
class Link {
  export url: string,
  export created: i64,
  export hits: int,
}

interface Store {
  put(code: string, l: Link),
  get(code: string): Link,
}

class MemoryStore {
  links: map<string, Link>
  export put(code: string, l: Link) {
    this.links[code] = l
  }
  export get(code: string): Link {
    return this.links[code]
  }
}

fn memoryStore(): MemoryStore {
  return MemoryStore{ links = map<string, Link>() }
}

fn demo() {
  let store: Store = memoryStore() // MemoryStore was never declared to satisfy Store
}
```

`MemoryStore` never mentions `Store` anywhere in its own declaration. It
satisfies `Store` simply by having a `put` and a `get` with the right
signatures. A future `PostgresStore` would satisfy the same interface the
same way, and `main` would not need to change at all.

## The real use case

This is stage 04 in full: `main` now holds a `Store`, not a `MemoryStore`.

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

interface Store {
  put(code: string, l: Link),
  get(code: string): Link,
}

class MemoryStore {
  links: map<string, Link>
  export put(code: string, l: Link) {
    this.links[code] = l
  }
  export get(code: string): Link {
    return this.links[code]
  }
}

fn memoryStore(): MemoryStore {
  return MemoryStore{ links = map<string, Link>() }
}

fn main() {
  let store: Store = memoryStore()
  let code = shortCode(12345)
  store.put(code, Link{ url = "https://example.com", created = 0, hits = 0 })

  let l = store.get(code)
  println("${code} -> ${l.url} (hits=${l.hits})")
}
// 7sj -> https://example.com (hits=0)
```

Nothing after `let store: Store = memoryStore()` mentions `MemoryStore`
again. Replacing the in-memory store later is a one-line change to that one
call.

## The built-in `error` interface

Bit's own `error` type is declared the exact same way, which is worth
seeing before [Errors](errors.md) covers what it's used for:

```bit
interface error { message(): string }
```

Any type with a `message(): string` method is an `error`. The shortener
starts using this once "no such code" needs to be a real failure instead of
an empty `Link` - that's the next requirement after traits.

## Sharp edges

A `Store`-typed variable only offers what `Store` declares. `store.links` is
not part of `Store`, even though the value behind it is a `MemoryStore` with
a `links` field:

```bit ignore
fn demo(store: Store) {
  println("${store.links}") // error[E0057]: no field or method 'links' on this type
}
```

Narrowing a `Store` value back to a concrete type is a type assertion,
`.()`. The two-result form reports whether it worked; the one-result form
panics if it didn't:

```bit
class Link {
  export url: string,
  export created: i64,
  export hits: int,
}

interface Store {
  put(code: string, l: Link),
  get(code: string): Link,
}

class MemoryStore {
  links: map<string, Link>
  export put(code: string, l: Link) {
    this.links[code] = l
  }
  export get(code: string): Link {
    return this.links[code]
  }
}

class OtherStore {
  links: map<string, Link>
  export put(code: string, l: Link) {
    this.links[code] = l
  }
  export get(code: string): Link {
    return this.links[code]
  }
}

fn demo(store: Store) {
  let (m, ok) = store.(MemoryStore) // ok is false if store isn't a MemoryStore
  if (!ok) {
    return
  }
  println("${len(m.links)} link(s)")
}

fn mustMemory(store: Store): MemoryStore {
  return store.(MemoryStore) // panics if store isn't a MemoryStore
}
```

On a mismatch, `mustMemory` panics with `type assertion failed: OtherStore is
not MemoryStore`. The target of `.()` also has to be a class - only a class
carries methods, so only a class can be the concrete type behind an
interface value:

```bit ignore
fn demo(store: Store): int {
  return store.(int) // error[E0041]: cannot store 'i64' in interface 'Store'
}
```

## When not to reach for an interface

If the shortener only ever has one store and nothing is ever going to
replace it, `MemoryStore` alone is simpler and just as correct. An interface
earns its place when something genuinely needs to vary - here, "a database
will replace the in-memory store later" - not as a default wrapper around
every class.

## Next

[Traits](traits.md): `Store` is about to grow a third method, `has`, and
every implementation would otherwise have to write the same one-liner to
get it.
