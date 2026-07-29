#!/usr/bin/env bash
# Runtime codegen differential (#1859): run every `runtime/**/*.bit` through both
# compilers' `--dump-ir-pre` and diff the lowered SSA text.
#
# ## Why this exists
#
# The other fifteen `selfhost-diff*.sh` all walk the same corpus:
#
#     find stdlib examples tests/cases tests/imports -name '*.bit'
#
# `runtime/` is in none of them. The compiler had therefore NEVER been
# differentially tested against the source it compiles into every user binary.
#
# That blind spot has a price tag. #1857: `parseFloat` had no hex-float branch,
# so every `0x…p…` literal became ±0.0. `runtime/root` is the only place in the
# repo that uses hex float literals, so no differential could ever have compared
# the construct. The bug survived the entire self-hosting effort and surfaced
# only when #1593 made the self-hosted compiler build `libbitrt.a` for the first
# time — where it silently zeroed `bit_rt_log`'s whole polynomial and made
# `log(x)` return 0 for every input. The differentials were green throughout.
# They were not wrong; they were asked about a corpus that excluded the code.
#
# ## Why IR text and not object bytes
#
# #1859 proposed object bytes as "the strongest available surface". They are not
# usable here. Measured seed-vs-selfhost, every module differs and the
# self-hosted output is consistently larger (root 147941 vs 171069, gc 50661 vs
# 57173, sched 29813 vs 32309, chan 30736 vs 33856). That is #1851, the backend
# optimiser gap, not a correctness difference. Object bytes only mean something
# between two builds of the SAME implementation.
#
# IR text is the right surface anyway for this bug class: a mis-parsed constant
# appears directly in it as `const_float f64 0.5`.
#
# ## Why per-file and not per-module
#
# Not a preference — there is no module-level IR dump for a freestanding module:
#
#     bit build runtime/gc --dump-ir-pre                 -> bit build: NoMain
#     bit build runtime/root --dump-ir-pre --freestanding -> pass --emit-obj
#
# A runtime module has no `main`, and `--freestanding` (the flag that permits
# that) forces object output. Adding `--dump-ir-pre` to the freestanding path is
# a compiler feature, not a script; until then, per-file is the whole surface.
# It happens to cost nothing: the walk below skips zero files.
#
# Usage: ./make selfhost && bash scripts/selfhost-diffruntime.sh
set -uo pipefail

# The oracle is the PINNED STAGE0 (previous release), like every other
# differential since #1593. scripts/stage0.sh downloads and DIGEST-VERIFIES it
# and refuses rather than skipping, so a failure here is loud. It also pins
# BIT_STDLIB to the WORKING TREE for both sides — without that this would diff
# two stdlibs instead of two compilers.
ORACLE="$(sh scripts/stage0.sh)" || exit 2
BIT2=bit-out/bin/bit
GAPS=tests/selfhost-runtime-gaps.txt
TIMEOUT=${DIFFRUNTIME_TIMEOUT:-20}

# A gate whose population can quietly go to zero passes everything. `runtime/`
# holds 85 `.bit` files today and the walk skips none of them, so a floor well
# under that catches a broken find, a moved directory or a compiler that starts
# refusing every file, while leaving room to delete a module.
MIN_FILES=${DIFFRUNTIME_MIN_FILES:-70}

# A count is not coverage. These are the files carrying hex float literals — the
# construct #1857 got wrong — and each MUST be compared, not merely counted. A
# refactor that makes one unparseable in single-file mode would drop it into the
# skip set, leave the totals looking healthy, and silently retire the only
# regression test this gate exists to provide.
REQUIRED="runtime/root/floatslog.bit runtime/root/floatsatan.bit"

for bin in "$ORACLE" "$BIT2"; do
  [ -x "$bin" ] || { echo "diffruntime: missing $bin — run: ./make selfhost" >&2; exit 2; }
done
[ -f "$GAPS" ] || { echo "diffruntime: missing expected-gap list $GAPS" >&2; exit 2; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

match=0 skip=0 total=0
: >"$work/mismatch"
: >"$work/timeout"
: >"$work/compared"

for f in $(find runtime -name '*.bit' | sort); do
  total=$((total + 1))

  a=$("$ORACLE" --dump-ir-pre "$f" 2>/dev/null)
  if [ $? -ne 0 ] || [ -z "$a" ]; then
    # The oracle cannot lower it, so there is no verdict to be had. Counted and
    # reported, never scored as agreement (#1514/#1516).
    skip=$((skip + 1))
    continue
  fi

  b=$(perl -e 'alarm shift; exec @ARGV' "$TIMEOUT" "$BIT2" --dump-ir-pre "$f" 2>/dev/null)
  rc=$?
  # >=128 is death by signal, i.e. the alarm fired or bit crashed. Either way it
  # produced no verdict, so it must not be scored as one.
  if [ "$rc" -ge 128 ]; then
    echo "$f" >>"$work/timeout"
    continue
  fi
  if [ "$rc" -ne 0 ]; then
    # The oracle lowered it and the working tree could not. That is a
    # regression, not a skip.
    echo "$f (bit failed where stage0 succeeded)" >>"$work/mismatch"
    echo "$f" >>"$work/compared"
    continue
  fi

  echo "$f" >>"$work/compared"
  if [ "$a" = "$b" ]; then
    match=$((match + 1))
  else
    echo "$f" >>"$work/mismatch"
  fi
done

bad=0

if [ "$total" -lt "$MIN_FILES" ]; then
  echo "diffruntime: FAIL — walked $total file(s), floor is $MIN_FILES." >&2
  echo "  An empty or shrunken walk passes everything; check the find expression." >&2
  bad=1
fi

for r in $REQUIRED; do
  if ! grep -qxF "$r" "$work/compared"; then
    echo "diffruntime: FAIL — required file '$r' was never compared." >&2
    echo "  It carries hex float literals, the construct #1857 got wrong. Losing" >&2
    echo "  coverage of it is a failure, not a smaller number." >&2
    bad=1
  fi
done

if [ -s "$work/timeout" ]; then
  echo "diffruntime: FAIL — timed out after ${TIMEOUT}s (no verdict, not a match):" >&2
  sed 's/^/  /' "$work/timeout" >&2
  bad=1
fi

# Gate on the SET, not the count (#1469): MATCH could grow while a known gap
# closed and a fresh regression opened in its place, and the two runs would read
# identically.
sort -u "$work/mismatch" >"$work/mismatch.sorted"
grep -vE '^\s*(#|$)' "$GAPS" | sort -u >"$work/gaps.sorted"

entered=$(comm -23 "$work/mismatch.sorted" "$work/gaps.sorted")
left=$(comm -13 "$work/mismatch.sorted" "$work/gaps.sorted")

if [ -n "$entered" ]; then
  echo "diffruntime: FAIL — new mismatch(es), not in $GAPS:" >&2
  echo "$entered" | sed 's/^/  /' >&2
  echo "  Diff one with:  diff <(\"$ORACLE\" --dump-ir-pre FILE) <($BIT2 --dump-ir-pre FILE)" >&2
  bad=1
fi
if [ -n "$left" ]; then
  echo "diffruntime: FAIL — expected mismatch(es) now agree; delete from $GAPS:" >&2
  echo "$left" | sed 's/^/  /' >&2
  bad=1
fi

[ "$bad" -ne 0 ] && exit 1

echo "diffruntime: PASS — $match/$total runtime file(s) lower identically" \
  "($skip skipped, $(wc -l <"$work/gaps.sorted" | tr -d ' ') known gap(s) held)"
