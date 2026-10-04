#!/usr/bin/env bash
# Sourced-only (by scripts/selfhost-ir-signatures.sh, #7074): the two walking
# signatures declared against the 0.36.0 oracle, split out so that file stays
# under the 800-line ceiling. irWalkAwk sets IR_WALK_AWK (a function so the file
# has no top-level statement and test-shebang-mode accepts mode 100644; the
# sourcer calls it once), a block of awk functions
# explainMismatch concatenates in front of its own program (it calls
# `same`, `reset`, `isBox`, `idOf`, `lastTok`, `linesA`/`linesB`, `M`/`R`
# from there, and nilWalk/rangeWalk from its END block), and
# explainSwitchPostOpt/switchPostOptOk for the post-opt row. The identities
# and the files they explain are documented in selfhost-ir-signatures.sh under
# "Declared signatures"; both retire at the first repin after 0.36.0. Also here,
# for the same ceiling: byteRange (#6558, an oracle-side rewrite, not a walk),
# explainTableSynthTypes (#6988, the `types` row) and licmWalk (#5786, the
# host-dependent `iropt` identity; licmHostNames says which hosts list it).
#
# Both walk the oracle dump and the tree dump in lockstep under ONE oracle-to-
# tree %id bijection per function (`same`, the #6730 walker's machinery), so a
# wrong operand, opcode or type on any unchanged line fails, and a hunk may
# only be exactly the shape its signature names.
licmHostNames() {
  case "$(uname -m)" in arm64|aarch64) printf '%s\n' "5786-licm-wide-const-placement" ;; esac
}

irWalkAwk() {
  IR_WALK_AWK='
# ptrsLit -- `ptrs=[%N, ..]` lists the byte offsets of a box pointer
# fields, not values of the function: the numbers are never renumbered with the
# ids, so the bijection must see them as text. ptrsLit("%", "#") turns each `%`
# inside the brackets into `#` on every line of both dumps for the walks below;
# ptrsLit("#", "%") puts them back, so the other signatures see the dumps as
# they were.
function ptrsLit(from, to,    k) {
  for (k = 1; k <= nA; k++) { linesA[k] = ptrsText(linesA[k], from, to) }
  for (k = 1; k <= nB; k++) { linesB[k] = ptrsText(linesB[k], from, to) }
}
function ptrsText(s, from, to,    a, t, b, inner) {
  a = index(s, "ptrs=[")
  if (a == 0) { return s }
  t = substr(s, a + 6); b = index(t, "]"); inner = substr(t, 1, b - 1)
  gsub(from, to, inner)
  return substr(s, 1, a + 5) inner substr(t, b)
}
# zeroAt -- oracle id v is a `const_int i64 0` defined in this function.
function zeroAt(v,    k) {
  for (k = fnStart; k <= nA && (k == fnStart || linesA[k] !~ /^func /); k++) { if (linesA[k] == "  " v " = const_int i64 0") { return 1 } }
  return 0
}
# usesOnlyInRet -- from oracle line `from` (the first line after the box that
# starts at `i`) to the end of the function, every line naming %a is `ret %a`
# straight after an `rt_call err_set(..)` (the line before the box for a `ret`
# at `from` itself), and there is at least one.
function usesOnlyInRet(a, from, i,    k, n) {
  n = 0
  for (k = from; k <= nA && linesA[k] !~ /^func /; k++) {
    if (!match(linesA[k], a "([^0-9]|$)")) { continue }
    if (linesA[k] != "  ret " a || (k == from ? linesA[i - 1] : linesA[k - 1]) !~ /^  %[0-9]+ = rt_call err_set\(%[0-9]+\) void$/) { return 0 }
    n++
  }
  return n > 0 ? 1 : 0
}
# nilHunk (#6982) -- oracle A[i] is the zero box a fallible function returns on
# its error path: `%a = gc_alloc size=16 ptrs=[..] T` (T a named type, not a
# string), up to two `const_int i64 0`, one `field_set %a[0]` and one
# `field_set %a[8]` of zero. Tree B[j] is `%b = const_nil` in its place. Every
# use of %a is `ret %a` straight after `rt_call err_set(%e)` (the box built at
# the return, or one built once at entry and returned from several error
# paths). Returns the index of the first oracle line after the box, else 0.
function nilHunk(i, j,    a, b, k, l, n0, n8, nz, zs, v) {
  a = idOf(linesA[i]); b = idOf(linesB[j])
  if (linesA[i] !~ /^  %[0-9]+ = gc_alloc size=16 ptrs=\[(#[0-9]+)?\] [A-Za-z_]/ || lastTok(linesA[i]) ~ /^(string|\()/ || b == "" || (a in M) || (b in R) || linesB[j] != "  " b " = const_nil") { return 0 }
  n0 = 0; n8 = 0; nz = 0
  for (k = i + 1; k <= nA; k++) {
    l = linesA[k]
    if (l ~ /^  %[0-9]+ = const_int i64 0$/) { zs[++nz] = idOf(l); continue }
    if (l !~ /^  field_set %[0-9]+\[(0|8)\] = %[0-9]+$/ || index(l, "  field_set " a "[") != 1) { break }
    if (index(l, "[0] = ") > 0) { n0++ } else { n8++ }
  }
  if (k > nA || n0 != 1 || n8 != 1 || nz > 2 || !usesOnlyInRet(a, k, i)) { return 0 }
  for (v = i + 1; v < k; v++) {
    l = linesA[v]
    if (l ~ /^  field_set / && !zeroAt(lastTok(l))) { return 0 }
  }
  M[a] = b; R[b] = a
  for (v = 1; v <= nz; v++) { M[zs[v]] = "<gone>" }
  return k
}
# nilWalk -- the whole dump differs from the oracle only by nilHunks, and by a
# `const_int i64 0` the tree no longer holds (post-opt: the zero the removed
# boxes stored, shared with them, is dead; any other use of it then fails).
function nilWalk(    i, j, n, e) {
  i = 1; j = 1; n = 0; fnStart = 0; reset()
  while (i <= nA || j <= nB) {
    if (i <= nA && i != fnStart && linesA[i] ~ /^func /) { reset(); fnStart = i }
    if (i <= nA && j <= nB && same(linesA[i], linesB[j])) { i++; j++; continue }
    if (i <= nA && j <= nB && (e = nilHunk(i, j)) > 0) { i = e; j++; n++; continue }
    if (i <= nA && linesA[i] ~ /^  %[0-9]+ = const_int i64 0$/ && !(idOf(linesA[i]) in M)) { M[idOf(linesA[i])] = "<gone>"; i++; continue }
    return 0
  }
  return n > 0 ? 1 : 0
}
# constOf -- the id `  %N = const_int T V` defines, "" otherwise; sets cT, cV.
function constOf(s,    p) {
  if (s !~ /^  %[0-9]+ = const_int [A-Za-z_][A-Za-z0-9_$]* -?[0-9]+$/) { return "" }
  split(s, p, " "); cT = p[4]; cV = p[5]
  return p[1]
}
# defOf -- index of the oracle line defining id x in this function before `upto`.
function defOf(x, upto,    k) {
  for (k = upto - 1; k >= fnStart; k--) { if (index(linesA[k], "  " x " = ") == 1) { return k } }
  return 0
}
# runVals -- vals[1..n] (decimal strings, possibly beyond 2^53) are the
# integers [lo, hi] exactly: sets rLoS (the lowest, as printed) and rW (hi - lo).
# Each value is held as signed high and low parts around 10^9 so the offsets
# from vals[1] are exact whenever they are small, and a run wider than 10^6 is
# refused.
function runVals(vals, n,    k, m, t, off, bh, bl, mn, mx, kmin) {
  for (k = 1; k <= n; k++) {
    t = vals[k]; neg = (substr(t, 1, 1) == "-"); if (neg) { t = substr(t, 2) }
    bl[k] = substr(t, length(t) > 9 ? length(t) - 8 : 1) + 0; bh[k] = length(t) > 9 ? substr(t, 1, length(t) - 9) + 0 : 0
    if (neg) { bl[k] = -bl[k]; bh[k] = -bh[k] }
    off[k] = (bh[k] - bh[1]) * 1000000000 + (bl[k] - bl[1])
    if (off[k] > 1000000 || off[k] < -1000000) { return 0 }
  }
  mn = 0; mx = 0; kmin = 1
  for (k = 2; k <= n; k++) { if (off[k] < mn) { mn = off[k]; kmin = k } if (off[k] > mx) { mx = off[k] } }
  for (k = 1; k <= n; k++) {
    if (off[k] == mx) { continue }
    for (m = 1; m <= n && off[m] != off[k] + 1; m++) { }
    if (m > n) { return 0 }
  }
  rLoS = vals[kmin]; rW = mx - mn
  return 1
}
# swChain (#7058) -- the oracle chain whose first compare is A[i]: `%e1 =
# icmp_eq bool %S, %l1`, then per further label its lowering (a `const_int T v`,
# or that and a `neg T` of it) followed by `icmp_eq bool %S, %l` and a `bor` of
# the running result, then `br` of the last `bor`. All labels are of one type
# T. Fills sS, swTy, swN, plain (every label a bare const), gs[k] (index of
# the first line of label k, k >= 2), gl[k] (its line count), vals[], eids[],
# oids[], and returns the index of the `br`, else 0.
function swChain(i,    q, d, p, n, c, e, o, l, t, v) {
  if (linesA[i] !~ /^  %[0-9]+ = icmp_eq bool %[0-9]+, %[0-9]+$/) { return 0 }
  split(substr(linesA[i], index(linesA[i], "icmp_eq bool ") + 13), q, ", ")
  sS = q[1]; l = q[2]; d = defOf(l, i); plain = 1
  if (d == 0) { return 0 }
  if (linesA[d] ~ /^  %[0-9]+ = neg [A-Za-z0-9_$]+ %[0-9]+$/) {
    plain = 0; split(linesA[d], t, " "); l = t[5]; d = defOf(l, d); if (d == 0) { return 0 }
  }
  if (constOf(linesA[d]) != l) { return 0 }
  swTy = cT; n = 1; vals[1] = cV; eids[1] = idOf(linesA[i]); oids[1] = eids[1]; p = i + 1
  while (p + 2 <= nA) {
    c = constOf(linesA[p]); if (c == "" || cT != swTy) { break }
    gs[n + 1] = p; gl[n + 1] = 1; l = c; v = cV
    if (linesA[p + 1] == "  " idOf(linesA[p + 1]) " = neg " swTy " " c) { l = idOf(linesA[p + 1]); gl[n + 1] = 2; plain = 0 }
    p += gl[n + 1]
    e = idOf(linesA[p]); if (linesA[p] != "  " e " = icmp_eq bool " sS ", " l) { break }
    o = idOf(linesA[p + 1]); if (linesA[p + 1] != "  " o " = bor bool " oids[n] ", " e) { break }
    n++; vals[n] = v; eids[n] = e; oids[n] = o; p += 2
  }
  swN = n
  return (n >= 2 && index(linesA[p], "  br " oids[n] ", ") == 1) ? p : 0
}
# swHunk (#7058) -- oracle chain at A[i] against the tree at B[j]. Either the
# labels are hoisted (every label lowered first, then the same compares and
# ors in the same order) or, for a contiguous run of bare constants, they
# stand beside the unsigned range test `(S - lo) <=u width`. Returns the index
# of the oracle `br`, sets jNext.
function swHunk(i, j,    p, n, k, g, jj, bits, x, ut, lo, w, m, a1, a2, a3, r) {
  p = swChain(i); if (p == 0) { return 0 }
  n = swN; jj = j
  for (k = 2; k <= n; k++) {
    for (g = 0; g < gl[k]; g++) { if (!same(linesA[gs[k] + g], linesB[jj])) { return 0 } jj++ }
  }
  if (linesB[jj] ~ /icmp_eq bool/) {
    if (!same(linesA[i], linesB[jj])) { return 0 }
    jj++
    for (k = 2; k <= n; k++) {
      if (!same(linesA[gs[k] + gl[k]], linesB[jj]) || !same(linesA[gs[k] + gl[k] + 1], linesB[jj + 1])) { return 0 }
      jj += 2
    }
    jNext = jj
    return p
  }
  if (!plain || !(sS in M) || !runVals(vals, n)) { return 0 }
  bits = (swTy ~ /^[iu](8|16|32|64)$/) ? substr(swTy, 2) + 0 : 64
  ut = "u" bits; lo = rLoS; w = rW
  if (lo ~ /^-/) { if (bits == 64) { return 0 } m = 1; for (x = 0; x < bits; x++) { m *= 2 } lo = (lo + 0) + m }
  a1 = idOf(linesB[jj]); a2 = idOf(linesB[jj + 1]); a3 = idOf(linesB[jj + 2]); r = idOf(linesB[jj + 3])
  if (a1 == "" || a2 == "" || a3 == "" || r == "" || (a1 in R) || (a2 in R) || (a3 in R) || (r in R)) { return 0 }
  if (linesB[jj] != "  " a1 " = const_int " ut " " lo || linesB[jj + 1] != "  " a2 " = sub " ut " " M[sS] ", " a1) { return 0 }
  if (linesB[jj + 2] != "  " a3 " = const_int " ut " " w || linesB[jj + 3] != "  " r " = icmp_ule bool " a2 ", " a3) { return 0 }
  for (k = 1; k <= n; k++) { M[eids[k]] = "<gone>"; M[oids[k]] = "<gone>" }
  M[oids[n]] = r; R[r] = oids[n]; R[a1] = "<new>"; R[a2] = "<new>"; R[a3] = "<new>"
  jNext = jj + 4
  return p
}
# rangeWalk -- the whole dump differs from the oracle only by swHunks.
function rangeWalk(    i, j, n, e) {
  i = 1; j = 1; n = 0; fnStart = 0; reset()
  while (i <= nA || j <= nB) {
    if (i <= nA && i != fnStart && linesA[i] ~ /^func /) { reset(); fnStart = i }
    if (i <= nA && j <= nB && same(linesA[i], linesB[j])) { i++; j++; continue }
    if (i <= nA && j <= nB && (e = swHunk(i, j)) > 0) { i = e; j = jNext; n++; continue }
    return 0
  }
  return n > 0 ? 1 : 0
}
# byteRange (#6558, `ir` and `iropt`) -- the 6558-string-from-byte-range
# identity, declared in selfhost-ir-signatures.sh. #6558 lowers `string(b[lo:hi])`
# to ONE `%t = rt_call string_from_byte_range(%b, %lo, %hi) string`; the 0.36.0
# oracle emits `%s = rt_call slice_slice(%b, %lo, %hi) []u8`, then `%t =
# rt_call string_from_bytes(%s) string` on the next line. byteRange rewrites the
# ORACLE dump so each such adjacent pair, and only such a pair (%s named by no
# other line of its function, %t = %s + 1), becomes the one call, and renumbers
# every later %id of that function down by one (%t becomes %s), as the tree
# numbers them. It
# touches no other line and never the tree dump, so whatever remains must still
# agree with the tree under every other check. Returns the number of pairs.
# idUses -- the lines of oracle function [s, e] naming id x.
function idUses(x, s, e,    k, n) {
  n = 0
  for (k = s; k <= e; k++) { if (match(linesA[k], x "([^0-9]|$)")) { n++ } }
  return n
}
# shiftIds -- every %N of s with N > d printed as %(N - 1).
function shiftIds(s, d,    out, t) {
  out = ""
  while (match(s, /%[0-9]+/)) {
    t = substr(s, RSTART + 1, RLENGTH - 1) + 0
    out = out substr(s, 1, RSTART - 1) "%" (t > d ? t - 1 : t)
    s = substr(s, RSTART + RLENGTH)
  }
  return out s
}
# shiftLine -- shiftIds of a line; a line holding a string literal keeps its
# text and only the id its `const_string` defines moves.
function shiftLine(s, d,    n) {
  if (index(s, "\"") == 0) { return shiftIds(s, d) }
  if (!match(s, /^  %[0-9]+ = const_string "/)) { return s }
  n = index(s, " = ")
  return shiftIds(substr(s, 1, n - 1), d) substr(s, n)
}
# byteRangeAt -- collapse the pair at A[i], A[i + 1] when it is the shape above.
function byteRangeAt(i,    a, t, args, s, e, k) {
  if (linesA[i] !~ /^  %[0-9]+ = rt_call slice_slice\(%[0-9]+, %[0-9]+, %[0-9]+\) \[\]u8$/) { return 0 }
  a = idOf(linesA[i]); t = idOf(linesA[i + 1])
  if (t != "%" (substr(a, 2) + 1) || linesA[i + 1] != "  " t " = rt_call string_from_bytes(" a ") string") { return 0 }
  for (s = i; s > 1 && linesA[s] !~ /^func /; s--) { }
  for (e = i; e < nA && linesA[e + 1] !~ /^func /; e++) { }
  if (idUses(a, s, e) != 2) { return 0 }
  args = substr(linesA[i], index(linesA[i], "slice_slice(") + 12)
  linesA[i] = "  " a " = rt_call string_from_byte_range(" substr(args, 1, index(args, ")") - 1) ") string"
  for (k = i + 1; k < nA; k++) { linesA[k] = linesA[k + 1] }
  delete linesA[nA]; nA--; e--
  for (k = s; k <= e; k++) { linesA[k] = shiftLine(linesA[k], substr(a, 2) + 0) }
  return 1
}
function byteRange(    i, n) {
  n = 0
  for (i = 1; i < nA; i++) { n += byteRangeAt(i) }
  return n
}
# 5786-licm-wide-const-placement (#5786, `iropt`, arm64 hosts only). #5786 gives
# the LICM constant hoist the target: on arm64 a wide `const_int` (more than one
# instruction by movImm64, compiler/arm64.bit) is hoisted out of the body of an
# outer loop (the 0.36.0 oracle refuses any loop that holds a loop), a divisor
# stays in its body (the oracle hoists it), and an op over a hoisted constant
# hoists with it. `--dump-ir` lowers for the host, so the dumps differ only
# where the host is arm64 and licmHostNames lists the name there only. The
# pre-opt dumps agree. Files: _tests_/cases/decimal_collections,
# decimal_compound_assign, decimal_corpus, decimal_to_int_roundtrip,
# run_decimal_words, run_map_swar_scan, run_strings_builder_bulk_write,
# stdlib/crypto/asn1, stdlib/crypto/bigint and stdlib/decimal/decimal.bit.
# The identity (licmWalk): licmNorm reads each function of both dumps with its
# wide `const_int` lines, its add/sub/mul/band/bor/bxor/shl/lshr/ashr lines
# that have such a constant among their operands (transitively), and every
# block parameter that all its edges hand one such value (an optimistic
# fixpoint; the entry block is refuted) removed, along with the arguments that
# fed them, and each use printed as the literal `@K(T:V)` or `@E(op T x, y)`
# (an operand that is a parameter copying one value is read as that value).
# The two reads must then agree line for line under ONE %id bijection per
# function while the raw dumps differ. A different constant, operand, opcode
# or type, a narrow constant moved, and any hoist of an op that reads no wide
# constant (a header word, a plain add) leaves a line one side has alone, and
# fails. Retires at the first repin after 0.36.0.
#
# decDec/divMod/wideVal decide wideness on the decimal text, so a 64-bit value
# loses nothing to awk doubles.
function decDec(s,    i, d, tail) {
  tail = ""
  for (i = length(s); i > 0; i--) {
    d = substr(s, i, 1)
    if (d != "0") { s = substr(s, 1, i - 1) (d - 1) tail; sub(/^0+/, "", s); return s == "" ? "0" : s }
    tail = tail "9"
  }
  return "0"
}
# divMod -- the decimal string s modulo 65536; its quotient is left in dq.
function divMod(s,    i, r, q, d) {
  q = ""; r = 0
  for (i = 1; i <= length(s); i++) { d = r * 10 + substr(s, i, 1); q = q int(d / 65536); r = d % 65536 }
  sub(/^0+/, "", q); dq = (q == "" ? "0" : q)
  return r
}
# wideVal -- 1 when movImm64 spends more than one instruction on the decimal
# value v: 4 halfwords, the fewer of the zero ones and the all-ones ones are
# free, and 0 and -1 take one. A value that does not fit 64 bits is 0.
function wideVal(v,    neg, k, r, z, o) {
  neg = (substr(v, 1, 1) == "-"); if (neg) { v = substr(v, 2) }
  sub(/^0+/, "", v)
  if (v == "" || (neg && v == "1")) { return 0 }
  if (neg) { v = decDec(v) }
  z = 0; o = 0
  for (k = 0; k < 4; k++) { r = divMod(v); v = dq; if (neg) { r = 65535 - r } if (r == 0) { z++ } if (r == 65535) { o++ } }
  if (v != "0") { return 0 }
  return ((o > z ? 4 - o : 4 - z) > 1) ? 1 : 0
}
function licmClear() {
  split("", lkCK); split("", lkNP); split("", lkPT); split("", lkPK); split("", lkPB); split("", lkPI); split("", lkBN)
  split("", lkET); split("", lkEN); split("", lkEA); split("", lkInN); split("", lkIn)
  split("", lkOPN); split("", lkOPA); split("", lkOPB); split("", lkMemo)
  lkE = 0; lkNB = 0
}
# licmParams -- the parameter texts `%N: T` of a block header line into prm[1..n]
# (a type may hold ", ", so the split is on `, %`).
function licmParams(l, prm,    inner, n, i) {
  inner = substr(l, index(l, "(") + 1); sub(/\):$/, "", inner)
  if (inner == "") { return 0 }
  n = split(inner, prm, ", %")
  for (i = 2; i <= n; i++) { prm[i] = "%" prm[i] }
  return n
}
function licmHeaderAt(l,    prm, b, n, i, id) {
  b = substr(l, 1, index(l, "(") - 1); n = licmParams(l, prm)
  lkBN[++lkNB] = b; lkNP[b] = n
  for (i = 1; i <= n; i++) {
    id = substr(prm[i], 1, index(prm[i], ":") - 1)
    lkPT[b, i] = substr(prm[i], index(prm[i], ": ") + 2); lkPB[id] = b; lkPI[id] = i; lkPK[b, i] = "TOP"
  }
}
function licmEdgesAt(l,    t, nm, inner, n, a, i, e) {
  while (match(l, /bb[0-9]+\([^)]*\)/)) {
    t = substr(l, RSTART, RLENGTH); l = substr(l, RSTART + RLENGTH)
    nm = substr(t, 1, index(t, "(") - 1); inner = substr(t, index(t, "(") + 1); sub(/\)$/, "", inner)
    n = (inner == "") ? 0 : split(inner, a, ", ")
    e = ++lkE; lkET[e] = nm; lkEN[e] = n
    for (i = 1; i <= n; i++) { lkEA[e, i] = a[i] }
    lkIn[nm, ++lkInN[nm]] = e
  }
}
# licmOpAt -- records `%d = OP T %a, %b` for the integer ops a loop hoist moves
# (add, sub, mul and the bitwise and shift family); none of them can trap.
function licmOpAt(l,    p) {
  if (l !~ /^  %[0-9]+ = (add|sub|mul|band|bor|bxor|shl|lshr|ashr) [A-Za-z0-9_]+ %[0-9]+, %[0-9]+$/) { return }
  split(l, p, " "); sub(/,$/, "", p[5])
  lkOPN[p[1]] = p[3] " " p[4]; lkOPA[p[1]] = p[5]; lkOPB[p[1]] = p[6]
}
# licmCollect -- the wide constants, ops, block headers and edges of lines s..e
# of L. 0 when a line names a block target outside a `jump` or `br`.
function licmCollect(L, s, e,    k, l) {
  for (k = s; k <= e; k++) {
    l = L[k]
    if (index(l, "\"") > 0) { continue }
    if (l ~ /^bb[0-9]+\(.*\):$/) { licmHeaderAt(l); continue }
    if (l ~ /^  (jump bb|br %)/) { licmEdgesAt(l); continue }
    if (l ~ /bb[0-9]+\(/) { return 0 }
    if (constOf(l) != "" && wideVal(cV)) { lkCK[idOf(l)] = cT ":" cV; continue }
    licmOpAt(l)
  }
  return 1
}
# licmVal -- what operand a stands for: `@K(T:V)` for a wide constant, `@E(op T
# x, y)` for an op with such a value among its operands (the constants and the
# values they were combined with are all there is to it), the value of a
# parameter every edge hands one value (a constant, or the one value it
# copies), "TOP" while that is undecided, and the id itself otherwise.
function licmVal(a,    v, x, y) {
  if (a in lkCK) { return "@K(" lkCK[a] ")" }
  if (a in lkPB) { v = lkPK[lkPB[a], lkPI[a]]; return v == "NONE" ? a : v }
  if (!(a in lkOPN)) { return a }
  if (a in lkMemo) { return lkMemo[a] }
  x = licmVal(lkOPA[a]); y = licmVal(lkOPB[a])
  if (x == "TOP" || y == "TOP") { return "TOP" }
  v = (x ~ /^@/ || y ~ /^@/) ? "@E(" lkOPN[a] " " x ", " y ")" : a
  lkMemo[a] = v
  return v
}
# licmMeet -- the value parameter k of block b holds on every edge into it:
# a licmVal text, "TOP" (no edge decided yet) or "NONE".
function licmMeet(b, k,    v, i, e, ak, t) {
  v = "TOP"
  for (i = 1; i <= lkInN[b]; i++) {
    e = lkIn[b, i]
    if (k > lkEN[e]) { return "NONE" }
    ak = licmVal(lkEA[e, k])
    if (ak == "TOP") { continue }
    if (v != "TOP" && v != ak) { return "NONE" }
    v = ak
  }
  if (v ~ /^@K[(]/) {
    t = substr(v, 4, index(v, ":") - 4)
    if (t != lkPT[b, k]) { return "NONE" }
  }
  return v
}
# licmSolve -- the optimistic fixpoint over every parameter (those of a block
# no edge reaches, the entry block, are NONE from the start), then once more
# with the parameters nothing decided (a cycle that only feeds itself) NONE.
function licmSolve(    round, ch, guard, i, b, k, v, tot) {
  for (i = 1; i <= lkNB; i++) {
    b = lkBN[i]; tot += lkNP[b]
    for (k = 1; k <= lkNP[b] && lkInN[b] == 0; k++) { lkPK[b, k] = "NONE" }
  }
  for (round = 1; round <= 2; round++) {
    ch = 1; guard = 0
    while (ch && guard++ <= 3 * tot + 3) {
      ch = 0; split("", lkMemo)
      for (i = 1; i <= lkNB; i++) {
        b = lkBN[i]
        for (k = 1; k <= lkNP[b]; k++) {
          v = licmMeet(b, k)
          if (v == lkPK[b, k]) { continue }
          if (lkPK[b, k] != "TOP") { v = "NONE" }
          if (v != lkPK[b, k]) { lkPK[b, k] = v; ch = 1 }
        }
      }
    }
    for (i = 1; i <= lkNB; i++) {
      b = lkBN[i]
      for (k = 1; k <= lkNP[b]; k++) { if (lkPK[b, k] == "TOP") { lkPK[b, k] = "NONE" } }
    }
  }
  split("", lkMemo)
}
function licmIsK(b, k) { return ((b, k) in lkPK) && lkPK[b, k] ~ /^@/ }
function licmHeader(l,    prm, n, i, out, b) {
  n = licmParams(l, prm); out = ""; b = substr(l, 1, index(l, "(") - 1)
  for (i = 1; i <= n; i++) { if (!licmIsK(b, i)) { out = out (out == "" ? "" : ", ") prm[i] } }
  return b "(" out "):"
}
function licmEdges(l,    out, t, nm, inner, n, a, i, keep) {
  out = ""
  while (match(l, /bb[0-9]+\([^)]*\)/)) {
    t = substr(l, RSTART, RLENGTH); out = out substr(l, 1, RSTART - 1); l = substr(l, RSTART + RLENGTH)
    nm = substr(t, 1, index(t, "(") - 1); inner = substr(t, index(t, "(") + 1); sub(/\)$/, "", inner)
    n = (inner == "") ? 0 : split(inner, a, ", "); keep = ""
    for (i = 1; i <= n; i++) { if (!licmIsK(nm, i)) { keep = keep (keep == "" ? "" : ", ") a[i] } }
    out = out nm "(" keep ")"
  }
  return out l
}
# licmSubst -- every operand that is a wide constant, an op over one, or a
# parameter that only ever holds one printed as its licmVal text.
function licmSubst(s,    out, t, r) {
  out = ""
  while (match(s, /%[0-9]+/)) {
    t = substr(s, RSTART, RLENGTH); r = (t in lkPB) ? (licmIsK(lkPB[t], lkPI[t]) ? lkPK[lkPB[t], lkPI[t]] : t) : licmVal(t)
    out = out substr(s, 1, RSTART - 1) (r ~ /^@/ ? r : t)
    s = substr(s, RSTART + RLENGTH)
  }
  return out s
}
# licmNorm -- L[1..n] with, per function, the wide `const_int` lines, the ops
# over them and the block parameters (and the jump/br arguments feeding them)
# that only ever hold one of those removed, every use read as its licmVal
# text. The new line count, or -1 when a function is not in the shape
# licmCollect reads.
function licmNorm(L, n,    s, e, k, l, d) {
  lkN = 0; split("", lkOut); s = 1
  while (s <= n) {
    e = s
    while (e < n && L[e + 1] !~ /^func /) { e++ }
    licmClear()
    if (!licmCollect(L, s, e)) { return -1 }
    licmSolve()
    for (k = s; k <= e; k++) {
      l = L[k]
      if (index(l, "\"") == 0) {
        d = idOf(l)
        if (d != "" && ((d in lkCK) || ((d in lkOPN) && licmVal(d) ~ /^@/))) { continue }
        if (l ~ /^bb[0-9]+\(.*\):$/) { l = licmHeader(l) } else if (l ~ /^  (jump bb|br %)/) { l = licmEdges(l) }
        l = licmSubst(l)
      }
      lkOut[++lkN] = l
    }
    s = e + 1
  }
  split("", L)
  for (k = 1; k <= lkN; k++) { L[k] = lkOut[k] }
  return lkN
}
# licmWalk -- the dumps differ, and agree under one %id bijection per function
# once licmNorm has read both. Leaves linesA/linesB as it found them.
function licmWalk(    k, sA, sB, na, nb, ok, i, differ) {
  split("", svA); split("", svB); sA = nA; sB = nB; differ = (nA != nB)
  for (k = 1; k <= nA; k++) { svA[k] = linesA[k] }
  for (k = 1; k <= nB; k++) { svB[k] = linesB[k]; if (k <= nA && svB[k] != svA[k]) { differ = 1 } }
  na = licmNorm(linesA, nA); nb = (na < 0) ? -1 : licmNorm(linesB, nB)
  ok = (na >= 0 && na == nb && differ)
  nA = na; nB = nb; fnStart = 0; reset()
  for (i = 1; ok && i <= na; i++) {
    if (linesA[i] ~ /^func / && i != fnStart) { reset(); fnStart = i }
    ok = same(linesA[i], linesB[i])
  }
  split("", linesA); split("", linesB); nA = sA; nB = sB
  for (k = 1; k <= nA; k++) { linesA[k] = svA[k] }
  for (k = 1; k <= nB; k++) { linesB[k] = svB[k] }
  return ok
}
'
}

# switchPostOptOk <pre_oracle> <pre_tree> <post_oracle> <post_tree> -- returns
# 0 when every function whose post-opt text differs is a function whose
# pre-opt text differs, or one that (transitively) calls such a function: the
# optimizer only reaches what the lowering changed or what inlined it. The
# pre-opt dumps must be explained by the 7058 identity (checked by the
# caller). Post-opt text inside those functions is NOT independently verified:
# constant-folding the range test of a constant subject (every switch in main
# of run_switch.bit) cascades through the CFG, so no text identity holds there.
# `$t<id>` suffixes are erased before comparing.
switchPostOptOk() {
  awk '
    function strip(s) { gsub(/[$]t[0-9]+/, "$t", s); return s }
    FNR == 1 { fi++; cur = "" }
    {
      line = strip($0)
      if (line ~ /^func /) { cur = line; sub(/[(].*$/, "", cur); sub(/^func /, "", cur) }
      nm[cur] = 1; has[fi, cur] = 1; txt[fi, cur] = txt[fi, cur] line "\n"
      s = line
      while (fi <= 2 && match(s, /call @[^(]+[(]/)) {
        calls[fi, cur] = calls[fi, cur] " " substr(s, RSTART + 6, RLENGTH - 7) " "
        s = substr(s, RSTART + RLENGTH)
      }
    }
    END {
      split("", hit)
      for (n in nm) { if (!has[1, n] || !has[2, n] || !has[3, n] || !has[4, n]) { exit 1 } }
      for (n in nm) { if (txt[1, n] != txt[2, n]) { hit[n] = 1 } }
      do {
        grew = 0
        for (n in nm) {
          if (n in hit) { continue }
          for (c in hit) { if (index(calls[1, n] calls[2, n], " " c " ") > 0) { hit[n] = 1; grew = 1; break } }
        }
      } while (grew)
      for (n in nm) { if (txt[3, n] != txt[4, n]) { diffs++; if (!(n in hit)) { exit 1 } } }
      exit (diffs > 0 ? 0 : 1)
    }
  ' <(printf '%s\n' "$1") <(printf '%s\n' "$2") <(printf '%s\n' "$3") <(printf '%s\n' "$4")
}

# explainSwitchPostOpt <file> <post_oracle> <post_tree> -- the post-opt arm of
# 7058-switch-case-range: prints its name and returns 0 when the file's
# pre-opt dumps (oracle and tree, both asked here) are explained by
# 7058-switch-case-range and switchPostOptOk holds. Needs ORACLE and BIT2 as
# set by selfhost-diffdump-setup.sh.
explainSwitchPostOpt() {
  local pre_o pre_b
  pre_o=$("$ORACLE" --dump-ir-pre "$1" 2>/dev/null) || return 1
  pre_b=$("$BIT2" --dump-ir-pre "$1" 2>/dev/null) || return 1
  [ "$(explainMismatch "$pre_o" "$pre_b" ir "$1")" = "7058-switch-case-range" ] || return 1
  switchPostOptOk "$pre_o" "$pre_b" "$2" "$3" || return 1
  printf '%s\n' "7058-switch-case-range-opt"
}

# explainTableSynthTypes <oracle_types> <tree_types> -- the
# 6988-table-class-name-synth-shift signature over two `--dump-types` texts.
# Prints its name and returns 0 when the dumps differ ONLY in the column of
# synthesized @table members; else prints nothing, returns 1. #6988 adds the
# word `__className` to the text the compiler synthesizes for an @table class,
# ahead of `cols` and `__row`, so each of those members moves right by the
# length of the word and its separating space (12). Identity: the dumps have
# the same number of lines, at least one line differs, and every line that
# differs is `L:C: cols: []string` or `L:C: __row: T` in the oracle and the
# same text on the same line L at column C + 12 in the tree. A different name,
# type, line or shift, or any other line that differs, fails it.
explainTableSynthTypes() {
  awk '
    FNR == 1 { fi++ }
    fi == 1 { a[++na] = $0; next }
    { b[++nb] = $0 }
    function tail(s) { sub(/^[0-9]+:[0-9]+: /, "", s); return s }
    function pos(s, p,    t) { split(s, t, ":"); return t[p] + 0 }
    END {
      if (na != nb) { exit 1 }
      for (i = 1; i <= na; i++) {
        if (a[i] == b[i]) { continue }
        if (a[i] !~ /^[0-9]+:[0-9]+: (cols: \[\]string|__row: [A-Za-z_][A-Za-z0-9_]*)$/) { exit 1 }
        if (tail(a[i]) != tail(b[i]) || pos(a[i], 1) != pos(b[i], 1) || pos(b[i], 2) - pos(a[i], 2) != length("__className") + 1) { exit 1 }
        n++
      }
      if (n == 0) { exit 1 }
      print "6988-table-class-name-synth-shift"; exit 0
    }
  ' <(printf '%s\n' "$1") <(printf '%s\n' "$2")
}
