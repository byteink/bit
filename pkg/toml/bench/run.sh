#!/usr/bin/env bash
# pkg/toml's parse-throughput comparison against BurntSushi/toml and
# go-toml/v2 (#5488), published in ../README.md between the BENCH markers.
#
#   ./pkg/toml/bench/run.sh                ship, build, verify, measure, publish
#   ./pkg/toml/bench/run.sh --verify-only   build + verify agreement, stop before timing
#   ./pkg/toml/bench/run.sh --report        re-render from out/ as it stands, no rebuild
#
# ONE MACHINE, NOT TWO SCRIPTS. Unlike pkg/web/bench (HTTP servers, needs an
# x86-64 Linux host), everything here is a CLI that parses one file: pkg/toml
# builds locally with this checkout's own ./bit-out/bin/bit, and the two Go
# competitors are cross-compiled for this host's OS/arch (GOOS/GOARCH) inside
# a throwaway `docker run`, never installed on this machine (CLAUDE.md's
# machine-hygiene rule) and never run FROM inside the container: a Linux
# binary timed through Docker Desktop's VM would carry that VM's overhead
# into a number compared against pkg/toml's native process, so both
# competitors are built as native binaries for the host running this script
# and executed exactly like pkg/toml's - same OS, same scheduler, same `time`.
#
# EXCLUSIVE (per the epic and #5488's own ticket): dispatch this alone, with
# nothing else running. Waiting behind boxlock's `solo` costs the whole box.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)      # pkg/toml/bench
PKG=$(cd "$HERE/.." && pwd)              # pkg/toml
REPO=$(cd "$HERE/../../.." && pwd)       # repo root
BIT=${BIT:-$REPO/bit-out/bin/bit}
# Same env var name and same default tag as pkg/yaml/bench/run.sh (#5559):
# two sibling harnesses publishing Go-comparison numbers on two different Go
# toolchains cannot be read against each other.
GO_IMAGE=${BENCH_GO_IMAGE:-golang:1.25}
FIXTURE=$HERE/data/fixture.toml
RUNS=15                                  # timed runs per side; see trimmean() below
MODE=${1:-full}

[ -x "$BIT" ] || { echo "$BIT not built (run: ./make selfhost in $REPO)" >&2; exit 1; }
[ -f "$FIXTURE" ] || { echo "$FIXTURE missing - checked-in fixture, never generated at run time" >&2; exit 1; }
command -v docker >/dev/null || { echo "docker not found on PATH" >&2; exit 1; }

HOST_GOOS=darwin
HOST_GOARCH=arm64
case "$(uname -s)" in Linux) HOST_GOOS=linux ;; esac
case "$(uname -m)" in x86_64) HOST_GOARCH=amd64 ;; esac

# Outside the repo tree on purpose (#5559): Go writes module-cache files
# mode 0444, and a cache under $HERE survives into `git worktree remove`
# which then fails with Permission denied. BENCH_CACHE_DIR overrides it;
# the default lives under $TMPDIR, per-package so pkg/yaml/bench's own
# cache (same default base) never collides with this one.
CACHE_DIR=${BENCH_CACHE_DIR:-${TMPDIR:-/tmp}/bit-bench-gomod/toml}
mkdir -p "$HERE/out/bin" "$CACHE_DIR/go" "$CACHE_DIR/gomod"

say() { printf '%s\n' "$*"; }

# ---------------------------------------------------------------- build

build_bit() {
  # Written here and not committed (bench/.gitignore): the path is this
  # box's, not the repo's - the same convention pkg/web/bench/remote.sh
  # uses for its own apps/bit/{bit.json,bit.lock}.
  printf '{"name": "tomlbench", "dependencies": {"toml": "%s"}}\n' "$PKG" > "$HERE/apps/bit/bit.json"
  printf '{"toml": {"path": "%s", "requires": {}}}\n' "$PKG" > "$HERE/apps/bit/bit.lock"
  BIT_REPO="$REPO" "$BIT" build "$HERE/apps/bit/main.bit" -o "$HERE/out/bin/bitbench"
}

# build_go <dir> <out-name>. Pinned, not `go get ... @latest` (#5559):
# pkg/web/bench/apps/gin/go.mod's bare-go.mod precedent was considered and
# rejected here, in favour of matching pkg/yaml/bench (#5501), which already
# committed go.mod + go.sum pinning its two competitors - two sibling
# harnesses need one policy, and a published figure that cannot be
# reproduced next month is worse than no figure. GOFLAGS=-mod=readonly so a
# `go.{mod,sum}` drifted from its committed pin fails loudly instead of
# silently rewriting itself.
build_go() {
  local dir=$1 out=$2
  docker run --rm \
    -v "$HERE/apps/$dir:/src" \
    -v "$CACHE_DIR/go:/gocache" -v "$CACHE_DIR/gomod:/gomod" \
    -w /src -e GOCACHE=/gocache -e GOMODCACHE=/gomod -e GOFLAGS=-mod=readonly \
    -e GOOS="$HOST_GOOS" -e GOARCH="$HOST_GOARCH" -e CGO_ENABLED=0 \
    "$GO_IMAGE" go build -o "/src/$out" .
  cp "$HERE/apps/$dir/$out" "$HERE/out/bin/$out"
}

# Reads the pinned version straight out of the committed go.mod - the same
# value `go build` just built against, not a value resolved separately that
# could drift from it.
pinned_version() {
  awk '/^require /{print $3}' "$HERE/apps/$1/go.mod"
}

# ---------------------------------------------------------------- verify

# Runs `<binary> checksum <fixture>` for all three sides and aborts, named,
# on the first disagreement - pkg/web/bench/remote.sh's "prove identical
# responses before timing anything", the same guarantee for a parser instead
# of an HTTP server: a throughput number from two parsers that disagree
# measures nothing.
verify() {
  local out_bit out_bs out_gt
  out_bit=$("$HERE/out/bin/bitbench" checksum "$FIXTURE")
  out_bs=$("$HERE/out/bin/burntsushibench" checksum "$FIXTURE")
  out_gt=$("$HERE/out/bin/gotomlbench" checksum "$FIXTURE")
  say "bit:        $out_bit"
  say "burntsushi: $out_bs"
  say "go-toml/v2: $out_gt"
  if [ "$out_bit" != "$out_bs" ] || [ "$out_bit" != "$out_gt" ]; then
    echo "toml bench: checksum mismatch - the three parsers disagree on $FIXTURE, refusing to time anything" >&2
    exit 1
  fi
  say "checksums agree: $out_bit"
}

# ---------------------------------------------------------------- measure

# Runs $@ once under /usr/bin/time -l, echoes "<real_seconds> <max_rss_bytes>".
# Mirrors bench/run.sh's own time_run() (repo root, #4040) exactly, minus the
# cycles/instructions columns that harness reads from the same -l output:
# those come from Apple's hardware counters and have no Linux equivalent, so
# a cross-arch report here would compare numbers /usr/bin/time -l never
# meant to be compared. MB/s and peak RSS (the ticket's own two figures)
# need neither.
time_run() {
  local tmp
  tmp=$(mktemp "${TMPDIR:-/tmp}/t5488-time.XXXXXX")
  /usr/bin/time -l "$@" >/dev/null 2>"$tmp"
  awk '/ real/{r=$1} /maximum resident set size/{m=$1} END{print r, m}' "$tmp"
  rm -f "$tmp"
}

median() { sort -n | awk '{a[NR]=$1} END{n=NR; if(n%2){print a[(n+1)/2]} else {printf "%.6f\n",(a[n/2]+a[n/2+1])/2}}'; }

# Trimmed mean - the mean of the samples left after dropping the slowest
# fifth. Same estimator and the same reasoning bench/run.sh:34-59 (repo
# root, #4040) settled on after comparing four: a plain minimum is the worst
# of the four against a box that is not perfectly idle, and RUNS=15 is where
# that harness's own p95 spread flattens out.
trimmean() { sort -n | awk '{a[NR]=$1} END{k=int(NR/5); if(k<1)k=1; n=NR-k;
                            for(i=1;i<=n;i++)s+=a[i]; printf "%.6f", s/n}'; }

measure_one() {
  local name=$1 bin=$2
  : > "$HERE/out/$name.rs"; : > "$HERE/out/$name.ms"
  local i=0
  while [ "$i" -lt "$RUNS" ]; do
    set -- $(time_run "$bin" parse "$FIXTURE")
    echo "$1" >> "$HERE/out/$name.rs"
    echo "$2" >> "$HERE/out/$name.ms"
    i=$((i+1))
  done
}

measure() {
  say "Measuring ($RUNS runs each)..."
  measure_one bit "$HERE/out/bin/bitbench"
  measure_one burntsushi "$HERE/out/bin/burntsushibench"
  measure_one gotoml "$HERE/out/bin/gotomlbench"
}

# ---------------------------------------------------------------- render

publish() {
  local commit stamp bitver goversion host bsver gtver
  commit=$(git -C "$REPO" rev-parse --short=8 HEAD 2>/dev/null || echo "?")
  stamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  bitver=$("$BIT" --version 2>&1)
  goversion=$(docker run --rm "$GO_IMAGE" go version 2>&1)
  host=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || uname -m)
  bsver=$(pinned_version burntsushi)
  gtver=$(pinned_version gotoml)
  local md=$HERE/out/block.md
  python3 "$HERE/report.py" "$HERE/out" "$FIXTURE" "$commit" "$stamp" "$bitver" "$goversion" "$host" "$RUNS" "$bsver" "$gtver" > "$md"
  python3 - "$PKG/README.md" "$md" <<'PY'
import sys
readme, block = sys.argv[1], sys.argv[2]
begin, end = "<!-- BENCH:START -->", "<!-- BENCH:END -->"
text = open(readme).read()
body = open(block).read().rstrip("\n")
if begin not in text or end not in text:
    sys.exit("pkg/toml/README.md has no %s / %s pair to write into" % (begin, end))
head, rest = text.split(begin, 1)
_, tail = rest.split(end, 1)
open(readme, "w").write("%s%s\n%s\n%s%s" % (head, begin, body, end, tail))
PY
  cp "$md" "$HERE/RESULTS.md"
  say "wrote $PKG/README.md and $HERE/RESULTS.md"
}

# ---------------------------------------------------------------- main

case $MODE in
  --report)
    publish
    ;;
  --verify-only)
    build_bit
    build_go burntsushi burntsushibench
    build_go gotoml gotomlbench
    verify
    say "verify-only: stopping before the timed measurement"
    ;;
  full|"")
    build_bit
    build_go burntsushi burntsushibench
    build_go gotoml gotomlbench
    verify
    measure
    publish
    ;;
  *)
    echo "usage: $0 [--verify-only|--report]" >&2
    exit 1
    ;;
esac
