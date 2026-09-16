#!/usr/bin/env bash
# The half of pkg/web's framework benchmark that runs ON the Linux box (#5418).
# bench/run.sh ships this tree there and calls this; nothing here runs on a Mac.
#
# It builds the six servers under apps/, PROVES they answer byte-identical
# bodies and Content-Types before it times anything, reads back the CPU
# affinity every process actually got, then measures round-robin.
#
# ROUND-ROBIN IS NOT A STYLE CHOICE. The box is an unquota'd LXC container
# sharing six cores with neighbours that are invisible from inside it, so a
# framework measured to completion before the next one starts is measured
# against whatever the neighbours were doing in its window. Interleaving short
# reps spreads that drift over all six equally; the median over the reps is
# then a statement about the frameworks.
#
# Outputs, all under out/:
#   results.csv   rep,framework,test,conn,rps,p50_ms,p99_ms,total,non200
#   verify.txt    the byte-identical proof and the affinity read-back
#   env.txt       the box as measured, at measurement time
set -euo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)   # .../web/bench
SHIP=$(cd "$ROOT/../.." && pwd)       # ships as /w inside every container
OUT=$ROOT/out
LOG=$OUT/logs

REPS=${BENCH_REPS:-5}                 # measured reps; rep 0 is a discarded warmup
DUR=${BENCH_DUR:-5s}                  # per rep, per framework, per test
WARMDUR=${BENCH_WARMDUR:-10s}         # rep 0, long enough for a JIT to settle
# TWO concurrency levels, not one. c=1 is the per-request cost with no queue
# in front of it; c=64 is the loaded server. They are not a constant factor
# apart for every framework here, so publishing only one of them would hide
# which half of a gap is per-request work and which half is scheduling.
CONNS=${BENCH_CONNS:-"1 64"}
# The cores this container ACTUALLY has, not cores 0..n-1: an LXC container is
# handed a slice of the host's CPUs and ours is 2-7, so a hardcoded 0-3 is
# refused outright by docker ("Requested CPUs are not available"). Servers take
# all but the last two, the load generator takes those two, and the two sets
# are proven disjoint from /proc before anything is timed.
cpu_list() { cat /sys/fs/cgroup/cpuset.cpus.effective 2>/dev/null || echo 0-5; }
cpu_lo() { cpu_list | cut -d- -f1; }
cpu_hi() { cpu_list | cut -d- -f2; }
SERVER_CPUS=${BENCH_SERVER_CPUS:-$(cpu_lo)-$(( $(cpu_hi) - 2 ))}
LOAD_CPUS=${BENCH_LOAD_CPUS:-$(( $(cpu_hi) - 1 ))-$(cpu_hi)}

BIT_IMAGE=ghcr.io/byteink/bit:0.19.0
OHA_IMAGE=ghcr.io/hatoo/oha:latest

# name:port:image:workdir:command. Ports are distinct so all six stay up for
# the whole run and a rep costs a request, not a process start.
FRAMEWORKS="bit gin express bun spring aspnet"
port_of() {
  case $1 in
    bit) echo 8081 ;; gin) echo 8082 ;; express) echo 8083 ;;
    bun) echo 8084 ;; spring) echo 8085 ;; aspnet) echo 8086 ;;
    *) echo "unknown framework: $1" >&2; return 1 ;;
  esac
}

say() { printf '%s\n' "$*"; }

# ---------------------------------------------------------------- build

build_bit() {
  local d=$ROOT/apps/bit
  # Written here and not committed: the path is this box's, not the repo's.
  printf '{"name": "bitbench", "dependencies": {"web": "/w/web"}}\n' > "$d/bit.json"
  printf '{"web": {"path": "/w/web", "requires": {}}}\n' > "$d/bit.lock"
  # The image's ENTRYPOINT is already `bit`, so the subcommand starts here.
  # --user root only for the BUILD: the image's default 65532 cannot write
  # into the shipped tree. The server below runs as that default user.
  docker run --rm --user root -v "$SHIP:/w" -w /w/web/bench/apps/bit "$BIT_IMAGE" \
    build main.bit -o /w/web/bench/out/bin/bitbench
}

build_gin() {
  docker run --rm -v "$SHIP:/w" -w /w/web/bench/apps/gin \
    -e GOFLAGS=-mod=mod -e GOCACHE=/w/web/bench/out/cache/go \
    -e GOMODCACHE=/w/web/bench/out/cache/gomod golang:1-alpine \
    sh -c 'go get github.com/gin-gonic/gin@latest && go mod tidy && CGO_ENABLED=0 go build -o /w/web/bench/out/bin/ginbench .'
}

build_express() {
  docker run --rm -v "$SHIP:/w" -w /w/web/bench/apps/express node:22-alpine \
    sh -c 'npm install --no-audit --no-fund --loglevel=error express'
}

build_bun() {
  # No dependencies: bun runs the source. Prove the runtime is there instead.
  docker run --rm -v "$SHIP:/w" -w /w/web/bench/apps/bun oven/bun:1 bun --version
}

build_spring() {
  docker run --rm -v "$SHIP:/w" -w /w/web/bench/apps/spring \
    -v "$ROOT/out/cache/m2:/root/.m2" maven:3-eclipse-temurin-21-alpine \
    mvn -q -B -DskipTests package
}

build_aspnet() {
  docker run --rm -v "$SHIP:/w" -w /w/web/bench/apps/aspnet \
    -e DOTNET_CLI_TELEMETRY_OPTOUT=1 -e NUGET_PACKAGES=/w/web/bench/out/cache/nuget \
    mcr.microsoft.com/dotnet/sdk:9.0 \
    dotnet publish -c Release -o /w/web/bench/out/aspnet
}

build_all() {
  mkdir -p "$OUT/bin" "$LOG" "$OUT/cache/m2" "$OUT/cache/nuget"
  local fw pids=""
  for fw in $FRAMEWORKS; do
    ( "build_$fw" ) > "$LOG/build-$fw.log" 2>&1 &
    pids="$pids $!:$fw"
  done
  local rc=0 p
  for p in $pids; do
    wait "${p%%:*}" || { say "BUILD FAILED: ${p##*:} (see $LOG/build-${p##*:}.log)"; rc=1; }
  done
  [ "$rc" = 0 ] || { tail -n 25 "$LOG"/build-*.log; return 1; }
  say "built: $FRAMEWORKS"
}

# ---------------------------------------------------------------- servers

start_one() {
  local fw=$1 name=t5418-$fw
  docker rm -f "$name" >/dev/null 2>&1 || true
  case $fw in
    bit) docker run -d --name "$name" --network host --cpuset-cpus "$SERVER_CPUS" \
           -v "$SHIP:/w" --entrypoint /w/web/bench/out/bin/bitbench "$BIT_IMAGE" ;;
    gin) docker run -d --name "$name" --network host --cpuset-cpus "$SERVER_CPUS" \
           -v "$SHIP:/w" -e GIN_MODE=release golang:1-alpine /w/web/bench/out/bin/ginbench ;;
    express) docker run -d --name "$name" --network host --cpuset-cpus "$SERVER_CPUS" \
           -v "$SHIP:/w" -w /w/web/bench/apps/express -e NODE_ENV=production \
           node:22-alpine node server.js ;;
    bun) docker run -d --name "$name" --network host --cpuset-cpus "$SERVER_CPUS" \
           -v "$SHIP:/w" -w /w/web/bench/apps/bun -e NODE_ENV=production \
           oven/bun:1 bun server.ts ;;
    spring) docker run -d --name "$name" --network host --cpuset-cpus "$SERVER_CPUS" \
           -v "$SHIP:/w" eclipse-temurin:21-jdk-alpine \
           java -jar /w/web/bench/apps/spring/target/springbench.jar ;;
    aspnet) docker run -d --name "$name" --network host --cpuset-cpus "$SERVER_CPUS" \
           -v "$SHIP:/w" -e DOTNET_ENVIRONMENT=Production \
           mcr.microsoft.com/dotnet/sdk:9.0 dotnet /w/web/bench/out/aspnet/aspnetbench.dll ;;
  esac > "$LOG/run-$fw.cid"
}

wait_ready() {
  local fw=$1 port i
  port=$(port_of "$fw")
  for i in $(seq 1 120); do
    if curl -fsS --max-time 2 "http://127.0.0.1:$port/plaintext" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  say "SERVER NEVER ANSWERED: $fw on $port"
  docker logs "t5418-$fw" 2>&1 | tail -n 20
  return 1
}

start_all() {
  local fw
  for fw in $FRAMEWORKS; do start_one "$fw"; done
  for fw in $FRAMEWORKS; do wait_ready "$fw"; done
  say "up: $FRAMEWORKS"
}

stop_all() {
  local fw
  for fw in $FRAMEWORKS; do docker rm -f "t5418-$fw" >/dev/null 2>&1 || true; done
}

# ---------------------------------------------------------------- proof

# The exact Content-Type, lowercased with the optional space after ';' removed.
# Published raw beside it; compared normalized, because a framework that writes
# `text/plain;charset=utf-8` is serving the same response as one that writes
# `text/plain; charset=utf-8` and a byte compare of the header would call that
# a different benchmark when it is not.
norm_ct() { tr 'A-Z' 'a-z' | sed 's/; */;/g; s/ *$//'; }

# A Content-Length equal to the body, and no chunked framing. A server that
# streams the same 13 bytes chunked is writing more wire bytes than one that
# declares a length, so bodies matching is not on its own the same benchmark.
framed() {
  local fw=$1 test=$2 hdr=$OUT/hdr-$fw-$test.txt cl te
  cl=$(grep -i '^content-length:' "$hdr" | head -1 | tr -dc '0-9')
  te=$(grep -ic '^transfer-encoding:' "$hdr" || true)
  if [ "$cl" != "$(wc -c < "$OUT/body-$fw-$test.bin")" ]; then
    say "    MISMATCH Content-Length: $fw $test (header '${cl:-absent}')"
    return 1
  fi
  if [ "$te" != 0 ]; then
    say "    MISMATCH framing: $fw $test is chunked"
    return 1
  fi
}

capture() {
  local fw=$1 test=$2 port
  port=$(port_of "$fw")
  curl -fsS --max-time 5 -D "$OUT/hdr-$fw-$test.txt" \
    -o "$OUT/body-$fw-$test.bin" "http://127.0.0.1:$port/$test"
}

verify_responses() {
  local fw test ref refct ct rc=0
  for test in plaintext json; do
    for fw in $FRAMEWORKS; do capture "$fw" "$test"; done
    ref=$OUT/body-bit-$test.bin
    refct=$(grep -i '^content-type:' "$OUT/hdr-bit-$test.txt" | head -1 | cut -d: -f2- | sed 's/^ *//' | tr -d '\r')
    say "--- $test: reference is pkg/web, $(wc -c < "$ref") bytes, $(sha256sum < "$ref" | cut -c1-16)"
    say "    body: $(cat "$ref")"
    for fw in $FRAMEWORKS; do
      ct=$(grep -i '^content-type:' "$OUT/hdr-$fw-$test.txt" | head -1 | cut -d: -f2- | sed 's/^ *//' | tr -d '\r')
      printf '    %-8s %4s bytes  sha %s  Content-Type: %s\n' \
        "$fw" "$(wc -c < "$OUT/body-$fw-$test.bin")" \
        "$(sha256sum < "$OUT/body-$fw-$test.bin" | cut -c1-16)" "$ct"
      cmp -s "$ref" "$OUT/body-$fw-$test.bin" || { say "    MISMATCH body: $fw $test"; rc=1; }
      [ "$(printf %s "$ct" | norm_ct)" = "$(printf %s "$refct" | norm_ct)" ] \
        || { say "    MISMATCH Content-Type: $fw $test"; rc=1; }
      [ -n "$ct" ] || { say "    MISSING Content-Type: $fw $test"; rc=1; }
      framed "$fw" "$test" || rc=1
    done
  done
  return $rc
}

# Two requests down one connection: oha keeps connections alive by default, so
# a server that closes after every response would be measured on TCP setup.
verify_keepalive() {
  local fw port n
  for fw in $FRAMEWORKS; do
    port=$(port_of "$fw")
    n=$(curl -sS -o /dev/null -o /dev/null -w '%{num_connects}\n' --max-time 5 \
      "http://127.0.0.1:$port/plaintext" "http://127.0.0.1:$port/json" \
      | awk '{t += $1} END {print t}')
    printf '    %-8s 2 requests, %s TCP connect(s)\n' "$fw" "$n"
    [ "$n" = 1 ] || { say "    NOT REUSING THE CONNECTION: $fw"; return 1; }
  done
}

# What the processes GOT, not what the flag said. Cpus_allowed_list is the
# same mask taskset prints; these images do not all carry util-linux, so the
# pinning is the cgroup form and the read-back is from /proc.
verify_affinity() {
  local fw pid cid
  for fw in $FRAMEWORKS; do
    pid=$(docker inspect -f '{{.State.Pid}}' "t5418-$fw")
    local got
    got=$(awk '/Cpus_allowed_list/{print $2}' "/proc/$pid/status")
    printf '    %-8s server pid %-7s Cpus_allowed_list=%s\n' "$fw" "$pid" "$got"
    [ "$got" = "$SERVER_CPUS" ] || return 1
  done
  cid=$(docker run -d --network host --cpuset-cpus "$LOAD_CPUS" "$OHA_IMAGE" \
    -z 10s -c 4 --no-tui --output-format json "http://127.0.0.1:$(port_of bit)/plaintext")
  local i got=""
  for i in $(seq 1 30); do
    pid=$(docker inspect -f '{{.State.Pid}}' "$cid")
    if [ "$pid" != 0 ] && [ -r "/proc/$pid/status" ]; then
      got=$(awk '/Cpus_allowed_list/{print $2}' "/proc/$pid/status")
      break
    fi
    sleep 0.2
  done
  printf '    %-8s load   pid %-7s Cpus_allowed_list=%s\n' oha "${pid:-none}" "${got:-unreadable}"
  docker rm -f "$cid" >/dev/null 2>&1 || true
  [ "$got" = "$LOAD_CPUS" ] || return 1
}

# The whole proof, written to one file. Each step's failure is captured rather
# than aborting: a partial proof file is worse than a complete one that says
# which framework is wrong.
prove() {
  {
    say "=== byte-identical response proof, taken before any timing"
    verify_responses || say "RESPONSE PROOF FAILED"
    say "=== keep-alive, two requests down one connection"
    verify_keepalive || say "KEEP-ALIVE PROOF FAILED"
    say "=== CPU affinity, read back from /proc of the running processes"
    verify_affinity || say "AFFINITY PROOF FAILED"
    say "=== servers pinned $SERVER_CPUS, load generator $LOAD_CPUS, disjoint"
  } > "$OUT/verify.txt" 2>&1
}

# ---------------------------------------------------------------- measure

one_rep() {
  local fw=$1 test=$2 rep=$3 dur=$4 conn=$5 port json
  port=$(port_of "$fw")
  json=$(docker run --rm --network host --cpuset-cpus "$LOAD_CPUS" "$OHA_IMAGE" \
    -z "$dur" -c "$conn" --no-tui --output-format json "http://127.0.0.1:$port/$test") || return 1
  printf '%s' "$json" | python3 "$ROOT/ohajson.py" "$rep" "$fw" "$test" "$conn" >> "$OUT/results.csv"
}

# Rotated so no framework is always first in a rep: position in the rep is
# itself a source of bias on a box whose neighbours drift.
rotated() {
  local n=$1 i=0 fw out=""
  for fw in $FRAMEWORKS; do
    i=$((i + 1))
    if [ "$i" -gt "$n" ]; then out="$out $fw"; fi
  done
  i=0
  for fw in $FRAMEWORKS; do
    i=$((i + 1))
    if [ "$i" -le "$n" ]; then out="$out $fw"; fi
  done
  printf '%s' "$out"
}

measure() {
  local rep fw test conn order n
  n=$(printf '%s' "$FRAMEWORKS" | wc -w)
  printf 'rep,framework,test,conn,rps,p50_ms,p99_ms,total,non200\n' > "$OUT/results.csv"
  for fw in $FRAMEWORKS; do
    for test in plaintext json; do
      one_rep "$fw" "$test" 0 "$WARMDUR" 64 || return 1
    done
  done
  sed -i '/^0,/d' "$OUT/results.csv"       # rep 0 is warmup, never published
  for rep in $(seq 1 "$REPS"); do
    order=$(rotated $((rep % n)))
    for fw in $order; do
      for test in plaintext json; do
        for conn in $CONNS; do
          one_rep "$fw" "$test" "$rep" "$DUR" "$conn" || return 1
        done
      done
    done
    say "rep $rep/$REPS done"
  done
}

# ---------------------------------------------------------------- box

record_env() {
  {
    say "host: $(hostname)"
    say "virt: $(systemd-detect-virt 2>/dev/null || echo unknown)"
    say "cores: $(nproc)"
    say "cpu.max: $(cat /sys/fs/cgroup/cpu.max 2>/dev/null || echo unknown)"
    say "kernel: $(uname -sr)"
    say "cpu: $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2- | sed 's/^ *//')"
    say "mem_total_mb: $(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)"
    say "loadavg: $(cut -d' ' -f1-3 /proc/loadavg)"
    say "docker: $(docker --version)"
    say "date_utc: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    say "--- vmstat 1 5 (neighbour I/O is visible in b/wa/bi)"
    vmstat 1 5
  } > "$OUT/env.txt" 2>&1
}

versions() {
  {
    say "bit $(docker run --rm "$BIT_IMAGE" --version 2>&1 | head -1 | awk '{print $NF}')"
    say "gin $(grep -m1 'gin-gonic/gin' "$ROOT/apps/gin/go.mod" | awk '{print $NF}')"
    say "go $(docker run --rm golang:1-alpine go version | awk '{print $3}')"
    say "express $(docker run --rm -v "$SHIP:/w" -w /w/web/bench/apps/express node:22-alpine \
      node -p 'require("express/package.json").version' 2>&1 | tail -1)"
    say "node $(docker run --rm node:22-alpine node --version)"
    say "bun $(docker run --rm oven/bun:1 bun --version)"
    say "springboot $(grep -m1 -A2 spring-boot-starter-parent "$ROOT/apps/spring/pom.xml" | grep version | sed 's/.*<version>\(.*\)<\/version>.*/\1/')"
    say "jvm $(docker run --rm eclipse-temurin:21-jdk-alpine java -version 2>&1 | head -1 | cut -d'"' -f2)"
    say "dotnet $(docker run --rm mcr.microsoft.com/dotnet/sdk:9.0 dotnet --version)"
  } > "$OUT/versions.txt" 2>&1
}

# ---------------------------------------------------------------- main

# Stages, so a slow build is not repeated to re-run a fast measurement:
#   build     compile the six servers, nothing else
#   versions  re-record what each framework resolved to, nothing else
#   run       prove + measure against an already built tree (default: both)
main() {
  local stage=${1:-all}
  mkdir -p "$OUT" "$LOG"
  if [ "$stage" = build ]; then
    build_all
    versions
    return 0
  fi
  if [ "$stage" = versions ]; then
    versions
    return 0
  fi
  trap stop_all EXIT
  if [ "$stage" != run ]; then
    build_all
  fi
  versions
  record_env
  start_all
  prove
  cat "$OUT/verify.txt"
  if grep -q 'MISMATCH\|MISSING\|NOT REUSING\|NEVER ANSWERED' "$OUT/verify.txt"; then
    say "refusing to measure: the six servers are not serving the same responses"
    exit 1
  fi
  measure
  say "results in $OUT/results.csv"
}

main "$@"
