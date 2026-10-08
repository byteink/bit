# Sourced-only (by scripts/selfhost-ir-signatures.sh): the declared signatures against the 0.40.0
# oracle that read whole dumps, split out so that file stays under the 800-line ceiling. They
# retire at the next stage0 repin. irWalkAwk sets the awk programs (a function so this file has no
# top-level statement and holds no brace outside a function); explainIrLag is the `ir` and `iropt`
# row, explainLagTypes the `types` row. The identities, the files they explain and the merge each
# one belongs to are in selfhost-ir-signatures.sh under "Declared signatures".
#
# The IR row normalizes both dumps (stage 1, the oracle side rewritten, then on the tree side the
# fold, then the renumber) and holds when the two texts agree byte for byte. The oracle is the one
# that is rewritten, and only along the exact shapes #7562 changed, so a tree that still leaves a
# halfword slice word-strided, or differs anywhere else, stays unexplained.
irWalkAwk() {
  IR_PW_AWK='# The element widths a trial may treat as packed: half is #7562 (2), narrow is #7574 (1 for i8/bool, 4
# for i32/u32/f32). A type outside the trial set is width 0, so its sites are never rewritten.
function pw(t) {
  if (half == 1 && (t == "i16" || t == "u16")) { return 2 }
  if (narrow == 1 && (t == "i8" || t == "bool")) { return 1 }
  if (narrow == 1 && (t == "i32" || t == "u32" || t == "f32")) { return 4 }
  return 0
}
'
  IR_STAGE1_AWK='# Stage 1: one dump, one side. Pure ops (const, shl, add, sub, mul, convert) are never printed as
# lines: each use prints the whole expression in braces, so where an operand was defined never
# matters. Every other def is named by its ordinal in the function, `$k`. Side oracle then rewrites
# the word-strided halfword (i16/u16) slice shapes into the packed ones the tree emits; side tree
# is only inlined, never rewritten, so a tree that failed to pack a site stays different.
BEGIN { LB = "\173"; RB = "\175"; CI3 = LB "const_int i64 3" RB; CI8 = LB "const_int i64 8" RB }
function rwPtr(e,   n, t, w) {
  if (e !~ /^convert \*[a-z0-9]+ / || index(e, " " LB "add i64 ") == 0 || index(e, ", " LB "mul i64 ") == 0) { return e }
  t = e; sub(/^convert \*/, "", t); sub(/ .*$/, "", t)
  w = pw(t)
  n = length(e) - length(CI8 RB RB)
  if (w == 0 || substr(e, n + 1) != CI8 RB RB) { return e }
  return substr(e, 1, n) LB "const_int i64 " w RB RB RB
}
function isHalf(t) { return pw(t) > 0 }
function isHalfSlice(t) { return t ~ /^\[\][a-z0-9]+$/ && pw(substr(t, 3)) > 0 }
function lastTok(s,   n, p) { n = split(s, p, " "); return p[n] }
function resTy(e,   n, p) { n = split(e, p, " "); if (p[1] == "const_bool") { return "bool" }; return (p[2] ~ /^(i8|i16|i32|i64|u8|u16|u32|u64|bool|f32|f64|int)$/) ? p[2] : p[n] }
function ex(s,   out, id) {
  out = ""
  while (match(s, /%[0-9]+/)) {
    id = substr(s, RSTART, RLENGTH)
    out = out substr(s, 1, RSTART - 1) (id in S2 ? S2[id] : (id in E ? "{" E[id] "}" : (id in N ? N[id] : id)))
    s = substr(s, RSTART + RLENGTH)
  }
  return out s
}
function typeOf(x,   p) {
  if (x ~ /^\$[0-9]+$/) { return OT[x] }
  if (x ~ /^[\173][a-z_]+ /) { split(substr(x, 2), p, " "); return p[2] }
  return ""
}
function topComma(s,   i, d, c) {
  d = 0
  for (i = 1; i <= length(s); i++) {
    c = substr(s, i, 1)
    if (c == LB || c == "(" || c == "[") { d++ }
    if (c == RB || c == ")" || c == "]") { d-- }
    if (d == 0 && substr(s, i, 2) == ", ") { return i }
  }
  return 0
}
function sliceOfBuf(b,   d, p) {
  if (!(b in Def)) { return "" }
  d = Def[b]
  if (d !~ /^field_get \$[0-9]+\[0\] i64$/) { return "" }
  sub(/^field_get /, "", d)
  sub(/\[0\] i64$/, "", d)
  return OT[d]
}
function rwLoad(rest,   t, addr, c, b, i, r, m, k) {
  t = lastTok(rest)
  if (side != "oracle" || !isHalf(t) || rest !~ /^field_get .*\[0\] [a-z0-9]+$/) { return rest }
  addr = rest
  sub(/^field_get /, "", addr)
  sub(/\[0\] [a-z0-9]+$/, "", addr)
  if (addr ~ /^\{add i64 .*, \{shl i64 .*, \{const_int i64 3\}\}\}$/) {
    r = substr(addr, 10, length(addr) - 10)
    c = topComma(r)
    b = substr(r, 1, c - 1)
    i = substr(r, c + 2)
    if (i ~ /^\{shl i64 / && i ~ /, \{const_int i64 3\}\}$/) {
      i = substr(i, 10, length(i) - 10 - length(", " CI3 RB) + 1)
      return "index_get " b "[" i "] " t
    }
  }
  if (addr ~ /^\{add i64 .*, \{const_int i64 [0-9]+\}\}$/) {
    r = substr(addr, 10, length(addr) - 10)
    c = topComma(r)
    b = substr(r, 1, c - 1)
    k = substr(r, c + 2)
    sub(/^[\173]const_int i64 /, "", k)
    sub(/[\175]$/, "", k)
    if (k % 8 == 0 && k > 0) { return "index_get " b "[{const_int i64 " (k / 8) "}] " t }
  }
  if (addr ~ /^\$[0-9]+$/ && isHalfSlice(sliceOfBuf(addr))) { return "index_get " addr "[{const_int i64 0}] " t }
  return rest
}
# A hoisted buffer pointer (a block parameter of the optimized dump) has no field_get to name its
# slice, so the narrow value type of the stored operand is the only evidence there.
function isParam(b) { return (b in OT) && !(b in Def) }
function rwStore(line,   buf, v, et, pre, x) {
  if (side != "oracle") { return line }
  pre = line
  sub(/^index_set /, "", pre)
  buf = pre
  sub(/\[.*$/, "", buf)
  v = pre
  sub(/^.*\] = /, "", v)
  pre = substr(line, 1, length(line) - length(v))
  et = sliceOfBuf(buf)
  et = isHalfSlice(et) ? substr(et, 3) : ""
  if ((et != "" || isParam(buf)) && v ~ /^[\173]convert [iu]64 / && isHalf(typeOf(substr(v, 14, length(v) - 14)))) { return pre substr(v, 14, length(v) - 14) }
  if (et != "" && v ~ /^\{const_int [iu]64 -?[0-9]+\}$/) {
    x = v
    sub(/^[\173]const_int [iu]64 /, "", x)
    return pre LB "const_int " et " " x
  }
  return line
}
function rwRunes(rest,   args, r1) {
  if (side != "oracle" || rune != 1 || rest !~ /^rt_call string_from_byte_range\(/) { return rest }
  args = substr(rest, length("rt_call string_from_byte_range(") + 1)
  r1 = substr(args, 1, index(args, ",") - 1)
  if (OT[r1] != "[]i32" && Def[r1] != "const_nil") { return rest }
  return "rt_call string_from_rune_range(" args
}
function rwCall(rest, id,   name, args, t, st, c, pre, w) {
  rest = rwRunes(rest)
  if (side != "oracle" || rest !~ /^rt_call slice_[a-z_]*\(/) { return rest }
  name = rest
  sub(/^rt_call /, "", name)
  sub(/\(.*$/, "", name)
  t = lastTok(rest)
  args = substr(rest, length("rt_call " name "(") + 1)
  sub(/\) [^)]*$/, "", args)
  c = split(args, AP, ", ")
  st = isHalfSlice(t) ? t : (c > 0 ? OT[AP[1]] : "")
  if (!isHalfSlice(st) || AP[c] != "{const_int i64 8}") { return rest }
  w = pw(substr(st, 3))
  pre = substr(rest, 1, length(rest) - length(t) - 1)
  sub(/\{const_int i64 8\}\)$/, "{const_int i64 " w "})", pre)
  if (name == "slice_get" && (t == "i16" || t == "i8" || t == "i32")) {
    S2[id] = LB "convert " t " " NEXTORD RB
    return pre " i64"
  }
  return pre " " t
}
# Both sides: the buffer and offset reads of an []f32 slice are renamed so IR_F32_AWK can see them;
# it turns every one that is not consumed by a store or a load back into the field_get it was.
function markF32(e,   p) {
  if (narrow != 1 || e !~ /^field_get \$[0-9]+\[(0|16)\] i64$/) { return e }
  split(e, p, /[ \[]/)
  if (OT[p[2]] != "[]f32") { return e }
  return ((e ~ /\[0\] i64$/) ? "f32buf " : "f32off ") p[2]
}
function flushHeld() { if (HELD != "") { print HELD; HELD = "" } }
# #7574 stores an f32 element inline from a float register; the oracle widened it through
# `bitcast u32` into `rt_call slice_set` (the tree still does this where a lvalue is read back whole,
# at elem_size 4 instead of 8). All the spellings are canonicalized to the pseudo-op
# `f32_store s[i] = v`: here the oracle one (the bitcast line is held until the next def and
# becomes the pseudo-op when that def is the slice_set consuming it, otherwise it prints untouched),
# in IR_F32_AWK the tree one (the unchecked fill and the slice_len-guarded store).
# The oracle read of an f32 element is `rt_call slice_get(s, i, 4) u32` and a `bitcast f32`; held the
# same way and collapsed to `f32_load s[i] f32`, which the tree spelling (guard, then index_get) is
# collapsed to in IR_F32_AWK.
function f32Load(e, id,   args, c) {
  if (narrow != 1 || e !~ /^rt_call slice_get\(/ || lastTok(e) != "u32") { return 0 }
  args = substr(e, length("rt_call slice_get(") + 1)
  sub(/\) u32$/, "", args)
  c = split(args, AP, ", ")
  if (c != 3 || AP[3] != "{const_int i64 4}" || OT[AP[1]] != "[]f32") { return 0 }
  HELDKIND = "load"; HELDS = AP[1]; HELDI = AP[2]
  HELDID = "$" k
  N[id] = "$" (k++)
  OT[N[id]] = "u32"
  HELD = "  " N[id] " = " e
  return 1
}
function f32Fill(e, id,   v, args, c, S) {
  if (narrow != 1) { return 0 }
  if (e ~ /^bitcast u32 / && typeOf(substr(e, 13)) == "f32") {
    flushHeld()
    HELDV = substr(e, 13)
    HELDID = "$" k
    HELDKIND = "store"
    N[id] = "$" (k++)
    OT[N[id]] = "u32"
    HELD = "  " N[id] " = " e
    return 1
  }
  if (HELD != "" && HELDKIND == "load" && e == "bitcast f32 " HELDID) {
    k--
    N[id] = "$" (k++)
    OT[N[id]] = "f32"
    Def[N[id]] = "f32_load " HELDS "[" HELDI "] f32"
    print "  " N[id] " = " Def[N[id]]
    HELD = ""
    return 1
  }
  if (HELD == "" || HELDKIND != "store" || e !~ /^rt_call slice_set\(/ || lastTok(e) != "void") { return 0 }
  args = substr(e, length("rt_call slice_set(") + 1)
  sub(/\) void$/, "", args)
  c = split(args, AP, ", ")
  if (c != 4 || AP[3] != HELDID || AP[4] != (side == "oracle" ? "{const_int i64 8}" : "{const_int i64 4}") || OT[AP[1]] != "[]f32") { return 0 }
  S = AP[1]
  k--
  HELD = ""
  print "  f32_store " AP[1] "[" AP[2] "] = " HELDV
  return 1
}
/^func /{ flushHeld(); delete E; delete N; delete OT; delete Def; delete S2; k = 0; print; next }
/^bb[0-9]+\(/ {
  flushHeld()
  line = $0
  s = line
  while (match(s, /%[0-9]+: /)) {
    id = substr(s, RSTART, RLENGTH - 2)
    s = substr(s, RSTART + RLENGTH)
    ty = s
    sub(/(, %[0-9]+: .*|\)):?$/, "", ty)
    N[id] = "$" (k++)
    OT[N[id]] = ty
  }
  print ex(line)
  next
}
/^  %[0-9]+ = / {
  id = $1
  line = $0
  sub(/^  %[0-9]+ = /, "", line)
  op = $3
  if (op ~ /^(const_int|const_string|shl|add|sub|mul|convert)$/) {
    e = ex(line)
    if (side == "oracle" && op == "convert") { e = rwPtr(e) }
    E[id] = e
    next
  }
  NEXTORD = "$" k
  e = ex(line)
  if (f32Fill(e, id)) { next }
  flushHeld()
  e = markF32(e)
  e = rwLoad(rwCall(e, id))
  if (f32Load(e, id)) { next }
  N[id] = "$" (k++)
  OT[N[id]] = resTy(e)
  Def[N[id]] = e
  print "  " N[id] " = " e
  next
}
/^  index_set / { flushHeld(); print "  " rwStore(ex(substr($0, 3))); next }
{ flushHeld(); print ex($0) }
END { flushHeld() }'
  IR_FOLD_AWK='# Stage 2, tree side only: folds the append fast path that #7562 made eligible for []i16/[]u16
# (optappend.bit: elem_size equals the element width) back into the one slice_append call the
# oracle keeps. The template is matched line for line; a near miss folds nothing and so differs.
function repTok(s, from, to,   out, post, i) {
  out = ""
  while ((i = index(s, from)) > 0) {
    post = substr(s, i + length(from), 1)
    if (post ~ /[0-9]/) { out = out substr(s, 1, i + length(from) - 1); s = substr(s, i + length(from)); continue }
    out = out substr(s, 1, i - 1) to
    s = substr(s, i + length(from))
  }
  return out s
}
function dst(l) { sub(/^  /, "", l); sub(/ = .*$/, "", l); return l }
function tmplAt(i,   a, b, c, h, d, e, v, f, s, j, r, n, t, l, x, et, w, ix) {
  l = L[i]
  if (l !~ /^  \$[0-9]+ = slice_len \$[0-9]+$/) { return 0 }
  a = dst(l); h = l; sub(/^.* = slice_len /, "", h)
  b = dst(L[i + 1]); c = dst(L[i + 2])
  if (L[i + 1] != "  " b " = field_get " h "[24] i64") { return 0 }
  if (L[i + 2] != "  " c " = icmp_slt bool " a ", " b) { return 0 }
  x = L[i + 3]
  if (x !~ /^  br \$[0-9]+, bb[0-9]+\(\), bb[0-9]+\(\)$/) { return 0 }
  if (index(x, "br " c ", ") != 3) { return 0 }
  sub(/^  br \$[0-9]+, /, "", x)
  f = x; sub(/\(\), .*$/, "", f)
  s = x; sub(/^[^,]*, /, "", s); sub(/\(\)$/, "", s)
  if (L[i + 4] != f "():") { return 0 }
  d = dst(L[i + 5])
  if (L[i + 5] != "  " d " = field_get " h "[0] i64") { return 0 }
  e = dst(L[i + 6])
  sh = 0
  ix = "[{add i64 " e ", " a "}]"
  if (L[i + 6] != "  " e " = field_get " h "[16] i64") {
    sh = 1
    ix = "[" a "]"
  }
  v = L[i + 7 - sh]
  if (index(v, "  index_set " d ix " = ") != 1) { return 0 }
  v = substr(v, length("  index_set " d ix " = ") + 1)
  if (L[i + 8 - sh] != "  field_set " h "[8] = {add i64 " a ", {const_int i64 1}}") { return 0 }
  j = L[i + 9 - sh]
  if (j !~ /^  jump bb[0-9]+\(\$[0-9]+\)$/) { return 0 }
  if (L[i + 10 - sh] != s "():") { return 0 }
  t = L[i + 11 - sh]
  r = dst(t)
  et = t; sub(/^.* \[\]/, "", et)
  w = pw(et)
  if (w == 0 || t != "  " r " = rt_call slice_append(" h ", " v ", {const_int i64 0}, {const_int i64 " w "}) []" et) { return 0 }
  sub(/^  jump /, "", j); sub(/\(.*$/, "", j)
  if (L[i + 9 - sh] != "  jump " j "(" h ")" || L[i + 12 - sh] != "  jump " j "(" r ")") { return 0 }
  n = L[i + 13 - sh]
  if (index(n, j "(") != 1 || n !~ /^bb[0-9]+\(\$[0-9]+: \[\][a-z0-9]+\):$/) { return 0 }
  sub(/^[^(]*\(/, "", n); sub(/:.*$/, "", n)
  NN = n; RR = r; OUT1 = t
  return 1
}
function flush(   i, k, o, n) {
  o = 0
  for (i = 1; i <= n0; i++) {
    if (tmplAt(i)) {
      print OUT1
      for (k = i + 14 - sh; k <= n0; k++) { L[k] = repTok(L[k], NN, RR) }
      i = i + 13 - sh
      continue
    }
    print L[i]
  }
  n0 = 0
}
/^func /{ flush(); print; next }
{ L[++n0] = $0 }
END { flush() }'
  IR_F32_AWK='# Stage 2b, both sides: the inline f32 element store and load (#7574) collapsed to the pseudo-ops
# `f32_store s[i] = v` and `f32_load s[i] f32` the oracle slice_set / slice_get were canonicalized to. A store through a buffer read marked
# f32buf is the pseudo-op; when its index is `{add i64 <f32off of the same slice>, i}` and the nine
# lines before it are exactly the slice_len / icmp_ult / br guard with its panic block for that slice
# and index, that guard goes too. A guard that does not match, or whose values are used elsewhere,
# stays in the text and so keeps the file unexplained.
function dst(l) { sub(/^  /, "", l); sub(/ = .*$/, "", l); return l }
function usedOutside(tok, lo, hi,   j, s, i, c) {
  for (j = 1; j <= n0; j++) {
    if (j >= lo && j <= hi) { continue }
    s = L[j]
    while ((i = index(s, tok)) > 0) {
      c = substr(s, i + length(tok), 1)
      if (c !~ /[0-9]/) { return 1 }
      s = substr(s, i + length(tok))
    }
  }
  return 0
}
function guardAt(j, S, ix,   a, b, x, ok, bad) {
  if (j < 1) { return 0 }
  a = dst(L[j]); b = dst(L[j + 1])
  if (L[j] != "  " a " = slice_len " S) { return 0 }
  if (L[j + 1] != "  " b " = icmp_ult bool " ix ", " a) { return 0 }
  x = L[j + 2]
  if (x !~ /^  br \$[0-9]+, bb[0-9]+\(\), bb[0-9]+\(\)$/ || index(x, "br " b ", ") != 3) { return 0 }
  sub(/^  br \$[0-9]+, /, "", x)
  ok = x; sub(/\(\), .*$/, "", ok)
  bad = x; sub(/^[^,]*, /, "", bad); sub(/\(\)$/, "", bad)
  if (L[j + 3] != bad "():" || L[j + 5] != "  unreachable" || L[j + 6] != ok "():") { return 0 }
  if (L[j + 4] !~ /^  \$[0-9]+ = rt_call panic\(\{const_string "index out of range"\}\) void$/) { return 0 }
  return !usedOutside(a, j, j + 1) && !usedOutside(b, j + 1, j + 2) && !usedOutside(ok, j + 2, j + 6) && !usedOutside(bad, j + 2, j + 3)
}
function flush(   i, m, c, d, S, idx, v, q, r, inner, pfx) {
  for (i = 1; i <= n0; i++) {
    if (L[i] ~ /^  \$[0-9]+ = f32buf \$[0-9]+$/) { BUF[dst(L[i])] = L[i]; sub(/^.* = f32buf /, "", BUF[dst(L[i])]) }
    if (L[i] ~ /^  \$[0-9]+ = f32off \$[0-9]+$/) { OFF[dst(L[i])] = L[i]; sub(/^.* = f32off /, "", OFF[dst(L[i])]) }
  }
  for (i = 1; i <= n0; i++) {
    if (L[i] !~ /^  \$[0-9]+ = index_get \$[0-9]+\[.*\] f32$/) { continue }
    m = L[i]; sub(/^  \$[0-9]+ = index_get /, "", m)
    c = m; sub(/\[.*$/, "", c)
    if (!(c in BUF)) { continue }
    r = dst(L[i])
    idx = substr(m, length(c) + 2, length(m) - length(c) - 2 - length(" f32"))
    S = BUF[c]
    pfx = ""
    for (d in OFF) { if (OFF[d] == S && index(idx, "{add i64 " d ", ") == 1 && substr(idx, length(idx)) == "}") { pfx = "{add i64 " d ", "; break } }
    if (pfx == "") { continue }
    inner = substr(idx, length(pfx) + 1, length(idx) - length(pfx) - 1)
    if (!guardAt(i - 9, S, inner) || L[i - 1] != "  " d " = f32off " S || L[i - 2] != "  " c " = f32buf " S) { continue }
    for (q = i - 9; q < i; q++) { DEL[q] = 1 }
    L[i] = "  " r " = f32_load " S "[" inner "] f32"
  }
  for (i = 1; i <= n0; i++) {
    if (L[i] !~ /^  index_set \$[0-9]+\[.*\] = /) { continue }
    m = L[i]; sub(/^  index_set /, "", m)
    c = m; sub(/\[.*$/, "", c)
    if (!(c in BUF)) { continue }
    q = index(m, "] = ")
    v = substr(m, q + 4)
    idx = substr(m, length(c) + 2, q - length(c) - 2)
    S = BUF[c]
    pfx = ""
    for (d in OFF) { if (OFF[d] == S && index(idx, "{add i64 " d ", ") == 1 && substr(idx, length(idx)) == "}") { pfx = "{add i64 " d ", "; break } }
    if (pfx != "") {
      inner = substr(idx, length(pfx) + 1, length(idx) - length(pfx) - 1)
      if (guardAt(i - 9, S, inner) && L[i - 1] == "  " d " = f32off " S && L[i - 2] == "  " c " = f32buf " S) {
        for (m = i - 9; m < i; m++) { DEL[m] = 1 }
        idx = inner
      }
    }
    L[i] = "  f32_store " S "[" idx "] = " v
  }
  for (i = 1; i <= n0; i++) {
    if (DEL[i]) { continue }
    if (L[i] ~ /^  \$[0-9]+ = f32(buf|off) \$[0-9]+$/) {
      d = dst(L[i]); S = L[i]; sub(/^.* = f32(buf|off) /, "", S)
      if (!usedOutside(d, i, i)) { continue }
      L[i] = "  " d " = field_get " S ((L[i] ~ / = f32buf /) ? "[0]" : "[16]") " i64"
    }
    print L[i]
  }
  n0 = 0; delete L; delete DEL; delete BUF; delete OFF
}
/^func /{ flush(); print; next }
{ L[++n0] = $0 }
END { flush() }'
  IR_RENUM_AWK='# Stage 3, both sides: `$k` and `bbN` renumbered to first-appearance order, per function.
function mapTok(s, re, pre,   out, tok) {
  out = ""
  while (match(s, re)) {
    tok = substr(s, RSTART, RLENGTH)
    if (!(tok in M)) { M[tok] = pre (cnt[pre]++) }
    out = out substr(s, 1, RSTART - 1) M[tok]
    s = substr(s, RSTART + RLENGTH)
  }
  return out s
}
/^func /{ delete M; delete cnt; print; next }
{ print mapTok(mapTok($0, "\\$[0-9]+", "$"), "bb[0-9]+", "bb") }'
  IR_CMP_AWK='# The ir row verdict: both normalized dumps, split by @@@BIT2@@@, equal line for line.
/^@@@BIT2@@@$/ { second = 1; next }
{ if (second) { B[++nb] = $0 } else { A[++na] = $0 } }
END {
  if (na == 0 || na != nb) { exit 1 }
  for (i = 1; i <= na; i++) {
    if (A[i] != B[i]) { exit 1 }
  }
  if (which == "half") { print "7562-packed-halfword-slices" }
  else if (which == "narrow") { print "7574-packed-narrow-slices" }
  else { print "7637-string-from-rune-range" }
}'
  IR_TYPES_AWK='# The types row: the oracle dump, a line @@@BIT2@@@, then the tree dump. Rows are `line:col: name:
# type`. #7558 spells the synthesized import alias `__Json`, which lengthens the synthesized text, so
# only the COLUMN of a row moves: same row count, same line, name and type, a column that grows,
# on a source line that carries a synthesized `__json_` row, and never shrinks back along the line.
function rowPos(l) { return match(l, /^[0-9]+:[0-9]+: /) }
function lineOf(l,   p) { split(l, p, ":"); return p[1] + 0 }
function colOf(l,   p) { split(l, p, ":"); return p[2] + 0 }
function restOf(l) { sub(/^[0-9]+:[0-9]+: /, "", l); return l }
/^@@@BIT2@@@$/ { second = 1; next }
{ if (second) { B[++nb] = $0 } else { A[++na] = $0 } }
END {
  if (na != nb || na == 0) { exit 1 }
  for (i = 1; i <= na; i++) {
    if (rowPos(A[i]) && restOf(A[i]) ~ /^__json_/) { synth[lineOf(A[i])] = 1 }
  }
  for (i = 1; i <= na; i++) {
    if (!rowPos(A[i]) || !rowPos(B[i])) {
      if (A[i] != B[i]) { exit 1 }
      continue
    }
    ln = lineOf(A[i])
    d = colOf(B[i]) - colOf(A[i])
    if (ln != lineOf(B[i]) || restOf(A[i]) != restOf(B[i]) || d < last[ln]) { exit 1 }
    if (d > 0 && !synth[ln]) { exit 1 }
    last[ln] = d
    if (d > 0) { moved++ }
  }
  if (moved == 0) { exit 1 }
  print "7558-synth-json-alias-column-shift"
}'
}

# irTrial <oracle_text> <bit2_text> <half> <narrow> <rune> <name> -- one normalization with the given
# rewrite classes enabled; prints the signature when the two dumps then agree byte for byte.
irTrial() {
  local o t f="-v half=$3 -v narrow=$4 -v rune=$5"
  # shellcheck disable=SC2086
  o=$(canon_ir_ids "$1" | LC_ALL=C awk $f -v side=oracle "${IR_PW_AWK}${IR_STAGE1_AWK}" | LC_ALL=C awk "${IR_F32_AWK}" | LC_ALL=C awk "${IR_RENUM_AWK}") || return 1
  # shellcheck disable=SC2086
  t=$(canon_ir_ids "$2" | LC_ALL=C awk $f -v side=tree "${IR_PW_AWK}${IR_STAGE1_AWK}" | LC_ALL=C awk $f "${IR_PW_AWK}${IR_FOLD_AWK}" | LC_ALL=C awk "${IR_F32_AWK}" | LC_ALL=C awk "${IR_RENUM_AWK}") || return 1
  printf '%s\n@@@BIT2@@@\n%s\n' "${o}" "${t}" | LC_ALL=C awk -v which="$6" "${IR_CMP_AWK}"
}

# explainIrLag <oracle_text> <bit2_text> -- prints the signature name and returns 0 when the two
# dumps agree after normalization, prints nothing and returns 1 otherwise. The trials run from the
# narrowest rewrite set to the widest and the first that agrees names the file: halfword alone is
# #7562, halfword plus the 1 and 4 byte widths is #7574, the []rune range call alone or together
# with the packing is #7637 (a file that needs both is named for the rune call, the one rewrite
# that is not a width).
explainIrLag() {
  [ "$(canon_ir_ids "$1")" = "$(canon_ir_ids "$2")" ] && return 1
  irWalkAwk
  irTrial "$1" "$2" 1 0 0 half && return 0
  irTrial "$1" "$2" 1 1 0 narrow && return 0
  irTrial "$1" "$2" 0 0 1 rune && return 0
  irTrial "$1" "$2" 1 1 1 rune && return 0
  return 1
}

# explainLagTypes <oracle_text> <bit2_text> -- the `types` row, same contract as explainIrLag.
explainLagTypes() {
  irWalkAwk
  printf '%s\n@@@BIT2@@@\n%s\n' "$1" "$2" | LC_ALL=C awk "${IR_TYPES_AWK}"
}
