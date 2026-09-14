# Generics

Right now the shortener stores links and fetches them, but it does not count
anything. You want to know how many times `abc123` got looked up, and later
maybe how many lookups came from each referrer, or how many happened in each
hour. That is the same counting logic three times, differing only in what you
count by. A generic type lets you write it once and use it for any key.

<!-- doctest: per-block -->

## The simplest thing that works

A `Counter<T>` tallies lookups by whatever key type you give it:

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
  return Counter<T>{ counts: map<T, int>() }
}

fn main() {
  let hits = counter<string>()
  hits.bump("abc123")
  hits.bump("abc123")
  println("abc123 seen ${hits.get("abc123")} time(s)")
}
```

`<T>` after `class Counter` declares a type parameter. Inside the class body,
`T` stands for whatever type this particular counter ends up holding, so
`counts: map<T, int>` and `key: T` are real, checked types, not `any`. Ask for
a `Counter<string>` and `bump` only accepts strings; the compiler checks it at
every call site, the same as it would for a hand-written `Counter` that only
ever counted strings.

## Where the type argument comes from

Most of the time you never write `<T>` at a call site; Bit works it out from
what you pass. `hits.bump("abc123")` already tells the compiler `T` is
`string`, because `key: T` is right there next to the string argument.

`counter<string>()` above is different: `counter<T>` takes no arguments at
all, so nothing at the call site says what `T` should be. You give it
explicitly, once, where you create the counter:

```bit ignore
let hits = counter() // error: T only appears in the return type
```

Leaving it off is a compile error, not a guess:

```
error[E0068]: cannot infer type parameter 'T'; give explicit type arguments
```

The rule in one line: if a type parameter shows up in a function's
*arguments*, Bit infers it from what you call with; if it only shows up in
the *return type*, you say it at the call site.

## Wired into the shortener

The counter sits beside the store, not inside it. It does not know about
`Link` or `Store` at all, which is exactly why the same `Counter<T>` will
work for hit counts, referrer counts, or anything else you decide to tally
later:

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
  get(code: string): Link
  has(code: string): bool { return len(this.get(code).url) > 0 }
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
  return Counter<T>{ counts: map<T, int>() }
}

fn main() {
  let store: Store = memoryStore()
  let code = shortCode(12345)
  store.put(code, Link{ url: "https://example.com", created: 0, hits: 0 })

  let lookups = counter<string>()
  lookups.bump(code)
  lookups.bump(code)
  println("${code} looked up ${lookups.get(code)} time(s)")
}
```

## Why the store itself is not generic

You might expect the next step to be a generic `MemoryStore<T>` that holds
any record type, not just `Link`. It stays fixed on purpose. Two real gaps in
the language today mean that generic version teaches you two things - the
`Store` interface and the `Existence` trait - only to take them away again:
a trait cannot be made generic, and a generic interface's own methods do not
resolve through an interface-typed value once you have one. Until both are
fixed, `Counter<T>` lives beside the store rather than replacing any part of
it.

## What to read next

The store already returns a `Link` whether or not `abc123` exists. Next:
[Errors](errors.md), where "no such code" becomes a real failure instead of
an empty one.

---

Note: the compiler resolves generics by monomorphization. Each distinct set
of type arguments (here, `Counter<string>`) produces its own compiled copy
of a generic class and its methods at compile time. There is no shared
runtime representation and no type tag carried alongside a value, so a
generic call costs exactly what the same code would cost hand-written for
one type.

Specification: §11.3, §13.6, §15.3.
