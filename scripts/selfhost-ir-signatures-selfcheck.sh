#!/usr/bin/env bash
# Self-check for scripts/selfhost-ir-signatures.sh's explainMismatch, split
# into its own file by #5442 so the main file (which both selfhost-diffdump.sh
# and selfhost-diffruntime.sh source) stays under the 800-line ceiling
# (spec/LINT.md) as new signatures are added. Discovered and run directly by
# scripts/selfhost-diffall.sh's `scripts/selfhost-*.sh` glob, same as the
# file it tests.
ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
# shellcheck source=scripts/selfhost-ir-signatures.sh
. "${ROOT}/scripts/selfhost-ir-signatures.sh"

# Self-check: run directly (not sourced) to assert explainMismatch rejects
# unrelated text on every kind, and correctly explains/rejects the one
# currently declared signature (#6194, `types`/`ir`/`iropt` -- see
# scripts/selfhost-ir-signatures.sh's header). `ast`/`fmt` still have no
# signature declared at all (see that file's Retirement history).
# `bash scripts/selfhost-ir-signatures-selfcheck.sh`. Same pattern as
# scripts/selfhost-ir-canon.sh's self-check.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -u
  fail=0

  # #3107, #3108, #3898 and #3862 were declared here and RETIRED by #5509.
  # #5486-variant-payload-reorder, #5429-decimal-boxed-slot-explode,
  # #5506-enum-nil-payload-retype, #5445-method-return-explode-direct-call,
  # #5521-void-return-bare-ret and #5486-variant-payload-redundant-read-elim
  # were RETIRED by the stage0 0.20.0 repin (#5607). #5870, #5871 (both
  # arms), #5874, #5876, #5895, #5905, #5906 and #5910 were RETIRED by the
  # stage0 0.27.0 repin (#5914). #5921-ptrof-string-type was RETIRED by the
  # stage0 0.28.0 repin (#5957). #5474-catch-composite-default-ast,
  # #5474-catch-composite-default-fmt and #6051-generic-member-comment-fmt
  # were all RETIRED by the stage0 0.32.0 repin (#6187): 0.32.0's own
  # oracle already parses and formats every shape they used to explain the
  # way the tree does, confirmed by `bash scripts/selfhost-diffast.sh`
  # (MATCH=1410 MISMATCH=0 EXPLAINED=0) and `bash scripts/selfhost-
  # difffmt.sh` (MATCH=2036 MISMATCH=0 EXPLAINED=0) against the 0.32.0 pin
  # -- `ast`/`fmt` have no automated RETIRED audit, so this pair was
  # confirmed dead by hand. Their shaped-delta fixtures lived in this
  # self-check; removed with the arms they tested rather than kept as tests
  # for identities that no longer exist. Git history at this file's state
  # before #5914/#5957/#6187 has them, and scripts/selfhost-ir-
  # signatures.sh's own header records why each went dead.

  # An unrelated opcode-shaped delta must NOT be explained by anything
  # declared under `ir`/`iropt` -- no signature is currently declared for
  # either kind (see scripts/selfhost-ir-signatures.sh's Retirement history),
  # so both must always return 1 regardless of what the text looks like.
  oracle_unrelated='%1 = sub %2, %3'
  bit2_unrelated='%1 = sub %2, %3
%4 = sub %5, %6'

  sig2=$(explainMismatch "$oracle_unrelated" "$bit2_unrelated" ir)
  rc2=$?
  if [ "$rc2" -eq 0 ] || [ -n "$sig2" ]; then
    echo "FAIL: an unrelated ir delta was wrongly explained (rc=$rc2 sig='$sig2')"
    fail=1
  fi
  sig2o=$(explainMismatch "$oracle_unrelated" "$bit2_unrelated" iropt)
  rc2o=$?
  if [ "$rc2o" -eq 0 ] || [ -n "$sig2o" ]; then
    echo "FAIL: an unrelated iropt delta was wrongly explained (rc=$rc2o sig='$sig2o')"
    fail=1
  fi

  # An unrelated ast/fmt divergence must NOT be explained by anything --
  # no signature is currently declared for either kind (see scripts/
  # selfhost-ir-signatures.sh's Retirement history), so both must always
  # return 1 regardless of what the text looks like.
  sigau=$(explainMismatch '(program (call foo))' '(program (call bar))' ast)
  rcau=$?
  if [ "$rcau" -eq 0 ] || [ -n "$sigau" ]; then
    echo "FAIL: an unrelated ast delta was wrongly explained (rc=$rcau sig='$sigau')"
    fail=1
  fi
  sigfu=$(explainMismatch 'fn main() { println("a") }' 'fn main() { println("b") }' fmt)
  rcfu=$?
  if [ "$rcfu" -eq 0 ] || [ -n "$sigfu" ]; then
    echo "FAIL: an unrelated fmt delta was wrongly explained (rc=$rcfu sig='$sigfu')"
    fail=1
  fi

  # REJECTION: an unrelated type change (no `Option` involved at all) must
  # not be explained by coincidence, and neither must a real one.
  oracle_unrelated_type='10:5: x: int'
  bit2_unrelated_type='10:5: x: float'
  sigut=$(explainMismatch "$oracle_unrelated_type" "$bit2_unrelated_type" types)
  rcut=$?
  if [ "$rcut" -eq 0 ] || [ -n "$sigut" ]; then
    echo "FAIL: an unrelated types delta was wrongly explained (rc=$rcut sig='$sigut')"
    fail=1
  fi

  # --- #6194 POSITIVE: real captured `--dump-types`/`--dump-ir-pre`/
  # `--dump-ir` output for _tests_/cases/run_generic_method_receiver_explode.bit,
  # this tree vs the pinned 0.32.0 stage0 (captured 2026-09-28, ticket #6199) ---
  oracle_6194_types='48:12: Option<T>.Some(this.v): Option
57:7: opt: Option
57:13: mkBox(id): Box<Person>
57:13: mkBox(id).get(): Option
58:8: isSome<Person>(opt): bool
61:10: unwrap<Person>(opt): Person
65:7: f: () => i64
66:9: opt: Option
66:15: mkBox(id): Box<Person>
66:15: mkBox(id).get(): Option
67:10: isSome<Person>(opt): bool
70:12: unwrap<Person>(opt): Person
72:10: f(): i64
76:3: print("direct ${readDirect(7)}\n"): ()
76:19: readDirect(7): i64
77:3: print("closure ${readViaClosure(9)}\n"): ()
77:20: readViaClosure(9): i64'
  bit2_6194_types='48:12: Option<T>.Some(this.v): Option<T>
57:7: opt: Option<Person>
57:13: mkBox(id): Box<Person>
57:13: mkBox(id).get(): Option<Person>
58:8: isSome<Person>(opt): bool
61:10: unwrap<Person>(opt): Person
65:7: f: () => i64
66:9: opt: Option<Person>
66:15: mkBox(id): Box<Person>
66:15: mkBox(id).get(): Option<Person>
67:10: isSome<Person>(opt): bool
70:12: unwrap<Person>(opt): Person
72:10: f(): i64
76:3: print("direct ${readDirect(7)}\n"): ()
76:19: readDirect(7): i64
77:3: print("closure ${readViaClosure(9)}\n"): ()
77:20: readViaClosure(9): i64'
  sig6194t=$(explainMismatch "$oracle_6194_types" "$bit2_6194_types" types)
  rc6194t=$?
  if [ "$rc6194t" -ne 0 ] || [ "$sig6194t" != "6194-generic-method-receiver-unsubstituted-type" ]; then
    echo "FAIL: the real #6194 types divergence was not explained (rc=$rc6194t sig='$sig6194t')"
    fail=1
  fi

  # --- #6194 MUTATION (types): the SAME two lines differing, but with no
  # `Option<T>.` call anywhere in the file -- must be rejected. Proves the
  # signature does not swallow an ordinary Option->Option<X> substitution
  # outside the unsubstituted-generic-receiver shape it names. ---
  oracle_6194_types_mut='10:5: opt: Option'
  bit2_6194_types_mut='10:5: opt: Option<Person>'
  sig6194tm=$(explainMismatch "$oracle_6194_types_mut" "$bit2_6194_types_mut" types)
  rc6194tm=$?
  if [ "$rc6194tm" -eq 0 ] || [ -n "$sig6194tm" ]; then
    echo "FAIL: a types divergence with no Option<T>. call was wrongly explained (rc=$rc6194tm sig='$sig6194tm')"
    fail=1
  fi

  # --- #6161 POSITIVE (types, column-shift): real --dump-types excerpt,
  # _tests_/cases/run_json_decode_lenient.bit lines 110-117, this tree vs the
  # pinned 0.32.0 stage0 (captured 2026-09-28, ticket #6208). Every line
  # shares its line number (102) and its `<name>: <type>` suffix; every
  # column shifts by the same +32. ---
  oracle_6161_colshift='102:707: __json_x0: string
102:707: __json_x0: string
102:707: __json_x0: i64
102:815: __json_x1: Addr
102:891: __json_x2: []Item
102:901: __json_dp2: string
102:912: __json_di2: i64
102:956: __json_da2: []Json'
  bit2_6161_colshift='102:739: __json_x0: string
102:739: __json_x0: string
102:739: __json_x0: i64
102:847: __json_x1: Addr
102:923: __json_x2: []Item
102:933: __json_dp2: string
102:944: __json_di2: i64
102:988: __json_da2: []Json'
  sig6161cs=$(explainMismatch "$oracle_6161_colshift" "$bit2_6161_colshift" types)
  rc6161cs=$?
  if [ "$rc6161cs" -ne 0 ] || [ "$sig6161cs" != "6161-json-decode-column-shift" ]; then
    echo "FAIL: the real #6161 column-shift types divergence was not explained (rc=$rc6161cs sig='$sig6161cs')"
    fail=1
  fi

  # --- #6161 MUTATION (types, column-shift): same shape, but the LAST line
  # shifts by +40 instead of +32 -- a non-constant delta must be rejected. ---
  bit2_6161_colshift_mut='102:739: __json_x0: string
102:739: __json_x0: string
102:739: __json_x0: i64
102:847: __json_x1: Addr
102:923: __json_x2: []Item
102:933: __json_dp2: string
102:944: __json_di2: i64
102:996: __json_da2: []Json'
  sig6161csm=$(explainMismatch "$oracle_6161_colshift" "$bit2_6161_colshift_mut" types)
  rc6161csm=$?
  if [ "$rc6161csm" -eq 0 ] || [ -n "$sig6161csm" ]; then
    echo "FAIL: a non-constant column delta was wrongly explained (rc=$rc6161csm sig='$sig6161csm')"
    fail=1
  fi

  # --- #6161 POSITIVE (types, synthesized-insert): real --dump-types
  # excerpt, _tests_/cases/run_json_schema_attrs.bit lines 1-8/1-16 (captured
  # 2026-09-28, ticket #6208): the tree types the same 3 class-declaration
  # nodes 3 extra times each (the specialized schema builder re-walking the
  # class), oracle is an exact ordered subsequence. ---
  oracle_6161_insert='13:7: len(s): i64
14:5: panic("empty"): ()
19:7: len(s): i64
20:5: panic("empty"): ()
24:13: Widget: Json
24:13: Widget: []u8
24:13: Widget: []u8
25:3: @pattern("^[a-z]+$"): ()!'
  bit2_6161_insert='13:7: len(s): i64
14:5: panic("empty"): ()
19:7: len(s): i64
20:5: panic("empty"): ()
24:13: Widget: Json
24:13: Widget: []u8
24:13: Widget: []u8
24:13: Widget: Json
24:13: Widget: Json
24:13: Widget: Json
24:13: Widget: Json
24:13: Widget: Json
24:13: Widget: Json
24:13: Widget: Json
24:13: Widget: Json
25:3: @pattern("^[a-z]+$"): ()!'
  sig6161ins=$(explainMismatch "$oracle_6161_insert" "$bit2_6161_insert" types)
  rc6161ins=$?
  if [ "$rc6161ins" -ne 0 ] || [ "$sig6161ins" != "6161-json-schema-synthesized-insert" ]; then
    echo "FAIL: the real #6161 synthesized-insert types divergence was not explained (rc=$rc6161ins sig='$sig6161ins')"
    fail=1
  fi

  # --- #6161 MUTATION (types, synthesized-insert): the SAME insertions, but
  # one oracle line (`19:7: len(s): i64`) is altered instead of merely
  # missing from the ordered match -- oracle is no longer a subsequence of
  # the tree, so this must be rejected, not silently treated as another
  # insertion. ---
  bit2_6161_insert_mut='13:7: len(s): i64
14:5: panic("empty"): ()
19:7: len(s): string
20:5: panic("empty"): ()
24:13: Widget: Json
24:13: Widget: []u8
24:13: Widget: []u8
24:13: Widget: Json
25:3: @pattern("^[a-z]+$"): ()!'
  sig6161insm=$(explainMismatch "$oracle_6161_insert" "$bit2_6161_insert_mut" types)
  rc6161insm=$?
  if [ "$rc6161insm" -eq 0 ] || [ -n "$sig6161insm" ]; then
    echo "FAIL: an altered (not just missing) oracle line was wrongly explained as an insert (rc=$rc6161insm sig='$sig6161insm')"
    fail=1
  fi

  # --- #6161 POSITIVE (types, decode-enum-error-resolved): real
  # --dump-types excerpt, _tests_/cases/run_json_decode_enum.bit (captured
  # 2026-09-28, ticket #6208): the oracle cannot type `jsonDecode<Item>(j)`
  # at all (payload-free enum-field decode postdates it), so every
  # downstream use of the result is `<error>`; the tree resolves all of
  # them to real types, with every OTHER line byte-identical. ---
  oracle_6161_errres='55:28: it.toJson(): <error>
56:7: j: Json
56:11: jsonParse(encoded): Json!
57:5: print("parse: ${e.message()}\n"): ()
57:21: e.message(): string
60:7: back: <error>
60:14: jsonDecode<Item>(j): <error>
61:5: print("decode: ${e.message()}\n"): ()
61:22: e.message(): string'
  bit2_6161_errres='55:28: it.toJson(): Json
56:7: j: Json
56:11: jsonParse(encoded): Json!
57:5: print("parse: ${e.message()}\n"): ()
57:21: e.message(): string
60:7: back: Item
60:14: jsonDecode<Item>(j): Item!
61:5: print("decode: ${e.message()}\n"): ()
61:22: e.message(): string'
  sig6161er=$(explainMismatch "$oracle_6161_errres" "$bit2_6161_errres" types)
  rc6161er=$?
  if [ "$rc6161er" -ne 0 ] || [ "$sig6161er" != "6161-json-decode-enum-error-resolved" ]; then
    echo "FAIL: the real #6161 error-resolved types divergence was not explained (rc=$rc6161er sig='$sig6161er')"
    fail=1
  fi

  # --- #6161 MUTATION (types, decode-enum-error-resolved): a well-typed
  # oracle expression (not `<error>`) changing to a DIFFERENT concrete type
  # -- a real regression shape -- must never be accepted as a resolution. ---
  oracle_6161_errres_mut='60:7: back: Widget'
  bit2_6161_errres_mut='60:7: back: Item'
  sig6161erm=$(explainMismatch "$oracle_6161_errres_mut" "$bit2_6161_errres_mut" types)
  rc6161erm=$?
  if [ "$rc6161erm" -eq 0 ] || [ -n "$sig6161erm" ]; then
    echo "FAIL: a real type-to-type regression was wrongly explained as an error-resolution (rc=$rc6161erm sig='$sig6161erm')"
    fail=1
  fi

  # --- #6161 POSITIVE (ir/iropt, specialize-call, insLen=0): real
  # --dump-ir-pre for _tests_/imports/jsonschemacrossmod/main.bit (captured
  # 2026-09-28, ticket #6208): the specialization is DEFINED in another
  # module, so this file only renames the call, same line count both sides. ---
  oracle_6161_call='  %0 = call @m3$jsonSchema$14() Json'
  bit2_6161_call='  %0 = call @m4$__json_schema_Widget() Json'
  sig6161c=$(explainMismatch "$oracle_6161_call" "$bit2_6161_call" ir)
  rc6161c=$?
  if [ "$rc6161c" -ne 0 ] || [ "$sig6161c" != "6161-json-schema-specialize-call" ]; then
    echo "FAIL: the real #6161 cross-module call rename was not explained (rc=$rc6161c sig='$sig6161c')"
    fail=1
  fi

  # --- #6161 MUTATION (ir/iropt, specialize-call): TWO call sites renamed
  # in the same file -- must be rejected, not swallowed as two independent
  # instances of the same signature. ---
  oracle_6161_call_mut2='  %0 = call @m3$jsonSchema$14() Json
  %1 = call @m3$jsonSchema$15() Json'
  bit2_6161_call_mut2='  %0 = call @m4$__json_schema_Widget() Json
  %1 = call @m4$__json_schema_Other() Json'
  sig6161c2=$(explainMismatch "$oracle_6161_call_mut2" "$bit2_6161_call_mut2" ir)
  rc6161c2=$?
  if [ "$rc6161c2" -eq 0 ] || [ -n "$sig6161c2" ]; then
    echo "FAIL: two renamed call sites in one file were wrongly explained (rc=$rc6161c2 sig='$sig6161c2')"
    fail=1
  fi

  # --- #6161 POSITIVE (ir, specialize-call, insLen>0): a small synthetic
  # function matching the real shape captured from
  # _tests_/cases/run_json_schema_attrs.bit -- the call renames, and the
  # tree inserts exactly one well-formed __json_schema_Widget function
  # directly after the shared blank separator that already existed between
  # the two original functions. ---
  oracle_6161_callins='func main() void {
bb0():
  %0 = call @jsonSchema$14() Json
  ret
}

func helper() void {
bb0():
  ret
}'
  bit2_6161_callins='func main() void {
bb0():
  %0 = call @__json_schema_Widget() Json
  ret
}

func __json_schema_Widget() Json {
bb0():
  %0 = const_string "type"
  ret %0
}

func helper() void {
bb0():
  ret
}'
  sig6161ci=$(explainMismatch "$oracle_6161_callins" "$bit2_6161_callins" ir)
  rc6161ci=$?
  if [ "$rc6161ci" -ne 0 ] || [ "$sig6161ci" != "6161-json-schema-specialize-call" ]; then
    echo "FAIL: the synthetic call-rename-plus-insert was not explained (rc=$rc6161ci sig='$sig6161ci')"
    fail=1
  fi

  # --- #6161 MUTATION (ir, specialize-call, insLen>0): the SAME insertion,
  # but the inserted function is named for a DIFFERENT type than the one the
  # call was renamed to -- must be rejected. ---
  bit2_6161_callins_mut='func main() void {
bb0():
  %0 = call @__json_schema_Widget() Json
  ret
}

func __json_schema_Other() Json {
bb0():
  %0 = const_string "type"
  ret %0
}

func helper() void {
bb0():
  ret
}'
  sig6161cim=$(explainMismatch "$oracle_6161_callins" "$bit2_6161_callins_mut" ir)
  rc6161cim=$?
  if [ "$rc6161cim" -eq 0 ] || [ -n "$sig6161cim" ]; then
    echo "FAIL: an inserted function named for the WRONG type was wrongly explained (rc=$rc6161cim sig='$sig6161cim')"
    fail=1
  fi

  # --- #6201 POSITIVE (ir, generic-wrapper-specialize): a small synthetic
  # function matching the real shape captured from
  # _tests_/cases/run_json_schema_generic.bit and
  # run_json_schema_generic_method.bit (ticket #6212): the call renames
  # exactly like `6161-json-schema-specialize-call`, but the tree ALSO
  # inserts a second function -- a one-line forwarder reproducing the
  # untouched generic dispatch used by a separately-instantiated generic
  # (wrap<T>()/Box.describe<T>()) -- directly after the specialized body,
  # before the pre-existing helper() resumes. ---
  oracle_6201_callins="$oracle_6161_callins"
  bit2_6201_callins='func main() void {
bb0():
  %0 = call @__json_schema_Widget() Json
  ret
}

func __json_schema_Widget() Json {
bb0():
  %0 = const_string "type"
  ret %0
}

func jsonSchema$14() Json {
bb0():
  %0 = call @__json_schema_Widget() Json
  ret %0
}

func helper() void {
bb0():
  ret
}'
  sig6201ci=$(explainMismatch "$oracle_6201_callins" "$bit2_6201_callins" ir)
  rc6201ci=$?
  if [ "$rc6201ci" -ne 0 ] || [ "$sig6201ci" != "6201-json-schema-generic-wrapper-specialize" ]; then
    echo "FAIL: the real #6201 generic-wrapper call-rename-plus-two-inserts was not explained (rc=$rc6201ci sig='$sig6201ci')"
    fail=1
  fi

  # --- #6201 MUTATION (ir): the forwarder exists but calls a DIFFERENT
  # ident than the one the direct call was renamed to -- must be rejected. ---
  bit2_6201_wrongident='func main() void {
bb0():
  %0 = call @__json_schema_Widget() Json
  ret
}

func __json_schema_Widget() Json {
bb0():
  %0 = const_string "type"
  ret %0
}

func jsonSchema$14() Json {
bb0():
  %0 = call @__json_schema_Other() Json
  ret %0
}

func helper() void {
bb0():
  ret
}'
  sig6201wi=$(explainMismatch "$oracle_6201_callins" "$bit2_6201_wrongident" ir)
  rc6201wi=$?
  if [ "$rc6201wi" -eq 0 ] || [ -n "$sig6201wi" ]; then
    echo "FAIL: a forwarder calling the WRONG ident was wrongly explained (rc=$rc6201wi sig='$sig6201wi')"
    fail=1
  fi

  # --- #6201 MUTATION (ir): the forwarder's own ret references a DIFFERENT
  # SSA id than its own call result -- must be rejected. ---
  bit2_6201_retmismatch='func main() void {
bb0():
  %0 = call @__json_schema_Widget() Json
  ret
}

func __json_schema_Widget() Json {
bb0():
  %0 = const_string "type"
  ret %0
}

func jsonSchema$14() Json {
bb0():
  %0 = call @__json_schema_Widget() Json
  ret %1
}

func helper() void {
bb0():
  ret
}'
  sig6201rm=$(explainMismatch "$oracle_6201_callins" "$bit2_6201_retmismatch" ir)
  rc6201rm=$?
  if [ "$rc6201rm" -eq 0 ] || [ -n "$sig6201rm" ]; then
    echo "FAIL: a forwarder ret referencing the WRONG SSA id was wrongly explained (rc=$rc6201rm sig='$sig6201rm')"
    fail=1
  fi

  # --- #6201 MUTATION (ir): only the specialized body is inserted, no
  # forwarder at all -- this is `6161-json-schema-specialize-call`s shape,
  # not this ones, and must not ALSO satisfy this signature. ---
  sig6201single=$(explainMismatch "$oracle_6201_callins" "$bit2_6161_callins" ir)
  rc6201single=$?
  if [ "$sig6201single" = "6201-json-schema-generic-wrapper-specialize" ]; then
    echo "FAIL: a single-function insert (6161s shape) was wrongly explained as 6201 (rc=$rc6201single sig='$sig6201single')"
    fail=1
  fi

  # --- #6194 POSITIVE (ir/iropt): minimal synthetic dumps matching the
  # measured shape -- pre-opt gains field_get/gc_alloc in a [2x,4x] ratio,
  # post-opt loses ONLY gc_alloc. ---
  oracle_6194_ir='%1 = call @get(%0) Option'
  bit2_6194_ir='%1 = call @get(%0) Option
%2 = field_get %1[0] i64
%3 = field_get %1[8] i64
%4 = gc_alloc size=16 ptrs=[] Option'
  sig6194i=$(explainMismatch "$oracle_6194_ir" "$bit2_6194_ir" ir)
  rc6194i=$?
  if [ "$rc6194i" -ne 0 ] || [ "$sig6194i" != "6194-generic-method-receiver-explode" ]; then
    echo "FAIL: the synthetic #6194 ir divergence was not explained (rc=$rc6194i sig='$sig6194i')"
    fail=1
  fi
  oracle_6194_iropt='%1 = gc_alloc size=16 ptrs=[] Option
%2 = gc_alloc size=16 ptrs=[] Option'
  bit2_6194_iropt='%1 = gc_alloc size=16 ptrs=[] Option'
  sig6194o=$(explainMismatch "$oracle_6194_iropt" "$bit2_6194_iropt" iropt)
  rc6194o=$?
  if [ "$rc6194o" -ne 0 ] || [ "$sig6194o" != "6194-generic-method-receiver-explode" ]; then
    echo "FAIL: the synthetic #6194 iropt divergence was not explained (rc=$rc6194o sig='$sig6194o')"
    fail=1
  fi

  # --- #6194 MUTATION (ir/iropt): a DIFFERENT divergence using the same two
  # opcodes must NOT be swallowed. ir: field_get/gc_alloc both +1 (ratio 1,
  # below the measured floor of 2). iropt: gc_alloc INCREASES instead of
  # decreasing (the direction a real regression would take), and separately,
  # gc_alloc decreases but field_get also moves (not gc_alloc-only). ---
  oracle_6194_ir_mut='%1 = call @get(%0) Option'
  bit2_6194_ir_mut='%1 = call @get(%0) Option
%2 = field_get %1[0] i64
%3 = gc_alloc size=16 ptrs=[] Option'
  sig6194im=$(explainMismatch "$oracle_6194_ir_mut" "$bit2_6194_ir_mut" ir)
  rc6194im=$?
  if [ "$rc6194im" -eq 0 ] || [ -n "$sig6194im" ]; then
    echo "FAIL: an ir delta below the 2x ratio floor was wrongly explained (rc=$rc6194im sig='$sig6194im')"
    fail=1
  fi
  oracle_6194_iropt_mut1='%1 = call @get(%0) Option'
  bit2_6194_iropt_mut1='%1 = call @get(%0) Option
%2 = gc_alloc size=16 ptrs=[] Option'
  sig6194iom1=$(explainMismatch "$oracle_6194_iropt_mut1" "$bit2_6194_iropt_mut1" iropt)
  rc6194iom1=$?
  if [ "$rc6194iom1" -eq 0 ] || [ -n "$sig6194iom1" ]; then
    echo "FAIL: an iropt gc_alloc INCREASE was wrongly explained (rc=$rc6194iom1 sig='$sig6194iom1')"
    fail=1
  fi
  oracle_6194_iropt_mut2='%1 = gc_alloc size=16 ptrs=[] Option
%2 = gc_alloc size=16 ptrs=[] Option
%3 = field_get %1[0] i64'
  bit2_6194_iropt_mut2='%1 = gc_alloc size=16 ptrs=[] Option'
  sig6194iom2=$(explainMismatch "$oracle_6194_iropt_mut2" "$bit2_6194_iropt_mut2" iropt)
  rc6194iom2=$?
  if [ "$rc6194iom2" -eq 0 ] || [ -n "$sig6194iom2" ]; then
    echo "FAIL: an iropt delta that also moved field_get was wrongly explained (rc=$rc6194iom2 sig='$sig6194iom2')"
    fail=1
  fi

  # --- declaredSignatureNames() stays in sync with explainMismatch (#5509) ---
  #
  # The retirement check in scripts/selfhost-diffdump.sh's run_ir() only ever
  # asks declaredSignatureNames() what to look for; it never reads the awk
  # script. A name added to one list and not the other is silent everywhere
  # except here: extra-in-explainMismatch means a signature can fire but is
  # never checked for going dead; extra-in-declaredSignatureNames means a
  # live corpus run always reports it as explaining zero, because nothing
  # can ever print that name, which force-fails every future run with a
  # false "retired" verdict for a name that was never real.
  got=$(declaredSignatureNames | LC_ALL=C sort)
  # Unanchored on purpose (#5510 added `if (...) { print "…"; exit 0 }` on
  # one line, so `print "…"` no longer always starts the line) -- safe
  # against a false match inside `printf` because that is followed by `f`
  # then a SINGLE quote, never `print` immediately followed by a `"`.
  want=$(grep -oE 'print "[0-9]+-[a-z-]+"' "${ROOT}/scripts/selfhost-ir-signatures.sh" |
    grep -oE '"[0-9]+-[a-z-]+"' | tr -d '"' | LC_ALL=C sort -u)
  if [ "$got" != "$want" ]; then
    echo "FAIL: declaredSignatureNames() is out of sync with explainMismatch's print statements"
    echo "  declaredSignatureNames(): $(printf '%s' "$got" | tr '\n' ' ')"
    echo "  print \"…\" in the file:   $(printf '%s' "$want" | tr '\n' ' ')"
    fail=1
  fi

  if [ "$fail" -eq 0 ]; then
    echo "selfhost-ir-signatures-selfcheck.sh: self-check passed"
  fi
  exit "$fail"
fi
