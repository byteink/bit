#!/usr/bin/env bash
# Bit language benchmark harness.
#
# Builds each case in Bit, Go and C, verifies they compute the same result, then
# measures runtime (median wall-clock + peak RSS), binary size, process startup,
# and Bit compile speed. Writes results into README.md (between the BENCH
# markers), a standalone bench/RESULTS.md, and an appended bench/history.csv.
#
# No external tools: timing uses /usr/bin/time and perl's Time::HiRes, both of
# which ship with macOS. Requires `go` and `cc` on PATH. Runs on stock bash 3.2.
set -euo pipefail

cd "$(dirname "$0")/.."          # repo root
BIT=./bit-out/bin/bit
CASES="fib mandelbrot collatz alloc allocflat strings map sort matrix json"
RUNS=7                           # timed runs per case; median reported
CRUNS=3                          # compile-time samples per case; median reported
STARTUP_ITERS=200                # exec count for startup timing
CFLAGS="-O2 -ffp-contract=off"   # -ffp-contract=off: match strict IEEE (see README)

command -v go >/dev/null || { echo "go not found on PATH" >&2; exit 1; }
command -v cc >/dev/null || { echo "cc not found on PATH" >&2; exit 1; }
[ -x "$BIT" ] || { echo "$BIT not built (run: ./make)" >&2; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
RES="$WORK/res"      # lines: "<case> <lang> <median_s> <rss_bytes> <bin_bytes>"
: > "$RES"
ALC="$WORK/alc"      # lines: "<case> <lang> <heap_allocations_per_run>"
: > "$ALC"

now()    { perl -MTime::HiRes -e 'printf "%.6f\n", Time::HiRes::time()'; }
median() { sort -n | awk '{a[NR]=$1} END{n=NR; if(n%2){print a[(n+1)/2]} else {printf "%.6f\n",(a[n/2]+a[n/2+1])/2}}'; }
size()   { stat -f%z "$1"; }
get()    { awk -v c="$1" -v l="$2" -v k="$3" '$1==c&&$2==l{print $(k)}' "$RES"; }  # k: 3=s 4=rss 5=bin
alc()    { awk -v c="$1" -v l="$2" '$1==c&&$2==l{print $3}' "$ALC"; }
alcmd()  { n=$(alc "$1" "$2"); [ -n "$n" ] && echo "$n" || echo "—"; }

# Heap allocations one run of a case performs, per language — the number that
# proves the three sources still express the SAME data structure (#3934: the
# Bit side of `alloc` silently became a slice of inline values while the Go and
# C sides kept allocating per node, and the row compared them for a day). Bit
# reports it from the runtime (BIT_GC_STATS, every case); Go and C report it
# only where the source opts in (see bench/cases/alloc/alloc.go's
# `reportAllocs` and alloc.c's BENCH_ALLOC_STATS), and print "—" otherwise.
bit_allocs() { awk '{for(i=1;i<=NF;i++){if($i~/^swept=/){s=substr($i,7)}
                     if($i~/^live=/){l=substr($i,6)}}}
                END{if(s!="")print s+l}' "$1"; }
tag_allocs() { awk '/^\[allocs\]/{print $2}' "$1"; }

# Runs $@ once under /usr/bin/time -l, echoes "<real_seconds> <max_rss_bytes>".
time_run() {
  /usr/bin/time -l "$@" >/dev/null 2>"$WORK/t"
  awk '/ real/{r=$1} /maximum resident set size/{m=$1} END{print r, m}' "$WORK/t"
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
    : > "$WORK/rs"; : > "$WORK/ms"
    i=0; while [ "$i" -lt "$RUNS" ]; do
      set -- $(time_run "$WORK/$c.$l"); echo "$1" >> "$WORK/rs"; echo "$2" >> "$WORK/ms"
      i=$((i+1))
    done
    echo "$c $l $(median < "$WORK/rs") $(median < "$WORK/ms") $(size "$WORK/$c.$l")" >> "$RES"
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

md="$WORK/results.md"
{
  echo "_Full method and caveats below the tables._"
  echo
  echo "### Runtime — median wall-clock, lower is better"
  echo
  echo "| Benchmark | Bit | Go | C | Bit / C |"
  echo "|---|--:|--:|--:|--:|"
  for c in $CASES; do
    bs=$(get "$c" bit 3); cs=$(get "$c" c 3); gs=$(get "$c" go 3)
    # /usr/bin/time reports two decimals, so a C median can legitimately be
    # 0.00 (allocflat's C side is ~10ms) — print no ratio rather than dying on
    # the division, which is what this harness did the first time a case got
    # that fast.
    ratio=$(awk -v a="$bs" -v b="$cs" 'BEGIN{if(b+0==0){printf "—"}else{printf "%.2fx", a/b}}')
    echo "| $c | $(secs "$bs")s | $(secs "$gs")s | $(secs "$cs")s | $ratio |"
  done
  echo
  echo "### Peak memory — max RSS, lower is better"
  echo
  echo "| Benchmark | Bit | Go | C |"
  echo "|---|--:|--:|--:|"
  for c in $CASES; do
    echo "| $c | $(mb "$(get "$c" bit 4)") MB | $(mb "$(get "$c" go 4)") MB | $(mb "$(get "$c" c 4)") MB |"
  done
  echo
  echo "### Heap allocations per run — the equivalence check, not a score"
  echo
  echo "| Benchmark | Bit | Go | C |"
  echo "|---|--:|--:|--:|"
  for c in $CASES; do
    echo "| $c | $(alcmd "$c" bit) | $(alcmd "$c" go) | $(alcmd "$c" c) |"
  done
  echo
  echo "### Binary size — static, as emitted"
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
  echo "> Method: median of ${RUNS} runs. C built \`cc ${CFLAGS}\`, Go \`go build\`, Bit \`bit build\` — each language's standard optimized build."
  echo "> Mandelbrot: Bit and C agree to the last bit; Go differs by ~0.0002% because it contracts \`a*b+c\` to a hardware FMA. Not a bug — cross-compiler float bit-identity is not guaranteed."
  echo "> alloc measures the ALLOCATOR: 10M short-lived nodes, each its own heap object in all three languages (Bit's element class has a reference field, Go holds \`[]*Node\`, C mallocs per node). allocflat measures DATA LAYOUT: the same 10M nodes and the same printed total, stored by value in one buffer per batch (Bit packs \`[]Node\` inline since #3862, Go holds \`[]Node\`, C mallocs the batch once). The gap between the two rows is what per-node heap allocation costs a language."
  echo "> The allocation table above is how those two claims are checked rather than asserted — same order of magnitude across a row means the three sources still express the same data structure, which is exactly what \`alloc\` silently lost for a day (#3934). Bit's count is \`swept+live\` from \`BIT_GC_STATS=1\`; Go's is \`runtime.MemStats.Mallocs\` and C's a \`malloc\` counter, both opt-in (\`BENCH_ALLOC_STATS\`, \`-DBENCH_ALLOC_STATS\`) and both absent from every timed binary."
  echo "> Wall clock comes from \`/usr/bin/time\`, which reports hundredths of a second, so a row whose C side runs in ~10ms (allocflat) has a coarse Bit/C ratio and prints none at all when that median lands on 0.00. The allocation table and the per-language times carry such a row; the ratio column does not."
  echo "> Generated by \`bench/run.sh\` on ${STAMP} — do not edit by hand."
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
hist=bench/history.csv
[ -f "$hist" ] || echo "timestamp,git_sha,case,lang,median_s,rss_bytes,bin_bytes,alloc_count" > "$hist"
for c in $CASES; do
  for l in bit c go; do
    echo "$STAMP,$GITSHA,$c,$l,$(get "$c" "$l" 3),$(get "$c" "$l" 4),$(get "$c" "$l" 5),$(alc "$c" "$l")" >> "$hist"
  done
done

echo
cat "$md"
echo
echo "Wrote README.md, bench/RESULTS.md, appended $hist."
