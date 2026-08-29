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
# THE #3107 SIGNATURE, derived empirically, not from the ticket's prose: diff
# `stdlib examples _tests_/cases _tests_/imports` between the pinned oracle and
# `task-3107-inlineindex` (8d80e0a9), and aggregate every per-opcode COUNT
# delta over every file that diverges (145 on this tree's corpus count —
# #3107's own report measured 149 against a slightly different corpus the day
# before; the identity itself does not depend on the count). Solved as a
# linear system, not guessed:
#
#   N  = number of `xs[i]` reads this file had inlined
#        (= -delta(rt_call:slice_get); must be > 0)
#   Nn = delta(field_get) - 2N   (the packed/byte-indexed subset of N; 0 for
#                                  a plain element type)
#   Nf = -delta(bitcast)         (a float-index read that no longer needs the
#                                  word round-trip; 0 if none)
#
#   delta(slice_len)=N   delta(icmp_ult)=N   delta(br)=N
#   delta(const_string)=N   delta(rt_call:panic)=N   delta(unreachable)=N
#   delta(add)=N+Nn   delta(shl)=Nn   delta(const_int)=Nn
#   delta(index_get)=N-Nn   Nn>=0   Nf>=0
#   every OTHER opcode: delta==0 (pre-opt only — see POST-OPT below)
#
# 145/145 EXPLAINED, 0 UNEXPLAINED at pre-opt, with every coefficient an
# independent equation — not vacuous. Mutation-tested against a real bug
# (#3125): flipping `compiler/lower.bit`'s `binOpFor`, `Kind.Minus -> Op.Sub`
# to `Op.Add` (a real lowering site, unrelated to slice indexing, so
# `compiler/loweraccess.bit` — #3107's own file — is untouched), reddens both
# arms with a REGRESSION this signature does not explain (recorded on the
# ticket, not reproduced in this comment). #3132 repeats the same class of
# mutation test against `selfhost-diffruntime.sh`'s per-file arm and records
# the RED output there.
#
# POST-OPT (iropt) IS A LOOSER CHECK ON THE SAME 13 OPCODES, not the same
# equations — a deliberate, evidence-based narrowing, not a shortcut. The
# pre-opt formula's exact coefficients fail on 8/145 files under `--dump-ir`
# (post `opt.bit`'s CSE/DCE/inlining): `field_get`/`index_get` counts shift
# when the optimizer dedupes a repeated bounds check or address computation,
# which a per-site multiple of N cannot express. What DOES hold on all 145:
# every opcode with a nonzero delta is still one of the same 13, and on 7 of
# those 145 the optimizer's INLINER additionally moves `call`/`call_value`/
# `sub` by an amount this signature does not model — a downstream consequence
# of the transform changing a function's instruction count and crossing an
# inlining-cost threshold, not a second lowering bug. Those three are allowed
# to move by ANY amount for iropt only; every other opcode outside the
# declared 13 still fails the check on both arms. 145/145 EXPLAINED at
# post-opt with this rule, 0/145 without the three (i.e. the allowance is
# load-bearing, not decorative). selfhost-diffruntime.sh only calls this with
# kind="ir" (it has no post-opt dump arm), so the iropt branch below is
# exercised by selfhost-diffdump.sh alone.
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
# --- #3108 PAID THAT COST, and it did NOT need a second signature ---
#
# #3108 inlines the WRITE (`xs[i] = v`: `rt_call slice_set` -> an inline
# bounds-checked store, the same compiler/loweraccess.bit). It is not an
# independent transform: since #3108 the read and the write share
# `emitInlineSliceElem`, so every inlined access of either kind contributes
# exactly ONE bounds-check prologue and they differ only in the final
# `index_get` vs `index_set`. The identity generalises rather than forking:
#
#   Ng = -delta(rt_call:slice_get)   reads inlined  (>= 0)
#   Ns = -delta(rt_call:slice_set)   stores inlined (>= 0)
#   N  = Ng + Ns                     total accesses (> 0)
#   Nn = delta(field_get) - 2N       narrow-prim READS (>= 0)
#
#   delta(slice_len)=delta(icmp_ult)=delta(br)=N
#   delta(const_string)=delta(rt_call:panic)=delta(unreachable)=N
#   delta(add)=N+Nn   delta(shl)=Nn   delta(const_int)=Nn
#   delta(index_get)=Ng-Nn   delta(index_set)=Ns
#   every OTHER opcode: delta==0 (pre-opt only)
#
# Nn is READ-ONLY on purpose and that is a property of the change, not an
# approximation: #3108 inlines a store only when the element is exactly 8
# bytes, because `rtSliceSet` writes a whole word and a narrow store does not
# (it would leave the other seven bytes, which `rtSliceGet` still returns
# whole). So no store ever takes the shl/const_int arm.
#
# Setting Ns=0 recovers #3107's identity character for character, which is why
# a read-only delta still prints `3107-slice-read-inline` and that self-check
# below passes untouched. Derived the same empirical way — 153 diverging files
# on this tree, 153/153 EXPLAINED at pre-opt, 35 of them carrying a store
# delta, every coefficient an independent equation. Scoring `index_set` at all
# required the recognizer line inside `opcode()`; before it, all 35 of those
# files scored delta(index_set)=0 and the store was invisible.

# explainMismatch <oracle_ir_text> <bit2_ir_text> <kind: ir|iropt>
# Prints the name of the registered signature that explains the divergence
# and returns 0, or prints nothing and returns 1 if none does. Each call
# forks one fresh awk process, so all state below is per-call — no cross-file
# leakage between corpus files.
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
      # #3108 emits one `index_set` per inlined store, so without this line the
      # store half of the identity below cannot be constrained at all: measured
      # on this tree, all 35 store-bearing corpus files reported
      # delta(index_set)=0 while really gaining one per store. The self-check
      # pins it — a store whose `index_set` went missing must NOT be explained.
      #
      # `field_set` and the other `dst[i] = v`-shaped ops stay unscored. Nothing
      # declared here moves them, and widening the recognizer further changes
      # the delta set every existing signature is checked against at once.
      if (line ~ /^[[:space:]]*index_set /) { return "index_set" }
      return ""
    }
    side == 0 && $0 == "@@@BIT2@@@" { side = 1; next }
    side == 0 { op = opcode($0); if (op != "") a[op]++; next }
    { op = opcode($0); if (op != "") b[op]++ }
    END {
      for (op in a) allop[op] = 1
      for (op in b) allop[op] = 1
      # `moved` is the set of opcodes that ACTUALLY changed, recorded here and
      # never written again. `delta` cannot serve that purpose: in awk, merely
      # READING `delta["field_get"]` creates the element, so by the time the
      # second signature below runs, `delta` also contains every opcode the
      # first one asked about. Iterating it would then see keys that never
      # moved. (The #3107 block above is unaffected only because every key it
      # reads is in its own `core` list.)
      for (op in allop) {
        d = b[op] - a[op]
        if (d != 0) { delta[op] = d; moved[op] = 1 }
      }

      # --- #3107 + #3108: inline slice element ACCESS lowering (see the block
      # comment above this function for how these coefficients were derived) ---
      #
      # ONE identity covers both directions because both are the same transform:
      # since #3108 the read and the write share `emitInlineSliceElem`, so each
      # inlined access — read or write — contributes exactly one bounds-check
      # prologue (slice_len, icmp_ult, br, const_string, panic, unreachable, two
      # field_gets and one add) and they differ only in the final index_get vs
      # index_set. So the prologue coefficients key on the TOTAL N = Ng + Ns,
      # and only the last two equations separate the halves. With Ns = 0 this is
      # the #3107 identity unchanged, which is why that name is still printed
      # for a read-only delta and why its self-check below passes verbatim.
      split("slice_get slice_set slice_len icmp_ult br const_string panic unreachable field_get add shl const_int index_get index_set bitcast", corelist, " ")
      for (i in corelist) core[corelist[i]] = 1
      Ng = -delta["rt_call:slice_get"]
      Ns = -delta["rt_call:slice_set"]
      N = Ng + Ns
      ok = (N > 0 && Ng >= 0 && Ns >= 0)

      if (kind == "ir") {
        # Pre-opt: the exact linear identity, every coefficient an
        # independent equation, and no opcode outside the declared 13 may
        # move at all.
        if (delta["slice_len"] != N)      ok = 0
        if (delta["icmp_ult"] != N)       ok = 0
        if (delta["br"] != N)             ok = 0
        if (delta["const_string"] != N)   ok = 0
        if (delta["rt_call:panic"] != N)  ok = 0
        if (delta["unreachable"] != N)    ok = 0
        Nn = delta["field_get"] - 2 * N
        if (Nn < 0)                       ok = 0
        if (delta["add"] != N + Nn)       ok = 0
        if (delta["shl"] != Nn)           ok = 0
        if (delta["const_int"] != Nn)     ok = 0
        # The narrow-prim arm (Nn) is READ-ONLY: #3108 inlines a store only when
        # the element is exactly 8 bytes, because `rtSliceSet` writes a whole
        # word and a narrow store does not. So every inlined store contributes
        # an index_set and the wide reads alone account for index_get.
        if (delta["index_get"] != Ng - Nn) ok = 0
        if (delta["index_set"] != Ns)      ok = 0
        Nf = -delta["bitcast"]
        if (Nf < 0)                       ok = 0
        for (op in delta) {
          opname = op
          sub(/^rt_call:/, "", opname)
          if (!(opname in core)) ok = 0
        }
      } else {
        # Post-opt: opt.bit CSE/DCE can redistribute the SAME 13 opcodes
        # counts (dedupe a repeated bounds check or address computation), so
        # the exact pre-opt coefficients do not survive -- see the block
        # comment above. What must still hold: every opcode with a nonzero
        # delta is one of the declared 13, or one of the inliner call/
        # call_value/sub (unconstrained magnitude, both documented above).
        # Anything else still fails.
        for (op in delta) {
          opname = op
          sub(/^rt_call:/, "", opname)
          if (!(opname in core) && opname != "call" && opname != "call_value" && opname != "sub") ok = 0
        }
      }

      if (ok) {
        if (Ns > 0) { print "3108-slice-store-inline" } else { print "3107-slice-read-inline" }
        exit 0
      }

      # --- #3898: pointer-scale / right-shift cancellation ---
      #
      # `emitScaledOffset` (compiler/loweraccess.bit) rewrites the byte offset
      # of `p +- (e >> k)` on a `*T` of size 2^k from `(e >> k) * 2^k` to the
      # equivalent `e & ~(2^k - 1)`. Nm is the number of sites folded in this
      # file. Derived the same empirical way as the identity above -- diffed
      # against the pinned oracle over every runtime file that diverges
      # (runtime/gc/mem.bit, runtime/sched/task.bit, runtime/spinlock.bit),
      # both dump kinds, every coefficient an independent equation:
      #
      #   pre-opt   delta(mul) = -Nm   delta(band) = +Nm
      #             every OTHER opcode: delta == 0.
      #             The shift and its count constant are still emitted (dead),
      #             and `const_int 2^k` becomes `const_int ~(2^k - 1)`, so
      #             neither `ashr` nor `const_int` moves at all.
      #
      #   post-opt  delta(mul) = -Nm   delta(band) = +Nm
      #             delta(ashr) = -Nm  delta(const_int) = -Nm
      #             every OTHER opcode: delta == 0.
      #             DCE has now removed the dead shift and the shift-count
      #             constant; the scale constant survives as the mask, so
      #             const_int falls by exactly one per site, not two.
      #
      # Measured Nm: mem.bit 1 pre-opt / 10 post-opt (inlining multiplies the
      # sites), task.bit 1/1, spinlock.bit 1/2. NOTHING outside these four
      # opcodes moves on any of the three, on either kind -- so unlike the
      # #3107 post-opt arm this one needs no unconstrained-magnitude allowance,
      # and it is checked exactly on both kinds.
      Nm = -delta["mul"]
      okPtr = (Nm > 0 && delta["band"] == Nm)
      if (kind == "ir") {
        if (delta["ashr"] != 0)               okPtr = 0
        if (delta["const_int"] != 0)          okPtr = 0
      } else {
        if (delta["ashr"] != -Nm)             okPtr = 0
        if (delta["const_int"] != -Nm)        okPtr = 0
      }
      for (op in moved) {
        if (op != "mul" && op != "band" && op != "ashr" && op != "const_int") okPtr = 0
      }
      if (okPtr) {
        print "3898-ptr-scale-shift-fold"
        exit 0
      }

      # --- #3862: inline slice elements (all-scalar class, `[]T` packed) ---
      #
      # `emitInlineSliceElem` (compiler/lowersliceinline.bit) replaces THREE
      # old shapes with an inline bounds-check + address computation, once
      # `sliceElemSizeFor` returns the class T size (>8) instead of the
      # word stride 8:
      #
      #   rt_call slice_get(...)         a for-of-style whole-element READ
      #   rt_call slice_set(...)         a composite-literal element WRITE
      #   index_get %ptr[%adjIdx] T      a direct `xs[i]` handle load -- the
      #                                  OLD boxed lowering already emitted a
      #                                  bounds check ahead of this one, so
      #                                  replacing it adds no prologue.
      #
      # `append` additionally re-locates its growth target via `slice_len - 1`
      # (a `sub` this identity uses nowhere else, so it is read DIRECTLY, not
      # derived like the other three):
      #
      #   Ng  = -delta(rt_call:slice_get)   reads inlined            (>= 0)
      #   Nsl = -delta(rt_call:slice_set)   literal-population writes(>= 0)
      #   Na  = delta(sub)                  append growths reindexed(>= 0)
      #   Np  = -delta(index_get)           already-checked handle loads (>=0)
      #   B   = Ng + Nsl + Na   -- sites gaining a FRESH bounds-check prologue;
      #         Np sites already had one, so they add no prologue, only the
      #         address-computation tail (mul by stride instead of an implicit
      #         word-indexed load).
      #
      # Derived empirically from EVERY file that diverges on EITHER dump kind
      # (4 files, both kinds checked -- #3843 already proved these 4 are the
      # WHOLE diverging set against the pinned oracle):
      # _tests_/cases/check_composite_order.bit (Ng=0 Nsl=2 Na=0 Np=0),
      # _tests_/cases/run_slice_inline_basic.bit (Ng=2 Nsl=1 Na=4 Np=8),
      # _tests_/imports/selfhostlex/main.bit (Ng=1 Nsl=0 Na=4 Np=0),
      # stdlib/quic/frames.bit (Ng=1 Nsl=0 Na=1 Np=0). Every coefficient below
      # is an independent equation and all 4 satisfy every one, on both kinds:
      #
      #   delta(slice_len)  = B + Na   (an append re-locate needs a SECOND
      #                                 slice_len beyond the one the prologue itself uses)
      #   delta(icmp_ult) = delta(br) = delta(const_string) =
      #     delta(rt_call:panic) = delta(unreachable) = B
      #   delta(field_get)  = 2*B      (the address prologue ptr + start-
      #                                 offset fields; per-FIELD value reads
      #                                 are unchanged -- same field_get count
      #                                 as the old boxed form, just off a
      #                                 different base pointer)
      #   delta(mul)        = B + Np   (the stride multiply; Np sites gain
      #                                 this even though they gain no prologue)
      #   delta(const_int)  = Nsl + 3*Na + Np
      #                       Ng contributes ZERO: the old rt_call:slice_get
      #                       own stride-constant argument is removed at the
      #                       same rate the new mul stride constant is
      #                       added. Nsl contributes 1 (new mul stride only --
      #                       the old rt_call:slice_set stride arg was
      #                       already shared/reused, not one-per-site). Na
      #                       contributes 3: the mul stride, the append call
      #                       new null value-pointer argument (there is no
      #                       struct left to point at), and the literal `1` in
      #                       `slice_len - 1`. Np contributes 1 (mul stride).
      #   delta(sub)         = Na   (by definition -- this is how Na is read)
      #   delta(gc_alloc)    = -(Nsl + Na)   (every packed element that no
      #                                       longer needs its own heap box)
      #   delta(rt_call:slice_get) = -Ng   delta(rt_call:slice_set) = -Nsl
      #   delta(index_get)   = -Np
      #   delta(add), PRE-OPT ONLY = 2*B + Np   (2 per prologue site: the
      #                                 existing offset+index add is
      #                                 unchanged, this is the NEW base+scaled
      #                                 add, plus a second one Np sites also
      #                                 gain; 1 per Np site, which only gains
      #                                 the base+scaled add.)
      #
      # POST-OPT: every equation above holds UNCHANGED except `add`, which
      # DCE can shrink by folding an `add x, 0` identity when a written index
      # is the literal 0 (observed: -1 of the predicted total on 2 of the 4
      # files, 0 on the other 2 -- not a fixed multiple of B, Na, or Np, so
      # `add` is left with UNCONSTRAINED magnitude for iropt only, the same
      # allowance the #3107 post-opt arm makes for call/call_value/sub above).
      Ng2 = -delta["rt_call:slice_get"]
      Nsl2 = -delta["rt_call:slice_set"]
      Na2 = delta["sub"] + 0
      Np2 = -delta["index_get"]
      B2 = Ng2 + Nsl2 + Na2
      okSlice = (Ng2 >= 0 && Nsl2 >= 0 && Na2 >= 0 && Np2 >= 0 && (B2 + Np2) > 0)
      if (delta["slice_len"] != B2 + Na2)              okSlice = 0
      if (delta["icmp_ult"] != B2)                     okSlice = 0
      if (delta["br"] != B2)                           okSlice = 0
      if (delta["const_string"] != B2)                 okSlice = 0
      if (delta["rt_call:panic"] != B2)                okSlice = 0
      if (delta["unreachable"] != B2)                  okSlice = 0
      if (delta["field_get"] != 2 * B2)                okSlice = 0
      if (delta["mul"] != B2 + Np2)                    okSlice = 0
      if (delta["const_int"] != Nsl2 + 3 * Na2 + Np2)  okSlice = 0
      if (delta["gc_alloc"] != -(Nsl2 + Na2))          okSlice = 0
      if (kind == "ir") {
        if (delta["add"] != 2 * B2 + Np2)              okSlice = 0
      }
      split("slice_get slice_set gc_alloc slice_len icmp_ult br const_string panic unreachable field_get add mul sub const_int index_get", silist, " ")
      for (i in silist) sicore[silist[i]] = 1
      for (op in moved) {
        opname = op
        sub(/^rt_call:/, "", opname)
        if (!(opname in sicore)) okSlice = 0
      }
      if (okSlice) {
        print "3862-slice-inline-elements"
        exit 0
      }

      exit 1
    }
  ' <(printf '%s\n@@@BIT2@@@\n%s\n' "$1" "$2")
}

# Self-check: run directly (not sourced) to assert explainMismatch still
# accepts the #3107 shape and still rejects an unrelated single-opcode delta.
# `bash scripts/selfhost-ir-signatures.sh`. Same pattern as
# scripts/selfhost-ir-canon.sh's self-check.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -u
  fail=0

  # A minimal N=1, Nn=0, Nf=0 instance of the #3107 identity: one inlined
  # `xs[i]` read, plain element type, no float round-trip. Every opcode named
  # in the identity appears with exactly the delta the formula requires and
  # nothing else changes.
  oracle_explained='%1 = rt_call slice_get(%0, %i)'
  bit2_explained='%1 = slice_len(%0)
%2 = icmp_ult %i, %1
br %2, bb1, bb2
%3 = const_string "index out of range"
%4 = rt_call panic(%3)
unreachable
%5 = field_get %0, 0
%6 = field_get %0, 0
%7 = add %5, %6
%8 = index_get %0, %i'

  sig=$(explainMismatch "$oracle_explained" "$bit2_explained" ir)
  rc=$?
  if [ "$rc" -ne 0 ] || [ "$sig" != "3107-slice-read-inline" ]; then
    echo "FAIL: a #3107-shaped delta was not explained (rc=$rc sig='$sig')"
    fail=1
  fi

  # The #3108 half: one inlined `xs[i] = v` STORE, no reads. Ng = 0, Ns = 1,
  # Nn = 0. Same prologue as the read (the two share `emitInlineSliceElem`),
  # ending in `index_set` instead of `index_get` — and `index_set` is a void op,
  # so this also pins the recognizer line that makes it visible at all.
  oracle_store='%1 = rt_call slice_set(%0, %i, %v) void'
  bit2_store='%1 = slice_len(%0)
%2 = icmp_ult %i, %1
br %2, bb1, bb2
%3 = const_string "index out of range"
%4 = rt_call panic(%3)
unreachable
%5 = field_get %0, 0
%6 = field_get %0, 0
%7 = add %5, %6
index_set %0[%7] = %v'

  sigs=$(explainMismatch "$oracle_store" "$bit2_store" ir)
  rcs=$?
  if [ "$rcs" -ne 0 ] || [ "$sigs" != "3108-slice-store-inline" ]; then
    echo "FAIL: a #3108-shaped delta was not explained (rc=$rcs sig='$sigs')"
    fail=1
  fi

  # A store delta whose `index_set` did NOT appear must be REJECTED: that is the
  # shape of a store that lost its write, and before the recognizer line above
  # it scored identically to a correct one.
  bit2_store_lost=$(printf '%s\n' "$bit2_store" | grep -v '^index_set ')
  sigl=$(explainMismatch "$oracle_store" "$bit2_store_lost" ir)
  rcl=$?
  if [ "$rcl" -eq 0 ] || [ -n "$sigl" ]; then
    echo "FAIL: a store with no index_set was wrongly explained (rc=$rcl sig='$sigl')"
    fail=1
  fi

  # An unrelated single-opcode delta (the #3125 mutation-test shape: a binop
  # flipped from sub to add) must NOT be explained — there is no slice_get
  # delta at all, so N is never positive.
  oracle_unrelated='%1 = sub %2, %3'
  bit2_unrelated='%1 = sub %2, %3
%4 = sub %5, %6'

  sig2=$(explainMismatch "$oracle_unrelated" "$bit2_unrelated" ir)
  rc2=$?
  if [ "$rc2" -eq 0 ] || [ -n "$sig2" ]; then
    echo "FAIL: an unrelated opcode delta was wrongly explained (rc=$rc2 sig='$sig2')"
    fail=1
  fi

  # --- #3898: the pointer-scale / right-shift cancellation, both kinds ---
  #
  # Pre-opt, Nm = 1: the `const_int 8` + `mul` pair becomes `const_int -8` +
  # `band`, and the dead `ashr`/`const_int 3` are still emitted, so `ashr` and
  # `const_int` must NOT move.
  oracle_ptr='%1 = const_int i64 3
%2 = ashr i64 %0, %1
%3 = const_int i64 8
%4 = mul i64 %2, %3
%5 = convert i64 %4'
  bit2_ptr='%1 = const_int i64 3
%2 = ashr i64 %0, %1
%3 = const_int i64 -8
%4 = band i64 %0, %3
%5 = convert i64 %4'

  sigp=$(explainMismatch "$oracle_ptr" "$bit2_ptr" ir)
  rcp=$?
  if [ "$rcp" -ne 0 ] || [ "$sigp" != "3898-ptr-scale-shift-fold" ]; then
    echo "FAIL: a #3898-shaped pre-opt delta was not explained (rc=$rcp sig='$sigp')"
    fail=1
  fi

  # Post-opt, Nm = 1: DCE has removed the dead shift and its count constant, so
  # `ashr` and `const_int` each fall by exactly Nm. The SAME text scored as
  # `ir` must be REJECTED there and vice versa — the two kinds are different
  # identities, not one loosened check.
  bit2_ptr_opt='%3 = const_int i64 -8
%4 = band i64 %0, %3
%5 = convert i64 %4'

  sigq=$(explainMismatch "$oracle_ptr" "$bit2_ptr_opt" iropt)
  rcq=$?
  if [ "$rcq" -ne 0 ] || [ "$sigq" != "3898-ptr-scale-shift-fold" ]; then
    echo "FAIL: a #3898-shaped post-opt delta was not explained (rc=$rcq sig='$sigq')"
    fail=1
  fi

  sigr=$(explainMismatch "$oracle_ptr" "$bit2_ptr_opt" ir)
  rcr=$?
  if [ "$rcr" -eq 0 ] || [ -n "$sigr" ]; then
    echo "FAIL: a post-opt-shaped delta was wrongly explained as pre-opt (rc=$rcr sig='$sigr')"
    fail=1
  fi

  # THE MASK IS THE WHOLE CORRECTNESS ARGUMENT, so a fold that DROPPED it — the
  # tempting `(e >> k) * 2^k == e` non-identity, which truncates for a
  # misaligned `e` — must NOT be explained. It removes the mul and its constant
  # and adds no band at all.
  bit2_ptr_nomask='%1 = const_int i64 3
%2 = ashr i64 %0, %1
%5 = convert i64 %0'

  sigs2=$(explainMismatch "$oracle_ptr" "$bit2_ptr_nomask" ir)
  rcs2=$?
  if [ "$rcs2" -eq 0 ] || [ -n "$sigs2" ]; then
    echo "FAIL: a mask-dropping fold was wrongly explained (rc=$rcs2 sig='$sigs2')"
    fail=1
  fi

  # A second, unrelated opcode moving alongside a real #3898 delta must still
  # fail: a signature names an identity the WHOLE delta must satisfy, not a
  # file that is allowed to differ.
  bit2_ptr_plus="$bit2_ptr
%6 = call @somethingElse()"

  sigt=$(explainMismatch "$oracle_ptr" "$bit2_ptr_plus" ir)
  rct=$?
  if [ "$rct" -eq 0 ] || [ -n "$sigt" ]; then
    echo "FAIL: a #3898 delta carrying an unrelated op was wrongly explained (rc=$rct sig='$sigt')"
    fail=1
  fi

  # --- #3862: inline slice elements, both dump kinds (#3907) ---
  #
  # Minimal Ng=1 instance (a for-of-style whole-element READ inlined): one
  # `rt_call slice_get` replaced by a bounds check + address computation.
  oracle_si_read='%1 = const_int i64 8
%2 = rt_call slice_get(%0, %i, %1) T
%3 = field_get %2[0] i64'
  bit2_si_read='%1 = slice_len %0
%2 = icmp_ult bool %i, %1
br %2, bb1, bb2
%3 = const_string "index out of range"
%4 = rt_call panic(%3) void
unreachable
%5 = field_get %0[0] i64
%6 = field_get %0[16] i64
%7 = add i64 %6, %i
%8 = const_int i64 16
%9 = mul i64 %7, %8
%10 = add i64 %5, %9
%11 = field_get %10[0] i64'

  sigsi=$(explainMismatch "$oracle_si_read" "$bit2_si_read" ir)
  rcsi=$?
  if [ "$rcsi" -ne 0 ] || [ "$sigsi" != "3862-slice-inline-elements" ]; then
    echo "FAIL: a #3862-shaped Ng read delta was not explained (rc=$rcsi sig='$sigsi')"
    fail=1
  fi

  # Minimal Na=1 instance (an `append` growth reindexed via `slice_len - 1`),
  # pinning the `sub`-derived Na and its 3-per-site const_int contribution
  # (stride, the null value-pointer arg, and the literal `1`).
  oracle_si_append='%1 = const_int i64 1
%2 = const_int i64 8
%3 = gc_alloc size=16 ptrs=[] T
%4 = const_int i64 42
field_set %3[0] = %4
%6 = rt_call slice_append(%0, %3, %1, %2) []T'
  bit2_si_append='%1 = const_int i64 0
%2 = const_int i64 16
%3 = const_int i64 0
%4 = rt_call slice_append(%0, %3, %1, %2) []T
%5 = slice_len %4
%6 = const_int i64 1
%7 = sub i64 %5, %6
%8 = slice_len %4
%9 = icmp_ult bool %7, %8
br %9, bb1, bb2
%11 = const_string "index out of range"
%12 = rt_call panic(%11) void
unreachable
%14 = field_get %4[0] i64
%15 = field_get %4[16] i64
%16 = add i64 %15, %7
%17 = const_int i64 16
%18 = mul i64 %16, %17
%19 = add i64 %14, %18
%20 = const_int i64 42
field_set %19[0] = %20'

  sigsa=$(explainMismatch "$oracle_si_append" "$bit2_si_append" ir)
  rcsa=$?
  if [ "$rcsa" -ne 0 ] || [ "$sigsa" != "3862-slice-inline-elements" ]; then
    echo "FAIL: a #3862-shaped Na append delta was not explained (rc=$rcsa sig='$sigsa')"
    fail=1
  fi

  # Post-opt: DCE folds one `add x, 0` identity (observed on real corpus
  # files whose written index is a literal 0), so `add` must be accepted
  # with ONE FEWER occurrence than the pre-opt identity requires — but ONLY
  # under `iropt`. The same text scored as `ir` must be REJECTED, exactly
  # the cross-kind check #3898's post-opt arm already makes.
  bit2_si_read_opt='%1 = slice_len %0
%2 = icmp_ult bool %i, %1
br %2, bb1, bb2
%3 = const_string "index out of range"
%4 = rt_call panic(%3) void
unreachable
%5 = field_get %0[0] i64
%6 = field_get %0[16] i64
%8 = const_int i64 16
%9 = mul i64 %6, %8
%10 = add i64 %5, %9
%11 = field_get %10[0] i64'

  sigso=$(explainMismatch "$oracle_si_read" "$bit2_si_read_opt" iropt)
  rcso=$?
  if [ "$rcso" -ne 0 ] || [ "$sigso" != "3862-slice-inline-elements" ]; then
    echo "FAIL: a #3862-shaped post-opt (add-folded) delta was not explained (rc=$rcso sig='$sigso')"
    fail=1
  fi

  sigso2=$(explainMismatch "$oracle_si_read" "$bit2_si_read_opt" ir)
  rcso2=$?
  if [ "$rcso2" -eq 0 ] || [ -n "$sigso2" ]; then
    echo "FAIL: a post-opt-folded #3862 delta was wrongly explained as pre-opt (rc=$rcso2 sig='$sigso2')"
    fail=1
  fi

  # REJECTION 1: the bounds check dropped (the safety-relevant fold this
  # signature exists to refuse to paper over) — same read, minus the
  # const_string/panic/unreachable trio. `unreachable`'s delta then reads 0
  # against a required B=1, so this must NOT be explained on either kind.
  bit2_si_read_nocheck='%1 = slice_len %0
%2 = icmp_ult bool %i, %1
br %2, bb1, bb2
%5 = field_get %0[0] i64
%6 = field_get %0[16] i64
%7 = add i64 %6, %i
%8 = const_int i64 16
%9 = mul i64 %7, %8
%10 = add i64 %5, %9
%11 = field_get %10[0] i64'

  sigrc=$(explainMismatch "$oracle_si_read" "$bit2_si_read_nocheck" ir)
  rcrc=$?
  if [ "$rcrc" -eq 0 ] || [ -n "$sigrc" ]; then
    echo "FAIL: a #3862 delta with its bounds check dropped was wrongly explained (rc=$rcrc sig='$sigrc')"
    fail=1
  fi

  # REJECTION 2: an unrelated opcode moving alongside an otherwise-valid
  # #3862 delta must still fail — a signature is an identity the WHOLE delta
  # must satisfy, not a file allowed to differ elsewhere (same shape as the
  # #3898 rejection above).
  bit2_si_read_plus="$bit2_si_read
%12 = call @somethingElse()"

  sigrd=$(explainMismatch "$oracle_si_read" "$bit2_si_read_plus" ir)
  rcrd=$?
  if [ "$rcrd" -eq 0 ] || [ -n "$sigrd" ]; then
    echo "FAIL: a #3862 delta carrying an unrelated op was wrongly explained (rc=$rcrd sig='$sigrd')"
    fail=1
  fi

  # REJECTION 3: an extra, unaccounted field_get — the shape of a fold that
  # reads one field too many. field_get must be exactly 2*B; a third read
  # breaks the count even though field_get is already a declared opcode.
  bit2_si_read_extraread="$bit2_si_read
%12 = field_get %10[8] i64"

  sigre=$(explainMismatch "$oracle_si_read" "$bit2_si_read_extraread" ir)
  rcre=$?
  if [ "$rcre" -eq 0 ] || [ -n "$sigre" ]; then
    echo "FAIL: a #3862 delta with a spurious extra field_get was wrongly explained (rc=$rcre sig='$sigre')"
    fail=1
  fi

  if [ "$fail" -eq 0 ]; then
    echo "selfhost-ir-signatures.sh: self-check passed"
  fi
  exit "$fail"
fi
