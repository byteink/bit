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
# there. `ast` and `fmt` are a different, disjoint kind space entirely --
# #5474's two signatures never fire under `ir`/`iropt` and vice versa, so
# they are returned only for their own exact kind.
declaredSignatureNames() {
  local kind=${1:-}
  case "$kind" in
    ast) printf '%s\n' "5474-catch-composite-default-ast"; return ;;
    fmt) printf '%s\n' "5474-catch-composite-default-fmt"; return ;;
    ir) printf '%s\n' "5871-tuple-word-explode"; return ;;
    iropt) printf '%s\n' "5871-tuple-word-explode" "5871-tuple-word-explode-branch-fold"; return ;;
  esac
  [ -n "$kind" ] || printf '%s\n' \
    "5474-catch-composite-default-ast" "5474-catch-composite-default-fmt" \
    "5871-tuple-word-explode" "5871-tuple-word-explode-branch-fold"
}

