# Unlanded-work audit (#1800)

Date: 2026-07-26. Base: `main` at `fecd5f3`.

## Why this document exists

No task in the smash graph has ever had "merge to main" as its job. Engineers
commit to a per-task branch (`smash/task-<id>`), the task is marked
`completed` with a commit hash, and the branch is never merged. The result is
a ledger that says 600 tasks are done and a `main` that does not contain all
of their work.

This audit establishes which completed work is actually on `main`, and lands
what is safe to land.

## Method

Three independent checks, because no single one is sufficient:

1. **Hash ancestry.** Every commit hash recorded in a task's record or
   comments, tested with `git merge-base --is-ancestor <hash> main`. Catches
   nothing that was cherry-picked (a cherry-pick makes a new hash), so a
   "NO" here is a lead, not a verdict.
2. **Patch-id equivalence.** `git cherry main <branch>` per branch. Catches
   clean cherry-picks; still reports a false positive for any commit that was
   adapted while landing (context shift or conflict resolution changes the
   patch id).
3. **Content presence — the authority.** For every commit flagged by (1) or
   (2), the set of files it *adds* is compared against `git ls-tree -r main`.
   A commit whose added files do not exist on `main` is definitely not
   landed, whatever its hash says.

Raw output of all three is not committed; it is reproducible from the
commands above.

## What check (1) found, and why it overstates

464 recorded hashes are not ancestors of `main`; 115 completed tasks have no
landed hash at all. Most of that is cherry-pick noise — the std/json epic
(#1717-#1728) shows as 11 unlanded hashes and is fully present on `main`
under new hashes. Check (3) narrows the real set to the tasks listed below.

## Completed tasks with work genuinely missing from main

Disposition `landed` = cherry-picked onto `integration/land-completed` and
merged as part of this audit. 39 commits landed; `scripts/gate.sh --full` ran
on the batch before the merge, and the one commit pair that reddened it
(#1223) was dropped rather than forced through.

| Task | What is missing | Branch | Disposition |
|---|---|---|---|
| #1103 | `seed/link/pe.zig`, `seed/link/pe_reader.zig`, PE32+ linker + tests | `smash/task-1103` | landed |
| #1209 | `stdlib/tls/resume.bit`, TLS session resumption + 0-RTT | `smash/task-1209` | landed (with a `bit fmt` fix on keyschedule.bit the fmt_check gate required) |
| #1223 | `runtime/cpu.zig`, `runtime/cryptohw.zig`, x86-64 AES-NI/SHA-NI | `smash/task-1223` | NOT landed — applies clean but reddens 3 gates (rootabi_membership: 8 symbols with no Bit provider; stdlib_docs: 3 undocumented exports; fmt_check: gcm.bit); follow-up #1811 |
| #1249 | GOMAXPROCS boot, `examples/parallelmap/` | `smash/task-1768` | NOT landed — see #1768 below |
| #1250 | safepoint preemption, `tests/stress/schedpreempt/` | `smash/task-1768` | NOT landed — see #1768 below |
| #1251 | `stdlib/sync/*` (Mutex/RWMutex/WaitGroup/Once/atomics), `docs/stdlib/sync.md` | `smash/task-1251` | NOT landed — conflicts on `spec/SPEC.md`; follow-up #1805 |
| #1252 | M:N memory model in `spec/SPEC.md` + `runtime/ABI.md` | `smash/task-1252` | landed |
| #1255 | h3demux concurrency bump | `smash/task-1255` | landed |
| #1377 | 15 commits: lint rules E0201-E0214, `selfhost/lintunused.bit`, `docs/reference/lint.md`, `// lint` golden mode, LSP lint publish | `smash/task-1377` | NOT landed — separate batch, follow-up #1806 |
| #1560 | imported generic-type instantiation | `smash/task-1560` | landed |
| #1569 | `is_ref` on `bit_rt_slice_append` (both runtimes) | `smash/task-1569` | landed |
| #1623 | E0054 append-on-non-slice | `smash/task-1623` | landed |
| #1688 | hygiene-check zero-commit-branch fix | `smash/task-1688` | landed |
| #1689 | check.bit/lower.bit sibling split | `smash/task-1689` | NOT landed — both files moved substantially on main; the split must be redone, follow-up #1809 |
| #1690 | `x64host.sh --all` | `smash/task-1690` | landed |
| #1700 | stwPoll hot-path inline | `smash/task-1700` | landed |
| #1701 | E00xx select bad-comm rejection | `smash/task-1701` | landed |
| #1707 | x64 `emitPow2DivInt` sign-bias fix | `smash/task-1707` | landed |
| #1708 | narrow-signed constant fold sign-extension | `smash/task-1708` | landed |
| #1713 | `f++` as `const_float` | `smash/task-1713` | NOT landed — conflicts on `selfhost/lower.bit`, follow-up #1807 |
| #1740 | stale `rtGcAlloc` comment | `smash/task-1740` | landed |
| #1751 | release artifact signing/attestation (orphan `4687d8ca`) | orphan | tagged `rescue/task-1751`, not landed |
| #1752 | `dist/sbom.py`, CycloneDX SBOM per release | `smash/task-1752` | landed |
| #1753 | `scripts/verify-reproducible-release.sh` | `smash/task-1753` | landed |
| #1755 | `docs/release/VERSIONING.md`, `DEPRECATION.md`, LTS matrix | `smash/task-1755` | landed |
| #1761 | 256 KiB green-thread stacks, `tests/stress/deeprecursion/` | `smash/task-1761` | landed |
| #1766 | `scripts/selfhost-ir-canon.sh`, IR label canonicalization | `smash/task-1766` | landed |
| #1769 | QUIC deadline / timer-starvation fix | `smash/task-1769` | NOT landed — conflicts on `runtime/root.zig`, follow-up #1808 |
| #361 | `dist/install.ps1`, `.github/workflows/winget.yml` | `smash/task-361` | landed |
| #1768 (#1249+#1250) | GOMAXPROCS boot + safepoint preemption | `smash/task-1768` | NOT landed — applies clean, then `tests/stress/stwcollect` fails under `[selfhost/BIT_GC=stress]`: sub-tests C/D/E/F report `ran=false` with `abandoned=2`/`abandoned=3`. Measured both ways on this batch (red with the 3 commits, `zig build test-stress` EXIT=0 without them). This is #1562's bug — a thread asleep in `parkSleepNs` stalls the rendezvous — so #1768 now depends on #1562 |
| #365 | Stage 3 GATE sign-off docs | `smash/task-365` (locked worktree) | NOT landed — worktree locked, follow-up #1810 |

## Deliberately out of scope

| Task | Why |
|---|---|
| ~~#1734-#1738, #1767~~ | The package-manager CLI. Was out of scope here, then the owner approved landing it on 2026-07-26 — landed separately under #1816, gate green. All six branches kept intact. |
| #1745 | x86_64-macos backend. Task is in `backlog`; owner has not scheduled it. |
| #1583, #1584, #1591, #1562 | The Stage-2 runtime retirement (G2/G3) and its dependencies. Paused by the owner mid-landing; see `.g3-hold/`. Landing these is the G3 epic's job, not this audit's. |

## Orphan commits (unreachable from any ref)

`git fsck --no-reflogs --lost-found` reports 429 dangling commits. All but a
handful are `git stash` entries, `WIP on <branch>` snapshots, and superseded
pre-review versions of commits that later landed under a different subject —
tagging those adds 400+ refs of noise for no recovered work.

Content-checked (added files absent from `main`) and therefore rescued:

| Commit | Task | Subject | Tag |
|---|---|---|---|
| `4687d8ca` | #1751 | ci(release): sign and attest release artifacts | `rescue/task-1751` |
| `8edb3ee0` | dist | feat(dist): add Linux curl\|sh installer (`dist/install.sh`) | `rescue/dist-install-sh` |
| `ba003223` | #1696 | fix(sched): bound timer starvation (`tests/stress/schedtimerstarve/`) | `rescue/task-1696` |
| `0b0a25b7` | #1231 | feat(const): top-level `const []T{}` into .rodata + 3 goldens | `rescue/task-1231` |
| `41049f77` | #1571 | check(selfhost): E0042 per-instantiation methods + goldens | `rescue/task-1571` |
| `5b141cbe` | #1495 | test(selfhost): diffcheck/diffexamples gap pins | `rescue/task-1495` |
| `5c96639a` | #1395 | `tests/buildcmd.zig` | `rescue/task-1395` |
| `b131a7c9` | #366 | `docs/release/BRANCHING.md` | `rescue/task-366` |
| `7d23bf49` | website | pre-#1758 website design (Dockerfile/ssd.yaml) — superseded by the `website/` tree on main | `rescue/website-v1` |

Already tagged before this audit: `rescue/task-1728`.

## The root cause, unfixed

Nothing in this audit stops the next drop. As long as no task owns the merge,
the same divergence rebuilds itself. Two options, neither taken here because
both are process changes rather than repo changes:

- Give every task a merge step in its own acceptance ("the change is an
  ancestor of `main`"), verified by the same `git merge-base --is-ancestor`
  check this audit used.
- Or add a repo-side gate: a scheduled check that fails when a `completed`
  task's recorded commit is not an ancestor of `main`.
