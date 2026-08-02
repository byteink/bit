# Developing Bit

How this repository builds, tests and splits its own source. Read
[CONTRIBUTING.md](../CONTRIBUTING.md) first for the bar a change has to clear;
this document is the detail behind it.

## The build driver

```
./make                 # fetch/verify stage0, build libbitrt.a + bit
./make test            # every gate (23 harnesses + both artifacts)
./make fuzz -- 60      # open-ended fuzzing (default 60s; add a seed to replay)
./make --list          # every step and what it does
```

**`./make` is a Bit program, not a Makefile.** The `make` shell script is ~30
lines that resolve the pinned stage0, compile `tools/build/` with it, and exec
the result; every step body is written in Bit. Shell is acceptable there because
`sh` was already a hard dependency of this repo (the `selfhost-diff*.sh` family,
`gate.sh`, `stage0.sh`, `release.sh`), so ten lines of it add nothing that was
not already required.

`bit-out/` keeps its name: it is hardcoded in dozens of harnesses, scripts and
`.gitignore`, and renaming it is a mechanical change with no behavioural payoff.

## Bootstrap

Building `bit` requires a `bit`. The chain terminates at a published binary, not
at source: `./make` resolves the **pinned stage0** — the previous release —
digest-verified by `scripts/stage0.sh` against the committed
`dist/stage0/SHA256SUMS`. [`docs/release/bootstrap.md`](release/bootstrap.md) is
the authority.

**`compiler/` and `runtime/` may only use what the pinned stage0 understands**,
because stage0 compiles both. Needing a newer language feature means moving the
pin *first*: cut a release, repin `dist/stage0/SHA256SUMS`, then use it. (0.1.2
could not build a later `compiler/` because of `osRunTestBounded`, which is what
forced the 0.1.3 pin.)

## Testing conventions

**Verify scoped changes with `scripts/gate.sh`, not the full suite.** It reads
your `git diff` and runs only the steps that change can affect — a `compiler/**`
edit runs the selfhost diffs plus `test-imports-bit`, a `tests/cases/**` edit
runs `./make test-golden`. Run the full `./make test` (every gate, ~7 min) only
for a cross-cutting change (`tools/build/`, `runtime/`, `spec/`), a mixed change
set, or the final pre-merge gate — and `gate.sh` already falls back to it
automatically in those cases. Every harness also has its own named step
(`./make test-golden|test-examples|test-stress|test-selfcheck|…`) for running one
area directly.

**Golden-file tests** are `tests/cases/*.bit` with a sibling `.expected`; the
line-1 directive selects the mode — `// run` (execute, compare stdout),
`// panic` (must exit 2, compare stderr), `// error` (expect diagnostics),
`// fmt` (canonicalization), `// types` (inferred-type dump), `// lint`.

**What the differentials assert.** The fifteen `scripts/selfhost-diff*.sh` once
diffed a Zig seed against the Bit compiler, so green meant "two independent
implementations agree". The oracle is now the pinned stage0 — the same compiler
one release back — so green means "this version did not change behaviour versus
the last release". **That cannot catch a bug present in both.**
`docs/release/bootstrap.md` §5 records this as the accepted loss; do not read a
green differential as the stronger claim.

**Both sides of a differential must read THIS tree's stdlib and runtime.** The
stage0 tarball ships its own `stdlib/` and `libbitrt.a`, and `bit` resolves them
relative to the binary — so an unpinned oracle compares two stdlibs instead of
two compilers. `scripts/stage0.sh` emits a wrapper pinning `BIT_STDLIB`; the two
examples gates pin `BIT_LIBBITRT` themselves, because that names one archive per
triple and the wrapper cannot know the target.

**A hang is a failure, not a stall.** Every subprocess a harness spawns carries a
wall-clock deadline. Exceeding it kills that child (by its own PID, never a name
pattern), reports `TIMED OUT` naming the case, and reddens the suite. Default
**900s**; override with `BIT_TEST_TIMEOUT_S=<seconds>` on a slower host, or `0`
to block forever as before. A timeout is a distinct outcome from a crash: a child
killed by SIGSEGV/SIGBUS/SIGABRT is reported as a crash naming the signal.

The corpus's worst case is `tests/stress/quicwire` at 158s under `BIT_GC=stress`,
so 900s is a 5.7x margin rather than a stopgap. Two counter-intuitive things
about that number, worth knowing before re-measuring: `polloneshotdarwin` used to
sit beside it at 122s and is now 2s, because it bounded a deliberately-never-
satisfied wait in *idle scheduler passes* and an idle pass went from microseconds
to up to 1ms — **any test that counts scheduler passes is measuring an
implementation detail; bound it in wall clock instead.** And quicwire's 158s is
not a defect: `BIT_GC=off` runs it in ~1s, so the gap is that the collector's
machine code no longer comes from an optimising backend. **Do not read a
`TIMED OUT` as a hang until you have timed the program standalone**, and run
`uptime` first — load above ~20 on an 18-core box makes every timing worthless.

Doc snippets are gated: `tests/bit/docs.bit` typechecks every Bit-tagged fenced
code block under `docs/`, and `tests/bit/stdlibdocs.bit` fails on an undocumented
export. A doc that does not compile fails the build.

## File size

Hard limit **800 lines per file**, target ~500. 800 is the default of the repo's
own lint rule `E0200 max-file-lines` — the two must stay in step; changing one
means changing the other.

Split by moving top-level blocks into **sibling `.bit` files in the same
directory**. Siblings are the same module, so a split needs no imports, no
namespace changes and no call-site edits. Do not split into subdirectories — a
new directory is a new module, which is a design change, not a cleanup.

Two things a split can break that a green build will **not** catch:

- **Silent line loss.** A split that swallows blank lines still compiles, passes
  selfcheck, and passes `./make test`. Gate it with a line-multiset comparison of
  the directory before vs after — zero deletions, additions only for new file
  headers. Derive the "before" side from `git show HEAD:<path>`; a baseline
  written to a shared path can be clobbered by a concurrent agent, and a locale
  mismatch between the two sorts fabricates thousands of phantom deletions.
  Stronger still, and preferred: reassembling the new files in the original order
  must reproduce the original byte-for-byte.
- **Changed codegen.** Module files concatenate in bytewise sorted filename
  order, and the inliner only inlines a callee it has already lowered. A new
  sibling that sorts *before* the file holding its helpers silently loses
  inlining — perfect text diff, different machine code. Name new files so they
  sort after their helpers (for `sock.bit` the working order was
  `sock < tcp < udp`), and confirm with `bit build <src> --emit-obj` byte-identical
  before vs after.

Splitting can also make a test **vacuous rather than failing**: any gate that
names a single source path will keep scanning the remnant. Point such gates at a
directory and error on finding zero sources.

## Two names that used to mean something else

Old notes and tickets will mislead you:

- **`compiler/` was `selfhost/`** (#1841). The self-hosted compiler is *the*
  compiler; "selfhost" only carried information while a non-self-hosted one
  existed.
- **`seed/` no longer exists** (#1593). The Zig seed compiler is deleted, and so
  is `build.zig` (#1871) — the repo contains no Zig at all. `./make selfhost`
  keeps its step name because fifteen `scripts/selfhost-diff*.sh` invoke it, but
  it now means "run the pinned stage0 over `compiler/`".

## Website

The site is generated by **`website/gen`** and served by **`website/server`**,
both Bit programs. `website/Dockerfile` is `FROM scratch`: one cross-compiled
static binary plus the generated HTML — no distro, no libc, no shell.

**`website/server` is TEMPORARY and must not grow.** It is a few dozen lines that
answer GET for a directory. The real static server and the web framework are
separate, planned pieces of work, and both will replace it. Adding routing,
templating, compression, caching or middleware turns it into a framework nobody
designed — if you need any of that, that is the signal to build the real thing,
not to extend this.

**Two copies of the serving logic exist on purpose, and drift is the risk.**
`website/server/serve.bit` and `examples/staticserver/staticserver.bit` hold the
same `fileResponse`/`safePath`/`mimeFor`. The website deliberately does not build
out of `examples/` — an example is a showcase, not a production dependency — but
only the example is gated: the examples harness compiles and runs it, including a
mutation-tested path-traversal check. So a fix in `website/server` that is not
mirrored into the example is a fix with no test, and the traversal guard is where
that bites. **Change one, change both**, until the real server retires both.

The generator reads `docs/` and never writes it, so the doc gates keep covering
the content the site publishes. "Get started" *is* `docs/tutorial.md`, not a copy.

Deploys go through **ssd**. `.ssd/` is machine-local and gitignored;
`website/ssd.yaml.example` is the committed reference. `website/deploy.sh`
fetches the advisory feed, regenerates the pages, then hands over to
`ssd deploy website`, which builds the image on the server from committed source.
