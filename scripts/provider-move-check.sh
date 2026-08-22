#!/usr/bin/env bash
# provider-move-check.sh (#2549) — prove a runtime "provider move" (hoisting a
# function out of runtime/<mod>/{linux,darwin}/*.bit into the shared core
# runtime/<mod>/<mod>.bit, the refactor #2551-#2554 do) changed nothing a
# program can observe.
#
# Usage: bash scripts/provider-move-check.sh <root|net|thread|park>
#
# Step 1: BASE = `git merge-base HEAD main` — the commit the branch forked
#         from, reconstructed via `git archive` into scratch so cross-module
#         imports (root imports `../sched`, `../gc`, `../alloc`; picking those
#         apart by hand would silently drift as the import graph changes)
#         resolve exactly as they do for the working tree.
# Step 2: for the module's core directory plus its linux/ and darwin/
#         provider directories, `--emit-obj` each one at BASE and at the
#         working tree, for every (directory, target) pair
#         scripts/g2archive.sh's own PLATFORM_PAIRS list builds this module
#         for: core is compiled once per target (ISA differs even though the
#         source is platform-free), each provider only for the target(s) that
#         actually link it.
# Step 3: `cmp` each BASE/working-tree pair; print PASS/FAIL per pair.
# Step 4: line-multiset check — concatenate the module's core files plus both
#         provider directories, sort with a forced C locale, and `cmp` BASE
#         against the working tree; this is the check that tolerates an
#         actual cross-file move (same lines, different home file) as long as
#         no line was gained or lost.
#
# Every FAIL prints an explanation; the script exits 1 if any check failed,
# 0 if every check passed. Nothing under runtime/ is ever written — BASE's
# source is read with `git archive` into $(mktemp -d), the working tree is
# read in place, and cmp's own scratch objects live in the same mktemp dir.
set -u

usage() {
  echo "usage: bash scripts/provider-move-check.sh <root|net|thread|park>" >&2
  exit 2
}

MODULE=${1:-}
case "$MODULE" in
  root | net | thread | park) ;;
  *) usage ;;
esac

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd) || exit 1
BIT="$REPO_ROOT/bit-out/bin/bit"
if [ ! -x "$BIT" ]; then
  echo "provider-move-check: '$BIT' not found or not executable (build it first: ./make)" >&2
  exit 1
fi

BASE=$(git -C "$REPO_ROOT" merge-base HEAD main) || exit 1
echo "provider-move-check: module=$MODULE base=$BASE"

SCRATCH=$(mktemp -d) || exit 1
trap 'rm -rf "$SCRATCH"' EXIT

BASE_RT="$SCRATCH/base/runtime"
mkdir -p "$SCRATCH/base"
if ! (cd "$REPO_ROOT" && git archive "$BASE" -- runtime) | tar -x -C "$SCRATCH/base"; then
  echo "provider-move-check: failed to reconstruct runtime/ at $BASE" >&2
  exit 1
fi
WORK_RT="$REPO_ROOT/runtime"

# --- Step 2/3 data table: (relative provider dir, "-" for the core dir
# itself) paired with every target that dir is actually built for, matching
# scripts/g2archive.sh's PLATFORM_PAIRS entries for this module. ---
PAIR_RELS=(- - - linux linux darwin)
PAIR_TARGETS=(x86_64-linux aarch64-linux aarch64-macos x86_64-linux aarch64-linux aarch64-macos)

FAIL=0
CMP_FAIL=0
i=0
while [ "$i" -lt "${#PAIR_RELS[@]}" ]; do
  rel=${PAIR_RELS[$i]}
  target=${PAIR_TARGETS[$i]}
  i=$((i + 1))
  if [ "$rel" = "-" ]; then
    base_dir="$BASE_RT/$MODULE"
    work_dir="$WORK_RT/$MODULE"
    label="$MODULE"
  else
    base_dir="$BASE_RT/$MODULE/$rel"
    work_dir="$WORK_RT/$MODULE/$rel"
    label="$MODULE/$rel"
  fi
  tag="${label//\//_}_${target}"

  if [ ! -d "$base_dir" ] || [ ! -d "$work_dir" ]; then
    echo "FAIL cmp $label @ $target (directory missing: base=$base_dir work=$work_dir)"
    FAIL=1
    CMP_FAIL=1
    continue
  fi

  base_obj="$SCRATCH/${tag}_base.o"
  work_obj="$SCRATCH/${tag}_work.o"
  base_err="$SCRATCH/${tag}_base.err"
  work_err="$SCRATCH/${tag}_work.err"

  "$BIT" build "$base_dir" --emit-obj --freestanding --target "$target" -o "$base_obj" >"$base_err" 2>&1
  base_rc=$?
  "$BIT" build "$work_dir" --emit-obj --freestanding --target "$target" -o "$work_obj" >"$work_err" 2>&1
  work_rc=$?

  if [ "$base_rc" -ne 0 ] || [ "$work_rc" -ne 0 ]; then
    echo "FAIL cmp $label @ $target (build failed: base_rc=$base_rc work_rc=$work_rc)"
    [ "$base_rc" -ne 0 ] && sed 's/^/  base: /' "$base_err" >&2
    [ "$work_rc" -ne 0 ] && sed 's/^/  work: /' "$work_err" >&2
    FAIL=1
    CMP_FAIL=1
    continue
  fi

  if cmp -s "$base_obj" "$work_obj"; then
    echo "PASS cmp $label @ $target"
  else
    echo "FAIL cmp $label @ $target ($(cmp "$base_obj" "$work_obj" 2>&1))"
    FAIL=1
    CMP_FAIL=1
  fi
done

# --- Step 4: line-multiset over the core dir plus both providers. ---
base_lines="$SCRATCH/${MODULE}_base_lines.txt"
work_lines="$SCRATCH/${MODULE}_work_lines.txt"
: >"$base_lines"
: >"$work_lines"
for rel in "" linux darwin; do
  if [ -z "$rel" ]; then
    bdir="$BASE_RT/$MODULE"
    wdir="$WORK_RT/$MODULE"
  else
    bdir="$BASE_RT/$MODULE/$rel"
    wdir="$WORK_RT/$MODULE/$rel"
  fi
  [ -d "$bdir" ] && find "$bdir" -maxdepth 1 -name '*.bit' -exec cat {} + >>"$base_lines"
  [ -d "$wdir" ] && find "$wdir" -maxdepth 1 -name '*.bit' -exec cat {} + >>"$work_lines"
done

base_sorted="$SCRATCH/${MODULE}_base_sorted.txt"
work_sorted="$SCRATCH/${MODULE}_work_sorted.txt"
LC_ALL=C sort "$base_lines" >"$base_sorted"
LC_ALL=C sort "$work_lines" >"$work_sorted"

MULTISET_PASS=1
if cmp -s "$base_sorted" "$work_sorted"; then
  echo "PASS line-multiset $MODULE"
else
  echo "FAIL line-multiset $MODULE"
  FAIL=1
  MULTISET_PASS=0
fi

# A cmp FAIL here does not by itself mean content changed: this compiler lays
# functions out in source-declaration order (verified #2549 by disassembling
# both sides of a pure reposition — the actual instructions were identical,
# only their file offsets moved), so ANY reordering, including a legitimate
# provider hoist, changes these raw object bytes. line-multiset is the
# authoritative "no content was gained or lost" signal; read a cmp FAIL
# alongside a line-multiset PASS as "repositioned, not changed".
if [ "$CMP_FAIL" -eq 1 ] && [ "$MULTISET_PASS" -eq 1 ]; then
  echo "NOTE: cmp FAILed but line-multiset PASSed — the object's raw bytes" >&2
  echo "  moved (declaration order shifted where code sits in the section)," >&2
  echo "  but no source line was gained or lost. See this script's header." >&2
fi

exit "$FAIL"
