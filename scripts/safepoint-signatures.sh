#!/usr/bin/env bash
# Sourced-only (by scripts/selfhost-diffsafepoints.sh): the declared signatures that read the two
# OBJECTS, split out of that file when it reached the 800-line ceiling. No top-level statement, so
# test-shebang-mode accepts mode 100644. Both retire at the first repin after 0.39.0.
#
# explainSpreadDelta is #7377, moved here unchanged. explainInstanceDelta is #7482.

# --- 7377-bulk-spread-append: against the 0.39.0 oracle; retires at the next repin
# #7377 lowers `append(dst, ...src)` to ONE `rt_call slice_append_slice`; the 0.39.0
# oracle lowers it to a per-element loop whose back edge carries a poll. So every
# spread the tree compiles has one poll fewer, in any module the file imports
# (--dump-ir shows only the main module, so this reads the OBJECTS). Measured at
# main 091e74450 on all 61 mismatching files: oracle bulk calls 0, polls lost ==
# bulk calls in the tree, and per function lost polls == the function's bulk calls
# (stdlib/cbor, stdlib/tls, pkg/web/openapi.bit, run_append_spread.bit,
# decimal_collections.bit); no function lost a poll without a bulk call. The bulk
# call is an ordinary call safepoint with its own stack map and is the only place
# the move can collect (allocBuf, before any element moves), so no root is lost.
# A MISSING poll beyond the bulk calls is NEVER explained (ABI.md 5).
# explainSpreadDelta <seed> <self> <oracle_bulk_calls> <bit2_bulk_calls>
explainSpreadDelta() {
  [ "$(($1 - $2))" -gt 0 ] && [ "$3" -eq 0 ] && [ "$4" -eq "$(($1 - $2))" ] || return 1
  echo "7377-bulk-spread-append"
}
spreadCalls() {
  objdump -r "$1" 2>/dev/null | grep -c 'bit_rt_slice_append_slice'
}

# --- 7482-aliased-generic-instance-methods: against the 0.39.0 oracle; retires at the next repin
# #7482 instantiates a generic class imported under an alias (`import { Pool as P }`;
# stdlib/sql/pool.bit does since #6024). The 0.39.0 oracle keys the instantiation on the alias,
# gets the bare template, REFERENCES its methods (`_m7$init$t443`) and never emits them; the tree
# emits the instance (`_m7$init$t484`, nineteen methods of std/sync's Pool<slot>), and those
# functions hold polls of their own. Measured by building the tree with and without cc924d944
# (compiler/checkinst.bit reverted, same corpus): the objects differ in exactly those functions
# and the polls inside them (run_import_alias_generic_pool 150 -> 155, run_sql_row_find 879 -> 884
# next to its seven 7377 spreads).
#
# The identity reads `objdump -d -r` of both objects, per function, names canonical (`$t<id>`
# written `$t`, since type ids move between compilers):
#   - the oracle references at least one instance symbol (`...$t<id>`) it does not define, and
#     every such symbol is defined by the tree;
#   - every function the oracle defines the tree defines (nothing is lost);
#   - every function the tree defines and the oracle does not is an instance symbol (the
#     dangling references above name some of them, the rest are what those call);
#   - for every function both define: oracle polls - tree polls == tree bulk calls (the 7377
#     rule), the oracle having none;
#   - self - seed == (polls in the functions only the tree defines) - (tree bulk calls), which
#     ties the per-function read to the counts the differential compares.
# A function that loses a poll beyond its bulk calls is NEVER explained (ABI.md 5).
# explainInstanceText <oracle_dis> <tree_dis> <seed> <self>   (the two `objdump -d -r` texts)
explainInstanceText() {
  awk -v seed="$3" -v self="$4" '
    function canon(n) { gsub(/\$t[0-9]+/, "$t", n); return n }
    FNR == 1 { fi++ }
    $0 ~ /^[0-9a-f]+ <.*>:$/ {
      cur = substr($0, index($0, "<") + 1); sub(/>:$/, "", cur)
      raw[fi, cur] = 1; cur = canon(cur); def[fi, cur] = 1; names[cur] = 1
      next
    }
    $1 ~ /^[0-9a-f]+:$/ && $2 ~ /^[A-Z][A-Z0-9_]*$/ && NF >= 3 && cur != "" {
      t = $NF; sub(/[-+]0x[0-9a-f]+$/, "", t)
      if (t ~ /bit_rt_safepoint$/) { polls[fi, cur]++ }
      else if (t ~ /bit_rt_slice_append_slice$/) { bulk[fi, cur]++ }
      else if (t ~ /\$t[0-9]+$/) { refs[fi, ++nref[fi]] = t }
    }
    END {
      for (n in names) {
        if (def[1, n] && !def[2, n]) { exit 1 }
        if (def[1, n]) {
          if (bulk[1, n] != 0 || polls[1, n] - polls[2, n] != bulk[2, n]) { exit 1 }
          nb += bulk[2, n]
        } else {
          if (n !~ /\$t$/) { exit 1 }
          ne += polls[2, n]; ntree++
        }
      }
      if (ntree == 0) { exit 1 }
      for (i = 1; i <= nref[1]; i++) {
        t = refs[1, i]
        if (raw[1, t]) { continue }
        if (!def[2, canon(t)]) { exit 1 }
        dangling++
      }
      if (dangling == 0 || self - seed != ne - nb) { exit 1 }
      print "7482-aliased-generic-instance-methods"
      exit 0
    }
  ' <(printf '%s\n' "$1") <(printf '%s\n' "$2")
}
# explainInstanceDelta <oracle_obj> <tree_obj> <seed> <self>
explainInstanceDelta() {
  explainInstanceText "$(objdump -d -r --no-show-raw-insn "$1" 2>/dev/null)" "$(objdump -d -r --no-show-raw-insn "$2" 2>/dev/null)" "$3" "$4"
}

# The self-tests prove each signature here REFUSES, not only accepts (the mute button #1883 deleted
# would explain everything). Each prints one line and returns 1 on the first FATAL.
# spreadcheck <want, "" = refuse> <name> <the four explainSpreadDelta args>
spreadcheck() {
  local got
  got=$(explainSpreadDelta "$3" "$4" "$5" "$6")
  [ "$got" = "$1" ] || { echo "FATAL: spread self-test '$2': got '$got', want '$1'" >&2; return 1; }
}
# instcheck <want, "" = refuse> <name> <oracle_dis> <tree_dis> <seed> <self>
instcheck() {
  local got
  got=$(explainInstanceText "$3" "$4" "$5" "$6")
  [ "$got" = "$1" ] || { echo "FATAL: instance self-test '$2': got '$got', want '$1'" >&2; return 1; }
}
spreadSelfTests() {
  spreadcheck "7377-bulk-spread-append" "seven polls lost, seven bulk calls" 734 727 0 7 &&
  spreadcheck "" "a poll lost beyond the bulk calls" 734 726 0 7 &&
  spreadcheck "" "a bulk call that lost no poll" 734 727 0 8 &&
  spreadcheck "" "an EXTRA poll is not this signature" 727 734 0 7 &&
  spreadcheck "" "the oracle already bulk-appends" 734 727 7 7 &&
  spreadcheck "" "equal counts" 5 5 0 0 &&
  spreadcheck "" "polls lost with no bulk call" 734 727 0 0 || {
    echo "FATAL: the spread signature is broken; EXPLAINED would be meaningless." >&2
    return 1
  }
  echo "self-test: spread signature — 1 accepted, 6 refused"
}
# The reduced objects: `f` calls the template's init (oracle) or the instance's (tree), `g` has one
# poll, and the instance holds two. Registers and addresses are not read, only names and relocations.
instSelfTests() {
  local poll sp oracle tree
  poll=$'\t\t0000000000000004:  ARM64_RELOC_BRANCH26\t_bit_rt_safepoint'
  sp=$'\t\t0000000000000008:  ARM64_RELOC_BRANCH26\t_bit_rt_slice_append_slice'
  oracle="0000000000000000 <_f>:
"$'\t\t0000000000000000:  ARM64_RELOC_BRANCH26\t_m7$init$t443'"
$poll
0000000000000100 <_g>:
$poll"
  tree="0000000000000000 <_f>:
"$'\t\t0000000000000000:  ARM64_RELOC_BRANCH26\t_m7$init$t484'"
$poll
0000000000000100 <_g>:
$poll
0000000000000200 <_m7\$init\$t484>:
$poll
$poll"
  instcheck "7482-aliased-generic-instance-methods" "two polls in the emitted instance" "$oracle" "$tree" 2 4 &&
  instcheck "7482-aliased-generic-instance-methods" "the same next to a spread (one poll lost, one bulk call)" \
    "$oracle
$poll" "${tree/<_g>:/<_g>:
$sp}" 3 4 &&
  instcheck "" "a MISSING poll in a function both define" "$oracle" "${tree/<_g>:
$poll/<_g>:}" 2 3 &&
  instcheck "" "counts that do not follow from the functions" "$oracle" "$tree" 2 5 &&
  instcheck "" "no emitted instance" "$oracle" "$oracle" 2 2 &&
  instcheck "" "an instance the oracle never referenced" "${oracle//t443/x}" "$tree" 2 4 &&
  instcheck "" "a function only the oracle defines" "$oracle
0000000000000300 <_h>:
$poll" "$tree" 2 3 &&
  instcheck "" "a tree-only function that is not an instance symbol" "$oracle" "$tree
0000000000000300 <_h>:
$poll" 2 5 &&
  instcheck "" "an oracle that already bulk-appends" "$oracle
$sp" "$tree
$sp" 2 4 || {
    echo "FATAL: the instance signature is broken; EXPLAINED would be meaningless." >&2
    return 1
  }
  echo "self-test: instance signature — 2 accepted, 7 refused"
}
