# How `bit` bootstraps

Status: DECIDED 2026-07-28 (#1840) and implemented in #1593 — `seed/` no longer
exists.

`bit` is compiled by `bit`. This document decides how that terminates, and it
answers two questions at once:

1. how to build `bit` from a clean checkout with no `bit` already present
2. what the differential oracle is that the differential-gate family (§4)
   compares this tree against

## The decision in one paragraph

Stage0 is **the previous release's `bit` binary for the host triple**, fetched
and verified against a digest **committed in this repo**. The differential
gates are re-based from "seed vs self-hosted" to "release N-1 vs N".
Self-consistency is proven by the byte-identical fixed point, which needs no
seed. The capability genuinely lost is the independent second implementation: a
bug present in both N-1 and N becomes invisible, and that is accepted,
mitigated by diverse double-compiling at release time rather than pretended
away.

## 1. Which artifact is stage0, where it comes from, how a clean checkout verifies it

**Stage0 is `bit` from the most recent release, for the host triple.**
`dist/release.sh` already produces exactly this: one self-hosted `bit` per target
for `x86_64-linux`, `aarch64-linux`, `aarch64-macos`, packaged as
`bit-<version>-<os>-<arch>.tar.xz` with a `SHA256SUMS` over them, published as a
GitHub release and a Homebrew tap.

This is the Go and Rust model, verified against current upstream documentation
rather than memory:

- **Go** requires a previous Go to build Go, on a published schedule: "Go version
  1.N will require a Go 1.M compiler, where M is N-2 rounded down to an even
  number." It lists four ways to obtain that toolchain: download a binary
  release, cross-compile from a machine that has one, use `gccgo`, or build Go
  1.4 (the last C-implemented release) from source.
- **Rust** downloads a stage0 `rustc` tarball and verifies it against SHA256
  checksums recorded in `src/stage0` in the rust repo itself.
- A third route, taken by some projects, is to commit a minimal compiler as a
  WebAssembly blob, so only a C compiler is needed.

We take Rust's shape, because `release.sh` already emits checksummed per-target
artifacts and a tap, so nothing new has to be built or hosted.

**The digest must be COMMITTED, and this is the one place the existing machinery
is not sufficient.** `dist/install.sh` today downloads `SHA256SUMS` from the same
base URL as the artifact (`install.sh:60`). That is a correct integrity check —
it catches a truncated or corrupted download — but it is NOT a trust anchor:
anyone who can serve a modified tarball can serve a matching `SHA256SUMS`. For an
end-user install that is an accepted risk mitigated by HTTPS and the tap. For
stage0 it is not, because stage0 compiles the compiler.

So `dist/stage0/SHA256SUMS` is committed to this repository, listing one digest
per supported triple for the pinned stage0 version, and the bootstrap verifies
against **that file**, never against a downloaded one. Changing stage0 then
requires a commit, which is reviewable, rather than a server-side change, which
is not.

The verification command a clean checkout runs:

```sh
dist/stage0-verify.sh <artifact.tar.xz>
```

It resolves the host triple, looks the expected digest up in
`dist/stage0/SHA256SUMS`, computes the actual digest with `shasum -a 256` or
`sha256sum`, and fails loudly on any mismatch or on a missing entry. It refuses
rather than warns: a bootstrap that continues after a failed digest check is a
bootstrap with no digest check.

## 2. What happens when no release exists for the host triple

`dist/release.sh` ships **four** targets: x86_64-linux, aarch64-linux,
aarch64-macos and x86_64-windows (#3342). Stage0 covers only the first
three — a stage0 entry can only name a **published** release for that triple
(`dist/stage0/SHA256SUMS`), and no Windows release existed before #3342
shipped one, so there is no Windows stage0 yet. Repinning it is a separate
ticket, now that a Windows release can exist to name. There is also no
32-bit or big-endian target, and ARM64 Windows is out of scope for the
Windows port.

On a host outside those three stage0-pinned triples there is no stage0 and
**bootstrapping is not possible on that machine**. That is a deliberate
statement, not a gap to be papered over. The supported path is Go's second
option: cross-compile a stage0 from a machine that has one.

```sh
# on a supported host
./bit-out/bin/bit build compiler --target <new-triple> -o bit-<new-triple>
```

The new triple must already be a target the compiler can emit for. A genuinely
new target is a porting job, and porting a self-hosted compiler to a target it
cannot yet emit for requires a working compiler on some host by definition —
that is a property of self-hosting, not of this decision.

## 3. How a compromised stage0 is detected

A stage0 binary compiles the compiler, so a malicious stage0 can inject itself
into every compiler it builds and into the source it appears to compile
faithfully. This is Thompson's trusting-trust attack and it is not hypothetical
enough to ignore.

**The fixed point is the lever, and it already exists.**
`scripts/selfhost-fixpoint.sh` proves:

```
stageA builds compiler/ -> stageB
stageB builds compiler/ -> stageC
sha256(stageB) == sha256(stageC)
```

Its own header states why this is the right property: the binary the pinned
stage0 produces is **not** required to be byte-identical to stageB — two
compilers can emit different-but-equivalent code for the same source — what
must hold is `bit == bit-built-by-bit`. A stage0 that injects a payload must
make that payload survive into stageB and reproduce itself byte-identically in
stageC, which is a far narrower attack than modifying a compiler.

**Byte-identical self-reproduction alone does not detect it, though**, because a
faithful self-reproducing backdoor is exactly what the classic attack builds. The
check that does is **diverse double-compiling**: build the same source with two
INDEPENDENTLY OBTAINED stage0s and require the resulting stageB to be
byte-identical.

```sh
# two stage0s: the pinned release, and the one before it
bit-N-1 build compiler -o /tmp/stageB-a
bit-N-2 build compiler -o /tmp/stageB-b
cmp /tmp/stageB-a /tmp/stageB-b     # must be identical
```

Two stage0s from the same publisher is weaker than two from different publishers,
and that limit is stated rather than hidden. This is required at RELEASE time,
not on every developer build, because it costs a second full compile.

A committed-blob bootstrap has been audited this way in practice: a third party
rebuilt one from source, iterating 45+ times, got a byte-identical result, and
had it independently reproduced in Guix — the conclusion being that nothing was
hiding in the blob that had not been checked in as a source file. That is the
standard to aim at, and it is reachable only because the result is reproducible.

## 4. What each differential gate compares after `seed/` is gone

**#1840 said seven gates. That count has already drifted once — #1859 added a
sixteenth (`selfhost-diffruntime.sh`) after this table was first written, and
it went unrecorded here for a release cycle.** Do not carry a number forward
from this paragraph either; re-derive the row count from `scripts/` before
trusting it, because an undercount here is exactly how a gate goes silently
retired:

```sh
ls scripts/selfhost-diff*.sh scripts/selfhost-fixpoint.sh scripts/selfhost-fuzzdiff.sh \
  | grep -v -e diffall.sh -e diffdump.sh
```

That excludes two kinds of file the naive `scripts/selfhost-*.sh` glob would
otherwise sweep in, neither of which is a gate in its own right:

- `scripts/selfhost-diffall.sh`, the family's own aggregator (it runs every
  row below and reduces them to one verdict; itself listed as a row because
  it is independently invocable, but it compares nothing on its own), and
  `scripts/selfhost-diffdump.sh`, the shared table-driven driver behind six
  of the rows below (`ast`/`tokens`/`diags`/`types`/`ir`/`iropt`) — it takes a
  required mode argument and errors on a bare invocation, so it is not itself
  a gate.
- `scripts/selfhost-ir-canon.sh` and `scripts/selfhost-ir-signatures.sh`,
  sourced-only helper functions shared by the IR-comparing rows (including
  `diffruntime.sh`, below). Invoked directly they run only their own
  self-check and exit in under a second; they walk no corpus and are not
  differentials.

Every `selfhost-diff*.sh` runs the pinned stage0 (release N-1) against
`bit-out/bin/bit` and diffs the output. Before #1593 the same scripts ran
`bit-out/bin/bit-seed`; "re-based" below names exactly that substitution and
nothing more.

| gate | compares | post-seed oracle |
|---|---|---|
| `selfhost-difftokens.sh` | token stream | re-based on N-1 |
| `selfhost-diffast.sh` | AST dump | re-based on N-1 |
| `selfhost-diffcheck.sh` | check verdict | re-based on N-1 |
| `selfhost-diffdiags.sh` | diagnostic text | re-based on N-1 |
| `selfhost-difftypes.sh` | inferred types | re-based on N-1 |
| `selfhost-diffir.sh` | pre-opt IR | re-based on N-1 |
| `selfhost-diffiropt.sh` | post-opt IR | re-based on N-1 |
| `selfhost-diffruntime.sh` | runtime codegen IR — its own corpus, `runtime/**/*.bit`, not the shared stdlib/examples/_tests_/cases/_tests_/imports corpus every other row walks (#1859) | re-based on N-1 |
| `selfhost-diffsafepoints.sh` | static safepoint counts | re-based on N-1 |
| `selfhost-difffmt.sh` | formatter output | re-based on N-1 |
| `selfhost-diffdoc.sh` | `bit doc` output | re-based on N-1 |
| `selfhost-diffverdict.sh` | verdict over a generated matrix | re-based on N-1 |
| `selfhost-difftests.sh` | `bit test` results | re-based on N-1 |
| `selfhost-diffexamples.sh` | example RUNTIME behaviour | re-based on N-1 |
| `selfhost-diffexamples-x64.sh` | same, on x86_64-linux | re-based on N-1 |
| `selfhost-fuzzdiff.sh` | front-end on mutated corpus | re-based on N-1 |
| `selfhost-fixpoint.sh` | stageB vs stageC | **UNCHANGED** — never used the seed |
| `selfhost-diffall.sh` | aggregator | unchanged, runs the above |

**None of the rows above run as part of `./make test`.** Since #2570 the whole
family is reachable as `./make test-differentials` (`tools/build/defs.bit`'s
`coreSteps()`, deliberately not `gateSteps()` — it runs into the tens of
minutes, so folding it into `test` would roughly double the pre-push suite).
It is the third step of the pre-push gate, run once over the whole batch
immediately before `git push`, after `rm -rf bit-out && ./make` and
`./make test`; neither `scripts/gate.sh` nor `./make test` on its own
exercises it.

Two consequences to plan for rather than discover:

- **A re-based gate's meaning changed.** Before #1593 a diff meant "the port
  disagrees with an independent implementation"; now it means "this version
  changed behaviour versus the last release". Both are useful; they are not the
  same assertion, and an intentional improvement can redden a gate that used to
  stay green for that reason. The gates need a way to record an accepted,
  reviewed difference.
- **`selfhost-diffiropt.sh` and `selfhost-diffir.sh` no longer carry a waiver
  list.** They used to tolerate two known cosmetic monomorph instance-ordering
  differences between the seed and the self-hosted output; those waivers became
  meaningless once the seed was gone, and #1883 deleted the list along with its
  reader. No mismatch is permitted now.

## 5. What checks the compiler that compiles the compiler

**(a) The current fact.** Every `selfhost-diff*.sh` gate in §4 compares this
tree against the pinned stage0 — release N-1 of this same compiler. Stage0 is
not an independent implementation; it is an earlier build of the same source
lineage, produced by the same compiler design. It therefore shares every bug
the current tree already has. When both sides agree, the gate reports MATCH
whether they agree because they are both right or because they are both wrong
in the same way — a bug present in N-1 and carried into N is structurally
invisible to a comparison between them. This is not hypothetical: #1857's
`parseFloat` had no hex-float branch, so every `0x1p-1` literal silently
became `0.0` and shipped in every release for months. All fifteen
differentials active at the time were green throughout, because the bug was
already in stage0 by the time it was in the tree being checked. It was found
only by comparing Bit's output against a C compiler on the same program — an
oracle entirely outside the stage0-vs-tree chain.

**(b) The candidates.**

| candidate | catches a bug both compilers share | needs a second implementation | cost to keep alive |
|---|---|---|---|
| 1. Accept and document | No | No | Free — this document |
| 2. Property-based and differential fuzzing (#1907) | Yes, for anything its oracles can express: `-O0` vs `-O1` disagreement, aarch64 vs x86-64 disagreement, a self-checking generated program computing the wrong answer. None of these compare against stage0, so a bug shared with N-1 is not hidden from them | No | Moderate, ongoing: a program generator plus three fuzz modes to build and keep working as the language grows |
| 3. Reproducible builds from a published stage0, double-compiled independently by a third party | No, for a logic bug carried in the shared source — every rebuild starts from the same source and the same stage0 lineage, so it reproduces identically. Yes, for a backdoor injected into a published stage0 binary that has no source-level trace | No — it verifies existing binaries against each other and against source; it writes no second compiler | Real but partial today: `scripts/verify-reproducible-release.sh` was broken for the 0.1.9 and 0.1.10 releases and was fixed in #2500 (`1bf4881f`); it has since been run against v0.1.16 (#3035, the first release cut after that fix) and v0.1.19 (#3206), green on all three targets each time — v0.1.19 first reported a false `CONTENT differs` on all three, traced to a `BIT_STDLIB`-propagation bug in the script itself, not a real divergence in the release, and fixed in the same ticket |
| 4. A small independent reference checker | Yes, for whatever it independently re-derives | Yes — that is what "independent" means here | High and permanent: a second implementation to design, write, and keep in sync with every language change, and one that still never checks codegen |

### Decision

For 1.0: **options 1, 2 and 3, together.** Option 4 is rejected.

- **Accept and document (1).** This document states the trust model as it is,
  not as a differential's MATCH count makes it look. A green
  `selfhost-diff*.sh` run means "this version did not change behaviour versus
  the last release," never "this version is correct."
- **Fuzzing is the bug-finding oracle (2, #1907).** It does not compare
  against stage0 at all, so it is not blind to a bug stage0 and the tree
  share. Its three modes: `-O0` vs `-O1` differential over generated
  programs, aarch64 vs x86-64 differential over the same programs, and
  self-checking generated programs that compute a value and assert it
  themselves. All three find a wrong answer without needing a second
  implementation of the compiler.
- **A reproducible, independently rebuildable stage0 is the trust oracle (3).**
  It answers a different question than fuzzing — not "is the compiler's logic
  correct" but "is the binary I am bootstrapping from the one the published
  source actually produces" — and it is the answer to Thompson's
  trusting-trust attack described in §3: diverse double-compiling at release
  time, by machines the owner does not fully control, is what makes a
  faithfully-self-reproducing backdoor detectable.
- **Option 4 is rejected.** A small independent reference checker is a second
  implementation under a different name: it costs the same ongoing
  maintenance tax as the seed did, permanently, for the life of the language.
  And even a complete one only checks what it re-derives — typing and
  semantics — never codegen, which is where #1857 and the ABI-boundary bugs
  actually live. Ruled out by the owner; the decision here comes from options
  1–3 only.

### What this does not fix

#1859 (closed) added `selfhost-diffruntime.sh`, a differential with its own
corpus (`runtime/**/*.bit`) — the one directory every other §4 differential's
shared corpus excludes. Runtime codegen now participates in a stage0-vs-tree
comparison instead of going unchecked. That narrows the blind spot described
in (a) — a bug like #1857's, confined to `runtime/`, is now at least compared
— but it does not make the oracle independent. `diffruntime` still compares
stage0 (N-1) against this tree (N), the same lineage checking itself, so a
bug both versions already share stays invisible whether or not `runtime/` is
in the walked corpus. #1859 grew what gets compared; only fuzzing (2) and a
genuinely external oracle change what "agreement" is evidence of.

## 6. Other accepted losses from the stage0 decision

The oracle weakness above is the significant loss from re-basing the
differentials onto stage0. Three smaller, unrelated losses came from the same
`seed/`-removal decision (#1593) and are recorded here rather than reopened:

**From-source bootstrap with no prior binary.** Building `bit` now requires a
`bit`. The chain terminates at a published binary rather than at source. A
committed-blob approach would preserve a source-only path at the cost of a
binary in the tree; we do not take it, so this is given up.

**Bootstrapping on an unsupported host.** See §2. Cross-compilation from a
machine that has a working `bit` is the only path.

**Detection of a stage0 that backdoors itself faithfully**, except by diverse
double-compiling at release time (§3). A developer build does not check this.

## What is NOT lost

Worth listing so the losses above are not read as larger than they are:

- `./make test`'s 28 harnesses, the 78-program stress suite, the golden
  corpus, the doc gates and the stdlib-export gate are all self-contained. None
  of them needs the seed.
- The byte-identical fixed point, which is the strongest single statement
  available about a self-hosted compiler.
- Real-hardware verification (`scripts/arm64gate.sh`, `scripts/x64gate.sh`),
  which never involved the seed.
