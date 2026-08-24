#!/usr/bin/env bash
# g2archive.sh (#1694) — build a Bit-SOURCED libbitrt.a for one target from
# runtime/: the per-module emit + `bit ar` recipe that #1685/#1691/#1692/#1643
# each hand-reconstructed this session. Since G3 (#1584) this IS `./make
# libbitrt`'s archive step, not a side tool — the shipped runtime comes from
# here.
#
# Usage: bash scripts/g2archive.sh <x86_64-linux|aarch64-linux|aarch64-macos> <out.a>
#
# Reads the working tree, writes only its own `mktemp -d` scratch and $OUT; the
# shared `bit-out/lib/<target>/libbitrt.a` is explicitly refused. Set BIT=<path>
# to use a `bit` other than `bit-out/bin/bit` (e.g. a fresher seed).
#
# Three traps this script exists to encode rather than let the next reader
# rediscover:
#   1. Each runtime module is a DIRECTORY, not a single file — a lone file
#      cannot see its siblings (confirmed: building boot.bit alone fails
#      with 'undefined name' on every helper in its sibling files).
#   2. The process entry is the literal `@symbol("_start")`, never
#      `bit_rt_start` — the linker hardcodes `_start` as the entry symbol
#      name (`elEntrySymbol` in compiler/elflink.bit), so anything else
#      fails MissingEntry.
#   3. Under zsh, the object list from `find | sort` must go through an
#      array (`${(@f)$(...)}`), never a bare `$var` — this script is POSIX
#      sh (`set -u`, no zsh-isms) precisely so it has no such variable to
#      mis-split in the first place; each object path is passed to `bit ar`
#      as its own argv element, built up in a bash array.
#
# Fails loudly and non-zero on any partial build: a missing or zero-length
# object is a named error, never a quietly short archive. `wc -c` on macOS
# emits leading whitespace (` 0`, not `0`) — every size check here forces
# arithmetic evaluation (`$((sz))`, which strips the whitespace) before
# comparing with `-eq`, never a string `=` against the raw `wc` output, so
# that whitespace can never mask a zero-length object again.
set -u

usage() {
  echo "usage: bash scripts/g2archive.sh <x86_64-linux|aarch64-linux|aarch64-macos> <out.a>" >&2
  exit 2
}

[ $# -eq 2 ] || usage
TARGET=$1
OUT=$2

case "$TARGET" in
  x86_64-linux|aarch64-linux) PLAT=linux ;;
  aarch64-macos) PLAT=darwin ;;
  x86_64-windows) PLAT=windows ;;
  *) echo "g2archive: unknown target '$TARGET' (want x86_64-linux|aarch64-linux|aarch64-macos|x86_64-windows)" >&2; exit 2 ;;
esac

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd) || exit 1
BIT=${BIT:-"$REPO_ROOT/bit-out/bin/bit"}
if [ ! -x "$BIT" ]; then
  echo "g2archive: '$BIT' not found or not executable (build it first: ./make)" >&2
  exit 1
fi

# Guard on the shared archive's shape, not just this repo's absolute path, so
# a relative "bit-out/lib/<target>/libbitrt.a" (a peer's likely first typo)
# is refused too, not only the fully-qualified form.
case "$OUT" in
  */bit-out/lib/*/libbitrt.a|bit-out/lib/*/libbitrt.a)
    echo "g2archive: refusing to write the shared $OUT — it is read by peers" >&2
    exit 2
    ;;
esac

SCRATCH=$(mktemp -d) || exit 1
trap 'rm -rf "$SCRATCH"' EXIT

# Compiled straight out of the checkout. This used to take a `git archive HEAD`
# scratch copy of runtime/ and apply the G2 rename to it, because the rename
# could not be written into the shared tree while another module still claimed
# the real ABI names. G2 (#1583) landed that rename in the source, so there is
# nothing left to rewrite — and reading HEAD instead of the working tree is now
# actively wrong: this script is `./make libbitrt`'s archive step, so it
# would compile committed source and silently ignore every uncommitted runtime
# edit. That is #1486's stale-archive failure with a new cause. Only the
# emitted objects go to scratch; the checkout is still never written.
RT="$REPO_ROOT/runtime"

# The rename is a SOURCE property now, so this is a verification rather than a
# transformation: zero live (non-comment) `bit_rt_root_` pins may exist. Kept
# because it is the cheap pre-flight for the whole class — `tests/bit/rootpins/`
# proves the pin graph has no cycle, but only after a full build.
LEFT=$(find "$RT" -name '*.bit' -print0 | xargs -0 grep -n '@symbol("bit_rt_root_' \
  | grep -vE ':[0-9]+:[[:space:]]*//' | wc -l | tr -d ' ')
if [ "$LEFT" != "0" ]; then
  echo "g2archive: $LEFT live bit_rt_root_ pin(s) remain in runtime/ — the G2" >&2
  echo "  rename (#1583) is incomplete. Every ABI pin must be its bare" >&2
  echo "  'bit_rt_<name>'; 'bit_rt_root_start' is the one special case and" >&2
  echo "  becomes the literal @symbol(\"_start\")." >&2
  find "$RT" -name '*.bit' -print0 | xargs -0 grep -n '@symbol("bit_rt_root_' \
    | grep -vE ':[0-9]+:[[:space:]]*//' >&2
  exit 1
fi

# --- Module set: 16 platform-free dirs + 9 platform-specific pairs (25 for a
# linux/darwin build). Matches tests/bit/rootpins/'s module split and the
# module set the G3 (#1584) attempts converged on. Each entry is REL (module
# directory relative to $RT, empty string for $RT itself) and LABEL (the
# archive-member-friendly name, matching the "runtime_alloc.o" /
# "runtime_root_darwin.o" shape prior sessions' `ar t` output showed).
#
# This list is HAND-MAINTAINED and the completeness check below is why it is
# safe to be: `runtime/cryptohw` was added to the tree after G3 was first
# written and silently never reached the archive, because nothing compared the
# list against the directories that actually exist. It surfaced only because
# stdlib/crypto declares those symbols `extern` and E0078 caught the dangling
# reference — a module nothing externs would simply have been absent, with
# every gate green.
#
# `cryptohw` joined PLATFORM_PAIRS (#2520): ARM64 crypto-capability detection
# needs a real `getauxval` (linux) / `sysctlbyname` (darwin) provider per OS,
# unlike the rest of ../cryptohw.bit, which is one placeholder file shared by
# every target.
PLATFORM_FREE_RELS="- alloc auxv chan cryptohw gc net park rand root sched shims shims/scan stw syscalls thread"
PLATFORM_PAIRS="alloc cryptohw gc net park rand root sched thread"

# Windows is mid-port (epic #3322): alloc, gc, park, rand, root, sched and
# thread have a runtime/<pair>/windows/ directory today (#3330, #3336, #3338,
# #3331, #3339, #3335, #3420). net's windows sibling is tracked (#3340, socket ops) and not
# yet on disk, so it correctly stays out of this list. `thread` (#3335) lands
# here on the completeness check's own terms, not because anything consumes it
# yet: `runtime/thread/windows/spawn.bit` exists and compiles cleanly for the
# target, but `runtime/root/windows/boot.bit` does not call
# threadStart/threadRelease yet (that file's own header: "left for a later
# ticket") — this list only asks "is the directory real and buildable",
# which it is (#3386 is the record of this entry having been missed when
# #3335 landed). `park` landed #3336: runtime/sched/sleep.bit
# (platform-free, always linked in) declares `extern fn
# bit_rt_port_park_wake`/`bit_rt_port_park_wait`, which only
# runtime/park/<os>/wait.bit provides, so this was the actual reason ANY
# program failed to LINK for x86_64-windows before this landed (verified
# 2026-08-21, tests/bit/windowssmoke.bit's header). `sched` landed #3339 (the
# IOCP netpoller, runtime/sched/windows/poll.bit) and IS both consumed and
# wired: runtime/root/windows/boot.bit's step 4b/8b and `workerBody` call
# `pollCreate`/`pollDrain`/`pollClose` from it, the same three points
# ../linux/boot.bit and ../darwin/boot.bit call their own twins from —
# correcting this comment's own prior claim that sched "may not need" a
# windows pair at all. `gc` landed #3420: `gcThreadToken`'s token read is now
# OS-specific (Windows reads the TEB self-pointer at gs:[0x30]; Linux/Darwin
# still read fs:0/TPIDRRO_EL0 unchanged), the same "one x64 payload cannot
# answer for every OS" problem `park` hit, fixed the same way — an `extern fn
# bit_rt_port_gc_thread_token` in the platform-free runtime/gc/gcthread.bit,
# implemented per OS in runtime/gc/{linux,darwin,windows}/gcthread.bit.
# Hand-maintained rather than derived from `find`, on purpose: an
# auto-detected list would also silently swallow a genuine accidental
# deletion under linux/darwin, where all eight pairs must always be
# present — this list only relaxes the requirement for the one platform
# still being built out. As each pair's windows port lands, add its name
# here in the same commit. `net` lands with #3340 (AcceptEx/ConnectEx/
# WSARecv/WSASend on top of #3339's poller, runtime/net/windows/**) —
# the #3386 failure mode this comment already documents, caught before it
# bit this time. `cryptohw` lands with #3588: `runtime/cryptohw/windows/`
# implements `bit_rt_crypto_hwcaps` (reporting no hardware acceleration,
# matching x86_64-linux's own actual answer — see that file's header), which
# was the E0078 link failure blocking any `std/tls` program from building for
# x86_64-windows at all (#3340's finding). The same #3386 failure mode this
# comment already documents: the directory existing on disk is not enough,
# it must be listed here too.
WINDOWS_PAIRS="alloc cryptohw gc net park rand root sched thread"

case "$PLAT" in
  windows) PAIRS_FOR_PLAT="$WINDOWS_PAIRS" ;;
  *) PAIRS_FOR_PLAT="$PLATFORM_PAIRS" ;;
esac

REL_LIST=()
LABEL_LIST=()
for rel in $PLATFORM_FREE_RELS; do
  if [ "$rel" = "-" ]; then
    REL_LIST+=("")
    LABEL_LIST+=("runtime")
  else
    REL_LIST+=("$rel")
    LABEL_LIST+=("runtime_$(printf '%s' "$rel" | tr '/' '_')")
  fi
done
for p in $PAIRS_FOR_PLAT; do
  REL_LIST+=("$p/$PLAT")
  LABEL_LIST+=("runtime_${p}_${PLAT}")
done

# --- Completeness: every module directory in runtime/ must be in the list. ---
# A Bit module is a DIRECTORY of .bit files, so the set of modules is exactly the
# set of directories holding one. Anything present on disk but missing from the
# list above is silently left out of the archive; anything in the list but absent
# on disk is a typo that would abort the emit loop anyway, but is named here
# because the message is clearer before 22 compiles than during them. Every OTHER
# platform's directories are excluded, not missing: only $PLAT's providers belong
# in this target's archive.
#
# ALL_PLATS, not a single OTHER_PLAT (#3330): a two-way linux/darwin toggle
# silently stopped excluding a THIRD platform's in-progress directories the
# moment one existed on disk — runtime/root/windows and runtime/alloc/windows
# (epic #3322 Stage B) landed while this script still only knew "linux" and
# "darwin" exist, so building x86_64-linux or aarch64-macos saw them as
# "on disk but not listed" and refused to archive ANYTHING, for every target,
# not just the unbuilt one. Exclude every known platform name except $PLAT,
# so an in-progress platform's directories stay legitimately excluded here
# until its own tools/build wiring (x86_64-windows: #3341) adds it to
# PLATFORM_PAIRS's targets and to this list.
ALL_PLATS="linux darwin windows"
OTHER_PLATS=""
for p in $ALL_PLATS; do
  [ "$p" = "$PLAT" ] && continue
  OTHER_PLATS="$OTHER_PLATS $p"
done
OTHER_PLAT_RE=$(printf '%s\n' $OTHER_PLATS | paste -sd '|' -)

on_disk=$(cd "$RT" && find . -name '*.bit' -exec dirname {} \; \
  | sed 's|^\./||; s|^\.$|-|' | grep -vE "/(${OTHER_PLAT_RE})\$" | sort -u)
listed=$(printf '%s\n' "${REL_LIST[@]}" | sed 's|^$|-|' | sort -u)

missing=$(comm -23 <(printf '%s\n' "$on_disk") <(printf '%s\n' "$listed"))
extra=$(comm -13 <(printf '%s\n' "$on_disk") <(printf '%s\n' "$listed"))
if [ -n "$missing" ] || [ -n "$extra" ]; then
  echo "g2archive: the module list does not match runtime/ for $TARGET." >&2
  [ -n "$missing" ] && echo "  on disk but NOT in the archive (would be silently absent):" >&2 &&
    printf '    runtime/%s\n' $missing >&2
  [ -n "$extra" ] && echo "  in the list but NOT on disk:" >&2 &&
    printf '    runtime/%s\n' $extra >&2
  echo "  Fix PLATFORM_FREE_RELS / PLATFORM_PAIRS above." >&2
  exit 1
fi

OBJDIR="$SCRATCH/obj"
mkdir -p "$OBJDIR"

OBJS=()
FAILS=0
NMOD=${#REL_LIST[@]}
i=0
while [ "$i" -lt "$NMOD" ]; do
  rel=${REL_LIST[$i]}
  label=${LABEL_LIST[$i]}
  i=$((i + 1))
  if [ -z "$rel" ]; then
    dir="$RT"
  else
    dir="$RT/$rel"
  fi
  obj="$OBJDIR/${label}.o"
  errlog="$OBJDIR/${label}.err"
  "$BIT" build "$dir" --emit-obj --freestanding --target "$TARGET" -o "$obj" >"$errlog" 2>&1
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "g2archive: FAILED to emit 'runtime/$rel' for $TARGET (rc=$rc):" >&2
    cat "$errlog" >&2
    FAILS=$((FAILS + 1))
    continue
  fi
  if [ ! -f "$obj" ]; then
    echo "g2archive: FAILED: 'runtime/$rel' reported success but produced no object at $obj" >&2
    FAILS=$((FAILS + 1))
    continue
  fi
  sz=$(wc -c < "$obj" | tr -d ' ')
  if [ "$((sz))" -eq 0 ]; then
    echo "g2archive: FAILED: 'runtime/$rel' produced a zero-length object at $obj" >&2
    FAILS=$((FAILS + 1))
    continue
  fi
  OBJS+=("$obj")
done

if [ "$FAILS" -ne 0 ]; then
  echo "g2archive: $FAILS of $NMOD module(s) failed to emit for $TARGET — aborting, no archive written" >&2
  exit 1
fi

if [ "${#OBJS[@]}" -ne "$NMOD" ]; then
  echo "g2archive: internal error: ${#OBJS[@]} objects collected for $NMOD modules" >&2
  exit 1
fi

mkdir -p "$(dirname "$OUT")" || exit 1
rm -f "$OUT"
"$BIT" ar "$OUT" "${OBJS[@]}" --target "$TARGET"
rc=$?
if [ "$rc" -ne 0 ]; then
  echo "g2archive: 'bit ar' failed (rc=$rc) for $TARGET" >&2
  exit 1
fi
if [ ! -f "$OUT" ]; then
  echo "g2archive: 'bit ar' reported success but produced no archive at $OUT" >&2
  exit 1
fi
outsz=$(wc -c < "$OUT" | tr -d ' ')
if [ "$((outsz))" -eq 0 ]; then
  echo "g2archive: 'bit ar' produced a zero-length archive at $OUT" >&2
  exit 1
fi

echo "g2archive: OK — $TARGET, ${#OBJS[@]} objects, $OUT ($outsz bytes)"
exit 0
