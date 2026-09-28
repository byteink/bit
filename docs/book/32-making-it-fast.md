# Making it fast

`ink stats` adds up the words in every draft. With a few dozen drafts it
answers at once. Point it at a library of twenty thousand drafts and it
takes seconds. The tempting move is to guess why and start rewriting. Do
not. Measure first, find the one place the time goes, fix that place, and
measure again. This chapter does exactly that, on the word count from
[Words and dates](09-words-and-dates.md).

## A benchmark you can run

Here is the word count as chapter 9 wrote it: split the body on runs of
whitespace with a regular expression, and count the pieces.

```bit
import { trimSpace, repeat } from "std/strings"
import { mustCompile, Regex } from "std/regex"
import { monotonic, since } from "std/time"
import { startCpu, stopCpu } from "std/prof"

fn wordSplitter(): Regex {
  return mustCompile("\\s+")
}

fn wordCount(body: string): int {
  let trimmed = trimSpace(body)
  if (trimmed == "") {
    return 0
  }
  return len(wordSplitter().split(trimmed, -1))
}
```

A number you can trust needs the same work every run, so the benchmark
builds its library in memory instead of reading it from disk: twenty
thousand drafts of 240 words each. `ink stats` only reads each draft's
body, so the bodies are all it needs. `monotonic` and `since` from
[std/time](/std/time) time the loop and nothing else:

```bit
fn sampleBodies(n: int): []string {
  let body = repeat("Bit keeps drafts short and plain. ", 40)
  let out = []string(0)
  let i = 0
  while (i < n) {
    out = append(out, body)
    i = i + 1
  }
  return out
}

fn countAll(bodies: []string): int {
  let words = 0
  for b of bodies {
    words = words + wordCount(b)
  }
  return words
}

fn main() {
  let bodies = sampleBodies(20000)
  let start = monotonic()
  let words = countAll(bodies)
  let ms = since(start) / 1_000_000
  println("${len(bodies)} drafts, ${words} words, ${ms} ms")
}
```

Put the two blocks in `wordbench/main.bit`, next to a `bit.json` holding
`{ "name": "wordbench" }`, then build it once and run the binary. Run it
a few times: the first number is never the whole story, and a busy laptop
moves it.

```text
$ bit build wordbench -o wb
$ ./wb
20000 drafts, 4800000 words, 3596 ms
$ ./wb
20000 drafts, 4800000 words, 3852 ms
$ ./wb
20000 drafts, 4800000 words, 3868 ms
```

On a laptop, close to four seconds to count under five million words. That
is slow enough to fix, and now there is a number to beat.

## Where the memory goes: `BIT_GC_STATS`

Bit frees memory for you with a garbage collector: every so often it
pauses the program, finds the objects nothing points to any more, and
reuses their space. Set `BIT_GC_STATS=1` and the program prints one line
about that work when it exits, on standard error:

```text
$ BIT_GC_STATS=1 ./wb
20000 drafts, 4800000 words, 3668 ms
[bit-gc] collections=1562 swept=88706152 live=53880 ... allocbytes=4279801104 pauses=1562 pausens=1108488195 ...
```

The line is long; three fields answer the first question.

- `allocbytes` is every byte the program asked for, over its whole run:
  here about 4.3 GB, to count words in about 27 MB of text.
- `collections` is how many times the collector ran: 1,562.
- `pausens` is the total time the program stood still while it did, in
  nanoseconds: about 1.1 seconds of the 3.7.

So close to a third of the run is spent cleaning up memory, and something
is asking for about 160 times more memory than the text it reads.

## Where the time goes: `std/prof`

`BIT_GC_STATS` says how much memory. A profiler says which code. The
[std/prof](/std/prof) module samples the running program many times a
second and records which function the processor was in each time. Wrap
the loop you care about in `startCpu` and `stopCpu`:

```bit
fn profileCountAll(bodies: []string, path: string): int! {
  startCpu(1000)
  let words = countAll(bodies)
  let _ = stopCpu(path)?
  return words
}
```

`std/prof` runs on Apple Silicon Macs (`aarch64-macos`) only. Call
`profileCountAll(bodies, "stats.prof")?` in place of `countAll(bodies)` in
`main`, make `main` return `()!` so the `?` has somewhere to go, and
rebuild. The profile it writes is plain text; render it with `bit prof`:

```text
$ bit prof stats.prof
profile: 1588 sample(s) of 8192 ring capacity, 49 distinct function(s)
1279	80.5%	(outside the binary)
48	3.0%	_bit_rt_heap_take_small_locked
28	1.8%	_gcHeapAllocUncached
21	1.3%	_m6$addThread
20	1.3%	_setSlotBit
17	1.1%	_m6$runPikeAll
14	0.9%	_allocObject
12	0.8%	_noteBody
11	0.7%	_zeroBytes
11	0.7%	_bit_rt_alloc_classify
10	0.6%	_m6$firstMatchIndex
8	0.5%	_m2$decodeRune
...
```

Each line is a function and its share of the samples. The top line is not
a function in `wb` at all: 1,279 samples' addresses fell outside every
function the binary defines, so the renderer reports them on their own
row, `(outside the binary)`, instead of charging them to whichever
function happens to come last. Those samples were taken inside the
operating system's own libraries, not in `wb`. Below it, almost every name
belongs to the runtime: `alloc`, `heap`, `gc` and `zeroBytes` are handing
out memory, clearing it and collecting it again. The regular expression
matcher itself (`addThread`, `runPikeAll`) is under 2% a line. The profile
agrees with `BIT_GC_STATS`: the cost is not the matching, it is the
memory.

Now read `wordCount` again with that in mind. `split` builds a new string
for every word and a list to hold them, and the only thing the code wants
is the list's length. All of that memory is thrown away the moment `len`
returns. Two hundred and forty strings per draft, twenty thousand drafts.

## The fix: count without copying

A word is a run of bytes that are not whitespace. Walk the body once and
count every place a run starts. Nothing is copied, so nothing is
allocated:

```bit
fn isSpace(b: int): bool {
  return b == 32 || (b >= 9 && b <= 13)
}

fn countWords(body: string): int {
  let words = 0
  let inWord = false
  let i = 0
  while (i < len(body)) {
    let space = isSpace(int(body[i]))
    if (!space && !inWord) {
      words = words + 1
    }
    inWord = !space
    i = i + 1
  }
  return words
}
```

`isSpace` accepts the same six bytes `\s` matches in
[std/regex](/std/regex) and `trimSpace` strips in
[std/strings](/std/strings): tab, newline, vertical tab, form feed,
carriage return (9 to 13) and space (32). That is what makes this a fix
and not a new behaviour: for every body, `countWords` gives the same
answer `wordCount` did. Leading and trailing whitespace start no run, so
the `trimSpace` call is no longer needed either.

Change the one line in `countAll` from `wordCount(b)` to `countWords(b)`,
rebuild, and measure again, the same way:

```text
$ BIT_GC_STATS=1 ./wb
20000 drafts, 4800000 words, 44 ms
[bit-gc] collections=0 swept=0 live=20032 ... allocbytes=2041104 pauses=0 pausens=0 ...
```

Three plain runs took 39, 46 and 42 ms. The same 4,800,000 words, in about
42 ms instead of about 3,850: about 90 times faster. `allocbytes` fell from
4.3 GB to 2.0 MB, and a copy of the program with the counting loop taken
out allocates the same 2.0 MB: the loop itself allocates nothing. The
collector never ran at all.

## What to take from it

- **Measure before and after, the same way, more than once.** A change
  you did not measure is a guess, and one run on a busy machine can be off
  by a lot.
- **`BIT_GC_STATS=1` first.** It costs nothing to turn on, and a large
  `allocbytes` next to a small input points straight at code that builds
  things only to throw them away.
- **Then `std/prof`**, to find which function. When the top of the
  profile is the runtime's memory functions, look for the code that asks
  for the memory, not for a faster collector.
- **A faster answer must be the same answer.** Check the new function
  against the old one on the inputs that matter (empty, only spaces, tabs
  and newlines) before you delete the old one.
- **Fix one thing, then measure again.** Here one function was nearly all
  of the cost. Often the next hot spot is somewhere you would never have
  guessed, which is the reason to measure instead of guessing.

Previous: [Background jobs](31-background-jobs.md). Next:
[Shipping](33-shipping.md).
