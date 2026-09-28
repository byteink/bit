# Hello, Inkwell

You are about to build Inkwell, a notes tool, from nothing. This chapter
gets you a Bit project that builds and runs. It assumes Bit is already
installed - if it is not, [Get started](/get-started) covers that first.

## Make the project

```text
$ mkdir ink && cd ink
$ bit init ink
bit init: wrote bit.json
```

`bit init ink` writes `bit.json`, the file that names your project and
will later list its dependencies:

```json
{"name": "ink"}
```

Every file you add under this directory from now on is part of the `ink`
project. This is [`docs/book/ink/bit.json`](ink/bit.json), Inkwell's real
one.

## Write something and run it

Inkwell will end up doing a lot, but the smallest real piece of it is
`newId`: a function that hands out a fresh, time-ordered id for a new
draft, from [`docs/book/ink/store.bit`](ink/store.bit).

Create `main.bit`:

```bit
import { format, uuidV7 } from "std/uuid"

// A fresh, time-ordered id for a new draft.
export fn newId(): string {
  return format(uuidV7())
}

fn main() {
  println("ink is ready: ${newId()}")
}
```

`import { format, uuidV7 } from "std/uuid"` brings in two functions from
the standard library's `uuid` module. `uuidV7()` builds a UUID that sorts
by the time it was created; `format` turns it into the string form you
have seen elsewhere, like `f47ac10b-58cc-4372-a567-0e02b2c3d479`. `fn
main()` is where a Bit program starts.

Run it:

```text
$ bit run main.bit
ink is ready: 01912e9a-...
```

`bit run` compiles `main.bit` and everything it imports, then runs the
result in one step. Run it again and you get a different id - `uuidV7()`
reads the clock and some randomness each call.

## Build it

A program you run once with `bit run` is fine while you are working on it.
Inkwell will eventually be a command you install and run by name, so build
it into a binary:

```text
$ bit build main.bit -o ink
$ ./ink
ink is ready: 01912e9b-...
```

`bit build` compiles `main.bit` into a standalone executable, `ink`, that
runs with no `bit` toolchain present. That is the same binary [chapter 33,
Shipping](33-shipping.md) cross-compiles for other machines, much later.

## What you built

A real Bit project with one real function from Inkwell, compiled and run
two ways. `bit init`, `bit run` and `bit build` are all covered in full on
[Tools](/tools).

Next: [chapter 2, saving drafts](02-saving-drafts.md), where `main.bit`
gets its first real commands, `ink new` and `ink list`.
