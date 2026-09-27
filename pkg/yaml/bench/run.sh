#!/usr/bin/env bash
# pkg/yaml's parse-throughput comparison (#5501, widened by #6049) against
# go.yaml.in/yaml/v3 and github.com/goccy/go-yaml (Go), libyaml (C),
# rapidyaml (C++, in-place and arena modes), saphyr and yaml-rust2 (Rust), on
# two fixtures: data/k8s-manifests.yaml and data/yaml-features.yaml.
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
# NOR IS ANY C, C++ OR RUST TOOLCHAIN (#6049). The four native competitors
# are cross-compiled for the host the same way, inside one throwaway
# cargo-zigbuild container: `zig cc`/`zig c++` for libyaml and rapidyaml,
# `cargo zigbuild` (zig as the linker) for the two Rust crates. Sources are
# fetched at build time from their official release, pinned by sha256.
#
#   ./pkg/yaml/bench/run.sh              build, verify, measure, publish
#   ./pkg/yaml/bench/run.sh --verify     build + verify only, no timing
#   ./pkg/yaml/bench/run.sh --measure    build, verify, measure; publish nothing
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
BIT=${BIT:-$(command -v bit || true)}
# The RELEASED toolchain, not this checkout's ./bit-out/bin/bit. A package
# bench is a published claim about software a user installs, and that user has
# the release - so the release is what the table has to measure. The repo's own
# bench/run.sh is the opposite case and correctly builds from the tree: it
# measures the language being tagged. pkg/web/bench/remote.sh already works this
# way, pinning a ghcr image (#5623). Set BIT= to measure a dev build on purpose;
# --verify and --measure accept one, because they publish nothing.
if [ -z "${BIT}" ]; then
  echo "bench: no 'bit' on PATH. Install the release (brew install byteink/tap/bit)" >&2
  echo "       or set BIT=<path> to measure a specific compiler." >&2
  exit 1
fi
# A dev build reports 0.1.0-dev, a hardcoded placeholder ./make never stamps.
# Publishing that against pinned competitor versions is what #5658 fixed; refuse
# rather than let it reach the table again.
refuseDevBuild() {
  local v
  v=$("$BIT" --version 2>&1 | head -1)
  case "$v" in
    *-dev*)
      echo "bench: ${BIT} reports '$v' - a development build." >&2
      echo "       The published table must name a release. Use the released bit," >&2
      echo "       or run --measure, which publishes nothing." >&2
      exit 1 ;;
  esac
}
FIXTURES="k8s-manifests yaml-features"
IMPLS="bit yamlv3 goccy libyaml rapidyaml rapidyamlarena saphyr yamlrust2"
OUT=$HERE/out
BIN=$OUT/bin
# Same env var name and same default tag as pkg/toml/bench/run.sh (#5559):
# two sibling harnesses publishing Go-comparison numbers on two different Go
# toolchains cannot be read against each other.
GO_IMAGE=${BENCH_GO_IMAGE:-golang:1.25}
# zig (C, C++, and the Rust crates' linker) plus the macOS SDK. The Rust
# toolchain itself is installed per RUST_TOOLCHAIN into $CACHE, because the
# image's own rustc trails the stable release.
NATIVE_IMAGE=${BENCH_NATIVE_IMAGE:-ghcr.io/rust-cross/cargo-zigbuild:0.23.4}
RUST_TOOLCHAIN=${BENCH_RUST_TOOLCHAIN:-1.98.1}
LIBYAML_VERSION=0.2.5
LIBYAML_SHA256=c642ae9b75fee120b2d96c712538bd2cf283228d2337df2cf2988e3c02678ef4
RYML_VERSION=0.16.0
RYML_SHA256=0d0b8076174cf62f034406b03529fda542ebc9a17506d3bd6d949aedc4bfa6ab
RUNS=${BENCH_RUNS:-15}
MODE=${1:-full}

# Outside the repo tree on purpose (#5559): Go writes module-cache files
# mode 0444, and a cache under $OUT survives into `git worktree remove`
# which then fails with Permission denied. BENCH_CACHE_DIR overrides it;
# the default lives under $TMPDIR, per-package so pkg/toml/bench's own
# cache (same default base) never collides with this one.
CACHE=${BENCH_CACHE_DIR:-${TMPDIR:-/tmp}/bit-bench-gomod/yaml}
mkdir -p "$BIN" "$CACHE/gocache" "$CACHE/gomodcache" "$CACHE/native"

command -v docker >/dev/null || { echo "docker not found; required to cross-compile the competitors, because no Go, C, C++ or Rust toolchain is ever installed on this machine" >&2; exit 1; }
[ -x "$BIT" ] || { echo "$BIT not built (run: ./make selfhost)" >&2; exit 1; }
for fx in $FIXTURES; do
  [ -f "$HERE/data/$fx.yaml" ] || { echo "fixture missing: data/$fx.yaml (checked in, never generated at run time)" >&2; exit 1; }
done

hostGoos() { case "$(uname -s)" in Darwin) echo darwin ;; Linux) echo linux ;; *) echo "$(uname -s)" | tr '[:upper:]' '[:lower:]' ;; esac; }
hostGoarch() { case "$(uname -m)" in arm64|aarch64) echo arm64 ;; x86_64|amd64) echo amd64 ;; *) echo "$(uname -m)" ;; esac; }
HOST_GOOS=$(hostGoos)
HOST_GOARCH=$(hostGoarch)
HOST_ZIG="$([ "$HOST_GOARCH" = arm64 ] && echo aarch64 || echo x86_64)-$([ "$HOST_GOOS" = darwin ] && echo macos || echo linux-gnu)"
HOST_RUST="$([ "$HOST_GOARCH" = arm64 ] && echo aarch64 || echo x86_64)-$([ "$HOST_GOOS" = darwin ] && echo apple-darwin || echo unknown-linux-gnu)"

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

# Every native peer in one container. -O3 -DNDEBUG is CMake's Release, the
# build rapidyaml documents; the Rust crates use their own Cargo.toml's
# release profile (fat LTO, one codegen unit). A download whose sha256 does
# not match the pin fails the build instead of measuring unknown source.
# Two Docker Desktop bind-mount failures shape this (both seen here, #6049):
# a container-side cp between two bind-mounted paths produced a right-sized
# file of NUL bytes, and rustc died of SIGBUS mmapping rlibs from a
# bind-mounted target dir. So downloads land where they are used, cargo builds
# in the container's own /tmp, and only finished binaries cross the mount.
build_native() {
  local ma mi pa
  IFS=. read -r ma mi pa <<< "$LIBYAML_VERSION"
  docker run --rm \
    -v "$HERE:/w" -v "$CACHE/native:/cache" \
    -e RUSTUP_HOME=/cache/rustup -v "$CACHE/native/registry:/usr/local/cargo/registry" \
    -e CARGO_TARGET_DIR=/tmp/target -e ZIG_GLOBAL_CACHE_DIR=/cache/zig \
    "$NATIVE_IMAGE" bash -euo pipefail -c "
      fetch() { [ -f \"/cache/\$2\" ] || curl -fsSL --create-dirs -o \"/cache/\$2\" \"\$1\"
                echo \"\$3  /cache/\$2\" | sha256sum -c --quiet; }
      fetch https://pyyaml.org/download/libyaml/yaml-$LIBYAML_VERSION.tar.gz yaml-$LIBYAML_VERSION.tar.gz $LIBYAML_SHA256
      fetch https://github.com/biojppm/rapidyaml/releases/download/v$RYML_VERSION/rapidyaml.v$RYML_VERSION.singlehdr.hpp ryml-$RYML_VERSION/ryml.hpp $RYML_SHA256
      tar xzf /cache/yaml-$LIBYAML_VERSION.tar.gz -C /cache
      Y=/cache/yaml-$LIBYAML_VERSION
      zig cc -target $HOST_ZIG -O3 -DNDEBUG -DYAML_DECLARE_STATIC \
        -DYAML_VERSION_MAJOR=$ma -DYAML_VERSION_MINOR=$mi -DYAML_VERSION_PATCH=$pa -DYAML_VERSION_STRING='\"$LIBYAML_VERSION\"' \
        -I\$Y/include \$Y/src/*.c /w/apps/libyaml/main.c -o /w/out/bin/libyamlbench
      zig c++ -target $HOST_ZIG -std=c++17 -O3 -DNDEBUG -I/cache/ryml-$RYML_VERSION /w/apps/rapidyaml/main.cpp -o /w/out/bin/rapidyamlbench
      zig c++ -target $HOST_ZIG -std=c++17 -O3 -DNDEBUG -DBENCH_ARENA -I/cache/ryml-$RYML_VERSION /w/apps/rapidyaml/main.cpp -o /w/out/bin/rapidyamlarenabench
      rustup toolchain install $RUST_TOOLCHAIN --profile minimal --target $HOST_RUST >/dev/null
      for app in saphyr yamlrust2; do
        cargo +$RUST_TOOLCHAIN zigbuild --quiet --locked --release --target $HOST_RUST --manifest-path /w/apps/\$app/Cargo.toml
        cp /tmp/target/$HOST_RUST/release/\${app}bench /w/out/bin/\${app}bench
      done
      zig version > /w/out/zig.version
    "
}

goVersion() {
  docker run --rm "$GO_IMAGE" go version | awk '{print $3}'
}

# Reads the pinned version straight out of the committed go.mod - the same
# value `go build` just built against (#5559: name what was actually beaten).
pinnedVersion() {
  awk '/^require /{print $3}' "$HERE/apps/$1/go.mod"
}

# ---------------------------------------------------------------- verify

# Refuses to time anything until every implementation parses each fixture to
# the SAME "docs=<N> nodes=<N> crc=<u32>" line (#5501: "do not publish a
# number without first proving all sides parse the fixture to the same
# checksum").
verify() {
  local fx impl line ref bad=0
  : > "$OUT/verify.txt"
  for fx in $FIXTURES; do
    ref=""
    for impl in $IMPLS; do
      line=$("$BIN/${impl}bench" "$HERE/data/$fx.yaml")
      printf '%-15s %-15s %s\n' "$fx" "$impl:" "$line" | tee -a "$OUT/verify.txt"
      [ -z "$ref" ] && ref=$line
      [ "$line" = "$ref" ] || bad=1
    done
  done
  if [ "$bad" -ne 0 ]; then
    echo "pkg/yaml/bench: CHECKSUM MISMATCH - refusing to time a disagreement" >&2
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

# Runs $1 on fixture $2 once, echoes "<wall_seconds> <max_rss_bytes>".
# The wall time is perl's microsecond clock around fork, exec and wait of
# `/usr/bin/time -l`, NOT time's own "real" line: that line has 10 ms
# resolution, which quantized every sub-20 ms peer to the same 120.52 MB/s
# on a 1.2 MB fixture (#6049). time -l stays in the chain only for the peak
# RSS; its own exec and wait cost the same on every side.
time_run() {
  local wall
  wall=$(perl -MTime::HiRes=time -e '
    my ($bin, $data, $err) = @ARGV;
    my $t0 = time;
    my $pid = fork() // die "fork: $!";
    if ($pid == 0) {
      open(STDOUT, ">", "/dev/null") or die; open(STDERR, ">", $err) or die;
      exec("/usr/bin/time", "-l", $bin, $data) or exit 127;
    }
    waitpid($pid, 0);
    my $t1 = time;
    exit 1 if $? != 0;
    printf "%.6f\n", $t1 - $t0;' "$1" "$2" "$OUT/.time") || {
    echo "pkg/yaml/bench: $1 failed on $2" >&2; exit 1; }
  echo "$wall $(awk '/maximum resident set size/{print $1}' "$OUT/.time")"
}

measure() {
  local fx impl size i n order t r mbps rmb
  n=$(echo $IMPLS | wc -w)
  echo "fixture,impl,mbps,rss_mb" > "$OUT/results.csv"
  for fx in $FIXTURES; do
    for impl in $IMPLS; do
      : > "$OUT/$fx.$impl.rs"; : > "$OUT/$fx.$impl.ms"
    done
    i=0
    while [ "$i" -lt "$RUNS" ]; do
      # Rotate which implementation goes first each iteration (bench/run.sh's
      # #4398 fix): a box's speed drifts on a timescale of minutes, so running
      # all of one side's RUNS before the next attributes that drift to
      # whichever side happened to run in the noisy window instead of
      # spreading it evenly across all of them.
      order=$(echo $IMPLS $IMPLS | tr ' ' '\n' | tail -n +$((i % n + 1)) | head -n "$n")
      for impl in $order; do
        set -- $(time_run "$BIN/${impl}bench" "$HERE/data/$fx.yaml")
        echo "$1" >> "$OUT/$fx.$impl.rs"
        echo "$2" >> "$OUT/$fx.$impl.ms"
      done
      i=$((i+1))
    done
    size=$(stat -f%z "$HERE/data/$fx.yaml")
    for impl in $IMPLS; do
      t=$(trimmean < "$OUT/$fx.$impl.rs")
      r=$(trimmean < "$OUT/$fx.$impl.ms")
      mbps=$(awk -v s="$size" -v t="$t" 'BEGIN{printf "%.2f", s/t/1000000}')
      rmb=$(awk -v r="$r" 'BEGIN{printf "%.1f", r/1048576}')
      echo "$fx,$impl,$mbps,$rmb" >> "$OUT/results.csv"
    done
  done
}

# ---------------------------------------------------------------- render

# Reads the exact "=X.Y.Z" pin of crate $2 out of apps/$1/Cargo.toml.
cratePin() {
  sed -n "s/^$2 = \"=\(.*\)\"$/\1/p" "$HERE/apps/$1/Cargo.toml"
}

label() {
  case $1 in
    bit) echo "pkg/yaml" ;;
    yamlv3) echo "go.yaml.in/yaml/v3 (Go)" ;;
    goccy) echo "goccy/go-yaml (Go)" ;;
    libyaml) echo "libyaml (C)" ;;
    rapidyaml) echo "rapidyaml, in place (C++)" ;;
    rapidyamlarena) echo "rapidyaml, arena copy (C++)" ;;
    saphyr) echo "saphyr (Rust)" ;;
    yamlrust2) echo "yaml-rust2 (Rust)" ;;
  esac
}

render() {
  refuseDevBuild
  local sha bitver gover host impl fx cells
  sha=$(git -C "$REPO" rev-parse --short=8 HEAD 2>/dev/null || echo "?")
  bitver=$("$BIT" version 2>/dev/null || echo "?")
  gover=$(goVersion)
  host="$(sysctl -n machdep.cpu.brand_string 2>/dev/null || uname -m), macOS $(sw_vers -productVersion 2>/dev/null || uname -sr)"

  local md=$OUT/block.md
  {
    echo "## Benchmarks"
    echo
    echo "Parse throughput over two multi-document fixtures, one process per timed run, trimmed mean of ${RUNS} runs (see run.sh's \`trimmean\` for the estimator): \`bench/data/k8s-manifests.yaml\` ($(awk -v s="$(stat -f%z "$HERE/data/k8s-manifests.yaml")" 'BEGIN{printf "%.2f", s/1048576}') MiB, Kubernetes-manifest-shaped) and \`bench/data/yaml-features.yaml\` ($(awk -v s="$(stat -f%z "$HERE/data/yaml-features.yaml")" 'BEGIN{printf "%.2f", s/1048576}') MiB, anchors and aliases, block scalars, flow collections, escaped quoted scalars). Every implementation is proven to parse each fixture to the same document count, node count and CRC-32C checksum before anything is timed - see \`RESULTS.md\`'s verification transcript."
    echo
    echo "| Implementation | k8s MB/s | k8s peak RSS | features MB/s | features peak RSS |"
    echo "|---|--:|--:|--:|--:|"
    for impl in $IMPLS; do
      cells=""
      for fx in $FIXTURES; do
        cells="$cells$(awk -F, -v f="$fx" -v i="$impl" '$1==f && $2==i {printf " %s | %s MB |", $3, $4}' "$OUT/results.csv")"
      done
      echo "| $(label "$impl") |$cells"
    done
    echo
    echo "> pkg/yaml at \`${sha}\`, compiled by the released ${bitver}. Go ${gover}: go.yaml.in/yaml/v3 $(pinnedVersion yamlv3), goccy/go-yaml $(pinnedVersion goccy). libyaml ${LIBYAML_VERSION} and rapidyaml ${RYML_VERSION} by zig $(cat "$OUT/zig.version") at -O3. Rust ${RUST_TOOLCHAIN}: saphyr $(cratePin saphyr saphyr), yaml-rust2 $(cratePin yamlrust2 yaml-rust2). Host: ${host}."
    echo "> Every competitor is cross-compiled for this host (${HOST_GOOS}/${HOST_GOARCH}) inside a throwaway docker container (\`${GO_IMAGE}\` for Go, \`${NATIVE_IMAGE}\` for C, C++ and Rust) and then run NATIVELY on the host, timed by the same \`/usr/bin/time -l\` invocation as the Bit binary. No Go, C, C++ or Rust toolchain is installed on this machine."
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

build_all() {
  build_bit
  build_go yamlv3 yamlv3bench
  build_go goccy goccybench
  build_native
}

case $MODE in
  --report)
    ;;
  --verify)
    build_all
    verify
    echo "verify OK - no timing run performed (--verify)"
    exit 0
    ;;
  --measure)
    build_all
    verify
    measure
    cat "$OUT/results.csv"
    echo "measure OK - nothing published (--measure)"
    exit 0
    ;;
  *)
    refuseDevBuild
    build_all
    verify
    measure
    ;;
esac
render
