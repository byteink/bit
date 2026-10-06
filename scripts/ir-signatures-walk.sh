#!/usr/bin/env bash
# Sourced-only (by scripts/selfhost-ir-signatures.sh): the declared signatures against the 0.39.0
# oracle that read whole dumps, split out so that file stays under the 800-line ceiling. They
# retire at the first repin after 0.39.0. irWalkAwk sets IR_WALK_AWK, the awk program behind the
# `ir` and `iropt` rows (a function so this file has no top-level statement and test-shebang-mode
# accepts mode 100644); explainLagTypes is the `types` row. The identities, the files they explain
# and the merge each one belongs to are in selfhost-ir-signatures.sh under "Declared signatures".
#
# The IR program reads the oracle dump, a line `@@@BIT2@@@`, then the tree dump. Both are split
# into functions. Every constant (`const_int`, `const_nil`) is erased and each use printed as a
# literal, so where a constant is defined never matters. The ORACLE functions then get the
# rewrites below, each one the exact shape a named change produced, and `%id` and `bbN` are
# renumbered to first-appearance order. The signature holds when every function agrees byte for
# byte afterwards and at least one named rewrite fired, so an unrelated difference anywhere in
# the file still fails. A rewrite whose shape does not match fires nothing.
irWalkAwk() {
  IR_WALK_AWK='

# canonT -- rewrite every `$t<N>` of arr[1..n] to `$c<idx>` in first-appearance order.
function canonT(arr, n,    i, line, out, tok, cnt, map) {
  cnt = 0
  for (i = 1; i <= n; i++) {
    line = arr[i]; out = ""
    while (match(line, /\$t[0-9]+/)) {
      tok = substr(line, RSTART, RLENGTH)
      if (!(tok in map)) { map[tok] = "$c" cnt++ }
      out = out substr(line, 1, RSTART - 1) map[tok]
      line = substr(line, RSTART + RLENGTH)
    }
    arr[i] = out line
  }
}
# ptrsText -- `ptrs=[%N, ..]` lists byte offsets, not values: never renumbered.
function ptrsText(s, from, to,    a, t, b, inner) {
  a = index(s, "ptrs=[")
  if (a == 0) { return s }
  t = substr(s, a + 6); b = index(t, "]"); inner = substr(t, 1, b - 1)
  gsub(from, to, inner)
  return substr(s, 1, a + 5) inner substr(t, b)
}
# mapToks -- replace every `%N` token of s found in tab by the value tab holds.
function mapToks(s, tab,    out, tok) {
  out = ""
  while (match(s, /%[0-9]+/)) {
    tok = substr(s, RSTART, RLENGTH)
    out = out substr(s, 1, RSTART - 1) ((tok in tab) ? tab[tok] : tok)
    s = substr(s, RSTART + RLENGTH)
  }
  return out s
}
function mapLine(l, tab) { return ptrsText(mapToks(ptrsText(l, "%", "#"), tab), "#", "%") }
function defId(l) { return match(l, /^  %[0-9]+ = /) ? substr(l, 3, RLENGTH - 5) : "" }
function lastTokOf(s,    n, p) { n = split(s, p, " "); return p[n] }
# typeAfterCall -- the result type printed after the closing paren of the call.
function typeAfterCall(l,    p) { p = index(l, ") "); return substr(l, p + 2) }
# eraseConsts -- every `%c = const_int T V` and `%c = const_nil` line is dropped and each use of
# %c is printed as the literal `{T:V}` / `{nil}`: where a constant is defined never matters.
function eraseConsts(a, n,    i, l, p, lit, m, out) {
  split("", lit)
  for (i = 1; i <= n; i++) {
    l = a[i]
    if (l ~ /^  %[0-9]+ = const_int [A-Za-z_][A-Za-z0-9_]* -?[0-9]+$/) { split(l, p, " "); lit[p[1]] = "{" p[4] ":" p[5] "}" }
    else if (l ~ /^  %[0-9]+ = const_nil$/) { split(l, p, " "); lit[p[1]] = "{nil}" }
  }
  m = 0
  for (i = 1; i <= n; i++) {
    l = a[i]
    if (l ~ /^  %[0-9]+ = const_(int [A-Za-z_][A-Za-z0-9_]* -?[0-9]+|nil)$/) { continue }
    out[++m] = mapLine(l, lit)
  }
  for (i = 1; i <= m; i++) { a[i] = out[i] }
  for (i = m + 1; i <= n; i++) { delete a[i] }
  return m
}
function useCount(a, n, tok,    i, c, s) {
  c = 0
  for (i = 1; i <= n; i++) {
    s = ptrsText(a[i], "%", "#")
    while (match(s, /%[0-9]+/)) {
      if (substr(s, RSTART, RLENGTH) == tok) { c++ }
      s = substr(s, RSTART + RLENGTH)
    }
  }
  return c
}
# hasParse -- `%h = rt_call iface_has(recv, {i64:N}) T`: sets gH gRecv gId gT.
function hasParse(l,    r, p) {
  if (l !~ /^  %[0-9]+ = rt_call iface_has\([^,()]+, \{i64:[0-9]+\}\) [^ ]/) { return 0 }
  gH = defId(l)
  r = substr(l, index(l, "iface_has(") + 10); p = index(r, ", {i64:")
  gRecv = substr(r, 1, p - 1)
  r = substr(r, p + 7); gId = substr(r, 1, index(r, "}") - 1)
  gT = typeAfterCall(l)
  return 1
}
# chainRewrite -- #7406: the per-method of the 0.39.0 oracle `iface_has` chain becomes the one
# `const_string "ids"` + `iface_implements(recv, ids)`. A link continues the chain only when the
# previous result has exactly that one use.
function chainRewrite(a, n,    i, k, cnt, hi, hH, hR, hId, hT, nx, isNext, ids, last, out, m, del, rep, ln, fid) {
  cnt = 0
  for (i = 1; i <= n; i++) { if (hasParse(a[i])) { hi[++cnt] = i; hH[cnt] = gH; hR[cnt] = gRecv; hId[cnt] = gId; hT[cnt] = gT } }
  if (cnt == 0) { return n }
  split("", nx); split("", isNext)
  for (i = 1; i <= cnt; i++) {
    if (useCount(a, n, hH[i]) != 2) { continue }  # the def and the one next link
    for (k = 1; k <= cnt; k++) { if (hR[k] == hH[i] && k != i) { nx[i] = k; isNext[k] = 1; break } }
  }
  split("", del); split("", rep)
  for (i = 1; i <= cnt; i++) {
    if (i in isNext) { continue }
    ids = hId[i]; last = i
    while (last in nx) { last = nx[last]; ids = ids "," hId[last]; del[hi[last]] = 1 }
    fid = "%" (9000000 + ++gFresh)
    del[hi[i]] = 1
    rep[hi[i]] = "  " fid " = const_string \"" ids "\"\n  " hH[last] " = rt_call iface_implements(" hR[i] ", " fid ") " hT[last]
    gHit["chain"] = 1
  }
  m = 0
  for (i = 1; i <= n; i++) {
    if (i in rep) { split(rep[i], ln, "\n"); out[++m] = ln[1]; out[++m] = ln[2]; continue }
    if (i in del) { continue }
    out[++m] = a[i]
  }
  for (i = 1; i <= m; i++) { a[i] = out[i] }
  for (i = m + 1; i <= n; i++) { delete a[i] }
  return m
}
# okRewrite -- #7408: the oracle reads the ok of a type assertion with `rt_call iface_as_ok()` straight
# after the assertion call; the tree compares the result of that call against nil.
function okRewrite(a, n,    i) {
  for (i = 2; i <= n; i++) {
    if (a[i] !~ /^  %[0-9]+ = rt_call iface_as_ok\(\) bool$/) { continue }
    if (a[i - 1] !~ /^  %[0-9]+ = rt_call (iface_as|iface_as_enum|iface_implements)\(/) { continue }
    a[i] = "  " defId(a[i]) " = icmp_ne bool " defId(a[i - 1]) ", {nil}"
    gHit["ok"] = 1
  }
  return n
}
function splitList(s, arr) { return s == "" ? 0 : split(s, arr, ", ") }
# paramNames -- the `%id`s of a block label or function header parameter list.
function paramNames(s, names,    inner, parts, k, n) {
  inner = substr(s, index(s, "(") + 1); inner = substr(inner, 1, length(inner) - 2)
  if (inner == "") { return 0 }
  n = split(inner, parts, ", %")
  for (k = 1; k <= n; k++) { names[k] = (k == 1 ? "" : "%") substr(parts[k], 1, index(parts[k], ":") - 1) }
  return n
}
function argsOf(l,    s) { s = substr(l, index(l, "(") + 1); return substr(s, 1, length(s) - 1) }
function resolveVal(x, P, A, np,    k) {
  if (x ~ /^\{[^\175]*\}$/) { return x }
  for (k = 1; k <= np; k++) { if (P[k] == x) { return A[k] } }
  return ""
}
# loopRewrite -- #7377: the `append(dst, ...src)` runtime loop (header, body, exit block)
# becomes the one `rt_call slice_append_slice(dst, src, is_ref, elem_size)`.
function loopRewrite(a, n,    j, tries, r) {
  for (tries = 0; tries < 64; tries++) {
    r = 0
    for (j = 1; j <= n; j++) {
      if (a[j] ~ /^  jump bb[0-9]+\(.*\)$/ && (r = loopAt(a, n, j)) > 0) { n = r; break }
      r = 0
    }
    if (r == 0) { break }
  }
  return n
}
# loopHeader -- the entry jump a[j] targets a header at a[h] whose four lines name an
# `idx < len(src)` loop; sets lpBB lpP lpNp lpA lpSrc lpIdx lpElse lpE lpNe.
function loopHeader(a, n, j, h,    bb, p0, l, then, cmpId, lenId, na) {
  bb = substr(a[j], index(a[j], "bb"), index(a[j], "(") - index(a[j], "bb"))
  if (h + 4 > n || substr(a[h], 1, index(a[h], "(") - 1) != bb) { return 0 }
  lpBB = bb
  lpNp = paramNames(substr(a[h], 1, length(a[h]) - 1), lpP)
  na = splitList(argsOf(a[j]), lpA)
  if (lpNp != na) { return 0 }
  if (a[h + 1] !~ /^  %[0-9]+ = slice_len %[0-9]+$/ || a[h + 2] !~ /^  %[0-9]+ = icmp_slt bool %[0-9]+, %[0-9]+$/ || a[h + 3] !~ /^  br %[0-9]+, bb[0-9]+\(\), bb[0-9]+\(.*\)$/) { return 0 }
  lenId = defId(a[h + 1]); lpSrc = lastTokOf(a[h + 1])
  cmpId = defId(a[h + 2]); split(a[h + 2], p0, " ")
  lpIdx = p0[5]; sub(/,$/, "", lpIdx)
  if (p0[6] != lenId || index(a[h + 3], "  br " cmpId ", ") != 1) { return 0 }
  l = a[h + 3]; sub(/^  br %[0-9]+, /, "", l)
  then = substr(l, 1, index(l, "(") - 1)
  l = substr(l, length(then) + 5)
  lpElse = substr(l, 1, index(l, "(") - 1)
  lpNe = splitList(argsOf("  x " l), lpE)
  return a[h + 4] == then "():"
}
# loopBody -- a[h+5..e-1] is the body: no control flow but the back edge a[e], exactly one
# slice_append and no other call, and the index steps by one. Sets lpApp lpAdd lpE2.
function loopBody(a, n, h,    e, i, l, apps, bad) {
  for (e = h + 5; e <= n; e++) {
    if (a[e] ~ /^(bb[0-9]+\(|  br |  ret|  unreachable)/) { return 0 }
    if (a[e] ~ /^  jump /) { break }
  }
  if (e > n || index(a[e], "  jump " lpBB "(") != 1 || a[e + 1] !~ /^bb[0-9]+\(.*\):$/ || substr(a[e + 1], 1, index(a[e + 1], "(") - 1) != lpElse) { return 0 }
  apps = 0; bad = 0; lpAdd = ""
  for (i = h + 5; i < e; i++) {
    l = a[i]
    if (l ~ / = rt_call slice_append\(/) { apps++; lpApp = i; continue }
    if (l ~ / = (rt_call|call|call_iface|call_word|spawn)/) { bad = 1 }
    if (l == "  " defId(l) " = add i64 " lpIdx ", {i64:1}") { lpAdd = defId(l) }
  }
  lpE2 = e
  return apps == 1 && !bad && lpAdd != ""
}
function labelAt(a, n, bb,    i) {
  for (i = 1; i <= n; i++) { if (index(a[i], bb "(") == 1 && a[i] ~ /\):$/) { return i } }
  return 0
}
function loopAt(a, n, j,    h, t, e, i, k, args, B2, back, acc, ref, es, src, Rid, T, accPos, idxPos, nx, XM, X, P2, np2, ii, m, out) {
  h = labelAt(a, n, substr(a[j], index(a[j], "bb"), index(a[j], "(") - index(a[j], "bb")))
  if (h <= j || !loopHeader(a, n, j, h) || !loopBody(a, n, h)) { return 0 }
  e = lpE2
  args = argsOf(a[lpApp]); sub(/\) .*$/, "", args)
  if (splitList(args, B2) != 4) { return 0 }
  acc = B2[1]; ref = B2[3]; es = B2[4]
  Rid = defId(a[lpApp]); T = typeAfterCall(a[lpApp])
  accPos = 0; idxPos = 0
  for (k = 1; k <= lpNp; k++) { if (lpP[k] == acc) { accPos = k }; if (lpP[k] == lpIdx) { idxPos = k } }
  if (!accPos || !idxPos || lpA[idxPos] != "{i64:0}" || splitList(argsOf(a[e]), back) != lpNp) { return 0 }
  # the back edge passes every header parameter through except the accumulator and the index
  for (k = 1; k <= lpNp; k++) {
    if (k == accPos) { if (back[k] != Rid) { return 0 } }
    else if (k == idxPos) { if (back[k] != lpAdd) { return 0 } }
    else if (back[k] != lpP[k]) { return 0 }
  }
  src = resolveVal(lpSrc, lpP, lpA, lpNp); ref = resolveVal(ref, lpP, lpA, lpNp); es = resolveVal(es, lpP, lpA, lpNp)
  if (src == "" || ref == "" || es == "") { return 0 }
  nx = "%" (9000000 + ++gFresh)
  X = a[e + 1]; np2 = paramNames(substr(X, 1, length(X) - 1), P2)
  if (np2 != lpNe) { return 0 }
  split("", XM)
  for (k = 1; k <= lpNe; k++) {
    if (lpE[k] ~ /^\{[^\175]*\}$/) { XM[P2[k]] = lpE[k]; continue }
    ii = 0
    for (i = 1; i <= lpNp; i++) { if (lpP[i] == lpE[k]) { ii = i } }
    if (!ii) { return 0 }
    XM[P2[k]] = (ii == idxPos) ? "{loop-index}" : (ii == accPos) ? nx : lpA[ii]
  }
  # the straight-line code of the exit block continues the entry block; what lay between the entry
  # jump and the header keeps its place after it
  for (t = e + 2; t <= n; t++) { if (a[t] ~ /^  (jump|br|ret|unreachable)/) { break } }
  if (t > n) { return 0 }
  m = 0
  for (i = 1; i < j; i++) { out[++m] = a[i] }
  out[++m] = "  " nx " = rt_call slice_append_slice(" lpA[accPos] ", " src ", " ref ", " es ") " T
  for (i = e + 2; i <= t; i++) { out[++m] = mapLine(a[i], XM) }
  for (i = j + 1; i < h; i++) { out[++m] = a[i] }
  for (i = t + 1; i <= n; i++) { out[++m] = mapLine(a[i], XM) }
  for (i = 1; i <= m; i++) { a[i] = out[i] }
  for (i = m + 1; i <= n; i++) { delete a[i] }
  gHit["loop"] = 1
  return m
}
# renumber -- `%N` and `bbN` to first-appearance order in this function. The text of a const_string is
# never touched (only its own id).
function renumber(a, n,    i, s, out, tok, pre, map, cnt, first, sym) {
  cnt = 0; split("", map)
  for (i = 1; i <= n; i++) {
    s = ptrsText(a[i], "%", "#"); out = ""
    first = (s ~ /^  %[0-9]+ = const_string "/)
    while (match(s, /(%|bb)[0-9]+/)) {
      tok = substr(s, RSTART, RLENGTH)
      pre = (RSTART > 1) ? substr(s, RSTART - 1, 1) : ""
      if ((substr(tok, 1, 1) == "b" && pre ~ /[A-Za-z0-9_$.]/) || (first && out != "")) {
        out = out substr(s, 1, RSTART + RLENGTH - 1); s = substr(s, RSTART + RLENGTH); continue
      }
      sym = substr(tok, 1, 1) == "%" ? "%n" : "bbn"
      if (!(tok in map)) { map[tok] = sym cnt++ }
      out = out substr(s, 1, RSTART - 1) map[tok]
      s = substr(s, RSTART + RLENGTH)
    }
    a[i] = ptrsText(out s, "#", "%")
  }
}
function joinLines(a, n,    i, t) { t = ""; for (i = 1; i <= n; i++) { t = t a[i] "\n" } return t }
# parseRaw -- L[1..n] into functions as the compiler printed them: rcnt[s], rkey[s,k] (the name
# without its `$t<id>` interning numbers), rhead[s,k], rtxt[s,k] (every line, `\n` terminated).
# Text outside a function must be blank, else the dump has a shape this file does not read.
function parseRaw(s, L, n,    i, k, nm) {
  k = 0
  for (i = 1; i <= n; i++) {
    if (L[i] ~ /^func /) {
      k++; nm = substr(L[i], 6); nm = substr(nm, 1, index(nm, "(") - 1); gsub(/\$t[0-9]+/, "$t", nm)
      rkey[s, k] = nm; rhead[s, k] = L[i]; rtxt[s, k] = L[i] "\n"; continue
    }
    if (k == 0) { if (L[i] != "") { return 0 } continue }
    rtxt[s, k] = rtxt[s, k] L[i] "\n"
  }
  rcnt[s] = k
  return 1
}
# compile -- the functions of side s not in rdrop, `$t` ids canonical over exactly those, each one
# normalized: constants erased, the oracle hunks rewritten, ids renumbered.
function compile(s,    k, n, L, t, parts, np, j, a, m) {
  n = 0
  for (k = 1; k <= rcnt[s]; k++) {
    if ((s SUBSEP k) in rdrop) { continue }
    t = rtxt[s, k]; sub(/\n$/, "", t); np = split(t, parts, "\n")
    for (j = 1; j <= np; j++) { if (parts[j] != "") { L[++n] = parts[j] } }
  }
  canonT(L, n)
  for (k = 1; k <= fcnt[s]; k++) { delete fname[s, k]; delete fhead[s, k]; delete fraw[s, k]; delete fnorm[s, k]; delete fhit[s, k, "chain"]; delete fhit[s, k, "ok"]; delete fhit[s, k, "loop"] }
  fcnt[s] = 0; m = 0
  for (j = 1; j <= n; j++) {
    if (L[j] ~ /^func /) {
      m++; t = substr(L[j], 6); fname[s, m] = substr(t, 1, index(t, "(") - 1); fhead[s, m] = L[j]; fraw[s, m] = L[j] "\n"; continue
    }
    fraw[s, m] = fraw[s, m] L[j] "\n"
  }
  fcnt[s] = m
  for (k = 1; k <= m; k++) { procFn(s, k) }
}
function procFn(s, k,    a, n, t, i) {
  t = fraw[s, k]; sub(/\n$/, "", t); n = split(t, a, "\n")
  n = eraseConsts(a, n)
  split("", gHit)
  if (s == "A") { n = chainRewrite(a, n); n = okRewrite(a, n); n = loopRewrite(a, n) }
  for (i in gHit) { fhit[s, k, i] = 1 }
  renumber(a, n)
  fnorm[s, k] = joinLines(a, n)
}
function hdrParams(hd,    i, d, c, st) {
  st = index(hd, "("); d = 0
  for (i = st; i <= length(hd); i++) {
    c = substr(hd, i, 1)
    if (c == "(") { d++ } else if (c == ")") { d--; if (d == 0) { return substr(hd, st + 1, i - st - 1) } }
  }
  return ""
}
# selfResult -- a function holding `%x = call_iface %r.K() I` where %r is itself of type I (a
# parameter or an earlier call_iface result): an interface method whose result is `Self`.
function selfResult(s, k,    a, n, i, l, ty, p, r, T, tp) {
  n = split(rtxt[s, k], a, "\n")
  split("", ty)
  tp = split(hdrParams(rhead[s, k]), p, ", %")
  for (i = 1; i <= tp; i++) { ty[(i == 1 ? "" : "%") substr(p[i], 1, index(p[i], ":") - 1)] = substr(p[i], index(p[i], ": ") + 2) }
  for (i = 1; i <= n; i++) {
    l = a[i]
    if (l !~ /^  %[0-9]+ = call_iface %[0-9]+\.[0-9]+\(\) [^ ]+$/) { continue }
    r = substr(l, index(l, "call_iface ") + 11); r = substr(r, 1, index(r, ".") - 1)
    T = lastTokOf(l)
    if ((r in ty) && ty[r] == T) { return 1 }
    ty[defId(l)] = T
  }
  return 0
}
function sameLists(headersOnly,    i, a, b) {
  if (fcnt["A"] != fcnt["B"]) { return 0 }
  for (i = 1; i <= fcnt["A"]; i++) {
    if (fname["A", i] != fname["B", i]) { return 0 }
    if (headersOnly ? fhead["A", i] != fhead["B", i] : fnorm["A", i] != fnorm["B", i]) { return 0 }
  }
  return 1
}
# hitName -- the signature whose hunk rewrote a surviving oracle function.
function hitName(    k, i, names) {
  names[1] = "chain"; names[2] = "ok"; names[3] = "loop"
  for (i = 1; i <= 3; i++) {
    for (k = 1; k <= fcnt["A"]; k++) { if ((("A" SUBSEP k SUBSEP names[i]) in fhit)) { seen[names[i]] = 1 } }
  }
  if ("chain" in seen) { return "7406-iface-implements-call" }
  if ("ok" in seen) { return "7408-assert-ok-nil-compare" }
  if ("loop" in seen) { return "7377-append-spread-bulk-move" }
  return ""
}
function inA(key,    k) { for (k = 1; k <= rcnt["A"]; k++) { if (rkey["A", k] == key) { return 1 } } return 0 }
# arrowLeak -- #7383: the closure bodies of the oracle keep an unsubstituted type (`<invalid>`) and it
# never lowered `main`; the tree lowers them. Drops the leaky oracle functions and, from the tree,
# those and every function the oracle lacks, each of which must be `main` or a closure.
function arrowLeak(    k, nm, leaky, any) {
  any = 0; split("", leaky)
  for (k = 1; k <= rcnt["A"]; k++) { if (index(rhead["A", k], "<invalid>") > 0) { leaky[rkey["A", k]] = 1; rdrop["A", k] = 1; any = 1 } }
  if (!any) { return 0 }
  for (k = 1; k <= rcnt["B"]; k++) {
    nm = rkey["B", k]
    if (!(nm in leaky) && inA(nm)) { continue }
    if (nm != "main" && nm !~ /^closure\$[0-9]+$/) { return 0 }
    rdrop["B", k] = 1
  }
  return 1
}
# selfOmit -- #7387: the oracle never lowered a function the tree lowers, every one of which calls
# an interface method whose result is `Self`.
function selfOmit(    k, any) {
  any = 0
  for (k = 1; k <= rcnt["B"]; k++) {
    if (inA(rkey["B", k])) { continue }
    if (!selfResult("B", k)) { return 0 }
    rdrop["B", k] = 1; any = 1
  }
  return any
}
function explainIr(    nm) {
  if (!parseRaw("A", LA, nA) || !parseRaw("B", LB, nB)) { return "" }
  split("", rdrop); compile("A"); compile("B")
  if (sameLists(0) && (nm = hitName()) != "") { return nm }
  split("", rdrop)
  if (arrowLeak()) { compile("A"); compile("B"); if (sameLists(kind == "iropt")) { return "7383-arrow-oracle-leaks-type-param" } }
  split("", rdrop)
  if (selfOmit()) { compile("A"); compile("B"); if (sameLists(0)) { return "7387-self-result-oracle-omits-function" } }
  return ""
}
side == 0 && $0 == "@@@BIT2@@@" { side = 1; next }
side == 0 { nA++; LA[nA] = $0; next }
{ nB++; LB[nB] = $0 }
END {
  if (kind != "ir" && kind != "iropt") { exit 1 }
  nm = explainIr()
  if (nm == "") { exit 1 }
  print nm
  exit 0
}

'
}

# explainLagTypes <oracle_types> <tree_types> -- the two `types` signatures declared against the
# 0.39.0 oracle. Prints the name and returns 0 when the dumps have the same number of lines and
# every line that differs is the same `L:C: expr:` with a different type, of one of two shapes;
# else prints nothing and returns 1.
#   7387-self-result-types: the oracle type is `Self` or `<error>` (an interface method whose
#     result is `Self`, or what is called on it) and the tree type is neither; at least one
#     oracle type is `Self`.
#   7383-arrow-param-types: expr is a bare name (an arrow parameter), the oracle type is one
#     capital letter (the unsubstituted type parameter) or `<error>`, and the tree type is not
#     `<error>`; at least one oracle type is the capital letter.
explainLagTypes() {
  awk '
    FNR == 1 { fi++ }
    fi == 1 { a[++na] = $0; next }
    { b[++nb] = $0 }
    # cut -- s into the prefix through its last ": " and the type, in cutP and cutT.
    function cut(s,    i) {
      for (i = length(s) - 1; i > 0; i--) { if (substr(s, i, 2) == ": ") { cutP = substr(s, 1, i + 1); cutT = substr(s, i + 2); return 1 } }
      return 0
    }
    END {
      if (na != nb) { exit 1 }
      selfOk = 1; arrowOk = 1; selfN = 0; arrowN = 0
      for (i = 1; i <= na; i++) {
        if (a[i] == b[i]) { continue }
        if (!cut(a[i])) { exit 1 }
        pa = cutP; ta = cutT
        if (!cut(b[i]) || cutP != pa) { exit 1 }
        tb = cutT
        expr = pa; sub(/^[0-9]+:[0-9]+: /, "", expr); sub(/: $/, "", expr)
        if (tb ~ /<error>|^Self$/) { exit 1 }
        if (ta != "Self" && ta != "<error>") { selfOk = 0 } else if (ta == "Self") { selfN++ }
        if (expr !~ /^[a-z_][A-Za-z0-9_]*$/ || (ta !~ /^[A-Z]$/ && ta != "<error>")) { arrowOk = 0 } else if (ta != "<error>") { arrowN++ }
      }
      if (selfOk && selfN > 0) { print "7387-self-result-types"; exit 0 }
      if (arrowOk && arrowN > 0) { print "7383-arrow-param-types"; exit 0 }
      exit 1
    }
  ' <(printf '%s\n' "$1") <(printf '%s\n' "$2")
}
