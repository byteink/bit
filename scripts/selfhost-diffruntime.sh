#!/usr/bin/env bash
# Runtime codegen differential (#1859): run every `runtime/**/*.bit` through both
# compilers' `--dump-ir-pre` and diff the lowered SSA text, then compare
# whole-module object bytes / atomic-instruction-width signatures (#2741,
# #3103, #3110).
#
# Full design record moved to docs/development/runtime-differential.md
# (#4264, to stay under the 800-line file-size ceiling): why this differential
# exists, why IR text alone is not enough, why byte-for-byte identity against
# the pinned release was narrowed to an atomic-instruction-width signature on
# aarch64/x86-64, and why the IR walk is per-file rather than per-module.
# Read it before changing any invariant below.
#
# Usage: ./make selfhost && bash scripts/selfhost-diffruntime.sh
set -uo pipefail
# shellcheck source=scripts/alarmrun.sh
. "$(dirname -- "$0")/alarmrun.sh"
# shellcheck source=scripts/selfhost-ir-signatures.sh
. "$(dirname -- "$0")/selfhost-ir-signatures.sh"
# shellcheck source=scripts/diffexit.sh
. "$(dirname -- "$0")/diffexit.sh"

# Oracle: the pinned stage0 (previous release), like every other differential
# since #1593. scripts/stage0.sh downloads and DIGEST-VERIFIES it and refuses
# rather than skipping, so a failure here is loud. It also pins BIT_STDLIB to
# the WORKING TREE for both sides — without that this would diff two stdlibs
# instead of two compilers.
ORACLE="$(sh scripts/stage0.sh)" || exit 2
BIT2=bit-out/bin/bit
# The alarm is a HANG guard, not a performance budget (#2070). 20s sat below the
# corpus's slowest file measured on the IR differentials (25.20s on this tree,
# 21.86s on the oracle), so a busy box turned a clean run red with no divergence
# at all. 300s is ~12x that, in the spirit of the suite's own 900s-against-158s.
TIMEOUT=${DIFFRUNTIME_TIMEOUT:-300}

# Why a child died, for the report. 128+N is death by signal N; 14 is the alarm
# this script set, so that alone is a timeout and every other signal is a crash.
# Calling a SIGSEGV "timed out" sends the reader after a problem that is not
# there — the same distinction the test harnesses make (#2070, docs/development.md).
sep="  -> "
whydied() {
  case "$1" in
    142) echo "timed out after ${TIMEOUT}s" ;;
    139) echo "CRASHED (SIGSEGV)" ;;
    138) echo "CRASHED (SIGBUS)" ;;
    134) echo "CRASHED (SIGABRT)" ;;
    *)   echo "CRASHED (signal $(( $1 - 128 )))" ;;
  esac
}

# A gate whose population can quietly go to zero passes everything. `runtime/`
# holds 85 `.bit` files today and the walk skips none of them, so a floor well
# under that catches a broken find, a moved directory or a compiler that starts
# refusing every file, while leaving room to delete a module.
MIN_FILES=${DIFFRUNTIME_MIN_FILES:-70}

# A count is not coverage. These are the files carrying hex float literals — the
# construct #1857 got wrong — and each MUST be compared, not merely counted. A
# refactor that makes one unparseable in single-file mode would drop it into the
# skip set, leave the totals looking healthy, and silently retire the only
# regression test this gate exists to provide.
REQUIRED="runtime/root/floatslog.bit runtime/root/floatsatan.bit"

# --- Object-byte module list (#2741): extracted, not hand-copied ---
#
# `PLATFORM_FREE_RELS` / `PLATFORM_PAIRS` come straight out of g2archive.sh —
# never restated here — so the two lists cannot drift the way g2archive.sh's
# own header (lines 106-112 there) warns a hand-maintained copy always does.
# Sourcing the whole file is not an option: it is an argv-driven CLI that
# calls `usage` and exits 2 when run with no arguments.
GARCHIVE="$(dirname "$0")/g2archive.sh"
eval "$(grep -E '^(PLATFORM_FREE_RELS|PLATFORM_PAIRS)=' "$GARCHIVE")"
if [ -z "${PLATFORM_FREE_RELS:-}" ] || [ -z "${PLATFORM_PAIRS:-}" ]; then
  echo "diffruntime: FAIL — could not extract the module list from $GARCHIVE." >&2
  exit 2
fi

# Same OS mapping g2archive.sh uses (aarch64-macos -> darwin; x86_64-linux and
# aarch64-linux both -> linux) restricted to the HOST — this check builds with
# no --target, so `bit build` targets the host by default and the platform
# pair must match it.
case "$(uname -s)" in
  Darwin) PLAT=darwin ;;
  Linux)  PLAT=linux ;;
  *) echo "diffruntime: FAIL — unsupported host $(uname -s) for the object-byte check." >&2; exit 2 ;;
esac

# The invariant that survives #1852-style optimisation is atomic INSTRUCTION
# WIDTH, not full bytes — see the header. Keyed off the CPU, not PLAT: an
# aarch64-linux host gets the same treatment as this aarch64-macos one,
# because it is the same ISA. x86-64 gets its own signature extraction now
# too (header, #3110), verified on real x86_64-linux hardware. Any other ISA
# still keeps the old, stricter, byte-identity check unconditionally.
case "$(uname -m)" in
  arm64|aarch64) ATOMIC_ISA=aarch64 ;;
  x86_64|amd64)  ATOMIC_ISA=x86_64 ;;
  *)             ATOMIC_ISA=other ;;
esac

# The disassembler differs by OS, not by ISA: `otool -tV` on Darwin,
# `objdump -d` on Linux (both understand aarch64 Mach-O/ELF relocatables and
# print the same standard ARM mnemonics — `ldar`, `stlr`, register operand
# `w9`/`x9` — so one extraction regex covers both). The x86-64 extraction
# below is verified against objdump's AT&T-syntax output only (header) but
# reuses this same OS dispatch, so an x86_64-macOS host would still get
# otool's text — untested, guarded by MIN_ATOMIC_SITES below.
disasmText() { # <objfile>
  case "$(uname -s)" in
    Darwin) otool -tV "$1" 2>/dev/null ;;
    Linux)  objdump -d "$1" 2>/dev/null ;;
  esac
}

# Every acquire/release-ordered mnemonic this backend can emit for §11.5's
# atomic builtins, AARCH64 ONLY — see x86AtomicSignature below for why x86-64
# needs a structurally different extraction, not just a different mnemonic
# list. CAS lowers to an ldaxr/stlxr load-linked/store-conditional loop on
# this backend rather than a dedicated `casal`, confirmed by grepping the
# corpus (#3103) — the cas* entries are kept anyway in case that changes; an
# unmatched alternative costs nothing.
ATOMIC_MNEMONICS='ldar|ldarb|ldarh|ldaxr|ldaxrb|ldaxrh|ldapr|ldaprb|ldaprh|ldaxp|stlr|stlrb|stlrh|stlxr|stlxrb|stlxrh|stlxp|cas|casa|casl|casal|casb|casab|caslb|casalb|cash|casah|caslh|casalh|casp|caspa|caspl|caspal'

# x86-64 atomic-instruction-width signature (#3110, header has the full
# derivation and the mutation-test result). Unlike aarch64 this needs two
# discriminators, not one mnemonic list:
#
#   RMW/CAS: `lock (xadd|cmpxchg) %REG,` — register class is the width.
#   STORE:   a `mov %REG,MEM` immediately followed by `mfence` — register
#            class of the mov's SOURCE operand is the width. Adjacency is
#            safe because `xMfence` (compiler/x64select.bit) has exactly one
#            call site, `xEmitAtomicStore`, and emits nothing between the
#            mov and the fence.
#
# Output format matches the aarch64 arm's ("<mnemonic-ish> <class>", sorted,
# one line per site) so both feed the same cmp-based multiset comparison
# below. Register CLASS here is x=64-bit, w=32-bit, h=16-bit, b=8-bit (ARM's
# own naming, reused for one consistent vocabulary across both ISAs) — full,
# not prefix-based, register-name classification, since x86 register names
# (`eax` vs `rax` vs `r13d` vs `r13`) don't share a common numeric suffix to
# strip the way aarch64's `w9`/`x9` do.
x86AtomicSignature() { # <objfile>
  disasmText "$1" | awk '
    function regClass(r) {
      if (r ~ /^r(8|9|1[0-5])$/)               return "x"
      if (r ~ /^r(ax|bx|cx|dx|si|di|bp|sp)$/)  return "x"
      if (r ~ /^r(8|9|1[0-5])d$/)              return "w"
      if (r ~ /^e(ax|bx|cx|dx|si|di|bp|sp)$/)  return "w"
      if (r ~ /^r(8|9|1[0-5])w$/)              return "h"
      if (r ~ /^(ax|bx|cx|dx|si|di|bp|sp)$/)   return "h"
      if (r ~ /^r(8|9|1[0-5])b$/)              return "b"
      if (r ~ /^[abcd]l$/)                     return "b"
      if (r ~ /^(sil|dil|bpl|spl)$/)           return "b"
      return ""
    }
    {
      if (match($0, /lock (cmpxchg|xadd) %[a-z0-9]+,/)) {
        seg = substr($0, RSTART, RLENGTH)
        split(seg, p, " ")
        reg = p[3]; sub(/^%/, "", reg); sub(/,$/, "", reg)
        cls = regClass(reg)
        if (cls != "") print p[2]" "cls
        prevcls = ""
        next
      }
      if (match($0, /mov[ \t]+%[a-z0-9]+,[^\t]*\(%[a-z0-9]+\)/)) {
        seg = substr($0, RSTART, RLENGTH)
        match(seg, /%[a-z0-9]+/)
        reg = substr(seg, RSTART + 1, RLENGTH - 1)
        prevcls = regClass(reg)
        next
      }
      if ($0 ~ /mfence/) {
        if (prevcls != "") print "store " prevcls
        prevcls = ""
        next
      }
      prevcls = ""
    }
  ' | sort
}

# Sorted, register-NUMBER-stripped, register-CLASS-preserved atomic mnemonic
# list for one object — the signature two builds must agree on. Register
# ALLOCATION (which number) legitimately varies with optimisation; register
# CLASS (w=32-bit vs x=64-bit) is fixed by the pointee's declared type
# (§11.5) and is exactly what #2569 got wrong.
atomicSignature() { # <objfile>
  if [ "$ATOMIC_ISA" = x86_64 ]; then
    x86AtomicSignature "$1"
    return
  fi
  disasmText "$1" | grep -oE "\\b(${ATOMIC_MNEMONICS})[[:space:]]+[wx][0-9]+" | sed -E 's/[0-9]+$//' | sort
}

# A count is not coverage (same principle as MIN_FILES/MIN_MODULES below): if
# extraction silently breaks — otool/objdump missing, a mnemonic spelling
# change, a moved tool — every module's signature would go empty on BOTH
# sides and pass vacuously. 362 sites were extracted from the pinned oracle's
# 23 modules on aarch64 when this floor was set (#3103); 300 is comfortably
# under that while still catching an emptied extraction. x86-64's corpus is
# structurally smaller — a store costs 2 instructions (mov+mfence) there
# against 1 (stlr) on aarch64, but there are fewer RMW/CAS sites overall — and
# measured independently on hl-master at 126 (#3110); 100 is the same margin
# in spirit.
MIN_ATOMIC_SITES_DEFAULT=300
[ "$ATOMIC_ISA" = x86_64 ] && MIN_ATOMIC_SITES_DEFAULT=100
MIN_ATOMIC_SITES=${DIFFRUNTIME_MIN_ATOMIC_SITES:-$MIN_ATOMIC_SITES_DEFAULT}
atomic_sites_seen=0

# Same (rel, label) expansion g2archive.sh applies to the same two variables —
# glue over the extracted data, not a second copy of the data itself.
MOD_RELS=()
MOD_LABELS=()
for rel in $PLATFORM_FREE_RELS; do
  if [ "$rel" = "-" ]; then
    MOD_RELS+=("")
    MOD_LABELS+=("runtime")
  else
    MOD_RELS+=("$rel")
    MOD_LABELS+=("runtime_$(printf '%s' "$rel" | tr '/' '_')")
  fi
done
for p in $PLATFORM_PAIRS; do
  MOD_RELS+=("$p/$PLAT")
  MOD_LABELS+=("runtime_${p}_${PLAT}")
done
NMOD=${#MOD_RELS[@]}

# A floor, not an exact match, for the same reason MIN_FILES above is a floor:
# the extracted list is 23 today (16 platform-free entries incl. the bare
# `runtime` dir, + 7 platform pairs) and legitimately grows as modules are
# added — g2archive.sh's own on-disk completeness check (lines 132-157 there)
# is what keeps it honest going forward. 20 is well under 23, so this still
# catches an emptied list or a broken extraction without going stale the next
# time a module is added, which is exactly how #2741's own filing ended up
# citing 22.
MIN_MODULES=${DIFFRUNTIME_MIN_MODULES:-20}

for bin in "$ORACLE" "$BIT2"; do
  [ -x "$bin" ] || { echo "diffruntime: missing $bin — run: ./make selfhost" >&2; exit 2; }
done

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# Per-attempt-truncated captures for the two --dump-ir-pre calls below (#4207,
# same #3478 shape as #4196/#4205): reused across iterations of the sequential
# loop, which is safe because alarmrun_retry_cap truncates each before EVERY
# attempt and the loop never runs the two sides concurrently.
oraclecap="$work/dump.oracle"
bit2cap="$work/dump.bit2"

match=0 skip=0 total=0
: >"$work/mismatch"
: >"$work/explained"
: >"$work/timeout"
: >"$work/oracletimeout"
: >"$work/oraclecrash"
: >"$work/compared"

for f in $(find runtime -name '*.bit' | sort); do
  total=$((total + 1))

  # The oracle is bounded too (#2070). Its timeout is NOT a skip: a skip means
  # the oracle could not lower the file, an expected outcome, while a hang is a
  # broken stage0 — and an unbounded oracle wedged this gate with no message.
  # #3422: verdict-deciding retry, via the capture-truncating retry helper
  # (#3490) so a stalled first attempt's partial bytes can never survive as a
  # prefix inside the retried attempt's compared payload (#3478, #4207) — the
  # old `a=$(alarmrun_retry ...)` command substitution was a sink opened once
  # for both attempts.
  alarmrun_retry_cap ORACLE "" "$oraclecap" "$ORACLE" --dump-ir-pre "$f"
  arc=$?
  a=$(cat "$oraclecap")
  if [ "$arc" -eq 142 ]; then
    echo "$f${sep}$(whydied "$arc")" >>"$work/oracletimeout"
    continue
  fi
  if [ "$arc" -ge 128 ]; then
    echo "$f${sep}$(whydied "$arc")" >>"$work/oraclecrash"
    continue
  fi
  if [ "$arc" -ne 0 ] || [ -z "$a" ]; then
    # The oracle cannot lower it, so there is no verdict to be had. Counted and
    # reported, never scored as agreement (#1514/#1516).
    skip=$((skip + 1))
    continue
  fi

  # Same conversion as the ORACLE call above (#4207).
  alarmrun_retry_cap BIT2 "" "$bit2cap" "$BIT2" --dump-ir-pre "$f"
  rc=$?
  b=$(cat "$bit2cap")
  # >=128 is death by signal, and WHICH signal is not a detail: 142 is our own
  # alarm, anything else is the compiler crashing. Either way no verdict (#2070).
  if [ "$rc" -ge 128 ]; then
    echo "$f${sep}$(whydied "$rc")" >>"$work/timeout"
    continue
  fi
  if [ "$rc" -ne 0 ]; then
    # The oracle lowered it and the working tree could not. That is a
    # regression, not a skip.
    echo "$f (bit failed where stage0 succeeded)" >>"$work/mismatch"
    echo "$f" >>"$work/compared"
    continue
  fi

  echo "$f" >>"$work/compared"
  if [ "$a" = "$b" ]; then
    match=$((match + 1))
  else
    # A raw mismatch is not automatically a regression (#3132, same fix as
    # #3125 one level up): check it against the declared-transform-signature
    # table before scoring it. Only an UNEXPLAINED divergence fails the gate.
    sig=$(explainMismatch "$a" "$b" ir)
    if [ -n "$sig" ]; then
      echo "$f${sep}explained by declared signature '$sig'" >>"$work/explained"
    else
      echo "$f" >>"$work/mismatch"
    fi
  fi
done

# --- Whole-module object comparison (#2741, invariant narrowed by #3103) ---
#
# Same taxonomy as the per-file walk above (oracle hang is a FAIL, oracle
# crash is a NOTE, dev hang/crash is a FAIL, dev build failure where the
# oracle succeeded is a mismatch), applied at module instead of file
# granularity. `-c --freestanding -o` with no `--target` compiles for the
# host, matching `PLAT` resolved above. On aarch64 hosts "compare" means the
# atomic-signature check (header); elsewhere it is still full byte identity.

objdev="$work/obj_dev"
objor="$work/obj_or"
mkdir -p "$objdev" "$objor"

modmatch=0 modskip=0
: >"$work/mod_mismatch"
: >"$work/mod_timeout"
: >"$work/mod_oracletimeout"
: >"$work/mod_oraclecrash"
: >"$work/mod_compared"

i=0
while [ "$i" -lt "$NMOD" ]; do
  rel=${MOD_RELS[$i]}
  label=${MOD_LABELS[$i]}
  i=$((i + 1))
  dir="runtime${rel:+/$rel}"
  devobj="$objdev/${label}.o"
  orobj="$objor/${label}.o"

  alarmrun_retry ORACLE "$orobj" "$ORACLE" build "$dir" -c --freestanding -o "$orobj" >/dev/null  # #3422
  orc=$?
  if [ "$orc" -eq 142 ]; then
    echo "$dir${sep}$(whydied "$orc")" >>"$work/mod_oracletimeout"
    continue
  fi
  if [ "$orc" -ge 128 ]; then
    echo "$dir${sep}$(whydied "$orc")" >>"$work/mod_oraclecrash"
    continue
  fi
  if [ "$orc" -ne 0 ] || [ ! -s "$orobj" ]; then
    # The oracle cannot build this module, so there is no verdict to be had —
    # counted and reported, never scored as agreement (#1514/#1516).
    modskip=$((modskip + 1))
    continue
  fi

  alarmrun_retry BIT2 "$devobj" "$BIT2" build "$dir" -c --freestanding -o "$devobj" >/dev/null  # #3422
  rc=$?
  if [ "$rc" -ge 128 ]; then
    echo "$dir${sep}$(whydied "$rc")" >>"$work/mod_timeout"
    continue
  fi
  if [ "$rc" -ne 0 ] || [ ! -s "$devobj" ]; then
    # The oracle built it and the working tree could not. That is a
    # regression, not a skip.
    echo "$dir (bit failed where stage0 succeeded)" >>"$work/mod_mismatch"
    echo "$dir" >>"$work/mod_compared"
    continue
  fi

  echo "$dir" >>"$work/mod_compared"
  if [ "$ATOMIC_ISA" = aarch64 ] || [ "$ATOMIC_ISA" = x86_64 ]; then
    devsig="$work/sig_dev"
    orsig="$work/sig_or"
    atomicSignature "$devobj" >"$devsig"
    atomicSignature "$orobj" >"$orsig"
    # The floor below counts raw (non-deduped) sites — it exists to catch a
    # broken extraction, not to weigh in on the equality check.
    atomic_sites_seen=$((atomic_sites_seen + $(wc -l <"$orsig")))
    # #3170: compare the SET of (mnemonic, register-class) pairs, not the
    # multiset. The header above says this check "no longer asserts ...
    # instruction COUNT" — the un-deduped `cmp` below it contradicted that:
    # inlining the same atomic into an extra call site (#3164, a legitimate
    # `wordsAt` fold that dropped `trampRelease` under the inline budget)
    # duplicates a line in the sorted list without touching any width, and
    # `cmp` on two differently-sized files always fails. `sort -u` collapses
    # duplicate (mnemonic, class) lines on both sides first; a width flip
    # still fails the comparison because it adds a class absent on the other
    # side or removes the last remaining instance of one — see the ticket
    # (#3170) for the mutation test that confirms the latter.
    if cmp -s <(sort -u "$devsig") <(sort -u "$orsig"); then
      modmatch=$((modmatch + 1))
    else
      echo "$dir" >>"$work/mod_mismatch"
    fi
  elif cmp -s "$devobj" "$orobj"; then
    modmatch=$((modmatch + 1))
  else
    echo "$dir" >>"$work/mod_mismatch"
  fi
done

bad=0
# Real divergence and a broken-harness floor violation always win and exit 1.
# A pure timeout decided nothing -- exit 2 (could-not-decide), tracked
# separately from bad so it can never read as a divergence that was never
# observed (family convention: x64gate.sh, diffverdict.sh,
# selfhost-diffall.sh, #3351/#3377/#3380).
timedout=0

if [ "$total" -lt "$MIN_FILES" ]; then
  echo "diffruntime: FAIL — walked $total file(s), floor is $MIN_FILES." >&2
  echo "  An empty or shrunken walk passes everything; check the find expression." >&2
  bad=1
fi

for r in $REQUIRED; do
  if ! grep -qxF "$r" "$work/compared"; then
    echo "diffruntime: FAIL — required file '$r' was never compared." >&2
    echo "  It carries hex float literals, the construct #1857 got wrong. Losing" >&2
    echo "  coverage of it is a failure, not a smaller number." >&2
    bad=1
  fi
done

if [ -s "$work/oracletimeout" ]; then
  # Apart from ours because it means something different: the PINNED oracle hung,
  # so the corpus shrank rather than this tree misbehaving. Folding it into the
  # skip count would hide that behind a number meaning "the oracle declined it".
  echo "diffruntime: FAIL — the pinned stage0 HUNG (corpus reduced, not verified):" >&2
  sed 's/^/  /' "$work/oracletimeout" >&2
  timedout=1
fi

# Reported, not failed — the oracle is a published immutable binary and no change
# here can stop it faulting, so failing would leave the gate red until the pin
# moves (#1895's routed-around-red hazard). A HANG still fails: that one means the
# run could not complete in bounded time. Naming the file every run is the point;
# before #2070 an oracle crash was an anonymous +1 to the skip count (#2084).
if [ -s "$work/oraclecrash" ]; then
  echo "diffruntime: NOTE — the pinned stage0 crashed, no verdict available (#2084):" >&2
  sed 's/^/  /' "$work/oraclecrash" >&2
fi

if [ -s "$work/timeout" ]; then
  echo "diffruntime: FAIL — no verdict (not a match):" >&2
  sed 's/^/  /' "$work/timeout" >&2
  timedout=1
fi

# NO UNEXPLAINED DIVERGENCE IS PERMITTED. Any runtime file whose IR differs
# from the pinned stage0's, and whose delta does not satisfy a registered
# transform signature (explainMismatch, scripts/selfhost-ir-signatures.sh,
# #3132/#3125), fails the run. There was an expected-mismatch FILE list so a
# known difference could be written down instead of fixed; its last entry
# closed and it was deleted with its reader (#1883) — a signature is not that
# list reborn, see selfhost-ir-signatures.sh's header for why.
#
# The MIN_FILES floor and the REQUIRED list above are a SEPARATE property and
# stay: they prove the run was not vacuous, which an exit code cannot (#1881).
sort -u "$work/mismatch" >"$work/mismatch.sorted"
sort -u "$work/explained" >"$work/explained.sorted"

if [ -s "$work/mismatch.sorted" ]; then
  echo "diffruntime: FAIL — $(wc -l <"$work/mismatch.sorted" | tr -d ' ') file(s) diverge from the pinned stage0:" >&2
  sed 's/^/  /' "$work/mismatch.sorted" >&2
  echo "  Diff one with:  diff <(\"$ORACLE\" --dump-ir-pre FILE) <($BIT2 --dump-ir-pre FILE)" >&2
  bad=1
fi

# Informational, never fails the gate: each of these matched a declared
# transform signature's identity exactly (explainMismatch), a stronger claim
# than "this file is allowed to differ" — see selfhost-ir-signatures.sh's
# header for why that distinction is load-bearing.
if [ -s "$work/explained.sorted" ]; then
  echo "diffruntime: EXPLAINED — $(wc -l <"$work/explained.sorted" | tr -d ' ') file(s) diverge from the pinned stage0 but match a declared lowering-transform signature (not a regression):"
  sed 's/^/  /' "$work/explained.sorted"
fi

# --- Object-byte checks (#2741), mirroring the IR-walk checks above ---

if [ "$NMOD" -lt "$MIN_MODULES" ]; then
  echo "diffruntime: FAIL — extracted $NMOD archive module(s) from $GARCHIVE, floor is $MIN_MODULES." >&2
  echo "  An emptied or badly-split module list passes everything; check" >&2
  echo "  PLATFORM_FREE_RELS/PLATFORM_PAIRS there." >&2
  bad=1
fi

# Same "count is not coverage" floor defined (with the full rationale) at
# MIN_ATOMIC_SITES_DEFAULT above — not restated here.
if { [ "$ATOMIC_ISA" = aarch64 ] || [ "$ATOMIC_ISA" = x86_64 ]; } && [ "$atomic_sites_seen" -lt "$MIN_ATOMIC_SITES" ]; then
  echo "diffruntime: FAIL — extracted $atomic_sites_seen atomic-instruction site(s) from the oracle's objects, floor is $MIN_ATOMIC_SITES." >&2
  echo "  An emptied atomic-signature extraction passes everything; check ATOMIC_MNEMONICS" >&2
  echo "  (aarch64) or x86AtomicSignature (x86-64), and that otool/objdump are on PATH and" >&2
  echo "  can disassemble these objects." >&2
  bad=1
fi

if [ -s "$work/mod_oracletimeout" ]; then
  echo "diffruntime: FAIL — the pinned stage0 HUNG building a runtime module (corpus reduced, not verified):" >&2
  sed 's/^/  /' "$work/mod_oracletimeout" >&2
  timedout=1
fi

if [ -s "$work/mod_oraclecrash" ]; then
  echo "diffruntime: NOTE — the pinned stage0 crashed building a runtime module, no verdict available (#2084):" >&2
  sed 's/^/  /' "$work/mod_oraclecrash" >&2
fi

if [ -s "$work/mod_timeout" ]; then
  echo "diffruntime: FAIL — no verdict building a runtime module (not a match):" >&2
  sed 's/^/  /' "$work/mod_timeout" >&2
  timedout=1
fi

sort -u "$work/mod_mismatch" >"$work/mod_mismatch.sorted"

if [ -s "$work/mod_mismatch.sorted" ]; then
  what="object bytes"
  { [ "$ATOMIC_ISA" = aarch64 ] || [ "$ATOMIC_ISA" = x86_64 ]; } && what="atomic-instruction width signature — see the header before assuming this is a real bug"
  echo "diffruntime: FAIL — $(wc -l <"$work/mod_mismatch.sorted" | tr -d ' ') runtime module(s) diverge from the pinned stage0 ($what):" >&2
  sed 's/^/  /' "$work/mod_mismatch.sorted" >&2
  if [ "$ATOMIC_ISA" = aarch64 ] || [ "$ATOMIC_ISA" = x86_64 ]; then
    dtool="otool -tV"; [ "$(uname -s)" = Linux ] && dtool="objdump -d"
    echo "  Compare one with:  \"$ORACLE\" build MODULE -c --freestanding -o /tmp/or.o && $BIT2 build MODULE -c --freestanding -o /tmp/dev.o && diff <($dtool /tmp/or.o) <($dtool /tmp/dev.o)" >&2
  else
    echo "  Rebuild one with:  \"$ORACLE\" build MODULE -c --freestanding -o /tmp/or.o && $BIT2 build MODULE -c --freestanding -o /tmp/dev.o && cmp /tmp/or.o /tmp/dev.o" >&2
  fi
  bad=1
fi

# $timedout is a 0/1 "did anything time out" flag (four sources feed it above);
# the actual count named in diffexit's UNDECIDED line is summed separately so
# the message is accurate when more than one source timed out.
timedoutfiles=$(( $(wc -l <"$work/oracletimeout" | tr -d ' ') + $(wc -l <"$work/timeout" | tr -d ' ') +
  $(wc -l <"$work/mod_oracletimeout" | tr -d ' ') + $(wc -l <"$work/mod_timeout" | tr -d ' ') ))

if [ "$bad" -eq 0 ] && [ "$timedout" -eq 0 ]; then
  modwhat="byte-identical"
  { [ "$ATOMIC_ISA" = aarch64 ] || [ "$ATOMIC_ISA" = x86_64 ]; } && modwhat="atomic-width-signature-identical"
  explained=$(wc -l <"$work/explained.sorted" | tr -d ' ')
  echo "diffruntime: PASS — $match/$total runtime file(s) lower identically ($skip skipped, $explained explained); $modmatch/$NMOD runtime module(s) $modwhat ($modskip skipped, object)"
fi
diffexit "runtime" -f "$bad" -t "runtime file(s)=$timedoutfiles"
