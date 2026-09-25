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
# intentional lowering improvement had landed since the pin — #3107 is the
# first that did (`xs[i]` on a slice: `rt_call slice_get` -> an inline
# bounds-checked load, compiler/loweraccess.bit), and it reddened every IR
# arm by construction: MATCH 754->608, MISMATCH 0->149 on
# `task-3107-inlineindex` (8d80e0a9) for diffdump's corpus, and 5 of 85
# `runtime/**` files for diffruntime's (#3132). #3103 hit the identical shape
# one level down (object bytes vs. the pinned release) and this is the same
# fix, one level up: a mismatch is no longer automatically a REGRESSION. It
# is checked first against a small table of DECLARED TRANSFORM SIGNATURES
# (`explainMismatch` below) — an exact opcode-COUNT-delta identity, proven
# against the real branch that motivated it, not eyeballed. Only a
# divergence that satisfies a registered signature is downgraded to
# EXPLAINED (printed, not failed); anything else still fails exactly as
# before.
#
# WHY NOT A PER-FILE ALLOWLIST INSTEAD. There was one — the expected-mismatch
# list #1883 deleted, "so a known difference could be written down instead of
# fixed." A signature is not that list reborn: an allowlist names a FILE and
# accepts anything it does next; a signature names an IDENTITY the delta must
# satisfy, checked fresh on every run, and a second, unrelated bug landing on
# an already-explained file still fails it (proven below — the mutation is in
# a file this signature already covers zero times, but the mechanism applies
# per-file regardless of history).
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
# like any other divergence, which is what the mutation test below shows.
#
# #3107 (inline slice element READ), #3108 (…STORE), #3898 (pointer-scale/
# shift fold) and #3862 (inline slice elements, packed class) were declared
# here the same way, and RETIRED by #5509: on the tree at 843d5cd9,
# immediately before #5486 landed, `selfhost-diffir.sh` reported EXPLAINED=2
# and both files were #5429's — zero files of their own for any of the four.
# The oracle is the pinned stage0, release N-1 (docs/release/bootstrap.md),
# so a transform that lands before release N is IN the oracle by N+1: the
# two compilers agree again on every site these four used to explain, and
# each signature stopped explaining anything.
#
# Confirmed on BOTH hosts this repo builds for before deletion (dc2b8625,
# which also carries #5506): `selfhost-diffir.sh` and `selfhost-diffiropt.sh`
# report EXPLAINED=62 on arm64-macos (0 from any of the four, all 62 from the
# three still-live signatures) and EXPLAINED=62 / EXPLAINED=61 on
# x86_64-linux (pre-opt / post-opt) -- 0 from any of the four there either,
# on both arms. The x86_64-linux post-opt run's one point of difference from
# macOS (61 vs 62, MISMATCH=1 on _tests_/cases/decimal_enum_single_payload.bit)
# is UNRELATED to this retirement: none of the four removed identities key on
# any opcode that file's delta touches (decimal/enum payload lowering,
# scored by #5429/#5506, not by slice-access or pointer-scale opcodes), the
# fixture predates this branch (67fc24af), and it already reproduces with
# these four signatures left untouched -- filed separately as #5511 rather
# than folded into this ticket's scope or used to justify keeping a signature
# that explains nothing of its own. It is independent evidence AGAINST this
# file's own "does not vary by target ISA at all" claim for a LIVE signature,
# which is exactly why per-arch confirmation matters here and not only for
# retirement candidates.
#
# The retirement check a few lines below this comment is what catches the
# NEXT one of these instead of leaving it to a manual audit — see
# `declaredSignatureNames` and its caller in selfhost-diffdump.sh. The
# original per-opcode derivation (N/Nn/Nf, the #4370 elem_size correction, the
# post-opt looser-check rule, the #3125 mutation-test result) is preserved in
# git history at this file's state before #5509, not carried here indefinitely
# — a dead identity's math is not load-bearing for anything still declared.
#
# WHICH HOSTS. Both arms apply on EVERY host (aarch64-macos, aarch64-linux,
# x86_64-linux) — unlike #3103's diffruntime object-byte arm, which is
# aarch64-only because it disassembles target MACHINE CODE. `--dump-ir-pre`/
# `--dump-ir` are pre-codegen: the SSA text carries no register or
# instruction-selection content, so it does not vary by target ISA at all.
#
# COST PER LANDING, as this ticket names up front: a future lowering change
# that alters IR shape needs its OWN signature added to `explainMismatch`
# below, derived the same way — diff the real branch against the pinned
# oracle, aggregate every nonzero opcode delta across every diverging file,
# and solve for the coefficients. A signature that only explains the one file
# its author happened to look at is not a signature; it is a scoped allowlist
# wearing a disguise, and #1883 is why that is rejected.
#
# explainMismatch <oracle_text> <bit2_text> <kind: ir|iropt|ast|fmt>
# Prints the name of the registered signature that explains the divergence
# and returns 0, or prints nothing and returns 1 if none does. Each call
# forks one fresh awk process, so all state below is per-call — no cross-file
# leakage between corpus files. `ast`/`fmt` (#5510) compare TEXT (an
# S-expression dump / formatted source), not IR opcodes; `ir`/`iropt` are the
# original opcode-COUNT-delta family this function started as.
explainMismatch() {
  awk -v kind="$3" '
    function opcode(line,    s) {
      if (match(line, /= rt_call [A-Za-z_][A-Za-z0-9_]*\(/)) {
        s = substr(line, RSTART, RLENGTH)
        sub(/^= rt_call /, "", s)
        sub(/\($/, "", s)
        return "rt_call:" s
      }
      if (match(line, /= [a-zA-Z_][a-zA-Z0-9_]*/)) {
        return substr(line, RSTART + 2, RLENGTH - 2)
      }
      if (line ~ /^[[:space:]]*br /) { return "br" }
      if (line ~ /^[[:space:]]*unreachable/) { return "unreachable" }
      # It is the RENDERING that decides what the two matches above can see, not
      # whether the op returns a value: a void `rt_call` still prints as
      # `%5 = rt_call slice_set(%2, %4, %3) void` and scores fine. `index_set`
      # prints as `index_set %32[%34] = %25` — its `=` is followed by a `%`, not
      # by an opcode name — so it scores as NOTHING, the same way `br` and
      # `unreachable` do, which is why those two already have their own lines.
      #
      # No currently-declared signature keys on `index_set` (#3108, the last
      # one that did, was retired by #5509 — see the file header). The line
      # stays: without it `index_set` scores as nothing at all, so a future
      # write-shaped transform delta would be invisible to any signature
      # scanning `moved`/`delta` below, not merely unconstrained by one.
      #
      # `field_set` and the other `dst[i] = v`-shaped ops stay unscored. Nothing
      # declared here moves them, and widening the recognizer further changes
      # the delta set every existing signature is checked against at once.
      if (line ~ /^[[:space:]]*index_set /) { return "index_set" }
      return ""
    }
    # canon5486 erases every `%<id>` token (definition AND use sites alike,
    # same as the ticket-proposed `sed -E "s/%[0-9]+/%/g"`) so a line SHAPE
    # can be compared across two dumps whose value numbering shifted because
    # instructions were reordered, not because anything structural changed.
    # $t<id> type-id tokens are NOT touched here -- explainMismatch only ever
    # runs on text the caller already ran through canon_ir_ids (selfhost-ir-
    # canon.sh) and found STILL mismatching, so any residual difference is
    # not a $t-interning-order artifact by construction.
    function canon5486(line,    c) {
      c = line
      gsub(/%[0-9]+/, "%", c)
      return c
    }
    # catchDisambigAst (#5510) -- the `ast` kind never enters the opcode/delta
    # machinery above (there is no opcode text to score in an S-expression
    # dump), so it works on the RAW joined text instead, string-search only
    # (no regex over rawA/rawB: parens are not metacharacters here). #5474
    # made `catch IDENT{ singleField = v }` parse as a composite default
    # instead of a catch-bind block, so the pinned (pre-fix) oracle still
    # dumps the old `catch_bind` shape and this tree dumps `catch_default` for
    # the exact same source. NARROW ON PURPOSE, stated plainly: this accepts
    # ANY value for the single field (not just the literal `1` the fixture
    # uses), so it cannot tell a composite default the fix built CORRECTLY
    # from one that got the wrong value in the same shape -- the fixtures own
    # `.expected` file is what catches that, not this signature. A value
    # containing a paren is rejected outright (not this shape -- the whole
    # point is a single scalar field_init, and #3862/#5429 already cover
    # deeper structural deltas elsewhere in this file).
    function catchDisambigAst(rawA, rawB,    ia, afterOpen, sep1, fn, afterFn, sep2, ty, afterTy, sep3, fld, afterFld, sep4, val, blockA, blockB, ib, plainA, plainB) {
      ia = index(rawA, "(catch_bind (call ")
      if (ia == 0) { return 0 }
      afterOpen = substr(rawA, ia + length("(catch_bind (call "))
      sep1 = index(afterOpen, " _ (args)) ")
      if (sep1 == 0) { return 0 }
      fn = substr(afterOpen, 1, sep1 - 1)
      afterFn = substr(afterOpen, sep1 + length(" _ (args)) "))
      sep2 = index(afterFn, " (block (assign = (lhs_list ")
      if (sep2 == 0) { return 0 }
      ty = substr(afterFn, 1, sep2 - 1)
      afterTy = substr(afterFn, sep2 + length(" (block (assign = (lhs_list "))
      sep3 = index(afterTy, ") (expr_list ")
      if (sep3 == 0) { return 0 }
      fld = substr(afterTy, 1, sep3 - 1)
      afterFld = substr(afterTy, sep3 + length(") (expr_list "))
      sep4 = index(afterFld, "))))")
      if (sep4 == 0) { return 0 }
      val = substr(afterFld, 1, sep4 - 1)
      if (fn == "" || ty == "" || fld == "" || val == "" || val ~ /[()]/) { return 0 }

      blockA = "(catch_bind (call " fn " _ (args)) " ty " (block (assign = (lhs_list " fld ") (expr_list " val "))))"
      blockB = "(catch_default (call " fn " _ (args)) (composite_lit " ty " (field_inits (field_init " fld " " val "))))"
      if (index(rawA, blockA) != ia) { return 0 }
      ib = index(rawB, blockB)
      if (ib == 0) { return 0 }

      plainA = substr(rawA, 1, ia - 1) "@@SLOT@@" substr(rawA, ia + length(blockA))
      plainB = substr(rawB, 1, ib - 1) "@@SLOT@@" substr(rawB, ib + length(blockB))
      return (plainA == plainB)
    }
    # catchDisambigFmt (#5510) -- the fmt arm of the same #5474 shape, on
    # formatted SOURCE text instead of an AST dump. The pre-fix oracle formats
    # `catch Circle{ r = 1 }` as a multi-line bind block (`catch Circle {` /
    # `  r = 1` / `}`, each additionally indented by the enclosing scope);
    # this tree, parsing it as a composite default, formats it glued and
    # single-line (`catch Circle{ r = 1 }` -- the formatter canonical
    # field_init separator has been `=` since #3842 step A, and #3842 step F
    # retired `:` from the parser entirely). Line-
    # array based, not raw-text index(): the multi-line-vs-one-line shape
    # means the surrounding line COUNT changes (3 oracle lines collapse to 1),
    # so what must match is "every line before/after the block is identical,
    # and the block reduces to exactly the reconstructed bit2 line" -- a
    # single index() on joined text cannot express the line-count collapse.
    # Same narrowness as catchDisambigAst: any scalar field value, no parens/
    # braces/`&`/backslash in it (the last two only because reconstruction
    # goes through sub()`s replacement text, which treats them specially).
    function catchDisambigFmt(nA, linesA, nB, linesB,    k, sep, indent, rest, ty, innerPrefix, assignPart, esep, fld, val, wantB, i, ok) {
      for (k = 1; k <= nA; k++) {
        sep = index(linesA[k], " catch ")
        if (sep == 0) { continue }
        if (substr(linesA[k], length(linesA[k]) - 1) != " {") { continue }
        match(linesA[k], /^ */)
        indent = substr(linesA[k], RSTART, RLENGTH)
        rest = substr(linesA[k], sep + length(" catch "))
        ty = substr(rest, 1, length(rest) - 2)
        if (ty !~ /^[A-Za-z_][A-Za-z0-9_]*$/) { continue }
        if (k + 2 > nA) { continue }
        innerPrefix = indent "  "
        if (substr(linesA[k + 1], 1, length(innerPrefix)) != innerPrefix) { continue }
        assignPart = substr(linesA[k + 1], length(innerPrefix) + 1)
        esep = index(assignPart, " = ")
        if (esep == 0) { continue }
        fld = substr(assignPart, 1, esep - 1)
        if (fld !~ /^[A-Za-z_][A-Za-z0-9_]*$/) { continue }
        val = substr(assignPart, esep + length(" = "))
        if (val == "" || val ~ /[(){}&\\]/) { continue }
        if (linesA[k + 2] != indent "}") { continue }

        wantB = linesA[k]
        sub(/ catch .*$/, " catch " ty "{ " fld " = " val " }", wantB)

        if (nA - 2 != nB) { continue }
        if (k > nB) { continue }
        if (linesB[k] != wantB) { continue }
        ok = 1
        for (i = 1; i < k; i++) { if (linesA[i] != linesB[i]) { ok = 0; break } }
        if (ok) {
          for (i = k + 3; i <= nA; i++) {
            if (linesA[i] != linesB[i - 2]) { ok = 0; break }
          }
        }
        if (ok) { return 1 }
      }
      return 0
    }
    # scanOracleWideIntRets (#5883) -- scans the ORACLE side function
    # headers (side A, `linesA`) for a tuple return type wider than the
    # #5870 5-int-word budget but no wider than the pre-#5870 8-word one
    # (`func NAME(params) (T1, T2, ..., TN) {`, N in 6..8, every T an int-
    # classed register type -- not `f32`/`f64`, the only two AAPCS FLOAT-
    # class types this IR ever prints). Outside that N range neither
    # compiler `retWordsFitRegisters` (compiler/lowerexplode.bit) boxes
    # (N<=5) or both already did before #5870 (N>8, `nine(n): (int x9)` in
    # `_tests_/cases/run_multiword_return.bit` is exactly this case and
    # contributes NOTHING -- confirmed by including it below and getting
    # the wrong S5870/R5870 before this bound was added). Sets S5870 (how
    # many such functions) and R5870 (their word counts summed) -- both are
    # ORACLE-side facts, independent of what bit2 actually did, which is
    # exactly what makes the #5870 identity below an INDEPENDENT check
    # rather than a fit to the bit2 delta itself.
    function scanOracleWideIntRets(   i, line, pos, stripped, rettype, parts, np, j, allInt) {
      S5870 = 0; R5870 = 0
      for (i = 1; i <= nA; i++) {
        line = linesA[i]
        if (substr(line, 1, 5) != "func ") continue
        if (substr(line, length(line) - 1) != " {") continue
        stripped = substr(line, 1, length(line) - 2)
        if (substr(stripped, length(stripped)) != ")") continue
        pos = index(stripped, ") (")
        if (pos == 0) continue
        rettype = substr(stripped, pos + 3, length(stripped) - pos - 3)
        if (rettype == "" || rettype ~ /[()]/) continue
        np = split(rettype, parts, ", ")
        if (np <= 5 || np > 8) continue
        allInt = 1
        for (j = 1; j <= np; j++) { if (parts[j] == "f32" || parts[j] == "f64") allInt = 0 }
        if (allInt) { S5870++; R5870 += np }
      }
    }
    # fallibleWordsOk (#5874, pulled out into its own function by #5883 so
    # the composed #5870+#5874 check below can run the identical rule
    # against a RESIDUAL delta table, not just the raw one) -- see the
    # #5874 block below for the derivation; behaviour is unchanged, this is
    # a pure extraction.
    function fallibleWordsOk(D, Mv, knd,    op, zm) {
      for (op in Mv) { if (!(op in fwok)) return 0 }
      zm = (("const_int" in Mv) || ("const_bool" in Mv) || ("const_float" in Mv) || ("const_nil" in Mv))
      if (!zm) return 0
      if (D["call_word"] < 0) return 0
      if (knd == "ir") {
        if (D["field_get"] < 0 || D["gc_alloc"] < 0) return 0
        if (D["const_int"] < 0 || D["const_bool"] < 0 || D["const_float"] < 0) return 0
        if (D["const_int"] + D["const_bool"] + D["const_float"] + D["const_nil"] <= 0) return 0
      } else {
        if (D["field_get"] > 0 || D["gc_alloc"] > 0) return 0
        if (D["call_word"] - D["field_get"] - D["gc_alloc"] <= 0) return 0
      }
      return 1
    }
    # scanOracleMapStrKeys (#5906) -- counts, from the ORACLE text alone, the
    # `map_get`/`map_slot` reads whose key is a `string` box the function
    # built: MSg/MSs sites in all, MSq of them keyed through the join param
    # of a #4628 reuse diamond (`bbN(%k: string):`, entered by a `jump`
    # carrying such a box) rather than by the box itself. Per function, since
    # value ids restart at every `func`.
    function scanOracleMapStrKeys(   i, lo) {
      MSg = 0; MSs = 0; MSq = 0; lo = 1
      for (i = 1; i <= nA + 1; i++) {
        if (i <= nA && substr(linesA[i], 1, 5) != "func ") continue
        mapStrFn(lo, i)
        lo = i
      }
    }
    function mapStrFn(lo, hi,    i, s, t, p, box, dj, par) {
      for (i = lo; i < hi; i++) {
        s = linesA[i]
        if (s !~ /^ *%[0-9]+ = gc_alloc .* string$/) continue
        t = s; sub(/^ */, "", t); sub(/ .*/, "", t); box[t] = 1
      }
      for (i = lo; i < hi; i++) {
        s = linesA[i]
        if (s ~ /^ *jump bb[0-9]+\(%[0-9]+\)$/) {
          t = s; sub(/^ *jump /, "", t); split(t, p, "("); sub(/\)$/, "", p[2])
          if (p[2] in box) dj[p[1]] = 1
        }
        if (s ~ /^bb[0-9]+\(%[0-9]+: string\):$/) { split(s, p, "("); sub(/:.*/, "", p[2]); par[p[2]] = p[1] }
      }
      for (i = lo; i < hi; i++) {
        if (!match(linesA[i], /= rt_call map_(get|slot)\(%[0-9]+, %[0-9]+\)/)) continue
        s = substr(linesA[i], RSTART, RLENGTH); t = s; sub(/.*, /, "", t); sub(/\)$/, "", t)
        if (!(t in box) && !((t in par) && (par[t] in dj))) continue
        if (s ~ /map_get/) { MSg++ } else { MSs++ }
        if (!(t in box)) MSq++
      }
    }
    side == 0 && $0 == "@@@BIT2@@@" { side = 1; next }
    side == 0 {
      nA++; linesA[nA] = $0
      rawA = (nA == 1 ? $0 : rawA "\n" $0)
      cntA5486[canon5486($0)]++; op = opcode($0); if (op != "") a[op]++; next
    }
    {
      nB++; linesB[nB] = $0
      rawB = (nB == 1 ? $0 : rawB "\n" $0)
      cntB5486[canon5486($0)]++; op = opcode($0); if (op != "") b[op]++
    }
    END {
      # `ast`/`fmt` never reach the opcode-delta machinery below -- it is
      # meaningless for both (no IR opcodes in either text) and could only
      # ever accidentally fire on unrelated text, never intentionally guard
      # it. Checked and returned first, unconditionally.
      if (kind == "ast") {
        if (catchDisambigAst(rawA, rawB)) { print "5474-catch-composite-default-ast"; exit 0 }
        exit 1
      }
      if (kind == "fmt") {
        if (catchDisambigFmt(nA, linesA, nB, linesB)) { print "5474-catch-composite-default-fmt"; exit 0 }
        exit 1
      }
      scanOracleWideIntRets()
      for (op in a) allop[op] = 1
      for (op in b) allop[op] = 1
      # `moved` is the set of opcodes that ACTUALLY changed, recorded here and
      # never written again. `delta` cannot serve that purpose: in awk, merely
      # READING `delta["field_get"]` creates the element, so by the time a
      # later signature below runs, `delta` also contains every opcode an
      # earlier one asked about. Iterating it would then see keys that never
      # moved.
      for (op in allop) {
        d = b[op] - a[op]
        if (d != 0) { delta[op] = d; moved[op] = 1 }
      }

      # --- #5895, POST-OPT ONLY: a bounds check the loop test already proved ---
      #
      # `bceParamSource` (compiler/optbce.bit) now resolves a loop param the
      # back edge passes back to itself, so `proveInductionBounds` drops the
      # bounds check on a hoisted `let n = len(w)` loop and on an outer index
      # carried through an inner loop. Each dropped check is one `icmp_ult`,
      # its `br` (now a `jump`, which scores as nothing), and the panic block:
      # `const_string`, `rt_call panic`, `unreachable`. Reddened 13 files
      # against the pinned stage0 (this tree vs 4c99e3d24, `iropt` only;
      # pre-opt is untouched): all five opcodes fall by the same N >= 1 and
      # nothing else moves, except stdlib/smtp/header.bit, which also carries
      # the #5871 post-opt delta. So the five are subtracted first and the
      # residual, if any, goes on to the signatures below.
      if (kind == "iropt") {
        nBce = -delta["icmp_ult"]
        okBce = (nBce > 0)
        split("br const_string unreachable rt_call:panic", bceOps, " ")
        for (bi in bceOps) { if (delta[bceOps[bi]] != -nBce) okBce = 0 }
        if (okBce) {
          bceOps[0] = "icmp_ult"
          for (bi in bceOps) { delete delta[bceOps[bi]]; delete moved[bceOps[bi]] }
          bceRest = 0
          for (op in moved) bceRest = 1
          if (!bceRest) { print "5895-bce-trivial-param"; exit 0 }
        }
      }

      # --- #5905, POST-OPT ONLY: the unread zero object of a comma-ok miss ---
      #
      # `nullCommaOkMisses` (compiler/optcommaok.bit) hands a comma-ok map
      # read miss edge the null word instead of the zero object when every
      # read of the value sits behind an ok-true edge, and `deadAllocs` then
      # deletes that `gc_alloc` (its `field_set`s score as nothing). Reaches
      # two corpus files, both its own fixtures (this tree vs 0ddd85504,
      # `iropt` only): `gc_alloc` falls by N >= 1 and nothing else moves.
      # Every such miss belongs to a comma-ok read, so the file must still
      # hold at least N `map_val_at` calls.
      if (kind == "iropt" && ("gc_alloc" in moved) && delta["gc_alloc"] < 0) {
        okMiss = (b["rt_call:map_val_at"] >= -delta["gc_alloc"])
        for (op in moved) { if (op != "gc_alloc") okMiss = 0 }
        if (okMiss) { print "5905-commaok-miss-zero-drop"; exit 0 }
      }

      # #3107 (inline slice element READ), #3108 (its STORE half), #3898
      # (pointer-scale/shift fold) and #3862 (inline slice elements, packed
      # class) were declared here and RETIRED by #5509 -- see the header
      # comment at the top of this file for the zero-file measurement and why
      # a signature can go dead without anyone removing it (the oracle is the
      # pinned stage0, release N-1, and it moves every release). Their
      # per-opcode-delta derivations are in git history at the state of this
      # file before #5509.

      # --- #5871: sub-word tuple explosion (word-sized `ret`/`call_word`
      # instead of `gc_alloc`+`field_set`/`field_get`) ---
      #
      # `tupleWordTypes` (compiler/lowerexplode.bit) explodes a tuple whose
      # members all sit at byte offset 8k under the class layout rule into
      # separate WORDS -- a multi-word `ret`/`call` result read back with
      # `call_word`, instead of boxing the tuple on the heap and reading its
      # fields with `field_get`. Reddened the `--dump-ir-pre`/`--dump-ir` of 10 files
      # against the pinned (pre-#5871) stage0: every one of them only ever
      # gains `call_word` and loses `gc_alloc`+`field_get` traffic; nothing
      # else moves. Derived from real dumps of all 10 (this tree at cd7e781c2,
      # oracle stage0.sh, both `ir`/`iropt`):
      #
      #   file                                    call_word field_get gc_alloc  (pre-opt delta)
      #   recover_boundary.bit                         +1        0        +1
      #   run_tuple_eq.bit                            +16       +3        +8
      #   run_tuple_literal_expr.bit                   +3       +10        +6
      #   run_tuple_multi_return.bit                   +4        +3        +2
      #   run_tuple_subword.bit                       +29       +58       +72
      #   examples/tuples/tuples.bit                   +4        +6        +2
      #   stdlib/csv/csv.bit                           +1       +10        +1
      #   stdlib/metrics/labelkey.bit                  +1        +8        +1
      #   stdlib/runtime/runtime.bit                    0        +4         0
      #   stdlib/smtp/header.bit                       +3       +18        +2
      #
      # Pre-opt still builds the box explicitly (word-explode a call/ret, then
      # re-box it for anything reading a field off it (opt.bit has not run
      # yet), so all three counts only ever go UP: a fresh `call_word` read,
      # plus the round-trip own `gc_alloc` and its `field_get`s. Post-opt
      # forwards the box away instead (the freshly-built box is dead on
      # arrival once nothing but field reads observes it), so `field_get` and
      # `gc_alloc` only ever go DOWN; `call_word` still only goes up (same 9
      # of 10 files, `call_word` deltas identical to the pre-opt table above
      # except recover_boundary/csv/labelkey/header, still all >=0) or is
      # untouched. The `run_tuple_subword.bit` post-opt delta additionally
      # includes a branch-fold cascade (below) and is NOT explained here.
      okTupleExplode = 1
      for (op in moved) {
        if (op != "call_word" && op != "field_get" && op != "gc_alloc") okTupleExplode = 0
      }
      if (kind == "ir") {
        if (delta["call_word"] < 0 || delta["field_get"] < 0 || delta["gc_alloc"] < 0) okTupleExplode = 0
        if (delta["call_word"] + delta["field_get"] + delta["gc_alloc"] <= 0) okTupleExplode = 0
      } else {
        if (delta["call_word"] < 0 || delta["field_get"] > 0 || delta["gc_alloc"] > 0) okTupleExplode = 0
        if (delta["call_word"] - delta["field_get"] - delta["gc_alloc"] <= 0) okTupleExplode = 0
      }
      if (okTupleExplode) {
        print "5871-tuple-word-explode"
        exit 0
      }

      # --- #5871, POST-OPT ONLY: branch fold enabled by the box going away
      # ---
      #
      # `run_tuple_subword.bit` `main()` calls its `bi*`/`ib*`/`bs*` helpers
      # with LITERAL `true`/`false` arguments. Once the tuple bool member is
      # a plain SSA value instead of a `field_get` off a freshly-built box,
      # inlining plus constant folding sees straight through it and turns
      # `br %cond, bbT(), bbF()` into an unconditional `jump`, deleting
      # whichever arm the literal proves dead -- the #3862/#3107-style
      # "small pre-opt change, large post-opt echo" shape (a real fold
      # cascade, not a miscompile): the pre-opt delta for this exact file is
      # the clean 3-opcode table above (call_word +29, field_get +58, gc_alloc
      # +72, nothing else), so the cascade is entirely opt.bit own doing,
      # confirming it is downstream of the fold and not a second, independent
      # change.
      #
      # Measured (this tree at cd7e781c2 vs the pinned stage0, `--dump-ir`):
      #   add -4  br -14  call -2  call_word -4  const_int -8  const_nil -2
      #   const_string +2  field_get -42  gc_alloc -10  icmp_eq -4  icmp_ne -2
      #   mul -8  rt_call:string_concat +2  sub -4
      # (`call_word` goes negative here only because the oracle already emits
      # `call_word` for `string` own pre-existing two-word ABI, unrelated to
      # #5871 -- string-returning arms folding away removes some of THOSE too.)
      #
      # Anchored on two things a same-shape but unrelated bug cannot satisfy
      # by accident: (1) `gc_alloc`/`field_get` strictly fall and `br` strictly
      # falls -- a real fold, not zero movement; (2) `add`/`sub` move by the
      # IDENTICAL amount. Every dead arm here is one half of a `p.1 + k` /
      # `p.1 - k` pair (`biDirect`/`ibDirect`/`biLoop`/`ibLoop` two literal
      # calls each discard the opposite arm of the pair once), so `add` and
      # `sub` move in lockstep by construction. #3125 canonical mutation
      # (`Op.Sub` -> `Op.Add` in `compiler/lower.bit` binOpFor) breaks that
      # lockstep on any single flipped site and is rejected (mutation-tested
      # below and in the self-check). The remaining opcodes
      # (call/call_word/const_int/const_nil/const_string/icmp_eq/icmp_ne/mul/
      # rt_call:string_concat) are left at unconstrained magnitude, the same
      # allowance the #3107/#3862 post-opt arms make for DCE-shaped
      # opcodes retired by #5509 -- a dead arm can contain anything the
      # source wrote, and its exact size is not this signature business;
      # the closed opcode SET plus the two anchors above is.
      okFold = (kind != "ir")
      split("call_word field_get gc_alloc br add sub mul icmp_eq icmp_ne const_int const_nil const_string call rt_call:string_concat", foldlist, " ")
      for (i in foldlist) foldok[foldlist[i]] = 1
      for (op in moved) { if (!(op in foldok)) okFold = 0 }
      if (delta["gc_alloc"] >= 0) okFold = 0
      if (delta["field_get"] >= 0) okFold = 0
      if (delta["br"] >= 0) okFold = 0
      if (delta["add"] != delta["sub"]) okFold = 0
      if (okFold) {
        print "5871-tuple-word-explode-branch-fold"
        exit 0
      }

      # --- #5876: a field store converted to its own declared type ---
      #
      # `fieldStoreValue` (compiler/lowertuple.bit, called from
      # lowerclasslit.bit too) converts a value narrower than the field it is
      # stored into, and `fieldSetRhsTarget` (compiler/optfold.bit) stops the
      # widening-alias fold (`convertAliasesSource`, optfoldconvert.bit) from
      # retyping that stored value back to its narrow producer -- see the
      # repro in `_tests_/cases/run_tuple_narrow_boxed_convert.bit`.
      # Reddened 8 files against the pinned (pre-#5876) stage0, `iropt` only
      # (a plain runtime-derived producer keeps its `convert`, unmoved, at
      # `ir`; `untyped_const_expr_narrow.bit` stores a compile-time constant,
      # so that convert folds straight to a materialized `const_int` once
      # optimization runs -- verified against its own real dump, not
      # assumed): `convert` and/or `const_int` only ever RISE (never both
      # zero) and `field_get` only ever FALLS or holds -- one site
      # (`convert_widen_alias.bit`, `r.wide2 = int(hs[1])`) now has its own
      # pre-existing type-mismatched store forwarded for the first time,
      # dropping a `field_get` the oracle could never eliminate. Nothing
      # else in the opcode set moves in any of the 8. A wrong extension
      # direction (u8 sign-extended, i32 zero-extended) changes a VALUE, not
      # an opcode count, so it cannot satisfy this signature by accident --
      # the `.expected` file for `run_tuple_narrow_boxed_convert.bit` is what
      # catches that.
      okFieldStoreConvert = 1
      for (op in moved) {
        if (op != "convert" && op != "const_int" && op != "field_get") okFieldStoreConvert = 0
      }
      if (delta["convert"] < 0) okFieldStoreConvert = 0
      if (delta["const_int"] < 0) okFieldStoreConvert = 0
      if (delta["field_get"] > 0) okFieldStoreConvert = 0
      if (delta["convert"] + delta["const_int"] <= 0) okFieldStoreConvert = 0
      if (okFieldStoreConvert) {
        print "5876-field-store-declared-type-convert"
        exit 0
      }

      # --- #5874: a fallible tuple `(A, B)!` returns its ok value in words ---
      #
      # `declPlainResultType` (compiler/lowerexplode.bit) admits a Fallible
      # result whose ok type is a word tuple, so its call sites gain the
      # `call_word` run and a rebuilt box, the `?`/`catch` joins read the words
      # before `err_get` and rebuild the box past it (`field_get` + `gc_alloc`,
      # compiler/lowerfail.bit), and each err-path `ret` returns one zero
      # constant per WORD (`fallibleZeroArgs`) where it returned one
      # `const_nil`. Changes the IR of six files against the pinned
      # (pre-#5874) stage0: four newly red (one is this ticket case),
      # stdlib/csv/csv.bit, which gained a `const_int` and so left
      # `5871-tuple-word-explode`, and run_multiword_return.bit, already red
      # (below). Derived from real dumps of all six (this tree at 7597162c1,
      # oracle stage0.sh):
      #
      #   file                        pre-opt delta
      #   run_fallible_zero_ret.bit   gc_alloc +22 call_word +24 field_get +69 const_int +5 const_bool +5
      #   run_tuple_fallible_words    gc_alloc +23 call_word +15 field_get +55 const_int +2 const_bool +2 const_float +2
      #   wsclientmask.bit            gc_alloc +2  call_word +2  field_get +6  const_int +5 const_bool +5
      #   wsframing.bit               gc_alloc +26 call_word +20 field_get +38 const_int +6 const_bool +4
      #   stdlib/csv/csv.bit          gc_alloc +3  call_word +2  field_get +16 const_int +1
      #   run_multiword_return.bit    (the #5874 part) gc_alloc +2 call_word +1 field_get +4
      #                               const_int +2 const_nil -1; see below for the rest
      #
      # The anchor is the err path, which only #5874 touches: a site that
      # returned one `const_nil` now returns W >= 2 zero constants, so pre-opt
      # the four constant opcodes rise by (W - 1) per site, strictly, and only
      # `const_nil` may fall (a tuple with no reference word). The box traffic
      # moves with the #5871 signs -- pre-opt only up, post-opt `field_get` and
      # `gc_alloc` only down -- because it is the same mechanism reached
      # through `?`/`catch`. Post-opt, CSE merges zero constants into ones the
      # function already had (`ret %1, %7` in `two` reuses its `const_int 0`),
      # so their magnitude is unconstrained there; at least one must move, or
      # the delta has the #5871 shape and that signature, checked first, owns it.
      #
      # run_multiword_return.bit is NOT explained by this ALONE: its `eight`
      # returns 8 int words, which the stage0 oracle passed in registers and
      # the #5870 5-word budget (d93a3d1e7) boxes again (call_word -7), a
      # mismatch main already carried before #5874 with no signature of its
      # own -- see `5870-multiword-return-rebox` below, which subtracts
      # exactly that #5870 contribution and hands the residual to this same
      # `fallibleWordsOk` to explain the rest.
      split("call_word field_get gc_alloc const_int const_bool const_float const_nil", fwlist, " ")
      for (i in fwlist) fwok[fwlist[i]] = 1
      if (fallibleWordsOk(delta, moved, kind)) {
        print "5874-fallible-tuple-words"
        exit 0
      }

      # --- #5870: a `ret` over the 5-integer-word budget boxes again (#5883)
      # ---
      #
      # `retWordsFitRegisters` (compiler/lowerexplode.bit, d93a3d1e7) moved
      # from the old aarch64 8-register budget to a target-independent 5-int
      # word one. A function whose tuple return has 6..8 int-classed words
      # (`_tests_/cases/run_multiword_return.bit`, `eight`, the only corpus
      # file this hits) now boxes where the pinned stage0 still returned the
      # words directly: the callee `ret` becomes `gc_alloc`+N `field_set`+
      # `ret %box` instead of N register words, and the caller drops its
      # N-1 `call_word` reads for N `field_get`s off the box.
      #
      # `scanOracleWideIntRets` (top of file) counts these sites from the
      # ORACLE side alone (S5870 functions, R5870 total words) -- an
      # INDEPENDENT fact about the divergence, not fit to the bit2 delta.
      # Two real measurements confirm the exact per-site contribution this
      # implies (this tree at 1c87cd749 vs the pinned stage0, `eight`
      # isolated in its own file to remove any #5874 entanglement, S=1 R=8
      # both times):
      #
      #   pre-opt (ir):    gc_alloc -S      call_word (S-R)   field_get -R
      #   post-opt (iropt): gc_alloc +S      call_word (S-R)   field_get +R
      #
      # For `eight` (S=1, R=8): pre-opt gc_alloc -1, call_word -7,
      # field_get -8; post-opt gc_alloc +1, call_word -7, field_get +8 --
      # the WHOLE divergence when #5874 is not also in play (proven below
      # with `eight` alone, no `checked`). Subtracting this from the actual
      # delta and handing what is left to `fallibleWordsOk` explains the
      # combined file: residual pre-opt is gc_alloc +2, call_word +1,
      # const_nil -1, const_int +2, field_get +4 -- exactly the #5874-alone
      # contribution the block above already derived for this file.
      #
      # Guarded on real #5870-shaped movement actually being present
      # (`call_word` in `moved` and strictly negative, plus `gc_alloc` or
      # `field_get` also moved) before subtracting anything: S5870>0 alone
      # is an ORACLE-side fact that can be true of a file for reasons
      # unrelated to this divergence, and subtracting a nonzero contribution
      # from an UNMOVED opcode would fabricate box traffic no dump ever
      # showed (mutation-tested in the self-check: an unrelated single-
      # opcode delta in a file whose oracle happens to declare an 8-int-word
      # return is correctly left unexplained).
      if (S5870 > 0 && ("call_word" in moved) && delta["call_word"] < 0 && (("gc_alloc" in moved) || ("field_get" in moved))) {
        if (kind == "ir") { c_gc = -S5870; c_fg = -R5870 } else { c_gc = S5870; c_fg = R5870 }
        c_cw = S5870 - R5870
        for (op in delta) resDelta[op] = delta[op]
        resDelta["gc_alloc"] = delta["gc_alloc"] - c_gc
        resDelta["call_word"] = delta["call_word"] - c_cw
        resDelta["field_get"] = delta["field_get"] - c_fg
        for (op in moved) resMoved[op] = 1
        if (resDelta["gc_alloc"] == 0) { delete resMoved["gc_alloc"] } else { resMoved["gc_alloc"] = 1 }
        if (resDelta["call_word"] == 0) { delete resMoved["call_word"] } else { resMoved["call_word"] = 1 }
        if (resDelta["field_get"] == 0) { delete resMoved["field_get"] } else { resMoved["field_get"] = 1 }
        residualEmpty = 1
        for (op in resMoved) residualEmpty = 0
        # residualEmpty: the #5870 identity alone accounts for the whole
        # divergence (no #5874 or anything else stacked on this file).
        if (residualEmpty || fallibleWordsOk(resDelta, resMoved, kind)) {
          print "5870-multiword-return-rebox"
          exit 0
        }
      }

      # --- #5906: a map read keyed by a fresh `string` box passes its words ---
      #
      # `setMapKeyArgs` (compiler/lowermapaccess.bit) sends such a read to
      # `map_get_str`/`map_slot_str` with the box `ptr`/`len` words. Pre-opt each
      # site renames its call and reads the box back: `field_get` +3 per site.
      # Post-opt the box dies (gc_alloc -1 per site), and a site the oracle
      # keyed through a #4628 diamond also loses the diamond: field_get -2,
      # icmp_eq -2, icmp_ne -1, const_nil -1, br -3. Measured exact on all
      # four corpus files it reddens (this tree at 65e6265d4 vs stage0):
      # run_map_str_key_words, run_map_string_key_align, run_map_swar_scan,
      # examples/wordcount. Nothing else may move.
      scanOracleMapStrKeys()
      MSn = MSg + MSs
      msw["rt_call:map_get"] = -MSg; msw["rt_call:map_get_str"] = MSg
      msw["rt_call:map_slot"] = -MSs; msw["rt_call:map_slot_str"] = MSs
      if (kind == "ir") {
        msw["field_get"] = 3 * MSn
      } else {
        msw["gc_alloc"] = -MSn; msw["field_get"] = -2 * MSq; msw["icmp_eq"] = -2 * MSq
        msw["icmp_ne"] = -MSq; msw["const_nil"] = -MSq; msw["br"] = -3 * MSq
        # Composed with #5905 (run_map_commaok_miss_zero): each dropped miss
        # zero object is one more `gc_alloc`, under the #5905 anchor.
        msx = msw["gc_alloc"] - (delta["gc_alloc"] + 0)
        if (msx > 0 && b["rt_call:map_val_at"] >= msx) msw["gc_alloc"] -= msx
      }
      okMapStr = (MSn > 0)
      for (op in moved) { if (!(op in msw)) okMapStr = 0 }
      for (op in msw) { if ((delta[op] + 0) != msw[op]) okMapStr = 0 }
      if (okMapStr) { print "5906-map-str-key-words"; exit 0 }

      exit 1
    }
  ' <(printf '%s\n@@@BIT2@@@\n%s\n' "$1" "$2")
}

# declaredSignatureNames [ir|iropt|ast|fmt] -- every name explainMismatch CAN
# print for the given dump kind, one per line, in the same order as the
# `print "…"` statements above (#5509, extended by #5510). The single source
# of truth for the retirement check in scripts/selfhost-diffdump.sh's
# run_ir() (`ir`/`iropt` only -- #5510 does not wire a retirement check into
# the `ast`/`fmt` arms, so a call with those kinds only matters to the sync
# self-check below): a signature this function does not list for a kind can
# never be checked for going dead under that kind, and one it lists that
# explainMismatch no longer prints would make that check fail on every run
# for a signature that does not exist. Kept in sync by hand — there is no
# safe way to grep `print "…"` lines back out of the awk script above and
# have that be more trustworthy than typing the same names twice, and
# selfhost-ir-signatures-selfcheck.sh asserts the two lists match (with the
# kind argument omitted there, since that check is "does this name exist at
# all", not "under which kind").
#
# 5486-variant-payload-reorder, 5429-decimal-boxed-slot-explode,
# 5506-enum-nil-payload-retype, 5445-method-return-explode-direct-call,
# 5521-void-return-bare-ret and 5486-variant-payload-redundant-read-elim were
# retired by the stage0 0.20.0 repin (#5607) — the pinned oracle now carries
# every fix each one used to explain, so each explained zero corpus files.
# `ir`/`iropt` now declare #5871's two: `5871-tuple-word-explode` fires under
# both kinds (explainMismatch's `kind` branch only changes which SIGN the
# core opcodes must move in, not whether the check runs at all);
# `5871-tuple-word-explode-branch-fold` is gated `kind != "ir"` inside
# explainMismatch, so it can only ever fire under `iropt` and is listed only
# there. `5876-field-store-declared-type-convert` fires under both kinds like
# `5871-tuple-word-explode` (no `kind` branch of its own), and so does
# `5874-fallible-tuple-words` (its `kind` branch picks signs, not whether it
# runs). `5870-multiword-return-rebox` (#5883) fires under both kinds too --
# only on `_tests_/cases/run_multiword_return.bit`, and only COMPOSED with
# `5874-fallible-tuple-words` in the current corpus (that file's `checked`
# also goes through #5874's own words convention), so it is not gated on
# `checked` disappearing, only on `eight`'s divergence from the pinned
# stage0 closing (a repin past #5870, same as any other entry here).
# `5895-bce-trivial-param` is gated `kind == "iropt"` (bounds-check
# elimination is an optimizer pass) and is listed only there, as is
# `5905-commaok-miss-zero-drop` (an optimizer pass too).
# `5906-map-str-key-words` fires under both (`kind` picks the opcode table).
# `ast`
# and `fmt` are
# a different, disjoint kind space entirely -- #5474's two signatures never
# fire under `ir`/`iropt` and vice versa, so they are returned only for their
# own exact kind.
declaredSignatureNames() {
  local kind=${1:-}
  case "$kind" in
    ast) printf '%s\n' "5474-catch-composite-default-ast"; return ;;
    fmt) printf '%s\n' "5474-catch-composite-default-fmt"; return ;;
    ir) printf '%s\n' "5871-tuple-word-explode" "5876-field-store-declared-type-convert" "5874-fallible-tuple-words" "5870-multiword-return-rebox" "5906-map-str-key-words"; return ;;
    iropt) printf '%s\n' "5895-bce-trivial-param" "5905-commaok-miss-zero-drop" "5871-tuple-word-explode" "5871-tuple-word-explode-branch-fold" "5876-field-store-declared-type-convert" "5874-fallible-tuple-words" "5870-multiword-return-rebox" "5906-map-str-key-words"; return ;;
  esac
  [ -n "$kind" ] || printf '%s\n' \
    "5474-catch-composite-default-ast" "5474-catch-composite-default-fmt" \
    "5895-bce-trivial-param" "5905-commaok-miss-zero-drop" \
    "5871-tuple-word-explode" "5871-tuple-word-explode-branch-fold" \
    "5876-field-store-declared-type-convert" "5874-fallible-tuple-words" \
    "5870-multiword-return-rebox" "5906-map-str-key-words"
}

