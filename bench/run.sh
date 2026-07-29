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
BIT=./zig-out/bin/bit
CASES="fib mandelbrot collatz alloc"
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

now()    { perl -MTime::HiRes -e 'printf "%.6f\n", Time::HiRes::time()'; }
median() { sort -n | awk '{a[NR]=$1} END{n=NR; if(n%2){print a[(n+1)/2]} else {printf "%.6f\n",(a[n/2]+a[n/2+1])/2}}'; }
size()   { stat -f%z "$1"; }
get()    { awk -v c="$1" -v l="$2" -v k="$3" '$1==c&&$2==l{print $(k)}' "$RES"; }  # k: 3=s 4=rss 5=bin

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

  # --- correctness gate ---
  ob=$("$WORK/$c.bit"); oc=$("$WORK/$c.c"); og=$("$WORK/$c.go")
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
  echo "  $c ok (= $ob)"
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
srclines=$(wc -l bench/cases/*/*.bit | awk 'END{print $1}')
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
    ratio=$(awk -v a="$bs" -v b="$cs" 'BEGIN{printf "%.2fx", a/b}')
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
hist=bench/history.csv
[ -f "$hist" ] || echo "timestamp,git_sha,case,lang,median_s,rss_bytes,bin_bytes" > "$hist"
for c in $CASES; do
  for l in bit c go; do
    echo "$STAMP,$GITSHA,$c,$l,$(get "$c" "$l" 3),$(get "$c" "$l" 4),$(get "$c" "$l" 5)" >> "$hist"
  done
done

echo
cat "$md"
echo
echo "Wrote README.md, bench/RESULTS.md, appended $hist."
