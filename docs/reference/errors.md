# Errors

`MemoryStore.get` has a problem: look up a code that was never stored, and it
hands back a zero-valued `Link` with an empty URL. That is indistinguishable
from a real link whose URL is somehow empty. "No such code" needs to be a
different thing from "here is your link," visibly, at the type level - not a
value the caller has to guess is fake.

<!-- doctest: per-block -->

## Fallible returns

Bit's answer is a return type that can be either a value or an error. Write
`T!` instead of `T`, and return either `T` with `return` or an error with
`fail`:

```bit
class Link {
  export url: string,
  export created: i64,
  export hits: int,
}

class MemoryStore {
  links: map<string, Link>
  export get(code: string): Link! {
    let (l, ok) = this.links[code]
    if (!ok) {
      fail newError("no such code: ${code}")
    }
    return l
  }
}

fn main() {
  let store = MemoryStore{ links: map<string, Link>() }
  let l = store.get("abc123") catch Link{ url: "", created: 0, hits: 0 }
  println("abc123 -> ${l.url}")
}
```

`Link!` is shorthand for "a `Link`, or an error." You cannot get a `Link` out
of a `Link!` by just using it as one - see Sharp edges below. You have to say
what happens on failure, either with `catch` (here) or with `?` (next).

## Propagating with `?`

A function that calls a fallible function usually cannot handle the failure
itself - it just needs to pass it up. Postfix `?` does that: on success it
unwraps the value, on failure it returns the error immediately from the
enclosing function, which must itself be fallible.

```bit
class Link {
  export url: string,
  export created: i64,
  export hits: int,
}

class MemoryStore {
  links: map<string, Link>
  export get(code: string): Link! {
    let (l, ok) = this.links[code]
    if (!ok) {
      fail newError("no such code: ${code}")
    }
    return l
  }
}

fn resolve(store: MemoryStore, code: string): Link! {
  let l = store.get(code)?
  return l
}
```

`resolve` has nothing useful to do if the code is missing, so it does not
handle the error at all - `?` sends it straight to `resolve`'s own caller.

## Handling with `catch`

`catch` is for the function that actually knows what to do when something
fails. Two forms: `expr catch default` swaps in a fallback value and
discards the error; `expr catch e { ... }` binds the error to `e` so you can
look at it.

```bit
class Link {
  export url: string,
  export created: i64,
  export hits: int,
}

class MemoryStore {
  links: map<string, Link>
  export get(code: string): Link! {
    let (l, ok) = this.links[code]
    if (!ok) {
      fail newError("no such code: ${code}")
    }
    return l
  }
}

fn main() {
  let store = MemoryStore{ links: map<string, Link>() }

  store.get("zzz") catch e {
    println("zzz -> unresolved: ${e.message()}")
    Link{ url: "", created: 0, hits: 0 }
  }
}
```

The block form still has to produce a `Link` (its last expression) or divert
control entirely with `return`, `fail`, `panic`, `break`, or `continue` - you
cannot fall off the end with nothing.

## Cleanup with `defer`

Once the shortener keeps a resource open - a file, a connection - closing it
on every exit path gets repetitive. `defer call` schedules a call to run when
the enclosing function returns, however it returns, in last-in-first-out
order:

```bit
import { open, create } from "std/fs"

fn copyFile(src: string, dst: string): ()! {
  let f = open(src)?
  defer f.close() // runs on every exit path below
  let g = create(dst)?
  defer g.close()
  g.write(f.readAll()?)?
  return
}
```

Arguments to a deferred call are evaluated at the `defer` statement, not when
it eventually runs, so `f` and `g` above are pinned to the files this call
opened.

## Panics

Fallible returns are for failures you expect - a missing code is a normal
outcome of running a link shortener. A panic is different: it means the
program hit a state that should be impossible, and it aborts immediately,
with no unwinding and no `defer` calls running. Use `assert` to state an
invariant you believe must hold:

```bit
class Link {
  export url: string,
  export created: i64,
  export hits: int,
}

fn recordHit(l: Link): Link {
  assert(l.hits >= 0, "hit count must not go negative")
  return Link{ url: l.url, created: l.created, hits: l.hits + 1 }
}
```

If `recordHit` is ever called with a link whose count already went negative,
that is a bug somewhere else in the program, not a condition the caller
should have to handle with `catch`.

## Sharp edges

A fallible value is not the value it wraps. You cannot use a `Link!` where a
`Link` is expected without unwrapping it first:

```bit ignore
let l: Link = store.get("abc123") // error: Link! is not Link
```

```
error[E0041]: expected 'Link', found 'Link!'
```

`?` only works inside a function whose own return type is fallible - you
cannot propagate a failure out of `main() { }`, only out of a function
declared `T!`.

## What to read next

The shortener now tells the truth about missing codes. Next:
[Concurrency](concurrency.md), where a background task expires old links
while the store keeps serving requests.

---

Specification: §18.
