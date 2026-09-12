# std/runtime

The **panic boundary**: run a call so that a panic inside it ends the call
instead of the program.

A panic is for a programmer error or a broken invariant (SPEC §18.4), and by
default it aborts the process. This module is how one failing unit of work — a
connection task, a test case, a plugin — is contained instead of taking
everything with it. It is not an error-handling mechanism: an expected failure
still returns `T!` and propagates with `?`.

### `runRecovering(f: () => ()): (bool, string)`

Run `f` with a panic boundary installed on the current task. Returns
`(false, "")` when `f` returns normally, and `(true, message)` when a panic
raised in `f` — or in anything `f` calls on the same task — was caught: the
frames between the panic site and this call are discarded and control resumes
here.

```bit
import { runRecovering } from "std/runtime"

fn parseAge(s: string): int {
  if (len(s) == 0) {
    panic("empty age")
  }
  return len(s)
}

fn handle(s: string): string {
  let age = 0
  let (panicked, msg) = runRecovering(() => {
    age = parseAge(s)
  })
  if (panicked) {
    return "rejected: ${msg}"
  }
  return "age ${age}"
}
```

`f` takes no arguments and returns nothing, so anything it produces travels
through a captured binding — which is also how a caller sees how far `f` got
before it panicked. A binding written before `f` was called keeps its value; a
binding `f` wrote before panicking keeps what `f` wrote.

The message is the panic's own: `panic(msg)`'s string, or the runtime's wording
for an implicit panic (`index out of range`, `integer division by zero`,
`integer overflow`, `call of a nil function`,
`method call on a nil interface value`) — the same text an unrecovered panic
writes to stderr. The bytes are copied, so the returned string stays valid after
a later panic.

## What a boundary does not do

**Recovery is per task.** A boundary installed on one task never catches a panic
raised on another; a `spawn`ed task needs its own `runRecovering`.

**Boundaries nest, innermost first.** The innermost boundary on the current task
wins. A panic raised inside a handler — after `runRecovering` has resumed and
before it returns — reaches the next boundary out, never the one already
unwound.

**Deferred calls do not run** (SPEC §18.5). There is no unwinding of any kind,
so nothing in the discarded frames gets to clean up. Anything a panic path must
release has to be released explicitly, before the call that may panic.

**A held `std/sync` mutex stays held.** That is the previous rule applied to a
lock: the `unlock` in a discarded frame never runs, so a recovered panic inside
a critical section leaves the mutex locked forever. Do not wrap a critical
section in `runRecovering` — wrap the work, and take the lock around the result.

**Four classes stay fatal** whatever the boundary does: a runtime-internal
invariant failure, out of memory, a panic raised while the task is blocked in a
syscall, and a panic raised on a thread that is not running a task. In the last
case no boundary is installed at all, `f` runs unguarded, and a panic in it ends
the program exactly as it would without this call.

## Task-local storage

**One opaque word per task**, inherited by copy at `spawn` and never shared
afterward. This is a raw primitive, not a `Context` type: it carries one word
of whatever a caller puts in it, and any typed request-scoped mechanism (a
trace id, a deadline, an identity) is built on top of it by the caller, not
provided here.

### `taskLocalGet(): int`

Returns the current task's task-local word. `0` for a task that has never set
it, directly or by inheritance — in particular, the first task in the program.

### `taskLocalSet(v: int)`

Sets the current task's task-local word. There is no cross-task accessor: a
task can read and write only its own word.

```bit
import { taskLocalGet, taskLocalSet } from "std/runtime"

fn worker(id: int, results: chan<int>) {
  // Inherited from the task that spawned this one, at the moment it spawned.
  let inherited = taskLocalGet()
  taskLocalSet(id)
  results <- inherited
}

fn main() {
  taskLocalSet(7)
  let results = chan<int>(0)
  spawn worker(1, results)
  let got = <- results
  print("${got}\n")            // 7 — the value inherited at spawn time
  print("${taskLocalGet()}\n") // 7 — the child's write never reaches the parent
}
```

**Inheritance is copy-on-spawn, not a live link.** A child's later write is
never visible to the task that spawned it, or to any sibling spawned from the
same parent — each task's word is its own from the moment it is copied.

**Survives a park/resume on the same task.** Blocking on a channel, a mutex, or
a `WaitGroup` parks and resumes the same task (the same task identity), so
task-local storage is unaffected by blocking — it is lost only if code runs
outside any task, which ordinary Bit code cannot do (`spawn` is the only
task-creation primitive in the language).
