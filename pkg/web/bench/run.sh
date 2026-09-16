#!/usr/bin/env bash
# pkg/web's framework benchmark, driven from a developer machine (#5418).
#
# WHY THIS IS TWO SCRIPTS. gin, express, bun, Spring Boot and ASP.NET are
# compared against pkg/web under Linux containers, which a Mac cannot host
# natively; remote.sh is the half that runs on the Linux box. This half ships
# the tree there, calls it, brings the results back, and writes them into
# ../README.md between the BENCH markers.
#
# THE BLOCK IS GENERATED, NEVER HAND-EDITED, the same contract bench/run.sh
# holds for the language benchmarks: the block says so itself, and the next
# run of this script overwrites whatever is between the markers.
#
#   ./pkg/web/bench/run.sh              ship, build, measure, publish
#   ./pkg/web/bench/run.sh --reuse      measure against the tree already there
#   ./pkg/web/bench/run.sh --fetch      pull the box's last results, then publish
#   ./pkg/web/bench/run.sh --report     re-render from out/ as it stands here
#
# --report renders whatever is in out/ WITHOUT going to the box, so it will
# happily republish a stale or partial results.csv. Use --fetch after a run
# that was started by hand over there.
#
# Environment: BIT_X64_HOST and friends, resolved by scripts/x64host.sh.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)     # pkg/web/bench
PKG=$(cd "$HERE/.." && pwd)             # pkg/web
REPO=$(cd "$HERE/../../.." && pwd)      # repo root
REMOTE_DIR=${BENCH_REMOTE_DIR:-t5418-web-bench}
MODE=${1:-full}

host=$(sh "$REPO/scripts/x64host.sh") || {
  echo "no x86-64 Linux host configured; see scripts/x64host.sh" >&2; exit 1; }

ship() {
  local tgz
  tgz=$(mktemp "${TMPDIR:-/tmp}/t5418-ship.XXXXXX.tgz")
  # COPYFILE_DISABLE and the ._ sweep: macOS AppleDouble sidecars travel inside
  # a tar and `._aspnet.csproj` is a second project file as far as MSBuild is
  # concerned, which fails the .NET build with MSB1011.
  ( cd "$PKG/.." && COPYFILE_DISABLE=1 tar czf "$tgz" --exclude='web/bench/out' web ) 2>/dev/null
  ssh "$host" "mkdir -p ~/$REMOTE_DIR" < /dev/null
  scp -q "$tgz" "$host:~/$REMOTE_DIR/ship.tgz"
  # out/ carries the go, npm, maven and nuget caches and the built servers, so
  # it survives the wipe; everything else is replaced outright rather than
  # merged, which is how a deleted source file stops being built over there.
  ssh "$host" "set -e; cd ~/$REMOTE_DIR
    rm -rf out.keep && if [ -d web/bench/out ]; then mv web/bench/out out.keep; fi
    rm -rf web && tar xzf ship.tgz && rm ship.tgz
    if [ -d out.keep ]; then mv out.keep web/bench/out; fi
    find web -name '._*' -delete
    chmod +x web/bench/remote.sh" < /dev/null
  rm -f "$tgz"
}

# --reuse skips the ship as well as the build, and has to: the shipped tree
# replaces web/ outright, which takes express's node_modules with it.
measure() {
  local stage=all
  [ "$MODE" != --reuse ] || stage=run
  ssh "$host" "cd ~/$REMOTE_DIR/web/bench && ./remote.sh $stage" < /dev/null
}

fetch() {
  mkdir -p "$HERE/out"
  local f
  for f in results.csv verify.txt env.txt versions.txt; do
    scp -q "$host:~/$REMOTE_DIR/web/bench/out/$f" "$HERE/out/$f"
  done
}

publish() {
  local commit stamp md
  commit=$(git -C "$REPO" rev-parse --short=8 HEAD)
  stamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  md=$HERE/out/block.md
  python3 "$HERE/report.py" "$HERE/out" "$commit" "$stamp" "$host" > "$md"
  python3 - "$PKG/README.md" "$md" <<'PY'
import sys
readme, block = sys.argv[1], sys.argv[2]
begin, end = "<!-- BENCH:START -->", "<!-- BENCH:END -->"
text = open(readme).read()
body = open(block).read().rstrip("\n")
if begin not in text or end not in text:
    sys.exit("pkg/web/README.md has no %s / %s pair to write into" % (begin, end))
head, rest = text.split(begin, 1)
_, tail = rest.split(end, 1)
open(readme, "w").write("%s%s\n%s\n%s%s" % (head, begin, body, end, tail))
PY
  # RESULTS.md carries the block AND the transcript of the proof that ran
  # before it, because out/ is generated and gitignored: without this the
  # committed artefact would assert identical responses with nothing behind it.
  {
    cat "$md"
    echo
    echo "## Verification, exactly as it ran"
    echo
    echo '```'
    cat "$HERE/out/verify.txt"
    echo '```'
  } > "$HERE/RESULTS.md"
  echo "wrote pkg/web/README.md and pkg/web/bench/RESULTS.md"
}

case $MODE in
  --report) ;;
  --fetch)  fetch ;;
  --reuse)  measure; fetch ;;
  *)        ship; measure; fetch ;;
esac
publish
