# Sourced-only (by scripts/selfhost-ir-signatures.sh): the 7737-forof-len-once signature, split out so
# scripts/ir-signatures-walk.sh stays under the 800-line ceiling. It retires at the next stage0 repin
# (#6533). The identity and the files it explains are in selfhost-ir-signatures.sh under "Declared
# signatures"; the trials that use it are explainIrLag in scripts/ir-signatures-walk.sh.
#
# #7737 (lowerForOf, lowerForIn) reads the length of a ranged slice ONCE, in the block that jumps into
# the loop, and carries it through every block of the loop as one more block parameter; the pinned
# stage0 read `slice_len` of the ranged slice in the loop header, every iteration. irForOfUnhoist
# rewrites the TREE dump back to the oracle's shape and the trials then compare as usual, so the
# rewrite can only ever make the tree look like the oracle on exactly this shape.
#
# One loop is rewritten when ALL of these hold, else it is left alone (and the file stays unexplained):
#   - a `jump bbH(...)` whose previous line is `%V = slice_len %X`, passing %V at position p >= 3 and
#     %X at position p-2 (the ranged slice, then the cursor at p-1, then the length);
#   - bbH's first line is `%c = icmp_slt bool %<param p-1>, %<param p>`;
#   - the carriers - %V and every block parameter that receives only %V or another carrier, found as
#     the greatest fixpoint reachable from %V over every jump/br edge of the function - are used
#     nowhere except as edge arguments into other carriers, and in that one compare (a `ptrs=[...]`
#     list holds byte offsets spelled like ids, irdump.bit dumpValList, and is not a use);
#   - every edge into a carrier passes a carrier and no edge passes a carrier to a non-carrier. A block
#     no edge enters (code after a body that always returns) has parameters nothing flows into: one
#     is a carrier when every edge passing it lands on a carrier position.
# The rewrite deletes `%V = slice_len %X`, every carrier parameter and every edge argument into one,
# and puts `%n = slice_len %<param p-2>` before the compare, which then reads %n.
irForOfAwk() {
  IR_FOROF_COMMON='function parseFunc(   i, b, inner, k, m, s, t, e, a, rest, hdr) {
  nb = 0; ne = 0; maxid = 0; delete PK; delete NP; delete PID; delete PTX; delete BI; delete BLK
  delete ET; delete EA; delete NA; delete EL; delete INC; firstB = ""
  for (i = 1; i <= n0; i++) {
    s = L[i]
    t = s
    while (match(t, /%[0-9]+/)) { m = substr(t, RSTART + 1, RLENGTH - 1) + 0; if (m > maxid) { maxid = m }; t = substr(t, RSTART + RLENGTH) }
    if (s ~ /^bb[0-9]+\(/) {
      b = s; sub(/\(.*$/, "", b); BI[b] = i; BLK[i] = b; nb++
      if (firstB == "") { firstB = b }
      inner = s; sub(/^bb[0-9]+\(/, "", inner); sub(/\):$/, "", inner)
      k = 0
      while (inner != "") {
        match(inner, /^%[0-9]+: /); id = substr(inner, 1, RLENGTH - 2); inner = substr(inner, RSTART + RLENGTH)
        if (match(inner, /, %[0-9]+: /)) { ty = substr(inner, 1, RSTART - 1); inner = substr(inner, RSTART + 2) } else { ty = inner; inner = "" }
        k++; PID[b, k] = id; PTX[b, k] = ty; PK[id] = b SUBSEP k
      }
      NP[b] = k
    } else if (s ~ /^  (jump|br) /) {
      t = s
      while (match(t, /bb[0-9]+\([^)]*\)/)) {
        e = substr(t, RSTART, RLENGTH); t = substr(t, RSTART + RLENGTH)
        ne++; b = e; sub(/\(.*$/, "", b); ET[ne] = b; EL[ne] = i; INC[b]++
        rest = e; sub(/^bb[0-9]+\(/, "", rest); sub(/\)$/, "", rest)
        NA[ne] = (rest == "") ? 0 : split(rest, a, ", ")
        for (k = 1; k <= NA[ne]; k++) { EA[ne, k] = a[k] }
      }
    }
  }
}
function rebuildEdges(s,   out, e, b, rest, a, n, k, j, parts) {
  out = ""
  while (match(s, /bb[0-9]+\([^)]*\)/)) {
    e = substr(s, RSTART, RLENGTH)
    b = e; sub(/\(.*$/, "", b)
    rest = e; sub(/^bb[0-9]+\(/, "", rest); sub(/\)$/, "", rest)
    n = (rest == "") ? 0 : split(rest, a, ", ")
    parts = ""
    for (k = 1; k <= n; k++) { if (!(C[b, k] && R[b, k])) { parts = parts (parts == "" ? "" : ", ") a[k] } }
    out = out substr(s, 1, RSTART - 1) b "(" parts ")"
    s = substr(s, RSTART + RLENGTH)
  }
  return out s
}
function rebuildHeader(b,   k, parts) {
  parts = ""
  for (k = 1; k <= NP[b]; k++) { if (!(C[b, k] && R[b, k])) { parts = parts (parts == "" ? "" : ", ") PID[b, k] ": " PTX[b, k] } }
  return b "(" parts "):"
}'
  IR_FOROF_AWK="${IR_FOROF_COMMON}"'

# A block no edge enters (the code after a body that always returns) has no value flowing into its
# parameters, so the forward walk cannot reach them. Such a parameter is a carrier when every edge
# that passes it lands on a carrier position and at least one does.
function deadParams(   b, k, e, j, found, bad) {
  for (b in NP) {
    if (INC[b] > 0 || b == firstB) { continue }
    for (k = 1; k <= NP[b]; k++) {
      found = 0; bad = 0
      for (e = 1; e <= ne; e++) {
        for (j = 1; j <= NA[e]; j++) {
          if (EA[e, j] != PID[b, k]) { continue }
          if (C[ET[e], j]) { found = 1 } else { bad = 1 }
        }
      }
      if (found && !bad) { R[b, k] = 1 }
    }
  }
}
function carriers(V, H, p,   ch, e, k, t, arg, ok, b) {
  delete C; delete R
  for (e = 1; e <= ne; e++) { for (k = 1; k <= NA[e]; k++) { C[ET[e], k] = 1 } }
  for (b in NP) {
    if (INC[b] > 0 || b == firstB) { continue }
    for (k = 1; k <= NP[b]; k++) { C[b, k] = 1 }
  }
  ch = 1
  while (ch) {
    ch = 0
    for (e = 1; e <= ne; e++) {
      for (k = 1; k <= NA[e]; k++) {
        arg = EA[e, k]; t = ET[e]
        if (!C[t, k]) { continue }
        ok = (arg == V) || ((arg in PK) && C[PK[arg]])
        if (!ok) { C[t, k] = 0; ch = 1 }
      }
    }
  }
  deadParams()
  ch = 1
  while (ch) {
    ch = 0
    for (e = 1; e <= ne; e++) {
      for (k = 1; k <= NA[e]; k++) {
        arg = EA[e, k]; t = ET[e]
        if (C[t, k] && !R[t, k] && (arg == V || ((arg in PK) && R[PK[arg]]))) { R[t, k] = 1; ch = 1 }
      }
    }
  }
  return (C[H, p] && R[H, p])
}
function isCarrier(id) { return (id in PK) && C[PK[id]] && R[PK[id]] }
function usesClean(V, vline, cmpLine,   i, s, t, tok) {
  for (i = 1; i <= n0; i++) {
    if (i == vline || i == cmpLine || (i in BLK)) { continue }
    s = L[i]
    gsub(/bb[0-9]+\([^)]*\)/, "", s)
    gsub(/ptrs=\[[^]]*\]/, "", s)
    while (match(s, /%[0-9]+/)) {
      tok = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH)
      if (tok == V || isCarrier(tok)) { return 0 }
    }
  }
  return 1
}
function edgesClean(V,   e, k, arg) {
  for (e = 1; e <= ne; e++) {
    for (k = 1; k <= NA[e]; k++) {
      arg = EA[e, k]
      if ((arg == V || isCarrier(arg)) && !(C[ET[e], k] && R[ET[e], k])) { return 0 }
      if (C[ET[e], k] && R[ET[e], k] && !(arg == V || isCarrier(arg))) { return 0 }
    }
  }
  return 1
}
function tryOne(   i, s, V, X, H, p, e, k, cmpLine, ci, cmpId, iter, idx, len, nn, out, j, b) {
  for (e = 1; e <= ne; e++) {
    i = EL[e]
    if (L[i] !~ /^  jump / || i < 2 || (i, "x") in SKIP) { continue }
    if (!match(L[i - 1], /^  %[0-9]+ = slice_len %[0-9]+$/)) { continue }
    V = L[i - 1]; sub(/^  /, "", V); sub(/ = .*$/, "", V)
    X = L[i - 1]; sub(/^.* = slice_len /, "", X)
    H = ET[e]; p = 0
    for (k = 1; k <= NA[e]; k++) { if (EA[e, k] == V) { if (p) { p = -1 } else { p = k } } }
    if (p < 3 || EA[e, p - 2] != X) { SKIP[i, "x"] = 1; continue }
    cmpLine = BI[H] + 1
    iter = PID[H, p - 2]; idx = PID[H, p - 1]; len = PID[H, p]
    if (!match(L[cmpLine], /^  %[0-9]+ = icmp_slt bool %[0-9]+, %[0-9]+$/)) { SKIP[i, "x"] = 1; continue }
    cmpId = L[cmpLine]; sub(/^  /, "", cmpId); sub(/ = .*$/, "", cmpId)
    if (L[cmpLine] != "  " cmpId " = icmp_slt bool " idx ", " len) { SKIP[i, "x"] = 1; continue }
    if (!carriers(V, H, p) || !edgesClean(V) || !usesClean(V, i - 1, cmpLine)) { SKIP[i, "x"] = 1; continue }
    nn = "%" (maxid + 1)
    out = 0
    for (j = 1; j <= n0; j++) {
      if (j == i - 1) { continue }
      if (j == cmpLine) {
        N2[++out] = "  " nn " = slice_len " iter
        N2[++out] = "  " cmpId " = icmp_slt bool " idx ", " nn
        continue
      }
      if (j in BLK) { N2[++out] = rebuildHeader(BLK[j]); continue }
      N2[++out] = (L[j] ~ /^  (jump|br) /) ? rebuildEdges(L[j]) : L[j]
    }
    for (j = 1; j <= out; j++) { L[j] = N2[j] }
    n0 = out; delete N2
    return 1
  }
  return 0
}
function flush(   i, rounds, fired) {
  fired = 0
  for (rounds = 0; rounds < 64; rounds++) {
    parseFunc()
    if (!tryOne()) { break }
    fired++; delete SKIP
  }
  total += fired
  for (i = 1; i <= n0; i++) { print L[i] }
  n0 = 0; delete L; delete SKIP
}
/^func / { flush(); print; next }
{ L[++n0] = $0 }
END { flush(); if (total == 0) { exit 1 } }'
  irDedupAwk
}


# irDedupAwk -- IR_DEDUP_AWK: the trivial-phi cleanup of SSA construction (Braun et al.) on the text of a
# dump. A block parameter whose incoming edges all pass one value, or the parameter itself, holds that
# value, so it is deleted and its uses read the value; the arguments are compared after the parameters
# already deleted are resolved, which is what lets a loop-carried invariant that comes back through a
# join block's own parameter collapse. It runs on BOTH sides of the iropt trial: the loop lowering of
# #7737 carries the length through the loop's blocks as a parameter, while the optimizer of the pinned
# stage0 made the same invariant a header parameter of its own, so the two dumps differ in how many
# copies of one value the loop carries and through which blocks, not in what the loop computes.
irDedupAwk() {
  IR_DEDUP_AWK="${IR_FOROF_COMMON}"'
function res(x,   n) {
  n = 0
  while ((x in REN) && n < 1000) { x = REN[x]; n++ }
  return x
}
function rnAll(s,   out, p, q) {
  p = index(s, "ptrs=[")
  if (p > 0) {
    q = index(substr(s, p), "]")
    return rnAll(substr(s, 1, p - 1)) substr(s, p, q) rnAll(substr(s, p + q))
  }
  out = ""
  while (match(s, /%[0-9]+/)) {
    out = out substr(s, 1, RSTART - 1) res(substr(s, RSTART, RLENGTH))
    s = substr(s, RSTART + RLENGTH)
  }
  return out s
}
function trivialParam(b, k,   e, a, v, p) {
  p = PID[b, k]; v = ""
  for (e = 1; e <= NEB[b]; e++) {
    a = res(EA[EB[b, e], k])
    if (a == p) { continue }
    if (v == "") { v = a } else if (a != v) { return "" }
  }
  return v
}
function findDup(   b, k, v, ch, any, e) {
  delete C; delete R; delete REN; delete EB; delete NEB; any = 0
  for (e = 1; e <= ne; e++) { EB[ET[e], ++NEB[ET[e]]] = e }
  ch = 1
  while (ch) {
    ch = 0
    for (b in NP) {
      if (b == firstB || INC[b] == 0) { continue }
      for (k = 1; k <= NP[b]; k++) {
        if (PID[b, k] in REN) { continue }
        v = trivialParam(b, k)
        if (v != "") { REN[PID[b, k]] = v; C[b, k] = 1; R[b, k] = 1; ch = 1; any = 1 }
      }
    }
  }
  return deadParams() || any
}
# A parameter nothing reads except as the argument of another dead parameter (a value carried round a
# loop and never used) is dead too: start from every parameter with no reader outside the edges and
# keep removing those an edge hands to a live one. Edges into a parameter already merged away are
# dropped with it.
function deadParams(   i, s, t, tok, e, k, a, ch, any, b, tgt) {
  delete USEDOUT; delete DEADP; any = 0
  for (i = 1; i <= n0; i++) {
    if (i in BLK) { continue }
    s = L[i]; gsub(/bb[0-9]+\([^)]*\)/, "", s); gsub(/ptrs=\[[^]]*\]/, "", s)
    while (match(s, /%[0-9]+/)) { USEDOUT[res(substr(s, RSTART, RLENGTH))] = 1; s = substr(s, RSTART + RLENGTH) }
  }
  for (b in NP) {
    if (b == firstB || INC[b] == 0) { continue }
    for (k = 1; k <= NP[b]; k++) { if (!(PID[b, k] in REN) && !(PID[b, k] in USEDOUT)) { DEADP[PID[b, k]] = 1 } }
  }
  ch = 1
  while (ch) {
    ch = 0
    for (e = 1; e <= ne; e++) {
      for (k = 1; k <= NA[e]; k++) {
        a = res(EA[e, k])
        if (!(a in DEADP) || !(a in PK)) { continue }
        tgt = PID[ET[e], k]
        if (!((tgt in DEADP) || (tgt in REN))) { delete DEADP[a]; ch = 1 }
      }
    }
  }
  for (a in DEADP) { C[PK[a]] = 1; R[PK[a]] = 1; any = 1 }
  return any
}
function applyDup(   i) {
  for (i = 1; i <= n0; i++) {
    if (i in BLK) { N2[i] = rebuildHeader(BLK[i]); continue }
    N2[i] = rnAll((L[i] ~ /^  (jump|br) /) ? rebuildEdges(L[i]) : L[i])
  }
  for (i = 1; i <= n0; i++) { L[i] = N2[i] }
  delete N2
}
function flush(   i, rounds) {
  for (rounds = 0; rounds < 8; rounds++) {
    parseFunc()
    if (!findDup()) { break }
    applyDup()
  }
  for (i = 1; i <= n0; i++) { print L[i] }
  n0 = 0; delete L
}
/^func / { flush(); print; next }
{ L[++n0] = $0 }
END { flush() }'
}

# irParamDedup <dump> -- the dump with every trivial block parameter deleted (IR_DEDUP_AWK).
irParamDedup() {
  irForOfAwk
  printf '%s\n' "$1" | LC_ALL=C awk "${IR_DEDUP_AWK}"
}

# irDropDeadLoads <dump> -- the dump without the `slice_len` and `field_get` lines whose result nothing
# reads, repeated until none is left. Hoisting a header word load out of a loop leaves the copy in the
# preheader behind when its only reader has gone; the two compilers disagree about which loops keep
# one, and the load has no effect, so it is dropped from both sides of the iropt trial.
irDropDeadLoads() {
  printf '%s\n' "$1" | LC_ALL=C awk '
function flush(   i, r, v, s, tok, ch) {
  for (r = 0; r < 16; r++) {
    delete USES
    for (i = 1; i <= n0; i++) {
      if (dead[i]) { continue }
      s = L[i]; gsub(/ptrs=\[[^]]*\]/, "", s)
      while (match(s, /%[0-9]+/)) { USES[substr(s, RSTART, RLENGTH)]++; s = substr(s, RSTART + RLENGTH) }
    }
    ch = 0
    for (i = 1; i <= n0; i++) {
      if (dead[i] || !match(L[i], /^  %[0-9]+ = (slice_len|field_get) /)) { continue }
      v = L[i]; sub(/^  /, "", v); sub(/ = .*$/, "", v)
      if (USES[v] == 1) { dead[i] = 1; ch = 1 }
    }
    if (!ch) { break }
  }
  for (i = 1; i <= n0; i++) { if (!dead[i]) { print L[i] } }
  n0 = 0; delete L; delete dead
}
/^func / { flush(); print; next }
{ L[++n0] = $0 }
END { flush() }'
}

# irLenToHeader <dump> -- for a dump the parameter cleanup above has already run over: the optimizer
# threads the hoisted length into the loop header as a plain dominating value, so the compare in the
# header reads a `slice_len` that sits in the block before the loop. When the first line of a block is
# `%c = icmp_slt bool %i, %v`, `%v` is `slice_len %x` defined in another block and that compare is its
# only use, the definition moves to just before the compare - where the pinned stage0 leaves it - and
# nothing else changes (`%x` dominates `%v`'s block, which dominates the header). Exits 1 when no
# compare matched.
irLenToHeader() {
  printf '%s\n' "$1" | LC_ALL=C awk '
function flush(   i, b, v, x, nu, m, s, t, tok) {
  blk = ""; delete DEF; delete DEFB; delete USES; delete FIRST
  for (i = 1; i <= n0; i++) {
    if (L[i] ~ /^bb[0-9]+\(/) { blk = L[i]; sub(/\(.*$/, "", blk); first = 1; continue }
    if (first) { FIRST[blk] = i; first = 0 }
    if (match(L[i], /^  %[0-9]+ = slice_len %[0-9]+$/)) {
      v = L[i]; sub(/^  /, "", v); sub(/ = .*$/, "", v); DEF[v] = i; DEFB[v] = blk
    }
    s = L[i]; gsub(/ptrs=\[[^]]*\]/, "", s)
    while (match(s, /%[0-9]+/)) { tok = substr(s, RSTART, RLENGTH); USES[tok]++; s = substr(s, RSTART + RLENGTH) }
  }
  delete MOVE
  for (b in FIRST) {
    i = FIRST[b]
    if (!match(L[i], /^  %[0-9]+ = icmp_slt bool %[0-9]+, %[0-9]+$/)) { continue }
    v = L[i]; sub(/^.*, /, "", v)
    if ((v in DEF) && DEFB[v] != b && USES[v] == 2 && !(DEF[v] in MOVE)) { MOVE[DEF[v]] = i; moved++ }
  }
  for (i = 1; i <= n0; i++) {
    if (i in MOVE) { continue }
    for (m in MOVE) { if (MOVE[m] == i) { print L[m] } }
    print L[i]
  }
  n0 = 0; delete L
}
/^func / { flush(); print; next }
{ L[++n0] = $0 }
END { flush(); if (moved == 0) { exit 1 } }'
}

# irForOfUnhoist <bit2_text> -- the tree dump with every loop the rule above matches rewritten to the
# oracle's shape; prints nothing and returns 1 when no loop matched.
irForOfUnhoist() {
  irForOfAwk
  printf '%s\n' "$1" | LC_ALL=C awk "${IR_FOROF_AWK}"
}

# explainForOfLen <oracle_text> <bit2_text> <kind: ir|iropt> -- prints the signature and returns 0 when
# the rewritten tree dump agrees with the oracle's under the same trials explainIrLag runs on the
# unrewritten one (a file that needs the packing, the rune call or the forwarded loads as well is named
# for that signature, a file that needs only this one for 7737-forof-len-once). The iropt arm adds the stage-1b trials, the ir arm has no CSE.
explainForOfLen() {
  local t o u
  o=$1
  if [ "$3" = iropt ]; then
    o=$(irDropDeadLoads "$(irParamDedup "${o}")")
    # Both spellings: the optimizer may already have hoisted the unhoisted compare's `slice_len` into
    # the preheader, in which case putting it back moves it away from where the oracle has it and the
    # parameters alone differ.
    u=$(irForOfUnhoist "$2") && forOfTrials "${o}" "$(irDropDeadLoads "$(irParamDedup "${u}")")" "$3" && return 0
    t=$(irDropDeadLoads "$(irParamDedup "$2")")
    forOfTrials "${o}" "${t}" "$3" && return 0
    u=$(irLenToHeader "${t}") && forOfTrials "${o}" "${u}" "$3" && return 0
    return 1
  fi
  t=$(irForOfUnhoist "$2") || return 1
  forOfTrials "${o}" "${t}" "$3"
}

# forOfTrials <oracle> <tree> <kind> -- explainIrLag's trial set over an already rewritten pair.
forOfTrials() {
  local h n r c trials tr name
  trials="0:0:0:0 1:0:0:0 1:1:0:0 0:0:1:0 1:1:1:0"
  [ "$3" = iropt ] && trials="${trials} 0:0:0:1 1:1:0:1 1:1:1:1"
  for tr in ${trials}; do
    IFS=: read -r h n r c <<<"${tr}"
    # A pair that also needs a packing, the rune call or the forwarded loads keeps that signature's
    # name, as explainIrLag names a file that needs two of them, so none of those starves into
    # RETIRED while its files move to this one.
    name=forof
    [ "${h}" = 1 ] && name=half
    [ "${n}" = 1 ] && name=narrow
    [ "${c}" = 1 ] && name=cse
    [ "${r}" = 1 ] && name=rune
    irTrial "$1" "$2" "${h}" "${n}" "${r}" "${name}" "${c}" && return 0
  done
  return 1
}

# explainIrLagPinForOf <oracle_text> <bit2_text> -- a pinned file (irLagPins) that also has a #7737 loop:
# the pin's own comparison, run over the same rewritten pair explainForOfLen compares. Prints the pin's
# signature name, as explainIrLagPin does.
explainIrLagPinForOf() {
  local o t u
  o=$(irDropDeadLoads "$(irParamDedup "$1")")
  u=$(irForOfUnhoist "$2") || u=$2
  t=$(irDropDeadLoads "$(irParamDedup "${u}")")
  [ "${t}" = "$2" ] && return 1
  explainIrLagPin "${o}" "${t}"
}
