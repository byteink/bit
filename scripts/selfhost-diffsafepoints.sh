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

SEED=zig-out/bin/bit-seed
BIT2=zig-out/bin/bit

# --- preconditions, loud ------------------------------------------------------
# A missing tool must ABORT, never silently score every case as "match". Four
# mutation harnesses in this repo have already no-opped exactly that way.
command -v objdump >/dev/null 2>&1 || {
  echo "FATAL: objdump not found — this harness cannot count safepoints without it" >&2
  exit 2
}
[ -x "$SEED" ] && [ -x "$BIT2" ] || { echo "FATAL: build both compilers first (zig build)" >&2; exit 2; }

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
st_seed=$(sites "$SEED" "$tmp/selftest.bit" "$tmp/st_seed.o")
st_self=$(sites "$BIT2" "$tmp/selftest.bit" "$tmp/st_self.o")
if [ "$st_seed" = "x" ] || [ "$st_self" = "x" ] || [ "$st_seed" -lt 1 ] || [ "$st_self" -lt 1 ]; then
  echo "FATAL: self-test found no safepoint in a plain loop (seed=$st_seed self=$st_self)." >&2
  echo "       The counter is broken; a green run would be vacuous." >&2
  exit 2
fi

# --- the differential ---------------------------------------------------------
match=0 mismatch=0 skip=0
for f in $(find stdlib examples tests/cases tests/stress -name '*.bit' | sort); do
  s=$(sites "$SEED" "$f" "$tmp/a.o")
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
[ "$mismatch" -eq 0 ]
