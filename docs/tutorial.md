# Getting started with Bit

<!-- doctest: per-block -->

Say you have a text file, a log, a chat export, the draft of something you're
writing, and you want to know which words show up the most. This page builds
that program, in Bit, in about fifteen minutes. Every code block below is
compiled by Bit's own test suite, so none of it can quietly rot.

## Install

```
brew install byteink/tap/bit           # macOS
curl -fsSL bitlang.org/install.sh | sh # Linux
irm bitlang.org/install.ps1 | iex      # Windows
```

Check it:

```
bit --version
```

## Hello, world

Put this in `hello.bit`:

```bit
fn main() {
  println("hello, bit")
}
```

Run it straight from source, or build a binary:

```
bit run hello.bit      # compile to a temp binary and execute
bit build hello.bit    # leaves ./hello
```

Anything after the file is forwarded to the program as its own arguments -
`bit run hello.bit alpha beta` runs `hello` with `alpha` and `beta` in `argv`,
just as `bit build hello.bit -o hello && ./hello alpha beta` would. Write `--`
before an argument that would otherwise look like one of `bit run`'s own
flags, e.g. `bit run hello.bit -- --verbose`.

`println` needs no import. It comes from the **prelude**, a small module every
program gets for free.

`main` is the entry point. Returning normally exits 0; returning an `int` uses
it as the exit code.

## Count the words in a file

A program that takes a file path and prints how many words are in it needs a
place to keep the words, a way to read the file, and a way to split its text
apart. `let` declares a mutable binding, and a type after `:` is only needed
when Bit cannot infer one:

```bit
import { readFile } from "std/fs"
import { arg, argc } from "std/os"
import { split, replace, trim, toLower } from "std/strings"

fn words(text: string): []string {
  let flat = replace(text, "\n", " ") // treat newlines as spaces too
  let raw = split(flat, " ")
  let out = []string(0)
  for token of raw {
    let w = toLower(trim(token, ".,!?;:\"'()")) // drop punctuation, case
    if (len(w) > 0) {
      out = append(out, w)
    }
  }
  return out
}

fn main() {
  if (argc() < 2) {
    println("usage: ${arg(0)} <file>")
    return
  }
  let text = readFile(arg(1)) catch ""
  println("${len(words(text))} words")
}
```

`arg(0)` is the program's own path; `arg(1)` is the first real argument.
`readFile` can fail, so it returns a `string!`, "a string, or an error" -
`catch ""` uses an empty string if it does. `${...}` inside a string
interpolates a value.

That answers "how many words", not "which ones matter". Counting duplicates
needs a running total per word - a `map`. Reading an absent key gives you its
zero value instead of an error, which makes counting a one-liner:

```bit
import { readFile } from "std/fs"
import { arg, argc } from "std/os"
import { split, replace, trim, toLower } from "std/strings"
import { sortInPlace } from "std/sort"

fn words(text: string): []string {
  let flat = replace(text, "\n", " ")
  let raw = split(flat, " ")
  let out = []string(0)
  for token of raw {
    let w = toLower(trim(token, ".,!?;:\"'()"))
    if (len(w) > 0) {
      out = append(out, w)
    }
  }
  return out
}

fn tally(ws: []string): map<string, int> {
  let counts = map<string, int>()
  for w of ws {
    counts[w] = counts[w] + 1 // absent key reads as 0
  }
  return counts
}

fn main() {
  if (argc() < 2) {
    println("usage: ${arg(0)} <file>")
    return
  }
  let text = readFile(arg(1)) catch ""
  let counts = tally(words(text))

  let keys = []string(0)
  for (k, _) of counts {
    keys = append(keys, k)
  }
  sortInPlace(keys, (a: string, b: string) => a < b)
  for k of keys {
    println("${k}: ${counts[k]}")
  }
}
```

A map's iteration order is not insertion order, and it is not the same across
builds - so the keys are sorted before printing, or the same file would print
in a different order every time you rebuild. `sortInPlace` takes a `less`
function; here it is an arrow function, `(a, b) => a < b`, a value like any
other.

Alphabetical order tells you every word once, not which ones matter. Sorting
by count instead needs a `less` function that looks up two words in `counts`
- an arrow function closes over the variables around it, so it can:

```bit
import { readFile } from "std/fs"
import { arg, argc } from "std/os"
import { split, replace, trim, toLower } from "std/strings"
import { sortInPlace } from "std/sort"

fn words(text: string): []string {
  let flat = replace(text, "\n", " ")
  let raw = split(flat, " ")
  let out = []string(0)
  for token of raw {
    let w = toLower(trim(token, ".,!?;:\"'()"))
    if (len(w) > 0) {
      out = append(out, w)
    }
  }
  return out
}

fn tally(ws: []string): map<string, int> {
  let counts = map<string, int>()
  for w of ws {
    counts[w] = counts[w] + 1
  }
  return counts
}

fn topWords(counts: map<string, int>, n: int): []string {
  let keys = []string(0)
  for (k, _) of counts {
    keys = append(keys, k)
  }
  sortInPlace(keys, (a: string, b: string) => {
    if (counts[a] != counts[b]) {
      return counts[a] > counts[b] // higher count first
    }
    return a < b // tie: alphabetical, so reruns agree
  })
  if (len(keys) > n) {
    return keys[0:n]
  }
  return keys
}

fn main() {
  if (argc() < 2) {
    println("usage: ${arg(0)} <file>")
    return
  }
  let text = readFile(arg(1)) catch ""
  let counts = tally(words(text))
  for w of topWords(counts, 5) {
    println("${w}: ${counts[w]}")
  }
}
```

`keys[0:n]` slices the first `n` entries - the same `[low:high]` syntax as
`text[i:i+1]` above, on any slice.

One thing here is still wrong: a file that does not exist silently counts
zero words. `catch ""` throws the error away. Bit has no exceptions, so a
failure like this is never invisible unless you choose to make it so - and
`catch` has a second form for when you don't want to:

## The finished program

```bit
import { readFile } from "std/fs"
import { arg, argc } from "std/os"
import { split, replace, trim, toLower } from "std/strings"
import { sortInPlace } from "std/sort"

fn words(text: string): []string {
  let flat = replace(text, "\n", " ")
  let raw = split(flat, " ")
  let out = []string(0)
  for token of raw {
    let w = toLower(trim(token, ".,!?;:\"'()"))
    if (len(w) > 0) {
      out = append(out, w)
    }
  }
  return out
}

fn tally(ws: []string): map<string, int> {
  let counts = map<string, int>()
  for w of ws {
    counts[w] = counts[w] + 1
  }
  return counts
}

fn topWords(counts: map<string, int>, n: int): []string {
  let keys = []string(0)
  for (k, _) of counts {
    keys = append(keys, k)
  }
  sortInPlace(keys, (a: string, b: string) => {
    if (counts[a] != counts[b]) {
      return counts[a] > counts[b]
    }
    return a < b
  })
  if (len(keys) > n) {
    return keys[0:n]
  }
  return keys
}

fn main() {
  if (argc() < 2) {
    println("usage: ${arg(0)} <file>")
    return
  }

  let text = readFile(arg(1)) catch e {
    println("could not read ${arg(1)}: ${e.message()}")
    return
  }

  let counts = tally(words(text))
  println("${len(counts)} distinct words")
  for w of topWords(counts, 5) {
    println("${w}: ${counts[w]}")
  }
}
```

`expr catch default` swaps in a value on failure and moves on, which is what
every version above did. `expr catch e { ... }` instead binds the error to
`e` and runs a block, which must either produce a value or leave the function
- here, printing the message and returning. Run it against a three-line file:

```
$ bit run wordcount.bit -- sample.txt
14 distinct words
the: 6
dog: 3
fox: 3
lazy: 3
quick: 3
```

And against a path that isn't there:

```
$ bit run wordcount.bit -- missing.txt
could not read missing.txt: cannot open file: missing.txt
```

## Where to next

- [The language guide](reference/README.md) builds a link shortener chapter
  by chapter, growing this same kind of program into one with interfaces,
  generics, errors and concurrency.
- [Guides](guides/README.md) answers specific tasks, like
  [reading and writing files](guides/reading-and-writing-files.md) and
  [handling errors](guides/handle-errors.md), in more depth than this page
  does.
- [Standard library](stdlib/README.md) - one page per module, every exported
  symbol.
- `bit fmt` formats; `bit doc <module>` lists what a module exports; `bit lsp`
  backs the editor extension.
