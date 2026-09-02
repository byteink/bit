#!/usr/bin/env bash
# Bit language benchmark harness.
#
# Builds each case in Bit, Go and C, verifies they compute the same result, then
# measures runtime (CPU cycles + instructions retired, wall clock, peak RSS),
# binary size, process startup, and Bit compile speed. Writes results into
# README.md (between the BENCH markers), a standalone bench/RESULTS.md, and an
# appended bench/history.csv.
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
BIT=./bit-out/bin/bit
# Explicit on purpose, NOT a glob over bench/cases/*/ -- that directory holds 13
# entries and only these 10 have all three of <case>.bit, <case>.go and <case>.c.
# churn/ and trustcache/ are Bit-only (nothing to compare against) and startup/
# is the per-language empty-program baseline subtracted below, not a case. A
# glob here would try to `go build` a .go that does not exist and abort the run.
CASES="fib mandelbrot collatz alloc allocflat strings map sort matrix json"
RUNS=15                          # timed runs per case; see trimmean() for why 15
CRUNS=3                          # compile-time samples per case; median reported
STARTUP_ITERS=200                # exec count for startup timing
CFLAGS="-O2 -ffp-contract=off"   # -ffp-contract=off: match strict IEEE (see README)

command -v go >/dev/null || { echo "go not found on PATH" >&2; exit 1; }
command -v cc >/dev/null || { echo "cc not found on PATH" >&2; exit 1; }
[ -x "$BIT" ] || { echo "$BIT not built (run: ./make)" >&2; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
RES="$WORK/res"      # lines: "<case> <lang> <median_s> <rss_bytes> <bin_bytes> <cycles> <instrs>"
: > "$RES"
ALC="$WORK/alc"      # lines: "<case> <lang> <heap_allocations_per_run>"
: > "$ALC"

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
get()    { awk -v c="$1" -v l="$2" -v k="$3" '$1==c&&$2==l{print $(k)}' "$RES"; }  # k: 3=s 4=rss 5=bin 6=cyc 7=instr
alc()    { awk -v c="$1" -v l="$2" '$1==c&&$2==l{print $3}' "$ALC"; }
alcmd()  { n=$(alc "$1" "$2"); [ -n "$n" ] && echo "$n" || echo "n/a"; }

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
time_run() {
  /usr/bin/time -l "$@" >/dev/null 2>"$WORK/t"
  awk '/ real/{r=$1} /maximum resident set size/{m=$1}
       /cycles elapsed/{c=$1} /instructions retired/{n=$1}
       END{print r, m, c+0, n+0}' "$WORK/t"
}

comp_total=0; comp_n=0
echo "Building + benchmarking cases x 3 languages ($RUNS runs each)..."
for c in $CASES; do
  d="bench/cases/$c"

  # --- build (Bit compile time is itself measured) ---
  : > "$WORK/ct"
  i=0; while [ "$i" -lt "$CRUNS" ]; do
    t0=$(now); "$BIT" build "$d/$c.bit" -o "$WORK/$c.bit" >/dev/null; t1=$(now)
    awk -v a="$t0" -v b="$t1" 'BEGIN{print b-a}' >> "$WORK/ct"
    i=$((i+1))
  done
  cmed=$(median < "$WORK/ct")
  comp_total=$(awk -v s="$comp_total" -v x="$cmed" 'BEGIN{print s+x}'); comp_n=$((comp_n+1))
  cc $CFLAGS "$d/$c.c" -o "$WORK/$c.c"
  go build -o "$WORK/$c.go" "$d/$c.go"

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
    cc $CFLAGS -DBENCH_ALLOC_STATS "$d/$c.c" -o "$WORK/$c.cstat"
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

  # --- timed runs ---
  for l in bit c go; do
    : > "$WORK/rs"; : > "$WORK/ms"; : > "$WORK/cy"; : > "$WORK/in"
    i=0; while [ "$i" -lt "$RUNS" ]; do
      set -- $(time_run "$WORK/$c.$l")
      echo "$1" >> "$WORK/rs"; echo "$2" >> "$WORK/ms"
      echo "$3" >> "$WORK/cy"; echo "$4" >> "$WORK/in"
      i=$((i+1))
    done
    echo "$c $l $(median < "$WORK/rs") $(median < "$WORK/ms") $(size "$WORK/$c.$l")" \
         "$(trimmean < "$WORK/cy") $(trimmean < "$WORK/in")" >> "$RES"
  done
  echo "  $c ok (= $ob) allocs bit=$(alcmd "$c" bit) go=$(alcmd "$c" go) c=$(alcmd "$c" c)"
done

# --- startup: median per-exec ms over a tight loop ---
"$BIT" build bench/cases/startup/startup.bit -o "$WORK/s.bit" >/dev/null
cc $CFLAGS bench/cases/startup/startup.c -o "$WORK/s.c"
go build -o "$WORK/s.go" bench/cases/startup/startup.go
: > "$WORK/start"
for l in bit c go; do
  t0=$(now); i=0; while [ "$i" -lt "$STARTUP_ITERS" ]; do "$WORK/s.$l"; i=$((i+1)); done; t1=$(now)
  echo "$l $(awk -v a="$t0" -v b="$t1" -v n="$STARTUP_ITERS" 'BEGIN{printf "%.3f",(b-a)/n*1000}')" >> "$WORK/start"
done
sms() { awk -v l="$1" '$1==l{print $2}' "$WORK/start"; }

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

secs() { awk -v x="$1" 'BEGIN{printf "%.3f", x}'; }
mb()   { awk -v x="$1" 'BEGIN{printf "%.1f", x/1048576}'; }
kb()   { awk -v x="$1" 'BEGIN{printf "%.0f", x/1024}'; }
mil()  { awk -v x="$1" 'BEGIN{printf "%.1f", x/1000000}'; }
# Startup-corrected counters for one case+language: the process total minus
# that language's own empty-program floor. Clamped at 1 so no ratio can divide
# by zero -- unlike the wall-clock column this replaces, which had to print "—"
# for allocflat because its C median rounded to 0.000s.
netcyc() { awk -v t="$(get "$1" "$2" 6)" -v b="$(scyc "$2")" 'BEGIN{v=t-b; if(v<1)v=1; print v}'; }
netins() { awk -v t="$(get "$1" "$2" 7)" -v b="$(sins "$2")" 'BEGIN{v=t-b; if(v<1)v=1; print v}'; }
ratio()  { awk -v a="$1" -v b="$2" 'BEGIN{if(b+0<=0){printf "n/a"}else{printf "%.2fx", a/b}}'; }

STARTBASE=$(awk '{printf "%s%s %.1fM", (NR>1?", ":""), $1, $2/1000000} END{print ""}' "$WORK/startcyc")

md="$WORK/results.md"
{
  echo "_Full method and caveats below the tables._"
  echo
  echo "### Runtime: CPU cycles, lower is better"
  echo
  echo "| Benchmark | Bit | Go | C | Bit / Go | Bit / C |"
  echo "|---|--:|--:|--:|--:|--:|"
  for c in $CASES; do
    bcy=$(netcyc "$c" bit); gcy=$(netcyc "$c" go); ccy=$(netcyc "$c" c)
    echo "| $c | $(mil "$bcy") M | $(mil "$gcy") M | $(mil "$ccy") M |" \
         "$(ratio "$bcy" "$gcy") | $(ratio "$bcy" "$ccy") |"
  done
  echo
  echo "### Instructions retired: work emitted, not time taken"
  echo
  echo "| Benchmark | Bit | Go | C |"
  echo "|---|--:|--:|--:|"
  for c in $CASES; do
    echo "| $c | $(mil "$(netins "$c" bit)") M | $(mil "$(netins "$c" go)") M | $(mil "$(netins "$c" c)") M |"
  done
  echo
  echo "### Wall clock: median of ${RUNS} runs, context only"
  echo
  echo "| Benchmark | Bit | Go | C |"
  echo "|---|--:|--:|--:|"
  for c in $CASES; do
    echo "| $c | $(secs "$(get "$c" bit 3)")s | $(secs "$(get "$c" go 3)")s | $(secs "$(get "$c" c 3)")s |"
  done
  echo
  echo "### Peak memory: max RSS, lower is better"
  echo
  echo "| Benchmark | Bit | Go | C |"
  echo "|---|--:|--:|--:|"
  for c in $CASES; do
    echo "| $c | $(mb "$(get "$c" bit 4)") MB | $(mb "$(get "$c" go 4)") MB | $(mb "$(get "$c" c 4)") MB |"
  done
  echo
  echo "### Heap allocations per run: the equivalence check, not a score"
  echo
  echo "| Benchmark | Bit | Go | C |"
  echo "|---|--:|--:|--:|"
  for c in $CASES; do
    echo "| $c | $(alcmd "$c" bit) | $(alcmd "$c" go) | $(alcmd "$c" c) |"
  done
  echo
  echo "### Binary size: static, as emitted"
  echo
  echo "| Benchmark | Bit | Go | C |"
  echo "|---|--:|--:|--:|"
  for c in $CASES; do
    echo "| $c | $(kb "$(get "$c" bit 5)") KB | $(kb "$(get "$c" go 5)") KB | $(kb "$(get "$c" c 5)") KB |"
  done
  echo
  echo "### Startup & compile"
  echo
  echo "| Metric | Bit | Go | C |"
  echo "|---|--:|--:|--:|"
  echo "| Process startup (per exec) | $(sms bit) ms | $(sms go) ms | $(sms c) ms |"
  echo
  echo "Bit compile speed: **${lps} lines/sec** (${srclines} lines across ${comp_n} cases, warm)."
  echo
  echo "> Machine: ${CPU}, macOS ${OSV}. Bit @ \`${GITSHA}\`, Go $(go version | awk '{print $3}'), $(cc --version | head -1)."
  echo "> Method: ${RUNS} runs per case per language. Cycles and instructions are a trimmed mean of those runs, meaning the mean after dropping the slowest fifth, which was the most reproducible of four estimators measured over 40 samples per series; wall clock and RSS are the median. C built \`cc ${CFLAGS}\`, Go \`go build\`, Bit \`bit build\`, each language's standard optimized build."
  echo "> Mandelbrot: Bit and C agree to the last bit; Go differs by ~0.0002% because it contracts \`a*b+c\` to a hardware FMA. Not a bug: cross-compiler float bit-identity is not guaranteed."
  echo "> alloc measures the ALLOCATOR: 10M short-lived nodes, each its own heap object in all three languages (Bit's element class has a reference field, Go holds \`[]*Node\`, C mallocs per node). allocflat measures DATA LAYOUT: the same 10M nodes and the same printed total, stored by value in one buffer per batch (Bit packs \`[]Node\` inline since #3862, Go holds \`[]Node\`, C mallocs the batch once). The gap between the two rows is what per-node heap allocation costs a language."
  echo "> The allocation table above is how those two claims are checked rather than asserted: same order of magnitude across a row means the three sources still express the same data structure, which is exactly what \`alloc\` silently lost for a day (#3934). Bit's count is \`swept+live\` from \`BIT_GC_STATS=1\`; Go's is \`runtime.MemStats.Mallocs\` and C's a \`malloc\` counter, both opt-in (\`BENCH_ALLOC_STATS\`, \`-DBENCH_ALLOC_STATS\`) and both absent from every timed binary."
  echo "> The ratios are built from CYCLES, not from wall clock. \`/usr/bin/time\` reports \`real\` in hundredths of a second and most of the C sides here finish in under 0.10s, so a wall-clock ratio for those rows is quantisation: \`map\` published 7.50x C off 0.300s/0.040s where the counters say ~4.5x. Adding runs does not fix that, because it narrows the spread around a quantised value instead of removing the quantisation, so the unit changed (#4040). Both counters come from the same \`/usr/bin/time -l\` invocation that already produced the wall clock and the RSS; nothing extra is run and nothing extra is installed. The wall-clock table is kept as context and carries no ratio column."
  echo "> Cycles and instructions are startup-corrected: each figure has that language's own empty-program cost (\`bench/cases/startup\`, ${STARTBASE}) subtracted, because dyld and runtime init differ per language and are a fifth of C's \`allocflat\` row. Every other table is raw."
  echo "> Reproducibility was measured rather than assumed (#4040): four independent regenerations of this table on this box held every ratio to 2.5% between adjacent runs and 8.5% at worst across all four. The loose rows are \`alloc\`, \`map\`, \`allocflat\` and \`strings\`, whose Go or C side is short enough that that language's own allocator and collector scheduling moves it by several percent from run to run; \`matrix\`, \`mandelbrot\`, \`fib\` and \`sort\` reproduce to about 1%. On those four loose rows, read a change under ~3% as noise."
  echo "> Instructions are published beside cycles because a cycle gap alone does not say whether it is work emitted or work stalled, and the two ratios differ a lot here: Bit retires roughly 4-7 instructions per cycle against C's 1.4-1.8, so its instruction ratio always overstates its cycle ratio. Cycles are the time; instructions are the reason."
  echo "> Generated by \`bench/run.sh\` on ${STAMP}. Do not edit by hand."
} > "$md"

# --- inject into README between markers ---
awk -v f="$md" '
  /<!-- BENCH:START -->/{print; while((getline line < f)>0) print line; skip=1; next}
  /<!-- BENCH:END -->/{skip=0}
  !skip
' README.md > "$WORK/README.md" && mv "$WORK/README.md" README.md
cp "$md" bench/RESULTS.md

# --- append history.csv ---
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

echo
cat "$md"
echo
echo "Wrote README.md, bench/RESULTS.md, appended $hist."
