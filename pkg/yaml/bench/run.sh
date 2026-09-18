#!/usr/bin/env bash
# pkg/yaml's parse-throughput comparison against github.com/goccy/go-yaml and
# gopkg.in/yaml.v3 (#5501), both pure Go.
#
# Mirrors pkg/web/bench's shape (run.sh, RESULTS.md, a competitor tree under
# apps/, a table published into ../README.md between BENCH markers) and
# bench/run.sh's measurement method (trimmed mean over RUNS, interleaved
# execution order - see trimmean()/time_run() below for why).
#
# NO GO TOOLCHAIN IS EVER INSTALLED ON THIS MACHINE (#5501's own constraint).
# The two Go competitors are CROSS-COMPILED for the host OS/arch inside a
# throwaway `golang` docker container (CGO_ENABLED=0, both are pure Go), so
# the resulting binaries run NATIVELY on the host afterward - same measurement
# technique (/usr/bin/time -l) as the Bit binary, not a container-vs-bare-metal
# split the way pkg/web/bench's six HTTP servers are. `bit` itself is never
# containerized: it is built once by ./make selfhost, same as every other
# package gate.
#
#   ./pkg/yaml/bench/run.sh              build, verify, measure, publish
#   ./pkg/yaml/bench/run.sh --verify     build + verify only, no timing
#   ./pkg/yaml/bench/run.sh --report     re-render from out/ as it stands
#
# BENCH_RUNS overrides the run count (default 15, see trimmean()'s comment
# for why 15 is the floor this repo settled on). A run with BENCH_RUNS under
# 15 writes out/ and RESULTS.md exactly like a full run - nothing here
# refuses to run, so a short smoke run is real output, just not one this
# script would call representative; state the run count when quoting one.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)        # pkg/yaml/bench
PKG=$(cd "$HERE/.." && pwd)                # pkg/yaml
REPO=$(cd "$HERE/../../.." && pwd)         # repo root
BIT=${BIT:-$REPO/bit-out/bin/bit}
DATA=$HERE/data/k8s-manifests.yaml
OUT=$HERE/out
BIN=$OUT/bin
CACHE=$OUT/cache
GO_IMAGE=${BENCH_GO_IMAGE:-golang:1.27}
RUNS=${BENCH_RUNS:-15}
MODE=${1:-full}

mkdir -p "$BIN" "$CACHE/gocache" "$CACHE/gomodcache"

command -v docker >/dev/null || { echo "docker not found; required to cross-compile the Go competitors (#5501 forbids installing Go on this machine)" >&2; exit 1; }
[ -x "$BIT" ] || { echo "$BIT not built (run: ./make selfhost)" >&2; exit 1; }
[ -f "$DATA" ] || { echo "fixture missing: $DATA (checked in, never generated at run time)" >&2; exit 1; }

hostGoos() { case "$(uname -s)" in Darwin) echo darwin ;; Linux) echo linux ;; *) echo "$(uname -s)" | tr '[:upper:]' '[:lower:]' ;; esac; }
hostGoarch() { case "$(uname -m)" in arm64|aarch64) echo arm64 ;; x86_64|amd64) echo amd64 ;; *) echo "$(uname -m)" ;; esac; }
HOST_GOOS=$(hostGoos)
HOST_GOARCH=$(hostGoarch)

# ---------------------------------------------------------------- build

# The `yaml` import needs a bit.json local-path dependency naming THIS box's
# absolute path to pkg/yaml, so it cannot be committed (pkg/web/bench/remote.sh
# has the same note for its own bit.json). Regenerated every run.
build_bit() {
  ( cd "$HERE/apps/bit" \
    && rm -f bit.json bit.lock \
    && BIT_REPO="$REPO" "$BIT" init >/dev/null \
    && BIT_REPO="$REPO" "$BIT" add "$PKG" >/dev/null \
    && BIT_REPO="$REPO" BIT_STDLIB="$REPO/stdlib" "$BIT" build main.bit -o "$BIN/bitbench" )
}

# Cross-compiled for the HOST's OS/arch, not the container's: CGO_ENABLED=0
# and both libraries are pure Go, so the container never needs to execute
# anything it builds - go build alone, then the binary runs natively on the
# host afterward, timed the same way as the Bit binary.
build_go() {
  local dir=$1 out=$2
  docker run --rm \
    -v "$HERE:/w" -w "/w/apps/$dir" \
    -v "$CACHE/gocache:/gocache" -v "$CACHE/gomodcache:/gomodcache" \
    -e GOOS="$HOST_GOOS" -e GOARCH="$HOST_GOARCH" -e CGO_ENABLED=0 \
    -e GOCACHE=/gocache -e GOMODCACHE=/gomodcache \
    "$GO_IMAGE" go build -o "/w/out/bin/$out" .
}

goVersion() {
  docker run --rm "$GO_IMAGE" go version | awk '{print $3}'
}

# ---------------------------------------------------------------- verify

# Refuses to time anything until all three sides parse the fixture to the
# SAME "docs=<N> nodes=<N> crc=<u32>" line (#5501: "do not publish a number
# without first proving all sides parse the fixture to the same checksum").
verify() {
  local ob ov og
  ob=$("$BIN/bitbench" "$DATA")
  ov=$("$BIN/yamlv3bench" "$DATA")
  og=$("$BIN/goccybench" "$DATA")
  {
    echo "bit:      $ob"
    echo "yaml.v3:  $ov"
    echo "goccy:    $og"
  } | tee "$OUT/verify.txt"
  if [ "$ob" != "$ov" ] || [ "$ob" != "$og" ]; then
    echo "pkg/yaml/bench: CHECKSUM MISMATCH - refusing to time a disagreement" >&2
    echo "  bit:     $ob" >&2
    echo "  yaml.v3: $ov" >&2
    echo "  goccy:   $og" >&2
    exit 1
  fi
}

# ---------------------------------------------------------------- measure

now()    { perl -MTime::HiRes -e 'printf "%.6f\n", Time::HiRes::time()'; }
# Trimmed mean: the mean after dropping the slowest fifth of RUNS samples.
# Same estimator and the same reasoning bench/run.sh:51-66 settled on after
# comparing four candidates over 40 samples per series - the minimum is the
# most tempting alternative ("contention can only inflate a counter") and
# measured worst there, because it reports whichever run happened to dodge
# scheduling noise rather than the steady-state cost. RUNS=15 leaves 12
# samples after the trim, the point bench/run.sh found the spread flattens.
trimmean() { sort -n | awk '{a[NR]=$1} END{k=int(NR/5); if(k<1)k=1; n=NR-k;
                            for(i=1;i<=n;i++)s+=a[i]; printf "%.6f", s/n}'; }

# Runs $1 once under /usr/bin/time -l, echoes "<real_seconds> <max_rss_bytes>".
time_run() {
  /usr/bin/time -l "$1" "$DATA" >/dev/null 2>"$OUT/.time"
  awk '/ real/{r=$1} /maximum resident set size/{m=$1} END{print r, m}' "$OUT/.time"
}

measure() {
  local size
  size=$(stat -f%z "$DATA")
  for impl in bit yamlv3 goccy; do
    : > "$OUT/rs.$impl"; : > "$OUT/ms.$impl"
  done
  local i=0
  while [ "$i" -lt "$RUNS" ]; do
    # Rotate which implementation goes first each iteration (bench/run.sh's
    # #4398 fix): a box's speed drifts on a timescale of minutes, so running
    # all of one side's RUNS before the next attributes that drift to
    # whichever side happened to run in the noisy window instead of
    # spreading it evenly across all three.
    case $((i % 3)) in
      0) order="bit yamlv3 goccy" ;;
      1) order="yamlv3 goccy bit" ;;
      *) order="goccy bit yamlv3" ;;
    esac
    for impl in $order; do
      set -- $(time_run "$BIN/${impl}bench")
      echo "$1" >> "$OUT/rs.$impl"
      echo "$2" >> "$OUT/ms.$impl"
    done
    i=$((i+1))
  done
  {
    echo "impl,mbps,rss_mb"
    for impl in bit yamlv3 goccy; do
      local t r mbps rmb
      t=$(trimmean < "$OUT/rs.$impl")
      r=$(trimmean < "$OUT/ms.$impl")
      mbps=$(awk -v s="$size" -v t="$t" 'BEGIN{printf "%.2f", s/t/1000000}')
      rmb=$(awk -v r="$r" 'BEGIN{printf "%.1f", r/1048576}')
      echo "$impl,$mbps,$rmb"
    done
  } > "$OUT/results.csv"
}

# ---------------------------------------------------------------- render

render() {
  local sha bitver gover host fsize
  sha=$(git -C "$REPO" rev-parse --short=8 HEAD 2>/dev/null || echo "?")
  bitver=$("$BIT" version 2>/dev/null || echo "?")
  gover=$(goVersion)
  host="$(sysctl -n machdep.cpu.brand_string 2>/dev/null || uname -m), macOS $(sw_vers -productVersion 2>/dev/null || uname -sr)"
  fsize=$(stat -f%z "$DATA")

  local md=$OUT/block.md
  {
    echo "## Benchmarks"
    echo
    echo "Parse throughput over \`bench/data/k8s-manifests.yaml\` ($(awk -v s="$fsize" 'BEGIN{printf "%.2f", s/1048576}') MiB, multi-document Kubernetes-manifest-shaped YAML), one process per timed run, trimmed mean of ${RUNS} runs (see run.sh's \`trimmean\` for the estimator). Every implementation is proven to parse the fixture to the same document count, node count and CRC-32C checksum before anything is timed - see \`RESULTS.md\`'s verification transcript."
    echo
    echo "| Implementation | MB/s | Peak RSS |"
    echo "|---|--:|--:|"
    tail -n +2 "$OUT/results.csv" | while IFS=, read -r impl mbps rss; do
      case $impl in
        bit) label="pkg/yaml" ;;
        yamlv3) label="gopkg.in/yaml.v3" ;;
        goccy) label="goccy/go-yaml" ;;
      esac
      echo "| $label | $mbps | ${rss} MB |"
    done
    echo
    echo "> Bit \`${sha}\` (\`bit version\`: ${bitver}), Go ${gover}, host: ${host}."
    echo "> The two Go competitors are cross-compiled for this host (${HOST_GOOS}/${HOST_GOARCH}) inside a throwaway \`${GO_IMAGE}\` docker container - CGO_ENABLED=0, both are pure Go - and then run NATIVELY on the host, timed by the same \`/usr/bin/time -l\` invocation as the Bit binary. Go itself is never installed on this machine."
    echo "> Generated by \`pkg/yaml/bench/run.sh\` on $(date -u +%Y-%m-%dT%H:%M:%SZ). Do not edit by hand."
  } > "$md"

  awk -v f="$md" '
    /<!-- BENCH:START -->/{print; while((getline line < f)>0) print line; skip=1; next}
    /<!-- BENCH:END -->/{skip=0}
    !skip
  ' "$PKG/README.md" > "$OUT/README.md.tmp" || {
    echo "pkg/yaml/README.md has no BENCH:START/BENCH:END pair to write into" >&2; exit 1; }
  mv "$OUT/README.md.tmp" "$PKG/README.md"

  {
    cat "$md"
    echo
    echo "## Verification, exactly as it ran"
    echo
    echo '```'
    cat "$OUT/verify.txt"
    echo '```'
  } > "$HERE/RESULTS.md"
  echo "wrote pkg/yaml/README.md and pkg/yaml/bench/RESULTS.md"
}

case $MODE in
  --report)
    ;;
  --verify)
    build_bit
    build_go yamlv3 yamlv3bench
    build_go goccy goccybench
    verify
    echo "verify OK - no timing run performed (--verify)"
    exit 0
    ;;
  *)
    build_bit
    build_go yamlv3 yamlv3bench
    build_go goccy goccybench
    verify
    measure
    ;;
esac
render
