# std/sync

Locks and other shared-memory tools for Bit code that truly runs in
parallel. **Channels are still the preferred way to coordinate work** -
*do not communicate by sharing memory; share memory by communicating*.
Reach for `std/sync` only on a shared-memory hot path, or to coordinate a
fixed group of parallel workers, where routing every access through a
channel costs more than the data warrants.

Every tool here is built entirely from atomic operations and channels - no
new runtime or grammar support. A blocking call (`Mutex.lock`,
`WaitGroup.wait`) parks the caller on the scheduler rather than spinning,
because it is implemented as a channel operation, and channel operations
already park the caller instead of spinning.

```bit ignore
import { Mutex, WaitGroup, RWMutex, Once, AtomicI64 } from "std/sync"
```

<!-- doctest: per-block -->

## Mutex

### `Mutex`

Mutual exclusion lock. A class, so it is a reference type: every holder of the
same `Mutex` value contends for the same lock. The zero-valued `Mutex` (never
built with `Mutex()`) is not usable - always construct with `Mutex()`.

### `Mutex()`

A `Mutex` ready to use, unlocked.

### `Mutex.lock()`

Blocks until the lock is free, then acquires it. Contention parks the caller;
it does not spin.

### `Mutex.unlock()`

Releases the lock. Unlocking a `Mutex` the caller does not hold is a caller
bug, same as Go's `sync.Mutex` - it is not detected.

```bit
import { Mutex, WaitGroup } from "std/sync"

// N spawned tasks incrementing a shared counter under a Mutex land on an
// exact total - the same shape as this module's directory KAT
// (examples/syncmutex), just small enough to typecheck as a doc example.
fn fanOutCount(counter: []i64, mu: Mutex, wg: WaitGroup, n: int) {
  let i = 0
  while (i < n) {
    spawn bump(counter, mu, wg)
    i = i + 1
  }
}

fn bump(counter: []i64, mu: Mutex, wg: WaitGroup) {
  mu.lock()
  counter[0] = counter[0] + 1
  mu.unlock()
  wg.done()
}
```

## RWMutex

### `RWMutex`

A reader/writer lock: any number of readers may hold it at once, but a writer
excludes everyone. Construct with `RWMutex()`.

### `RWMutex()`

An `RWMutex` ready to use, unlocked.

### `RWMutex.rLock()`

Acquires the lock for reading. Blocks only while a writer holds it.

### `RWMutex.rUnlock()`

Releases a read lock acquired by `rLock()`.

### `RWMutex.lock()`

Acquires the lock for writing, excluding both readers and other writers.

### `RWMutex.unlock()`

Releases a write lock acquired by `lock()`.

```bit
import { RWMutex } from "std/sync"

fn readCached(cache: []i64, mu: RWMutex): i64 {
  mu.rLock()
  let v = cache[0]
  mu.rUnlock()
  return v
}

fn refreshCached(cache: []i64, mu: RWMutex, v: i64) {
  mu.lock()
  cache[0] = v
  mu.unlock()
}
```

## WaitGroup

### `WaitGroup`

Coordinates a fan-out/fan-in: `add(n)` before spawning `n` workers, `done()`
at the end of each, `wait()` in the coordinator. Single-use - construct a
fresh `WaitGroup` per fan-out round rather than reusing one after `wait()`
returns.

### `WaitGroup()`

A fresh `WaitGroup` with a zero counter.

### `WaitGroup.add(delta: i64)`

Adds `delta` (may be negative) to the counter. Call before spawning the
workers that will call `done()` - `spawn` guarantees the count is visible to
the new worker with no further synchronization needed.

### `WaitGroup.done()`

Decrements the counter by one. The call that brings it to zero unblocks every
`wait()`.

### `WaitGroup.wait()`

Blocks until the counter reaches zero.

```bit
import { WaitGroup } from "std/sync"

fn fanIn(n: int): int {
  let wg = WaitGroup()
  wg.add(n)
  let i = 0
  while (i < n) {
    spawn finish(wg)
    i = i + 1
  }
  wg.wait()
  return n
}

fn finish(wg: WaitGroup) {
  wg.done()
}
```

## Once

### `Once`

Runs a function exactly once, however many green threads call `do`
concurrently. Construct with `Once()`.

### `Once()`

A fresh `Once`, not yet run.

### `Once.do(f: () => ())`

Runs `f` on the first call only. Every call - concurrent or not - blocks
until that first run has completed.

```bit
import { Once } from "std/sync"

fn initOnce(o: Once, ready: []i64) {
  o.do(() => {
    ready[0] = 1
  })
}
```

## Atomics

### `AtomicI64`

A single `i64` accessed only through sequentially-consistent atomic
operations - the strongest ordering, and the only one this module offers.
Bit's generic constraints are interface bounds only, so there is no single
`Atomic<T>` to write against an "integer" bound - this offers one concrete
class per width in common use, the same shape as
Go's `sync/atomic.Int64`.

### `AtomicI64(v: i64)`

An `AtomicI64` initialized to `v`.

### `AtomicI64.load(): i64`

Reads the current value.

### `AtomicI64.store(v: i64)`

Writes `v`.

### `AtomicI64.add(delta: i64): i64`

Adds `delta` and returns the **new** value (unlike the raw `atomicAdd`
builtin, which returns the previous one - this matches Go's
`atomic.Int64.Add`).

### `AtomicI64.compareAndSwap(old: i64, newVal: i64): bool`

If the current value equals `old`, stores `newVal` and returns `true`;
otherwise leaves it unchanged and returns `false`.

### `AtomicI64.swap(v: i64): i64`

Stores `v` and returns the previous value.

### `AtomicU64`

The `u64` counterpart of `AtomicI64`, for unsigned counters.

### `AtomicU64(v: u64)`

An `AtomicU64` initialized to `v`.

### `AtomicU64.load(): u64`

Reads the current value.

### `AtomicU64.store(v: u64)`

Writes `v`.

### `AtomicU64.add(delta: u64): u64`

Adds `delta` and returns the new value.

### `AtomicU64.compareAndSwap(old: u64, newVal: u64): bool`

If the current value equals `old`, stores `newVal` and returns `true`;
otherwise leaves it unchanged and returns `false`.

### `AtomicU64.swap(v: u64): u64`

Stores `v` and returns the previous value.

```bit
import { AtomicI64 } from "std/sync"

fn raceFreeCounter(n: i64): i64 {
  let counter = AtomicI64(0)
  let i = 0
  while (i < n) {
    counter.add(1)
    i = i + 1
  }
  return counter.load()
}
```

## Pool

Opening a database connection, a Redis link, or anything else expensive to
create is fine once. Doing it on every request is not: each one pays a
handshake, and a burst of requests can open more of them than the far end
allows. `Pool<T>` keeps a bounded set of resources open, hands one out at a
time, and returns it to the set when the caller is done - the same shape
`std/sql`'s own connection pool has used for a while, generalized to any
resource `T`.

You tell the pool three things: how to open a resource, how to close one,
and how to tell a live one from a dead one. The pool decides when to open a
new one, when to reuse an idle one, and when a resource has gotten too old
to trust.

### `PoolOptions`

The pool's tunables. Every field has a default, so `PoolOptions{}` is a
complete, working configuration.

- `maxSize` - the most resources open at once (default 10).
- `maxIdle` - how many resources may sit idle; a resource released above
  this is closed instead of parked (default -1, no cap beyond `maxSize`; 0
  parks nothing).
- `minIdle` - how many idle resources `maxIdleTime` will not reap below
  (default 0).
- `maxIdleTime` - retire a resource idle this many milliseconds (default
  600,000; 0 or less means no limit).
- `maxLifetime` - retire a resource this many milliseconds after it was
  opened, however healthy it looks (default 1,800,000; 0 or less means no
  limit).
- `acquireTimeout` - how long `acquire()` waits before failing (default
  5,000).

### `Lease<T>`

What `acquire()` returns and `release()` takes back. `lease.value` is the
resource itself; the rest is the pool's own bookkeeping, kept alongside it
for as long as the caller holds it.

### `PoolStats`

A snapshot from `Pool.stats()`: `open` (resources that exist), `idle`
(parked and ready), `checkedOut` (out with a caller) and `waiting` (callers
queued for one).

### `Pool<T>(open: () => T!, close: (T) => (), healthy: (T) => bool, opts: PoolOptions)`

Builds a pool that opens resources through `open`, closes them through
`close`, and validates one before reuse through `healthy`. Nothing opens
here - resources are created on demand, up to `opts.maxSize`.

### `Pool.acquire(): Lease<T>!`

Checks a resource out, opening one or waiting for one as `opts` allows.
Waiters are served strictly in the order they arrived. Fails once
`opts.acquireTimeout` passes rather than waiting forever.

### `Pool.release(lease: Lease<T>, ok: bool)`

Hands `lease` back. `ok = false` closes the resource instead of reusing it -
the caller's way of saying "this one is bad", for a failure `healthy` cannot
see on its own.

### `Pool.with<R>(f: (T) => R!): R!`

Acquires a resource, runs `f` on it, and releases it on every path,
including a failing `f` - the usual way to use a pool, so a caller cannot
forget to release.

### `Pool.close()`

Closes every idle resource and fails every waiting caller. A resource still
checked out is closed as it comes back. Safe to call more than once.

### `Pool.stats(): PoolStats`

A point-in-time snapshot of how the pool is doing.

```bit
import { Pool, Lease, PoolOptions, PoolStats } from "std/sync"

// A toy resource standing in for anything expensive to open - a database or
// a Redis connection, in a real program.
class widgetConn {
  id: i64,
}

class widgetCounter {
  next: i64 = 0,
}

fn openWidget(counter: widgetCounter): widgetConn! {
  counter.next = counter.next + 1
  return widgetConn{ id = counter.next }
}

fn closeWidget(c: widgetConn) {
  // A real resource would close a socket or a file here.
}

fn widgetHealthy(c: widgetConn): bool {
  return true
}

fn newWidgetPool(): Pool<widgetConn> {
  let counter = widgetCounter{}
  return Pool<widgetConn>(
    () => openWidget(counter),
    closeWidget,
    widgetHealthy,
    PoolOptions{ maxSize = 5, acquireTimeout = 2_000 },
  )
}

// The usual way to use a pool: acquire, run, release on every path.
fn widgetId(p: Pool<widgetConn>): i64! {
  return p.with<i64>((c) => {
    return c.id
  })?
}

// The manual form, for a caller that needs to hold a resource across more
// than one call.
fn borrowWidget(p: Pool<widgetConn>): Lease<widgetConn>! {
  return p.acquire()?
}

fn returnWidget(p: Pool<widgetConn>, lease: Lease<widgetConn>) {
  p.release(lease, true)
}

fn widgetPoolLoad(p: Pool<widgetConn>): PoolStats {
  return p.stats()
}

fn shutdownWidgets(p: Pool<widgetConn>) {
  p.close()
}
```
