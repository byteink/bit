# Modules

One file now holds the record type, the store, the counter, and the
background sweep, and `main` is buried at the bottom of all of it. Before it
grows any further, the store logic belongs in its own file, so `main.bit`
can be just the part that wires everything together and runs it.

<!-- doctest: per-block -->

## A module is a directory

A Bit module is a directory of `.bit` files that share one flat namespace -
there is no per-file package name to declare, and declarations in the same
module can refer to each other in any order regardless of which file they
are in. Importing from another module uses a path:

```bit
import { now, sleep, Millisecond } from "std/time"

fn wait() {
  let start = now().ns
  sleep(5 * Millisecond)
}
```

`"std/time"` is a standard-library module. A path starting with `.` or `..`
is a project-relative module - the shortener's split uses `"./store"` for a
`store` directory next to `main.bit`.

## Visibility with `export`

Visibility is explicit, not inferred from naming. A declaration is
module-private unless marked `export`, and that applies separately to each
class field and method too:

```bit
export class Link {
  export url: string,
  export created: i64,
  export hits: int,
  export expiresAt: i64,
}
```

Every field here is exported because `main.bit`, in a different module,
needs to read `url` and `hits` off a `Link` it gets back from the store.
Drop `export` from a field and code outside this module can no longer read
or write it, even though code inside the module still can.

## The store, moved out

`store/store.bit` becomes the whole record-and-storage layer: the `Link`
class, `shortCode`, the `Existence` trait, the `Store` interface, the
`MemoryStore` class, the `Counter<T>`, and the sweep functions - everything
`main.bit` does not need to see the insides of:

```bit
import { now, sleep, Millisecond } from "std/time"

export class Link {
  export url: string,
  export created: i64,
  export hits: int,
  export expiresAt: i64,
}

const alphabet: string = "abcdefghijklmnopqrstuvwxyz0123456789"

export fn shortCode(n: int): string {
  let out = []byte(0)
  let x = n
  while (x > 0 || len(out) == 0) {
    out = append(out, alphabet[x % len(alphabet)])
    x = x / len(alphabet)
  }
  return string(out)
}

export trait Existence {
  get(code: string): Link!
  has(code: string): bool {
    let l = this.get(code) catch Link{ url: "", created: 0, hits: 0, expiresAt: 0 }
    return len(l.url) > 0
  }
}

export interface Store {
  put(code: string, l: Link),
  get(code: string): Link!,
  has(code: string): bool,
}

export class MemoryStore {
  use Existence

  export links: map<string, Link>
  export put(code: string, l: Link) {
    this.links[code] = l
  }
  export get(code: string): Link! {
    let (l, ok) = this.links[code]
    if (!ok) {
      fail newError("no such code: ${code}")
    }
    return l
  }
}

export fn memoryStore(): MemoryStore {
  return MemoryStore{ links: map<string, Link>() }
}

export class Counter<T> {
  export counts: map<T, int>
  export bump(key: T): int {
    this.counts[key] = this.counts[key] + 1
    return this.counts[key]
  }
  export get(key: T): int {
    return this.counts[key]
  }
}

export fn counter<T>(): Counter<T> {
  return Counter<T>{ counts: map<T, int>() }
}

// Removes every link whose expiresAt has passed nowNs, returning the count.
export fn sweepOnce(store: MemoryStore, nowNs: i64): int {
  let expired = []string(0)
  for (code, l) of store.links {
    if (l.expiresAt > 0 && l.expiresAt <= nowNs) {
      expired = append(expired, code)
    }
  }
  for code of expired {
    delete(store.links, code)
  }
  return len(expired)
}

export fn sweepLoop(store: MemoryStore, stop: chan<bool>, done: chan<int>) {
  let removed = 0
  let running = true
  while (running) {
    select {
      case _ = <- stop:
        running = false
      default:
        sleep(5 * Millisecond)
        removed = removed + sweepOnce(store, now().ns)
    }
  }
  done <- removed
}
```

`links` is exported too, even though `main.bit` never reads it directly -
anything holding the concrete `MemoryStore`, not just the `Store` interface,
is entitled to.

## Wiring it from `main.bit`

`main.bit` imports the pieces it needs by name and never sees `links` or the
map at all:

```bit ignore
// This block imports a sibling module directory ("./store") and cannot be
// checked on its own here; run it as part of the shortener example.
import { now, sleep, Millisecond } from "std/time"
import { Link, Store, counter, memoryStore, shortCode, sweepLoop } from "./store"

fn main() {
  let ms = memoryStore()
  let store: Store = ms
  let code = shortCode(12345)
  store.put(code, Link{ url: "https://example.com", created: 0, hits: 0, expiresAt: 0 })

  let lookups = counter<string>()
  lookups.bump(code)
  println("${code} looked up ${lookups.get(code)} time(s)")

  let stop = chan<bool>(1)
  let done = chan<int>(1)
  spawn sweepLoop(ms, stop, done)
  sleep(10 * Millisecond)
  stop <- true
  let removed = <- done
  println("swept ${removed} expired link(s)")
}
```

Only exported names are importable - naming an unexported one from outside
its module is an error, not a silent miss - and an import cycle between two
modules is also an error.

## The `main` entry point

The directory you pass to `bit build` is the executable module, and it must
declare exactly one `main`:

```bit ignore
fn main() { }              // exit code 0 on normal return

fn main(): int {           // returned int is the process exit code
  return 0
}

fn main(): ()! {           // a returned error prints to stderr, exit 1
  return
}
```

`main` takes no parameters. A library module - one nothing ever builds
directly - has no `main` at all.

## Builtins

A handful of functions need no import in any module: `len`, `cap`, `append`,
`delete`, `close`, `panic`, `assert`.

```bit
fn builtins(xs: []int, m: map<string, int>) {
  let n = len(xs)
  let c = cap(xs)
  let ys = append(xs, 4, 5)
  delete(m, "key")
  assert(n >= 0)
}
```

## The finished program

Two files, one module boundary: `store/store.bit` owns the record type, the
store, the counter, and the sweep; `main.bit` imports what it needs and runs
it. That is the shortener this whole section built: a store you can swap
implementations of, a trait several stores could share, a counter that works
for any key, failures that are visible instead of guessed at, and a
background task that cleans up without blocking a single request.

## What to read next

The language guide ends here. For task-shaped how-tos - reading files,
serving JSON, running work in parallel, and more - see
[Guides](../guides/README.md). For the full standard library API, see
[Standard library](../stdlib/README.md).

---

Specification: §17.
