# std/sync

Shared-memory synchronization for truly-parallel Bit code (SPEC §16.1, §13.7).
**Channels remain the preferred concurrency primitive** - *do not communicate by
sharing memory; share memory by communicating*. Reach for `std/sync` only on a
shared-memory hot path, or to coordinate a fixed group of parallel workers,
where routing every access through a channel costs more than the data
warrants.

Every primitive here is built entirely from SPEC §11.5's atomic builtins and
§16.2's channels - no new runtime or grammar support. A blocking call
(`Mutex.lock`, `WaitGroup.wait`) parks the caller on the scheduler rather than
spinning, because it is implemented as a channel operation, and channel
operations already do that under M:N (SPEC §16.1).

```bit ignore
import { newMutex, newWaitGroup, newRWMutex, newOnce, newAtomicI64 } from "std/sync"
```

<!-- doctest: per-block -->

## Mutex

### `Mutex`

Mutual exclusion lock. A class, so it is a reference type: every holder of the
same `Mutex` value contends for the same lock. The zero-valued `Mutex` (never
constructed with `newMutex`) is not usable - always construct with
`newMutex()`.

### `newMutex(): Mutex`

A `Mutex` ready to use, unlocked.

### `Mutex.lock()`

Blocks until the lock is free, then acquires it. Contention parks the caller;
it does not spin.

### `Mutex.unlock()`

Releases the lock. Unlocking a `Mutex` the caller does not hold is a caller
bug, same as Go's `sync.Mutex` - it is not detected.

```bit
import { Mutex, newMutex, WaitGroup, newWaitGroup } from "std/sync"

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
excludes everyone. Construct with `newRWMutex()`.

### `newRWMutex(): RWMutex`

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
import { RWMutex, newRWMutex } from "std/sync"

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

### `newWaitGroup(): WaitGroup`

A fresh `WaitGroup` with a zero counter.

### `WaitGroup.add(delta: i64)`

Adds `delta` (may be negative) to the counter. Call before spawning the
workers that will call `done()` - `spawn`'s own happens-before edge (SPEC
§16.1) makes this safe with no further synchronization.

### `WaitGroup.done()`

Decrements the counter by one. The call that brings it to zero unblocks every
`wait()`.

### `WaitGroup.wait()`

Blocks until the counter reaches zero.

```bit
import { WaitGroup, newWaitGroup } from "std/sync"

fn fanIn(n: int): int {
  let wg = newWaitGroup()
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
concurrently. Construct with `newOnce()`.

### `newOnce(): Once`

A fresh `Once`, not yet run.

### `Once.do(f: () => ())`

Runs `f` on the first call only. Every call - concurrent or not - blocks
until that first run has completed.

```bit
import { Once, newOnce } from "std/sync"

fn initOnce(o: Once, ready: []i64) {
  o.do(() => {
    ready[0] = 1
  })
}
```

## Atomics

### `AtomicI64`

A single `i64` accessed only through sequentially-consistent atomic
operations (SPEC §11.5 - the strongest ordering, and the only one v0.1
exposes). Generic constraints (SPEC §11.3) are interface bounds only, so
there is no single `Atomic<T>` to write against an "integer prim" bound -
this offers one concrete class per width in common use, the same shape as
Go's `sync/atomic.Int64`.

### `newAtomicI64(v: i64): AtomicI64`

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

### `newAtomicU64(v: u64): AtomicU64`

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
import { newAtomicI64 } from "std/sync"

fn raceFreeCounter(n: i64): i64 {
  let counter = newAtomicI64(0)
  let i = 0
  while (i < n) {
    counter.add(1)
    i = i + 1
  }
  return counter.load()
}
```
