# Bootstrap

**The seed is gone (#1593). [`docs/release/bootstrap.md`](docs/release/bootstrap.md)
is the authority for how Bit builds today.** This file is the short version plus
the history, because the long version it used to contain describes a compiler
that no longer exists and would mislead anyone who found it first.

## How `bit` is built now

`bit` is compiled by **stage0**: the previous release, downloaded and verified
against the digest committed in [`dist/stage0/SHA256SUMS`](dist/stage0/SHA256SUMS).

```
./make        # resolve + verify stage0, build libbitrt.a, compile compiler/ -> bit
```

`scripts/stage0.sh` does the resolving. It reads the artifact name out of the
committed digest file, fetches it once into `bit-out/stage0/`, verifies it
through `dist/stage0-verify.sh`, and refuses on any failure — a build never falls
back to something unverified. Later runs are silent and offline.

Two consequences worth stating plainly:

- **Building `bit` requires a `bit`.** The chain terminates at a published
  binary, not at source. That trade was made deliberately; see
  `docs/release/bootstrap.md` §5.
- **`compiler/` and `runtime/` may only use what the pinned stage0 understands.**
  Both are compiled by it. Needing a newer feature means moving the pin first:
  cut a release, repin `dist/stage0/SHA256SUMS`, then use the feature.

## The fixed point

```
bash scripts/selfhost-fixpoint.sh
```

Builds `compiler/` with `bit`, builds it again with the result, and requires the
two binaries to be byte-identical. This is the proof that matters: `bit` ==
`bit`-built-by-`bit`. It never depended on the seed, which is why it is the one
gate #1593 did not have to re-base.

Compare stages built to the **same basename in different directories**. A Mach-O
ad-hoc signature embeds the binary's own file name, so `-o /tmp/stage2` versus
`-o /tmp/stage3` differ at one byte range for that reason alone and read exactly
like a broken fixed point.

## What the differentials assert now

The fifteen `scripts/selfhost-diff*.sh` compare the working tree against stage0.
Green means **"this version did not change behaviour versus the last release"** —
not "two independent implementations agree", which is what it meant while the
seed existed. Version-over-version comparison cannot catch a bug present in both
N-1 and N. `docs/release/bootstrap.md` §4 lists every gate; §5 records the loss.

Both sides must read **this tree's** stdlib and runtime. The stage0 tarball ships
its own, and `bit` resolves them relative to the binary, so an unpinned oracle
compares two stdlibs instead of two compilers. `scripts/stage0.sh` emits a
wrapper pinning `BIT_STDLIB`; the two examples gates pin `BIT_LIBBITRT`
themselves, since that names one archive per triple.

## Why this is called self-hosted

`bit` compiles its own source to a fixed point: the binary stage 2 produces and
the binary stage 3 produces are byte-identical.

```
stage0  ->  stage1     this tree's compiler, built by the pinned release
stage1  ->  stage2
stage2  ->  stage3     and stage2 == stage3, byte for byte
```

A compiler that reproduces itself exactly when it compiles its own source depends
on nothing but the language — not on whatever built it. That is what "self-hosted"
means, and `scripts/selfhost-fixpoint.sh` checks it on every change.
