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

**The same ordering rule binds a new runtime primitive to `tools/build/`
itself.** `tools/build/` — the build driver — is compiled by the pinned stage0
too, and it transitively imports `std/fs`, `std/os` and the rest of the stdlib
the driver's own artifact steps need. A stdlib module `tools/build/` imports
that declares an `extern fn` the pinned stage0's bundled `libbitrt.a`
does not provide cannot land until stage0 is repinned to a release that has
it — the checker resolves every extern a module declares whether or not the
importer calls it, so it is not enough for the driver to avoid *calling* the
new function. #2152 landed exactly this (`bit_rt_fs_is_symlink_w`, added to
`stdlib/fs/fs.bit` and reached through `tools/build/artifacts.bit`'s `import {
walk } from "std/fs"`) and reverted at `49e74817` once `rm -rf bit-out &&
./make` was tried against it — every warm-`bit-out` gate had stayed green.

**`./make test-coldboot` is what catches that class before it lands.** It
deletes `bit-out/` entirely and re-bootstraps through the pinned stage0 exactly
as a fresh clone or `dist/release.sh` would (never `BIT_STAGE0_BIN` — that is
the two-pass escape hatch for when stage0 genuinely cannot build the tree, and
using it here would defeat the point), then asserts the default step
(`install`) exits 0. It is deliberately **not** part of `./make test` — a cold
bootstrap, including re-verifying and possibly re-fetching stage0, is the most
expensive operation in this repo — so run it explicitly before a release,
before merging to main, or right after a stage0 repin.

## Testing conventions

**Verify scoped changes with `scripts/gate.sh`, not the full suite.** It reads
your `git diff` and runs only the steps that change can affect — a `compiler/**`
edit runs the selfhost diffs plus `test-imports-bit`, `test-lint-filelines` and
`test-selfhostcheck`, a `tests/cases/**` edit runs `./make test-golden test-fuzz`.
Every bucket runs every gate whose OWN declared file set (its `argv`/`env` in
`tools/build/gates.bit`) intersects that bucket's paths, not just the one gate
the bucket was originally named after — see `scripts/gate.sh`'s own header
comment for the full bucket→gate table (#2962). One narrow exception to "a mix
of areas forces full" (#3055): `tests/bit/stdlibdocs.bit` makes a
`docs/stdlib/<mod>.md` page mandatory for every exported stdlib symbol, so an
ordinary stdlib-export change is structurally required to touch both the
`stdlib` and `docs` buckets in the same diff — resolving that to `full` would
mean no stdlib-export ticket could ever use the scoped gate. A diff touching
only `stdlib/<mod>/**` and its own paired `docs/stdlib/<mod>.md` (plus,
optionally, `docs/stdlib/README.md`) resolves to bucket `stdlibdocs` instead,
the union of the `stdlib` and `docs` buckets' own steps. Any other pairing —
`stdlib/**` with a *different* module's doc page, or with any bucket besides
`docs` — still spans more than one bucket and still forces `full`. For a
cross-cutting change (`tools/build/`), a mixed change set spanning more than
one bucket that isn't that narrow pairing, or anything
else it cannot confidently scope, `gate.sh` (no flags) **refuses rather than
guessing**: it
prints the resolved bucket and the reason, runs nothing, and exits 3
(`GATE_RESULT=FULL_REQUIRED`, #2872). Run `scripts/gate.sh --full` or
`./make test` directly (every gate, **18-18.5 min** — measured four separate
times, 18m13s-18m36s, most recently on `8f5e49e8`; the driver prints its own
`make: test — total` line, which is the number to trust over anything
reconstructed afterward) to actually verify a change like that, or as the
final pre-merge gate. In this repo's own workflow that full run is batched
once per push by whoever integrates (see `CLAUDE.md`'s verify-loop rule) —
that batching is a convention for this repo's own contributors, not this
script's answer for someone with no integrator to hand it to. Every harness
also has its own named step
(`./make test-golden|test-examples|test-stress|test-selfcheck|…`) for running one
area directly.

**Golden-file tests** are `tests/cases/*.bit` with a sibling `.expected`; the
line-1 directive selects the mode — `// run` (execute, compare stdout),
`// panic` (must exit 2, compare stderr), `// error` (expect diagnostics),
`// fmt` (canonicalization), `// types` (inferred-type dump), `// lint`.

**What the differentials assert.** The fifteen `scripts/selfhost-diff*.sh` once
diffed a separately-implemented bootstrap compiler against the Bit compiler, so
green meant "two independent implementations agree". The oracle is now the
pinned stage0 — the same compiler one release back — so green means "this
version did not change behaviour versus the last release". **That cannot catch
a bug present in both.**
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

**A gate whose printed count omits its denominator reads as coverage when it
is not — that is itself a way this repo can report green while verifying
nothing.** (Related but distinct: the "Two things a split can break" list
under `## File size` below is about what a *file split* can silently break,
not about scope.) Three measured instances, all re-measured on `main` at
`c2a1eb27`:

- **`test-filesize`** enforces the 800-line limit over `tests/bit/` only and
  prints `filesize: ok — 77 file(s) scanned, 30 file(s) skipped as fixture
  corpora, …` (`./bit-out/bin/bit run tests/bit/filesize.bit`). The tree holds
  **1182** tracked `.bit` files (`git ls-files -- '*.bit' | wc -l`), so the
  limit is enforced over 77 of 1182 (6.5%) and 1105 files are checked by
  nothing. Its scoping is deliberate — the point is only that the line reads
  as a whole-tree verdict.
- **`test-fmt`** (`tools/build/gates.bit:217`) walks `stdlib/` and `examples/`
  only — 173 of 1182 files (14.6%, `git ls-files -- 'stdlib/*.bit'
  'examples/*.bit' | wc -l`). `compiler/`, `runtime/` and `tests/` — 997 of
  1182 (84%, `git ls-files -- 'compiler/*.bit' 'runtime/*.bit' 'tests/*.bit' |
  wc -l`) — are checked for fmt-canonicality by nothing, which is why four
  genuine formatter bugs (#2878, #2879, #2880, #2140) sat unreported in the
  directories it omits.
- **#2570**: none of the **19** `scripts/selfhost-*.sh` differentials (every
  `selfhost-*.sh` file except the shared `selfhost-diffdump.sh` driver behind
  six of them) is invoked from `tools/build/**` — `grep -n "selfhost-"
  tools/build/*.bit dist/release.sh` turns up only comments — so the
  mandatory pre-push gate executes none of them.

The tell is the same in all three and it is cheap: a gate that prints a count
with no denominator cannot be read as coverage. A scoped gate should print
both its scope and the size of what it excludes, so the ratio is visible in
the log rather than reconstructible only by someone who goes looking. #2747
gates E0200 (the same 800-line rule) over `compiler/**` and `runtime/**`,
closing the gap instance 1 leaves outside `tests/bit/`; #2876 widens
`test-fmt` itself, closing instance 2.

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
- **`seed/` no longer exists** (#1593). `./make selfhost` keeps its step name
  because fifteen `scripts/selfhost-diff*.sh` invoke it, but it now means "run
  the pinned stage0 over `compiler/`".

## Website

**bitlang.org lives in a separate repository: `byteink/bit-website`.** It used to
be `website/` here. That repo consumes this one as a git submodule, because most
of the site is generated *from* this tree — `docs/tutorial.md`, `docs/reference`,
`docs/stdlib`, `docs/release/SUPPORT.md`, `stdlib/`, `examples/` and
`dist/install.sh`.

Two consequences for work done **here**:

- **The doc gates still carry the site.** `tests/bit/docs.bit` typechecks every
  Bit-tagged block under `docs/`, and the site publishes those same files —
  "Get started" *is* `docs/tutorial.md`, not a copy. A docs change that passes
  the gate here is publishable there; one that fails is not.
- **`examples/staticserver` is the only GATED copy of the website's serving
  logic.** It holds the same `fileResponse`/`safePath`/`mimeFor` as that repo's
  `server/`, deliberately duplicated: the website must not build out of
  `examples/`, because an example is a showcase, not a production dependency.
  Only this side is tested — the examples harness compiles and runs it, including
  a mutation-tested path-traversal check. **A fix to the traversal guard here
  must be mirrored into `byteink/bit-website`, and vice versa.** Across two
  repositories nothing mechanical will catch a divergence.

Changing `docs/` or `examples/` does not publish anything by itself. The site
repo pins this one by commit; someone has to bump its submodule and regenerate.
