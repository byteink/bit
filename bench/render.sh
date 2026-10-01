# Rendering half of bench/run.sh, sourced by it. Turns the last recorded
# measurement (bench/last-run.dat, written by every measured run) into the
# short README block and the complete bench/RESULTS.md. `bench/run.sh --render`
# runs only this half, so the README can be rebuilt without re-measuring.
#
# The README block is for a reader who wants the verdict in ten seconds:
# one sentence, one plain table, two lines on memory and size, the machine and
# the date, and a link. Every table and every method paragraph that used to
# sit there lives in bench/RESULTS.md, unchanged in substance.
#
# Needs from the caller: $CASES, $RUNS, $WORK, $RES $ALC $GCRES $APW (empty
# files under $WORK). Runs on stock bash 3.2 and BSD awk.

DATA=${BENCH_DATA:-bench/last-run.dat}
BANNED='cycles|instructions retired|rss|trimmed mean|quantis|stw|startup-corrected'

get()    { awk -v c="$1" -v l="$2" -v k="$3" '$1==c&&$2==l{print $(k)}' "$RES"; }  # k: 3=s 4=rss 5=bin 6=cyc 7=instr
alc()    { awk -v c="$1" -v l="$2" '$1==c&&$2==l{print $3}' "$ALC"; }
alcmd()  { n=$(alc "$1" "$2"); [ -n "$n" ] && echo "$n" || echo "n/a"; }
apwget() { awk -v c="$1" -v l="$2" '$1==c&&$2==l{print $3}' "$APW"; }                       # <case>_W<n> lang -> wall ms
gcget()  { awk -v c="$1" -v l="$2" -v k="$3" '$1==c&&$2==l{print $(k)}' "$GCRES"; }  # k: 3=count/pauses 4=ms 5=maxms 6=share

ms1()  { awk -v x="$1" 'BEGIN{printf "%.1f", x*1000}'; }  # seconds (from $RES col 3) -> ms, one decimal
mb()   { awk -v x="$1" 'BEGIN{printf "%.1f", x/1048576}'; }
kb()   { awk -v x="$1" 'BEGIN{printf "%.0f", x/1024}'; }
mil()  { awk -v x="$1" 'BEGIN{printf "%.1f", x/1000000}'; }
ratio()  { awk -v a="$1" -v b="$2" 'BEGIN{if(b+0<=0){printf "n/a"}else{printf "%.2fx", a/b}}'; }
# $DATA stores the startup-corrected counters (the process total minus that
# language's own empty-program floor, clamped at 1 so no ratio divides by
# zero), so rendering reads them as they are.
cyc()    { get "$1" "$2" 6; }
ins()    { get "$1" "$2" 7; }
metaget() { awk -v k="$1" '$1=="meta"&&$2==k{sub(/^meta [^ ]+ /,""); print}' "$DATA"; }

# One <tag> line group of $DATA into one of the working files, tag stripped.
slice() { awk -v t="$1" '$1==t{sub(/^[^ ]+ /,""); print}' "$DATA" > "$2"; }
loadData() {
  [ -s "$DATA" ] || { echo "$DATA missing: run bench/run.sh once to record a measurement" >&2; exit 1; }
  slice res "$RES"; slice alc "$ALC"; slice gc "$GCRES"; slice apw "$APW"; slice start "$WORK/start"
  GITSHA=$(metaget sha); STAMP=$(metaget stamp); CPU=$(metaget machine); OSV=$(metaget os)
  GOV=$(metaget go); CCV=$(metaget cc); STARTBASE=$(metaget startbase)
  lps=$(metaget lps); srclines=$(metaget srclines); comp_n=$(metaget ncases)
}
sms() { awk -v l="$1" '$1==l{print $2}' "$WORK/start"; }

# What each case exercises, in six plain words or fewer.
describe() {
  case "$1" in
    fib) echo "function calls" ;;
    mandelbrot) echo "floating point math" ;;
    collatz) echo "integer loops and branches" ;;
    alloc) echo "many small heap objects" ;;
    allocflat) echo "many objects in one buffer" ;;
    allocpar) echo "heap objects on 8 threads" ;;
    strings) echo "building and slicing strings" ;;
    map) echo "hash map with number keys" ;;
    strmap) echo "hash map with string keys" ;;
    sort) echo "sorting numbers and strings" ;;
    matrix) echo "matrix multiplication" ;;
    json) echo "JSON parse and walk" ;;
    *) echo "$1" ;;
  esac
}

# Reads "case<TAB>what<TAB>bit<TAB>go<TAB>c" rows (the Bit, Go and C CPU costs)
# and prints, per $1: `table` the sorted plain table, `summary` the sentence.
plain() {
  awk -F'\t' -v mode="$1" '
    function phrase(r) {
      if (r <= 0) return "n/a"
      if (r >= 0.95 && r <= 1.05) return "about the same"
      if (r > 1) return sprintf("%.1fx slower", r)
      return sprintf("%.1fx faster", 1 / r)
    }
    function tally(r, k) {
      if (r <= 0) return
      if (r < 0.95) fast[k]++
      else if (r <= 1.05) same[k]++
      else { slow[k]++; if (r > worst[k]) worst[k] = r }
    }
    function slowtail(k) {
      if (slow[k] > 0) return sprintf(" and slower on %d (up to %.1fx slower)", slow[k], worst[k])
      return ""
    }
    { n++; name[n] = $1; what[n] = $2
      rg[n] = ($4 > 0) ? $3 / $4 : 0; rc[n] = ($5 > 0) ? $3 / $5 : 0
      tally(rg[n], "go"); tally(rc[n], "c") }
    END {
      if (mode == "summary") {
        printf "Bit is faster than Go on %d of %d benchmarks, about the same on %d%s; against C it is faster on %d, about the same on %d%s.\n", \
               fast["go"], n, same["go"], slowtail("go"), fast["c"], same["c"], slowtail("c")
        exit
      }
      for (i = 1; i <= n; i++) idx[i] = i
      for (i = 2; i <= n; i++) {            # insertion sort, best Bit/Go first
        j = i
        while (j > 1 && rg[idx[j - 1]] > rg[idx[j]]) { t = idx[j]; idx[j] = idx[j - 1]; idx[j - 1] = t; j-- }
      }
      print "| Benchmark | What it tests | vs Go | vs C |"
      print "|---|---|--:|--:|"
      for (i = 1; i <= n; i++) { k = idx[i]; printf "| %s | %s | %s | %s |\n", name[k], what[k], phrase(rg[k]), phrase(rc[k]) }
    }'
}

# median of the numbers on stdin
med() { sort -n | awk '{a[NR]=$1} END{n=NR; if(n%2){print a[(n+1)/2]} else {print (a[n/2]+a[n/2+1])/2}}'; }
# "340 KB" below one MB, "2.4 MB" above
size_words() { awk -v b="$1" 'BEGIN{if(b>=1048576){printf "%.1f MB", b/1048576}else{printf "%.0f KB", b/1024}}'; }

# The README block: exactly the five things the owner asked for.
readmeBlock() {
  local rows c lang mem less n=0 same
  rows=""
  for c in $CASES; do
    rows="${rows}${c}	$(describe "$c")	$(cyc "$c" bit)	$(cyc "$c" go)	$(cyc "$c" c)
"
  done
  printf '%s' "$rows" > "$WORK/plainrows"
  plain summary < "$WORK/plainrows"
  echo
  plain table < "$WORK/plainrows"
  echo
  # Memory: how often Bit is under Go, and the typical run of each language.
  less=0
  for c in $CASES; do
    n=$((n+1))
    less=$((less + $(awk -v b="$(get "$c" bit 4)" -v g="$(get "$c" go 4)" 'BEGIN{print (b < g*0.95) ? 1 : 0}')))
  done
  local mb_bit mb_go mb_c
  for lang in bit go c; do
    eval "mb_$lang=\$(for c in \$CASES; do get \"\$c\" $lang 4; done | med)"
  done
  echo "Memory: Bit uses less than Go on ${less} of ${n} benchmarks. A typical run takes $(mb "$mb_bit") MB in Bit, $(mb "$mb_go") MB in Go and $(mb "$mb_c") MB in C."
  echo
  local b_bit b_go b_c
  for lang in bit go c; do
    eval "b_$lang=\$(for c in \$CASES; do get \"\$c\" $lang 5; done | med)"
  done
  echo "Program size: about $(size_words "$b_bit") in Bit, $(size_words "$b_go") in Go and $(size_words "$b_c") in C."
  echo
  echo "Measured on ${CPU}, macOS ${OSV}, on ${STAMP%%T*}."
  echo
  echo "Full numbers and method: [bench/RESULTS.md](bench/RESULTS.md)"
}

# U+2014 spelled as bytes, so no locale or grep wrapper changes the match.
hasEmDash() { LC_ALL=C command grep -q -F "$(printf '\342\200\224')" "$1"; }

# The banned jargon and the em dash stay out of the README block. Fails the
# render, before any file is written, when one appears.
assertPlain() {
  local hit
  hit=$(grep -E -i -o "$BANNED" "$1" | head -1 || true)
  [ -z "$hit" ] || { echo "render: banned word '$hit' in the README block" >&2; exit 1; }
  ! hasEmDash "$1" || { echo "render: em dash in generated prose" >&2; exit 1; }
}

# --- peak-RSS reproducibility across regenerations (#4199) ------------------
# The RSS this table publishes is already a MEDIAN of ${RUNS} in-process
# samples, but #4068 found that median itself can swing between SEPARATE
# regenerations -- Go's `strings` RSS was reported at "68.9-122 MB across
# runs", which a single run's own ${RUNS} samples cannot show. history.csv is
# the record of every regeneration this repo has ever committed, so it is
# read here rather than re-measured.
#
# Scoped to the SAME four rows #4040 already flagged as noisy on the cycle
# ratios (alloc, map, allocflat, strings) and to the go/c columns only. The
# bit column is deliberately excluded: it legitimately swings across real
# compiler/runtime changes over that history window (`strings` bit's own RSS
# fell 952MB -> 131MB as the allocator improved, a 7x move with no bug and no
# noise in it), and folding that into a noise disclosure would misreport a
# real fix as instability.
rssHistSpread() {  # case lang -> "min median max N" in MB, or empty if N<5
  awk -F, -v c="$1" -v l="$2" '$3==c && $4==l && $6!="" {print $6}' "$hist" \
    | sort -n | awk '{a[NR]=$1} END{
        if (NR<5) exit 0
        med = (NR%2) ? a[(NR+1)/2] : (a[NR/2]+a[NR/2+1])/2
        printf "%.1f %.1f %.1f %d", a[1]/1048576, med/1048576, a[NR]/1048576, NR
      }'
}
rssNote() {
  local c l s rlo rmed rhi rn unstable
  RSSNOTE=""
  for c in alloc map allocflat strings; do
    for l in go c; do
      s=$(rssHistSpread "$c" "$l")
      [ -n "$s" ] || continue
      set -- $s
      rlo=$1; rmed=$2; rhi=$3; rn=$4
      # >10%, same order of magnitude as #4040's "read a change under ~3% as
      # noise" for the loose cycle rows, scaled up for a cruder cross-run signal.
      unstable=$(awk -v a="$rhi" -v b="$rlo" 'BEGIN{print (a > b*1.10) ? 1 : 0}')
      [ "$unstable" = 1 ] && RSSNOTE="${RSSNOTE}${RSSNOTE:+; }\`$c\` $l: ${rlo}-${rhi} MB (median ${rmed} MB, N=${rn})"
    done
  done
  return 0
}

# The complete reference: every table and every method paragraph.
fullResults() {
  echo "# Benchmark results: full numbers and method"
  echo
  echo "The README carries the short version. This page keeps every table and the method behind it."
  echo
  echo "### Runtime: CPU cycles, lower is better"
  echo
  echo "| Benchmark | Bit | Go | C | Bit / Go | Bit / C |"
  echo "|---|--:|--:|--:|--:|--:|"
  for c in $CASES; do
    bcy=$(cyc "$c" bit); gcy=$(cyc "$c" go); ccy=$(cyc "$c" c)
    echo "| $c | $(mil "$bcy") M | $(mil "$gcy") M | $(mil "$ccy") M |" \
         "$(ratio "$bcy" "$gcy") | $(ratio "$bcy" "$ccy") |"
  done
  echo
  echo "### Instructions retired: work emitted, not time taken"
  echo
  echo "| Benchmark | Bit | Go | C |"
  echo "|---|--:|--:|--:|"
  for c in $CASES; do
    echo "| $c | $(mil "$(ins "$c" bit)") M | $(mil "$(ins "$c" go)") M | $(mil "$(ins "$c" c)") M |"
  done
  echo
  echo "### Wall clock: median of ${RUNS} runs, milliseconds"
  echo
  echo "| Benchmark | Bit | Go | C |"
  echo "|---|--:|--:|--:|"
  for c in $CASES; do
    echo "| $c | $(ms1 "$(get "$c" bit 3)") ms | $(ms1 "$(get "$c" go 3)") ms | $(ms1 "$(get "$c" c 3)") ms |"
  done
  for w in 1 8; do
    echo "| allocpar W$w | $(apwget "allocpar_W$w" bit) ms | $(apwget "allocpar_W$w" go) ms | $(apwget "allocpar_W$w" c) ms |"
  done
  echo
  echo "### GC pauses: one untimed run per case, share of that run's own wall clock"
  echo
  echo "| Benchmark | Bit pauses | Bit pausens ms (share) | Bit pausemax ms | Go GCs | Go STW ms (share) | Go STW max ms | C |"
  echo "|---|--:|--:|--:|--:|--:|--:|--:|"
  for c in $CASES; do
    bp=$(gcget "$c" bit 3); bms=$(gcget "$c" bit 4); bmax=$(gcget "$c" bit 5); bsh=$(gcget "$c" bit 6)
    gp=$(gcget "$c" go 3);  gms=$(gcget "$c" go 4);  gmax=$(gcget "$c" go 5);  gsh=$(gcget "$c" go 6)
    echo "| $c | $bp | $bms ms ($bsh) | $bmax ms | $gp | $gms ms ($gsh) | $gmax ms | n/a |"
  done
  for w in 1 8; do
    bp=$(gcget "allocpar_W$w" bit 3); bms=$(gcget "allocpar_W$w" bit 4)
    bmax=$(gcget "allocpar_W$w" bit 5); bsh=$(gcget "allocpar_W$w" bit 6)
    gp=$(gcget "allocpar_W$w" go 3);  gms=$(gcget "allocpar_W$w" go 4)
    gmax=$(gcget "allocpar_W$w" go 5);  gsh=$(gcget "allocpar_W$w" go 6)
    echo "| allocpar W$w | $bp | $bms ms ($bsh) | $bmax ms | $gp | $gms ms ($gsh) | $gmax ms | n/a |"
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
  echo "> Machine: ${CPU}, macOS ${OSV}. Bit @ \`${GITSHA}\`, Go ${GOV}, ${CCV}."
  echo "> Method: ${RUNS} runs per case per language. Cycles and instructions are a trimmed mean of those runs, meaning the mean after dropping the slowest fifth, which was the most reproducible of four estimators measured over 40 samples per series; wall clock and RSS are the median. C built \`cc ${CFLAGS}\`, Go \`go build\`, Bit \`bit build\`, each language's standard optimized build."
  echo "> Mandelbrot: Bit and C agree to the last bit; Go differs by ~0.0002% because it contracts \`a*b+c\` to a hardware FMA. Not a bug: cross-compiler float bit-identity is not guaranteed."
  echo "> alloc measures the ALLOCATOR: 10M short-lived nodes, each its own heap object in all three languages (Bit's element class has a reference field, Go holds \`[]*Node\`, C mallocs per node). allocflat measures DATA LAYOUT: the same 10M nodes and the same printed total, stored by value in one buffer per batch (Bit packs \`[]Node\` inline, Go holds \`[]Node\`, C mallocs the batch once). The gap between the two rows is what per-node heap allocation costs a language."
  echo "> allocpar measures the allocator under CONTENTION: the identical 10M nodes and the identical printed total as alloc, partitioned across 8 concurrent workers (Bit \`spawn\`, Go goroutines, C pthreads), worker count fixed in all three sources and never read from the host core count. The gap between the alloc and allocpar rows is what a language's allocator costs when more than one thread is in it; every other case in this table is single-mutator, so that cost appears nowhere else."
  echo "> The allocation table above is how those two claims are checked rather than asserted: same order of magnitude across a row means the three sources still express the same data structure, which is exactly what \`alloc\` silently lost for a day. Bit's count is \`swept+live\` from \`BIT_GC_STATS=1\`; Go's is \`runtime.MemStats.Mallocs\` and C's a \`malloc\` counter, both opt-in (\`BENCH_ALLOC_STATS\`, \`-DBENCH_ALLOC_STATS\`) and both absent from every timed binary."
  echo "> The ratios are built from CYCLES, not from wall clock. \`/usr/bin/time\` reports \`real\` in hundredths of a second and most of the C sides here finish in under 0.10s, so a wall-clock ratio for those rows would be quantisation: \`map\` published 7.50x C off 0.300s/0.040s where the counters say ~4.5x. Adding runs does not fix that, because it narrows the spread around a quantised value instead of removing the quantisation, so the unit changed. Cycles and instructions come from the same \`/usr/bin/time -l\` invocation that also produced the RSS; nothing extra is run and nothing extra is installed for those three. Wall clock is a separate one-decimal-millisecond measurement (\`wall_run()\`, one \`fork\`+\`exec\`+\`waitpid\` perl process per run, not \`/usr/bin/time\`'s own field) so it stays usable below \`/usr/bin/time\`'s 10ms floor; it still carries no ratio column and is kept as context."
  echo "> GC pauses: one untimed run per case, separate from the timed runs above (BIT_GC_STATS/GODEBUG both add real overhead). Bit's fields are \`pausens=\`/\`pausemaxns=\`/\`pauses=\` from \`BIT_GC_STATS=1\`. Go's are parsed from one \`GODEBUG=gctrace=1\` run: each \`gc N @Ts P%: A+B+C ms clock\` line's A (sweep termination) and C (mark termination) are its two STW segments (\`go doc runtime\`, go1.27.1), summed for the STW total, maxed individually for the longest single pause; B (concurrent mark) is not a stop and is excluded. C has no collector (n/a). Share is that probe run's own \`wall_run()\` wall time, not the timed loop's median. \`allocpar W1\`/\`W8\` reruns the same probe with \`BIT_WORKERS\`/\`GOMAXPROCS\` set; C is unchanged (its worker count is a compile-time \`#define\`, never read from env) so its wall-table cell reuses the baseline \`allocpar\` row rather than a redundant rerun."
  echo "> Cycles and instructions are startup-corrected: each figure has that language's own empty-program cost (\`bench/cases/startup\`, ${STARTBASE}) subtracted, because dyld and runtime init differ per language and are a fifth of C's \`allocflat\` row. Every other table is raw."
  echo
  echo "> On \`matrix\`, read the Go column as the target and not the C one. The C side vectorises: it retires 2.06 instructions per inner-loop iteration against Go's 9.09, so the Bit:C ratio on this row compares a scalar loop against a vectorised one and is not a statement about codegen quality. A scalar \`cc -O2 -fno-vectorize\` control build of the same case retires 8.07, which is the like-for-like figure. Denominator for all three: \`trials * n^3 = 6 * 512^3 = 805,306,368\` inner iterations."
  echo "> Reproducibility was measured rather than assumed: four independent regenerations of this table on this box held every ratio to 2.5% between adjacent runs and 8.5% at worst across all four. The loose rows are \`alloc\`, \`map\`, \`allocflat\` and \`strings\`, whose Go or C side is short enough that that language's own allocator and collector scheduling moves it by several percent from run to run; \`matrix\`, \`mandelbrot\`, \`fib\` and \`sort\` reproduce to about 1%. On those four loose rows, read a change under ~3% as noise."
  if [ -n "${RSSNOTE}" ]; then
    echo "> Peak RSS above is a within-run median like every other figure in that table, but it can still swing further ACROSS separate regenerations than one run shows. From every regeneration recorded in \`bench/history.csv\`, restricted to the same four loose rows above and to the Go/C columns (the Bit column reflects real compiler/runtime changes over that history, not noise): ${RSSNOTE}. Read that cell's published number as representative of the stated range, not a fixed constant."
  fi
  echo "> Instructions are published beside cycles because a cycle gap alone does not say whether it is work emitted or work stalled, and the two ratios differ a lot here: Bit retires roughly 4-7 instructions per cycle against C's 1.4-1.8, so its instruction ratio always overstates its cycle ratio. Cycles are the time; instructions are the reason."
  echo "> Generated by \`bench/run.sh\` on ${STAMP}. Do not edit by hand."
}

# Rebuilds the README block and bench/RESULTS.md from $DATA. The block is
# checked for banned words before either file is touched.
renderAll() {
  loadData
  hist=bench/history.csv
  rssNote
  readmeBlock > "$WORK/block.md"
  assertPlain "$WORK/block.md"
  fullResults > "$WORK/results.new"
  ! hasEmDash "$WORK/results.new" || { echo "render: em dash in bench/RESULTS.md" >&2; exit 1; }
  awk -v f="$WORK/block.md" '
    /<!-- BENCH:START -->/{print; while((getline line < f)>0) print line; skip=1; next}
    /<!-- BENCH:END -->/{skip=0}
    !skip
  ' README.md > "$WORK/README.new" && mv "$WORK/README.new" README.md
  cp "$WORK/results.new" bench/RESULTS.md
  echo "Wrote README.md and bench/RESULTS.md from $DATA."
}
