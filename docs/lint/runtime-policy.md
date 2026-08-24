# Lint remediation policy: `runtime/`

#2567. This is the policy for every `bit lint runtime` finding **except
E0211** `unused-local` (already fixed and gated: #2515,
`tests/bit/lintruntime.bit`, `test-lint-runtime`) and **except E0214**
`append-aliasing` (a correctness rule with its own settled per-instance
triage elsewhere in this repo, out of scope for a readability-policy
document).

**`runtime/` is not `compiler/`/`stdlib/`, and this policy is not a copy of
[docs/lint/policy.md](policy.md).** That document's defaults are "fix, or
raise per-function for a proven-flat function." Here the population is
structurally different: the overwhelming majority of findings sit on
`@nosplit` functions, `@symbol("bit_rt_port_...")` C-ABI boundary shims,
freestanding boot entrypoints (`boot()`, `workerBody()`,
`mapGuardedStack()`), raw syscall/`asm` wrappers, or direct ports of
published numerical algorithms (Dragon4 float formatting, fdlibm-style
`pow`/`atan`). None of those can be safety-verified by a clean build — this
is the tree where `root.bit` refuses to boot unless `gcWords == 37`
(`runtime/root/**`) and a passing compile says nothing about whether the
result still boots on darwin/linux/windows. So the default here is reversed:
**override is the norm, fix is the exception**, and every fix decision below
is scoped to code with no ABI/nosplit/boot constraint, verified by an actual
`bit check` (and, where it touches `runtime/root/**` or scheduler
concurrency, an actual program run — never claimed here without one).

## How to read this document

Same mechanics as `policy.md` — restated because they are easy to get wrong
and this ticket exists partly because they were:

1. `bit lint` writes every finding to **stderr**. Always `2>&1`.
2. The denominator is `bit lint`'s own printed `lint: N findings, M overrides
   active` line, never a count reconstructed by subtraction or `grep -c` on
   an unredirected stream.

```sh
export BIT_STDLIB="$PWD/stdlib"
LOG=$(mktemp)
./bit-out/bin/bit lint runtime > "$LOG" 2>&1
tail -1 "$LOG"                                   # lint: N findings, M overrides active
grep -oE '^(warning|error)\[E[0-9]+\]' "$LOG" | sort | uniq -c
```

## Counts this policy was written against

Re-derived this session (the ticket's own "63" is stale — see below), branch
`task-2567-runtime-lint-policy`, worktree built via `./make selfhost`. One
override already exists in the tree
(`runtime/cryptohw/cryptohw.bit:48`, `max-params=7`, landed separately for
`bit_rt_crypto_ghash_mul_hw`'s fixed hardware-AES arity — pre-existing, not
part of this policy's scope, shown here only because it changes the "1
overrides active" denominator).

| rule | before this session | after this session's one fix | decision |
|---|--:|--:|---|
| E0200 `max-file-lines` | 0 | 0 | n/a — see note below |
| E0201 `max-fn-lines` | 18 | 18 | override, per-function |
| E0202 `max-params` | 18 | 18 | override (14) / fix (4) — see split below |
| E0203 `max-nesting` | 7 | 7 | override, per-function |
| E0204 `max-complexity` | 41 | 41 | override, per-function |
| E0210 `unused-import` | 1 | 0 | fix — done this session |
| E0212 `unreachable-code` | 0 | 0 | n/a — see note below |
| E0215 `unused-result` | 30 | 30 | **out of scope — filed separately, see below** |

In-scope total (the 7 codes named in this ticket's acceptance):
**85 → 84** findings after the one E0210 fix (`grep -cE
'\[(E0200|E0201|E0202|E0203|E0204|E0210|E0212)\]'` against a fresh
`bit lint runtime 2>&1` log — matches 0+18+18+7+41+0+0). The linter's own
overall total (all 8 codes it reports here, including out-of-scope E0215)
moved **115 → 114** over the same fix, printed as `lint: 114 findings, 1
overrides active` — the "1 overrides active" is the pre-existing
`cryptohw.bit` override, unrelated to this ticket.

**The ticket's "63" was measured 2026-08-08 and has drifted upward, not
down, despite #2515's E0211 work and heavy runtime/ churn since (#3340
Windows sockets, #3592 safepoint shim, #2613 stack sizes, #3595 `@nosplit`
annotations) — re-derive, never quote.** Two rule codes the original ticket
counted (E0200: 3, E0212: 1) are now **zero** — already cleared by unrelated
work (E0200 is also independently gated: `test-lint-filelines` covers
`runtime/` as one of its seven scanned trees per the corrected note in this
workspace's `CLAUDE.md`, so a regression there is already caught without
this ticket adding anything). One new rule code, **E0215
`unused-result`, did not exist when this ticket was filed** (#2117 landed
after) and now accounts for 30 findings — see "Out of scope" below for why
it is not dispositioned here.

## Out of scope: E0215 `unused-result` (30 findings) — filed as its own ticket

**This is not a readability rule and does not belong in this document's risk
class.** `spec/LINT.md:233` describes it as "the one case E0211 cannot see
because nothing was ever named" — i.e. it is E0211's sibling in the
discarded-result family, which already has its own gate
(`test-lint-runtime`) and its own settled fix pattern (`let _ = ...`,
#2515). The 7 codes this ticket's acceptance names (E0200/201/202/203/204/
210/212) are explicitly the readability class the original ticket text
distinguishes from "the discarded-result class E0211 is." Bundling 30
E0215 sites into this document would guarantee exactly what #2515's own
constraint warns against: reviewing a correctness-adjacent class alongside
a purely cosmetic one so the correctness-adjacent ones get skimmed. Filed as
a new ticket to re-derive and disposition E0215 in `runtime/` on its own,
using #2515's `let _ = ...` pattern plus the fallible-result carve-out
`docs/lint/policy.md`'s own E0215 section already states (route a
discarded `T!`/`Option`/`Result` to whoever owns that call site's
correctness, never rubber-stamp it).

## E0200 `max-file-lines` — NO FINDINGS, NO ACTION

Zero in `runtime/` today. No file in `runtime/` needs a decision. This rule
is also already gated for `runtime/` independent of this ticket —
`test-lint-filelines` (`tests/bit/lintfilelines.bit`) scans seven trees
including `runtime/`, so a future regression here is caught without any new
gate. Nothing to add.

## E0212 `unreachable-code` — NO FINDINGS TODAY; POLICY FOR IF ONE APPEARS: FIX, NO OVERRIDE

Zero in `runtime/` today. `docs/lint/policy.md`'s own E0212 section
(`#3211`) established, empirically rather than by argument, that this rule's
findings in this codebase are always real dead code, never a checker-gap
false positive, because `lintUnreachableCode` reuses the exact same
`vDiverges` predicate `bit check` itself uses — the two consumers can never
disagree. That evidence is about the shared analysis, not about which
directory is linted, so it applies to `runtime/` identically. If a finding
appears here: delete the statement, verify with `bit check` on the
containing module (exit 0, no new diagnostics). No `allow` path — same as
`compiler/`/`stdlib/`.

## E0210 `unused-import` — FIX (done this session)

**Decision: fix**, same reasoning as `docs/lint/policy.md`'s E0210 section —
a dead import misleads the next reader about a module's dependencies, and
the rule has no raise/override path at all (it is boolean, and the
convention this codebase uses for "keep an import for a side effect only" is
`as _`, not suppression).

**The one finding, fixed:** `runtime/stw/stw.bit:255` imported
`worldEnsureSelf` from `../gc` alongside `maxMutators` (which **is** used,
five times in the same file); `worldEnsureSelf` itself was never referenced
— only the distinct `worldEnsureSelfOn` (line 254, a separate import,
genuinely used per the comment at line 374) was. Removed `worldEnsureSelf`
from the import list, kept `maxMutators`.

Verified: `bit check runtime/stw` exit 0 before and after; `bit check
runtime` (whole tree) exit 0; `bit lint runtime/stw 2>&1` dropped from 4
findings to 3, with the E0210 line gone and the remaining 3
(E0201/E0202/E0204, all on `stwPollOn` — an `@nosplit @symbol` port
function) unaffected, exactly as expected for an import-only edit.

## E0201 `max-fn-lines` (18) — OVERRIDE, per-function

**Decision: override, no fix path exercised.** Every one of the 18 sites is
one of four boundary-constrained shapes, verified by reading each
signature, not inferred from rule code alone:

| shape | example sites |
|---|---|
| freestanding boot entrypoint (`boot()`, `workerBody()`) | `runtime/root/{darwin,linux,windows}/boot{,tail,worker}.bit` |
| `@nosplit` low-level primitive (stack scan, chan select, syscall shim) | `runtime/gc/{gcindex,stackmap}.bit`, `runtime/chan/chanselect.bit`, `runtime/root/windows/os.bit:368` (`winSplitArgs`) |
| `@symbol("bit_rt_port_...")` C-ABI boundary shim | `runtime/net/{darwin,linux}/tcp.bit:112` (`netDialTcp`), `runtime/thread/linux/tls.bit:299` (`tlsPrepare`), `runtime/stw/stwpoll.bit:230` (`stwPollOn`) |
| direct numerical-algorithm port | `runtime/root/floatfmt.bit:66` (`dragon4`), `runtime/root/floatparse.bit:78,339` (`parseBits`/`parseHexBits`), `runtime/root/floatspow.bit:163` (`rtPow`) |

The one apparent outlier, `runtime/sched/workerrun.bit:104`
(`schedWorkerStep`), is not actually a fifth shape: its own doc comment
states it was already extracted out of `schedWorkerRun` specifically so two
call sites share one body rather than drifting copies — i.e. it is already
at the minimum size a shared, sequential state-transition step can be
without re-duplicating logic between its two callers. Forcing it smaller
would recreate the drift risk it was written to prevent.

**Why override, not fix, for all 18:** shrinking a freestanding
boot-entrypoint or a `@nosplit` primitive by extracting a helper is not
provably safe from a green build — it needs the resulting binary to
actually boot on darwin/linux/windows, and `runtime/root/**` changes are on
this project's mandatory-full-suite list for exactly that reason. That
verification is real work belonging to a dedicated execution ticket per
site (or per small cluster), not to a decision ticket. The numeric-algorithm
ports (`dragon4`, `parseHexBits`, `rtPow`, …) carry a second, independent
reason: their branch structure mirrors the published algorithm's own
variable names and case structure, so an arbitrary split risks a silent
ULP-level correctness change with no existing gate that would catch it.

**Follow-up:** #2450-equivalent execution ticket, one per file or small
cluster, each override reason naming the specific shape (boot entrypoint /
nosplit primitive / ABI shim / algorithm port) and the exact symbol.

**Test:**
```sh
grep -c '^warning\[E0201\]' "$LOG"   # target: 0, all via override directives
```

## E0202 `max-params` (18) — SPLIT: OVERRIDE (14) for ABI/syscall boundaries, FIX (4) for the internal worker-launch cluster

**Decision: override for 14, fix for 4 — this is the one rule code where
runtime/'s population is NOT uniform**, and collapsing it to one policy
either over-fixes boundary code or leaves a real, DRY-able smell unaddressed.

**Override (14) — every one is a C-ABI/`@nosplit`/raw-syscall boundary
where the parameter list is not this codebase's to shorten:**

- `runtime/gc/gc.bit:233,312,571` (`gcInit`, `gcBindMemory`, `gcConfigure`)
  — `@nosplit @symbol("bit_rt_port_gc_*")`; every parameter is a distinct
  piece of the fixed port-init contract the C caller passes.
- `runtime/net/{darwin,linux,windows}/udp.bit` (`netSendTo`, 3 sites) and
  `runtime/root/{darwin,linux}/io.bit` (`writeConstLine`) and
  `runtime/root/root.bit:321` (`writeInfo`) and
  `runtime/root/windows/io.bit` (equivalent) — `@symbol`/`@nosplit`
  boot-console or socket-send shims; each parameter is one packed word of a
  fixed-shape wire record or log line.
- `runtime/root/floatfmt.bit:66,212` (`dragon4`, `highTest`) — bignum
  digit-array arithmetic from the Dragon4 algorithm; each param is a
  `(buffer, length)` pair for one of several independent big-number
  operands, matching the published algorithm's own variable names.
- `runtime/stw/stw.bit:758` (`stwCollect`) — `@nosplit`, one parameter per
  subsystem handle (`g`, `world`, `selfSlot`, `snap`, `sched`, `chanReg`)
  the collector pass needs; grouping into a struct here just moves the same
  six fields behind one more level of indirection in `@nosplit` code, where
  indirection is the thing to avoid, not add.
- `runtime/thread/linux/spawn.bit:292` (`cloneChild`) — the function's own
  comment documents that its parameters map 1:1 onto specific registers
  consumed by the inline `asm` block implementing the raw `clone`/`clone3`
  syscall; a struct would require marshalling before the `asm`, defeating
  the point of a hand-encoded shim.

**Fix (4) — the internal worker-launch cluster, no ABI/nosplit constraint:**

- `runtime/sched/grow.bit:176` (`schedMaybeGrow`)
- `runtime/sched/worker.bit:245` (`schedStartWorker`)
- `runtime/thread/threadpool.bit:158,184` (`schedStart`, `schedJoin`)

All four are plain `export fn` — `schedStart`'s own comment states explicitly
*"NOT `@nosplit`: this runs on the boot/parent thread... may allocate and
reach safepoints"* — and three of the four (`schedMaybeGrow`,
`schedStartWorker`, `schedStart`) share the **identical** five-parameter
group `entry: *byte, argArea: *i64, doneArea: *i32, handleArea: *i64,
startFn: (*byte, *byte, *i32) => int` verbatim. This is exactly the rule's
own hint ("group them into a class") applied to code with no external
contract forcing the shape — a `WorkerLaunch{entry, argArea, doneArea,
handleArea, startFn}` struct would cut all three to 2 params
(`s`/`started`, `launch`) and remove a 5-tuple that three call sites already
keep in sync by hand. `schedJoin` shares the `doneArea`/`handleArea` half of
the same group plus its own callback trio; it is included because it is the
same call family, not because its signature is byte-identical to the other
three.

**Why this is a fix ticket and not done here:** worker-launch code is
concurrency-sensitive scheduler internals. A struct-grouping refactor here
needs verification beyond `bit check` — an actual concurrent run
(`test-stress` or the scheduler's own stress fixtures), not just a clean
build, to be trustworthy. That is real, separate work; scope discipline
means it is its own ticket, not a same-session edit to a decision ticket.

**Test:**
```sh
grep -c '^warning\[E0202\]' "$LOG"   # target: 0 (14 via override, 4 via the struct fix)
```

## E0203 `max-nesting` (7) — OVERRIDE, per-function

**Decision: override, no fix path exercised.** All 7 are `@nosplit`
multi-platform syscall-marshalling functions:

- `runtime/gc/stackmap.bit:310` (`scanFrame`)
- `runtime/root/{darwin,linux,windows}/fs.bit` (`sysList`, 3 sites —
  directory listing, one native syscall per platform)
- `runtime/root/{darwin,linux}/os.bit` (`osForkExecWaitBounded`, 2 sites)
- `runtime/root/windows/os.bit:368` (`winSplitArgs`)

Every site's nesting comes from sequential syscall error handling (each OS
call has its own failure branch) inside a `@nosplit` freestanding function —
exactly the shape this ticket's own brief names as a legitimate override
class. Unlike a typical "missing early return," restructuring these without
running the resulting binary on all three platforms (darwin/linux/windows)
to confirm the exec/list/fork path still behaves is out of this decision
ticket's scope and arguably out of any single ticket's scope without
cross-platform hardware. A future ticket MAY revisit any one of these
case-by-case if someone can verify it end-to-end on the specific OS; default
policy until then is override.

**Test:**
```sh
grep -c '^warning\[E0203\]' "$LOG"   # target: 0, all via override directives
```

## E0204 `max-complexity` (41) — OVERRIDE, per-function

**Decision: override, no fix path exercised. This is the cleanest split in
the whole document: sampled all 41 sites by reading each function's
signature, and every single one is `@nosplit`, `@symbol("bit_rt_port_...")`,
a freestanding `boot()`/`workerBody()`/`mapGuardedStack()` entrypoint, or a
numerical-algorithm port** (`dragon4`, `atanInner`/`bit_rt_atan2`,
`powScalbn`/`powExp`/`bit_rt_pow`, `parseBits`/`parseHexBits`). Representative
sites: `runtime/alloc/{alloc,classify}.bit` (heap span reclaim/classify,
`@nosplit @symbol`), `runtime/gc/{gcindex,gcworldsync,stackmap}.bit`,
`runtime/net/{darwin,linux}/tcp.bit` + `runtime/net/net.bit` (DNS/TCP port
shims), the full `runtime/root/{darwin,linux,windows}/boot*.bit` family, and
`runtime/root/floatfmt.bit`/`floatparse.bit`/`floatspow.bit`/`floatsatan.bit`.

Same reasoning as E0201: a `@nosplit`/boot/ABI function's complexity here is
inherent to doing real sequential platform/protocol work in one place where
splitting risks introducing a call site whose safety (nosplit-ness, boot
readiness, ULP-exactness) has not been proven; that proof needs an actual
program run, which belongs to a follow-up execution ticket, not to this
decision.

**Test:**
```sh
grep -c '^warning\[E0204\]' "$LOG"   # target: 0, all via override directives
```

## The constraint this whole document is answerable to

Inherited from #2354/#2567, verbatim: *"Do not silence this with a blanket
suppression or by raising every limit until the count reaches zero — an
override must carry the reason it is safe."* Every override decided above is
per-function or per-small-cluster with a stated, specific reason (a named
`@symbol`, a named `asm`-register mapping, a named algorithm) — never a
blanket "runtime is special" waiver, and the one rule split three ways
(E0202) is split precisely because a uniform disposition would have been
exactly that kind of waiver in one direction.

## Gate extension — not done here, and blocked on #3616

The original ticket's step 2 ("extend the settled count into a gate") is
explicitly deferred, for two reasons stated in this ticket's own dispatch:
first, this ticket's deliverable is the decision, not the mechanical
gate-wiring (`tools/build/lint-ceiling.txt` only supports exactly two scopes
today, `compiler`/`stdlib` — `tests/bit/lintself.bit:224` hard-requires
both lines and no others — so adding `runtime` needs a real code change to
that harness, not a data-file edit); second, **#3616 is concurrently
tightening `tools/build/lint-ceiling.txt` to the measured counts**, so
touching that file or its harness here would race it. Filed as its own
follow-up ticket, to run after #3616 lands.
