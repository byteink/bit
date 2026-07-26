# Deprecation Policy

How a feature, flag, or API is retired without breaking users out from under
them. This doc governs the three surfaces from `docs/release/VERSIONING.md`'s
numbered surface list (§1 language, §2 CLI, §3 stdlib) that can lose members
on a MINOR bump pre-1.0 and require a MAJOR bump post-1.0: **language
features**, **CLI flags**, and **stdlib API**. (Runtime
ABI removals are covered by `runtime/ABI.md` directly — the ABI has no
"deprecated but still linkable" state, an old binary either links or it
doesn't.)

## Minimum warning period

**A deprecated item must remain deprecated-but-working for at least one full
LTS cycle before it can be removed**, per the cadence in
`docs/release/SUPPORT.md`'s "Cadence definitions" section. Concretely, using
SUPPORT.md's LTS line numbering:

> If an item is marked deprecated no later than LTS line N's GA, it is
> removable no earlier than LTS line N+1's GA.

The floor is LTS line N's GA, not merely "sometime during N" — a deprecation
that lands mid-cycle, after N has already shipped, does not satisfy the rule
for N; it must wait for N+1 as its baseline instead. This guarantees anyone
who adopts LTS line N at GA sees the deprecation warning for that LTS line's
entire support life (full-support + security-only, 12–60 months per
SUPPORT.md) before upgrading past the release that removes the item — they
are never forced to jump two LTS lines in one upgrade to avoid a silent
break. Deprecating and removing within the same LTS line, or between an LTS
line and the next interim release, is not sufficient; the clock only counts
full LTS-to-LTS spans anchored at each line's GA.

Pre-1.0, there is no LTS line yet (`docs/release/SUPPORT.md`'s pre-1.0
phasing note), so this rule has no floor to enforce until #366 (v1.0) ships
and the first LTS line is designated. Before that point, 0.x deprecations
still carry the compiler warning below as a courtesy, but removal timing is
unconstrained — consistent with 0.x's "MINOR may break" rule in
`VERSIONING.md`.

## Compiler deprecation diagnostic

**`E09xx` is reserved for deprecation warnings** — the next free band after
checker errors (`E0000`–`E0081`) and lint (`E0200`–`E0299`, per
`spec/LINT.md` §3). Individual codes are allocated from `E0900` upward as
deprecations are added, following the lint registry's never-renumber rule:
once assigned, a code is never reused, even after the deprecated item is
removed and the warning retired.

A deprecation diagnostic is a **warning**, not an error — it does not fail
`bit build`, only `bit lint` treats warnings as build-failing (per
`spec/LINT.md` §1), and deprecation is emitted by `bit check`. It must name,
in this order:

1. the deprecated item (fully qualified: `strings.oldSplit`, `bit build
   --legacy-layout`, or the language construct itself)
2. the version it was deprecated in
3. the version it will be removed in (the earliest LTS line per the rule
   above — a concrete version once that line is designated, or "no earlier
   than the next LTS line" pre-designation)
4. the replacement, if one exists (omit this clause only when there is
   truly no replacement, e.g. a feature removed outright for a security
   reason)

Fixed message shape:

```
warning[E0900]: `strings.oldSplit` is deprecated since 1.2.0 and will be
removed no earlier than the 2.0 LTS line; use `strings.split` instead
```

```
warning[E0901]: flag `--legacy-layout` is deprecated since 1.4.0 and will be
removed no earlier than the 2.0 LTS line; there is no replacement, the
legacy layout is being dropped for a memory-safety issue
```

## Surface-specific notes

- **Language features**: a deprecated keyword, operator, or syntax form
  keeps compiling and emits `E09xx` at the use site; removal is a
  MAJOR-bump breaking change per `VERSIONING.md` §1.
- **CLI flags**: a deprecated flag keeps its old behavior and emits `E09xx`
  on every invocation that passes it; removal is a MAJOR-bump breaking
  change per `VERSIONING.md` §2.
- **Stdlib API**: a deprecated exported function/type/constant keeps
  working and emits `E09xx` at each call site during `bit check`; removal
  is a MAJOR-bump breaking change per `VERSIONING.md` §3.
