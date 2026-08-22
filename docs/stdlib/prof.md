# std/prof

An in-process CPU sampling profiler. **aarch64-macos only** — the runtime half
uses Darwin's `SIGPROF`/`setitimer`; calling this on another platform fails at
link time.

Nothing here runs unless a program calls `startCpu`: no environment variable,
no boot-time hook, no background cost when unused.

Only a leaf program counter is recorded per tick, not a full call stack, and
only one OS thread is sampled (whichever one happens to receive `SIGPROF` —
validated with `BIT_WORKERS=1`). Both are deliberate scope cuts for this first
version, not silent gaps.

The written profile is a small, self-describing text format (`BITPROF1`), not
the `pprof` protobuf format. Render it with `bit run tools/prof <file>`, which
symbolizes each recorded address against the profiled binary's own linked
Mach-O symbol table and prints each function's share of samples.

### `startCpu(hz: int)`

Start sampling this process's own CPU use at approximately `hz` samples per
second (clamped to `[1, 100000]`). Must be paired with a later `stopCpu(path)`
— this call only arms the timer. Calling `startCpu` again before `stopCpu`
re-arms the timer and resets the sample ring; it does not stack.

### `stopCpu(path: string): int!`

Stop sampling and write the captured profile to `path`. Returns the number of
samples actually stored.

```bit
import { startCpu, stopCpu } from "std/prof"

fn hotLoop(n: int): int {
  let sum = 0
  let i = 0
  while (i < n) {
    sum = sum + i * i
    i = i + 1
  }
  return sum
}

fn profileHotLoop(outPath: string): int! {
  startCpu(500)
  let _ = hotLoop(1000000)
  return stopCpu(outPath)?
}
```
