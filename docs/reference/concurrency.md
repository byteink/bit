# Concurrency

Bit's concurrency is Go-like: lightweight green threads started with `spawn`,
typed channels for communication, and `select` to wait on several channels. The
discipline is *do not communicate by sharing memory; share memory by
communicating.* (Spec: §13.7, §16.)

## Green threads with `spawn`

`spawn` runs a call on a new green thread scheduled over a fixed pool of OS
threads. The argument **must be a call expression**; its arguments are evaluated
in the current thread before the new one starts. There is no thread handle in
v0.1 — coordinate through channels.

```bit
function worker(id: int, out: chan<int>) {
  out <- id * id
}

function fanOut(n: int) {
  let results = chan<int>(n)
  for (let i = 1; i <= n; i++) {
    spawn worker(i, results)     // starts a green thread
  }
  for (let k = 0; k < n; k++) {
    let sq = <- results          // collect results
  }
}
```

The runtime fixes the number of OS worker threads at startup — no unbounded
thread creation.

## Channels

A channel is a typed synchronization primitive. Unbuffered channels are
synchronous; buffered channels hold up to their capacity.

```bit
function channels() {
  let c = chan<int>()      // unbuffered (synchronous)
  let b = chan<int>(16)    // buffered, capacity 16
}
```

### Send and receive

- **Send** is a statement: `c <- v`. It blocks until a receiver is ready
  (unbuffered) or buffer space exists (buffered).
- **Receive** is an expression: `<- c`. It blocks until a value is available. The
  two-result form reports whether the channel is still open.

```bit
function pingPong(c: chan<int>) {
  c <- 1                         // send
  let x = <- c                   // receive
  let (v, ok) = <- c             // ok is false if closed and drained
}
```

### Close and range

`close(c)` marks a channel closed: further sends panic, and receives drain any
buffered values then yield `(zero, false)`. Only the sending side should close.
Range over a channel with `for ... of` until it is closed and drained.

```bit
function producer(out: chan<int>) {
  for (let i = 0; i < 3; i++) {
    out <- i
  }
  close(out)                     // signal completion
}

function consumer(in: chan<int>) {
  for v of in {                  // receives until closed and drained
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
function pump(in: chan<int>, out: chan<int>, next: int) {
  select {
    case v = <- in:
      handle(v)
    case out <- next:
      advance()
    default:
      idle()
  }
}

function handle(v: int) { }
function advance() { }
function idle() { }
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
