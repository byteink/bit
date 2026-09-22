#!/usr/bin/env bash
# bench/ctxsw/ctxsw.sh — run ./ctxsw.bit on real x86_64 Linux hardware and report
# context switches per timer wake, interleaved, with a byte-identical null control.
#
#   bash bench/ctxsw/ctxsw.sh                       # build from this tree, one subject
#   bash bench/ctxsw/ctxsw.sh before=/p/a after=/p/b   # compare prebuilt binaries
#
# A SUBJECT IS A BINARY, NOT A TREE. The runtime under test is linked into the
# program, so comparing two commits means building ./ctxsw.bit with each commit's
# own compiler (`bit build bench/ctxsw/ctxsw.bit --target x86_64-linux -o <out>`,
# the flag AFTER the file) and passing both binaries here. That keeps the source
# of the workload identical across subjects, which comparing two trees does not.
#
# THE NULL CONTROL IS NOT OPTIONAL and is added for you: the first subject is
# shipped a SECOND time under `<label>~null`, byte-identical, and measured in the
# same rotation. Whatever spread it shows is the box's drift; a difference
# between real subjects smaller than that is not a result. Sequential blocks
# measure box drift as if it were the subject, so the subjects are rotated
# A/B/A/B rather than run in blocks.
#
# Env: BIT_X64_HOST / see scripts/x64host.sh (which box), ROUNDS (default 7),
# BIT_WORKERS (default 1 — see ctxsw.bit on why one worker is what makes the
# reading worker 0's), BIT_CTXSW_TASKS / BIT_CTXSW_TURNS / BIT_CTXSW_PERIOD_NS
# (the workload), CTXSW_FORCE=1 to measure on a box that failed the load check.
set -euo pipefail

cd "$(dirname "$0")/../.."          # repo root
ROUNDS=${ROUNDS:-7}
WORKERS=${BIT_WORKERS:-1}
TASKS=${BIT_CTXSW_TASKS:-8}
TURNS=${BIT_CTXSW_TURNS:-2000}
PERIOD=${BIT_CTXSW_PERIOD_NS:-200000}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/ctxsw.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# --- subjects ---------------------------------------------------------------
LABELS=(); BINS=()
if [ $# -eq 0 ]; then
  BIT=${BIT:-./bit-out/bin/bit}
  [ -x "$BIT" ] || { echo "ctxsw: no compiler at $BIT (run ./make)" >&2; exit 1; }
  "$BIT" build bench/ctxsw/ctxsw.bit --target x86_64-linux -o "$WORK/tree"
  LABELS+=("tree"); BINS+=("$WORK/tree")
else
  for a in "$@"; do
    case "$a" in
      *=*) l=${a%%=*}; p=${a#*=} ;;
      *)   echo "ctxsw: expected <label>=<binary>, got '$a'" >&2; exit 1 ;;
    esac
    [ -f "$p" ] || { echo "ctxsw: no binary at $p" >&2; exit 1; }
    LABELS+=("$l"); BINS+=("$p")
  done
fi
LABELS+=("${LABELS[0]}~null"); BINS+=("${BINS[0]}")   # the control: the same bytes twice

# --- the box ----------------------------------------------------------------
HOST=${BIT_X64_HOST:-$(sh scripts/x64host.sh)} || { echo "ctxsw: no x86_64 host" >&2; exit 1; }
KERNEL=$(ssh -o BatchMode=yes "$HOST" 'uname -srm' </dev/null)
LOAD=$(ssh -o BatchMode=yes "$HOST" 'cut -d" " -f1 /proc/loadavg' </dev/null)
case "$KERNEL" in
  *x86_64*) ;;
  *) echo "ctxsw: $HOST is not x86_64 ($KERNEL)" >&2; exit 1 ;;
esac
if [ "${CTXSW_FORCE:-0}" != "1" ] && [ "$(echo "$LOAD" | cut -d. -f1)" -ge 2 ]; then
  echo "ctxsw: refusing, $HOST load average is $LOAD (CTXSW_FORCE=1 to override)" >&2
  exit 1
fi
echo "ctxsw host=$HOST kernel=\"$KERNEL\" loadavg=$LOAD rounds=$ROUNDS workers=$WORKERS tasks=$TASKS turns=$TURNS period_ns=$PERIOD"

# --- ship -------------------------------------------------------------------
REMOTE=".bit-ctxsw-$$"
ssh -o BatchMode=yes "$HOST" "rm -rf $REMOTE && mkdir -p $REMOTE" </dev/null
trap 'rm -rf "$WORK"; ssh -o BatchMode=yes "$HOST" "rm -rf $REMOTE" </dev/null || true' EXIT
i=0
while [ $i -lt ${#LABELS[@]} ]; do
  scp -q "${BINS[$i]}" "$HOST:$REMOTE/${LABELS[$i]}"
  i=$((i + 1))
done
ssh -o BatchMode=yes "$HOST" "chmod +x $REMOTE/*" </dev/null

# --- measure, rotating the subjects ----------------------------------------
RES="$WORK/res"; : > "$RES"
r=1
while [ $r -le "$ROUNDS" ]; do
  i=0
  while [ $i -lt ${#LABELS[@]} ]; do
    out=$(ssh -o BatchMode=yes "$HOST" \
      "cd $REMOTE && BIT_WORKERS=$WORKERS BIT_CTXSW_TASKS=$TASKS BIT_CTXSW_TURNS=$TURNS BIT_CTXSW_PERIOD_NS=$PERIOD ./'${LABELS[$i]}'" </dev/null)
    echo "$out" | sed "s/^/[${LABELS[$i]} r$r] /"
    cs=$(echo "$out" | sed -n 's/.*cs_per_wake=\([0-9.]*\).*/\1/p')
    same=$(echo "$out" | sed -n 's/.*same_thread=\([a-z]*\).*/\1/p')
    [ "$same" = "true" ] || { echo "ctxsw: ${LABELS[$i]} round $r migrated between reads — reading discarded" >&2; cs=""; }
    [ -n "$cs" ] && echo "${LABELS[$i]} $cs" >> "$RES"
    i=$((i + 1))
  done
  r=$((r + 1))
done

# --- report -----------------------------------------------------------------
echo "ctxsw summary (cs per timer wake, median of the kept readings)"
for l in "${LABELS[@]}"; do
  vals=$(awk -v l="$l" '$1 == l { print $2 }' "$RES" | sort -n)
  n=$(echo "$vals" | grep -c . || true)
  [ "$n" -gt 0 ] || { echo "  $l  no readings"; continue; }
  med=$(echo "$vals" | awk '{a[NR]=$1} END{ if (NR%2) print a[(NR+1)/2]; else printf "%.3f\n", (a[NR/2]+a[NR/2+1])/2 }')
  echo "  $l  median=$med  n=$n  all=$(echo "$vals" | tr '\n' ' ')"
done
