# Errors

<!-- doctest: per-block -->

Look up a draft id that was never stored, and `MemoryStore.load` hands back a
zero-valued `Draft` with an empty title. That is indistinguishable from a
real draft whose title is somehow empty. "No such draft" needs to be a
different thing from "here is your draft," visibly, at the type level.

## Fallible returns

Bit's answer is a return type that can be either a value or an error. Write
`T!` instead of `T`, and return either `T` with `return` or an error with
`fail`:

```bit
class Draft {
  export title: string,
}

class MemoryStore {
  drafts: map<string, Draft>
  export load(id: string): Draft! {
    let (d, ok) = this.drafts[id]
    if (!ok) {
      fail newError("no such draft: ${id}")
    }
    return d
  }
}

fn main() {
  let store = MemoryStore{ drafts = map<string, Draft>() }
  let d = store.load("missing") catch Draft{ title = "" }
  println("${d.title}")
}
```

`Draft!` is shorthand for "a `Draft`, or an error." You cannot use a `Draft!`
where a `Draft` is expected without unwrapping it first. You have to say
what happens on failure, either with `catch` (here) or with `?` (next).

## Propagating with `?`

A function that calls a fallible function usually cannot handle the failure
itself; it just needs to pass it up. Postfix `?` does that: on success it
unwraps the value, on failure it returns the error immediately from the
enclosing function, which must itself be fallible.

```bit
class Draft {
  export title: string,
}

class MemoryStore {
  drafts: map<string, Draft>
  export load(id: string): Draft! {
    let (d, ok) = this.drafts[id]
    if (!ok) {
      fail newError("no such draft: ${id}")
    }
    return d
  }
}

fn resolve(store: MemoryStore, id: string): Draft! {
  return store.load(id)?
}
```

`resolve` has nothing useful to do if the id is missing, so `?` sends the
error straight to `resolve`'s own caller.

## Handling with `catch`

`catch` is for the function that actually knows what to do when something
fails. `expr catch default` swaps in a fallback and discards the error;
`expr catch e { ... }` binds the error to `e` so you can look at it:

```bit
class Draft {
  export title: string,
}

class MemoryStore {
  drafts: map<string, Draft>
  export load(id: string): Draft! {
    let (d, ok) = this.drafts[id]
    if (!ok) {
      fail newError("no such draft: ${id}")
    }
    return d
  }
}

fn main() {
  let store = MemoryStore{ drafts = map<string, Draft>() }

  let d = store.load("missing") catch e {
    println("missing -> unresolved: ${e.message()}")
    Draft{ title = "" }
  }
  println("${d.title}")
}
```

The block form still has to produce a `Draft` (its last expression) or
divert control entirely with `return`, `fail`, `panic`, `break`, or
`continue`; it cannot fall off the end with nothing.

## Cleanup with `defer`

`defer call` schedules `call` to run when the enclosing function returns,
however it returns, in last-in-first-out order:

```bit
import { open, create } from "std/fs"

fn importDraft(src: string, dst: string): ()! {
  let f = open(src)?
  defer f.close() // runs on every exit path below
  let g = create(dst)?
  defer g.close()
  g.write(f.readAll()?)?
  return
}
```

Arguments to a deferred call are evaluated at the `defer` statement, not when
it eventually runs. If `create(dst)` fails, `f.close()` still runs: `defer`
was already registered before that line could fail.

## Panics

Fallible returns are for failures you expect - a missing draft is a normal
outcome. A panic means the program hit a state that should be impossible; it
aborts immediately, with no unwinding and no `defer` calls running. Use
`assert` to state an invariant you believe must hold:

```bit
class Draft {
  export views: int,
}

fn recordView(d: Draft): Draft {
  assert(d.views >= 0, "view count must not go negative")
  return Draft{ views = d.views + 1 }
}
```

`fail` is for a caller who might reasonably recover: a missing draft, a bad
request. `panic` is for a broken invariant - a bug, not an expected outcome.
Reach for it to check a precondition your own code broke, never for input
from outside the program.

## Sharp edges

A fallible value is not the value it wraps:

```bit ignore
let d: Draft = store.load("d1") // error[E0041]: expected 'Draft', found 'Draft!'
```

The same holds wherever the value is used, not only in an annotated `let`.
A fallible call in an `if` or `while` condition is E0041 (`expected 'bool',
found 'bool!'`), and one used as an index, a receiver or an iterable, bound by
a bare `let`, or left as a statement on its own is E0190. Each says to add `?`
or `catch`. `let _ = save(d)` is the written way to drop a result on purpose.
`defer` and `spawn` refuse a fallible call too (E0190): they run it with no
caller to hand its error to, and take no `?` or `catch`, so the error is
handled inside a small infallible function and that function is what you defer
or spawn.

`?` only works inside a function whose own return type is fallible; you
cannot propagate a failure out of `fn main() { }`, only out of a function
declared to return `T!`.

`defer` does not run on a panic: a panic aborts immediately with no
unwinding, so a lock or a temp file that must be released before the process
dies has to be released before the call that might panic, not after it in a
`defer`.

## Next

[Concurrency](concurrency.md): a background task can index drafts while the
store keeps serving requests.
