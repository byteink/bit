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
# still declared.
#
# #5921-ptrof-string-type was retired by the stage0 0.28.0 repin (#5957):
# 0.28.0 contains #5921 (`ptrOf(s: string): *u8`), so 0.28.0 is the first
# oracle that agrees with the tree on the `--dump-types` sites it used to
# explain. Confirmed by `bash scripts/selfhost-difftypes.sh` against the
# 0.28.0 pin (this tree at 35599936e, aarch64-macos, the only host this
# repin was built on): MATCH=1412 MISMATCH=0 EXPLAINED=0, and the script's
# own RETIRED line named exactly this one signature. `selfhost-diffir.sh`
# and `selfhost-diffiropt.sh` both report MATCH=963 MISMATCH=0 EXPLAINED=0
# against the same pin — no `ir`/`iropt` signature was declared going in, so
# neither RETIRED anything. Its opcode-free line-diff derivation (the
# ptrofStringType/lastColonSpace functions) is preserved in git history at
# this file's state before #5957.
#
# The `catch`-composite-default `ast`/`fmt` disambiguation pair (#5474,
# #5510) and the generic-class-member leading-comment `fmt` signature were
# both retired by the stage0 0.32.0 repin: 0.32.0's own oracle already
# parses and formats both shapes the way the tree does, so neither explains
# anything anymore. Confirmed by `bash scripts/selfhost-diffast.sh` (MATCH=
# 1410 MISMATCH=0 EXPLAINED=0) and `bash scripts/selfhost-difffmt.sh`
# (MATCH=2036 MISMATCH=0 EXPLAINED=0) against the 0.32.0 pin (this tree,
# aarch64-macos, the only host this repin was built on) -- no divergence
# remains for either kind, so there is nothing left for any signature to
# explain. `ast`/`fmt` had no automated RETIRED audit (unlike `ir`/`iropt`/
# `types`, checked by scripts/selfhost-diffdump.sh's run_ir()/run_types()),
# so this pair was confirmed dead by hand rather than by that mechanism
# failing. Their `catchDisambigAst`/`catchDisambigFmt`/`fmtCodeOnly`/
# `genericMemberCommentFmt` derivations and ticket numbers are preserved in
# git history and in scripts/selfhost-ir-signatures-selfcheck.sh's
# retirement note, at this file's state before that repin.
#
# #6194 (46b6d13eb, "Fix foreignTypeDeclParam to scan every module, not just
# the caller's own") landed AFTER the 0.32.0 pin above, so the pinned oracle
# still carries the pre-fix bug on the one corpus file it touches
# (_tests_/cases/run_generic_method_receiver_explode.bit, added by #6194
# itself to pin the corrected shape): a generic method's `Option<T>` result
# read through its receiver stays unsubstituted in the oracle (`--dump-types`
# reports the bare `Option`; `--dump-ir-pre`/`--dump-ir` keep it boxed, one
# heap object read by `field_get`), while this tree substitutes it to
# `Option<Person>` and explodes the payload to words at every call/return
# site that consumes it. Two signatures declared below:
# `6194-generic-method-receiver-unsubstituted-type` (`types`, the
# `optionUnsubstitutedType` line-for-line identity, same shape as #5921's
# `ptrofStringType`) and `6194-generic-method-receiver-explode` (`ir`/
# `iropt`, an opcode-count-delta identity on `field_get`/`gc_alloc` only,
# same shape as #5871). EXPECTED TO RETIRE AT THE 0.33.0 REPIN: 0.33.0 will
# contain #6194, so it will be the first oracle that agrees with the tree on
# this file, and both signatures will explain zero files that run — the
# automated RETIRED check below (declaredSignatureNames) is what catches
# that, the same way it caught #5921/the eight 0.27.0-era signatures.
#
# explainMismatch <oracle_text> <bit2_text> <kind: ir|iropt|ast|fmt|types>
# Prints the name of the registered signature that explains the divergence
# and returns 0, or prints nothing and returns 1 if none does. Each call
# forks one fresh awk process, so all state below is per-call — no cross-file
# leakage between corpus files. `ast`/`fmt` compare TEXT (an S-expression
# dump / formatted source), not IR opcodes; `types` compares `--dump-types`
# TEXT line-for-line (optionUnsubstitutedType, #6194); `ir`/`iropt` compare
# opcode COUNT deltas (the same #6194 identity, kind-gated). No signature is
# currently declared for `ast`/`fmt` (see Retirement history above).
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
      if (line ~ /^[[:space:]]*index_set /) { return "index_set" }
      return ""
    }
    function lastColonSpace(s,    i, n, found) {
      found = 0
      n = length(s) - 1
      for (i = 1; i <= n; i++) {
        if (substr(s, i, 2) == ": ") { found = i }
      }
      return found
    }
    # optionUnsubstitutedType (#6194) -- same shape as #5921s ptrofStringType:
    # `--dump-types` output is `LINE:COL: <expr>: <type>` per line, one line
    # per typed node, same LINE COUNT on both sides (never reflows). A line is
    # accepted only when its prefix (everything before the LAST ": ") is
    # byte-identical on both sides and the oracles trailing type is exactly
    # the bare `Option` while the trees is `Option<X>` for a single bare
    # identifier X -- ANY other kind of difference on ANY line rejects the
    # whole file. At least one accepted lines prefix must contain the literal
    # `Option<T>.` substring (the unsubstituted generic-method-receiver call
    # syntax #6194 fixed) -- gates this to the exact defect shape, not any
    # `Option`-typed expression that happens to gain a type argument.
    function optionUnsubstitutedType(nA, linesA, nB, linesB,    i, la, lb, cutA, cutB, pfxA, pfxB, tyA, tyB, diffCount, sawCall) {
      if (nA != nB || nA == 0) { return 0 }
      diffCount = 0
      sawCall = 0
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
        if (tyA != "Option") { return 0 }
        if (tyB !~ /^Option<[A-Za-z_][A-Za-z0-9_]*>$/) { return 0 }
        if (index(pfxA, "Option<T>.") > 0) { sawCall = 1 }
      }
      if (diffCount == 0 || sawCall == 0) { return 0 }
      return 1
    }
    side == 0 && $0 == "@@@BIT2@@@" { side = 1; next }
    side == 0 {
      nA++; linesA[nA] = $0
      rawA = (nA == 1 ? $0 : rawA "\n" $0)
      op = opcode($0); if (op != "") a[op]++
      next
    }
    {
      nB++; linesB[nB] = $0
      rawB = (nB == 1 ? $0 : rawB "\n" $0)
      op = opcode($0); if (op != "") b[op]++
    }
    END {
      # `ast`/`fmt` never reach the opcode-delta machinery below -- meaningless
      # for both (no IR opcodes in either text).
      if (kind == "ast") { exit 1 }
      if (kind == "fmt") { exit 1 }
      if (kind == "types") {
        if (optionUnsubstitutedType(nA, linesA, nB, linesB)) {
          print "6194-generic-method-receiver-unsubstituted-type"; exit 0
        }
        exit 1
      }

      for (op in a) allop[op] = 1
      for (op in b) allop[op] = 1
      # `moved` is the set of opcodes that ACTUALLY changed. `delta` cannot
      # serve that purpose on its own: merely READING delta["x"] creates the
      # element in awk, which is why the identity below checks `moved`
      # membership before ever reading `delta`.
      for (op in allop) {
        d = b[op] - a[op]
        if (d != 0) { delta[op] = d; moved[op] = 1 }
      }

      # --- #6194: generic method receiver Option<T> result stays boxed in
      # the oracle, explodes to words in this tree ---
      #
      # PRE-OPT (kind=ir): every consuming site unpacks the oracles single
      # boxed Option with 2 `field_get`s, then REBOXES those 2 words into a
      # fresh same-shape Option (1 `gc_alloc`, its `field_set`s unscored) so
      # the exploded ABI can read it back with 2 more `field_get`s before the
      # call/return -- net +4 `field_get`/+1 `gc_alloc` per isSome-shaped
      # site, +2 `field_get`/+1 `gc_alloc` per unwrap-shaped site (the
      # existing single-field unpack of the Person payload is unchanged on
      # both sides). Measured on the real #6194 fixture (this tree vs the
      # 0.32.0 pin, 2 call sites of each shape across its 2 functions):
      # field_get +12, gc_alloc +4, nothing else moves. Checked as an
      # identity, not the exact fixture counts: only field_get/gc_alloc may
      # move, both strictly positive, and field_get must fall in
      # [2x, 4x] of gc_alloc -- the structural floor (every rebox needs at
      # least 2 field_gets to read back) and ceiling (never more than the
      # isSome-shaped sites 4 measured here) a different, unrelated
      # field_get/gc_alloc-only delta is not expected to satisfy by
      # coincidence.
      if (kind == "ir") {
        ok6194 = 1
        for (op in moved) { if (op != "field_get" && op != "gc_alloc") ok6194 = 0 }
        Nfg6194 = delta["field_get"] + 0
        Nga6194 = delta["gc_alloc"] + 0
        if (Nga6194 <= 0 || Nfg6194 <= 0) ok6194 = 0
        if (Nfg6194 < 2 * Nga6194 || Nfg6194 > 4 * Nga6194) ok6194 = 0
        if (ok6194) { print "6194-generic-method-receiver-explode"; exit 0 }
      }

      # POST-OPT (kind=iropt): opt.bit CSE/DCE forwards the unpacked words
      # directly to their consumers, so every rebox `field_get` pair is dead
      # on arrival and removed along with it -- field_get nets to NO delta
      # (both sides end up reading the payload exactly once), while the
      # rebox `gc_alloc` itself becomes dead code and is dropped, a pure
      # DECREASE. Measured on the same fixture: gc_alloc -2 (2 functions x 1
      # net dead box each, once isSome/unwraps own reboxes both fold away),
      # field_get identical on both sides (no entry in `moved` at all).
      # Checked as an identity: gc_alloc must be the ONLY opcode that moved,
      # strictly negative -- an unrelated field_get delta, or a gc_alloc
      # INCREASE, is never explained here.
      if (kind == "iropt") {
        ok6194o = 1
        for (op in moved) { if (op != "gc_alloc") ok6194o = 0 }
        Nga6194o = delta["gc_alloc"] + 0
        if (Nga6194o >= 0) ok6194o = 0
        if (ok6194o) { print "6194-generic-method-receiver-explode"; exit 0 }
      }

      exit 1
    }
  ' <(printf '%s\n@@@BIT2@@@\n%s\n' "$1" "$2")
}

# declaredSignatureNames [ir|iropt|ast|fmt|types] -- every name explainMismatch
# CAN print for the given dump kind, one per line, in the same order as the
# `print "…"` statements above (#5509, extended by #5510). The single source
# of truth for the retirement check in scripts/selfhost-diffdump.sh's
# run_ir()/run_types(): a signature this function does not list for a kind can
# never be checked for going dead under that kind, and one it lists that
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
    ast) return ;;
    fmt) return ;;
    types) printf '%s\n' "6194-generic-method-receiver-unsubstituted-type"; return ;;
    ir) printf '%s\n' "6194-generic-method-receiver-explode"; return ;;
    iropt) printf '%s\n' "6194-generic-method-receiver-explode"; return ;;
  esac
  [ -n "$kind" ] || printf '%s\n' \
    "6194-generic-method-receiver-unsubstituted-type" \
    "6194-generic-method-receiver-explode"
}
