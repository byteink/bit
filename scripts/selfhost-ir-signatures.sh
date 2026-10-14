#!/usr/bin/env bash
# Declared-transform-signature scoring for the IR differentials (#3125).
#
# Extracted from scripts/selfhost-diffdump.sh's ir/iropt rows into its own
# sourced file by #3132, so scripts/selfhost-diffruntime.sh's SEPARATE
# per-file IR walk (its own `--dump-ir-pre` shell-out, never routed through
# selfhost-diffdump.sh) can reuse the identical scoring logic instead of
# re-implementing it — the exact "a fix reaches some callers and misses
# others" shape #2743/#2866 already cost this repo once (six pasted
# selfhost-diff*.sh scripts, a safety fix that reached three and missed
# three). Both callers source THIS file with `. scripts/selfhost-ir-signatures.sh`;
# neither defines its own copy of explainMismatch.
#
# --- Declared-transform-signature escape valve (#3125, same shape as #3103) ---
#
# selfhost-diffdump.sh's ir/iropt rows, and selfhost-diffruntime.sh's
# per-file `runtime/**` walk, each compare a file's lowered IR TEXT against
# the pinned stage0's, byte for byte (mod $t<id> canon on the diffdump side),
# with NO divergence permitted at all. That held only as long as no
# intentional lowering improvement had landed since the pin — #3107 was the
# first that did, and it reddened every IR arm by construction: a mismatch is
# no longer automatically a REGRESSION. It is checked first against a small
# table of DECLARED TRANSFORM SIGNATURES (`explainMismatch` below) — an exact
# opcode-COUNT-delta identity, proven against the real branch that motivated
# it, not eyeballed. Only a divergence that satisfies a registered signature
# is downgraded to EXPLAINED (printed, not failed); anything else still fails
# exactly as before.
#
# WHY NOT A PER-FILE ALLOWLIST INSTEAD. There was one — the expected-mismatch
# list #1883 deleted, "so a known difference could be written down instead of
# fixed." A signature is not that list reborn: an allowlist names a FILE and
# accepts anything it does next; a signature names an IDENTITY the delta must
# satisfy, checked fresh on every run, and a second, unrelated bug landing on
# an already-explained file still fails it.
#
# WHY NOT TREE-AGAINST-TREE (the other option this ticket weighed). #3103
# rejected two self-build generations of the SAME tree because `bit build
# compiler` links a pre-built libbitrt.a, so that comparison never touched
# runtime codegen at all — vacuous by construction. That specific mechanism
# does not apply here: `--dump-ir-pre`/`--dump-ir` lower one file standalone,
# no link step. The DEEPER reason still does, though: two generations of ONE
# tree share whatever lowering bug that tree has, so a bug baked into both
# generations identically never diverges — the same self-reproducing-bug
# blind spot, independent of why #3103 hit it. A signature checked against an
# INDEPENDENT, unchanged oracle (the pinned release) does not have that blind
# spot: a real bug fails the identity and is reported as a regression exactly
# like any other divergence.
#
# WHICH HOSTS. Every declared signature applies on EVERY host (aarch64-macos,
# aarch64-linux, x86_64-linux) — unlike #3103's diffruntime object-byte arm,
# which is aarch64-only because it disassembles target MACHINE CODE.
# `--dump-ir-pre`/`--dump-ir` are pre-codegen: the SSA text carries no
# register or instruction-selection content, so it does not vary by target
# ISA at all.
#
# COST PER LANDING, as this ticket names up front: a future lowering change
# that alters IR shape needs its OWN signature added to `explainMismatch`
# below, derived the same way — diff the real branch against the pinned
# oracle, aggregate every nonzero opcode delta across every diverging file,
# and solve for the coefficients. A signature that only explains the one file
# its author happened to look at is not a signature; it is a scoped allowlist
# wearing a disguise, and #1883 is why that is rejected.
#
# Retirement history is preserved in docs/development/dump-differential.md.
#
# --- Declared signatures (against the 0.41.0 oracle) ---
#
# Each retires at the next stage0 repin, the first oracle cut from a tree that carries #7745
# (7745-loop-defer-stack), #7761 and #7770 (7761-range-chain-cse) or #7766 and #7773
# (7766-synth-json-helper-column-shift), or #7929 (7933-variadic-type-marker
# and 7936-variadic-doc-marker), or #7279 (8110-contextual-in-token).
#
# 7933-variadic-type-marker (`types`) explains only an inferred direct binding
# of a unique, unshadowed top-level variadic function with primitive parameters
# and result. Both compilers must check the unchanged source successfully and
# emit identical AST/tokens. Token offsets pin the binding row; the AST proves
# the final rest parameter and exact type. Every other dump byte stays equal.
# Nested/imported/generic captures and failed witnesses remain unexplained.
#
# 7766-synth-json-helper-column-shift (`types`). #7766 (a9a95fc70) added `jsonAppendValue`,
# `jsonDecJson` and `jsonTextValue` to the helper lists a `@json` class synthesizes imports for
# (jsonAppendHelperNames, jsonDecHelperNames, jsonDecTextHelperNames), and #7773 (1f0ea0c1a)
# added `jsonTextEnumKey`, `jsonTextEnumIndex` and the `__json_dv` local to the text decoder's.
# Every helper name is written into the synthesized text twice (the name and its `__` alias), so
# the text is longer and every row `--dump-types` places after the insertion moves right. Only the
# COLUMN moves. `explainJsonHelperShift` prints the signature and returns 0 only when ALL hold:
#   1. the file declares a `@json` class (its path is the 4th argument of explainMismatch);
#   2. both dumps have the same, nonzero number of rows, and every row agrees on line, name and
#      type, in the same order (a non-row line must be equal);
#   3. a column moves only on a source line that carries a synthesized `__json_` row, and only a
#      synthesized name moves there: `__json_*`, or `cols`/`__row` of an `@table` class on that line;
#   4. a column only grows, and never shrinks back along the line (the shift is cumulative: the
#      later the insertion point, the fewer rows sit after it);
#   5. at least one column moved.
# 12 corpus files: run_json_attr, run_json_decode, run_json_decode_classgeneric/_enum/_errors/
# _generic/_lenient/_text, run_json_schema, run_synth_alias_collision, run_table_persisted_flag
# (its `cols` and `__row` sit on the `@table @json` line, after the insertion) and
# _tests_/imports/jsonattr/model/user.bit. A changed type, a changed name, a moved row of a user
# binding, a moved row on a line with no `__json_` row, or a file with no `@json` class stays
# unexplained.
#
# 7745-loop-defer-stack (`ir`, `iropt`). #7745 (lowerdefer.bit) lowers a function with a `defer`
# inside a loop onto a per-frame stack of thunks: every execution of a defer builds
# `make_closure @defer$thunk$N` (a function that unpacks the captured receiver/arguments and makes the
# deferred call) and appends it to a `[]fn() void`, and every exit pops the stack. The pinned stage0 kept
# one flag and one set of slots per defer statement and replayed each at every exit. The two shapes share
# nothing a rewrite could map line to line, so the identity is on the function level, in three parts.
# `explainLoopDeferStack` prints the signature and returns 0 only when ALL hold:
#   1. A tree function is STACK-MODE when its body holds a `make_closure @defer$thunk$N`. There is at
#      least one, every `defer$thunk$N` function of the tree is made by some stack-mode function, every
#      thunk a stack-mode function makes exists, and the oracle has a function of the same name for each
#      stack-mode function.
#   2. Every other function is byte-equal. Both dumps lose the stack-mode functions; the tree also loses
#      the thunks, and a `closure$N` or `trampoline$N` name (they share the thunks' id space, so every
#      one after a thunk moved up by the thunks before it) is renumbered back by that count.
#   3. For each stack-mode function every callee (`call @f`, `rt_call f`, `call_iface`) of the oracle
#      function is a callee of the tree function or of a thunk it makes, so no deferred call was dropped.
#      The tree may hold more: the oracle replays a defer only at an exit it can reach, and a loop with
#      no exit has none. The stack's own `rt_call slice_append`/`slice_get` are not callees here.
# What it does not check is the body of a stack-mode function beyond that callee set; the golden case
# _tests_/cases/run_defer_each_loop_iteration.bit proves its behaviour. Files: see the run output.
#
# explainLoopDeferStack <oracle_text> <bit2_text> -- see the 7745 entry above.
irLoopDeferAwk() {
  IR_LOOPDEFER_AWK='
function fname(s,   n) { n = s; sub(/^func /, "", n); sub(/\(.*$/, "", n); return n }
function isThunk(n) { return n ~ /^defer\$thunk\$[0-9]+$/ }
function thunkId(n,   i) { i = n; sub(/^defer\$thunk\$/, "", i); return i + 0 }
# The callee tokens of one function text, as " tok " items appended to the set string s.
function callees(text, s,   a, n, i, l, t) {
  n = split(text, a, "\n")
  for (i = 1; i <= n; i++) {
    l = a[i]; t = ""
    if (match(l, /= call @[^(]+\(/)) { t = substr(l, RSTART + 2, RLENGTH - 3) }
    else if (match(l, /= rt_call [^(]+\(/)) { t = substr(l, RSTART + 2, RLENGTH - 3) }
    else if (l ~ /= call_iface /) { t = "call_iface" }
    if (t != "" && t != "rt_call slice_append" && t != "rt_call slice_get" && index(s, " " t " ") == 0) { s = s " " t " " }
  }
  return s
}
# Whether every item of the set string x is in the set string y.
function subsetSet(x, y,   a, n, i) {
  n = split(x, a, "  ")
  for (i = 1; i <= n; i++) {
    gsub(/^ +| +$/, "", a[i])
    if (a[i] != "" && index(y, " " a[i] " ") == 0) { return 0 }
  }
  return 1
}
# Renumbers every closure$N / trampoline$N of a line down by the thunks with a smaller id.
function renumber(line,   out, tok, id, k, c) {
  out = ""
  while (match(line, /(closure|trampoline)\$[0-9]+/)) {
    tok = substr(line, RSTART, RLENGTH)
    id = tok; sub(/^[a-z]+\$/, "", id); id = id + 0
    c = 0
    for (k = 1; k <= nth; k++) { if (TID[k] < id) { c++ } }
    sub(/\$[0-9]+$/, "", tok)
    out = out substr(line, 1, RSTART - 1) tok "$" (id - c)
    line = substr(line, RSTART + RLENGTH)
  }
  return out line
}
$0 == "@@@BIT2@@@" { side = 1; cur = ""; next }
{
  if ($0 ~ /^func /) {
    cur = fname($0)
    if (side == 0) { on++; ON[on] = cur; OT[cur] = "" } else { tn++; TN[tn] = cur; TT[cur] = "" }
  }
  if (cur != "") { if (side == 0) { OT[cur] = OT[cur] $0 "\n" } else { TT[cur] = TT[cur] $0 "\n" } }
}
END {
  nth = 0; ns = 0
  for (i = 1; i <= tn; i++) {
    f = TN[i]
    if (isThunk(f)) { nth++; TID[nth] = thunkId(f); TNAME[nth] = f; continue }
    if (index(TT[f], "make_closure @defer$thunk$") > 0) { ns++; SN[ns] = f; ISS[f] = 1 }
  }
  if (ns == 0) { exit 1 }
  # 1. thunks and stack-mode functions pair up, and the oracle has every stack-mode function.
  for (i = 1; i <= ns; i++) {
    f = SN[i]
    if (!(f in OT)) { exit 1 }
    m = split(TT[f], L, "\n"); need = ""
    for (j = 1; j <= m; j++) {
      if (match(L[j], /make_closure @defer\$thunk\$[0-9]+/)) {
        t = substr(L[j], RSTART + 14, RLENGTH - 14)
        if (!(t in TT)) { exit 1 }
        MADE[t] = 1; need = need " " t
      }
    }
    NEED[f] = need
  }
  for (i = 1; i <= nth; i++) { if (!(TNAME[i] in MADE)) { exit 1 } }
  # 3. the callee sets.
  for (i = 1; i <= ns; i++) {
    f = SN[i]
    ts = callees(TT[f], ""); m = split(NEED[f], P, " ")
    for (j = 1; j <= m; j++) { ts = callees(TT[P[j]], ts) }
    os = callees(OT[f], "")
    if (!subsetSet(os, ts)) { exit 1 }
  }
  # 2. everything else is byte-equal.
  ot = ""; tt = ""
  for (i = 1; i <= on; i++) { if (!(ON[i] in ISS)) { ot = ot OT[ON[i]] } }
  for (i = 1; i <= tn; i++) {
    f = TN[i]
    if ((f in ISS) || isThunk(f)) { continue }
    m = split(TT[f], L, "\n")
    for (j = 1; j < m; j++) { tt = tt renumber(L[j]) "\n" }
  }
  # A dump ends at its last function; the one the tree loses may have been followed by that blank line.
  sub(/\n+$/, "", ot); sub(/\n+$/, "", tt)
  if (ot != tt) { exit 1 }
  print "7745-loop-defer-stack"
}'
}

explainLoopDeferStack() {
  irLoopDeferAwk
  printf '%s\n@@@BIT2@@@\n%s\n' "$(canon_ir_ids "$1")" "$(canon_ir_ids "$2")" | LC_ALL=C awk "${IR_LOOPDEFER_AWK}"
}

# explainLoopDeferPolls <oracle_ir> <bit2_ir> <seed_count> <self_count> -- the 7745 entry above,
# read by scripts/selfhost-diffsafepoints.sh for an EXTRA-SAFEPOINT divergence. Prints the signature
# and returns 0 only when explainLoopDeferStack holds (so the dumps differ in the stack-mode
# functions and their thunks only) AND, summed over the stack-mode functions, with
# d = self - seed and P = the added `rt_call slice_get` (one per pop loop, `slice_len` down to 0):
#   d > 0 and P == d     every extra poll is a pop loop's back edge, and each loop adds one
#   added call_value == P   each loop body makes exactly one deferred call
#   added icmp_sgt == P     each loop has exactly one header comparison
# The pushes add none: `make_closure` and `slice_append` carry no back edge, so a closure
# allocation per defer is not a poll. A poll with no pop loop (d > P), a pop loop that lost its
# poll (d < P), or a missing safepoint (d < 0) is refused. Retires with the 7745 entry above.
explainLoopDeferPolls() {
  explainLoopDeferStack "$1" "$2" >/dev/null || return 1
  printf '%s\n@@@BIT2@@@\n%s\n' "$1" "$2" | LC_ALL=C awk -v d="$(($4 - $3))" '
function bump(k) {
  if ($0 ~ /rt_call slice_get\(/) { N[k, "get"]++ }
  else if ($0 ~ / call_value /)    { N[k, "val"]++ }
  else if ($0 ~ / icmp_sgt /)      { N[k, "sgt"]++ }
  else if (side == 1 && $0 ~ /make_closure @defer\$thunk\$/) { S[cur] = 1 }
}
$0 == "@@@BIT2@@@" { side = 1; cur = ""; next }
/^func / { cur = $2; sub(/\(.*$/, "", cur); next }
cur != "" { bump(side SUBSEP cur) }
END {
  split("get val sgt", K, " ")
  for (f in S) {
    for (i = 1; i <= 3; i++) { delta[K[i]] += N[1 SUBSEP f, K[i]] - N[0 SUBSEP f, K[i]] }
  }
  if (d > 0 && delta["get"] == d && delta["val"] == d && delta["sgt"] == d) { print "7745-loop-defer-stack"; exit 0 }
  exit 1
}'
}

# 7761-range-chain-cse (`iropt`). #7761 (optselect.bit) fuses an if's branch-chain range check into one
# unsigned compare: `br (icmp_uge x lo), R, F` + R `br (icmp_ule x hi), T, F` becomes
# `t = sub x lo; br (icmp_ule t (hi-lo)), T, F` and R is dropped; the mirror `c < lo || c > hi`
# (`icmp_ult` + `icmp_ugt`) becomes the same compare with the edges swapped. #7770 (optcse.bit) then keys
# a single-predecessor block's param as its edge argument, so the body's `c - lo` is forwarded to that
# `sub`, and any other pure op or load on such a param to its earlier twin. Both are post-opt only, so
# `--dump-ir-pre` (`ir`) does not move. Checked per FUNCTION, ids and block numbers being function-local:
# the two dumps hold the same functions in the same order and the same text ahead of the first, at
# least one function differs, and each that differs satisfies, with d[op] = tree count - oracle
# count and n = -d[br] the fused sites (CSE never removes a `br`):
#   exact     n >= 0, d[jump] <= 0 and d[blocks] = d[br] + d[jump]: every block that goes takes its
#             own `br` (a fused R) or `jump` (an inlined fused copy folding further), never a `ret`
#   bounded   some split n = n1 (`&&`) + n2 (`||`), both >= 0, with d[icmp_uge] <= -n1,
#             d[icmp_ult] <= -n2, d[icmp_ugt] <= -n2 and d[icmp_ule] <= n2 (equalities but for the
#             compares CSE also forwards); d[sub] <= n and d[const_int] <= n (each site adds at most
#             one `sub` and the `hi - lo` constant); every other op d <= 0, and one that decreases is
#             an op CSE forwards (`opIsCsePure`/`opIsCseLoad`/element `index_get`)
#   nonempty  n >= 1, or some op decreased (a #7770-only function)
# What it does not check is which value a forwarded use now reads; the golden cases
# ir_if_range_chain, opt_select_range_chain and ir_cse_param_edge pin that. Files: see the run output.
#
# explainRangeChainCse <oracle_text> <bit2_text> -- see the 7761 entry above.
explainRangeChainCse() {
  printf '%s\n@@@BIT2@@@\n%s\n' "$(canon_ir_ids "$1")" "$(canon_ir_ids "$2")" | LC_ALL=C awk '
function opOf(l) {
  sub(/^ +/, "", l); sub(/^%[0-9]+ = /, "", l); sub(/ .*$/, "", l); return l
}
function cse(op) {
  return op ~ /^(add|sub|mul|smulhi|umulhi|fadd|fsub|fmul|fdiv|band|bor|bxor|shl|ashr|lshr|icmp_[a-z]+|fcmp_[a-z]+|const_int|const_bool|const_float|field_get|slice_len|index_get)$/
}
function note(op) { if (index(OPS[cur], " " op " ") == 0) { OPS[cur] = OPS[cur] " " op " " } }
function dl(f, op) { return C[1, f, op] - C[0, f, op] }
function mx(a, b) { return a > b ? a : b }
function mn(a, b) { return a < b ? a : b }
BEGIN { side = 0 }
$0 == "@@@BIT2@@@" { side = 1; cur = ""; next }
/^func / {
  cur = $2; sub(/\(.*$/, "", cur); N[side]++; NAME[side, N[side]] = cur; T[side, cur] = ""
}
cur == "" { P[side] = P[side] $0 "\n"; next }
{ T[side, cur] = T[side, cur] $0 "\n" }
/^bb[0-9]+\(/ { B[side, cur]++; next }
/^  / { op = opOf($0); C[side, cur, op]++; note(op) }
END {
  if (N[0] != N[1] || N[0] == 0 || P[0] != P[1]) { exit 1 }
  changed = 0
  for (i = 1; i <= N[0]; i++) {
    f = NAME[0, i]
    if (NAME[1, i] != f) { exit 1 }
    if (T[0, f] == T[1, f]) { continue }
    changed++
    n = -dl(f, "br"); jd = dl(f, "jump")
    if (n < 0 || jd > 0 || B[1, f] - B[0, f] != jd - n) { exit 1 }
    lo = mx(mx(0, dl(f, "icmp_ule")), n + dl(f, "icmp_uge"))
    hi = mn(mn(n, -dl(f, "icmp_ugt")), -dl(f, "icmp_ult"))
    if (lo > hi) { exit 1 }
    m = split(OPS[f], L, " "); fell = (jd < 0)
    for (j = 1; j <= m; j++) {
      op = L[j]
      if (op == "" || op ~ /^(br|jump)$/) { continue }
      d = dl(f, op)
      if (d < 0) { fell = 1 }
      if (op ~ /^icmp_u(ge|lt|gt|le)$/) { continue }
      if (d > ((op == "sub" || op == "const_int") ? n : 0)) { exit 1 }
      if (d < 0 && !cse(op)) { exit 1 }
    }
    if (n == 0 && !fell) { exit 1 }
  }
  if (changed == 0) { exit 1 }
  print "7761-range-chain-cse"
}'
}

# explainJsonHelperShift <oracle_text> <bit2_text> <file> -- the 7766 entry above.
explainJsonHelperShift() {
  [ -f "${3:-}" ] || return 1
  command grep -qE '^[^/]*@json([[:space:](]|$)' "$3" || return 1
  printf '%s\n@@@BIT2@@@\n%s\n' "$1" "$2" | LC_ALL=C awk '
function rowPos(l) { return match(l, /^[0-9]+:[0-9]+: /) }
function lineOf(l,   p) { split(l, p, ":"); return p[1] + 0 }
function colOf(l,   p) { split(l, p, ":"); return p[2] + 0 }
function restOf(l) { sub(/^[0-9]+:[0-9]+: /, "", l); return l }
function synthName(l) { return restOf(l) ~ /^(__json_[A-Za-z0-9_]+|cols|__row): / }
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
    if (ln != lineOf(B[i]) || restOf(A[i]) != restOf(B[i])) { exit 1 }
    if (d < last[ln]) { exit 1 }
    if (d > 0 && (!synth[ln] || !synthName(A[i]))) { exit 1 }
    last[ln] = d
    if (d > 0) { moved++ }
  }
  if (moved == 0) { exit 1 }
  print "7766-synth-json-helper-column-shift"
}'
}

# #7933: prove each changed binding against identical same-source AST/tokens.
# Unsupported shapes stay unexplained; no type text is globally normalized.
variadicTypeWitness() {
  local witness_dir=$1 source=$2 check_source=${3:-$2} binary mode rc side=0 input
  cp "$source" "$witness_dir/source" || return 1
  for binary in "$ORACLE" "$BIT2"; do
    for mode in check --dump-ast --dump-tokens; do
      input=$source
      [ "$mode" = check ] && input=$check_source
      ALARMRUN_KEEP_STDERR=1 alarmrun "$binary" "$mode" "$input" > "$witness_dir/$side$mode" 2> "$witness_dir/err"
      rc=$?
      [ "$rc" -eq 0 ] && [ ! -s "$witness_dir/err" ] || return 1
    done
    side=$((side + 1))
  done
  cmp -s "$source" "$witness_dir/source" || return 1
  cmp -s "$witness_dir/0--dump-ast" "$witness_dir/1--dump-ast" || return 1
  cmp -s "$witness_dir/0--dump-tokens" "$witness_dir/1--dump-tokens"
}

variadicMarkerParse() {
  perl - "$1" "${2:-types}" <<'PERL'
use strict; use warnings;
sub readall { open my $f, '<:raw', $_[0] or die; local $/; return <$f> }
my $d = shift; my $kind = shift; my $src = readall("$d/source");
my @stack; my @nodes; my $tree;
my $ast = readall("$d/0--dump-ast");
while ($ast =~ /\G\s*(\(|\)|"(?:\\.|[^"\\])*"|[^()\s]+)/gc) {
  my $t = $1;
  if ($t eq '(') {
    exit 1 if $tree && !@stack;
    my $n = []; push @nodes, $n;
    push @{$stack[-1]}, $n if @stack;
    $tree = $n unless @stack;
    push @stack, $n;
  } elsif ($t eq ')') { exit 1 unless @stack; pop @stack }
  else { exit 1 unless @stack; push @{$stack[-1]}, $t }
}
exit 1 if @stack || !$tree || $tree->[0] ne 'program' || $ast !~ /\G\s*\z/gc;
my (%decl, %count, %bound);
# Resolver pattern binders can shadow a declaration without a binding node.
sub addBound {
  my @pending = ($_[0]);
  while (@pending) {
    my $p = pop @pending;
    if (ref($p)) {
      exit 1 unless $p->[0] =~ /^(tuple_pat|field_pat|expr_list)$/;
      push @pending, @$p[1..$#$p];
    } else { $bound{$p}++ if $p ne '_' }
  }
}
for my $n (@nodes) {
  next unless @$n > 1;
  $count{$n->[2]}++ if $n->[0] eq 'func_decl' && !ref($n->[2]);
  addBound($n->[1]) if $n->[0] =~ /^(binding|param|param_rest|arrow_p|receiver|generic_param|for_of|for_in|recv_bind)$/;
  addBound($n->[2]) if $n->[0] =~ /^(catch_bind|variant_pat)$/;
}
my %prim = map { $_ => $_ } qw(bool i8 u8 i16 u16 i32 u32 i64 u64 f32 f64 string);
@prim{qw(int byte)} = qw(i64 u8);
my %alias = map { $_->[1] => 1 } grep { $_->[0] eq 'type_alias' } @nodes;
sub docAtom {
  my $t = shift;
  die unless $t =~ /^[A-Za-z_][A-Za-z_0-9]*$/ && !$alias{$t};
  return $prim{$t} // $t;
}
sub docGenericType {
  my ($t, $depth) = @_;
  die unless @$t == 3 && $t->[0] eq 'generic_inst';
  my $args = $t->[2];
  die unless ref($args) && $args->[0] eq 'type_args' && @$args > 1;
  return docType($t->[1], $depth + 1) . '<' . join(', ', map { docType($_, $depth + 1) } @$args[1..$#$args]) . '>';
}
sub docType {
  my ($t, $depth) = @_;
  die unless $depth < 128;
  return docAtom($t) unless ref($t);
  return '[]' . docType($t->[1], $depth + 1) if @$t == 2 && $t->[0] eq 'slice_type';
  return docType($t->[1], $depth + 1) . '!' if @$t == 3 && $t->[0] eq 'fallible' && $t->[2] eq '_';
  return docGenericType($t, $depth);
}
sub docGenerics {
  my $g = shift;
  return '' if !ref($g) && $g eq '_';
  die unless ref($g) && $g->[0] eq 'generic_params';
  my @names;
  for my $p (@$g[1..$#$g]) {
    die unless ref($p) && @$p == 3 && $p->[0] eq 'generic_param' && !ref($p->[1]);
    push @names, $p->[1];
  }
  return '<' . join(', ', @names) . '>';
}
sub docSignature {
  my $n = shift; my $params = $n->[4];
  return unless ref($params) && $params->[0] eq 'params' && @$params > 1;
  my @types; my $rest = 0;
  for my $i (1..$#$params) {
    my $p = $params->[$i];
    return unless docParam($p);
    if ($p->[0] eq 'param_rest') { $rest++; return unless $i == $#$params }
    push @types, docType($p->[2], 0);
  }
  return unless $rest == 1;
  my $result = docType($n->[5], 0); my $old = '(' . join(', ', @types) . ') => ' . $result;
  $types[-1] = '...' . $types[-1];
  return [$old, '(' . join(', ', @types) . ') => ' . $result, docGenerics($n->[3])];
}
sub docParam { my $p = shift; return ref($p) && @$p == 3 && $p->[0] =~ /^param(_rest)?$/ }
sub docRow {
  my ($row, $json) = @_;
  if ($json && $row =~ /^  \{/) {
    $row =~ s/,\z//;
    my $obj = JSON::PP::decode_json($row);
    return unless $obj->{kind} eq 'function';
    return [@$obj{qw(name params type)}];
  }
  return [$1, $2 // '', $3] if !$json && $row =~ /^function (\w+)(<[^>]+>)? (.+)$/;
  return;
}
sub docChangedRow {
  my ($a, $b, $row, $decls, $json) = @_;
  my ($name, $params, $ty) = @$row; my $s = $decls->{$name};
  die unless $s && $params eq $s->[2] && $ty eq $s->[0];
  my $want = "function $name$params $s->[1]";
  if ($json) {
    $want = $a; my $from = '"type": ' . JSON::PP::encode_json($s->[0]);
    my $to = '"type": ' . JSON::PP::encode_json($s->[1]);
    die unless $want =~ s/\Q$from\E/$to/;
  }
  die unless $b eq $want;
}
sub docRows {
  my ($old, $new, $decls, $json) = @_;
  my @a = split /\n/, $old, -1; my @b = split /\n/, $new, -1;
  die unless @a == @b; my %seen; my %changed;
  for my $i (0..$#a) {
    my $row = docRow($a[$i], $json);
    if (!$row) { die unless $a[$i] eq $b[$i]; next }
    die if $seen{$row->[0]}++;
    next if $a[$i] eq $b[$i];
    docChangedRow($a[$i], $b[$i], $row, $decls, $json);
    $changed{$row->[0]} = 1;
  }
  return join(',', sort keys %changed);
}
if ($kind eq 'doc') {
  require JSON::PP;
  my %docs;
  for my $outer (@$tree[1..$#$tree]) {
    next unless ref($outer) && @$outer == 2 && $outer->[0] eq 'export';
    my $n = $outer->[1];
    next unless ref($n) && @$n == 7 && $n->[0] eq 'func_decl' && $n->[1] eq '_';
    my $name = $n->[2];
    next if ref($name) || $count{$name} != 1 || $bound{$name};
    my $sig = eval { docSignature($n) };
    $docs{$name} = $sig if $sig;
  }
  my $plain = docRows(readall("$d/old"), readall("$d/new"), \%docs, 0);
  my $json = docRows(readall("$d/oldjson"), readall("$d/newjson"), \%docs, 1);
  exit($plain ne '' && $plain eq $json ? 0 : 1);
}
for my $n (@$tree[1..$#$tree]) {
  next unless ref($n) && @$n == 7 && $n->[0] eq 'func_decl';
  my ($name, $generics, $params, $result) = @$n[2..5];
  next if ref($name) || $count{$name} != 1 || $bound{$name} || ref($generics) || $generics ne '_';
  next unless ref($params) && $params->[0] eq 'params' && @$params > 1;
  next if ref($result) || !exists $prim{$result};
  my @types; my $valid = 1; my $rest = 0;
  for my $i (1..$#$params) {
    my $p = $params->[$i];
    if (!ref($p) || @$p != 3 || $p->[0] !~ /^param(_rest)?$/ || ref($p->[2]) || !exists $prim{$p->[2]}) { $valid = 0; last }
    if ($p->[0] eq 'param_rest') { $rest++; $valid = 0 unless $i == $#$params }
    push @types, $prim{$p->[2]};
  }
  next unless $valid && $rest == 1;
  my $old = '(' . join(', ', @types) . ') => ' . $prim{$result};
  $types[-1] = '...' . $types[-1];
  $decl{$name} = [$old, '(' . join(', ', @types) . ') => ' . $prim{$result}];
}
my @tokens;
for my $line (split /\n/, readall("$d/0--dump-tokens")) {
  exit 1 unless $line =~ /^(\w+) ([0-9]+)\.\.([0-9]+)$/;
  exit 1 if $2 > $3 || $3 > length($src);
  push @tokens, [$1, $2, substr($src, $2, $3 - $2)];
}
my %bindings;
for my $i (1..$#tokens-3) {
  my ($prev, $name, $eq, $callee, $end) = @tokens[$i-1..$i+3];
  next unless $prev->[0] =~ /^kw_(let|const)$/ && $name->[0] eq 'ident' && $eq->[0] eq 'eq';
  next unless $callee->[0] eq 'ident' && $end->[0] eq 'semicolon' && exists $decl{$callee->[2]};
  next unless $bound{$name->[2]} == 1;
  my @lines = split /\n/, substr($src, 0, $name->[1]), -1;
  my $pos = scalar(@lines) . ':' . (length($lines[-1]) + 1) . ': ' . $name->[2];
  $bindings{$pos} = $decl{$callee->[2]};
}
my @old = split /\n/, readall("$d/old"), -1; my @new = split /\n/, readall("$d/new"), -1;
exit 1 unless @old == @new; my $changed = 0;
for my $i (0..$#old) {
  next if $old[$i] eq $new[$i];
  exit 1 unless $old[$i] =~ /^([0-9]+:[0-9]+: [A-Za-z_][A-Za-z_0-9]*): (.+)$/;
  my ($pos, $ty) = ($1, $2); my $sig = $bindings{$pos};
  exit 1 unless $sig && $ty eq $sig->[0] && $new[$i] eq "$pos: $sig->[1]";
  $changed++;
}
exit 1 unless $changed;
PERL
}

explainVariadicTypeMarker() (
  [ -f "${3:-}" ] && [ -x "${ORACLE:-}" ] && [ -x "${BIT2:-}" ] || return 1
  command -v alarmrun >/dev/null || return 1
  local witness_dir rc
  witness_dir=$(mktemp -d "${TMPDIR:-/tmp}/t7933-witness-XXXXXX") || return 1
  trap 'rm -rf "${witness_dir:?}"' EXIT
  printf '%s\n' "$1" > "$witness_dir/old" || return 1
  printf '%s\n' "$2" > "$witness_dir/new" || return 1
  variadicTypeWitness "$witness_dir" "$3" || return 1
  variadicMarkerParse "$witness_dir" types
  rc=$?
  [ "$rc" -eq 0 ] || return 1
  awk 'BEGIN { print "7933-variadic-type-marker" }'
)

# Mirror loadModuleReadFiles, retaining raw names/bytes to detect source changes.
docModuleSource() {
  perl - "$@" <<'PERL'
use strict; use warnings;
my ($dir, $source, $manifest) = @ARGV;
opendir my $dh, $dir or die;
my @names = sort grep { /\.bit\z/ && -f "$dir/$_" } readdir $dh;
closedir $dh or die;
exit 1 unless @names && @names <= 1024;
open my $out, '>:raw', $source or die;
open my $raw, '>:raw', $manifest or die;
for my $name (@names) {
  open my $f, '<:raw', "$dir/$name" or die;
  local $/; my $text = <$f>; close $f or die;
  print {$raw} pack('N', length($name)), $name, pack('N', length($text)), $text or die;
  $text =~ s/^\xef\xbb\xbf//;
  print {$out} $text, "\n" or die;
}
close $out or die; close $raw or die;
PERL
}

variadicDocCapture() {
  local d=$1 module=$2 binary side=0 rc form
  for binary in "$ORACLE" "$BIT2"; do
    for form in plain json; do
      local args=(doc "$module")
      [ "$form" = json ] && args=(doc --json "$module")
      ALARMRUN_KEEP_STDERR=1 alarmrun "$binary" "${args[@]}" > "$d/$side$form" 2> "$d/err"
      rc=$?
      [ "$rc" -eq 0 ] && [ ! -s "$d/err" ] || return 1
    done
    side=$((side + 1))
  done
  cmp -s "$d/old" "$d/0plain" && cmp -s "$d/new" "$d/1plain" || return 1
  cmp -s "$d/oldjson" "$d/0json" && cmp -s "$d/newjson" "$d/1json"
}

variadicDocWitness() {
  local d=$1 module=$2
  docModuleSource "$module" "$d/module.bit" "$d/manifest" || return 1
  variadicTypeWitness "$d" "$d/module.bit" "$module" || return 1
  variadicDocCapture "$d" "$module" || return 1
  docModuleSource "$module" "$d/after.bit" "$d/after.manifest" || return 1
  cmp -s "$d/manifest" "$d/after.manifest"
}

explainVariadicDocMarker() (
  [ -d "${5:-}" ] && [ -x "${ORACLE:-}" ] && [ -x "${BIT2:-}" ] || return 1
  local d rc name i=0 names=(old new oldjson newjson)
  d=$(mktemp -d "${TMPDIR:-/tmp}/t7936-witness-XXXXXX") || return 1
  trap 'rm -rf "${d:?}"' EXIT
  for name in "$1" "$2" "$3" "$4"; do
    cp "$name" "$d/${names[$i]}" || return 1
    i=$((i + 1))
  done
  variadicDocWitness "$d" "$5" || return 1
  variadicMarkerParse "$d" doc
  rc=$?
  [ "$rc" -eq 0 ] || return 1
  awk 'BEGIN { print "7936-variadic-doc-marker" }'
)

# #7925: whole-project O0 ELF proves owner/ABI evidence absent from root IR.
# The native checker keeps every other root IR byte unchanged.
explainFnvalueOwners() (
  [ -f "${3:-}" ] || return 1
  printf '%s\n' "$1" | grep -q '^func fnvalue\$trampoline\$' || return 1
  printf '%s\n' "$2" | grep -q '@__bitfnv_' || return 1
  [ -x "${ORACLE:-}" ] && [ -x "${BIT2:-}" ] || return 1
  command -v alarmrun >/dev/null || return 1
  local witness_dir rc
  witness_dir=$(mktemp -d "${TMPDIR:-/tmp}/t7925-witness-XXXXXX") || return 1
  trap 'rm -rf "${witness_dir:?}"' EXIT
  printf '%s\n' "$1" > "$witness_dir/old.ir" || return 1
  printf '%s\n' "$2" > "$witness_dir/new.ir" || return 1
  alarmrun "$ORACLE" build "$3" --emit-obj --no-optimize --target x86_64-linux -o "$witness_dir/old.o" > "$witness_dir/old.log" 2>&1
  rc=$?
  [ "$rc" -eq 0 ] || return 1
  alarmrun "$BIT2" build "$3" --emit-obj --no-optimize --target x86_64-linux -o "$witness_dir/new.o" > "$witness_dir/new.log" 2>&1
  rc=$?
  [ "$rc" -eq 0 ] || return 1
  alarmrun "$BIT2" build _tests_/bit/fnvalueir -o "$witness_dir/check" > "$witness_dir/helper.log" 2>&1
  rc=$?
  [ "$rc" -eq 0 ] || return 1
  alarmrun "$witness_dir/check" "$witness_dir/old.ir" "$witness_dir/new.ir" "$witness_dir/old.o" "$witness_dir/new.o" > "$witness_dir/check.log" 2>&1
  rc=$?
  [ "$rc" -eq 0 ] || return 1
  awk 'BEGIN { print "7925-fnvalue-owner-reuse" }'
)

# #8110: contextual in changes only its token kind; offsets witness raw source bytes.
explainContextualIn() (
  [ -f "${3:-}" ] || return 1
  local d rc
  d=$(mktemp -d "${TMPDIR:-/tmp}/t8110-witness-XXXXXX") || return 1
  trap 'rm -rf "${d:?}"' EXIT
  cp "$3" "$d/source" || return 1
  printf '%s' "$1" > "$d/old" || return 1
  printf '%s' "$2" > "$d/new" || return 1
  perl - "$d" <<'PERL'
use strict; use warnings;
sub readall {
  open my $f, '<:raw', $_[0] or die;
  local $/; my $text = <$f>; close $f or die;
  return defined($text) ? $text : '';
}
sub contextualRow {
  my ($old, $new, $source) = @_;
  return 0 unless $old =~ /\Akw_in ([0-9]+)\.\.([0-9]+)\z/;
  my ($start, $end) = ($1, $2);
  return 0 unless $new eq "ident $start..$end";
  return 0 if length($start) > 16 || length($end) > 16;
  return 0 unless $end - $start == 2 && $end <= length($source);
  return substr($source, $start, 2) eq 'in';
}
my $d = shift; my $source = readall("$d/source");
my @old = split /\n/, readall("$d/old"), -1;
my @new = split /\n/, readall("$d/new"), -1;
exit 1 unless @old == @new;
my $changed = 0;
for my $i (0 .. $#old) {
  next if $old[$i] eq $new[$i];
  exit 1 unless contextualRow($old[$i], $new[$i], $source);
  $changed++;
}
exit($changed ? 0 : 1);
PERL
  rc=$?
  [ "$rc" -eq 0 ] || return 1
  cmp -s "$3" "$d/source" || return 1
  awk 'BEGIN { print "8110-contextual-in-token" }'
)

# explainMismatch <oracle_text> <bit2_text> <kind: ir|iropt|ast|fmt|types|diags|tokens> [file]
# Prints the name of the registered signature that explains the divergence
# and returns 0, or prints nothing and returns 1 if none does. 7745-loop-defer-stack is registered
# on the `ir` and `iropt` kinds, 7761-range-chain-cse on `iropt` only, 7766-synth-json-helper-column-shift
# and 7933-variadic-type-marker on `types`, 8110-contextual-in-token on `tokens`.
explainMismatch() {
  case "$3" in
    tokens) explainContextualIn "$1" "$2" "${4:-}"; return ;;
    ir) explainLoopDeferStack "$1" "$2" || explainFnvalueOwners "$1" "$2" "${4:-}"; return ;;
    iropt) explainLoopDeferStack "$1" "$2" || explainRangeChainCse "$1" "$2" || explainFnvalueOwners "$1" "$2" "${4:-}"; return ;;
    types) explainJsonHelperShift "$1" "$2" "${4:-}" || explainVariadicTypeMarker "$1" "$2" "${4:-}"; return ;;
  esac
  return 1
}

# declaredSignatureNames [ir|iropt|ast|fmt|types|diags|tokens|doc] -- every registered
# mismatch identity for the given surface, one per line (#5509, #5510, #7936).
# The single source of truth for the retirement check in
# scripts/selfhost-diffdump.sh's run_ir()/run_types(): a signature this
# function does not list can never be checked for going dead, and one it lists
# that explainMismatch no longer prints would make that check fail on every
# run. Kept in sync by hand, and selfhost-ir-signatures-selfcheck.sh asserts
# the list matches the `print "..."` statements in this file. Declared for
# `ir`, `iropt`, `types`, `tokens` and `doc`.
declaredSignatureNames() {
  case "${1:-}" in
    ir) printf '%s\n' 7745-loop-defer-stack 7925-fnvalue-owner-reuse ;;
    iropt|"") printf '%s\n' 7745-loop-defer-stack 7761-range-chain-cse 7925-fnvalue-owner-reuse ;;
  esac
  case "${1:-}" in
    types|"") printf '%s\n' 7766-synth-json-helper-column-shift 7933-variadic-type-marker ;;
    tokens) printf '%s\n' 8110-contextual-in-token ;;
    doc) printf '%s\n' 7936-variadic-doc-marker ;;
  esac
  [ -n "${1:-}" ] || printf '%s\n' 7936-variadic-doc-marker 8110-contextual-in-token
  return 0
}

# shellcheck source=scripts/selfhost-ir-canon.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/selfhost-ir-canon.sh"
