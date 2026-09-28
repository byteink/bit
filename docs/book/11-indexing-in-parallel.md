# Indexing in parallel

<!-- doctest: per-block -->

[Chapter 5](05-searching-drafts.md) searches Inkwell's drafts by scanning
every one, every time. That is fine for a few dozen notes. Once there are
thousands, you want a word index built once, ahead of time, so a search is a
map lookup instead of a scan. Building that index means reading every
draft's title and body and is exactly the kind of work that splits cleanly
across your machine's cores - so build it with several green threads
instead of one. A green thread is a lightweight task Bit itself schedules
over a handful of real OS threads: starting thousands of them is cheap, far
cheaper than thousands of OS threads would be.

## One task, one channel

`spawn` starts a call on a new green thread. There is no handle to it and
nothing to join - the only way to learn what it did is a channel:

```bit
import { split, trimSpace } from "std/strings"

fn wordCount(text: string): int {
  let words = 0
  for w of split(text, " ") {
    if (len(trimSpace(w)) > 0) {
      words = words + 1
    }
  }
  return words
}

fn countInBackground(text: string, done: chan<int>) {
  done <- wordCount(text)
}

fn main() {
  let done = chan<int>(1)
  spawn countInBackground("a small note about Bit", done)
  let n = <- done
  println("words: ${n}")
}
```

`chan<int>(1)` is buffered with room for one value, so `countInBackground`'s
send does not have to wait for `main` to be ready to receive.

## A fixed pool, not one task per draft

Spawning one green thread per draft would work, but with thousands of drafts
you would rather bound how many run at once. The usual shape: split the work
into chunks, one per worker, and hand each worker its chunk over a shared
`jobs` channel. `close(jobs)` after the last chunk is sent is itself the
signal to stop - a worker ranging over a channel with `for x of jobs`
finishes as soon as it is closed and drained, no separate "stop" value
needed:

```bit
fn square(n: int): int {
  return n * n
}

fn worker(jobs: chan<int>, results: chan<int>) {
  for n of jobs {
    results <- square(n)
  }
}

fn squareAll(nums: []int, workers: int): []int {
  let jobs = chan<int>(len(nums))
  let results = chan<int>(len(nums))
  let w = 0
  while (w < workers) {
    spawn worker(jobs, results)
    w = w + 1
  }
  for n of nums {
    jobs <- n
  }
  close(jobs)

  let out = []int(0)
  let i = 0
  while (i < len(nums)) {
    out = append(out, <- results)
    i = i + 1
  }
  return out
}

fn main() {
  let squares = squareAll([]int{ 1, 2, 3, 4 }, 2)
  println("done: ${len(squares)} results")
}
```

Every worker reads off the *same* `jobs` channel, so the pool self-balances:
a worker that finishes its chunk early just picks up the next one, rather
than sitting idle while a slower worker is still on its first.

## Wired into Inkwell

`ink/index.bit` builds a word index the same way: split the drafts into
chunks, spawn one worker per chunk, and merge the partial indexes each
worker sends back. `chunkDrafts` clamps `workers` to `1..len(drafts)`, so
`buildIndex` is safe to call with a fixed pool size no matter how many
drafts there are - including zero.

```bit
import { toLower, split, trimSpace } from "std/strings"

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

// The lowercase, whitespace-separated words of a draft's title and body.
// Repeated whitespace never produces an empty word.
fn wordsOf(d: Draft): []string {
  let raw = split(d.title + " " + d.body, " ")
  let out = []string(0)
  for w of raw {
    let word = toLower(trimSpace(w))
    if (len(word) > 0) {
      out = append(out, word)
    }
  }
  return out
}

// Indexes one slice of drafts into word -> the ids of the drafts containing
// it. One worker's share of the whole index.
fn indexChunk(drafts: []Draft): map<string, []string> {
  let idx = map<string, []string>()
  for d of drafts {
    for w of wordsOf(d) {
      let (ids, ok) = idx[w]
      if (ok) {
        idx[w] = append(ids, d.id)
      } else {
        idx[w] = []string{ d.id }
      }
    }
  }
  return idx
}

// Splits drafts into at most `n` roughly equal, contiguous chunks. Never
// returns more chunks than drafts, and returns none for an empty slice.
fn chunkDrafts(drafts: []Draft, n: int): [][]Draft {
  let total = len(drafts)
  if (total == 0) {
    return [][]Draft(0)
  }
  let count = n
  if (count < 1) {
    count = 1
  }
  if (count > total) {
    count = total
  }
  let size = total / count
  if (total % count != 0) {
    size = size + 1
  }
  let out = [][]Draft(0)
  let i = 0
  while (i < total) {
    let end = i + size
    if (end > total) {
      end = total
    }
    out = append(out, drafts[i:end])
    i = end
  }
  return out
}

// One worker: indexes chunks off `jobs` until it is closed, sending each
// chunk's partial index on `results`.
fn indexWorker(jobs: chan<[]Draft>, results: chan<map<string, []string>>) {
  for chunk of jobs {
    results <- indexChunk(chunk)
  }
}

// Merges `ids` into `merged[word]`, appending to any existing entry.
fn mergeInto(merged: map<string, []string>, word: string, ids: []string) {
  let (existing, ok) = merged[word]
  if (!ok) {
    merged[word] = ids
    return
  }
  for id of ids {
    existing = append(existing, id)
  }
  merged[word] = existing
}

// Builds a word index over `drafts` using up to `workers` green threads. The
// drafts are split into chunks, one per worker, indexed in parallel, and
// merged back into one map. `workers` below 1 or above `len(drafts)` is
// clamped, so this is safe to call with a fixed pool size regardless of how
// many drafts there are.
export fn buildIndex(drafts: []Draft, workers: int): map<string, []string> {
  let chunks = chunkDrafts(drafts, workers)
  let jobs = chan<[]Draft>(len(chunks))
  let results = chan<map<string, []string>>(len(chunks))

  let w = 0
  while (w < len(chunks)) {
    spawn indexWorker(jobs, results)
    w = w + 1
  }
  for chunk of chunks {
    jobs <- chunk
  }
  close(jobs)

  let merged = map<string, []string>()
  let received = 0
  while (received < len(chunks)) {
    let partial = <- results
    for (word, ids) of partial {
      mergeInto(merged, word, ids)
    }
    received = received + 1
  }
  return merged
}

fn main() {
  let drafts = []Draft{
    Draft{
      id = "1", title = "Bit release notes", body = "a new worker pool",
      tags = []string(0), status = Status.Published, created = 0, updated = 0,
    },
    Draft{
      id = "2", title = "Channels", body = "a typed pipe between green threads",
      tags = []string(0), status = Status.Draft, created = 0, updated = 0,
    },
  }
  let idx = buildIndex(drafts, 2)
  let (ids, ok) = idx["worker"]
  if (ok) {
    println("\"worker\" appears in ${len(ids)} draft(s)")
  }
}
```

## Wiring it into main.bit

`ink index` is one more command in `main.bit`'s dispatch:

```text
fn cmdIndex(store: Store): ()! {
  let drafts = store.list()?
  let idx = buildIndex(drafts, 4)
  println("indexed ${len(drafts)} draft(s) into ${len(idx)} distinct word(s)")
}
```

Four workers is a fixed, reasonable default for a laptop; `buildIndex`
itself does not care how many drafts there are, so this line never needs to
change as Inkwell's library grows.

## Sharp edges

- A green thread's stack is fixed at 64 KiB and does not grow. `indexWorker`
  above is shallow, so this never matters here - keep any recursive work you
  do spawn bounded.
- Every worker reads and writes only through `jobs` and `results`; nothing
  touches `merged` from more than one green thread at a time (`buildIndex`
  itself is the only place that writes to it, after every worker has
  finished). Sharing `merged` directly with the workers instead would be a
  data race.
- `close(jobs)` must happen after every job is sent, not before - closing
  first would let a worker's `for chunk of jobs` end before it ever saw a
  chunk.

## When not to reach for a worker pool

A few dozen drafts index in well under a millisecond on one green thread.
Reach for `buildIndex`'s shape only once indexing shows up as real, measured
time - a worker pool adds channels and a merge step that a `for` loop over
`indexChunk` does not need.

## What you built

Inkwell now builds a word index across a fixed pool of green threads, splitting
the work into chunks and merging the partial results back into one map. You
used `spawn`, a shared `jobs` channel closed to signal "no more work", and a
`results` channel to collect the answers.

Next: [Chapter 12, watching for changes](12-watching-for-changes.md), where
Inkwell runs a loop in the background for as long as the program is up.
