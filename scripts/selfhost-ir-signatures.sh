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
#   delta(add)=N+Nn   delta(shl)=Nn   delta(const_int)=Nn-N
#   delta(index_get)=N-Nn   Nn>=0   Nf>=0
#   every OTHER opcode: delta==0 (pre-opt only — see POST-OPT below)
#
#   #4370 CORRECTED THE const_int TERM from Nn to Nn-N. #3120 (ABI.md §9,
#   landed after this signature was first derived) gave `rt_call slice_get`
#   a THIRD operand, `elem_size`, emitted as its own `const_int` immediately
#   ahead of every non-inlined call. Inlining removes the whole call AND that
#   preceding const_int, so each of the N accesses this signature explains
#   also removes one const_int the un-narrowed identity below never counted —
#   independent of and additional to the Nn narrow-prim shift-count consts
#   the formula already had. Verified against a real oracle dump (`bit-oracle
#   --dump-ir-pre` on `_tests_/cases/run_forof_slice.bit`): each surviving
#   `rt_call slice_get(%h, %i, %sz)` is preceded by its own `%sz = const_int
#   i64 8`, absent from the inlined replacement entirely.
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
#   delta(add)=N+Nn   delta(shl)=Nn   delta(const_int)=Nn-N
#   delta(index_get)=Ng-Nn   delta(index_set)=Ns
#   every OTHER opcode: delta==0 (pre-opt only)
#
# Nn is READ-ONLY on purpose and that is a property of the change, not an
# approximation: #3108 inlines a store only when the element is exactly 8
# bytes, because `rtSliceSet` writes a whole word and a narrow store does not
# (it would leave the other seven bytes, which `rtSliceGet` still returns
# whole). So no store ever takes the shl arm, and the const_int term's -N
# half is the ONLY effect a store contributes to const_int: `rt_call
# slice_set(%h, %i, %v, %sz)` carries the identical elem_size `const_int`
# operand `slice_get` does (`compiler/lowerflow.bit`'s `lowerIndexStore`,
# `compiler/loweraccess.bit`'s `emitInlineSliceSet` emits none), so each
# inlined store removes exactly one const_int and zero shl, same as a wide
# read. #4370 folds this into the single `Nn-N` term above rather than
# forking read/store, verified against a real oracle dump
# (`bit-oracle --dump-ir-pre` on a narrow-element store: `%3 = const_int i64
# 8` / `%4 = rt_call slice_set(%0, %1, %2, %3) void`).
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
    side == 0 && $0 == "@@@BIT2@@@" { side = 1; next }
    side == 0 { cntA5486[canon5486($0)]++; op = opcode($0); if (op != "") a[op]++; next }
    { cntB5486[canon5486($0)]++; op = opcode($0); if (op != "") b[op]++ }
    END {
      # --- #5486: pure instruction-reorder (payload lowered before its
      # `gc_alloc`, compiler/lowercall.bit variantPayloadValues via
      # lowerVariantConstruction, compiler/lowerlayout.bit) ---
      #
      # Every opcode-COUNT delta is zero for a reorder — nothing is added,
      # removed or retyped, so the #3107-style identities below (each keyed on
      # some N > 0) correctly do not explain it and would need their own,
      # weaker, all-zero special case if this were folded into one of them.
      # The identity actually checked here is STRONGER than an opcode
      # histogram: the CANONICALIZED LINE MULTISET (every `%<id>` erased, both
      # definition and use sites, then compared as a bag of lines rather than
      # ordered text) must be identical between the two sides. Measured
      # against every file #5486 (a928fd01) reorders relative to the pinned
      # oracle (bd466499) — 57 of them at pre-opt, `bash
      # scripts/selfhost-diffir.sh` before this signature existed — the
      # multiset holds on all 57; the io.bit hunk quoted in the ticket is the
      # worked example. This also explains 49 of those same 57 files at
      # POST-opt, where `opt.bit` does not additionally touch anything: the
      # other 8 post-opt files need the separate identity below, because
      # there the optimizer does not just reorder.
      #
      # WHAT THIS DOES NOT CATCH, stated plainly rather than implied: two
      # side-effecting expressions (two `rt_call`s, say) swapped in
      # EVALUATION ORDER produce the exact same bag of lines and pass this
      # check, even though the order genuinely matters for a caller-visible
      # effect. A per-file line multiset cannot distinguish "moved" from
      # "reordered past something it must not cross" — that is a real gap,
      # not a rounding error, and the reason this signature is scoped to one
      # named transform call site rather than offered as a general-purpose
      # reorder detector. The mutation control (flip `Op.Sub` to `Op.Add` in
      # compiler/lower.bit binOpFor) changes a line OPCODE, not its position,
      # so it changes the multiset CONTENTS and still fails this check and
      # every other one below (recorded on the ticket).
      reorder5486 = 1
      for (k5486 in cntA5486) { if (cntB5486[k5486] != cntA5486[k5486]) reorder5486 = 0 }
      if (reorder5486) {
        for (k5486 in cntB5486) { if (cntA5486[k5486] != cntB5486[k5486]) reorder5486 = 0 }
      }
      if (reorder5486) {
        print "5486-variant-payload-reorder"
        exit 0
      }


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
        # #4370: was `!= Nn` — #3120 (ABI.md §9) gave slice_get/slice_set a
        # third/fourth `elem_size` operand, its own preceding `const_int`,
        # which inlining removes along with the call. Each of the N inlined
        # accesses (read or store) removes one such const_int in addition to
        # whatever the narrow-prim shl arm adds.
        if (delta["const_int"] != Nn - N) ok = 0
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

      # --- #5429: decimal boxed-slot explode (field_set/field_get width-16 fix) ---
      #
      # `buildTupleIn`/`tupleElem` (compiler/lowerexpr.bit) and the closure-env
      # pack/unpack plus mutated-capture cell write (compiler/lowerclosure.bit,
      # compiler/lowerfuncval.bit) used to move a `decimal` VALUE with a single
      # field access typed `decimal` -- the oracle `gpSizeOpc: width 16` panic,
      # because a decimal VALUE is an 8-byte POINTER to a two-word box, not a
      # 16-byte inline value. #5429 fixes every one of those sites to move the
      # two i64 WORDS separately instead of the whole 16 bytes at once.
      #
      # A WRITE site (building a tuple/env slot from a decimal source) used to
      # be one `field_set dst[k] = %ptr`; now it reads the two source words
      # and writes them separately -- TWO more `field_get`s. `field_set` itself
      # is unscored by opcode() (see the comment on that function), so only the
      # `field_get` pair is visible here, not the doubled `field_set` count.
      #
      # A READ site (pulling a decimal member back out, to use as a
      # `decimal`-typed value) used to be one `field_get src[k] decimal` (a
      # pointer) plus the two-word unbox off that pointer -- 3 `field_get`s
      # total, no allocation, since the pointer already pointed at a live box.
      # Now the two words are read directly off `src` (2 `field_get`s, no
      # allocation), then RE-BOXED into a fresh 16-byte `(i64, i64)` object so
      # the value can still be passed around as a pointer (`gc_alloc` + 2 more
      # `field_set`s, unscored), then unboxed again at the point of use (2 more
      # `field_get`s) -- 4 `field_get`s and 1 `gc_alloc`, net +1 `field_get` and
      # +1 `gc_alloc` over the oracle per read site.
      #
      # So per write site (Nw) and read site (Nr), independently:
      #   delta(field_get) = 2*Nw + Nr        delta(gc_alloc) = Nr
      # Nr is read straight off delta(gc_alloc); Nw is solved from what is left
      # of delta(field_get) after removing the Nr share, and that remainder
      # must be a non-negative EVEN number -- an odd remainder is not this shape.
      #
      # Derived empirically from both #5429 fixtures at pre-opt (`--dump-ir-pre`,
      # oracle e960043d vs this tree, measured at 43627746):
      #   _tests_/cases/decimal_tuple_member.bit:    field_get +3, gc_alloc +1
      #     -> Nr=1, Nw=1 (one tuple-build write, one destructure-and-print read)
      #   _tests_/cases/decimal_closure_capture.bit: field_get +9, gc_alloc +3
      #     -> Nr=3, Nw=3 (env-pack write, two cell writes; read-capture use,
      #        two mutated-capture reads)
      # No other opcode moves on either file at pre-opt.
      Nr5429 = delta["gc_alloc"]
      Nrest5429 = delta["field_get"] - Nr5429
      ok5429 = (Nr5429 >= 0 && Nrest5429 >= 0 && Nrest5429 % 2 == 0)
      Nw5429 = Nrest5429 / 2
      if (Nw5429 + Nr5429 <= 0) ok5429 = 0

      # POST-OPT: the opt.bit CSE/DCE pass can fold a read site box-then-unbox
      # roundtrip away entirely once nothing else observes the intermediate
      # pointer (the same class of redistribution the #3107 post-opt arm
      # documents), so the exact Nw/Nr split above does not survive. What DOES
      # hold on both #5429 fixtures: `field_get` and `gc_alloc` move by the
      # SAME amount, always downward -- each eliminated box takes its own
      # reads with it, in lockstep, never a partial fold:
      #   decimal_tuple_member.bit:    field_get -3, gc_alloc -3
      #   decimal_closure_capture.bit: field_get -2, gc_alloc -2
      if (kind != "ir") {
        ok5429 = (delta["field_get"] == delta["gc_alloc"] && delta["gc_alloc"] < 0)
      }
      # Both kinds: nothing outside {field_get, gc_alloc} may move at all --
      # no unconstrained-magnitude allowance, unlike the #3107/#3862 post-opt
      # arms, because nothing else moved on either measured fixture. `moved`,
      # not `delta` -- see the block comment above this function for why
      # `delta` is polluted with every zero-valued key the earlier signature
      # blocks above have already probed by the time this one runs.
      for (op in moved) {
        opname = op
        sub(/^rt_call:/, "", opname)
        if (opname != "field_get" && opname != "gc_alloc") ok5429 = 0
      }
      if (ok5429) {
        print "5429-decimal-boxed-slot-explode"
        exit 0
      }

      # --- #5486, POST-OPT ONLY: redundant post-box payload read eliminated
      # WITHOUT the box itself dying --- the reorder block far above this one
      # explains a pure move; this covers the one shape in the corpus where
      # `opt.bit` goes further than a reorder but the box still survives.
      #
      # Once the payload is lowered before its `gc_alloc` (see the reorder
      # block), a `field_get box[k]` that used to re-derive the payload from
      # the freshly built box is sometimes redundant -- the payload SSA value
      # is already live -- and CSE forwards it directly, dropping the
      # `field_get`, even when the box itself is still returned/used
      # elsewhere and so is NOT eliminated. Measured on
      # _tests_/cases/run_enum_explode_method.bit (bd466499 oracle vs
      # a928fd01): delta(field_get) = -2, every other opcode delta = 0,
      # INCLUDING gc_alloc (=0 -- the box survives, unlike the 7 other
      # post-opt-diverging corpus files where the box also dies).
      #
      # THAT gc_alloc=0 case is exactly what keeps this block from ever firing
      # on a file the #5429 block above already claims: #5429s post-opt arm
      # requires delta(gc_alloc) == delta(field_get) AND delta(gc_alloc) < 0
      # (a box that DOES die), so it runs first and correctly claims the
      # other 7 #5486 post-opt files whose box also dies -- that identity is
      # not decimal-specific despite its name; it is opt.bit box-elimination
      # DCE in general, independently reachable from two different call
      # sites. This block is deliberately narrower and ONLY covers the
      # gc_alloc-untouched case #5429s block cannot: it is not a generalised
      # "field_get moved" check, since widening it further would risk
      # explaining an unrelated field-read miscount.
      Ng5486b = -delta["gc_alloc"]
      Nf5486b = -delta["field_get"]
      ok5486b = (kind != "ir" && Ng5486b == 0 && Nf5486b > 0)
      for (op in moved) {
        if (op != "field_get") ok5486b = 0
      }
      if (ok5486b) {
        print "5486-variant-payload-redundant-read-elim"
        exit 0
      }

      # --- #5506: the NIL PAYLOAD WORD of a no-payload variant, retyped from
      # `i64` to the type the exploded read-back reads it at
      # (`buildEnumObj`/`enumNilPayloadType`, compiler/lowerlayout.bit +
      # compiler/lowerexplode.bit) ---
      #
      # Runs LAST, immediately before the regression verdict, so it can never
      # claim a file one of the signatures above already explains.
      #
      # Like the #5486 reorder block it works on the CANONICALIZED LINE
      # MULTISET rather than an opcode histogram, because these files also
      # carry the #5486 reorder and a histogram cannot tell the two apart. Here
      # the multisets are NOT equal: what is checked is that their symmetric
      # difference contains nothing but the lines this one transform moves.
      #
      # PRE-OPT (`kind == "ir"`), the strict arm: every line the oracle has and
      # this tree does not must be `const_int i64 0` — the hardcoded nil word —
      # and every line this tree has and the oracle does not must be that same
      # ZERO in another type: `const_nil` for a reference slot, `const_float
      # <t> 0`, `const_bool false`, or `const_int <t> 0` for a narrower int.
      # `const_int i64 0` is deliberately NOT accepted on the added side: an
      # i64 payload word retypes to the identical line and so never appears in
      # the difference at all, which leaves the pattern free to refuse a gained
      # i64 zero as the regression it would be. The two counts must BALANCE
      # exactly — measured on all 21 pre-opt diverging files of this tree
      # (`bash scripts/selfhost-diffir.sh` before this signature existed), from
      # 1 site up to the 42 in stdlib/json/value.bit (25 const_nil, 11 const_float,
      # 6 const_bool) against 42 const_int i64 0.
      #
      # POST-OPT, the weaker arm, and its weakness stated rather than implied:
      # once the store and the load agree, `forwardOneLoad` answers the load
      # and the box DIES, so the difference also carries that footprint: one
      # `gc_alloc size=16 ptrs=[%] <enum>`, its two
      # `field_set`s at [0] and [8], and up to one read back of each of those
      # two words. The counts are tied to the allocation count (two stores per
      # dead box, never more reads than boxes), which is what refuses a
      # half-deleted box, but the SHAPE is not unique to `buildEnumObj`: a bug
      # that deleted a LIVE payload-carrying box of the same 16-byte
      # one-pointer layout would present the same way and be explained. That
      # gap is real. It is bounded by the pre-opt arm above, which admits
      # nothing but the constant, and by `test-golden`/`test-selfcheck`, which
      # run the deleted-box programs; this signature is evidence about the
      # TRANSFORM, never about the box being dead.
      #
      # The mutation control (flip `Op.Sub` to `Op.Add` in compiler/lower.bit
      # `binOpFor`) changes a `sub` line into an `add` line: neither is in
      # either pattern set, so the symmetric difference is non-empty in a shape
      # no arm accepts and every such file still fails. Recorded on #5506.
      ok5506 = 1
      Nci5506 = 0; Nadd5506 = 0; Ng5506 = 0
      Nfs0_5506 = 0; Nfs8_5506 = 0; Nfg5506 = 0
      for (k5506 in cntA5486) {
        d5506 = cntA5486[k5506] - cntB5486[k5506]
        if (d5506 <= 0) { continue }
        if (k5506 ~ /^[[:space:]]*% = const_int i64 0$/) { Nci5506 += d5506; continue }
        if (kind == "ir") { ok5506 = 0; continue }
        if (k5506 ~ /^[[:space:]]*% = gc_alloc size=16 ptrs=\[%\] /) { Ng5506 += d5506; continue }
        if (k5506 ~ /^[[:space:]]*field_set %\[0\] = %$/) { Nfs0_5506 += d5506; continue }
        if (k5506 ~ /^[[:space:]]*field_set %\[8\] = %$/) { Nfs8_5506 += d5506; continue }
        if (k5506 ~ /^[[:space:]]*% = field_get %\[[08]\] /) { Nfg5506 += d5506; continue }
        ok5506 = 0
      }
      for (k5506 in cntB5486) {
        d5506 = cntB5486[k5506] - cntA5486[k5506]
        if (d5506 <= 0) { continue }
        if (k5506 ~ /^[[:space:]]*% = const_nil$/ ||
            k5506 ~ /^[[:space:]]*% = const_bool false$/ ||
            k5506 ~ /^[[:space:]]*% = const_float [^ ]+ 0$/ ||
            (k5506 ~ /^[[:space:]]*% = const_int [^ ]+ 0$/ &&
             k5506 !~ /^[[:space:]]*% = const_int i64 0$/)) {
          Nadd5506 += d5506
          continue
        }
        ok5506 = 0
      }
      if (kind == "ir") {
        ok5506 = (ok5506 && Nadd5506 > 0 && Nci5506 == Nadd5506)
      } else {
        ok5506 = (ok5506 && Nfs0_5506 == Ng5506 && Nfs8_5506 == Ng5506 &&
                  Nfg5506 <= Ng5506 && Nci5506 <= Ng5506 &&
                  Ng5506 + Nadd5506 > 0)
      }
      if (ok5506) {
        print "5506-enum-nil-payload-retype"
        exit 0
      }

      exit 1
    }
  ' <(printf '%s\n@@@BIT2@@@\n%s\n' "$1" "$2")
}

