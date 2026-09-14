# Run work in parallel

`spawn` starts a call on a new green thread; a channel is how it hands a
result back. There is no shared variable two threads write at once - a
value crosses from one to the other by being sent down a channel, and that
send is itself what makes the value safe to read on the other side.

<!-- doctest: per-block -->

## The shortest complete program

```bit
fn square(id: int, out: chan<int>) {
  out <- id * id
}

fn main() {
  let n = 5
  let results = chan<int>(n)
  for (let i = 1; i <= n; i++) {
    spawn square(i, results)
  }
  let sum = 0
  for (let k = 0; k < n; k++) {
    sum += <- results
  }
  println("sum of squares = ${sum}")
}
```

Running it prints:

```
sum of squares = 55
```

`chan<int>(n)` is a buffered channel that can hold `n` values without a
receiver waiting; five sends from five spawned threads all succeed without
blocking on each other. `spawn square(i, results)` must be a call
expression - its arguments (`i`, `results`) are evaluated on the calling
thread before the new one starts, so each spawned call gets its own `i`, not
a variable later iterations will change. The two receive loops - one to
start the work, one to collect it - are what make the sum deterministic even
though the five squarings finish in whatever order the scheduler picks.

## When you need to wait on more than one channel

`select` waits on several channel operations at once and runs whichever one
becomes ready first:

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

`default` makes the whole `select` non-blocking: it runs when nothing else
is ready yet, rather than waiting. Drop it and `select` blocks until one
case can proceed.

## Signaling that a stream is finished

`close(c)` marks a channel closed, and `for ... of` ranges over a channel
until it is closed and fully drained - only the sending side should close:

```bit
fn producer(out: chan<int>) {
  for (let i = 0; i < 3; i++) {
    out <- i
  }
  close(out)
}

fn consumer(input: chan<int>) {
  for v of input {
    // handle v
  }
}
```

## Sharp edges

- **A green thread's stack is a fixed 64 KiB and does not grow** - `main`
  alone gets 8 MiB. A function that recurses comfortably on `main` can
  overflow inside `spawn` at roughly 1/128th the depth. Exceeding it exits 2
  with `bit: stack overflow in a spawned task` on stderr, rather than
  corrupting memory silently, but there is no flag that raises the limit.
  Recursion that runs inside `spawn` - which includes every request handler
  an HTTP server hands off - needs an explicit depth bound or an explicit
  heap-allocated worklist instead of unbounded recursion. Full numbers in
  the [Concurrency reference](../reference/concurrency.md#stack-size-and-what-happens-when-you-exceed-it).
- Sending on, or closing, a `nil` channel panics; receiving from a `nil`
  channel blocks forever. Always allocate with `chan<T>()` or `chan<T>(n)`
  before using it.
- Reading or writing shared mutable memory from two threads with no channel
  ordering between them is a data race with an unspecified result. v0.1 has
  no mutex or atomic - channels are the only synchronization primitive, so
  a value that needs to be touched from more than one thread needs to travel
  by channel, not by a shared variable.

## What to read next

The [Concurrency reference](../reference/concurrency.md) covers the memory
model's happens-before guarantees in full. `std/http`'s server spawns one
green thread per connection - see
[Serve JSON over HTTP](serve-json-over-http.md) for what that means for a
handler that recurses over request data.
