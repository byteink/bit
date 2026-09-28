# Watching for changes

<!-- doctest: per-block -->

Inkwell can index and search your drafts, but only when you ask it to. This part
adds a loop that runs in the background for as long as Inkwell is up, checking
for changed drafts on its own schedule, and stopping cleanly - on request,
or when you press Ctrl-C - instead of leaving work half done.

## Waiting on a timer without blocking forever

`select` waits on more than one channel at once and runs whichever case is
ready first. `newTimer(d)` returns a `Timer` whose `c` receives once, `d`
nanoseconds from now - the building block for "do this, but not more often
than every `d`":

```bit
import { newTimer, Millisecond } from "std/time"

fn tickThreeTimes() {
  let timer = newTimer(5 * Millisecond)
  let count = 0
  while (count < 3) {
    let _ = <- timer.c
    count = count + 1
    println("tick ${count}")
    timer.reset(5 * Millisecond)
  }
}

fn main() {
  tickThreeTimes()
}
```

`timer.reset(d)` re-arms the same timer for another `d` nanoseconds, so a
loop that polls on an interval needs only one `Timer`, not a fresh one per
pass.

## Stopping on request

A loop that polls forever is no good if nothing can ever stop it. Add a
second channel and `select` between the two: whichever is ready first wins,
so the loop reacts to a stop signal within one tick instead of only between
whole polling cycles:

```bit
import { newTimer, Millisecond } from "std/time"

fn pollUntilStopped(stop: chan<bool>, ticks: chan<int>) {
  let timer = newTimer(2 * Millisecond)
  let n = 0
  let running = true
  while (running) {
    select {
      case _ = <- stop:
        timer.stop()
        running = false
      case _ = <- timer.c:
        n = n + 1
        ticks <- n
        timer.reset(2 * Millisecond)
    }
  }
  close(ticks)
}

fn main() {
  let stop = chan<bool>(1)
  let ticks = chan<int>(4)
  spawn pollUntilStopped(stop, ticks)
  let first = <- ticks
  println("first tick: ${first}")
  stop <- true
  for t of ticks {
    println("late tick: ${t}")
  }
}
```

`timer.stop()` cancels the pending timer before the loop exits - not
required for correctness here, but it frees the scheduler's timer-pool slot
immediately instead of waiting for it to fire unread.

## Stopping on Ctrl-C

A background loop should also stop when the operating system asks the whole
program to: Ctrl-C (`SIGINT`) or a `SIGTERM` from `kill` or a process
manager. `waitForSignal` blocks until one of those arrives, so `main` can
start the loop, then simply wait:

```bit
import { waitForSignal, Signal } from "std/signal"

fn main() {
  let sig = waitForSignal([Signal.Term, Signal.Int])
  if (sig == Signal.Int) {
    println("stopping: Ctrl-C")
  } else {
    println("stopping: terminated")
  }
}
```

`waitForSignal` returns which signal arrived; a signal you did not ask for
never returns from the call, so this line only ever runs once you actually
want to stop.

## Wired into Inkwell

`ink/watch.bit` combines all three: `watchLoop` polls `loadAll` on a
`Timer`, reports every draft whose `updated` moved forward since the last
poll, and stops the moment a value arrives on `stop`. `ink/main.bit`'s
`ink watch` command spawns it and then calls `waitForSignal`, so Ctrl-C
stops the same way an explicit `stop` value would.

```bit
export enum Status { Draft, Published, Archived }

export class Draft {
  export id: string,
  export title: string,
  export body: string,
  export tags: []string,
  export status: Status,
  export created: i64,
  export updated: i64,
}

import { newTimer } from "std/time"

// The ids of every draft in `drafts` whose `updated` is newer than what
// `seen` last recorded for it (including ids `seen` has never recorded).
// `seen` is updated in place, so the next call only reports new changes.
fn changedSince(drafts: []Draft, seen: map<string, i64>): []string {
  let changed = []string(0)
  for d of drafts {
    let (last, ok) = seen[d.id]
    if (!ok || d.updated > last) {
      changed = append(changed, d.id)
      seen[d.id] = d.updated
    }
  }
  return changed
}

// Polls `loadAll` every `interval` nanoseconds and sends the id of each
// changed draft on `changes`, until a value arrives on `stop`. Closes
// `changes` before returning, so a receiver can range over it to know when
// the loop is done.
//
// Uses one `Timer`, reset after every poll, rather than calling `after`
// fresh each iteration: `after` would arm a new pool slot every pass and
// leave the previous one to expire unread, a leak bounded by `interval` but
// pointless when one timer can simply be reused (std/time's own `after` doc
// comment says the same).
export fn watchLoop(
  loadAll: () => []Draft,
  interval: int,
  stop: chan<bool>,
  changes: chan<string>,
) {
  let seen = map<string, i64>()
  let timer = newTimer(interval)
  let running = true
  while (running) {
    select {
      case _ = <- stop:
        timer.stop()
        running = false
      case _ = <- timer.c:
        for id of changedSince(loadAll(), seen) {
          changes <- id
        }
        timer.reset(interval)
    }
  }
  close(changes)
}

fn sampleDrafts(): []Draft {
  return []Draft{
    Draft{
      id = "1", title = "First", body = "one", tags = []string(0),
      status = Status.Draft, created = 0, updated = 1,
    },
  }
}

fn main() {
  let stop = chan<bool>(1)
  let changes = chan<string>(4)
  spawn watchLoop(sampleDrafts, 5_000_000, stop, changes)
  let first = <- changes
  println("changed: ${first}")
  stop <- true
}
```

## Wiring it into main.bit

`ink watch` starts `watchLoop` on a green thread, hands `stopOnSignal` the
`stop` channel so Ctrl-C reaches it, then blocks reading `changes` until
`watchLoop` closes it:

```text
fn stopOnSignal(stop: chan<bool>) {
  waitForSignal([Signal.Term, Signal.Int])
  stop <- true
}

fn cmdWatch(store: Store): ()! {
  let stop = chan<bool>(1)
  let changes = chan<string>(8)
  let loadAll = () => {
    return store.list() catch []Draft(0)
  }
  spawn watchLoop(loadAll, 2_000_000_000, stop, changes)
  spawn stopOnSignal(stop)
  for id of changes {
    println("changed: ${id}")
  }
}
```

`stopOnSignal` is its own named function - `spawn` needs a call expression,
not a closure. `loadAll` is a closure over `store`, an arrow function whose
body reads the variable from the enclosing `cmdWatch` (see
[Functions](/language/functions) for arrow function syntax); `catch
[]Draft(0)` turns `store.list()`'s failure into "nothing changed" for this
one poll, since `watchLoop`'s `loadAll` parameter cannot itself fail.

## Sharp edges

- `select` picks uniformly at random among every case that is ready, not the
  one written first - if `stop` and the timer both have a value waiting,
  either can run. A loop that must react to `stop` immediately checks it
  again at the top of its own `while`, rather than relying on `select`'s
  choice.
- `close(c)` on an already-closed channel panics. `watchLoop` closes
  `changes` exactly once, right before it returns - never call `close` on it
  from anywhere else.
- A signal outside the set you asked `waitForSignal` for never returns from
  the call; there is no way to be woken for "any" signal.

## When not to reach for a background loop

If you only need to know whether one specific draft changed, right when you
are about to use it, comparing its `updated` against a value you saved
earlier is simpler and needs no channel, timer, or spawned green thread at
all. Reach for `watchLoop`'s shape when the checking itself needs to keep
happening on its own schedule, independent of any single request.

## What you built

Inkwell now runs a background loop that polls for changed drafts, stops on
either an explicit signal or Ctrl-C, and never leaves a stray channel or
timer behind. You used `select`, a `Timer`, a `stop` channel, and
`waitForSignal`.

Next: [Chapter 13, backups](13-backups.md), where Inkwell protects your drafts
against data loss and corruption.
