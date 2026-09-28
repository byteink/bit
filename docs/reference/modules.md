# Modules

<!-- doctest: per-block -->

One file holding the `Draft` class, the store, and the counter gets crowded
as a program grows. Storage logic belongs in its own file, so `main.bit` can
be just the part that wires everything together and runs it.

## A module is a directory

A Bit module is a directory of `.bit` files that share one flat namespace:
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
is a project-relative module: a project split into a `store` directory next
to `main.bit` imports it as `"./store"`.

## Visibility with `export`

Visibility is explicit, not inferred from naming. A declaration is
module-private unless marked `export`, and that applies separately to each
class field and method too:

```bit
export class Draft {
  export id: string,
  export title: string,
  export tags: []string,
}
```

Every field here is exported because code in another module needs to read
`title` and `tags` off a `Draft` it gets back from the store. Drop `export`
from a field and code outside this module can no longer read or write it,
even though code inside the module still can.

## Splitting the store out

`store/store.bit` becomes the whole record-and-storage layer:

```bit
export class Draft {
  export id: string,
  export title: string,
}

export interface Store {
  save(id: string, d: Draft),
  load(id: string): Draft,
}

export class MemoryStore {
  export drafts: map<string, Draft>
  export save(id: string, d: Draft) {
    this.drafts[id] = d
  }
  export load(id: string): Draft {
    return this.drafts[id]
  }
}

export fn memoryStore(): MemoryStore {
  return MemoryStore{ drafts = map<string, Draft>() }
}
```

`drafts` is exported too, even though callers holding only the `Store`
interface never read it directly; anything holding the concrete
`MemoryStore` is entitled to.

## Wiring it from `main.bit`

`main.bit` imports the pieces it needs by name:

```bit ignore
// Imports a sibling module directory ("./store") and cannot be checked on
// its own here.
import { Draft, Store, memoryStore } from "./store"

fn main() {
  let store: Store = memoryStore()
  store.save("d1", Draft{ id = "d1", title = "Notes on Bit" })
  println("${store.load("d1").title}")
}
```

Only exported names are importable: naming an unexported one from outside
its module is an error, not a silent miss, and an import cycle between two
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

`main` takes no parameters. A library module, one nothing ever builds
directly, has no `main` at all.

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

## Next

For task-shaped how-tos, see [the Book](../book/README.md). For the full
standard library API, see [Standard library](../stdlib/README.md).
