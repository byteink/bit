# Ship a single binary

`bit build` produces one native executable with everything it needs already
linked in. There is no runtime to install alongside it and no interpreter to
point at it - copy the file to a machine of the right OS and architecture
and run it.

<!-- doctest: per-block -->

## The shortest complete program

```bit
fn main() {
  println("shipped")
}
```

Build and run it:

```
$ bit build hello.bit -o hello
$ ./hello
shipped
```

`-o hello` names the output; leaving it off writes a file named after the
source file's stem in the current directory. The result is an ordinary
native executable for the machine you built on - a `file hello` on macOS
reports `Mach-O 64-bit executable arm64`, on Linux an ELF binary - with no
`bit` binary anywhere in its dependency chain.

## A directory instead of one file

`bit build <dir>` builds the module rooted at `<dir>`; the output name comes
from `bit.json`'s `"name"` field if the directory has one, else the
directory's own name, written inside that directory unless `-o` says
otherwise.

## Building for a machine that is not this one

`--target <triple>` cross-compiles without needing that machine present:

```
$ bit build hello.bit --target aarch64-linux -o hello-linux-arm64
```

The supported triples are `x86_64-linux`, `aarch64-linux`, `aarch64-macos`
and `x86_64-windows`. Leaving `--target` off builds for the host you are
running `bit build` on.

## Sharp edges

- `--freestanding` compiles with no prelude and requires `-c`
  (`--emit-obj`) - it produces a relocatable object, not something you run
  directly. It is for embedding Bit-compiled code into another build, not
  for shipping an end-user binary.
- `--debug` turns on traps for signed add/sub/negate/multiply overflow. A
  release binary you hand to someone else should not carry it unless you
  specifically want an overflow to abort loudly instead of wrapping.
- `--no-optimize` skips the optimizer pass entirely. Reach for it only when
  you are narrowing down whether the optimizer itself changed behaviour -
  never for a binary you intend to ship.

## What to read next

`bit build --help` prints the full flag list, including `-c`/`--emit-obj`
for producing a relocatable object instead of an executable. For the
`main` signatures a built program can declare - plain, `int`-returning, or
fallible - see the [Modules reference](../reference/modules.md#the-main-entry-point).
