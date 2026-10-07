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
#   results.csv   rep,framework,test,conn,rps,p50_ms,p99_ms,total,non200,
#                 cpu_us_per_req,load_cores
#   verify.txt    the byte-identical proof and the affinity read-back
#   env.txt       the box as measured, at measurement time
#   quiet.txt     every quiet check: before each rep and after the last
#
# cpu_us_per_req and load_cores exist because oha's req/s alone conflates two
# ceilings. At c=64, oha's own two pinned cores can be saturated BEFORE the
# server is (#5897 comment 2: 44.8-79.6k req/s across frameworks while every
# server still had headroom), which makes req/s partly a measurement of oha's
# per-response cost rather than the server's capacity. cpu_us_per_req (server
# CPU time / requests, from /proc/<pid>/stat of the container's main process)
# is comparable across frameworks regardless of who was the bottleneck;
# load_cores (busy cores on LOAD_CPUS, from /proc/stat) says when req/s itself
# was not a server ceiling, so report.py can flag those rows instead of a
# reader taking them on trust.
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

# cpu ids, one per line, from a Cpus_allowed_list-style spec ("2-5,7").
expand_cpus() {
  printf '%s\n' "$1" | tr ',' '\n' | while IFS=- read -r a b; do
    [ -n "$a" ] && seq "$a" "${b:-$a}"
  done
}

# cpu ids on stdin back to the kernel's own Cpus_allowed_list spelling, so the
# affinity read-back can be compared as a string.
cpu_ranges() {
  sort -n | awk 'NR == 1 { s = p = $1; next }
    $1 == p + 1 { p = $1; next }
    { o = o (s == p ? s : s "-" p) ","; s = p = $1 }
    END { if (NR) print o (s == p ? s : s "-" p) }'
}

# The cores this container ACTUALLY has, not cores 0..n-1: an LXC container is
# handed a slice of the host's CPUs, so a hardcoded 0-3 is refused outright by
# docker ("Requested CPUs are not available").
cpu_list() { cat /sys/fs/cgroup/cpuset.cpus.effective 2>/dev/null || echo 0-5; }

# THE SERVER GETS FEWER CORES THAN THE LOAD GENERATOR. With the server on four
# cores and oha on two, oha saturated at c=64 for every framework, so req/s
# measured oha. Every server now gets ONE physical core: the first whose SMT
# siblings all lie inside this container, so no sibling is shared with oha or
# with a neighbour outside it. oha gets every other CPU the container has.
server_core() {
  local c sib s ok mine
  mine=$(expand_cpus "$(cpu_list)")
  for c in $mine; do
    sib=$(cat "/sys/devices/system/cpu/cpu$c/topology/thread_siblings_list" 2>/dev/null) || continue
    ok=1
    for s in $(expand_cpus "$sib"); do
      printf '%s\n' "$mine" | grep -qx "$s" || ok=0
    done
    if [ "$ok" = 1 ]; then expand_cpus "$sib" | cpu_ranges; return 0; fi
  done
  return 1
}

load_cpus() {
  expand_cpus "$(cpu_list)" | { grep -vxF "$(expand_cpus "$SERVER_CPUS")" || true; } | cpu_ranges
}

SERVER_CPUS=${BENCH_SERVER_CPUS:-$(server_core || true)}
LOAD_CPUS=${BENCH_LOAD_CPUS:-$(load_cpus)}
[ -n "$SERVER_CPUS" ] && [ -n "$LOAD_CPUS" ] || {
  echo "no disjoint server/load CPU sets in $(cpu_list)" >&2; exit 1; }

HZ=$(getconf CLK_TCK)   # /proc/*/stat and /proc/stat are both in clock ticks

# The Bit server is NOT built here. run.sh builds it on the developer machine
# with that tree's own compiler and runtime, and ships the binary to
# out/bin/bitbench; a release image would measure a release, not the tree the
# table is stamped with. No default for its label: a run started by hand over
# here has to say which build it is measuring.
BIT_LABEL=${BENCH_BIT_LABEL:?set BENCH_BIT_LABEL to the commit out/bin/bitbench was built from}
BIT_RUN_IMAGE=debian:trixie
OHA_IMAGE=ghcr.io/hatoo/oha:latest

# name:port:image:workdir:command. Ports are distinct so all six stay up for
# the whole run and a rep costs a request, not a process start.
FRAMEWORKS=${BENCH_FRAMEWORKS:-"bit gin express bun spring aspnet"}
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
  [ -x "$OUT/bin/bitbench" ] || { say "no out/bin/bitbench: run.sh ships it"; return 1; }
  sha256sum "$OUT/bin/bitbench"
}

build_gin() {
  drun --rm -v "$SHIP:/w" -w /w/web/bench/apps/gin \
    -e GOFLAGS=-mod=mod -e GOCACHE=/w/web/bench/out/cache/go \
    -e GOMODCACHE=/w/web/bench/out/cache/gomod golang:1-alpine \
    sh -c 'go get github.com/gin-gonic/gin@latest && go mod tidy && CGO_ENABLED=0 go build -o /w/web/bench/out/bin/ginbench .'
}

build_express() {
  drun --rm -v "$SHIP:/w" -w /w/web/bench/apps/express node:22-alpine \
    sh -c 'npm install --no-audit --no-fund --loglevel=error express'
}

build_bun() {
  # No dependencies: bun runs the source. Prove the runtime is there instead.
  drun --rm -v "$SHIP:/w" -w /w/web/bench/apps/bun oven/bun:1 bun --version
}

build_spring() {
  drun --rm -v "$SHIP:/w" -w /w/web/bench/apps/spring \
    -v "$ROOT/out/cache/m2:/root/.m2" maven:3-eclipse-temurin-21-alpine \
    mvn -q -B -DskipTests package
}

build_aspnet() {
  drun --rm -v "$SHIP:/w" -w /w/web/bench/apps/aspnet \
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
    bit) drun -d --name "$name" --network host --cpuset-cpus "$SERVER_CPUS" \
           -v "$SHIP:/w" "$BIT_RUN_IMAGE" /w/web/bench/out/bin/bitbench ;;
    gin) drun -d --name "$name" --network host --cpuset-cpus "$SERVER_CPUS" \
           -v "$SHIP:/w" -e GIN_MODE=release golang:1-alpine /w/web/bench/out/bin/ginbench ;;
    express) drun -d --name "$name" --network host --cpuset-cpus "$SERVER_CPUS" \
           -v "$SHIP:/w" -w /w/web/bench/apps/express -e NODE_ENV=production \
           node:22-alpine node server.js ;;
    bun) drun -d --name "$name" --network host --cpuset-cpus "$SERVER_CPUS" \
           -v "$SHIP:/w" -w /w/web/bench/apps/bun -e NODE_ENV=production \
           oven/bun:1 bun server.ts ;;
    spring) drun -d --name "$name" --network host --cpuset-cpus "$SERVER_CPUS" \
           -v "$SHIP:/w" eclipse-temurin:21-jdk-alpine \
           java -jar /w/web/bench/apps/spring/target/springbench.jar ;;
    aspnet) drun -d --name "$name" --network host --cpuset-cpus "$SERVER_CPUS" \
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

# Every container this run starts carries the lock's session label, so a
# reclaim of a dead run's lock removes them too (bl_rm_labelled in the lock text).
drun() { docker run --label "$BL_LABEL_KEY=$BL_TOKEN" "$@"; }

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
  cid=$(drun -d --network host --cpuset-cpus "$LOAD_CPUS" "$OHA_IMAGE" \
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

# utime+stime (ticks) of the container's main process, read via its host pid.
# The kernel aggregates every thread in that process's thread group into the
# /proc/<pid>/stat of the group leader, so this is already "all threads"
# without walking /proc/<pid>/task; a pid that has disappeared (container
# gone) reads as 0 rather than aborting a rep.
server_cpu_ticks() {
  local fw=$1 pid rest
  pid=$(docker inspect -f '{{.State.Pid}}' "t5418-$fw" 2>/dev/null) || { echo 0; return; }
  rest=$(sed -E 's/^[0-9]+[[:space:]]+\([^)]*\)[[:space:]]+//' "/proc/$pid/stat" 2>/dev/null) || { echo 0; return; }
  set -- $rest
  echo $(( ${12:-0} + ${13:-0} ))
}

# Sum of non-idle ticks (user+nice+system+irq+softirq+steal; idle and iowait
# excluded) over every cpu in LOAD_CPUS, from /proc/stat's per-cpu lines.
load_busy_ticks() {
  local cpu sum=0 line
  for cpu in $(expand_cpus "$LOAD_CPUS"); do
    line=$(awk -v c="cpu$cpu" '$1==c{print $2,$3,$4,$7,$8,$9}' /proc/stat)
    set -- $line
    sum=$(( sum + ${1:-0} + ${2:-0} + ${3:-0} + ${4:-0} + ${5:-0} + ${6:-0} ))
  done
  echo "$sum"
}

one_rep() {
  local fw=$1 test=$2 rep=$3 dur=$4 conn=$5 port json
  local cpu0 cpu1 load0 load1 t0 t1 elapsed cpu_us load_cores
  port=$(port_of "$fw")
  # Bracketed tightly around the oha run: server CPU and load-core busy time
  # are both measured over this exact window, not the rep's nominal -z value,
  # so docker start/stop overhead on either side is not charged to either.
  cpu0=$(server_cpu_ticks "$fw")
  load0=$(load_busy_ticks)
  t0=$(date +%s.%N)
  json=$(drun --rm --network host --cpuset-cpus "$LOAD_CPUS" "$OHA_IMAGE" \
    -z "$dur" -c "$conn" --no-tui --output-format json "http://127.0.0.1:$port/$test") || return 1
  t1=$(date +%s.%N)
  cpu1=$(server_cpu_ticks "$fw")
  load1=$(load_busy_ticks)
  elapsed=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.6f", b-a}')
  cpu_us=$(awk -v u0="$cpu0" -v u1="$cpu1" -v hz="$HZ" 'BEGIN{printf "%.0f", (u1-u0)*1000000.0/hz}')
  load_cores=$(awk -v l0="$load0" -v l1="$load1" -v hz="$HZ" -v el="$elapsed" \
    'BEGIN{if (el>0) printf "%.3f", (l1-l0)/hz/el; else print "0.000"}')
  printf '%s' "$json" | python3 "$ROOT/ohajson.py" "$rep" "$fw" "$test" "$conn" "$cpu_us" "$load_cores" \
    >> "$OUT/results.csv"
}

# QUIET BEFORE EVERY REP, AND AFTER THE LAST. The box is a container on a
# shared host: another tenant's burst lands on these cores without any trace
# in this container's own process list. Three conditions, each read from the
# kernel rather than inferred: no container running that this script did not
# start, the CPU pressure 10 s average under 1 after 20 s with nothing timed,
# and under 1% of a fresh 5 s window stalled. A check right after the warmup
# routinely fails once while our own load decays, so each check retries a
# bounded number of times and the run stops rather than time a noisy box.
QUIET_TRIES=${BENCH_QUIET_TRIES:-6}
psi_some() { awk -v k="$1" '/^some/ { for (i = 2; i <= NF; i++) if (index($i, k "=") == 1) print substr($i, length(k) + 2) }' /proc/pressure/cpu; }

quiet() {
  local label=$1 try foreign avg t0 t1 stall
  for try in $(seq 1 "$QUIET_TRIES"); do
    sleep 20
    foreign=$(docker ps --format '{{.Names}}' | grep -vc '^t5418-' || true)
    avg=$(psi_some avg10)
    t0=$(psi_some total); sleep 5; t1=$(psi_some total)
    stall=$(awk -v a="$t0" -v b="$t1" 'BEGIN { printf "%.2f", (b - a) / 50000.0 }')
    if [ "$foreign" = 0 ] && awk -v a="$avg" -v s="$stall" 'BEGIN { exit !(a < 1 && s < 1) }'; then
      say "$label try $try: quiet (foreign containers 0, cpu some avg10 $avg, 5 s stall $stall%)" >> "$OUT/quiet.txt"
      return 0
    fi
    say "$label try $try: NOT quiet (foreign containers $foreign, cpu some avg10 $avg, 5 s stall $stall%)" >> "$OUT/quiet.txt"
  done
  say "box never went quiet at $label after $QUIET_TRIES tries; see $OUT/quiet.txt"
  return 1
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
  printf 'rep,framework,test,conn,rps,p50_ms,p99_ms,total,non200,cpu_us_per_req,load_cores\n' > "$OUT/results.csv"
  for fw in $FRAMEWORKS; do
    for test in plaintext json; do
      one_rep "$fw" "$test" 0 "$WARMDUR" 64 || return 1
    done
  done
  sed -i '/^0,/d' "$OUT/results.csv"       # rep 0 is warmup, never published
  : > "$OUT/quiet.txt"
  for rep in $(seq 1 "$REPS"); do
    quiet "rep$rep-pre" || return 1
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
  quiet "rep$REPS-post"
}

# ---------------------------------------------------------------- box

record_env() {
  {
    say "virt: $(systemd-detect-virt 2>/dev/null || echo unknown)"
    say "cores: $(nproc)"
    say "cpu.max: $(cat /sys/fs/cgroup/cpu.max 2>/dev/null || echo unknown)"
    say "kernel: $(uname -sr)"
    say "cpu: $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2- | sed 's/^ *//')"
    say "cpu_cores: $(grep -m1 '^cpu cores' /proc/cpuinfo | cut -d: -f2 | tr -d ' ')"
    say "cpu_threads: $(grep -m1 '^siblings' /proc/cpuinfo | cut -d: -f2 | tr -d ' ')"
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
    say "bit $BIT_LABEL"
    say "gin $(grep -m1 'gin-gonic/gin' "$ROOT/apps/gin/go.mod" | awk '{print $NF}')"
    say "go $(drun --rm golang:1-alpine go version | awk '{print $3}')"
    say "express $(drun --rm -v "$SHIP:/w" -w /w/web/bench/apps/express node:22-alpine \
      node -p 'require("express/package.json").version' 2>&1 | tail -1)"
    say "node $(drun --rm node:22-alpine node --version)"
    say "bun $(drun --rm oven/bun:1 bun --version)"
    say "springboot $(grep -m1 -A2 spring-boot-starter-parent "$ROOT/apps/spring/pom.xml" | grep version | sed 's/.*<version>\(.*\)<\/version>.*/\1/')"
    say "jvm $(drun --rm eclipse-temurin:21-jdk-alpine java -version 2>&1 | head -1 | cut -d'"' -f2)"
    say "dotnet $(drun --rm mcr.microsoft.com/dotnet/sdk:9.0 dotnet --version)"
    say "oha $(drun --rm "$OHA_IMAGE" --version 2>&1 | head -1 | awk '{print $NF}')"
  } > "$OUT/versions.txt" 2>&1
}

# ---------------------------------------------------------------- main

# /tmp/benchlock is the box-wide measurement lock, a DIRECTORY, the same lock
# scripts/x64gate.sh and the dockerlive harness take. It is taken through the
# text `scripts/x64gate.sh lock-lib` prints (bench/run.sh ships it in
# BENCH_LOCK_LIB_B64), so all three share ONE owner file + 30 s heartbeat +
# 5-minute stale reclaim: a remote.sh that is SIGKILLed leaves a lock the next
# acquirer reclaims, where a bare mkdir would leave it for good (#7614, #7604).
# Held for the whole run, builds included, so no gate container lands on these
# cores mid-rep. The wait is bounded in 10 s tries; 360 is one hour.
LOCK=/tmp/benchlock
take_lock() {
  local n=0
  [ -n "${BENCH_LOCK_LIB_B64:-}" ] || {
    say "BENCH_LOCK_LIB_B64 is unset: run through bench/run.sh, which ships 'x64gate.sh lock-lib'"
    return 1
  }
  eval "$(printf '%s' "$BENCH_LOCK_LIB_B64" | base64 -d)"
  local token="remote-$$-$(date +%s)"
  until bl_try "$token" "$(hostname):$$:$(date +%s)"; do
    n=$((n + 1))
    if [ "$n" -ge "${BENCH_LOCK_TRIES:-360}" ]; then
      say "$LOCK still held after $((n * 10))s: $(ls -ld "$LOCK" 2>&1)"
      return 1
    fi
    sleep 10
  done
  trap 'stop_all; bl_release' EXIT
  trap 'exit 1' HUP INT TERM
  bl_beat
}

# Stages, so a slow build is not repeated to re-run a fast measurement:
#   build     compile the six servers, nothing else
#   versions  re-record what each framework resolved to, nothing else
#   run       prove + measure against an already built tree (default: both)
main() {
  local stage=${1:-all}
  mkdir -p "$OUT" "$LOG"
  take_lock
  if [ "$stage" = build ]; then
    build_all
    versions
    return 0
  fi
  if [ "$stage" = versions ]; then
    versions
    return 0
  fi
  if [ "$stage" != run ]; then
    build_all
  fi
  versions
  record_env
  start_all
  prove
  cat "$OUT/verify.txt"
  if grep -q 'MISMATCH\|MISSING\|NOT REUSING\|NEVER ANSWERED\|PROOF FAILED' "$OUT/verify.txt"; then
    say "refusing to measure: the six servers are not serving the same responses"
    exit 1
  fi
  measure
  say "results in $OUT/results.csv"
}

main "$@"
