#!/usr/bin/env bash
# Bit language benchmark harness.
#
# Builds each case in Bit, Go and C, verifies they compute the same result, then
# measures runtime (CPU cycles + instructions retired, wall clock, peak RSS),
# binary size, process startup, and Bit compile speed. Writes results into
# README.md (between the BENCH markers), a standalone bench/RESULTS.md, and an
# appended bench/history.csv, and keeps the raw numbers in bench/last-run.dat.
#
#   bench/run.sh            measure, then render
#   bench/run.sh --render   render only: rebuild the README block and
#                           bench/RESULTS.md from bench/last-run.dat, no
#                           measuring, no go/cc/bit needed (bench/render.sh)
#
# The README block is a verdict a reader takes in at a glance; every table and
# method paragraph lives in bench/RESULTS.md (bench/render.sh).
#
# The published Bit/Go and Bit/C ratios come from CYCLES, not from wall clock.
# /usr/bin/time reports `real` in hundredths of a second, and six of the ten C
# sides run in 0.00-0.09s, so a wall-clock ratio for those rows is quantisation
# and not a measurement (#4040: `map` read 7.50x C off 0.300s/0.040s where the
# cycle counters say 4.45x). More runs cannot fix that -- averaging a quantised
# value narrows the spread around the wrong number. The counters were already
# in the `/usr/bin/time -l` output this harness captures and threw away.
#
# No external tools: timing uses /usr/bin/time and perl's Time::HiRes, both of
# which ship with macOS. Requires `go` and `cc` on PATH. Runs on stock bash 3.2.
set -euo pipefail

cd "$(dirname "$0")/.."          # repo root
source bench/buildlib.sh         # BIT, CFLAGS, buildBit/buildC/buildGo -- shared with profile.sh
# Explicit on purpose, NOT a glob over bench/cases/*/ -- that directory holds 15
# entries and only these 12 have all three of <case>.bit, <case>.go and <case>.c.
# churn/ and trustcache/ are Bit-only (nothing to compare against) and startup/
# is the per-language empty-program baseline subtracted below, not a case. A
# glob here would try to `go build` a .go that does not exist and abort the run.
# `strmap` joined in #4376: `map` is map<i64,i64>, which takes the splitmix64
# scalar hash and the scalar probe path, so nothing published here reached the
# string path (wyhash + the group probe) and a change there read as "no
# regression" and "no improvement" identically.
# `allocpar` joined in #5728 for the same reason one case further out: every
# other case here is SINGLE-mutator, so the allocator's contended costs were
# unmeasurable by construction. One mutator never loses the heap-lock race,
# which is the only thing that arms runtime/gc's per-OS-thread allocation
# cache, so a change to that cache could land correct, land regressed, or not
# land at all and this suite would print the same numbers.
CASES="fib mandelbrot collatz alloc allocflat allocpar strings map strmap sort matrix json"
RUNS=15                          # timed runs per case; see trimmean() for why 15
CRUNS=3                          # compile-time samples per case; median reported
STARTUP_ITERS=200                # exec count for startup timing

RENDER_ONLY=0
[ "${1:-}" = "--render" ] && RENDER_ONLY=1

if [ "$RENDER_ONLY" = 0 ]; then
  command -v go >/dev/null || { echo "go not found on PATH" >&2; exit 1; }
  command -v cc >/dev/null || { echo "cc not found on PATH" >&2; exit 1; }
  [ -x "$BIT" ] || { echo "$BIT not built (run: ./make)" >&2; exit 1; }
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
RES="$WORK/res"      # lines: "<case> <lang> <median_s> <rss_bytes> <bin_bytes> <cycles> <instrs>"
: > "$RES"
ALC="$WORK/alc"      # lines: "<case> <lang> <heap_allocations_per_run>"
: > "$ALC"
GCRES="$WORK/gcres"  # bit lines: "<case> bit <pauses> <pausens_ms> <pausemaxns_ms> <share>"
: > "$GCRES"          # go lines:  "<case> go <gc_count> <stw_ms> <stwmax_ms> <share>"
APW="$WORK/apwall"   # allocpar_W1/allocpar_W8 wall rows: "<case> <lang> <wall_ms>"
: > "$APW"

source bench/render.sh           # accessors over the files above, and renderAll
if [ "$RENDER_ONLY" = 1 ]; then renderAll; exit 0; fi

now()    { perl -MTime::HiRes -e 'printf "%.6f\n", Time::HiRes::time()'; }
median() { sort -n | awk '{a[NR]=$1} END{n=NR; if(n%2){print a[(n+1)/2]} else {printf "%.6f\n",(a[n/2]+a[n/2+1])/2}}'; }
# Counters reduce by a TRIMMED MEAN: the mean of the samples left after dropping
# the slowest fifth. The obvious choice is the minimum -- "contention can only
# inflate a counter, never deflate it" -- and 40 samples per series say it is the
# WORST of the four estimators tried (#4040). That argument holds for a single
# thread and breaks for a language with a concurrent runtime, because the
# process-wide counter also moves with how much real GC work the runtime chose to
# do on that run. Go's `allocflat` gave one 109.5M sample against a 121-135M body,
# so a min reports whichever run happened to skip a collection: two independent
# min-of-15 estimates differ by 11.4% at p95, against 1.9% for this one. Trimming
# the top fifth keeps the mean's efficiency without its vulnerability to a box
# that was less idle than it looked -- C's `allocflat` carries a 28.1M sample over
# a 20.9M floor, where the untrimmed mean spreads 2.49% and this spreads 0.44%.
# RUNS=15 is from the same measurement: p95 spread falls steeply to about there
# and then flattens, and 15 leaves 12 samples after the trim.
trimmean() { sort -n | awk '{a[NR]=$1} END{k=int(NR/5); if(k<1)k=1; n=NR-k;
                            for(i=1;i<=n;i++)s+=a[i]; printf "%.0f", s/n}'; }
size()   { stat -f%z "$1"; }

# Heap allocations one run of a case performs, per language — the number that
# proves the three sources still express the SAME data structure (#3934: the
# Bit side of `alloc` silently became a slice of inline values while the Go and
# C sides kept allocating per node, and the row compared them for a day). Bit
# reports it from the runtime (BIT_GC_STATS, every case); Go and C report it
# only where the source opts in (see bench/cases/alloc/alloc.go's
# `reportAllocs` and alloc.c's BENCH_ALLOC_STATS), and print "n/a" otherwise.
bit_allocs() { awk '{for(i=1;i<=NF;i++){if($i~/^swept=/){s=substr($i,7)}
                     if($i~/^live=/){l=substr($i,6)}}}
                END{if(s!="")print s+l}' "$1"; }
tag_allocs() { awk '/^\[allocs\]/{print $2}' "$1"; }

# Runs $@ once under /usr/bin/time -l, echoes
# "<real_seconds> <max_rss_bytes> <cycles_elapsed> <instructions_retired>".
# The last two are printed by /usr/bin/time -l on Apple silicon from the same
# invocation -- no second run, no sampling profiler, no extra dependency.
# `real` is /usr/bin/time's own field, at BSD time(1)'s hundredth-of-a-second
# resolution -- too coarse for the millisecond wall table below, which uses
# wall_run() instead. It is still parsed here because this function's other
# three fields need the invocation anyway and a caller may want it.
time_run() {
  /usr/bin/time -l "$@" >/dev/null 2>"$WORK/t"
  awk '/ real/{r=$1} /maximum resident set size/{m=$1}
       /cycles elapsed/{c=$1} /instructions retired/{n=$1}
       END{print r, m, c+0, n+0}' "$WORK/t"
}

# Runs $1 once, fork-to-reap, echoes elapsed milliseconds (one decimal). $2,
# if given, captures the child's stderr (used for BIT_GC_STATS / GODEBUG
# probes); otherwise stderr is discarded like stdout.
#
# ONE perl process does the fork, exec and waitpid, and reads Time::HiRes
# immediately before and after itself -- not two separate now() calls
# bracketing the run the way the compile-time loop above does. Two calls
# would each pay perl's own ~5-10ms startup after the child has already
# exited, and that jitter would land inside the measured interval; allocpar's
# W8 pause share needs low-noise wall time to be meaningful at all. No
# intermediate shell: fork()+exec() runs $1 directly, so no extra process
# startup is inside the timed window either.
wall_run() {
  local errfile="${2:-/dev/null}"
  perl -MTime::HiRes -e '
    my ($bin, $errfile) = @ARGV;
    open(my $devnull, ">", "/dev/null") or die $!;
    open(my $errfh, ">", $errfile) or die $!;
    my $t0 = Time::HiRes::time();
    my $pid = fork();
    if (!defined $pid) { die "fork: $!" }
    if ($pid == 0) {
      open(STDOUT, ">&", $devnull);
      open(STDERR, ">&", $errfh);
      exec($bin) or exit 127;
    }
    waitpid($pid, 0);
    printf "%.1f\n", (Time::HiRes::time() - $t0) * 1000;
  ' "$1" "$errfile"
}

# One `field=value` token out of a BIT_GC_STATS or `[bit-gc] ...` line --
# shared by the allocation probe above (kept as bit_allocs/tag_allocs, its own
# two-field parse) and the pause fields below, which are one field each.
gcstat() { awk -v f="$2" '{for(i=1;i<=NF;i++) if(index($i,f"=")==1){print substr($i,length(f)+2); exit}}' "$1"; }

# `pauses=`/`pausens=`/`pausemaxns=` (#5834) from one BIT_GC_STATS=1 run's
# captured stderr, ns converted to ms.
bit_pauses()     { n=$(gcstat "$1" pauses); [ -n "$n" ] && echo "$n" || echo 0; }
bit_pausens_ms() { awk -v v="$(gcstat "$1" pausens)" 'BEGIN{printf "%.1f", (v+0)/1000000}'; }
bit_pausemax_ms(){ awk -v v="$(gcstat "$1" pausemaxns)" 'BEGIN{printf "%.1f", (v+0)/1000000}'; }

# Go's `GODEBUG=gctrace=1` log: one `gc N @Ts P%: A+B+C ms clock, ...` line
# per collection, where A is the sweep-termination STW pause, B is concurrent
# mark (not a stop) and C is the mark-termination STW pause -- `go doc
# runtime`'s gctrace entry, go1.27.1, confirmed against a live run of
# bench/cases/allocpar/allocpar.go. GC count is the number of lines; the STW
# sum is every line's A+C; the max is the single longest INDIVIDUAL A or C
# segment, matching what pausemaxns= reports for Bit (the longest one stop),
# not a per-collection sum.
go_gc_n()       { awk '/^gc [0-9]+ /{n++} END{print n+0}' "$1"; }
go_gc_stw_ms()  { awk '/^gc [0-9]+ /{split($5,a,"+"); s+=a[1]+0; s+=a[3]+0} END{printf "%.1f", s+0}' "$1"; }
go_gc_stwmax_ms(){ awk '/^gc [0-9]+ /{split($5,a,"+"); if(a[1]+0>m)m=a[1]+0; if(a[3]+0>m)m=a[3]+0} END{printf "%.1f", m+0}' "$1"; }

# Pause share of a probe run's own wall time -- $1 pause/STW ms, $2 that same
# run's wall ms from wall_run(). n/a on a zero-length run rather than a
# division by zero.
pause_share() { awk -v a="$1" -v b="$2" 'BEGIN{if(b+0<=0){printf "n/a"}else{printf "%.1f%%", a/b*100}}'; }

# `allocpar W1`/`allocpar W8` rows (#5835): BIT_WORKERS/GOMAXPROCS resize the
# scheduler's worker-thread pool while the source's own 8-way `spawn`/`go`
# fan-out stays fixed -- see allocpar.bit's header for why that knob, not the
# source constant, is what varies. C is unchanged: WORKERS is a C #define,
# never read from env in any of the three sources, so its wall figure reuses
# the baseline allocpar row already measured above instead of re-running the
# identical binary; the pause table has no C column at all (n/a, always).
# Appends one wall row per language to $WORK/apwall and one pause row per
# language to $GCRES, in the same shapes their non-allocpar counterparts use.
allocparExtraRows() {
  local w="$1"
  : > "$WORK/apwb"; : > "$WORK/apwg"
  local i=0
  while [ "$i" -lt "$RUNS" ]; do
    BIT_WORKERS="$w" wall_run "$WORK/allocpar.bit" >> "$WORK/apwb"
    GOMAXPROCS="$w" wall_run "$WORK/allocpar.go" >> "$WORK/apwg"
    i=$((i+1))
  done
  local cms
  cms=$(awk -v x="$(get allocpar c 3)" 'BEGIN{printf "%.1f", x*1000}')
  echo "allocpar_W$w bit $(median < "$WORK/apwb")" >> "$APW"
  echo "allocpar_W$w go $(median < "$WORK/apwg")" >> "$APW"
  echo "allocpar_W$w c $cms" >> "$APW"

  local bwms gwms
  bwms=$(BIT_WORKERS="$w" BIT_GC_STATS=1 wall_run "$WORK/allocpar.bit" "$WORK/apb")
  gwms=$(GOMAXPROCS="$w" GODEBUG=gctrace=1 wall_run "$WORK/allocpar.go" "$WORK/apg")
  echo "allocpar_W$w bit $(bit_pauses "$WORK/apb") $(bit_pausens_ms "$WORK/apb") $(bit_pausemax_ms "$WORK/apb")" \
       "$(pause_share "$(bit_pausens_ms "$WORK/apb")" "$bwms")" >> "$GCRES"
  echo "allocpar_W$w go $(go_gc_n "$WORK/apg") $(go_gc_stw_ms "$WORK/apg") $(go_gc_stwmax_ms "$WORK/apg")" \
       "$(pause_share "$(go_gc_stw_ms "$WORK/apg")" "$gwms")" >> "$GCRES"
}

comp_total=0; comp_n=0
echo "Building + benchmarking cases x 3 languages ($RUNS runs each)..."
for c in $CASES; do
  d="bench/cases/$c"

  # --- build (Bit compile time is itself measured) ---
  : > "$WORK/ct"
  i=0; while [ "$i" -lt "$CRUNS" ]; do
    t0=$(now); buildBit "$d" "$c" "$WORK/$c.bit" >/dev/null; t1=$(now)
    awk -v a="$t0" -v b="$t1" 'BEGIN{print b-a}' >> "$WORK/ct"
    i=$((i+1))
  done
  cmed=$(median < "$WORK/ct")
  comp_total=$(awk -v s="$comp_total" -v x="$cmed" 'BEGIN{print s+x}'); comp_n=$((comp_n+1))
  buildC "$d" "$c" "$WORK/$c.c"
  buildGo "$d" "$c" "$WORK/$c.go"

  # --- correctness gate, doubling as the allocation-count probe ---
  # Both stats env vars write to STDERR only, so stdout stays the answer this
  # gate compares and no extra run is needed for the counts. The timed runs
  # below set neither.
  ob=$(BIT_GC_STATS=1 "$WORK/$c.bit" 2>"$WORK/ab")
  oc=$("$WORK/$c.c")
  og=$(BENCH_ALLOC_STATS=1 "$WORK/$c.go" 2>"$WORK/ag")
  echo "$c bit $(bit_allocs "$WORK/ab")" >> "$ALC"
  echo "$c go $(tag_allocs "$WORK/ag")" >> "$ALC"
  if grep -q BENCH_ALLOC_STATS "$d/$c.c"; then
    # A counting build, never the timed one: the counter is a malloc macro.
    buildC "$d" "$c" "$WORK/$c.cstat" -DBENCH_ALLOC_STATS
    "$WORK/$c.cstat" >/dev/null 2>"$WORK/ac"
    echo "$c c $(tag_allocs "$WORK/ac")" >> "$ALC"
  fi
  if [ "$c" = mandelbrot ]; then
    # cross-compiler float results differ by FMA contraction; allow 0.01%.
    awk -v a="$ob" -v b="$oc" -v g="$og" 'BEGIN{
      d1=(a-b)/b; if(d1<0)d1=-d1; d2=(a-g)/g; if(d2<0)d2=-d2;
      if(d1>0.0001||d2>0.0001){exit 1}}' \
      || { echo "verify failed: $c (bit=$ob c=$oc go=$og)" >&2; exit 1; }
  else
    [ "$ob" = "$oc" ] && [ "$oc" = "$og" ] || { echo "verify failed: $c (bit=$ob c=$oc go=$og)" >&2; exit 1; }
  fi

  # --- GC pause probe (#5835): ONE untimed run per case, kept OUT of the
  # timed loop below because BIT_GC_STATS/GODEBUG add their own overhead.
  # wall_run's own fork-to-reap ms is this SAME run's wall, so pause share is
  # computed against the run that produced the pause numbers, not the timed
  # loop's median from a different set of runs.
  bwms=$(BIT_GC_STATS=1 wall_run "$WORK/$c.bit" "$WORK/pb")
  gwms=$(GODEBUG=gctrace=1 wall_run "$WORK/$c.go" "$WORK/pg")
  echo "$c bit $(bit_pauses "$WORK/pb") $(bit_pausens_ms "$WORK/pb") $(bit_pausemax_ms "$WORK/pb")" \
       "$(pause_share "$(bit_pausens_ms "$WORK/pb")" "$bwms")" >> "$GCRES"
  echo "$c go $(go_gc_n "$WORK/pg") $(go_gc_stw_ms "$WORK/pg") $(go_gc_stwmax_ms "$WORK/pg")" \
       "$(pause_share "$(go_gc_stw_ms "$WORK/pg")" "$gwms")" >> "$GCRES"

  # --- timed runs (interleaved run-for-run, #4398) ---
  # #4383 measured two BYTE-IDENTICAL copies of the same binary under the old
  # shape -- run all RUNS of bit, then all RUNS of c, then all RUNS of go --
  # and got -15.95%..+4.87% on this Mac, |delta|>=4% in 2/10 pairs. Box speed
  # drifts on a timescale of minutes, so two consecutive ~2-20s blocks sample
  # two different box states and the whole drift lands in the ratio. The fix
  # is to run one iteration of every language, RUNS times, so both sides of
  # every ratio share the same drift. Interleaved, the same protocol gave
  # 0/10 pairs above 4%. Rotate the language order each iteration so no
  # language keeps a fixed position in the triple.
  for l in bit c go; do : > "$WORK/ms.$l"; : > "$WORK/cy.$l"; : > "$WORK/in.$l"; : > "$WORK/wm.$l"; done
  i=0
  while [ "$i" -lt "$RUNS" ]; do
    case $((i % 3)) in
      0) order="bit c go" ;;
      1) order="c go bit" ;;
      *) order="go bit c" ;;
    esac
    for l in $order; do
      set -- $(time_run "$WORK/$c.$l")
      echo "$2" >> "$WORK/ms.$l"
      echo "$3" >> "$WORK/cy.$l"; echo "$4" >> "$WORK/in.$l"
      wall_run "$WORK/$c.$l" >> "$WORK/wm.$l"
    done
    i=$((i+1))
  done
  for l in bit c go; do
    wsec=$(awk -v x="$(median < "$WORK/wm.$l")" 'BEGIN{printf "%.6f", x/1000}')
    echo "$c $l $wsec $(median < "$WORK/ms.$l") $(size "$WORK/$c.$l")" \
         "$(trimmean < "$WORK/cy.$l") $(trimmean < "$WORK/in.$l")" >> "$RES"
  done
  # allocpar's own worker-count variants (#5835) -- need $RES's baseline
  # allocpar row above for the C column, so this runs only once it exists.
  if [ "$c" = allocpar ]; then
    allocparExtraRows 1
    allocparExtraRows 8
  fi
  echo "  $c ok (= $ob) allocs bit=$(alcmd "$c" bit) go=$(alcmd "$c" go) c=$(alcmd "$c" c)"
done

# --- startup: median per-exec ms over a tight loop ---
buildBit bench/cases/startup startup "$WORK/s.bit" >/dev/null
buildC bench/cases/startup startup "$WORK/s.c"
buildGo bench/cases/startup startup "$WORK/s.go"
: > "$WORK/start"
for l in bit c go; do
  t0=$(now); i=0; while [ "$i" -lt "$STARTUP_ITERS" ]; do "$WORK/s.$l"; i=$((i+1)); done; t1=$(now)
  echo "$l $(awk -v a="$t0" -v b="$t1" -v n="$STARTUP_ITERS" 'BEGIN{printf "%.3f",(b-a)/n*1000}')" >> "$WORK/start"
done

# The same empty program, in cycles: the floor every case pays before its own
# first instruction (dyld, runtime init, exit). It differs per language and is
# a few million cycles, which is noise against matrix but a FIFTH of C's
# allocflat (~17 Mcyc) -- leaving it in would publish a ratio that is partly a
# measurement of the dynamic linker. Subtracted from every cycle figure below.
: > "$WORK/startcyc"
for l in bit c go; do
  : > "$WORK/scy"; : > "$WORK/sin"
  i=0; while [ "$i" -lt "$RUNS" ]; do
    set -- $(time_run "$WORK/s.$l")
    echo "$3" >> "$WORK/scy"; echo "$4" >> "$WORK/sin"; i=$((i+1))
  done
  echo "$l $(trimmean < "$WORK/scy") $(trimmean < "$WORK/sin")" >> "$WORK/startcyc"
done
scyc() { awk -v l="$1" '$1==l{print $2}' "$WORK/startcyc"; }
sins() { awk -v l="$1" '$1==l{print $3}' "$WORK/startcyc"; }

# --- compile speed: total Bit source lines / total compile time ---
# Sum only the $CASES directories the timed loop above actually compiled —
# not every bench/cases/*/*.bit on disk (that glob also picks up churn/ and
# startup/, which are never in $CASES and would inflate srclines without
# inflating comp_n).
srclines=0
for c in $CASES; do
  srclines=$(( srclines + $(wc -l < "bench/cases/$c/$c.bit") ))
done
lps=$(awk -v l="$srclines" -v t="$comp_total" 'BEGIN{printf "%.0f", l/t}')

# ---------------- render ----------------
GITSHA=$(git rev-parse --short HEAD 2>/dev/null || echo "?")
STAMP=$(date -u +%FT%TZ)
CPU=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || uname -m)
OSV=$(sw_vers -productVersion 2>/dev/null || uname -sr)

# Startup-corrected counters for one case+language: the process total minus
# that language's own empty-program floor. Clamped at 1 so no ratio can divide
# by zero -- unlike the wall-clock column this replaces, which had to print "—"
# for allocflat because its C median rounded to 0.000s.
netcyc() { awk -v t="$(get "$1" "$2" 6)" -v b="$(scyc "$2")" 'BEGIN{v=t-b; if(v<1)v=1; print v}'; }
netins() { awk -v t="$(get "$1" "$2" 7)" -v b="$(sins "$2")" 'BEGIN{v=t-b; if(v<1)v=1; print v}'; }

STARTBASE=$(awk '{printf "%s%s %.1fM", (NR>1?", ":""), $1, $2/1000000} END{print ""}' "$WORK/startcyc")

# --- append history.csv (moved ahead of the render below, #4199: the
# reproducibility paragraph reads this file, so THIS run's own row must
# already be in it) ---
# alloc_count is empty, not 0, wherever a language has no counter for a case
# (alc() already returns "" on no match) -- a 0 meaning "not measured" is
# indistinguishable from a 0 meaning "allocated nothing" (#3997).
# cycles/instructions are the startup-corrected figures the tables publish, so a
# ratio recomputed from this file matches the one in RESULTS.md exactly.
hist=bench/history.csv
HDR="timestamp,git_sha,case,lang,median_s,rss_bytes,bin_bytes,alloc_count,cycles,instructions"
if [ ! -f "$hist" ]; then
  echo "$HDR" > "$hist"
elif [ "$(head -1 "$hist")" != "$HDR" ]; then
  # A column was added. Rewrite the header line only: historical rows keep their
  # own shorter arity, because a row that stops early means "not measured then",
  # which is the same claim an empty field makes (#3997). Padding them would
  # invent a measurement that was never taken.
  { echo "$HDR"; tail -n +2 "$hist"; } > "$WORK/hist" && mv "$WORK/hist" "$hist"
fi
for c in $CASES; do
  for l in bit c go; do
    echo "$STAMP,$GITSHA,$c,$l,$(get "$c" "$l" 3),$(get "$c" "$l" 4),$(get "$c" "$l" 5),$(alc "$c" "$l"),$(netcyc "$c" "$l"),$(netins "$c" "$l")" >> "$hist"
  done
done

# --- record the raw numbers so the README can be re-rendered without a re-run ---
# One flat file, the shape bench/render.sh reads back: counters already
# startup-corrected, the pause and worker-count rows, startup, and the facts
# about the machine. The next measured run overwrites it.
data=bench/last-run.dat
{
  echo "meta machine $CPU"
  echo "meta os $OSV"
  echo "meta sha $GITSHA"
  echo "meta stamp $STAMP"
  echo "meta go $(go version | awk '{print $3}')"
  echo "meta cc $(cc --version | head -1)"
  echo "meta startbase $STARTBASE"
  echo "meta lps $lps"
  echo "meta srclines $srclines"
  echo "meta ncases $comp_n"
  for c in $CASES; do
    for l in bit c go; do
      echo "res $c $l $(get "$c" "$l" 3) $(get "$c" "$l" 4) $(get "$c" "$l" 5) $(netcyc "$c" "$l") $(netins "$c" "$l")"
    done
  done
  sed 's/^/alc /' "$ALC"
  sed 's/^/gc /' "$GCRES"
  sed 's/^/apw /' "$APW"
  sed 's/^/start /' "$WORK/start"
} > "$data"

renderAll
echo "Appended $hist and wrote $data."