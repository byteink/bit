# Concurrency

<!-- doctest: per-block -->

Counting every draft's tags one at a time is slow once there are many of
them. `spawn` starts a call on a new green thread - lightweight, scheduled
over a fixed pool of OS threads, not one per task - and a channel is how it
hands a result back. There is no shared variable two threads write at once: a
value crosses from one to the other by being sent down a channel, and that
send is what makes the value safe to read on the other side.

## Starting work with `spawn`

```bit
fn tagCount(tags: []string, out: chan<int>) {
  out <- len(tags)
}

fn main() {
  let drafts = [][]string{
    []string{ "bit", "notes" },
    []string{ "draft" },
    []string{ "bit", "log", "notes" },
  }
  let counts = chan<int>(len(drafts))
  for tags of drafts {
    spawn tagCount(tags, counts)
  }
  let total = 0
  for tags of drafts {
    total += <- counts
  }
  println("total tags = ${total}")
}
```

`spawn tagCount(...)` must be a call expression; its arguments are evaluated
on the calling thread before the new one starts, so each spawned call gets
its own `tags`, not a variable a later iteration will change. There is no
handle to a spawned task and nothing to join; the only way to find out what
it did, or that it finished, is a channel.

When the work is a few statements rather than one call, spawn a block:
`spawn { ... }` runs the statements on the new thread, and it reads the
enclosing function's variables the way an arrow function does (shared, not
copied). It is also where a fallible call's error is handled, since a spawned
task has no caller to return it to:

```bit ignore
spawn {
  let n = countTags(tags) catch e { 0 }
  counts <- n
}
```

## Channels: send, receive, close

`chan<int>(n)` above is buffered with room for `n` values, so every send
succeeds without a receiver waiting. `chan<int>()` is unbuffered and forces
the sender to wait for a receiver. Send is a statement, `c <- v`; receive is
an expression, `<- c`. `close(c)` marks a channel closed, and `for ... of`
ranges over a channel until it is closed and fully drained; only the sending
side should close.

```bit
fn produce(out: chan<int>) {
  let i = 0
  while (i < 3) {
    out <- i
    i = i + 1
  }
  close(out)
}

fn main() {
  let c = chan<int>(3)
  spawn produce(c)
  for v of c {
    println("${v}")
  }
}
```

## Waiting on more than one channel with `select`

`select` waits on several channel operations at once and runs whichever one
becomes ready first. `default` makes the whole `select` non-blocking: it
runs when nothing else is ready, instead of waiting.

```bit
fn indexLoop(stop: chan<bool>, indexed: chan<int>) {
  let done = 0
  let running = true
  while (running) {
    select {
      case _ = <- stop:
        running = false
      default:
        done = done + 1
    }
  }
  indexed <- done
}

fn main() {
  let stop = chan<bool>(1)
  let indexed = chan<int>(1)
  spawn indexLoop(stop, indexed)
  stop <- true
  println("indexed ${<- indexed} time(s)")
}
```

## Sharp edges

- A green thread's stack is a fixed 64 KiB and does not grow, unlike
  `main`'s 8 MiB. A function that recurses comfortably on `main` can
  overflow inside `spawn` at a small fraction of the depth. Recursion that
  runs inside `spawn`, including every request handler a web server hands
  off, needs an explicit depth bound or an explicit worklist instead of
  unbounded recursion.
- Reading or writing shared mutable memory from two threads with no channel
  ordering between them is a data race with an unspecified result. Bit has
  no mutex or atomic in v0.1: channels are the only synchronization
  primitive, so a value touched from more than one thread needs to travel by
  channel, not by a shared variable.
- Sending on, or closing, a `nil` channel panics; receiving from a `nil`
  channel blocks forever. Always allocate with `chan<T>()` or `chan<T>(n)`
  before using it.

## When not to reach for `spawn`

If the work only needs to happen once, inline, a plain function call is
simpler and has no coordination to get wrong. Reach for `spawn` when work
genuinely needs to happen independent of a single request or on its own
schedule.

## Next

[Modules](modules.md) covers splitting a program like this across files as it
grows.
