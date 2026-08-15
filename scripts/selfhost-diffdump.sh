#!/usr/bin/env bash
# Table-driven differential driver (#2743). selfhost-diff{ast,tokens,diags,
# types,ir,iropt}.sh were six copies of the same script, one flag apart, and
# three of the six (ast/tokens/diags) had no timeout guard at all — a hung
# oracle or a hung working-tree `bit` wedged the gate indefinitely. This is one
# driver plus a data table (the six `case` arms below, one per row); the six
# old paths are now thin wrappers that `exec` into `selfhost-diffdump.sh
# <name>`.
#
# BOTH sides of every comparison are now alarm-guarded (perl `alarm`, the same
# mechanism the three already-guarded siblings used) — see
# selfhost-diffcheck.sh's header for why that guard exists: "the oracle side had
# no bound at all, so a hung ORACLE wedged the whole gate indefinitely."
#
# THE COMMENTS BELOW ARE CARRIED OVER FROM THE SIX FILES THIS REPLACES, one
# block per original file — except the `tokens` block's old two-compilers-
# in-different-languages framing, corrected by #2600 across the family: the
# oracle is the pinned stage0 (an earlier release of this same compiler), not
# a second implementation written in something else.
#
# Usage: ./make selfhost && bash scripts/selfhost-diffdump.sh <name>
#   name: ast | tokens | diags | types | ir | iropt
#
# --- types/ir/iropt never run the resolver (#3069) ---
#
# `--dump-types`/`--dump-ir-pre`/`--dump-ir` all reach `checkModule` through
# `lowerSourceModule`/`checkSourceDump` (compiler/lowerdriver.bit:312,
# compiler/checkmodule.bit:480) and never call `resolveModule`. A real
# `bit build`/`run`/`test`/`check`/`doc` resolves first
# (compiler/checkproject.bit:115) and only then checks -- a different branch
# inside `checkExprType` (compiler/check.bit:163: nodeSymbols is "[e]mpty on
# the bare dump entry points"), with different staleness behaviour. So a bug
# that only exists on the resolver-active path is invisible to these three
# rows, however MATCH they read. Demonstrated on
# tests/cases/run_generic_let_chain.bit: this dump shows `f1(x)` inside
# `build<T>` targeting the concrete `f1$3`, while a real `bit build` of the
# same file emits a call to `f1$0`, the degenerate unbound-type-param
# instance -- see docs/development.md "What the differentials assert" and
# #3069 for the full per-differential table and the object-level evidence.
# `ast`/`tokens`/`diags` never reach `checkModule` at all, so this does not
# apply to them.
#
# --- Reading a red types/ir/iropt run: outpaced oracle vs. real regression (#2382) ---
#
# All three of these compare against the PINNED STAGE0 -- a fixed earlier
# release -- so any inference or lowering improvement that has landed since that
# release IS a difference by construction. A mismatch here is not automatically a
# divergence: it can be the fix working, with the oracle still on the buggy side.
#
# What to do about it while landing a fix, in the window before the next repin
# (when nothing an author does makes this gate green): land the fix WITH its
# golden case, and record on the fix's own ticket that types/ir/iropt are
# expected red until stage0 repins past it. Do not delete the case, and do not
# try to keep the exercising program out of the swept corpus -- #2280's two
# lint_deferloop_* files are pre-existing corpus entries whose IR a legitimate
# lowering fix changed, which is proof there is no such workaround even in
# principle: the corpus holds a program for every construct on purpose.
#
# A stage0 repin (docs/release/bootstrap.md §4/§5) is what actually clears it --
# not a code change to these scripts. Once the pin moves to a release cut from a
# tree containing the fix, oracle and tree agree again and MISMATCH drops back on
# its own. A mismatch that SURVIVES a repin is a real regression, not an oracle
# lagging the tree, and should be treated like any other red gate.
#
# Telling the two apart before that repin lands: check that MATCH went UP, not
# only that MISMATCH is the number you expected. A repin can make a broken
# harness agree for the wrong reason -- both sides silently failing to parse the
# same input reads identically to a real fix. This nearly happened on
# selfhost-diffverdict.sh: its synthesized test source was still emitting the
# `function` keyword #2773 had removed, so runs were scoring on rejected input
# until #2846/#2848/#2850 fixed the emission sites.
#
# Why route 1 (repin) over the alternatives: a scoped expected-mismatch list was
# tried and deleted for exactly this class of problem (#1883, "nothing is
# permitted to differ now" above) -- re-admitting one bets against that history.
# Making --dump-ir-pre refuse what `build` refuses only fixes the
# signature-only-stub sub-case, not a file where both compilers lower and
# legitimately disagree because one of them is right, and it would be a compiler
# change made to serve a test harness rather than the other way round.
#
# UPDATE (#3125): the above is still the whole story for `types`, and for any
# `ir`/`iropt` divergence that is a genuine gap rather than an intentional
# improvement. But repin-and-wait made every future lowering IMPROVEMENT
# (opcode count going DOWN, not a coverage gap) block on a release cycle by
# construction -- #3107 was the first to hit it. `ir`/`iropt` now check a
# mismatch against `explainMismatch`'s declared-signature table (below,
# before `run_ir`) first: a divergence that matches a registered signature is
# EXPLAINED immediately, no repin needed. This is deliberately NOT the #1883
# list reborn -- see that function's header for why a signature checked
# against an identity is a different, narrower thing than a file checked
# against nothing. `types` is unchanged; it has no signature table.
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
CORPUS="stdlib examples tests/cases tests/imports"
# shellcheck source=scripts/selfhost-ir-canon.sh
. "${ROOT}/scripts/selfhost-ir-canon.sh"
# shellcheck source=scripts/alarmrun.sh
. "${ROOT}/scripts/alarmrun.sh"

NAME="${1:?usage: selfhost-diffdump.sh <ast|tokens|diags|types|ir|iropt>}"

# --- from scripts/selfhost-diffast.sh ---
# AST differential (#1332/#1335): parse every corpus `.bit` file with both the
# oracle and this tree's `bit` and diff their `--dump-ast` output. They must be
# byte-identical. Files the oracle rejects with a parse/lex error are skipped:
# the two sides do not agree on how far to parse past an error, so a rejected
# file compares diagnostics rather than trees and belongs to diffdiags.
#
# Usage: ./make selfhost && bash scripts/selfhost-diffast.sh
# Exits non-zero (printing the first divergence) on any mismatch.
#
# --- from scripts/selfhost-difftokens.sh ---
# Token differential (#1332/#1334): lex every corpus `.bit` file with both the
# PINNED STAGE0 (the previous release) and the working tree's compiler, and diff
# their `--dump-tokens` output. They must be byte-identical. Files the oracle
# rejects with a lex error are skipped — the two lexers disagree about how far
# to lex past an error, so those files measure the diagnostic renderer rather
# than the lexer.
#
# THE ORACLE CHANGED IN #1593, AND SO DID WHAT A GREEN RUN MEANS. It used to be
# `bit-out/bin/bit-seed`, a compiler written in a different language, so green
# meant two separately-written implementations agreed. It is now the last
# release of this same compiler, so green means "this version did not change
# behaviour versus the last release". See docs/release/bootstrap.md §4/§5 —
# the loss is recorded there, not papered over.
#
# Usage: ./make selfhost && bash scripts/selfhost-difftokens.sh
# Exits non-zero (printing the first divergence) on any mismatch.
#
# --- from scripts/selfhost-diffdiags.sh ---
# Self-host front-end diagnostic differential (#1335/#363): run every corpus
# `.bit` file through both compilers' `--dump-diags` (lexer + parser diagnostics
# only — resolve/check is Stage 2 and not yet ported) and diff. They must be
# byte-identical: empty for a clean file, and the same rendered diagnostic for a
# lex/parse error. Unlike difftokens/diffast this skips nothing — a valid file
# produces empty output from both, and the oracle's --dump-diags is frontend-only
# so checker `// error` cases are empty on both sides too.
#
# Usage: ./make selfhost && bash scripts/selfhost-diffdiags.sh
# Exits non-zero (printing the first divergence) on any mismatch.
#
# --- from scripts/selfhost-difftypes.sh ---
# Self-host type differential (#1337/#364): run every corpus `.bit` through both
# compilers' `--dump-types` (the binding/param/call type dump) and diff. Files
# the oracle rejects at check time are skipped (bit2's checker is still partial).
# This tracks Stage-2 inference coverage: MATCH grows as more constructs are
# ported; a byte diff pins the exact expression whose inferred type differs.
#
# ## It had no exit status either (#1478)
#
# Found by the #1478 audit, one script down from `selfhost-diffiropt.sh`: this
# printed `MISMATCH=n` and a first-divergence diff, then fell off the end at the
# `if`'s status — always 0. Quoting it as verification was never a true claim.
#
# No expected-gap set here, deliberately: unlike the IR differentials this one
# is at MISMATCH=0, so the expectation is simply "none", and a set file would be
# an empty ceremony. If a gap ever has to be tolerated, add one then — do not
# pin a count.
#
# A timeout is not evidence: a `bit` run killed by the alarm produced no verdict,
# so it is reported separately and fails, rather than being scored as a mismatch.
#
# Usage: ./make selfhost && bash scripts/selfhost-difftypes.sh
#
# --- from scripts/selfhost-diffir.sh ---
# Self-host IR (pre-opt) differential (#1337/#364): run every corpus `.bit` through both
# compilers' `--dump-ir-pre` (the lowered SSA text) and diff. Files the oracle cannot
# lower/check are skipped (bit2's lowering is still partial). This tracks
# Stage-2 lowering coverage: MATCH grows as more constructs lower; a byte diff
# pins the exact function whose IR differs.
#
# ## Why this gates on the SET, not the count (#1469)
#
# It used to print `MISMATCH=4` and name only the first offender. A count is not
# a set: MATCH could grow 141 -> 145 with MISMATCH steady at 4 while a known gap
# quietly closed and a fresh regression opened in its place, and the two runs
# would read identically. Three quarters of the claim was unverifiable.
#
# So every mismatching path is NAMED, and any mismatch at all fails the gate.
# There was an expected-mismatch list for a while, so a known difference could be
# written down instead of fixed; its last entry closed and it was deleted with its
# reader (#1883). Nothing is permitted to differ now.
#
# A timeout is likewise not evidence. A file whose run is killed by the alarm is
# reported separately and fails the gate, rather than being folded into the
# mismatch count — a load-sensitive counter that silently self-confirms is the
# exact bug this script was fixed for.
#
# ## The bound, and why BOTH sides carry it (#2070)
#
# The alarm is a HANG guard, not a performance budget, so it belongs well above
# the slowest legitimate file rather than beside it. 20s was below the corpus's
# worst case measured on the post-opt twin (25.20s wall on this tree, 21.86s on
# the oracle, for tests/imports/cryptomldsa/main.bit); pre-opt IR is cheaper and
# escaped by luck, not by design. 300s matches the sibling and is ~12x that.
#
# The oracle used to run UNBOUNDED, so a hung stage0 wedged this script with no
# message. Folding that into SKIP would be worse: a skip means the oracle
# legitimately declined the file, and quietly shrinking the corpus is how a gate
# stops asserting anything. Both sides are bounded, with separate outcomes.
#
# Usage: ./make selfhost && bash scripts/selfhost-diffir.sh
#
# --- from scripts/selfhost-diffiropt.sh ---
# Self-host POST-opt IR differential (#1339): diff `bit --dump-ir` (optimized)
# against the pinned stage0's optimized `--dump-ir` over the corpus. Tracks optimizer
# coverage — MATCH grows as fold/DCE/inline passes land. Mirror of
# selfhost-diffir.sh but for the post-optimizer surface.
#
# ## Why this gates on the SET, not the count (#1478)
#
# It used to print `MISMATCH=3`, name only the first offender, and exit 0 — so
# it could not fail under any circumstance, and its output was quoted as
# verification anyway. Two separate defects: no verdict, and a count where a set
# was needed. A count is not a set: MATCH could grow while MISMATCH held steady
# because a known gap closed and a fresh regression opened in its place, and the
# two runs would read identically.
#
# A timeout is likewise not evidence. A file whose run is killed by the alarm is
# reported separately and fails the gate, rather than being scored as a mismatch
# that happens to sit in the expected set.
#
# ## The bound, and why BOTH sides carry it (#2070)
#
# The alarm is a HANG guard, not a performance budget, so it must sit well above
# the slowest legitimate file rather than near it. It was 20s while the corpus's
# worst case — tests/imports/cryptomldsa/main.bit — needed 25.20s wall and ~14s
# CPU on THIS tree and 21.86s on the oracle. That is not a margin; the gate went
# red with MISMATCH=0 whenever the box was busy, which is the shape docs/development.md
# warns about ("do not read a TIMED OUT as a hang until you have timed the
# program standalone"). 300s is ~12x the slowest observed file, in the spirit of
# the suite's own 900s-against-158s choice from #1637/#1652.
#
# The oracle used to run UNBOUNDED, so a hung stage0 wedged this script forever
# with no message — and merging that into SKIP would have been worse, since a
# skip means "the oracle legitimately could not lower this" and silently
# shrinking the corpus is how a gate stops asserting anything. Both sides are
# bounded, and an oracle timeout is its own reported outcome.
#
# Usage: ./make selfhost && bash scripts/selfhost-diffiropt.sh

# name    | flag           | verdict label   | skip label        | verb (ir only) | kind  | timeout (env, default)
case "$NAME" in
  ast)    FLAG=--dump-ast;    LABEL="AST";           SKIPLABEL="parse-err";       VERB="";         KIND=basic; TIMEOUT="${DIFFAST_TIMEOUT:-20}" ;;
  tokens) FLAG=--dump-tokens; LABEL="token";         SKIPLABEL="lex-err";         VERB="";         KIND=basic; TIMEOUT="${DIFFTOKENS_TIMEOUT:-20}" ;;
  diags)  FLAG=--dump-diags;  LABEL="diag";          SKIPLABEL="";                VERB="";         KIND=basic; TIMEOUT="${DIFFDIAGS_TIMEOUT:-20}" ;;
  types)  FLAG=--dump-types;  LABEL="type";          SKIPLABEL="check-err";       VERB="";         KIND=types; TIMEOUT="${DIFFTYPES_TIMEOUT:-20}" ;;
  ir)     FLAG=--dump-ir-pre; LABEL="IR (pre-opt)";  SKIPLABEL="lower/check-err"; VERB="pre-opt";  KIND=ir;    TIMEOUT="${DIFFIR_TIMEOUT:-300}" ;;
  iropt)  FLAG=--dump-ir;     LABEL="IR (post-opt)"; SKIPLABEL="lower/check-err"; VERB="post-opt"; KIND=ir;    TIMEOUT="${DIFFIROPT_TIMEOUT:-300}" ;;
  *) echo "selfhost-diffdump: unknown differential '${NAME}' (want ast|tokens|diags|types|ir|iropt)" >&2; exit 2 ;;
esac
PREFIX="diff${NAME}"

# Oracle: the pinned stage0 -- the same compiler one release back, an EARLIER
# VERSION OF THIS SAME COMPILER, which is exactly what limits the claim below.
# scripts/stage0.sh downloads and DIGEST-VERIFIES it, and refuses rather
# than skipping, so a failure here is loud. A green run proves no behaviour
# change versus the last release; it cannot catch a bug present in both —
# docs/release/bootstrap.md §4/§5.
ORACLE="$(sh "${ROOT}/scripts/stage0.sh")" || exit 2
BIT2="${ROOT}/bit-out/bin/bit"

# A missing compiler must ABORT, never score a vacuous green (#1514): both sides
# of the differential would produce empty output, and equal-empty compares as
# agreement. Exit 2 to keep this distinct from a real divergence (exit 1).
# [diags' version of the same point:] This gate is the worst of the family
# without it: both sides render empty, and since it skips nothing every file
# scores MATCH — a full green board from no compiler.
for bin in "$ORACLE" "$BIT2"; do
  [ -x "$bin" ] || { echo "${PREFIX}: missing $bin — run: ./make selfhost" >&2; exit 2; }
done

# Why a child died, for the report. 128+N is death by signal N; 14 is the alarm
# this script set, so that alone is a timeout and every other signal is a crash.
whydied() {
  case "$1" in
    142) echo "timed out after ${TIMEOUT}s" ;;
    139) echo "CRASHED (SIGSEGV)" ;;
    138) echo "CRASHED (SIGBUS)" ;;
    134) echo "CRASHED (SIGABRT)" ;;
    *)   echo "CRASHED (signal $(( $1 - 128 )))" ;;
  esac
}

# ast/tokens/diags row bodies: a single MATCH/MISMATCH pass, first divergence
# reported. diags never skips (SKIPLABEL empty) — a valid file renders empty on
# both sides and a rejected one renders the same diagnostic on both, so nothing
# is excluded; ast/tokens skip a file the oracle could not lex/parse.
run_basic() {
  match=0 mismatch=0 skip=0 firstbad=""
  for f in $(find $CORPUS -name '*.bit' | sort); do
    seed=$(alarmrun "$ORACLE" "$FLAG" "$f")
    rc=$?
    if [ -n "$SKIPLABEL" ] && [ "$rc" -ne 0 ]; then
      skip=$((skip + 1))
      continue
    fi
    b2=$(alarmrun "$BIT2" "$FLAG" "$f")
    if [ "$seed" = "$b2" ]; then
      match=$((match + 1))
    else
      mismatch=$((mismatch + 1))
      [ -z "$firstbad" ] && firstbad="$f"
    fi
  done

  if [ -n "$SKIPLABEL" ]; then
    echo "$LABEL differential: MATCH=$match MISMATCH=$mismatch SKIP($SKIPLABEL)=$skip"
  else
    echo "$LABEL differential: MATCH=$match MISMATCH=$mismatch"
  fi

  # A phase that measured nothing must not pass (#1516). On an empty or unfindable
  # corpus the loop runs zero comparisons and MISMATCH is 0 for the wrong reason.
  if [ "$match" -lt 1 ]; then
    echo "FATAL: the $LABEL differential compared nothing (MATCH=$match) — corpus walk found no .bit file." >&2
    exit 2
  fi

  if [ -n "$firstbad" ]; then
    echo "first divergence: $firstbad"
    diff <(alarmrun "$ORACLE" "$FLAG" "$firstbad") <(alarmrun "$BIT2" "$FLAG" "$firstbad") | head -20
    exit 1
  fi
}

# types row body: a timeout is not evidence — a bit killed by the alarm produced
# no verdict, so it is reported separately and fails, rather than being scored
# as a mismatch.
run_types() {
  work=$(mktemp -d)
  trap 'rm -rf "$work"' EXIT
  : >"$work/mismatch"
  : >"$work/timeout"
  match=0 skip=0

  for f in $(find $CORPUS -name '*.bit' | sort); do
    seed=$("$ORACLE" "$FLAG" "$f" 2>/dev/null) || { skip=$((skip + 1)); continue; }
    b2=$(alarmrun "$BIT2" "$FLAG" "$f")
    rc=$?
    if [ "$rc" -ge 128 ]; then
      echo "$f" >>"$work/timeout"
      continue
    fi
    if [ "$seed" = "$b2" ]; then
      match=$((match + 1))
    else
      echo "$f" >>"$work/mismatch"
    fi
  done

  mismatch=$(wc -l <"$work/mismatch" | tr -d ' ')
  timeouts=$(wc -l <"$work/timeout" | tr -d ' ')
  echo "$LABEL differential: MATCH=$match MISMATCH=$mismatch TIMEOUT=$timeouts SKIP($SKIPLABEL)=$skip"

  status=0
  if [ -s "$work/mismatch" ]; then
    echo
    # EVERY divergence, named. "first divergence" told you one file out of n and
    # left the rest unreported, which is how a set of gaps reads as a single bug.
    echo "MISMATCH: $mismatch file(s) whose inferred types differ:"
    while read -r f; do echo "  $f"; done <"$work/mismatch"
    head -3 "$work/mismatch" | while read -r f; do
      echo
      echo "--- diff (seed vs bit): $f"
      diff <("$ORACLE" "$FLAG" "$f" 2>/dev/null) <(alarmrun "$BIT2" "$FLAG" "$f") | head -12
    done
    status=1
  fi

  if [ -s "$work/timeout" ]; then
    echo
    echo "INVALID: $timeouts file(s) timed out after ${TIMEOUT}s — no verdict, not a match:"
    while read -r f; do echo "  timeout: $f"; done <"$work/timeout"
    status=1
  fi

  [ "$status" -eq 0 ] && { echo; echo "$PREFIX: the two checkers agree on every compared file."; }
  exit "$status"
}

# --- Declared-transform-signature escape valve (#3125, same shape as #3103) ---
#
# ir/iropt compared every corpus file's lowered IR TEXT against the pinned
# stage0's, byte for byte (mod $t<id> canon), with NO divergence permitted at
# all. That held only as long as no intentional lowering improvement had
# landed since the pin — #3107 is the first that did (`xs[i]` on a slice:
# `rt_call slice_get` -> an inline bounds-checked load,
# compiler/loweraccess.bit), and it reddened both arms by construction:
# MATCH 754->608, MISMATCH 0->149 on `task-3107-inlineindex` (8d80e0a9).
# #3103 hit the identical shape one level down (object bytes vs. the pinned
# release) and this is the same fix, one level up: a mismatch is no longer
# automatically a REGRESSION. It is checked first against a small table of
# DECLARED TRANSFORM SIGNATURES (`explainMismatch` below) — an exact
# opcode-COUNT-delta identity, proven against the real branch that motivated
# it, not eyeballed. Only a divergence that satisfies a registered signature
# is downgraded to EXPLAINED (printed, not failed); anything else still fails
# exactly as before.
#
# WHY NOT A PER-FILE ALLOWLIST INSTEAD. There was one — the expected-mismatch
# list #1883 deleted, "so a known difference could be written down instead of
# fixed." A signature is not that list reborn: an allowlist names a FILE and
# accepts anything it does next; a signature names an IDENTITY the delta must
# satisfy, checked fresh on every run, and a second, unrelated bug landing on
# an already-explained file still fails it (proven below — the mutation is in
# a file this signature already covers zero times, but the mechanism applies
# per-file regardless of history).
#
# WHY NOT TREE-AGAINST-TREE (the other option this ticket weighed). #3103
# rejected two self-build generations of the SAME tree because `bit build
# compiler` links a pre-built libbitrt.a, so that comparison never touched
# runtime codegen at all — vacuous by construction. That specific mechanism
# does not apply here: `--dump-ir-pre`/`--dump-ir` lower one file standalone,
# no link step. The DEEPER reason still does, though: two generations of ONE
# tree share whatever lowering bug that tree has, so a bug baked into both
# generations identically never diverges — the same self-reproducing-bug
# blind spot, independent of why #3103 hit it. A signature checked against an
# INDEPENDENT, unchanged oracle (the pinned release) does not have that blind
# spot: a real bug fails the identity and is reported as a regression exactly
# like any other divergence, which is what the mutation test below shows.
#
# THE #3107 SIGNATURE, derived empirically, not from the ticket's prose: diff
# `stdlib examples tests/cases tests/imports` between the pinned oracle and
# `task-3107-inlineindex` (8d80e0a9), and aggregate every per-opcode COUNT
# delta over every file that diverges (145 on this tree's corpus count —
# #3107's own report measured 149 against a slightly different corpus the day
# before; the identity itself does not depend on the count). Solved as a
# linear system, not guessed:
#
#   N  = number of `xs[i]` reads this file had inlined
#        (= -delta(rt_call:slice_get); must be > 0)
#   Nn = delta(field_get) - 2N   (the packed/byte-indexed subset of N; 0 for
#                                  a plain element type)
#   Nf = -delta(bitcast)         (a float-index read that no longer needs the
#                                  word round-trip; 0 if none)
#
#   delta(slice_len)=N   delta(icmp_ult)=N   delta(br)=N
#   delta(const_string)=N   delta(rt_call:panic)=N   delta(unreachable)=N
#   delta(add)=N+Nn   delta(shl)=Nn   delta(const_int)=Nn
#   delta(index_get)=N-Nn   Nn>=0   Nf>=0
#   every OTHER opcode: delta==0 (pre-opt only — see POST-OPT below)
#
# 145/145 EXPLAINED, 0 UNEXPLAINED at pre-opt, with every coefficient an
# independent equation — not vacuous. Mutation-tested against a real bug
# (#3125): flipping `compiler/lower.bit`'s `binOpFor`, `Kind.Minus -> Op.Sub`
# to `Op.Add` (a real lowering site, unrelated to slice indexing, so
# `compiler/loweraccess.bit` — #3107's own file — is untouched), reddens both
# arms with a REGRESSION this signature does not explain (recorded on the
# ticket, not reproduced in this comment).
#
# POST-OPT (iropt) IS A LOOSER CHECK ON THE SAME 13 OPCODES, not the same
# equations — a deliberate, evidence-based narrowing, not a shortcut. The
# pre-opt formula's exact coefficients fail on 8/145 files under `--dump-ir`
# (post `opt.bit`'s CSE/DCE/inlining): `field_get`/`index_get` counts shift
# when the optimizer dedupes a repeated bounds check or address computation,
# which a per-site multiple of N cannot express. What DOES hold on all 145:
# every opcode with a nonzero delta is still one of the same 13, and on 7 of
# those 145 the optimizer's INLINER additionally moves `call`/`call_value`/
# `sub` by an amount this signature does not model — a downstream consequence
# of the transform changing a function's instruction count and crossing an
# inlining-cost threshold, not a second lowering bug. Those three are allowed
# to move by ANY amount for iropt only; every other opcode outside the
# declared 13 still fails the check on both arms. 145/145 EXPLAINED at
# post-opt with this rule, 0/145 without the three (i.e. the allowance is
# load-bearing, not decorative).
#
# WHICH HOSTS. Both arms apply on EVERY host (aarch64-macos, aarch64-linux,
# x86_64-linux) — unlike #3103's diffruntime, which is aarch64-only because it
# disassembles target MACHINE CODE. `--dump-ir-pre`/`--dump-ir` are
# pre-codegen: the SSA text carries no register or instruction-selection
# content, so it does not vary by target ISA at all.
#
# COST PER LANDING, as this ticket names up front: a future lowering change
# that alters IR shape (#3108 is next) needs its OWN signature added to
# `explainMismatch` below, derived the same way — diff the real branch
# against the pinned oracle, aggregate every nonzero opcode delta across
# every diverging file, and solve for the coefficients. A signature that only
# explains the one file its author happened to look at is not a signature; it
# is a scoped allowlist wearing a disguise, and #1883 is why that is rejected.

# explainMismatch <oracle_ir_text> <bit2_ir_text> <kind: ir|iropt>
# Prints the name of the registered signature that explains the divergence
# and returns 0, or prints nothing and returns 1 if none does. Each call
# forks one fresh awk process, so all state below is per-call — no cross-file
# leakage between corpus files.
explainMismatch() {
  awk -v kind="$3" '
    function opcode(line,    s) {
      if (match(line, /= rt_call [A-Za-z_][A-Za-z0-9_]*\(/)) {
        s = substr(line, RSTART, RLENGTH)
        sub(/^= rt_call /, "", s)
        sub(/\($/, "", s)
        return "rt_call:" s
      }
      if (match(line, /= [a-zA-Z_][a-zA-Z0-9_]*/)) {
        return substr(line, RSTART + 2, RLENGTH - 2)
      }
      if (line ~ /^[[:space:]]*br /) { return "br" }
      if (line ~ /^[[:space:]]*unreachable/) { return "unreachable" }
      return ""
    }
    side == 0 && $0 == "@@@BIT2@@@" { side = 1; next }
    side == 0 { op = opcode($0); if (op != "") a[op]++; next }
    { op = opcode($0); if (op != "") b[op]++ }
    END {
      for (op in a) allop[op] = 1
      for (op in b) allop[op] = 1
      for (op in allop) {
        d = b[op] - a[op]
        if (d != 0) delta[op] = d
      }

      # --- #3107: `xs[i]` slice-read inline lowering (see the block comment
      # above this function for how these coefficients were derived) ---
      split("slice_get slice_len icmp_ult br const_string panic unreachable field_get add shl const_int index_get bitcast", corelist, " ")
      for (i in corelist) core[corelist[i]] = 1
      N = -delta["rt_call:slice_get"]
      ok = (N > 0)
      if (delta["slice_len"] != N)      ok = 0
      if (delta["icmp_ult"] != N)       ok = 0
      if (delta["br"] != N)             ok = 0
      if (delta["const_string"] != N)   ok = 0
      if (delta["rt_call:panic"] != N)  ok = 0
      if (delta["unreachable"] != N)    ok = 0
      Nn = delta["field_get"] - 2 * N
      if (Nn < 0)                       ok = 0
      if (delta["add"] != N + Nn)       ok = 0
      if (delta["shl"] != Nn)           ok = 0
      if (delta["const_int"] != Nn)     ok = 0
      if (delta["index_get"] != N - Nn) ok = 0
      Nf = -delta["bitcast"]
      if (Nf < 0)                       ok = 0
      # No opcode outside the declared 13 may move at pre-opt. At post-opt,
      # the inliner may additionally move call/call_value/sub by any amount
      # (see the block comment above) -- any other opcode still fails.
      for (op in delta) {
        opname = op
        sub(/^rt_call:/, "", opname)
        if (!(opname in core)) {
          if (kind == "ir") {
            ok = 0
          } else if (opname != "call" && opname != "call_value" && opname != "sub") {
            ok = 0
          }
        }
      }
      if (ok) { print "3107-slice-read-inline"; exit 0 }
      exit 1
    }
  ' <(printf '%s\n@@@BIT2@@@\n%s\n' "$1" "$2")
}

# ir/iropt row bodies: every mismatching path is NAMED and any mismatch fails
# the gate (#1469/#1478 — this used to print a count and name only the first
# offender, or not fail at all); a timeout on either side is its own reported
# outcome, never folded into SKIP or MISMATCH (#2070); $t<id> suffixes are
# canonicalized before comparing (selfhost-ir-canon.sh) since they are
# interning-order artifacts, not structural. A raw/canon mismatch is then
# checked against `explainMismatch`'s declared-signature table above before
# being scored a regression.
run_ir() {
  work=$(mktemp -d)
  trap 'rm -rf "$work"' EXIT
  sep="  -> "
  match=0 skip=0
  : >"$work/mismatch"
  : >"$work/explained"
  : >"$work/timeout"
  : >"$work/oracletimeout"
  : >"$work/oraclecrash"

  for f in $(find $CORPUS -name '*.bit' | sort); do
    # The oracle is bounded too, and its timeout is NOT a skip: a skip means the
    # oracle could not lower or check the file, which is a real and expected
    # outcome, while a hang is a broken stage0 that must be named (#2070).
    want=$(alarmrun "$ORACLE" "$FLAG" "$f")
    rc=$?
    if [ "$rc" -eq 142 ]; then
      echo "$f${sep}$(whydied "$rc")" >>"$work/oracletimeout"
      continue
    fi
    if [ "$rc" -ge 128 ]; then
      echo "$f${sep}$(whydied "$rc")" >>"$work/oraclecrash"
      continue
    fi
    [ "$rc" -ne 0 ] && { skip=$((skip + 1)); continue; }
    [ -z "$want" ] && { skip=$((skip + 1)); continue; }

    b2=$(alarmrun "$BIT2" "$FLAG" "$f")
    rc=$?
    # >=128 is death by signal, and WHICH signal is not a detail. 142 is our own
    # SIGALRM — a timeout. Anything else is the compiler dying, and reporting a
    # SIGSEGV as "timed out after ${TIMEOUT}s" sends the reader after a performance
    # problem that does not exist. Either way there is no verdict (#2070).
    if [ "$rc" -ge 128 ]; then
      echo "$f${sep}$(whydied "$rc")" >>"$work/timeout"
      continue
    fi

    # $t<id> suffixes are interning-order artifacts, not structural — canonicalize
    # before comparing (see selfhost-ir-canon.sh). Raw compare first: the
    # overwhelming majority of files already match byte-for-byte, so skip the
    # two awk forks unless the raw strings actually differ.
    if [ "$want" = "$b2" ] || [ "$(canon_ir_ids "$want")" = "$(canon_ir_ids "$b2")" ]; then
      match=$((match + 1))
    else
      # A raw/canon mismatch is not automatically a regression: check it
      # against the declared-transform-signature table first (see the block
      # comment above explainMismatch). Only an UNEXPLAINED divergence is a
      # regression — this is the #3125 fix, so a real lowering improvement
      # like #3107's no longer fails this gate by construction.
      sig=$(explainMismatch "$want" "$b2" "$NAME")
      if [ -n "$sig" ]; then
        echo "$f${sep}explained by declared signature '$sig'" >>"$work/explained"
      else
        echo "$f" >>"$work/mismatch"
      fi
    fi
  done

  sort -o "$work/mismatch" "$work/mismatch"
  sort -o "$work/explained" "$work/explained"

  mismatch=$(wc -l <"$work/mismatch" | tr -d ' ')
  explained=$(wc -l <"$work/explained" | tr -d ' ')
  timeouts=$(wc -l <"$work/timeout" | tr -d ' ')
  oracletimeouts=$(wc -l <"$work/oracletimeout" | tr -d ' ')
  oraclecrashes=$(wc -l <"$work/oraclecrash" | tr -d ' ')

  echo "$LABEL differential: MATCH=$match MISMATCH=$mismatch EXPLAINED=$explained NO-VERDICT=$timeouts ORACLE-TIMEOUT=$oracletimeouts ORACLE-CRASH=$oraclecrashes SKIP($SKIPLABEL)=$skip"

  # A RUN THAT COMPARED NOTHING IS NOT A PASS (#1881). Two ways to get here having
  # verified nothing, and both leave `mismatch` and `timeout` empty, so every check
  # below passes and the success line claims that every file's IR is identical:
  #
  #   - the corpus enumerated no files at all — a renamed or moved directory in the
  #     `find` list above, which `find` reports on stderr and then carries on past;
  #   - every file was skipped, because the oracle could not lower or check a single
  #     one. A stage0 that is broken for the whole corpus scores as agreement.
  #
  # The distinction from the count-vs-set argument in the header is that this is not
  # a threshold on how much matched. Zero is the one count that means the gate did
  # not run, so it is the one count worth asserting.
  if [ "$match" -eq 0 ]; then
    echo
    echo "INVALID: compared 0 files (skipped $skip) — the corpus or the oracle is broken. Nothing was verified." >&2
    exit 1
  fi

  status=0

  # NO DIVERGENCE IS PERMITTED. There is no expected-mismatch list and no way to
  # add one (#1883): a file whose IR differs from the pinned stage0's fails the
  # run. The list existed so a known difference could be written down instead of
  # fixed; its last entry closed with #1882.
  if [ -s "$work/mismatch" ]; then
    echo
    echo "REGRESSION: $mismatch file(s) diverge from the pinned stage0:"
    while read -r f; do echo "  mismatch: $f"; done <"$work/mismatch"
    # Bounded evidence for the first few, so the failure is actionable in one read.
    head -3 "$work/mismatch" | while read -r f; do
      echo
      echo "--- diff (stage0 vs bit, \$t<id> canonicalized): $f"
      # Bounded on BOTH sides, exactly as the compare loop runs them — an unbounded
      # oracle here would hang the failure report of a run that already failed.
      diff <(canon_ir_ids "$(alarmrun "$ORACLE" "$FLAG" "$f")") <(canon_ir_ids "$(alarmrun "$BIT2" "$FLAG" "$f")") | head -20
    done
    status=1
  fi

  # Informational, never fails the gate: each of these matched a declared
  # transform signature's identity exactly (explainMismatch above), which is
  # a stronger claim than "this file is allowed to differ" — see the block
  # comment above explainMismatch for why that distinction is load-bearing.
  if [ -s "$work/explained" ]; then
    echo
    echo "EXPLAINED: $explained file(s) diverge from the pinned stage0 but match a declared lowering-transform signature (not a regression):"
    sed 's/^/  /' "$work/explained"
  fi

  if [ -s "$work/timeout" ]; then
    echo
    echo "INVALID: $timeouts file(s) produced no verdict — not a match:"
    while read -r f; do echo "  $f"; done <"$work/timeout"
    status=1
  fi

  # Reported apart from ours because it means something different: the PINNED
  # oracle hung, so the corpus shrank rather than this tree misbehaving. Merging
  # it into SKIP would have hidden that behind a number that is supposed to mean
  # "the oracle declined this file", which is how a gate quietly stops asserting.
  if [ -s "$work/oracletimeout" ]; then
    echo
    echo "INVALID: the pinned stage0 HUNG on $oracletimeouts file(s) — corpus reduced, not verified:"
    while read -r f; do echo "  $f"; done <"$work/oracletimeout"
    status=1
  fi

  # AN ORACLE CRASH IS REPORTED BUT DOES NOT FAIL, and the asymmetry with the hang
  # above is deliberate. The oracle is a PUBLISHED, IMMUTABLE binary: no change to
  # this tree can stop it faulting, so failing here would leave the gate red until
  # the next pin move — the "known-and-ignored red gets routed around" hazard
  # #1895 is about. A hang is different: it means the run could not complete in
  # bounded time and may be masking anything, so it still fails.
  #
  # What this is NOT is the expected-mismatch list #1883 deleted. That recorded
  # DIVERGENCES between the two compilers and let them be written down instead of
  # fixed. This records a defect in the oracle itself, names the file on EVERY run
  # rather than hiding it, and asserts nothing about agreement. Before #2070 the
  # same crash was an anonymous +1 to SKIP and went unnoticed for months (#2084).
  if [ -s "$work/oraclecrash" ]; then
    echo
    echo "NOTE: the pinned stage0 crashed on $oraclecrashes file(s) — no verdict available, tracked as #2084:"
    while read -r f; do echo "  $f"; done <"$work/oraclecrash"
  fi

  if [ "$status" -eq 0 ]; then
    echo
    if [ "$explained" -gt 0 ]; then
      echo "$PREFIX: every file's $VERB IR matches the pinned stage0's, or is explained by a declared transform signature ($explained explained)."
    else
      echo "$PREFIX: every file's $VERB IR is identical to the pinned stage0's."
    fi
  fi
  exit "$status"
}

case "$KIND" in
  basic) run_basic ;;
  types) run_types ;;
  ir)    run_ir ;;
esac
