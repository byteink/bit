# Bootstrap after `seed/` is gone

Status: DECIDED 2026-07-28 (#1840). Implementation is #1593.

`seed/` is the Zig compiler that builds the first `bit`. Deleting it (41,555
lines, the single largest block of Zig in the repo) is what "no Zig" actually
means, and it takes two capabilities with it:

1. the only way to build `bit` from a clean checkout with no `bit` already present
2. the differential oracle that fifteen gates compare the self-hosted compiler against

This document decides both. It is the answer to the question #1589's body
deferred: "no Zig in the repo" and "no Zig to build it" are different claims, and
the owner chose the second on 2026-07-28.

## The decision in one paragraph

Stage0 becomes **the previous release's `bit` binary for the host triple**,
fetched and verified against a digest **committed in this repo**. The
differential gates are re-based from "seed vs self-hosted" to "release N-1 vs
N". Self-consistency is proven by the existing byte-identical fixed point, which
needs no seed and already exists. The capability genuinely lost is the
independent second implementation: a bug present in both N-1 and N becomes
invisible, and that is accepted, mitigated by diverse double-compiling at
release time rather than pretended away.

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
- **Zig** takes the other route: it commits `stage1/zig1.wasm`, a minimal Zig
  compiler as a WebAssembly blob, so only a C compiler is needed.

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

Bit ships **three** targets and no others. There is no Windows build (the
PE/COFF writer landed; the CLI target and the Windows runtime port did not), and
no 32-bit or big-endian target.

On a host outside those three there is no stage0 and **bootstrapping is not
possible on that machine**. That is a deliberate statement, not a gap to be
papered over. The supported path is Go's second option: cross-compile a stage0
from a machine that has one.

```sh
# on a supported host
./bit-out/bin/bit build compiler --target <new-triple> -o bit-<new-triple>
```

The new triple must already be a target the compiler can emit for. A genuinely
new target is a porting job, and porting a self-hosted compiler to a target it
cannot yet emit for requires a working compiler on some host by definition —
that is a property of self-hosting, not of this decision.

**The first release cut after `seed/` is deleted is special and must not be
missed:** `dist/release.sh:102` builds the shipped `bit` by exec'ing
`./bit-out/bin/bit-seed`. With the seed gone that line has no compiler. It must
become the stage0 `bit`, and #1593 has to change it in the same commit that
deletes `seed/`, or the first post-seed release cannot be cut at all.

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

Its own header already states why this is the post-seed property: "once it is
gone there is no stage2 to compare against, so the meaningful property is
self-reproducibility". A stage0 that injects a payload must make that payload
survive into stageB and reproduce itself byte-identically in stageC, which is a
far narrower attack than modifying a compiler.

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

Zig's committed blob has been audited this way in practice: a third party rebuilt
`zig1.wasm` from the last C++-implemented Zig, iterating 45+ times, and got a
byte-identical result, independently reproduced in Guix — the conclusion being
"there is nothing hiding in `zig1.wasm` that hasn't been checked-in as a source
file." That is the standard to aim at, and it is reachable only because the
result is reproducible.

## 4. What each differential gate compares after `seed/` is gone

**#1840 said seven gates. There are fifteen.** The list below is derived from
`scripts/` rather than from the ticket, because an undercount here means gates
silently retired.

Every `selfhost-diff*.sh` today runs `bit-out/bin/bit-seed` against
`bit-out/bin/bit` and diffs the output. The substitution is mechanical: the seed
side becomes the pinned stage0 (release N-1) and the self-hosted side stays.
"Re-based" below means exactly that and nothing more.

| gate | compares | post-seed oracle |
|---|---|---|
| `selfhost-difftokens.sh` | token stream | re-based on N-1 |
| `selfhost-diffast.sh` | AST dump | re-based on N-1 |
| `selfhost-diffcheck.sh` | check verdict | re-based on N-1 |
| `selfhost-diffdiags.sh` | diagnostic text | re-based on N-1 |
| `selfhost-difftypes.sh` | inferred types | re-based on N-1 |
| `selfhost-diffir.sh` | pre-opt IR | re-based on N-1 |
| `selfhost-diffiropt.sh` | post-opt IR | re-based on N-1 |
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

Two consequences to plan for rather than discover:

- **Every re-based gate changes meaning.** Today a diff is "the port disagrees
  with an independent implementation". Afterwards it is "this version changed
  behaviour versus the last release". Both are useful; they are not the same
  assertion, and an intentional improvement will now redden a gate that used to
  stay green. The gates need a way to record an accepted, reviewed difference.
- **`selfhost-diffiropt.sh` and `selfhost-diffir.sh` already tolerate known
  cosmetic differences** (`fixpoint.sh`'s header notes two monomorph
  instance-ordering diffs between seed and `bit2`). Those specific waivers become
  meaningless once the seed is gone and must be DELETED, not carried forward, or
  they will mask a real N-1-to-N regression.

## 5. What is accepted as LOST

Stated plainly, because a decision that only lists what it preserves is not a
decision.

**The independent second implementation.** This is the real loss. The seed is a
compiler written by different code in a different language; agreement between it
and the self-hosted compiler is evidence that both are right. Version-over-
version comparison catches regressions introduced in one version, and cannot
catch a bug present in both N-1 and N. Every shared blind spot becomes permanent
and invisible. Nothing in this decision recovers that, and no amount of
version-over-version diffing substitutes for it.

**From-source bootstrap with no prior binary.** After this, building `bit`
requires a `bit`. The chain terminates at a published binary rather than at
source. Zig's committed-blob approach would preserve a source-only path at the
cost of a binary in the tree; we do not take it, so this is given up.

**Bootstrapping on an unsupported host.** See section 2. Cross-compilation is the
only path.

**Detection of a stage0 that backdoors itself faithfully**, except by diverse
double-compiling at release time. A developer build does not check this.

## What is NOT lost

Worth listing so the losses above are not read as larger than they are:

- `./make test`'s 28 harnesses, the 78-program stress suite, the golden
  corpus, the doc gates and the stdlib-export gate are all self-contained. None
  of them needs the seed.
- The byte-identical fixed point, which is the strongest single statement
  available about a self-hosted compiler.
- Real-hardware verification (`scripts/arm64gate.sh`, `scripts/x64gate.sh`),
  which never involved the seed.
