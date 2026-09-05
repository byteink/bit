#!/bin/sh
# objprobe -- cycles per object and collection count for one Bit program.
#
# WHY THIS EXISTS (#3847, epic #2945). Every child of the object-lifecycle epic
# has to prove a per-object win, and before this each one hand-rolled its own
# measurement. Three separate cycles/object figures in this project drifted
# apart that way. This is the one instrument they share, so two children's
# numbers are comparable by construction rather than by coincidence.
#
# WHAT IT REPORTS, AND WHY BOTH.
#   cyc/obj      the WIN signal. Lower is the claim a child is allowed to make.
#   collections  a SAFETY signal, NOT a win signal. #3846 ran the byte-side
#                control this probe's own ticket originally lacked:
#                BIT_GC_MIN_KB 4096 -> 6144 cut collections 210 -> 133, a 37%
#                drop, and bought 0.10% of cycles. `sweep` walks `gcAll` end to
#                end, so sweep work is per-object-ever-allocated and mark work
#                is a small live set times the collection count -- cutting
#                collections cuts the smaller term. So a change that RAISES
#                collections is a regression worth catching, and a change that
#                LOWERS them has not thereby proved anything. Read the column;
#                do not claim a win from it.
#
# THREE ISOLATIONS, NOT ONE NUMBER. A single total/N hides its own startup
# floor, and a single marginal slope hides a nonlinearity. The probe computes
# all three and PRINTS THE DISAGREEMENT. If they do not agree within the bound,
# the instrument is telling you the run was contended or the subject is not
# linear in its argument -- either way the number is not usable, and the probe
# says so instead of printing the one that looks best.
#
# THE DENOMINATOR IS ON EVERY LINE, and it is MEASURED, not assumed: the object
# count comes from `BIT_GC_STATS`' own `swept=` + `live=`, so a subject that
# silently stopped allocating per-object (the #3862 packing path, which is what
# turned bench/cases/alloc into bench/cases/allocflat for a day, #3934) reports
# a collapsed denominator rather than a flattering cyc/obj. A probe that
# examined zero objects would otherwise print a clean-looking zero.
#
# THE INSTRUMENT MUST BE SEEN TO MOVE. `--selftest` runs the 16 -> 64 byte body
# mutation and requires the reported figures to move, because a probe nobody has
# watched move is not known to measure anything. This repo has shipped queries
# that could not match and returned a clean zero (`otool -rv | grep
# ARM64_RELOC_BRANCH26`, which prints `BR26`) and an A/B that compared a
# compiler against itself and read byte-identical output as "no difference".
#
# USAGE
#   bench/objprobe/objprobe.sh [options]
#     -n <count>     objects to construct              (default 10000000)
#     -w <16|48|64>  body width, default subject only  (default 16)
#     -r <runs>      timed runs per point, min taken   (default 9)
#     -s <file.bit>  subject program                   (default subject.bit)
#     -l <label>     label for the RESULT line         (default the subject name)
#     -b <file>      a previous RESULT line to compare against
#     -o <file>      also write the RESULT line here
#     --selftest     run the 16 -> 64 mutation and prove the probe can move
#     --bound <c>    isolation agreement bound, cyc/obj (default 1.0)
#
# SUBJECT CONTRACT. `<subject> <count> [<width>]` constructs a number of heap
# objects proportional to <count>, prints one deterministic line to stdout, and
# accepts <count> 0 (constructing none) -- that zero point is what gives the
# floor-subtracted isolation a floor taken from THIS binary rather than from a
# different program with a different dyld and runtime-init cost.
#
# MEASUREMENT HYGIENE. Cycles come from `/usr/bin/time -l`, the same source
# bench/run.sh uses, with `BIT_GC_STATS` UNSET -- those counters cost a measured
# +5.5% cycles on this exact workload (runtime/ABI.md SS8.2), so the counting run
# and the timed runs are deliberately separate runs. Take the box first:
#   .claude/boxlock.sh solo bench/objprobe/objprobe.sh ...
# and check `ps -eo comm= -A | grep -c make-driver` is 0 before AND after.
set -e

N=10000000
WIDTH=16
RUNS=9
SUBJECT=""
LABEL=""
BASELINE=""
OUTFILE=""
SELFTEST=0
BOUND=1.0
BIT="${BIT:-./bit-out/bin/bit}"

while [ $# -gt 0 ]; do
  case "$1" in
    -n) N="$2"; shift 2 ;;
    -w) WIDTH="$2"; shift 2 ;;
    -r) RUNS="$2"; shift 2 ;;
    -s) SUBJECT="$2"; shift 2 ;;
    -l) LABEL="$2"; shift 2 ;;
    -b) BASELINE="$2"; shift 2 ;;
    -o) OUTFILE="$2"; shift 2 ;;
    --bound) BOUND="$2"; shift 2 ;;
    --selftest) SELFTEST=1; shift ;;
    -h|--help) sed -n '2,70p' "$0"; exit 0 ;;
    *) echo "objprobe: unknown option '$1' (try --help)" >&2; exit 2 ;;
  esac
done

HERE=$(cd "$(dirname "$0")" && pwd)
[ -n "$SUBJECT" ] || SUBJECT="$HERE/subject.bit"
[ -n "$LABEL" ] || LABEL=$(basename "$SUBJECT" .bit)
[ -f "$SUBJECT" ] || { echo "objprobe: no such subject: $SUBJECT" >&2; exit 2; }
[ -x "$BIT" ] || { echo "objprobe: no compiler at $BIT (set BIT=)" >&2; exit 2; }

# Per-run nonce. $TMPDIR is shared by every concurrent agent on this box, and a
# generic scratch name is how one run reads another's output as its own.
WORK="${TMPDIR:-/tmp}/objprobe-$$-$(date +%s)"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT INT TERM

BIN="$WORK/subject"
BIT_STDLIB="${BIT_STDLIB:-stdlib}" "$BIT" build "$SUBJECT" -o "$BIN" >"$WORK/build.log" 2>&1 \
  || { echo "objprobe: build failed:" >&2; cat "$WORK/build.log" >&2; exit 1; }

# One run with the stats counters ON. Echoes "<objects> <collections> <allocbytes>
# <peakbytes> <checksum>". Objects is `swept=` + `live=`: every object this run
# ever constructed, which is the denominator every figure below divides by.
count_run() {
  _out=$(BIT_GC_STATS=1 "$BIN" "$1" "$2" 2>"$WORK/st")
  awk -v chk="$_out" '{for(i=1;i<=NF;i++){
        if($i~/^swept=/)s=substr($i,7); if($i~/^live=/)l=substr($i,6)
        if($i~/^collections=/)c=substr($i,13)
        if($i~/^allocbytes=/)ab=substr($i,12); if($i~/^peakbytes=/)pb=substr($i,11)}}
      END{if(s=="")
            {print "0 0 0 0 " chk}
          else
            {print s+l, c+0, ab+0, pb+0, chk}}' "$WORK/st"
}

# `runs` timed runs with the stats counters OFF, echoing
# "<min_cycles> <runs> <spread%> <distinct_outputs>". MINIMUM, not mean: every
# source of error on a shared box ADDS cycles, so the smallest sample is the
# closest to the work itself. The spread is echoed so a contended run is visible
# rather than averaged away, and the distinct-output count is the determinism
# control -- runs of one point that printed different answers are not one
# measurement, and a subject the optimizer partly elided shows up there.
time_min() {
  : > "$WORK/cy"; : > "$WORK/ck"
  _i=0
  while [ "$_i" -lt "$RUNS" ]; do
    /usr/bin/time -l "$BIN" "$1" "$2" >"$WORK/o" 2>"$WORK/t"
    awk '/cycles elapsed/{print $1}' "$WORK/t" >> "$WORK/cy"
    cat "$WORK/o" >> "$WORK/ck"
    _i=$((_i+1))
  done
  _d=$(sort -u "$WORK/ck" | wc -l | tr -d ' ')
  sort -n "$WORK/cy" | awk -v d="$_d" '
    {a[NR]=$1}
    END{ if (NR < 1 || a[1] + 0 <= 0) { print "0 0 0 0"; exit }
         printf "%d %d %.2f %d", a[1], NR, (a[NR]-a[1])*100.0/a[1], d }'
}

# One measured point. Echoes every field of it on one line:
#   n width objects collections allocbytes peakbytes cycles runs spread% distinct checksum
point() {
  set -- $(count_run "$1" "$2") "$1" "$2"
  _obj=$1; _col=$2; _ab=$3; _pb=$4; _chk=$5; _n=$6; _w=$7
  set -- $(time_min "$_n" "$_w")
  echo "$_n $_w $_obj $_col $_ab $_pb $1 $2 $3 $4 $_chk"
}
f() { echo "$1" | awk -v k="$2" '{print $k}'; }

# ------------------------------------------------------------------ one arm --
# Measures one (subject, width) at three points -- N, N/2 and 0 -- prints the
# report on stdout and writes the single RESULT line to $2. Not a command
# substitution and not a pipeline on purpose: a `$(arm ...)` would swallow the
# non-zero exit of every check below and report the failure as a result.
arm() {
  aw="$1"; dest="$2"
  half=$((N / 2))

  pF=$(point "$N" "$aw")
  pH=$(point "$half" "$aw")
  pZ=$(point 0 "$aw")

  objF=$(f "$pF" 3); colF=$(f "$pF" 4); abF=$(f "$pF" 5); pbF=$(f "$pF" 6)
  cycF=$(f "$pF" 7); spF=$(f "$pF" 9); dF=$(f "$pF" 10); chkF=$(f "$pF" 11)
  objH=$(f "$pH" 3); colH=$(f "$pH" 4); cycH=$(f "$pH" 7); spH=$(f "$pH" 9); dH=$(f "$pH" 10)
  objZ=$(f "$pZ" 3); colZ=$(f "$pZ" 4); cycZ=$(f "$pZ" 7); spZ=$(f "$pZ" 9); dZ=$(f "$pZ" 10)

  echo "objprobe: === arm width=${aw}B  subject=${SUBJECT}  compiler=${BIT} ==="
  echo "objprobe: counting runs (BIT_GC_STATS=1; NOT timed -- those counters cost ~5.5% cycles, ABI.md 8.2)"
  # objects/n is the scaling column, and it is the one to read first: a subject
  # whose elements got packed inline (#3862) still runs, still prints the right
  # answer and still reports a plausible cycle count -- it just constructs
  # thousands of objects instead of millions, and every cyc/obj derived from it
  # is a division by a denominator nobody looked at. That is #3934 exactly.
  printf 'objprobe:   n=%-9s objects=%-9s objects/n=%-7s collections=%-6s allocbytes=%-11s peakbytes=%-10s bytes/obj=%s\n' \
    "$N" "$objF" "$(awk -v o="$objF" -v n="$N" 'BEGIN{if(n<1){print "n/a"}else{printf "%.3f", o/n}}')" \
    "$colF" "$abF" "$pbF" \
    "$(awk -v a="$abF" -v o="$objF" 'BEGIN{if(o<1){print "n/a"}else{printf "%.1f", a/o}}')"
  printf 'objprobe:   n=%-9s objects=%-9s objects/n=%-7s collections=%s\n' "$half" "$objH" \
    "$(awk -v o="$objH" -v n="$half" 'BEGIN{if(n<1){print "n/a"}else{printf "%.3f", o/n}}')" "$colH"
  printf 'objprobe:   n=%-9s objects=%-9s objects/n=%-7s collections=%s   <- the floor point, same binary\n' \
    0 "$objZ" "n/a" "$colZ"
  echo "objprobe: timed runs (BIT_GC_STATS unset; /usr/bin/time -l; min of ${RUNS})"
  printf 'objprobe:   n=%-9s cycles=%-14s runs=%-3s spread=%-7s distinct-outputs=%s\n' "$N" "$cycF" "$RUNS" "${spF}%" "$dF"
  printf 'objprobe:   n=%-9s cycles=%-14s runs=%-3s spread=%-7s distinct-outputs=%s\n' "$half" "$cycH" "$RUNS" "${spH}%" "$dH"
  printf 'objprobe:   n=%-9s cycles=%-14s runs=%-3s spread=%-7s distinct-outputs=%s\n' 0 "$cycZ" "$RUNS" "${spZ}%" "$dZ"

  # A collapsed denominator is the failure this probe exists to make visible: a
  # subject whose elements got packed inline (#3862) allocates no per-object
  # heap at all, and every cyc/obj computed from it would be a flattering
  # division by a number nobody looked at.
  if [ "$objF" -le "$objZ" ]; then
    echo "objprobe: FAIL -- $objF object(s) at n=$N against $objZ at n=0: nothing was measured." >&2
    echo "objprobe:   See subject.bit's 'o: Owner' note (#3862/#3934)." >&2
    return 1
  fi
  # Isolation B divides by this difference. Zero or negative is not a small
  # number to be careful with, it is a subject that does not scale with its
  # argument -- so it is refused here rather than turned into an infinity.
  if [ "$objF" -le "$objH" ]; then
    echo "objprobe: FAIL -- objects did not grow from n=$half ($objH) to n=$N ($objF)." >&2
    echo "objprobe:   The subject does not scale with its argument, so the marginal slope" >&2
    echo "objprobe:   has no denominator. See the subject contract in --help." >&2
    return 1
  fi
  if [ "$dF" != 1 ] || [ "$dH" != 1 ] || [ "$dZ" != 1 ]; then
    echo "objprobe: FAIL -- runs of one point printed different answers ($dF/$dH/$dZ distinct)." >&2
    echo "objprobe:   The subject is not deterministic; no cycle figure from it is comparable." >&2
    return 1
  fi

  set -- $(awk -v cF="$cycF" -v cH="$cycH" -v cZ="$cycZ" \
               -v oF="$objF" -v oH="$objH" -v oZ="$objZ" 'BEGIN{
    A = cF / oF
    B = (cF - cH) / (oF - oH)
    C = (cF - cZ) / oF
    lo = A; if (B < lo) lo = B; if (C < lo) lo = C
    hi = A; if (B > hi) hi = B; if (C > hi) hi = C
    printf "%.2f %.2f %.2f %.2f", A, B, C, hi - lo }')
  isoA=$1; isoB=$2; isoC=$3; disagree=$4

  echo "objprobe: cycles/object -- three isolations, each with its own denominator"
  printf 'objprobe:   A total/N            %8s   = %s / %s\n' "$isoA" "$cycF" "$objF"
  printf 'objprobe:   B marginal slope     %8s   = (%s - %s) / (%s - %s)\n' \
    "$isoB" "$cycF" "$cycH" "$objF" "$objH"
  printf 'objprobe:   C floor-subtracted   %8s   = (%s - %s) / %s\n' "$isoC" "$cycF" "$cycZ" "$objF"
  # A exceeds C by exactly the floor amortized over the objects -- structural,
  # not noise, and it shrinks as N grows. Printed so a reader who sees the three
  # diverge at a small N knows which part of the gap is arithmetic and which is
  # the box. It is the whole reason the default N is 10M rather than something
  # that finishes faster.
  printf 'objprobe:   A - C is the floor amortized: %s / %s = %s cyc/obj (structural, shrinks with n)\n' \
    "$cycZ" "$objF" "$(awk -v z="$cycZ" -v o="$objF" 'BEGIN{printf "%.2f", z/o}')"
  ok=$(awk -v d="$disagree" -v b="$BOUND" 'BEGIN{print (d<=b) ? "ok" : "FAIL"}')
  printf 'objprobe:   spread across the three: %s cyc/obj (bound %s) -- %s\n' "$disagree" "$BOUND" "$ok"
  printf 'objprobe:   checksum=%s, identical across all %s runs of each point\n' "$chkF" "$RUNS"

  if [ "$ok" = FAIL ]; then
    echo "objprobe: FAIL -- the three isolations disagree by more than ${BOUND} cyc/obj." >&2
    echo "objprobe:   Either the box was contended (read spread% above, and check that" >&2
    echo "objprobe:   'ps -eo comm= -A | grep -c make-driver' is 0) or the subject is not" >&2
    echo "objprobe:   linear in its argument. The number is not usable, so none is issued." >&2
    return 1
  fi

  printf 'RESULT %s width=%sB cyc/obj=%s objects=%s collections=%s cycles=%s runs=%s spread=%s%%\n' \
    "$LABEL" "$aw" "$isoB" "$objF" "$colF" "$cycF" "$RUNS" "$spF" | tee "$dest"
}

notes() {
  echo "objprobe: cyc/obj above is isolation B, the marginal slope: constants cancel in it."
  echo "objprobe: collections is a SAFETY signal, NOT a win signal. #3846: a 37% cut in"
  echo "objprobe:   collections (BIT_GC_MIN_KB 4096->6144, 210->133) bought 0.10% of cycles."
  echo "objprobe:   A RISE is a regression worth chasing; a fall proves nothing on its own."
  echo "objprobe: these figures DO NOT ADD. Two changes measured separately at -x and -y"
  echo "objprobe:   cyc/obj do not combine to -(x+y): #4162 measured 58.9 summed against"
  echo "objprobe:   44.3 when the same changes were ablated together (75%), and #4320"
  echo "objprobe:   independently found 78%. To claim a combined win, apply both and run"
  echo "objprobe:   this probe once -- the ratios do not multiply either. That is why the"
  echo "objprobe:   -b comparison below prints a RATIO and never a 'cycles saved' addend."
}

get() { sed "s/.*$2=\([0-9.]*\).*/\1/" "$1"; }

if [ "$SELFTEST" = 1 ]; then
  echo "objprobe: SELFTEST -- the 16B -> 64B body mutation, on the default subject."
  echo "objprobe: An instrument nobody has watched move is not known to measure anything."
  arm 16 "$WORK/r16"
  echo ""
  arm 64 "$WORK/r64"
  echo ""
  c16=$(get "$WORK/r16" collections); c64=$(get "$WORK/r64" collections)
  y16=$(get "$WORK/r16" "cyc\/obj");  y64=$(get "$WORK/r64" "cyc\/obj")
  o16=$(get "$WORK/r16" objects);     o64=$(get "$WORK/r64" objects)
  cat "$WORK/r16" "$WORK/r64"
  echo ""
  printf 'objprobe: MUTATION 16B -> 64B body, denominator held at %s vs %s objects\n' "$o16" "$o64"
  printf 'objprobe:   collections %s -> %s   (%s)\n' "$c16" "$c64" \
    "$(awk -v a="$c16" -v b="$c64" 'BEGIN{if(a<1){print "n/a"}else{printf "%.2fx", b/a}}')"
  printf 'objprobe:   cyc/obj     %s -> %s   (%s)\n' "$y16" "$y64" \
    "$(awk -v a="$y16" -v b="$y64" 'BEGIN{if(a<=0){print "n/a"}else{printf "%.2fx", b/a}}')"
  # Both columns must move, and the object count must NOT: a mutation that
  # changed how many objects exist would be a different program, not a wider
  # body, and the comparison would not be attributable to the body at all.
  awk -v c1="$c16" -v c2="$c64" -v y1="$y16" -v y2="$y64" -v o1="$o16" -v o2="$o64" 'BEGIN{
    bad = 0
    if (o1 != o2) { print "objprobe: FAIL -- object counts differ (" o1 " vs " o2 "): not a controlled mutation." > "/dev/stderr"; bad = 1 }
    if (c2 <= c1) { print "objprobe: FAIL -- collections did not rise (" c1 " -> " c2 "): that column is not live." > "/dev/stderr"; bad = 1 }
    if (y2 <= y1) { print "objprobe: FAIL -- cyc/obj did not rise (" y1 " -> " y2 "): that column is not live." > "/dev/stderr"; bad = 1 }
    if (bad) exit 1
    print "objprobe: SELFTEST PASS -- both reported columns moved under a mutation we control,"
    print "objprobe:   with the denominator (" o1 " objects) held fixed."
  }'
  notes
  exit 0
fi

arm "$WIDTH" "$WORK/res"
echo ""
if [ -n "$OUTFILE" ]; then
  cp "$WORK/res" "$OUTFILE"
  echo "objprobe: RESULT line written to $OUTFILE"
fi
if [ -n "$BASELINE" ]; then
  grep '^RESULT ' "$BASELINE" | tail -1 > "$WORK/base" || true
  [ -s "$WORK/base" ] || { echo "objprobe: no RESULT line in $BASELINE" >&2; exit 2; }
  echo "objprobe: baseline $(cat "$WORK/base")"
  # Deliberately NOT a "cycles saved" figure. An absolute saving is an addend,
  # and the one thing these numbers must not do is get added up.
  awk -v by="$(get "$WORK/base" "cyc\/obj")" -v ny="$(get "$WORK/res" "cyc\/obj")" \
      -v bo="$(get "$WORK/base" objects)"    -v no="$(get "$WORK/res" objects)" \
      -v bc="$(get "$WORK/base" collections)" -v nc="$(get "$WORK/res" collections)" 'BEGIN{
    printf "objprobe: cyc/obj %s -> %s = %.3fx, over %s vs %s objects\n", by, ny, ny/by, bo, no
    printf "objprobe: collections %s -> %s = %.3fx (SAFETY: a rise is the finding, a fall is not a win)\n", bc, nc, (bc > 0 ? nc/bc : 0)
    if (bo != no) print "objprobe: WARNING -- the two runs constructed different object counts, so this is\nobjprobe:   not a controlled comparison. Fix the subject or -n before quoting it."
  }'
fi
notes
