#!/usr/bin/env bash
# pkg/toml's parse-throughput comparison against BurntSushi/toml and
# go-toml/v2 (#5488), published in ../README.md between the BENCH markers.
#
#   ./pkg/toml/bench/run.sh                ship, build, verify, measure, publish
#   ./pkg/toml/bench/run.sh --verify-only   build + verify agreement, stop before timing
#   ./pkg/toml/bench/run.sh --report        record out/ as it stands into results.json, then render
#   ./pkg/toml/bench/run.sh --render        rebuild the README block and RESULTS.md from the
#                                           last recorded results.json: no build, no docker, no timing
#   ./pkg/toml/bench/run.sh --measure       build, verify, time every peer on both
#                                           fixtures, print the tables; publishes nothing
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
# Render-only (#6438): needs nothing but python3, so it runs before every
# check below that wants a compiler, docker or a built out/.
if [ "${1:-}" = --render ]; then
  exec python3 "$HERE/report.py" render "$HERE/results.json" "$PKG/README.md" "$HERE/RESULTS.md"
fi
BIT=${BIT:-$(command -v bit || true)}
# The RELEASED toolchain, not this checkout's ./bit-out/bin/bit. A package
# bench is a published claim about software a user installs, and that user has
# the release - so the release is what the table has to measure. The repo's own
# bench/run.sh is the opposite case and correctly builds from the tree: it
# measures the language being tagged. pkg/web/bench/remote.sh already works this
# way, pinning a ghcr image (#5623). Set BIT= to measure a dev build on purpose.
if [ -z "${BIT}" ]; then
  echo "bench: no 'bit' on PATH. Install the release (brew install byteink/tap/bit)" >&2
  echo "       or set BIT=<path> to measure a specific compiler." >&2
  exit 1
fi
# A dev build reports 0.1.0-dev, a hardcoded placeholder ./make never stamps.
# Publishing that against pinned competitor versions is what #5658 fixed; refuse
# rather than let it reach the table again.
_bitver=$("$BIT" --version 2>&1 | head -1)
case "${1:-full}:${_bitver}" in
  --measure:*|--verify-only:*) ;;  # print only, never reach the published table
  *-dev*)
    echo "bench: ${BIT} reports '${_bitver}' - a development build." >&2
    echo "       The published table must name a release. Use the released bit," >&2
    echo "       or set BIT= deliberately and do not commit the result." >&2
    exit 1 ;;
esac
# Same env var name and same default tag as pkg/yaml/bench/run.sh (#5559):
# two sibling harnesses publishing Go-comparison numbers on two different Go
# toolchains cannot be read against each other.
GO_IMAGE=${BENCH_GO_IMAGE:-golang:1.25}
FIXTURE=$HERE/data/fixture.toml
# The second fixture (#6048): many small tables, escape-dense long strings,
# big number arrays. Generated once by data/gen_config.py and checked in.
FIXTURES="$FIXTURE $HERE/data/config.toml"
# Every non-Go peer is cross-compiled for this host by zig inside this image
# (it carries zig and a macOS SDK) and run natively, like the Go ones. The
# Rust toolchain is rustup's current stable, installed into the cache inside
# the container, never on the host.
ZB_IMAGE=${BENCH_ZB_IMAGE:-ghcr.io/rust-cross/cargo-zigbuild:latest}
TOMLPP_TAG=v3.4.0
TOMLC17_TAG=R260821
# name:binary, pkg/toml first; every loop below walks this list.
SIDES="bit:bitbench burntsushi:burntsushibench gotoml:gotomlbench rusttoml:tomlbench tomledit:tomleditbench tomlpp:tomlppbench tomlc17:tomlc17bench"
RUNS=15                                  # timed runs per side; see trimmean() below
MODE=${1:-full}

[ -x "$BIT" ] || { echo "$BIT not built (run: ./make selfhost in $REPO)" >&2; exit 1; }
for f in $FIXTURES; do
  [ -f "$f" ] || { echo "$f missing - checked-in fixture, never generated at run time" >&2; exit 1; }
done
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
mkdir -p "$HERE/out/bin" "$CACHE_DIR/go" "$CACHE_DIR/gomod" "$CACHE_DIR/zb"

say() { printf '%s\n' "$*"; }

# ---------------------------------------------------------------- build

build_bit() {
  # Written here and not committed (bench/.gitignore): the path is this
  # box's, not the repo's - the same convention pkg/web/bench/remote.sh
  # uses for its own apps/bit/{bit.json,bit.lock}.
  printf '{"name": "tomlbench", "dependencies": {"toml": "%s"}}\n' "$PKG" > "$HERE/apps/bit/bit.json"
  printf '{"toml": {"path": "%s", "requires": {}}}\n' "$PKG" > "$HERE/apps/bit/bit.lock"
  BIT_REPO="$REPO" BIT_STDLIB="$REPO/stdlib" "$BIT" build "$HERE/apps/bit/main.bit" -o "$HERE/out/bin/bitbench"
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

zig_target() {
  case "$HOST_GOOS:$HOST_GOARCH" in
    darwin:arm64) echo aarch64-macos ;; darwin:amd64) echo x86_64-macos ;;
    linux:arm64) echo aarch64-linux-gnu ;; *) echo x86_64-linux-gnu ;;
  esac
}

rust_target() {
  case "$HOST_GOOS:$HOST_GOARCH" in
    darwin:arm64) echo aarch64-apple-darwin ;; darwin:amd64) echo x86_64-apple-darwin ;;
    linux:arm64) echo aarch64-unknown-linux-gnu ;; *) echo x86_64-unknown-linux-gnu ;;
  esac
}

# Both Rust sides from one crate (apps/rust), Cargo.lock committed and
# --locked, the same no-drift rule as the Go sides' GOFLAGS=-mod=readonly.
# The target dir stays inside the container: rustc's archive writer fails
# with EFAULT on a Docker Desktop bind mount.
build_rust() {
  local t
  t=$(rust_target)
  docker run --rm -v "$HERE/apps/rust:/src" -v "$CACHE_DIR/zb:/cache" -w /src \
    -v "$CACHE_DIR/zb/registry:/usr/local/cargo/registry" \
    -e RUSTUP_HOME=/cache/rustup -e CARGO_TARGET_DIR=/tmp/target \
    "$ZB_IMAGE" sh -c "set -e
      rustup toolchain install stable --profile minimal --target $t >/dev/null 2>&1
      rustup run stable rustc --version > /cache/rustc.version
      cargo +stable zigbuild --release --locked --target $t
      cp /tmp/target/$t/release/tomlbench /tmp/target/$t/release/tomleditbench /cache/"
  cp "$CACHE_DIR/zb/tomlbench" "$CACHE_DIR/zb/tomleditbench" "$HERE/out/bin/"
}

# build_zig <app dir> <out> <zig subcommand and flags...>: the app's own
# source plus its library, fetched at the pinned tag into the cache.
build_zig() {
  local dir=$1 out=$2
  shift 2
  docker run --rm -v "$HERE/apps/$dir:/src:ro" -v "$CACHE_DIR/zb:/cache" -w /cache \
    "$ZB_IMAGE" sh -c "set -e
      mkdir -p lib/tomlpp lib/tomlc17
      [ -f lib/tomlpp/toml.hpp ] || curl -fsSL -o lib/tomlpp/toml.hpp \
        https://raw.githubusercontent.com/marzer/tomlplusplus/$TOMLPP_TAG/toml.hpp
      for f in tomlc17.c tomlc17.h; do [ -f lib/tomlc17/\$f ] || curl -fsSL -o lib/tomlc17/\$f \
        https://raw.githubusercontent.com/cktan/tomlc17/$TOMLC17_TAG/src/\$f; done
      zig version > zig.version
      zig $* -target $(zig_target) -O3 -o /cache/$out"
  cp "$CACHE_DIR/zb/$out" "$HERE/out/bin/$out"
}

build_all() {
  build_bit
  build_go burntsushi burntsushibench
  build_go gotoml gotomlbench
  build_rust
  build_zig tomlpp tomlppbench c++ -std=c++17 -Wno-nullability-completeness -Wno-deprecated-literal-operator -I lib/tomlpp /src/main.cpp
  build_zig tomlc17 tomlc17bench cc -std=c17 -I lib/tomlc17 /src/main.c lib/tomlc17/tomlc17.c
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
  local f side name bin out ref
  : > "$HERE/out/verify.txt"
  for f in $FIXTURES; do
    ref=""
    for side in $SIDES; do
      name=${side%%:*}; bin=${side#*:}
      out=$("$HERE/out/bin/$bin" checksum "$f")
      say "$(basename "$f") $name: $out" | tee -a "$HERE/out/verify.txt"
      [ -n "$ref" ] || ref=$out
      if [ "$out" != "$ref" ]; then
        echo "toml bench: checksum mismatch - $name disagrees with pkg/toml on $f, refusing to time anything" >&2
        exit 1
      fi
    done
    say "$(basename "$f"): every side agrees: $ref" | tee -a "$HERE/out/verify.txt"
  done
}

# ---------------------------------------------------------------- measure

# Runs $@ once, echoes "<real_seconds> <max_rss_bytes>". NOT /usr/bin/time:
# macOS prints its real time to two decimals, a 10 ms quantum, and these
# parses take 3-30 ms - the fastest peer read 0.00 (#6048). perf_counter_ns
# around the spawn and wait4's rusage for the same child give sub-microsecond
# wall time and the kernel's own peak RSS (bytes on macOS) in one call.
time_run() {
  python3 -c 'import os, subprocess, sys, time
t = time.perf_counter_ns()
p = subprocess.Popen(sys.argv[1:], stdout=subprocess.DEVNULL)
_, st, ru = os.wait4(p.pid, 0)
e = time.perf_counter_ns() - t
if st != 0:
    sys.exit("time_run: %s exited with status %d" % (sys.argv[1], st))
print("%.6f %d" % (e / 1e9, ru.ru_maxrss))' "$@"
}

median() { sort -n | awk '{a[NR]=$1} END{n=NR; if(n%2){print a[(n+1)/2]} else {printf "%.6f\n",(a[n/2]+a[n/2+1])/2}}'; }

# Trimmed mean - the mean of the samples left after dropping the slowest
# fifth. Same estimator and the same reasoning bench/run.sh:34-59 (repo
# root, #4040) settled on after comparing four: a plain minimum is the worst
# of the four against a box that is not perfectly idle, and RUNS=15 is where
# that harness's own p95 spread flattens out.
trimmean() { sort -n | awk '{a[NR]=$1} END{k=int(NR/5); if(k<1)k=1; n=NR-k;
                            for(i=1;i<=n;i++)s+=a[i]; printf "%.6f", s/n}'; }

# Round-robin, not one block per side: run i of every side happens before
# run i+1 of any, so drift in the box's state lands on every side alike
# instead of on whichever side ran last. The first fixture keeps writing
# out/<name>.{rs,ms}, the files --report reads.
measure_fixture() {
  local f=$1 dir=$2 side name bin i=0
  mkdir -p "$dir"
  for side in $SIDES; do : > "$dir/${side%%:*}.rs"; : > "$dir/${side%%:*}.ms"; done
  while [ "$i" -lt "$RUNS" ]; do
    for side in $SIDES; do
      name=${side%%:*}; bin=${side#*:}
      set -- $(time_run "$HERE/out/bin/$bin" parse "$f")
      echo "$1" >> "$dir/$name.rs"
      echo "$2" >> "$dir/$name.ms"
    done
    i=$((i+1))
  done
}

# The empty document is the control: process start, runtime init, reading a
# file and exit, with nothing to parse. Subtracting it leaves the parse.
measure() {
  say "Measuring ($RUNS runs each, round-robin)..."
  : > "$HERE/out/empty.toml"
  measure_fixture "$HERE/out/empty.toml" "$HERE/out/empty"
  measure_fixture "$FIXTURE" "$HERE/out"
  measure_fixture "$HERE/data/config.toml" "$HERE/out/config"
}

# One table per fixture, trimmed means throughout: whole-process MB/s, the
# same net of the empty-document control, peak RSS, and each side's net
# MB/s as a ratio to the fastest side's. Printed, never written anywhere.
table() {
  local f=$1 dir=$2 side name bytes
  bytes=$(wc -c < "$f" | tr -d ' ')
  for side in $SIDES; do
    name=${side%%:*}
    printf '%s %s %s %s\n' "$name" "$(trimmean < "$dir/$name.rs")" \
      "$(trimmean < "$dir/$name.ms")" "$(trimmean < "$HERE/out/empty/$name.rs")"
  done | awk -v b="$bytes" -v fx="$(basename "$f")" '
    { n[NR]=$1; t[NR]=$2; rss[NR]=$3/1048576; e[NR]=$4; net[NR]=b/1e6/($2-$4)
      if (net[NR]>best) best=net[NR] }
    END { printf "%s (%d bytes)\n| side | ms | empty ms | MB/s | net MB/s | peak RSS MB | net vs fastest |\n|---|--:|--:|--:|--:|--:|--:|\n", fx, b
          for (i=1;i<=NR;i++) printf "| %s | %.2f | %.2f | %.1f | %.1f | %.1f | %.2fx |\n",
            n[i], t[i]*1e3, e[i]*1e3, b/1e6/t[i], net[i], rss[i], net[i]/best }'
}

# ---------------------------------------------------------------- render

# Version of crate $1 as locked in apps/rust/Cargo.lock (the build is --locked).
crate_version() {
  sed -n "/^name = \"$1\"\$/{n;s/^version = \"\([^+\"]*\).*/\1/p;}" "$HERE/apps/rust/Cargo.lock"
}

# Records out/ into results.json, then renders the README block and
# RESULTS.md from it, exactly as --render does.
publish() {
  local commit stamp bitver goversion host tools
  commit=$(git -C "$REPO" rev-parse --short=8 HEAD 2>/dev/null || echo "?")
  stamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  bitver=$("$BIT" --version 2>&1)
  goversion=$(docker run --rm "$GO_IMAGE" go version 2>&1)
  host=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || uname -m)
  tools="BurntSushi/toml $(pinned_version burntsushi), go-toml/v2 $(pinned_version gotoml), Rust toml $(crate_version toml), toml_edit $(crate_version toml_edit), toml++ $TOMLPP_TAG, tomlc17 $TOMLC17_TAG"
  python3 "$HERE/report.py" record "$HERE/out" "$HERE/results.json" "$commit" "$stamp" "$bitver" "$goversion" "$host" "$RUNS" "$tools"
  python3 "$HERE/report.py" render "$HERE/results.json" "$PKG/README.md" "$HERE/RESULTS.md"
  say "wrote $PKG/README.md, $HERE/RESULTS.md and $HERE/results.json"
}

# ---------------------------------------------------------------- main

case $MODE in
  --report)
    publish
    ;;
  --verify-only)
    build_all
    verify
    say "verify-only: stopping before the timed measurement"
    ;;
  --measure)
    build_all
    verify
    measure
    table "$FIXTURE" "$HERE/out"
    table "$HERE/data/config.toml" "$HERE/out/config"
    ;;
  full|"")
    build_all
    verify
    measure
    publish
    ;;
  *)
    echo "usage: $0 [--verify-only|--measure|--report|--render]" >&2
    exit 1
    ;;
esac
