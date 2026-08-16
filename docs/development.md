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

### Landing a runtime ABI change

**Changing an exported `runtime/**` symbol's arity or parameter types needs
the two-pass `BIT_STAGE0_BIN` bootstrap (#1857) — a single `./make selfhost`
is not safe for it, and #3152 is why.** `stepSelfhost`
(`tools/build/artifacts.bit:399`) links THIS TREE's `libbitrt.a` (line 412,
built from current `runtime/**` source) against a compiler produced by
compiling `compiler/**` with the PINNED stage0 (line 420) — a previous
release that never saw the new signature. `Op.RtCall` lowering (the backend's
lowering for slice/map/chan-literal syntax, e.g. `[]T(n)`) hardcodes its
callee's argument count into whichever compiler emits the call, as a property
of that compiler's own already-compiled machine code — not something `stage0
build compiler` re-derives from `runtime/**` source. So stage0 keeps emitting
calls at the OLD arity no matter what the tree's own copy of that function
now declares. The linker resolves a symbol NAME, not a signature, so this
links without error; the callee then reads an argument register the caller
never wrote.

#3152's concrete case: `runtime/root/slices.bit`'s `rtSliceNew` (and three
neighbouring exports) gained a trailing `elemSize` parameter, and the
resulting `bit-out/bin/bit` allocated 11.3 GB in 3 seconds compiling a
12-line program — the COMPILER'S OWN internal slice allocations (not
anything about the input program) read `elemSize` from whatever register
`x3` happened to hold, multiplied into `gcAllocRaw`'s size argument at
`runtime/root/root.bit:555`.

**`./make selfhost` now refuses this class of change outright, before
linking, with a diagnostic naming every mismatched symbol**
(`tools/build/abiarity.bit`, `checkRuntimeAbiArity`, called from
`stepSelfhost`). It diffs every `@symbol(...)`-exported `runtime/**`
function's declared parameter count in the working tree against the same
symbol's arity in the git tag stage0 was cut from
(`dist/stage0/SHA256SUMS`) — a sound proxy for stage0's own opaque,
unreadable call-site table, because a release only ships once its own
selfhost build and full suite pass against that exact runtime, so within any
single released tree the compiler backend's hardcoded arity for a symbol and
that symbol's own declared signature are, by construction, the same number.
The comparison is keyed by (file, symbol name), not symbol name alone — a
name like `_start` or `bit_rt_port_park_mono_ns` is legitimately exported
with a different arity from `runtime/root/darwin/` and `runtime/root/linux/`
files, since only one platform's file compiles per target; a flat
name-keyed map produced two false positives on an unmodified tree before
this was fixed. See `tools/build/abiarity.bit`'s own header for the full
reasoning and its documented narrow edge (a symbol renamed in the same
change that also changes its arity is not caught).

The check skips itself when `BIT_STAGE0_BIN` is set: that override is not
the pinned release, so there is no committed tag to diff its tree against —
and it is precisely the supported recovery path, not a mismatch to refuse.

**The fix is NOT the plain two-pass bootstrap `scripts/stage0.sh`'s own
header documents for #1857.** That recipe's pass 1 is a bare `./make`, and
#1857 was a compiler-only fix — the runtime was unchanged, so pass 1's
`./make` already builds against a runtime stage0 is self-consistent with.
Here the runtime is what changed: the working tree's `runtime/**` already
carries the new arity, which is exactly what this guard just refused to link
against stage0's old-arity call sites. Running the printed `./make` again
reproduces the same refusal — it is the very command that just failed.

Pass 1 instead needs the runtime **checked out at the commit before the
change**, so the compiler it produces (built from the new `compiler/**`
source, but linked against the OLD runtime archive) is internally
consistent — old stage0 emits old-arity calls, and the OLD runtime is what
still expects that arity:

```sh
rm -rf bit-out
git checkout <commit before this runtime/** change> -- runtime/
./make                                        # pass 1: stage0 -> a compiler from the new compiler/** source, linked against the OLD runtime
cp bit-out/bin/bit "$TMPDIR/bit1"
git checkout HEAD -- runtime/                 # restore BEFORE anything else reads the tree
BIT_STAGE0_BIN="$TMPDIR/bit1" ./make          # pass 2 — do NOT rm -rf bit-out here
```

Pass 2 rebuilds `libbitrt.a` from the new `runtime/**` (now restored) and
relinks with `BIT_STAGE0_BIN` pointed at pass 1's own output — a compiler
already built from the new `compiler/**` source, so it emits the new arity
against the new runtime. Once pass 2's result is released, repin
`dist/stage0/SHA256SUMS` to it; a single pass is correct again after that,
same as any other `BIT_STAGE0_BIN` recovery.

Two traps, each cost a real run when skipped:

- **Do not `rm -rf bit-out` between passes.** `./make` links its own build
  driver against `bit-out/lib/<triple>/libbitrt.a`; wiping the directory
  between pass 1 and pass 2 leaves the driver unbuildable —
  `bit: runtime archive bit-out/lib/aarch64-macos/libbitrt.a: cannot open
  file` then `make: cannot build the driver`, rc=2 in about a second.
- **Restore `runtime/` on every exit path, including failure**, before
  anything else reads the tree. A worktree left holding another commit's
  `runtime/` makes every later measurement silently wrong — nothing signals
  that it happened.

**Regression coverage for the escape hatch itself is `./make
test-stage0override`** (#3118, `tests/bit/stage0override.bit`): asserts
`BIT_STAGE0_BIN` is actually honoured (not silently ignored) and that
`fingerprint()`'s override-hashing invalidates the `libbitrt` cache when the
override binary's content changes at a fixed path. It does not assert that a
two-pass ABI-change bootstrap produces a *correct* runtime — that is a
property of the specific change being landed — only that the mechanism
itself works as documented.

## Does `./make libbitrt` build `runtime/**` with the tree compiler? (#3054)

**No — it stays pinned-stage0-built by default.** The status quo is not free of
risk either, though, so the fix is an opt-in, not silence. This is the decision
recorded so it is not re-derived from scratch the next time it comes up.

**The two paths, as of #3034.** `dist/release.sh:198` — the **shipped**
`libbitrt.a` is compiled by `bit1`, this tree's own self-hosted compiler, not
stage0. It gets there with a genuine two-pass bootstrap: `./make libbitrt`
first builds a bootstrap archive (L0) with the pinned stage0, stage0 uses L0 to
build a native `bit1` (`./make`'s own `selfhost` step), then `bit1` rebuilds
the real, shipped archive (L1) for all three targets via
`scripts/g2archive.sh`, and only L1 is packaged.
`tools/build/artifacts.bit:267` — the **ordinary** `./make libbitrt` still
compiles every `runtime/**` module with the pinned stage0. There is no L1 pass
in the everyday build.

**Why this is not a style choice: source vs. codegen.** A *source* edit to
`runtime/**` takes effect immediately either way, because stage0 re-reads the
current tree's source on every build. What the pinned-stage0 path freezes is
*codegen* — the machine code stage0's own, already-built copy of
`compiler/codegen.bit`/`emitmacho.bit`/`emitelf.bit` emits for `runtime/**`'s
own functions. #1927 is exactly a codegen-freeze bug: it needs a writer change
(`compiler/codegen.bit`, pad each stack-map entry to 8 bytes) and a reader
change (the runtime's walk) to move together. The writer change reaches
`bit-out/bin/bit` immediately — stage0 recompiles `compiler/**` from tree
source on every `./make selfhost` — so every other compiled unit gets the new,
padded format right away. But `libbitrt.a`'s own internal stack maps are
emitted by stage0's frozen, pre-fix copy of the writer, so they stay unpadded
until a release cut *after* the fix is pinned as the new stage0. There is no
discriminator between the two formats in the merged table (`runtime/ABI.md`
§4), so landing the reader half with no runtime-build change makes every dev
build between "the fix lands" and "the next repin" silently misdecode
`libbitrt.a`'s own stack maps. Waiting for the next repin does not avoid that
window, it only bounds its length — and `dist/stage0/SHA256SUMS`'s `git log`
shows recent repins landing roughly every 1-3 days, so the window is real, not
theoretical. The same reasoning applies to any future writer/reader pair, not
just #1927.

**Also worth naming, because the top-priority performance work depends on
getting this precise: same source-vs-codegen split, opposite direction.** A
*source* fix in `compiler/**` (#1852/#1853, landed) improves the machine code
the tree compiler emits for user programs immediately — the next
`./make selfhost` recompiles `compiler/**` from source. It does **not** improve
the machine code inside `libbitrt.a` itself, because that machine code was
already emitted, once, by the frozen pinned stage0 — no amount of rebuilding
re-emits it. #3113 measured `strings` at 137.4x C / 55.9x Go and found the time
is spent in exactly that frozen code (GC, allocator, slice/string primitives).
So `#1852`/`#1853`/queued `#3104`/`#3105`/`#3107` cannot move that number until
either a repin happens or the opt-in below exists and is used.

### The four questions

**1. How likely is a tree compiler that miscompiles the runtime, given the
fixed-point assert runs on every release?** The fixed-point assert
(`scripts/selfhost-fixpoint.sh`: `stageB` built by `stageA`, `stageC` built by
`stageB`, `sha256(stageB)==sha256(stageC)`) proves only that the compiler
reliably *reproduces itself*. It says nothing about whether the compiler
correctly compiles `runtime/**` — a deterministic miscompile (the same wrong
bytes every time, exactly #2569's shape) passes a fixed-point check as cleanly
as a correct compiler does. The actual backstop for runtime correctness is
`scripts/selfhost-diffruntime.sh`, and both it and the fixed-point check run
only via `./make test-differentials` (#2570, registered in `coreSteps()`, not
`gateSteps()`) — once per push, not on every commit that touches codegen.
Repins have landed roughly every 1-3 days recently (`git log` on
`dist/stage0/SHA256SUMS`), so in practice a runtime-affecting codegen
regression has a push-to-push window to surface, through a suite only the
integrator runs.

**2. Does `BIT_STAGE0_BIN` fully cover recovery, and is it exercised by
anything?** No. `grep -rln STAGE0_BIN tests/` returns exactly one file,
`tests/bit/coldboot.bit`, and its own comment says it deliberately does *not*
use `BIT_STAGE0_BIN` — "using it here would defeat the point," since
`test-coldboot`'s whole job is proving the pinned stage0 *alone* can
bootstrap. No test anywhere sets `BIT_STAGE0_BIN` and asserts the resulting
build is correct. `scripts/stage0.sh`'s own header calls the override
"DELIBERATELY UNVERIFIED, unlike the pinned path... there is no digest to
check an arbitrary local binary against." The escape hatch a switch would lean
on more heavily has zero regression coverage today. Filed as #3118.

**3. Do the selfhost differentials still mean what they mean if the runtime is
tree-built?** Yes on aarch64, and non-obviously: they already exercise exactly
that scenario, continuously, regardless of what `stepLibbitrt` does. #2741's
module-level object comparison in `scripts/selfhost-diffruntime.sh` builds
every `runtime/**` module *twice* purely for the comparison — once with the
pinned oracle, once with `bit-out/bin/bit` (the tree's own self-hosted
compiler) — into a scratch `mktemp -d`, never into `bit-out/lib/`. It never
reads the archive `stepLibbitrt` actually writes. So "the tree compiler builds
`runtime/**`" is already what this differential asserts about on every
`test-differentials` run; switching `stepLibbitrt` changes which compiler
produces the *shipped* archive, not what this gate has been checking.

What did just change (#3103) is the invariant itself, and it happens to be
exactly right for a tree-built world: byte-for-byte identity against the
pinned oracle stopped being valid the moment a real backend optimization
(#1852) landed, because an optimization is supposed to change bytes (22 of 23
modules now diverge, all smaller, none a bug). On aarch64 hosts the check now
disassembles both objects and compares only the acquire/release
atomic-instruction *width* signature (mnemonic + register class, register
number stripped) — the exact property #2569's bug broke, and nothing else.
Mutation-tested against the real bug (#3103): 0/23 modules diverge by
signature between #1852's tree and the pinned oracle, where 22/23 diverge by
raw bytes; the real v0.1.10 #2569 defect diverges 6/6 by both. So the
invariant tolerates the legitimate codegen improvement a tree-built archive
would carry, while still catching the class of bug a switch actually risks.

x86-64 is the one gap, and it predates this decision. The differential keeps
strict byte identity there (no local x86-64 host to verify a
signature-extraction regex against — tracked separately, #3110). No x86-64
codegen improvement has landed yet, so this has not bitten anyone, but using a
tree-built archive on x86_64-linux before #3110 closes would make that
target's differential go red the moment one does, for a reason unrelated to
correctness.

**4. Is there a middle option?** Yes, and it is the right one right now: keep
`./make libbitrt` stage0-built by default, add an opt-in that forces a
tree-built archive — not the reverse. Tree-built-by-default was rejected
because it would make the one recovery mechanism a switch leans on
(`BIT_STAGE0_BIN`, question 2) the routine path for a codegen regression at
exactly the moment its coverage is weakest, and it would change
`bit-out/lib/*/libbitrt.a`'s bytes for every dev build on every platform, where
only aarch64's invariant is proven tolerant of legitimate codegen change
(question 3). Stage0-by-default preserves today's build cost and verified
safety envelope for the common case, while giving #1927 — and any future
writer/reader pair that must move together — a real, load-bearing mechanism
instead of the purely-manual, unverified two-pass `BIT_STAGE0_BIN` dance
`scripts/stage0.sh` currently documents.

**What the opt-in requires, filed as #3117, not done here.**
`tools/build/defs.bit` declares `selfhost`'s only dependency as `["libbitrt"]`,
and `stepSelfhost` always resolves stage0 fresh via `runArtifact`
(`main.bit:125`) — there is no path that reuses a previously-built
`bit-out/bin/bit` as a builder for anything. An opt-in tree-built `libbitrt`
therefore cannot just swap which `BIT=` `stepLibbitrt` passes to
`scripts/g2archive.sh` — it needs its own internal two-pass bootstrap,
mirroring `dist/release.sh`'s shape: build the L0 archive to a scratch path as
today, use stage0 to build a throwaway host-native self-hosted compiler
linking it, then use that compiler to build the real
`bit-out/lib/<target>/libbitrt.a` for all three targets. `selfhost`'s existing
dependency on `libbitrt` does not need to invert — it already runs after
`libbitrt` and already links whatever `stepLibbitrt` leaves at
`bit-out/lib/<host>/libbitrt.a`. `fingerprint()` (`artifacts.bit:112`) also
needs to fold in `compiler/**` when the opt-in is active — today it
deliberately excludes `compiler/**` because `compiler/**` cannot affect
stage0-built bytes, but it would under a tree-built archive, and a fix landing
there with the cache unaware of it is the same stale-archive shape
`fingerprint()` already guards against for `BIT_STAGE0_BIN` (#1863).

**#1927 stays blocked, now on #3117 rather than on #3054 directly** — the
decision is made, but nothing changes for it until the opt-in exists and #1927
uses it.

**Correct invocation: ONE command, not two (#3126).** `BIT_LIBBITRT_TREE=1`
must be visible to the same process that runs `selfhost`, because
`tools/build/defs.bit` declares `Step{name: "selfhost", deps: ["libbitrt"]}` —
a bare `./make selfhost` re-invokes `stepLibbitrt` as its own dependency,
inside `selfhost`'s own process. A shell scopes `VAR=1 cmd1 && cmd2` to `cmd1`
only (plain POSIX behaviour, not a bug in either command), so:

```sh
BIT_LIBBITRT_TREE=1 ./make libbitrt && ./make selfhost   # WRONG — silently reverts
BIT_LIBBITRT_TREE=1 ./make selfhost                       # correct — one process
```

The wrong form gives no error and no warning. The first `./make libbitrt`
genuinely writes the tree-built archive; then the bare `./make selfhost`
re-runs `stepLibbitrt` with the flag unset, which rebuilds and silently
overwrites it with the stage0-built archive before `selfhost` links anything —
and `stepSelfhost` itself then reports "up to date", because
`bit-out/bin/bit`'s own stamp never changed. Measured on aarch64-macos at
`7b79f38b`: the two-command form leaves `bit-out/lib/aarch64-macos/libbitrt.a`
at 551848 bytes (the stage0-built size, byte-identical to a plain
`./make libbitrt`'s output); the one-command form correctly produces 489626
bytes (tree-built, smaller because it carries a real backend optimization the
frozen stage0 does not). This is not a cosmetic footgun: the whole reason
`BIT_LIBBITRT_TREE` exists is to measure whether a queued `compiler/**` codegen
fix (question 3 above) would improve the runtime once repinned, and the wrong
form silently hands back the stage0 archive while the person measuring
believes they are looking at the tree build — producing a confidently wrong
"no improvement" result rather than an error.

To set it for a whole shell session instead of one command line:
`export BIT_LIBBITRT_TREE=1`, then `unset BIT_LIBBITRT_TREE` (or open a new
shell) to return to the default stage0-built path — an exported variable is
visible to every subprocess `./make` spawns, so `./make libbitrt` followed by
`./make selfhost` both see it and the two-command form works correctly too.

## Testing conventions

**Verify scoped changes with `scripts/gate.sh`, not the full suite.** It reads
your `git diff` and runs only the steps that change can affect — a `compiler/**`
edit runs the selfhost diffs plus `test-imports-bit`, `test-lint-filelines`,
`test-selfhostcheck` and `test-selfcheck`, a `tests/cases/**` edit runs
`./make test-golden test-fuzz`.
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

**A second, separate limit: `diffir`/`diffiropt`/`difftypes` never run the
resolver, so they cannot see a bug that only exists on the resolver-active
path.** `--dump-ir-pre`/`--dump-ir`/`--dump-types` all reach `checkModule`
through `lowerSourceModule`/`checkSourceDump` (`compiler/lowerdriver.bit:312`,
`compiler/checkmodule.bit:480`) and never call `resolveModule`.
`compiler/check.bit:163`'s own field comment says so: `nodeSymbols` is "[e]mpty
on the bare dump entry points ... checkExprType falls back to the flat env
there." `bit build`/`run`/`test`/`check`/`doc` all resolve first
(`compiler/checkproject.bit:115`, `resolveModule(..., true)`) and only then
check — a different branch inside `checkExprType`, with different staleness
behaviour, so the two paths can disagree on the same source.

Demonstrated on `tests/cases/run_generic_let_chain.bit` (#3069, the #3068
degenerate-generic-instance repro, live in the corpus): `--dump-ir-pre` and
`--dump-ir` both show `f1(x)` inside `build<T>` targeting the CONCRETE
`f1$3`. A real `bit build --emit-obj` of the same file, disassembled
(`otool -tvV`/`otool -r`, relocation symbolnum resolved against `nm -pa`'s
symbol-table order), shows `main` — after inlining — calling `_f1$0`, the
DEGENERATE unbound-type-param instance, with the scalar `5`. Same source, same
lowering/optimizer code, different call target, because only one of the two
paths ran the resolver before lowering.

`diffcheck`/`diffverdict`/`diffexamples(-x64)`/`difftests`/`diffsafepoints`/
`diffdoc` and `diffruntime`'s module-level (object-byte) half all run
`check`/`build`/`doc`/`test`, so they ARE resolver-active — this specific
class is not invisible to the whole family, only to the three dump-based
differentials plus `diffruntime`'s file-level (`--dump-ir-pre`) half. None of
those resolver-active differentials would have caught *this particular* bug
either, but each for an unrelated reason (verdict-only, stdout-only, or an
unrelated codegen property) — none of them compares instantiation targeting or
emitted call symbols, which is the level this bug lives at. Full per-differential
table on #3069. No new differential was added; the gap is accepted and
documented here rather than fixed, because fixing it means changing what the
dump commands' entry points do, which is a compiler change with its own
sequencing (see #3069).

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

**A benchmark win is not landed until its baseline moves down with it.**
`tests/bit/benchgate/{benchgate,baselines}.bit` compares peak RSS and user CPU
against a baseline at 1.5x — see that file's own header for the method
(minimum of N runs, peak RSS and user CPU, never wall clock; not restated
here). The reason worth stating, because it is not obvious from the gate's
code: **the bar is one-directional on purpose, so the ratchet only tightens
when a human tightens it.** A change that improves a `bench/cases/*`
benchmark is not finished until the case's entry in
`tests/bit/benchgate/baselines.bit` is re-recorded in the same commit. Run
`./make test-benchgate` and read the `cpu=`/`rss=` line it prints for that
case (`benchgate: <name> cpu=...cs (baseline ...cs, ceiling ...cs)
rss=...B (baseline ...B, ceiling ...B)` — printed before the comparison
even fires) to get the numbers to write into the table. Skip this and nothing
fails today: the improved run just clears 1.5x more comfortably, and a later
change that regresses the benchmark back toward the OLD, unlowered baseline
still passes cleanly.

Once #3130 lands, this is mechanically enforced for one metric: deterministic
object counts get a two-sided band, so an unrecorded improvement there fails
the gate on its own. Peak RSS and user CPU stay noisy by design — that
noise is exactly why they need the 1.5x slack in the first place — so a
two-sided band is not sound for either, and re-recording those two stays a
written convention rather than something the gate checks for you.

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
