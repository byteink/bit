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
# --- Retirement history ---
#
# A declared signature goes dead without anyone removing it: the oracle is
# the pinned stage0, release N-1 (docs/release/bootstrap.md), and it moves
# every release, so a transform that landed before release N is back IN the
# oracle by N+1 — the two compilers agree again on every site the signature
# used to explain. The retirement check in scripts/selfhost-diffdump.sh's
# run_ir() (`declaredSignatureNames` below) is what catches the next one
# instead of leaving it to a manual audit.
#
# #3107 (inline slice element READ), #3108 (…STORE), #3898 (pointer-scale/
# shift fold) and #3862 (inline slice elements, packed class) were retired by
# #5509 on the 0.20.0-era tree. #5486-variant-payload-reorder,
# #5429-decimal-boxed-slot-explode, #5506-enum-nil-payload-retype,
# #5445-method-return-explode-direct-call, #5521-void-return-bare-ret and
# #5486-variant-payload-redundant-read-elim were retired by the stage0
# 0.20.0 repin (#5607).
#
# #5870-multiword-return-rebox, #5871-tuple-word-explode (both `ir` and its
# `iropt` branch-fold variant), #5874-fallible-tuple-words,
# #5876-field-store-declared-type-convert, #5895-bce-trivial-param,
# #5905-commaok-miss-zero-drop, #5906-map-str-key-words and
# #5910-chan-typeassert-live-zero were retired by the stage0 0.27.0 repin
# (#5914): every fix each one explained landed on the tree before 0.27.0 was
# cut, so 0.27.0 is the first oracle that agrees with the tree on every site
# they used to explain. Confirmed by `bash scripts/selfhost-diffir.sh` and
# `bash scripts/selfhost-diffiropt.sh` against the 0.27.0 pin (this tree at
# d1c6a09f4, aarch64-macos, the only host this repin was built on):
# MATCH=961 MISMATCH=0 EXPLAINED=0 on both arms, and both scripts' own
# RETIRED lines named exactly these eight — six under `ir`, nine under
# `iropt` (the `iropt`-only branch-fold variant makes it nine, not eight).
# Not independently confirmed on x86_64-linux or aarch64-linux the way
# #5509's four were; the two prior repins to 0.26.0 and 0.26.1 (dist/stage0/
# SHA256SUMS) folded runtime/compiler fixes affecting all three targets
# identically and neither needed a per-arch re-check, and none of these
# eight identities keys on anything target-ISA-shaped (see WHICH HOSTS
# above — `--dump-ir`/`--dump-ir-pre` do not vary by ISA at all). Their
# per-opcode derivations are preserved in git history at this file's state
# before #5914 — a dead identity's math is not load-bearing for anything
# still declared. The `catchDisambigAst`/`catchDisambigFmt` machinery below
# (#5474, #5510) is unaffected: nothing in 0.27.0 touches `catch`
# composite-default disambiguation, so it still explains its own two corpus
# files under `ast`/`fmt`.
#
# explainMismatch <oracle_text> <bit2_text> <kind: ir|iropt|ast|fmt|types>
# Prints the name of the registered signature that explains the divergence
# and returns 0, or prints nothing and returns 1 if none does. Each call
# forks one fresh awk process, so all state below is per-call — no cross-file
# leakage between corpus files. `ast`/`fmt` compare TEXT (an S-expression
# dump / formatted source), not IR opcodes; `types` compares `--dump-types`
# TEXT line-for-line (ptrofStringType, #5921). No signature is currently
# declared for `ir`/`iropt` (see Retirement history above) — a future
# lowering change that needs one restores the opcode-COUNT-delta machinery
# this file carried before #5914, from git history.
explainMismatch() {
  awk -v kind="$3" '
    # catchDisambigAst (#5510) -- works on the RAW joined text, string-search
    # only (no regex over rawA/rawB: parens are not metacharacters here).
    # #5474 made `catch IDENT{ singleField = v }` parse as a composite
    # default instead of a catch-bind block, so the pinned (pre-fix) oracle
    # still dumps the old `catch_bind` shape and this tree dumps
    # `catch_default` for the exact same source. NARROW ON PURPOSE, stated
    # plainly: this accepts ANY value for the single field (not just the
    # literal `1` the fixture uses), so it cannot tell a composite default
    # the fix built CORRECTLY from one that got the wrong value in the same
    # shape -- the fixtures own `.expected` file is what catches that, not
    # this signature. A value containing a paren is rejected outright.
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
    # ptrofStringType (#5921) -- the `types` row never called explainMismatch
    # at all until now (selfhost-diffdump.sh only checked `ast`, #5510). The
    # 0.27.0 pinned oracle still types `ptrOf(s: string)` as `*string` (the
    # scalar-cell path); this tree made it `*u8` (runtime/ABI.md section 2.3,
    # the `ptr` word). `--dump-types` output is `LINE:COL: <expr>: <type>` per
    # line, one line per typed node, same LINE COUNT on both sides (it never
    # reflows the way `fmt` does) -- so this compares line-for-line, not a raw
    # substring search the way catchDisambigAst does. A line is accepted only
    # when its prefix (everything before the LAST ": ") is byte-identical on
    # both sides and its trailing type is exactly `*string`->`*u8` or
    # `string`->`u8`; ANY other kind of difference on ANY line -- a changed
    # prefix, a different type pair, an extra or missing line -- rejects the
    # whole file, matching catchDisambigFmt: the whole delta must satisfy the
    # identity. At least one accepted line prefix must literally contain a
    # `ptrOf(` call (the col-13 line above): the other two lines (the `p`
    # binding, the `got` dereferenced type) are what is TYPED FROM that call,
    # never accepted alone with no `ptrOf(` line present.
    function lastColonSpace(s,    i, n, found) {
      found = 0
      n = length(s) - 1
      for (i = 1; i <= n; i++) {
        if (substr(s, i, 2) == ": ") { found = i }
      }
      return found
    }
    function ptrofStringType(nA, linesA, nB, linesB,    i, la, lb, cutA, cutB, pfxA, pfxB, tyA, tyB, diffCount, sawPtrOf) {
      if (nA != nB || nA == 0) { return 0 }
      diffCount = 0
      sawPtrOf = 0
      for (i = 1; i <= nA; i++) {
        la = linesA[i]; lb = linesB[i]
        if (la == lb) { continue }
        diffCount++
        cutA = lastColonSpace(la)
        cutB = lastColonSpace(lb)
        if (cutA == 0 || cutB == 0) { return 0 }
        pfxA = substr(la, 1, cutA - 1)
        tyA = substr(la, cutA + 2)
        pfxB = substr(lb, 1, cutB - 1)
        tyB = substr(lb, cutB + 2)
        if (pfxA != pfxB) { return 0 }
        if (!((tyA == "*string" && tyB == "*u8") || (tyA == "string" && tyB == "u8"))) { return 0 }
        if (index(pfxA, "ptrOf(") > 0) { sawPtrOf = 1 }
      }
      if (diffCount == 0 || sawPtrOf == 0) { return 0 }
      return 1
    }
    # catchDisambigFmt (#5510) -- the fmt arm of the same #5474 shape, on
    # formatted SOURCE text instead of an AST dump. The pre-fix oracle formats
    # `catch Circle{ r = 1 }` as a multi-line bind block (`catch Circle {` /
    # `  r = 1` / `}`, each additionally indented by the enclosing scope);
    # this tree, parsing it as a composite default, formats it glued and
    # single-line (`catch Circle{ r = 1 }` -- the formatter canonical
    # field_init separator has been `=` since #3842 step A). Line-array
    # based, not raw-text index(): the multi-line-vs-one-line shape means the
    # surrounding line COUNT changes (3 oracle lines collapse to 1), so what
    # must match is "every line before/after the block is identical, and the
    # block reduces to exactly the reconstructed bit2 line". Same narrowness
    # as catchDisambigAst: any scalar field value, no parens/braces/`&`/
    # backslash in it (the last two only because reconstruction goes through
    # sub()`s replacement text, which treats them specially).
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
      next
    }
    {
      nB++; linesB[nB] = $0
      rawB = (nB == 1 ? $0 : rawB "\n" $0)
    }
    END {
      if (kind == "ast") {
        if (catchDisambigAst(rawA, rawB)) { print "5474-catch-composite-default-ast"; exit 0 }
        exit 1
      }
      if (kind == "fmt") {
        if (catchDisambigFmt(nA, linesA, nB, linesB)) { print "5474-catch-composite-default-fmt"; exit 0 }
        exit 1
      }
      if (kind == "types") {
        if (ptrofStringType(nA, linesA, nB, linesB)) { print "5921-ptrof-string-type"; exit 0 }
        exit 1
      }
      # No `ir`/`iropt` signature is currently declared -- see Retirement
      # history above.
      exit 1
    }
  ' <(printf '%s\n@@@BIT2@@@\n%s\n' "$1" "$2")
}

# declaredSignatureNames [ir|iropt|ast|fmt] -- every name explainMismatch CAN
# print for the given dump kind, one per line, in the same order as the
# `print "…"` statements above (#5509, extended by #5510). The single source
# of truth for the retirement check in scripts/selfhost-diffdump.sh's
# run_ir(): a signature this function does not list for a kind can never be
# checked for going dead under that kind, and one it lists that
# explainMismatch no longer prints would make that check fail on every run
# for a signature that does not exist. Kept in sync by hand -- there is no
# safe way to grep `print "…"` lines back out of the awk script above and
# have that be more trustworthy than typing the same names twice, and
# selfhost-ir-signatures-selfcheck.sh asserts the two lists match (with the
# kind argument omitted there, since that check is "does this name exist at
# all", not "under which kind").
declaredSignatureNames() {
  local kind=${1:-}
  case "$kind" in
    ast) printf '%s\n' "5474-catch-composite-default-ast"; return ;;
    fmt) printf '%s\n' "5474-catch-composite-default-fmt"; return ;;
    types) printf '%s\n' "5921-ptrof-string-type"; return ;;
    ir) return ;;
    iropt) return ;;
  esac
  [ -n "$kind" ] || printf '%s\n' \
    "5474-catch-composite-default-ast" "5474-catch-composite-default-fmt" "5921-ptrof-string-type"
}
