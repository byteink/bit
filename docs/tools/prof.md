# Profile

<!-- doctest: per-block -->

You wrapped the slow part of your program in
[`startCpu`/`stopCpu`](../stdlib/prof.md) and now have a `.prof` file next to
it. It is plain text, but reading it by eye means matching raw addresses
against your own binary's symbol table by hand. `bit prof` does that for
you: it reads the profile, looks up each address in the binary named on the
profile's own header line, and prints a table of which function the
processor was in and how often.

## Running it

```
bit prof <file.prof>
```

There are no flags. The table is sorted by sample count, most-sampled
function first:

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

Build and run that program, pass its output path to `bit prof`, and you get:

```
$ bit prof hotloop.prof
profile: 227 sample(s) of 8192 ring capacity, 2 distinct function(s)
225	99.1%	_hotLoop
2	0.9%	(outside the binary)
```

| Exit code | Meaning |
| --- | --- |
| 0 | the profile was read and the table printed |
| 1 | the profile or the binary it names could not be read, or the file is not a `BITPROF1` profile |
| 2 | a usage error - no path given, or more than one |

## Sharp edges

The binary path on the profile's own header line is whatever `selfExe()`
returned when the profiled process called `stopCpu` - if you moved or
deleted that binary since, `bit prof` cannot symbolize the addresses and
reports it cannot read it.

A sample whose address falls outside every function the binary defines -
most often, one taken inside the operating system's own libraries rather
than your program - is reported on its own row, `(outside the binary)`,
never charged to one of your own functions. A large `(outside the binary)`
line is worth checking before concluding your own code is the hot spot.

## Where next

[std/prof](../stdlib/prof.md) covers `startCpu`/`stopCpu` themselves. [Part
5 of the Book](../book/README.md) profiles Inkwell end to end and reads a
real table line by line.
