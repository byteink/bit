#!/usr/bin/env bash
# Self-host SAFEPOINT differential (#1440): compare the number of STATIC
# `bit_rt_safepoint` call sites the oracle and the self-hosted compiler emit for
# the same source.
#
# WHY THIS EXISTS. Every other selfhost-diff* gate compares diagnostics
# (diffcheck/diffdiags), inferred types (difftypes), lowered or optimized IR
# (diffir/diffiropt), or program OUTPUT (diffexamples/difftests). Safepoints are
# invisible to all of them: they are inserted by codegen from block indices,
# strictly downstream of the post-opt IR the IR differentials compare, and an
# extra one changes no program's output. #1440 was exactly that blind spot — the
# self-hosted compiler emitted a spurious safepoint on the else arm of an
# if/else inside a loop, which cost ~2x the collector work under `BIT_GC=stress`
# while every gate stayed green and every program still printed the right answer.
#
# WHAT A DIVERGENCE MEANS. An EXTRA safepoint is safe (a poll is always legal,
# and the recording side gates on the same predicate so stack maps stay in
# lockstep), and a MISSING one is not — a loop that reaches no safepoint starves
# the collector (ABI.md §5). Either direction is a real codegen divergence and
# neither is acceptable, so this compares for equality.
#
# Both build invocations that feed sites()/exe_collections() are alarm-guarded
# (#2866): neither had a bound before, so a hung ORACLE or BIT2 `build` wedged
# this script indefinitely — the same shape selfhost-diffcheck.sh's header
# warns about ("the seed side had no bound at all, so a hung ORACLE wedged the
# whole gate indefinitely").
#
# PHASE 3 (#3070) is a different kind of check bolted onto this file rather
# than a new one, per that ticket's own constraint: it needs the same
# --emit-obj + relocation-table mechanics phases 1-2 already have, but no
# ORACLE and no diff — it asserts a property of BIT2's own output. See the
# PHASE 3 header below for why.
set -u
# shellcheck source=scripts/alarmrun.sh
. "$(dirname -- "$0")/alarmrun.sh"

# Oracle: the pinned stage0 -- the same compiler one release back, an EARLIER
# VERSION OF THIS SAME COMPILER, which is exactly what limits the claim below.
# scripts/stage0.sh downloads and DIGEST-VERIFIES it, and refuses rather
# than skipping, so a failure here is loud. A green run proves no behaviour
# change versus the last release; it cannot catch a bug present in both —
# docs/release/bootstrap.md §4/§5.
ORACLE="$(sh scripts/stage0.sh)" || exit 2
BIT2=bit-out/bin/bit

# 20s matches this family's single-call convention (diffdump.sh/diffcheck.sh/
# diffverdict.sh/diffdoc.sh); DIFFSAFEPOINTS_TIMEOUT overrides for a slower
# host. Do not go below ~12s on a shared box: #2863's mutation run at a 3s
# bound produced 11 false timeouts from ordinary machine load, redone at
# 12-20s.
TIMEOUT=${DIFFSAFEPOINTS_TIMEOUT:-20}

# --- preconditions, loud ------------------------------------------------------
# A missing tool must ABORT, never silently score every case as "match". Four
# mutation harnesses in this repo have already no-opped exactly that way.
command -v objdump >/dev/null 2>&1 || {
  echo "FATAL: objdump not found — this harness cannot count safepoints without it" >&2
  exit 2
}
[ -x "$ORACLE" ] && [ -x "$BIT2" ] || { echo "FATAL: build both compilers first (./make)" >&2; exit 2; }

sites() { # $1=compiler $2=source $3=objfile -> safepoint count, "x" (did not build), "TIMEOUT" (build hung)
  local rc side
  rm -f "$3"
  alarmrun "$1" build "$2" --emit-obj -o "$3" >/dev/null 2>&1
  rc=$?
  if [ "$rc" -eq 142 ]; then
    [ "$1" = "$ORACLE" ] && side=ORACLE || side=BIT2
    echo "$side timed out after ${TIMEOUT}s building: $2" >&2
    echo TIMEOUT
    return
  fi
  [ -f "$3" ] || { echo x; return; }
  objdump -r "$3" 2>/dev/null | grep -c bit_rt_safepoint
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# --- self-test: prove the counter can actually count --------------------------
# If objdump cannot read our object writer's output, every count comes back 0
# and every case "matches". A loop-bearing program MUST report at least one
# safepoint under both compilers, or this harness is measuring nothing.
cat > "$tmp/selftest.bit" <<'EOF'
fn main() {
  let n = 0
  let i = 0
  while (i < 10) {
    n = n + i
    i = i + 1
  }
  print("${n}\n")
}
EOF
st_seed=$(sites "$ORACLE" "$tmp/selftest.bit" "$tmp/st_seed.o")
st_self=$(sites "$BIT2" "$tmp/selftest.bit" "$tmp/st_self.o")
if [ "$st_seed" = "TIMEOUT" ] || [ "$st_self" = "TIMEOUT" ]; then
  echo "FATAL: self-test build timed out (seed=$st_seed self=$st_self) — the harness cannot proceed." >&2
  exit 2
fi
if [ "$st_seed" = "x" ] || [ "$st_self" = "x" ] || [ "$st_seed" -lt 1 ] || [ "$st_self" -lt 1 ]; then
  echo "FATAL: self-test found no safepoint in a plain loop (seed=$st_seed self=$st_self)." >&2
  echo "       The counter is broken; a green run would be vacuous." >&2
  exit 2
fi
echo "self-test: plain-loop safepoint count — seed=$st_seed self=$st_self"

# --- the differential ---------------------------------------------------------
# A timeout is not evidence, the same reasoning selfhost-diffdump.sh's header
# carries for its own ORACLE/BIT2 timeouts: a build killed by the alarm
# produced no verdict, so it is its own counter, not folded into SKIP (which
# means "declined to build") or MISMATCH (which means "built and disagreed").
match=0 mismatch=0 skip=0 timeout=0
for f in $(find stdlib examples tests/cases tests/stress -name '*.bit' | sort); do
  s=$(sites "$ORACLE" "$f" "$tmp/a.o")
  if [ "$s" = "TIMEOUT" ]; then
    timeout=$((timeout + 1))
    continue
  fi
  [ "$s" = "x" ] && { skip=$((skip + 1)); continue; }
  b=$(sites "$BIT2" "$f" "$tmp/b.o")
  if [ "$b" = "TIMEOUT" ]; then
    timeout=$((timeout + 1))
    continue
  fi
  [ "$b" = "x" ] && { skip=$((skip + 1)); continue; }
  if [ "$s" = "$b" ]; then
    match=$((match + 1))
  else
    mismatch=$((mismatch + 1))
    echo "SAFEPOINT DIVERGENCE  seed=$s self=$b  $f"
  fi
done

echo "safepoint differential: MATCH=$match MISMATCH=$mismatch SKIP(does not build alone)=$skip TIMEOUT=$timeout"

# =============================================================================
# PHASE 2 — the LINKED EXECUTABLE path (#1461)
# =============================================================================
#
# WHY THIS EXISTS. Everything above drives `build --emit-obj`, which in the
# self-hosted compiler is `buildObjCmd`. The path that produces the binaries
# users actually run is a DIFFERENT function, `writeModuleExe`, and it was
# covered by nothing.
#
# That is not a theoretical gap. #1448 is the proof: `optimizeModule` was
# reachable only from `--dump-ir`, so for months every binary the self-hosted
# compiler produced came from raw lowering while every IR differential compared
# optimized dumps. When #1448's agent mutation-tested its own fix, dropping
# `optimizeModule` from `buildObjCmd` was CAUGHT at MISMATCH=81 exactly —
# but dropping it from `writeModuleExe` SURVIVED every gate in the tree, while
# the executable it produced ran 150 collections against the oracle's 100.
#
# WHY NOT COMPARE OUTPUT. That M2 mutant prints the RIGHT answer. It differs
# only in how much collector work it does, so a stdout differential is blind to
# it by construction. This phase compares a measured RUNTIME property instead.
#
# WHAT IS MEASURED. Under `BIT_GC=stress` the collector runs at every safepoint
# poll, and `BIT_GC_STATS=on` prints one line per collection. For a deterministic
# bounded program the collection count is therefore exactly the number of
# safepoints EXECUTED — the same quantity phase 1 counts statically, but observed
# through the linked binary, so it sees the emit path phase 1 cannot reach.
# Counts must be equal: an extra safepoint is legal but wasteful, a missing one
# starves the collector (ABI.md §5), and either is a real codegen divergence.

exe_collections() { # $1=compiler $2=source $3=outbin -> collection count, "x" (did not build/link), "TIMEOUT" (build hung)
  local rc side
  rm -f "$3"
  alarmrun "$1" build "$2" -o "$3" >/dev/null 2>&1
  rc=$?
  if [ "$rc" -eq 142 ]; then
    [ "$1" = "$ORACLE" ] && side=ORACLE || side=BIT2
    echo "$side timed out after ${TIMEOUT}s building: $2" >&2
    echo TIMEOUT
    return
  fi
  [ -x "$3" ] || { echo x; return; }
  BIT_GC=stress BIT_GC_STATS=on "$3" 2>&1 >/dev/null | grep -c gc
}

exe_stdout() { # $1=binary -> its stdout, or "x" if it did not exit 0
  local o
  o=$("$1" 2>/dev/null) || { echo x; return; }
  printf '%s' "$o"
}

# The corpus is written here rather than borrowed from tests/, deliberately:
# every case must LOOP (a straight-line program executes no safepoint and would
# score 0==0 forever), must be bounded and deterministic (the count is the
# assertion), and must be cheap under `BIT_GC=stress`, which collects at every
# back edge. The shapes are the ones safepoint placement has actually got wrong:
# an if/else inside a loop is the exact construct of #1440.
mkdir -p "$tmp/exe"
cat > "$tmp/exe/ifelse_in_loop.bit" <<'EOF'
fn main() {
  let n = 0
  let i = 0
  while (i < 50) {
    if (i > 25) { n = n + i } else { n = n + 1 }
    i = i + 1
  }
  print("${n}\n")
}
EOF
cat > "$tmp/exe/nested_loops.bit" <<'EOF'
fn main() {
  let n = 0
  let i = 0
  while (i < 12) {
    let j = 0
    while (j < 12) {
      n = n + j
      j = j + 1
    }
    i = i + 1
  }
  print("${n}\n")
}
EOF
cat > "$tmp/exe/forof_loop.bit" <<'EOF'
fn main() {
  let xs = [1, 2, 3, 4, 5, 6, 7, 8]
  let n = 0
  for x of xs {
    if (x > 4) { n = n + x } else { n = n - 1 }
  }
  print("${n}\n")
}
EOF
cat > "$tmp/exe/switch_in_loop.bit" <<'EOF'
fn main() {
  let n = 0
  let i = 0
  while (i < 30) {
    switch (i % 3) {
      case 0: n = n + 1
      case 1: n = n + 2
      default: n = n + 3
    }
    i = i + 1
  }
  print("${n}\n")
}
EOF
cat > "$tmp/exe/loop_with_call.bit" <<'EOF'
fn step(x: i64): i64 {
  let r = 0
  let k = 0
  while (k < 3) {
    r = r + x
    k = k + 1
  }
  return r
}
fn main() {
  let n = 0
  let i = 0
  while (i < 20) {
    n = n + step(i)
    i = i + 1
  }
  print("${n}\n")
}
EOF

# --- self-test: prove the RUNTIME counter can actually count ------------------
# If `BIT_GC_STATS` is off, misspelled, or the stress policy stops polling, every
# program reports 0 collections and every case "matches" — the same vacuous-green
# failure the phase-1 self-test exists to prevent, one layer down.
sc_seed=$(exe_collections "$ORACLE" "$tmp/exe/ifelse_in_loop.bit" "$tmp/exe/st_seed")
sc_self=$(exe_collections "$BIT2" "$tmp/exe/ifelse_in_loop.bit" "$tmp/exe/st_self")
if [ "$sc_seed" = "TIMEOUT" ] || [ "$sc_self" = "TIMEOUT" ]; then
  echo "FATAL: self-test build timed out (seed=$sc_seed self=$sc_self) — the harness cannot proceed." >&2
  exit 2
fi
if [ "$sc_seed" = "x" ] || [ "$sc_self" = "x" ]; then
  echo "FATAL: self-test program did not build/link under both compilers (seed=$sc_seed self=$sc_self)." >&2
  exit 2
fi
if [ "$sc_seed" -lt 1 ] || [ "$sc_self" -lt 1 ]; then
  echo "FATAL: self-test observed no collection in a loop under BIT_GC=stress (seed=$sc_seed self=$sc_self)." >&2
  echo "       The runtime counter is not measuring anything; a green run would be vacuous." >&2
  exit 2
fi
echo "self-test: plain-loop collection count under BIT_GC=stress — seed=$sc_seed self=$sc_self"

# A timeout is not evidence, same reasoning as phase 1's own counter above: a
# build killed by the alarm produced no verdict, so it is counted apart from
# SKIP (declined to build) and MISMATCH (built and disagreed).
exe_match=0 exe_mismatch=0 exe_skip=0 exe_timeout=0
for f in "$tmp"/exe/*.bit; do
  name=$(basename "$f")
  sb="$tmp/exe/${name}.seedbin"
  bb="$tmp/exe/${name}.selfbin"
  s=$(exe_collections "$ORACLE" "$f" "$sb")
  if [ "$s" = "TIMEOUT" ]; then
    exe_timeout=$((exe_timeout + 1))
    continue
  fi
  [ "$s" = "x" ] && { echo "EXE SKIP (seed did not build) $name"; exe_skip=$((exe_skip + 1)); continue; }
  b=$(exe_collections "$BIT2" "$f" "$bb")
  if [ "$b" = "TIMEOUT" ]; then
    exe_timeout=$((exe_timeout + 1))
    continue
  fi
  [ "$b" = "x" ] && { echo "EXE SKIP (self did not build) $name"; exe_skip=$((exe_skip + 1)); continue; }

  # Comparing collection counts is only meaningful if the two binaries compute
  # the same thing. A miscompile that changed the ANSWER could otherwise land on
  # a matching count and be scored green.
  os=$(exe_stdout "$sb"); ob=$(exe_stdout "$bb")
  if [ "$os" = "x" ] || [ "$ob" = "x" ] || [ "$os" != "$ob" ]; then
    echo "EXE OUTPUT DIVERGENCE  $name  seed='$os' self='$ob'"
    exe_mismatch=$((exe_mismatch + 1))
    continue
  fi

  if [ "$s" = "$b" ]; then
    exe_match=$((exe_match + 1))
  else
    exe_mismatch=$((exe_mismatch + 1))
    echo "EXE SAFEPOINT DIVERGENCE  seed=$s self=$b  $name"
  fi
done

echo "linked-exe differential: MATCH=$exe_match MISMATCH=$exe_mismatch SKIP=$exe_skip TIMEOUT=$exe_timeout"

# A phase that measured nothing must not pass. If every case skipped, the loop
# above ran zero comparisons and `exe_mismatch` is 0 for the wrong reason.
if [ "$exe_match" -lt 1 ]; then
  echo "FATAL: the linked-exe differential compared nothing (MATCH=$exe_match)." >&2
  exit 2
fi

# =============================================================================
# PHASE 3 — instantiation-target check (#3070)
# =============================================================================
#
# WHY THIS EXISTS. #3068 fixed `resolveCallTarget` (compiler/lowerprim.bit) to
# substitute a generic call's type args through `fc.genEnv` before looking up
# which instantiation it targets. Nothing re-runs the bug once fixed: the
# golden fixture #3068 added for it (tests/cases/run_generic_call_via_param.bit)
# compares stdout, and the degenerate, mistyped instance still computes the
# right VALUE (#2379) — with the fix reverted, `./make test-golden` still
# exits 0, 465/465. Every dump-based differential (diffcheck/diffir/diffiropt/
# difftypes) is also blind, for the reasons #3069 catalogued: they either
# never run the resolver at all, or compare diagnostics/IR text, never which
# instantiation index a call's codegen actually targets.
#
# WHAT IS CHECKED, AND WHY NO ORACLE. Unlike phases 1-2, this needs no second
# compiler: the fixed behaviour is a property of what THIS compiler's own
# resolver+lowerer decide for one fixture, not a diff against last release.
# That makes it immune to the pin-lag every ORACLE-based differential in this
# family carries (see the header note above `ORACLE=`) — #3069 demonstrated
# the exact same object-level divergence by hand (otool -r relocations
# resolved against nm -pa's symbol order); this automates that procedure.
#
# Build the pinned fixture to an object and read its __text relocation table:
# the call site `f1(x)` inside `build`'s body must target the CONCRETE
# instantiation, never the degenerate template instance the checker's
# initial, unsubstituted sweep records.
#
# #3186: `f1`'s body is deliberately two-or-more blocks (a `while` loop) so
# `inlineEligible` (compiler/optinline.bit:63-70, exactly-one-block callees
# only) never splices it away. Before #3163's bounded recursive inliner
# (maxInlineDepth()==2), a single-block `f1` left `build(5)` inlined into
# `main` while `f1$2` still stood as its own call — the premise this header
# used to state. #3163 made that call site inlinable too, so the whole
# `main -> build -> f1` chain folded to a constant and PHASE 3 observed
# nothing (rc=2) in either direction; see #3186's bisection. The loop shape
# is the fix: it survives whatever the inliner's depth bound is.
#
# The degenerate entry's symbol is deterministically `_f1$0` for this exact
# fixture: `checkModule`'s initial sweep records a generic call's
# instantiation the first time it visits that Call node, arena order, once,
# regardless of the bug — and `f1(x)` inside `build`'s body is the first
# generic call in the file (`build(5)` inside `main` is swept second). So
# `_f1$0` is always the raw, unbound-`<T>` ledger entry; the bug is only
# which entry CODEGEN's call instruction is made to target. A `BRANCH`
# relocation naming `_f1$0` in __text is therefore the exact, deterministic
# signature of the reverted bug for this fixture — not a heuristic.
instcheck() { # $1=compiler $2=outobj -> prints verdict; sets $INSTCHECK_RC (0 pass, 1 fail, 2 could-not-decide)
  local fixture="tests/cases/run_generic_call_via_param.bit" calls rc
  rm -f "$2"
  alarmrun "$1" build "$fixture" --emit-obj -o "$2" >/dev/null 2>&1
  rc=$?
  if [ "$rc" -eq 142 ]; then
    echo "instcheck: build timed out after ${TIMEOUT}s: $fixture" >&2
    INSTCHECK_RC=2
    return
  fi
  if [ ! -f "$2" ]; then
    echo "instcheck: $1 did not produce $2 building $fixture (build rc=$rc)" >&2
    INSTCHECK_RC=2
    return
  fi
  calls=$(objdump -r "$2" 2>/dev/null | awk '
    /RELOCATION RECORDS FOR \[__text\]/ { intext=1; next }
    /RELOCATION RECORDS FOR/            { intext=0 }
    intext && /BRANCH/ && $NF ~ /^_f1\$[0-9]+$/ { print $NF }
  ')
  if [ -z "$calls" ]; then
    echo "instcheck: found no call to any f1\$N instance in $fixture's object — the check observed nothing" >&2
    INSTCHECK_RC=2
    return
  fi
  if printf '%s\n' "$calls" | grep -qxF '_f1$0'; then
    echo "INSTANTIATION TARGET DIVERGENCE: main calls the DEGENERATE instance _f1\$0"
    echo "  (resolveCallTarget did not substitute genericTypeArgs through fc.genEnv — #3068)"
    echo "  call target(s) found in __text: $(printf '%s ' $calls)"
    INSTCHECK_RC=1
    return
  fi
  echo "instcheck: main targets the concrete instance ($(printf '%s ' $calls)), not the degenerate _f1\$0"
  INSTCHECK_RC=0
}

echo
instcheck_start=$SECONDS
instcheck "$BIT2" "$tmp/instcheck.o"
instcheck_elapsed=$((SECONDS - instcheck_start))
echo "instantiation-target check: rc=$INSTCHECK_RC (${instcheck_elapsed}s)"
if [ "$INSTCHECK_RC" -eq 2 ]; then
  echo "FATAL: the instantiation-target check could not decide — see above." >&2
  exit 2
fi

[ "$mismatch" -eq 0 ] && [ "$timeout" -eq 0 ] && [ "$exe_mismatch" -eq 0 ] && [ "$exe_timeout" -eq 0 ] &&
  [ "$INSTCHECK_RC" -eq 0 ]
