# Get started

<!-- doctest: per-block -->

Bit compiles to one native binary with nothing else to install - no runtime,
no virtual machine, no separate toolchain to download afterward. This page
gets that binary onto your machine, checks it, and runs your first program.

## Install

Pick your platform:

```
brew install byteink/tap/bit           # macOS
curl -fsSL bitlang.org/install.sh | sh # Linux
irm bitlang.org/install.ps1 | iex      # Windows
```

Each of those gives you a single static binary. Check it:

```
bit --version
```

Later, an `install.sh` install moves to the newest release in place -
`bit upgrade --check` reports what it would do and changes nothing, and
`bit upgrade` applies it. A Homebrew install is upgraded with
`brew upgrade byteink/tap/bit` instead; `bit upgrade` notices and says so
rather than overwriting what Homebrew owns.

### Or run it as a container

No install at all: mount your project and run the toolchain from a
container image.

```
docker run --rm -v "$PWD:/work" ghcr.io/byteink/bit run hello.bit
```

To build a file rather than run it, pass your own user so the output belongs
to you instead of the container's:

```
docker run --rm --user "$(id -u):$(id -g)" -v "$PWD:/work" ghcr.io/byteink/bit build hello.bit
```

## Your first program

Put this in `hello.bit`:

```bit
fn main() {
  println("hello, bit")
}
```

Run it straight from source, or build a binary first:

```
bit run hello.bit      # compile to a temporary binary and execute it
bit build hello.bit    # leaves ./hello, a single native executable
```

`println` needs no import - it comes from the prelude, a small set of
functions every program gets for free. `main` is the entry point: returning
normally exits with status 0.

Anything you write after the file name is forwarded to the program as its
own arguments: `bit run hello.bit alpha beta` runs `hello` with `alpha` and
`beta` in its argument list, the same way
`bit build hello.bit -o hello && ./hello alpha beta` would. Write `--` before
an argument that would otherwise look like one of `bit run`'s own flags, for
example `bit run hello.bit -- --verbose`.

## Where next

Every install command above lives only on this page - a package's docs and
the Book both assume Bit is already installed and link back here instead of
repeating it.

[The Bit Book](book/README.md) starts from exactly this point and builds a
real program, Inkwell, one concept at a time. [Tools](tools/README.md) covers
`bit build`, `bit run`, `bit test`, `bit fmt`, `bit lint` and the package
manager in depth. [Language](reference/README.md) and
[Standard library](stdlib/README.md) are where each concept and each module
is defined, once, precisely.
