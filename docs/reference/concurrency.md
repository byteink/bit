# Concurrency

Bit's concurrency is Go-like: lightweight green threads started with `spawn`,
typed channels for communication, and `select` to wait on several channels. The
discipline is *do not communicate by sharing memory; share memory by
communicating.* (Spec: §13.7, §16.)

## Green threads with `spawn`

`spawn` runs a call on a new green thread scheduled over a fixed pool of OS
threads. The argument **must be a call expression**; its arguments are evaluated
in the current thread before the new one starts. There is no thread handle in
v0.1 - coordinate through channels.

```bit
fn worker(id: int, out: chan<int>) {
  out <- id * id
}

fn fanOut(n: int) {
  let results = chan<int>(n)
  for (let i = 1; i <= n; i++) {
    spawn worker(i, results) // starts a green thread
  }
  for (let k = 0; k < n; k++) {
    let sq = <- results // collect results
  }
}
```

The runtime fixes the number of OS worker threads at startup - no unbounded
thread creation.

### Stack size, and what happens when you exceed it

**A green thread's stack is fixed at 64 KiB and does not grow.** `main` is the
exception: it gets 8 MiB. So the same function recurses **128x deeper on `main`
than inside `spawn`** - measured on arm64-macos with a 48-byte frame, 174,759
calls succeed on `main` and 1,362 inside `spawn`.

That is not the goroutine behaviour §16.1 compares green threads to, and it is
not a number you can raise: 64 KiB is the *identity granule*. The runtime finds
the running task by masking the stack pointer down to that boundary and reading
a tag stored there, so the size is also the alignment unit and a stack cannot be
larger than it. Raising or growing it is a change to how task identity works,
not a constant edit.

**Exceeding it is now usually a diagnosed crash (#2246).** The runtime installs
a SIGSEGV/SIGBUS handler that recognizes a fault immediately below a stack's
base and exits 2 with `bit: stack overflow` (on `main`) or
`bit: stack overflow in a spawned task` (inside `spawn`), on stderr, from a
built binary as well as `bit run`. It is not guaranteed: the guard page below
a stack is a variable width (tracked separately as #2433), so a deep enough
single frame can occasionally corrupt the task's own bookkeeping before
reaching it, which surfaces as a raw `SIGTRAP`/`SIGILL` instead - still no
message, though attributable from a crash report by program counter. There is
no environment variable or flag that changes the limit.

```bit
fn down(n: int): int {
  if (n == 0) {
    return 0
  }
  return 1 + down(n - 1)
}

fn deepWorker(depth: int, done: chan<int>) {
  done <- down(depth) // 4000 frames: fine on main, SIGSEGV here
}
```

This matters outside synthetic recursion, because every server built on this
runtime handles a request in a green thread - `serveTls` spawns one per
connection. A recursive walk over request-shaped data (a category tree, a
comment thread, a directory listing, a nested JSON document) is running on 64
KiB, and roughly 1,300 frames is within reach of merely deep, not even hostile,
input.

Until the stack grows on demand, write recursion that runs inside `spawn` with
an explicit depth bound and reject input past it, or convert the walk to an
explicit heap-allocated worklist. The fixed size itself is tracked as
**#2613**; nothing in this section is settled design.

## Channels

A channel is a typed synchronization primitive. Unbuffered channels are
synchronous; buffered channels hold up to their capacity.

```bit
fn channels() {
  let c = chan<int>()   // unbuffered (synchronous)
  let b = chan<int>(16) // buffered, capacity 16
}
```

### Send and receive

- **Send** is a statement: `c <- v`. It blocks until a receiver is ready
  (unbuffered) or buffer space exists (buffered).
- **Receive** is an expression: `<- c`. It blocks until a value is available. The
  two-result form reports whether the channel is still open.

```bit
fn pingPong(c: chan<int>) {
  c <- 1             // send
  let x = <- c       // receive
  let (v, ok) = <- c // ok is false if closed and drained
}
```

### Close and range

`close(c)` marks a channel closed: further sends panic, and receives drain any
buffered values then yield `(zero, false)`. Only the sending side should close.
Range over a channel with `for ... of` until it is closed and drained.

```bit
fn producer(out: chan<int>) {
  for (let i = 0; i < 3; i++) {
    out <- i
  }
  close(out) // signal completion
}

fn consumer(input: chan<int>) {
  for v of input { // receives until closed and drained
    // handle v
  }
}
```

### `nil` channel behavior

Sending on or receiving from a `nil` channel blocks forever; closing a `nil` or
already-closed channel panics. Allocate with the constructor form first.

## `select`

`select` waits until one of its case communications can proceed, chooses one
uniformly at random among those ready, and runs its clause. A `default` clause,
if present, runs when no case is immediately ready, making the select
non-blocking.

```bit
fn pump(input: chan<int>, out: chan<int>, next: int) {
  select {
    case v = <- input:
      handle(v)
    case out <- next:
      advance()
    default:
      idle()
  }
}

fn handle(v: int) {}
fn advance() {}
fn idle() {}
```

An empty `select {}` blocks forever. Case operands (and the sent value for a
send case) are evaluated once, at entry to the select.

## Memory model

For programs that use channels correctly, Bit gives a sequentially consistent
view through these happens-before edges (§13.7):

1. `spawn f(...)` happens-before the spawned function begins.
2. A send happens-before the corresponding receive completes.
3. Closing a channel happens-before a receive that observes it closed.
4. On an unbuffered channel, a receive happens-before the send completes.

Accessing shared **mutable** memory from multiple threads without an ordering
edge established through channels is a **data race**, and its result is
unspecified. v0.1 provides channels as the only synchronization primitive;
mutexes and atomics are deferred to a later release.
