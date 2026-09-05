# Getting started with Bit

<!-- doctest: per-block -->

Bit is a systems language with TypeScript-flavoured syntax and Go-like
semantics: garbage collected, green threads, typed channels, structural
interfaces. It compiles to a single static native binary with no runtime to
install alongside it.

This page takes about fifteen minutes and ends with a real concurrent program.
Every code block below is compiled by Bit's own test suite, so none of it can
quietly rot.

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

Anything after the file is forwarded to the program as its own arguments —
`bit run hello.bit alpha beta` runs `hello` with `alpha` and `beta` in `argv`,
just as `bit build hello.bit -o hello && ./hello alpha beta` would. Write `--`
before an argument that would otherwise look like one of `bit run`'s own
flags, e.g. `bit run hello.bit -- --verbose`.

`println` needs no import. It comes from the **prelude**, a small module every
program gets for free.

`main` is the entry point. Returning normally exits 0; returning an `int` uses
it as the exit code.

## Variables

`let` declares a mutable binding, `const` an immutable one. Types are inferred
unless you write them.

```bit
fn variables() {
  let count = 0     // inferred int (i64)
  count = count + 1 // let is mutable

  const limit = 10         // immutable
  let name: string = "bit" // explicit type

  let ratio = 3.0 / 4.0 // f64
  println("${name}: ${count} of ${limit}, ratio ${ratio}")
}
```

String interpolation is `${...}` inside a normal string. There is no implicit
numeric conversion - widen explicitly with `i64(x)` or `f64(x)`.

## Functions

Parameters and return types are annotated; the body is an ordinary block.

```bit
fn add(a: int, b: int): int {
  return a + b
}

// Arrow functions are values, and close over their environment.
fn apply(xs: []int, f: (int) => int): []int {
  let out = []int(0)
  for x of xs {
    out = append(out, f(x))
  }
  return out
}

fn useThem() {
  println("${add(2, 3)}")
  let doubled = apply([1, 2, 3], (x: int) => x * 2)
  println("${len(doubled)} doubled values")
}
```

## Errors are values

A fallible function returns `T!` - "a `T`, or an error". `fail` produces the
error, `?` propagates it, and `catch` handles it locally. There are no
exceptions, so every failure path is visible in the source.

```bit
import { readFile } from "std/fs"

fn firstLineLength(path: string): int! {
  let text = readFile(path)? // on error, return it to our caller
  if (len(text) == 0) {
    fail newError("file is empty: ${path}")
  }
  return len(text)
}

fn report(path: string) {
  // `catch` with a default value: never fails.
  let n = firstLineLength(path) catch 0
  println("${n} bytes")
}
```

## Collections

Slices grow with `append`; maps read an absent key as the zero value, which
makes counting a one-liner.

```bit
fn collections() {
  let xs = [3, 1, 2] // []int
  xs = append(xs, 4)
  println("len=${len(xs)} first=${xs[0]}")

  let counts = map<string, int>()
  counts["fox"] = counts["fox"] + 1 // absent key reads as 0
  counts["fox"] = counts["fox"] + 1
  println("fox=${counts["fox"]} missing=${counts["absent"]}")

  for (word, n) of counts { // maps iterate as (key, value)
    println("${word} ${n}")
  }
}
```

## Concurrency

`spawn` starts a green thread - cheap enough to have thousands. Channels carry
typed values between them; `<-` sends and receives. A sleeping green thread
parks, leaving its OS thread free for the others.

```bit
import { sleep, Millisecond } from "std/time"

fn worker(id: int, out: chan<int>) {
  sleep(10 * Millisecond) // parks; does not block an OS thread
  out <- id * id
}

fn concurrency() {
  let results = chan<int>(4)
  let i = 0
  while (i < 4) {
    spawn worker(i, results)
    i = i + 1
  }

  let sum = 0
  i = 0
  while (i < 4) {
    sum = sum + <- results // blocks this green thread until one arrives
    i = i + 1
  }
  println("sum of squares = ${sum}") // 14
}
```

All four workers sleep concurrently, so this finishes in about 10ms, not 40.

## Putting it together: a concurrent word count

One green thread per file, each returning its own tally over a channel; the
main thread folds them into one map. This is the whole program - it is also
`examples/wordcount/`, which the test suite builds and runs.

```bit
import { readFile } from "std/fs"
import { toLower } from "std/strings"

fn countWords(text: string): map<string, int> {
  let counts = map<string, int>()
  let word = ""
  let i = 0
  while (i <= len(text)) {
    let isLetter = false
    if (i < len(text)) {
      let c = text[i]
      isLetter = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
    }
    if (isLetter) {
      word = word + text[i:i + 1]
    } else if (len(word) > 0) {
      counts[toLower(word)] = counts[toLower(word)] + 1
      word = ""
    }
    i = i + 1
  }
  return counts
}

// A read error yields an empty tally, so the collector below always receives
// exactly one message per worker it spawned.
fn worker(path: string, out: chan<map<string, int>>) {
  out <- countWords(readFile(path) catch "")
}

fn countFiles(paths: []string): map<string, int> {
  let results = chan<map<string, int>>(len(paths))
  for p of paths {
    spawn worker(p, results)
  }

  let total = map<string, int>()
  let i = 0
  while (i < len(paths)) {
    let part = <- results
    for (word, n) of part {
      total[word] = total[word] + n
    }
    i = i + 1
  }
  return total
}

fn main() {
  let counts = countFiles(["a.txt", "b.txt", "c.txt"])
  println("distinct words: ${len(counts)}")
  println("the=${counts["the"]}")
}
```

The files are read in parallel, and the folding is sequential - so no lock is
needed anywhere, and the only shared state is the channel.

## Testing

A test is any top-level function with no parameters and no return value,
declared in a file named `<name>.test.bit`. The filename is the only
discovery marker - no naming convention is required, though `test_...`
remains a common, readable choice for the function itself.

Put this in `math.test.bit`:

```bit
import { eq, ok } from "std/testing"

fn double(n: int): int {
  return n * 2
}

fn test_double() {
  eq<i64>(double(21), 42, "double")
  ok(double(0) == 0, "zero")
}
```

`double` takes a parameter and returns a value, so it is an ordinary helper,
not a test - it is excluded by its shape, not by its name.

```
$ bit test math.test.bit
ok   test_double

discovered 1 test, ran 1: 1 passed, 0 failed
```

A failing assertion prints the values it compared, not just that it failed.

## What checks the compiler

Bit's compiler is written in Bit and compiles itself. Every release is
checked against the previous release of the same compiler by a suite of
differential tests - not against a second, independently written
implementation - so a green run means this release produced the same
tokens, types and generated code as the last one, not that either is
correct. That distinction is not theoretical: a miscompile once shipped
silently in every release for months, on every platform, invisible to all
of these differentials because the new compiler and the reference release
shared the same bug; it was found only by comparing Bit's output against a
C compiler on the same program. Reaching a 1.0 release needs an oracle that
does not depend on comparing against a shared history, so the project's
answer is fuzzing that checks the compiler's own invariants directly - for
example, that two optimization levels or two target architectures agree on
the same program's behavior. Separately, the project's build is designed
to be reproducible: rebuilding a release from its published source should
yield a bit-identical binary, and the maintainers already run that rebuild
on separate machines they control as one check that the shipped binary
matches the published source. That check proves the binary matches its
source, not that the source is correct, and it does not catch a starting
compiler that was compromised before publication, since every rebuild
still starts from the same published binary.

## Where to next

- [Language reference](reference/README.md) - types, functions, interfaces,
  generics, errors, modules, concurrency.
- [Standard library](stdlib/README.md) - one page per module, every exported
  symbol.
- `examples/` in the repository - one small program per feature.
- `bit fmt` formats; `bit doc <module>` lists what a module exports; `bit lsp`
  backs the editor extension.
