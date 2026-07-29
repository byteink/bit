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
#      name (seed/link.zig), so anything else fails MissingEntry.
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
  *) echo "g2archive: unknown target '$TARGET' (want x86_64-linux|aarch64-linux|aarch64-macos)" >&2; exit 2 ;;
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
# could not be written into the shared tree while root.zig still claimed the
# real ABI names. G2 (#1583) landed that rename in the source, so there is
# nothing left to rewrite — and reading HEAD instead of the working tree is now
# actively wrong: this script is `./make libbitrt`'s archive step, so it
# would compile committed source and silently ignore every uncommitted runtime
# edit. That is #1486's stale-archive failure with a new cause. Only the
# emitted objects go to scratch; the checkout is still never written.
RT="$REPO_ROOT/runtime"

# The rename is a SOURCE property now, so this is a verification rather than a
# transformation: zero live (non-comment) `bit_rt_root_` pins may exist. Kept
# because it is the cheap pre-flight for the whole class — `tests/rootpins.zig`
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

# --- Module set: 15 platform-free dirs + 7 platform-specific pairs (22 total). ---
# Matches tests/rootpins.zig's module split and the module set the G3 (#1584)
# attempts converged on. Each entry is REL (module directory relative to $RT,
# empty string for $RT itself) and LABEL (the archive-member-friendly name,
# matching the "runtime_alloc.o" / "runtime_root_darwin.o" shape prior
# sessions' `ar t` output showed).
#
# This list is HAND-MAINTAINED and the completeness check below is why it is
# safe to be: `runtime/cryptohw` was added to the tree after G3 was first
# written and silently never reached the archive, because nothing compared the
# list against the directories that actually exist. It surfaced only because
# stdlib/crypto declares those symbols `extern` and E0078 caught the dangling
# reference — a module nothing externs would simply have been absent, with
# every gate green.
PLATFORM_FREE_RELS="- alloc auxv chan cryptohw gc net park rand root sched shims shims/scan stw thread"
PLATFORM_PAIRS="alloc net park rand root sched thread"

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
for p in $PLATFORM_PAIRS; do
  REL_LIST+=("$p/$PLAT")
  LABEL_LIST+=("runtime_${p}_${PLAT}")
done

# --- Completeness: every module directory in runtime/ must be in the list. ---
# A Bit module is a DIRECTORY of .bit files, so the set of modules is exactly the
# set of directories holding one. Anything present on disk but missing from the
# list above is silently left out of the archive; anything in the list but absent
# on disk is a typo that would abort the emit loop anyway, but is named here
# because the message is clearer before 22 compiles than during them. The other
# platform's directories are excluded, not missing: only $PLAT's providers belong
# in this target's archive.
OTHER_PLAT=linux
[ "$PLAT" = linux ] && OTHER_PLAT=darwin

on_disk=$(cd "$RT" && find . -name '*.bit' -exec dirname {} \; \
  | sed 's|^\./||; s|^\.$|-|' | grep -v "/${OTHER_PLAT}\$" | sort -u)
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
