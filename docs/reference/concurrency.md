# Concurrency

Links should not live forever. You want old ones to expire, but you do not
want every lookup to pay the cost of checking every link's age, and you do
not want the store to stop serving requests while it cleans up. That calls
for a background task that sweeps expired links on its own schedule while
the rest of the program keeps running.

<!-- doctest: per-block -->

## Starting a background task with `spawn`

`spawn` runs a call on a new green thread - lightweight, scheduled over a
fixed pool of OS threads, not one per task. The argument must be a call
expression:

```bit
fn sweepOnce(expiresAt: map<string, i64>, nowNs: i64): int {
  let expired = []string(0)
  for (code, at) of expiresAt {
    if (at > 0 && at <= nowNs) {
      expired = append(expired, code)
    }
  }
  return len(expired)
}

fn sweepLoop(expiresAt: map<string, i64>, done: chan<int>) {
  done <- sweepOnce(expiresAt, 0)
}

fn main() {
  let expiresAt = map<string, i64>()
  let done = chan<int>(1)
  spawn sweepLoop(expiresAt, done)
  let removed = <- done
  println("swept ${removed} link(s)")
}
```

There is no handle to a spawned task and nothing to join - the only way to
find out what it did, or that it finished, is a channel.

## Channels: send, receive, close

A channel is a typed pipe between tasks. `chan<int>(1)` above is buffered
with room for one value; `chan<int>()` is unbuffered and forces the sender to
wait for a receiver. Send is a statement, `c <- v`; receive is an expression,
`<- c`:

```bit
fn pingPong() {
  let c = chan<int>(1)
  c <- 1       // send, does not block: the buffer has room
  let x = <- c // receive
}
```

## Stopping the sweep with `select`

The sweep loop needs to keep going until told to stop, but it also should not
block forever waiting for a stop signal between sweeps. `select` with a
`default` case checks a channel without blocking:

```bit
import { sleep, Millisecond } from "std/time"

fn sweepLoop(stop: chan<bool>, done: chan<int>) {
  let removed = 0
  let running = true
  while (running) {
    select {
      case _ = <- stop:
        running = false
      default:
        sleep(5 * Millisecond)
        removed = removed + 1
    }
  }
  done <- removed
}
```

Every pass through the loop, `select` checks whether `stop` has a value
waiting. If it does not, `default` runs instead of blocking, so the loop can
go do another sweep. Send `true` on `stop` from elsewhere and the next pass
picks it up.

## Wired into the shortener

Put the pieces together: `Link` gets an `expiresAt`, `sweepLoop` walks the
concrete `MemoryStore` directly (it needs the map, not just what `Store`
exposes), and `main` starts it, lets it run for a while, then stops it and
reads how many links it removed:

```bit
import { now, sleep, Millisecond } from "std/time"

class Link {
  export url: string,
  export created: i64,
  export hits: int,
  export expiresAt: i64,
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
  get(code: string): Link!
  has(code: string): bool {
    let l = this.get(code) catch Link{ url = "", created = 0, hits = 0, expiresAt = 0 }
    return len(l.url) > 0
  }
}

interface Store {
  put(code: string, l: Link),
  get(code: string): Link!,
  has(code: string): bool,
}

class MemoryStore {
  use Existence

  links: map<string, Link>
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

fn memoryStore(): MemoryStore {
  return MemoryStore{ links = map<string, Link>() }
}

// Removes every link whose expiresAt has passed nowNs, returning the count.
fn sweepOnce(store: MemoryStore, nowNs: i64): int {
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

fn sweepLoop(store: MemoryStore, stop: chan<bool>, done: chan<int>) {
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

fn main() {
  let ms = memoryStore()
  let store: Store = ms

  let expiring = "exp1"
  store.put(
    expiring,
    Link{
      url = "https://example.org",
      created = now().ns,
      hits = 0,
      expiresAt = now().ns + 10 * Millisecond,
    },
  )

  let stop = chan<bool>(1)
  let done = chan<int>(1)
  spawn sweepLoop(ms, stop, done)

  println("has ${expiring} right after put: ${store.has(expiring)}")
  sleep(40 * Millisecond)
  stop <- true
  let removed = <- done

  println("swept ${removed} expired link(s)")
  println("has ${expiring} after the sweep: ${store.has(expiring)}")
}
```

## Sharp edges

- A green thread's stack is fixed at 64 KiB and does not grow, unlike
  `main`'s 8 MiB. `sweepLoop` above is shallow, but a recursive walk spawned
  the same way is not - keep recursion inside `spawn` bounded, or convert it
  to an explicit worklist.
- Accessing `store.links` from two tasks at once with no channel between them
  is a data race with an unspecified result. `sweepLoop` above is safe only
  because nothing else touches `ms` while it runs; a handler that also wrote
  to the store while the sweep ran would need a channel to hand it off, not
  direct access from both sides.
- `close(c)` on an already-closed or `nil` channel panics. Only the sender
  should close a channel.

## When not to reach for `spawn`

If the sweep only needs to happen once per request - check whether the link
you just looked up is expired, right there - a plain function call is
simpler and has no coordination to get wrong. Reach for `spawn` when the work
genuinely needs to happen on its own schedule, independent of any single
request.

## What to read next

The shortener runs, stores, errors, and cleans up after itself, all in one
file. Next: [Modules](modules.md), where it gets split across files as it
grows.

---

Specification: §13.7, §16.
