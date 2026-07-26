# Bit

A systems programming language with TypeScript-flavored syntax and Go-like
semantics. You write `let`/`const`, `function`, arrows, `interface` and `<>`
generics. You get garbage collection, green threads, typed channels and
structural interfaces. Programs compile to a single static native binary with no
runtime to install and no libc to link against.

```bit
import { serve, ok, Request, Response } from "std/http"

function route(req: Request): Response {
  return ok("hello from bit")
}

function main() {
  let s = serve("0.0.0.0", 8080) catch e {
    print("serve: ${e.message()}\n")
    return
  }
  // Each request runs on its own green thread.
  while (true) {
    let ex = s.accept() catch e { return }
    spawn handle(ex, route)
  }
}
```

## Easy to write is the design goal

Not "powerful", not "fast to compile" - easy to write, deliberately chosen as the
thing to optimize when the two conflict. The syntax is the one most working
programmers already know, so the language you have to learn is the semantics
underneath it, not a new notation on top.

## Nothing to install but the binary

`bit build` produces one static executable. No interpreter, no VM, no shared
library, no libc dependency. Copy it to a machine that has never heard of Bit and
it runs.

That also holds for the compiler itself: no LLVM, no system assembler, no system
linker. Bit owns its lexer, parser, checker, SSA IR, code generators for x86-64
and ARM64, its object writers for ELF, Mach-O and PE, and its own static linker.

## Concurrency you can reason about

Green threads via `spawn`, typed channels, and `select`. The scheduler is M:N, so
thousands of green threads ride on a handful of OS threads, and a blocking call
parks the green thread rather than the worker.

```bit
function worker(id: int, results: chan<int>) {
  results <- id * id
}

function main() {
  let results = chan<int>(4)
  for (let i = 0; i < 4; i++) {
    spawn worker(i, results)
  }
  let total = 0
  for (let i = 0; i < 4; i++) {
    total = total + <- results
  }
  print("${total}\n")
}
```

## Errors are values, and the compiler counts them

A fallible function is marked `!`. `?` propagates, `catch` handles, and there is
no third option - an unhandled error is a compile error, not a runtime surprise.

## Self-hosted

The compiler is written in Bit and compiles itself. The bootstrap is proven to a
fixed point: the compiler built by stage 2 and the one built by stage 3 are
byte-identical binaries.

## Honest status

Bit is pre-1.0 and the spec says so. The language, stdlib and toolchain work -
there is a package manager, a language server, a formatter, a linter and a test
runner - but the API is not frozen and `0.x` releases carry no support guarantee.
[Read the support policy](support.html) before depending on it.
