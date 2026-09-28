# Build and run

<!-- doctest: per-block -->

`bit run` is for developing: compile and execute in one step, throw the
binary away. `bit build` is for shipping: produce a file you keep and hand
to someone else. Both take a file or a project directory; a directory build
resolves your `bit.json` dependencies first.

## `bit run`

```
bit run <file.bit|dir> [args...]
```

Builds the module for the machine you're on, runs it, and exits with its
status:

```bit
fn main() {
  println("running")
}
```

```
$ bit run hello.bit
running
```

`bit run` takes no flags of its own - everything after the file name is
forwarded to the program as its own arguments. Write `--` before an argument
that would otherwise look like one of `bit run`'s own flags:

```
bit run hello.bit -- --verbose
```

`bit run hello.bit --help` still prints `bit run`'s own usage; put `--`
first to give the program its own `--help` instead.

## `bit build`

```
bit build <file.bit|dir> [-o <out>] [-c] [--target <triple>]
```

Produces one native executable with everything it needs already linked
in - no runtime to install alongside it, no interpreter to point at it.
Copy the file to a machine of the right OS and architecture and run it.

```
$ bit build hello.bit -o hello
$ ./hello
running
```

`-o <out>` names the output file. Left off, a single-file build writes a
file named after the source file's stem in the current directory; a
directory build names the output after `bit.json`'s `"name"` field, or the
directory's own name if it has none, written inside that directory.

### Cross-compiling

`--target <triple>` builds for a machine that isn't the one you're running
on:

```
bit build hello.bit --target aarch64-linux -o hello-linux-arm64
```

The supported triples are `x86_64-linux`, `aarch64-linux`, `aarch64-macos`
and `x86_64-windows`. Leaving `--target` off builds for the host you're
running `bit build` on.

### Sharp edges

- `-c` (`--emit-obj`) emits a relocatable object instead of an executable -
  for embedding Bit-compiled code into another build, not for shipping an
  end-user binary. `--freestanding` compiles with no prelude and requires
  `-c`; it produces an object with no `main` wired in at all.
- `--debug` turns on traps for signed add/sub/negate/multiply overflow. A
  binary you hand to someone else should not carry it unless you
  specifically want an overflow to abort loudly instead of wrapping.
- `--no-optimize` skips the optimizer pass entirely. Reach for it only when
  narrowing down whether the optimizer itself changed a program's
  behavior - never for a binary you intend to ship.

Run `bit build --help` or `bit run --help` for the full flag list.

## Where next

[Test](test.md) covers `bit test`. [Ship a binary](build-and-run.md) above
is the whole story for a single machine; the same `--target` flag is what
[Part 5 of the Book](../book/README.md) uses to cross-compile Inkwell for a
server that isn't your laptop.
