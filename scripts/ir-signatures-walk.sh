#!/usr/bin/env bash
# Sourced-only (by scripts/selfhost-ir-signatures.sh, #7074): the two walking
# signatures declared against the 0.36.0 oracle, split out so that file stays
# under the 800-line ceiling. Defines IR_WALK_AWK, a block of awk functions
# explainMismatch concatenates in front of its own program (it calls
# `same`, `reset`, `isBox`, `idOf`, `lastTok`, `linesA`/`linesB`, `M`/`R`
# from there, and nilWalk/rangeWalk from its END block), and
# explainSwitchPostOpt/switchPostOptOk for the post-opt row. The identities
# and the files they explain are documented in selfhost-ir-signatures.sh under
# "Declared signatures"; both retire at the first repin after 0.36.0.
#
# Both walk the oracle dump and the tree dump in lockstep under ONE oracle-to-
# tree %id bijection per function (`same`, the #6730 walker's machinery), so a
# wrong operand, opcode or type on any unchanged line fails, and a hunk may
# only be exactly the shape its signature names.
IR_WALK_AWK='
# ptrsLit -- `ptrs=[%N, ..]` lists the byte offsets of a box pointer
# fields, not values of the function: the numbers are never renumbered with the
# ids, so the bijection must see them as text. Turns each `%` inside the
# brackets into `#` on every line of both dumps.
function ptrsLit(    k) {
  for (k = 1; k <= nA; k++) { linesA[k] = ptrsText(linesA[k]) }
  for (k = 1; k <= nB; k++) { linesB[k] = ptrsText(linesB[k]) }
}
function ptrsText(s,    a, t, b, inner) {
  a = index(s, "ptrs=[")
  if (a == 0) { return s }
  t = substr(s, a + 6); b = index(t, "]"); inner = substr(t, 1, b - 1)
  gsub(/%/, "#", inner)
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
'

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
