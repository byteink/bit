#!/usr/bin/env bash
# Self-host SAFEPOINT differential (#1440): compare the number of STATIC
# `bit_rt_safepoint` call sites the seed and the self-hosted compiler emit for
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
set -u

# The oracle is the PINNED STAGE0 (previous release), not the retired Zig seed
# (#1593). scripts/stage0.sh downloads and DIGEST-VERIFIES it, and refuses rather
# than skipping, so a failure here is loud. What a green run asserts changed with
# it: "unchanged versus the last release", not "two implementations agree" —
# docs/release/bootstrap.md §4/§5.
ORACLE="$(sh scripts/stage0.sh)" || exit 2
BIT2=zig-out/bin/bit

# --- preconditions, loud ------------------------------------------------------
# A missing tool must ABORT, never silently score every case as "match". Four
# mutation harnesses in this repo have already no-opped exactly that way.
command -v objdump >/dev/null 2>&1 || {
  echo "FATAL: objdump not found — this harness cannot count safepoints without it" >&2
  exit 2
}
[ -x "$ORACLE" ] && [ -x "$BIT2" ] || { echo "FATAL: build both compilers first (./make)" >&2; exit 2; }

sites() { # $1=compiler $2=source $3=objfile -> static bit_rt_safepoint call sites, or "x" if it did not build
  rm -f "$3"
  "$1" build "$2" --emit-obj -o "$3" >/dev/null 2>&1
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
function main() {
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
if [ "$st_seed" = "x" ] || [ "$st_self" = "x" ] || [ "$st_seed" -lt 1 ] || [ "$st_self" -lt 1 ]; then
  echo "FATAL: self-test found no safepoint in a plain loop (seed=$st_seed self=$st_self)." >&2
  echo "       The counter is broken; a green run would be vacuous." >&2
  exit 2
fi

# --- the differential ---------------------------------------------------------
match=0 mismatch=0 skip=0
for f in $(find stdlib examples tests/cases tests/stress -name '*.bit' | sort); do
  s=$(sites "$ORACLE" "$f" "$tmp/a.o")
  [ "$s" = "x" ] && { skip=$((skip + 1)); continue; }
  b=$(sites "$BIT2" "$f" "$tmp/b.o")
  [ "$b" = "x" ] && { skip=$((skip + 1)); continue; }
  if [ "$s" = "$b" ]; then
    match=$((match + 1))
  else
    mismatch=$((mismatch + 1))
    echo "SAFEPOINT DIVERGENCE  seed=$s self=$b  $f"
  fi
done

echo "safepoint differential: MATCH=$match MISMATCH=$mismatch SKIP(does not build alone)=$skip"

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
# the executable it produced ran 150 collections against the seed's 100.
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

exe_collections() { # $1=compiler $2=source $3=outbin -> collection count, or "x"
  rm -f "$3"
  "$1" build "$2" -o "$3" >/dev/null 2>&1
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
function main() {
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
function main() {
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
function main() {
  let xs = [1, 2, 3, 4, 5, 6, 7, 8]
  let n = 0
  for x of xs {
    if (x > 4) { n = n + x } else { n = n - 1 }
  }
  print("${n}\n")
}
EOF
cat > "$tmp/exe/switch_in_loop.bit" <<'EOF'
function main() {
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
function step(x: i64): i64 {
  let r = 0
  let k = 0
  while (k < 3) {
    r = r + x
    k = k + 1
  }
  return r
}
function main() {
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
if [ "$sc_seed" = "x" ] || [ "$sc_self" = "x" ]; then
  echo "FATAL: self-test program did not build/link under both compilers (seed=$sc_seed self=$sc_self)." >&2
  exit 2
fi
if [ "$sc_seed" -lt 1 ] || [ "$sc_self" -lt 1 ]; then
  echo "FATAL: self-test observed no collection in a loop under BIT_GC=stress (seed=$sc_seed self=$sc_self)." >&2
  echo "       The runtime counter is not measuring anything; a green run would be vacuous." >&2
  exit 2
fi

exe_match=0 exe_mismatch=0 exe_skip=0
for f in "$tmp"/exe/*.bit; do
  name=$(basename "$f")
  sb="$tmp/exe/${name}.seedbin"
  bb="$tmp/exe/${name}.selfbin"
  s=$(exe_collections "$ORACLE" "$f" "$sb")
  [ "$s" = "x" ] && { echo "EXE SKIP (seed did not build) $name"; exe_skip=$((exe_skip + 1)); continue; }
  b=$(exe_collections "$BIT2" "$f" "$bb")
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

echo "linked-exe differential: MATCH=$exe_match MISMATCH=$exe_mismatch SKIP=$exe_skip"

# A phase that measured nothing must not pass. If every case skipped, the loop
# above ran zero comparisons and `exe_mismatch` is 0 for the wrong reason.
if [ "$exe_match" -lt 1 ]; then
  echo "FATAL: the linked-exe differential compared nothing (MATCH=$exe_match)." >&2
  exit 2
fi

[ "$mismatch" -eq 0 ] && [ "$exe_mismatch" -eq 0 ]
