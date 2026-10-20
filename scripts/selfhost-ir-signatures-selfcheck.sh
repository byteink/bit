#!/usr/bin/env bash
# Strict transform controls, discovered by selfhost-diffall.sh's shell glob (#5442).
ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
if [ "${BASH_SOURCE[0]}" = "$0" ] && [ "${1:-}" = --canon-only ]; then
  [ "$#" -eq 1 ] || exit 1
  # shellcheck source=scripts/selfhost-ir-canon.sh
  . "${ROOT}/scripts/selfhost-ir-canon.sh"
# Self-check: run directly (not sourced) to assert canon_ir_ids does its one
# job and nothing else. `bash scripts/selfhost-ir-canon.sh`.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -u
  fail=0

  assert_eq() {
    if [ "$2" != "$3" ]; then
      echo "FAIL: $1"
      echo "  got:  $2"
      echo "  want: $3"
      fail=1
    fi
  }

  # Same structure, different literal $t numbers -> identical canonical text.
  a=$(canon_ir_ids 'func push$t37(%0: Stack) Stack {
  call @size$t37(%1)
}
func other$t41() {}')
  b=$(canon_ir_ids 'func push$t99(%0: Stack) Stack {
  call @size$t99(%1)
}
func other$t12() {}')
  assert_eq "identical structure canonicalizes identically" "$a" "$b"

  # Distinct ids used consistently -> canonical labels in first-appearance order.
  want='func push$c0(%0: Stack) Stack {
  call @size$c0(%1)
}
func other$c1() {}'
  assert_eq "canonical labels are first-appearance order" "$a" "$want"

  # Leaked generic parameter is not a $t<id> and must survive untouched, so the
  # mismatch is still visible after canonicalization.
  c=$(canon_ir_ids 'func push$t37(%0: Stack<T>) Stack {}')
  d=$(canon_ir_ids 'func push$t99(%0: Stack) Stack {}')
  [ "$c" = "$d" ] && { echo "FAIL: leaked <T> was masked by canonicalization"; fail=1; }

  # A different symbol name is not a $t<id> and must still mismatch.
  e=$(canon_ir_ids 'func push$t37() {}')
  f=$(canon_ir_ids 'func pop$t99() {}')
  [ "$e" = "$f" ] && { echo "FAIL: differing symbol name was masked by canonicalization"; fail=1; }

  # Only the $t<id> suffix is touched: no whitespace/other-token normalization.
  g=$(canon_ir_ids '  %38 = call @size$t37(%26)  i64')
  assert_eq "non-\$t tokens and whitespace are untouched" "$g" '  %38 = call @size$c0(%26)  i64'

  # A non-UTF-8 byte in a const_string must not truncate the dump (#6716): both
  # sides keep all 4 lines and a difference after the byte still shows. Forced
  # to a UTF-8 locale, where awk without LC_ALL=C stops at the byte.
  bad=$(printf '  %%1 = const_string "\300A"')
  h=$(LC_ALL=en_US.UTF-8 canon_ir_ids "func f\$t1() {
${bad}
  ret \$t1 x
}")
  i=$(LC_ALL=en_US.UTF-8 canon_ir_ids "func f\$t2() {
${bad}
  ret \$t2 y
}")
  [ "$h" = "$i" ] && { echo "FAIL: a difference after a non-UTF-8 byte was truncated away"; fail=1; }
  assert_eq "non-UTF-8 byte keeps every line" "$(printf '%s\n' "$h" | wc -l | tr -d ' ')" 4

  if [ "$fail" -eq 0 ]; then
    echo "selfhost-ir-canon.sh: self-check passed"
  fi
  exit "$fail"
fi
fi
# shellcheck source=scripts/selfhost-ir-signatures.sh
. "${ROOT}/scripts/selfhost-ir-signatures.sh"
# shellcheck source=scripts/alarmrun.sh
. "${ROOT}/scripts/alarmrun.sh"
# shellcheck source=scripts/selfhost-diffdump-setup.sh
. "${ROOT}/scripts/selfhost-diffdump-setup.sh"
# shellcheck source=scripts/diffexit.sh
. "${ROOT}/scripts/diffexit.sh"
# Unknown deltas and retired identities decline; registry and dispatch must agree.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -u
  fail=0

  oracle_unrelated='%1 = sub %2, %3'
  bit2_unrelated='%1 = sub %2, %3
%4 = sub %5, %6'
  for kind in ir iropt ast fmt types diags tokens doc; do
    sig=$(explainMismatch "$oracle_unrelated" "$bit2_unrelated" "$kind" "_tests_/cases/run_bound_static_amp.bit")
    rc=$?
    if [ "$rc" -eq 0 ] || [ -n "$sig" ]; then
      echo "FAIL: an unrelated $kind delta was wrongly explained (rc=$rc sig='$sig')"
      fail=1
    fi
  done

  expect() { # <want name or ""> <got> <label>
    if [ "$1" != "$2" ]; then
      echo "FAIL: $3: want '$1' got '$2'"
      fail=1
    fi
  }

  expect "" "$(explainMismatch 'kw_in 0..2' 'ident 0..2' tokens)" 'retired token identity'
  for kind in ir iropt ast fmt types diags tokens doc; do
    case "$kind" in ir|iropt) want=6791-fallible-aggregate-words ;; *) want= ;; esac
    expect "$want" "$(declaredSignatureNames "$kind")" "$kind registry"
  done

  /bin/bash "$ROOT/scripts/selfhost-diffiropt.sh" --literal-selfcheck || fail=1
  . "$ROOT/scripts/selfhost-diffdump-setup.sh"
  diffdump_aggregate_fixture_library || exit 1
  python3 - "$ROOT/scripts/selfhost-ir-signatures.sh" "$DIFFDUMP_AGGREGATE_FIXTURES" <<'PYTHON'
import atexit
import base64
import json
import os
import re
import subprocess
import sys
import tempfile
helper = sys.argv[1]
exec(sys.argv[2])
old = b"""func tail$t59(%0: Builder, %1: i64) string {
bb0(%0: Builder, %1: i64):
  %2 = const_int i64 0
  %3 = icmp_slt bool %1, %2
  br %3, bb2(), bb1()
bb1():
  %5 = field_get %0[0] []u8
  %6 = slice_len %5
  %7 = icmp_sgt bool %1, %6
  br %7, bb2(), bb3(%1)
bb2():
  %9 = const_string "literal %13 $t59 \\" \xc0"
  %10 = rt_call panic(%9) void
  unreachable
bb3(%12: i64):
  %13 = rt_call slice_slice(%5, %2, %6) []u8
  %14 = rt_call string_from_byte_range(%13, %12, %6) string
  %15 = field_get %14[0] i64
  %16 = field_get %14[8] i64
  ret %15, %16, %14
}"""
new = old.replace(b"  %13 = rt_call slice_slice(%5, %2, %6) []u8\n", b"")
new = new.replace(b"string_from_byte_range(%13,", b"string_from_byte_range(%5,")
new = new.replace(b"%14", b"%113").replace(b"%15", b"%114").replace(b"%16", b"%115")

# Fixed fixture declarations bind pools; an unknown literal is a broken fixture.
values = [b"\n"]
values += [b'literal ' + i + b' ' + t + b' \\" ' + c
           for i in (b"%13", b"%12") for t in (b"$t59", b"$t60") for c in (b"\xc0", b"\xc1")]
values += [b'literal ' + i + b' ' + t + b' \\" ' + c
           for i in (b"%80", b"%81") for t in (b"$t59", b"$t60") for c in (b"\xc0", b"\xc1")]
values += [b"literal %80 bb360\n  %901 = rt_call slice_append_slice" + suffix +
           b"(%3, %0, %1, %2) []decimal" for suffix in (b"_fresh", b"")]
store = tempfile.TemporaryDirectory(prefix="t8271-signatures-")
atexit.register(store.cleanup)
objects = {}
clean_env = {k: v for k, v in os.environ.items()
             if not k.startswith(("BIT", "LIBBITRT", "DIFFALL", "BOXLOCK"))
             and k not in ("ORACLE", "TIMEOUT_S", "BASH_ENV", "ENV")}
def fixture_object(pool):
    if pool not in objects:
        wrapper = os.path.join(os.path.dirname(helper), "selfhost-diffiropt.sh")
        data = json.dumps([base64.b64encode(x).decode() for x in pool]).encode()
        result = subprocess.run(["/bin/bash", wrapper, "--fixture-object"], input=data,
                                capture_output=True, timeout=10, env=clean_env)
        assert result.returncode == 0 and not result.stderr and result.stdout
        path = os.path.join(store.name, "object-" + str(len(objects)))
        with open(path, "wb") as target:
            assert target.write(result.stdout) == len(result.stdout)
        objects[pool] = path
    return objects[pool]
def verdict(a, b, kind="iropt", path="", pools=None, caps=None, files=None):
    pools = (fixture_pool(a), fixture_pool(b)) if pools is None else pools
    captures = (a, b) if caps is None else caps
    paths = [os.path.join(store.name, "capture-" + str(i)) for i in range(2)]
    for filename, raw in zip(paths, captures):
        with open(filename, "wb") as target:
            assert target.write(raw) == len(raw)
    paths = paths if files is None else files
    command = 'source "$1"; IFS= read -r -d "" a && IFS= read -r -d "" b && explainMismatch "$a" "$b" "$2" "$3" "$4" "$5" "$6" "$7"'
    result = subprocess.run(["/bin/bash", "-c", command, "fixture", helper, kind, path,
                             *(fixture_object(p) for p in pools), *paths],
                            input=a.rstrip(b"\n") + b"\0" + b.rstrip(b"\n") + b"\0",
                            capture_output=True, timeout=10, env=clean_env)
    assert result.stderr == b"", result.stderr
    return result.returncode, result.stdout

expected = (1, b"")
assert verdict(old, new) == expected, "retired single-function identity"
assert verdict(old + b"\n\n" + old.replace(b"func tail", b"func other"),
               new + b"\n\n" + new.replace(b"func tail", b"func other")) == expected
negatives = {
    "slice base": (old.replace(b"slice_slice(%5,", b"slice_slice(%0,"), new),
    "lower bound": (old.replace(b"const_int i64 0", b"const_int i64 1"),
                    new.replace(b"const_int i64 0", b"const_int i64 1")),
    "slice upper bound": (old.replace(b"slice_slice(%5, %2, %6)", b"slice_slice(%5, %2, %1)"), new),
    "reader length": (old, new.replace(b"%12, %6)", b"%12, %1)")),
    "reader lower index": (old, new.replace(b"%12, %6)", b"%2, %6)")),
    "additional copy use": (old.replace(b"  ret %15", b"  ret %13, %15"), new),
    "inserted operation": (old, new.replace(b"  ret %114", b"  %120 = const_int i64 0\n  ret %114")),
    "SSA collapse": (old, new.replace(b"%115", b"%114")),
    "changed literal SSA": (old, new.replace(b"literal %13", b"literal %12")),
    "changed literal type": (old, new.replace(b"literal %13 $t59", b"literal %13 $t60")),
    "changed non-UTF-8 literal": (old, new.replace(b"\xc0", b"\xc1")),
    "same counts": (old, new.replace(b"icmp_sgt", b"icmp_slt")),
    "changed field type": (old.replace(b"%0[0] []u8", b"%0[0] []i8"),
                           new.replace(b"%0[0] []u8", b"%0[0] []i8")),
    "header store": (old.replace(b"bb3(%12: i64):", b"bb3(%12: i64):\n  field_set %5[8] = %2"),
                     new.replace(b"bb3(%12: i64):", b"bb3(%12: i64):\n  field_set %5[8] = %2")),
    "unknown operation": (old.replace(b"bb3(%12: i64):", b"bb3(%12: i64):\n  store %5"),
                          new.replace(b"bb3(%12: i64):", b"bb3(%12: i64):\n  store %5")),
    "join predecessor": (old.replace(b"br %3, bb2(), bb1()", b"br %3, bb3(%1), bb1()"),
                         new.replace(b"br %3, bb2(), bb1()", b"br %3, bb3(%1), bb1()")),
    "entry backedge": (old.replace(b"  unreachable", b"  jump bb0(%0, %1)"),
                       new.replace(b"  unreachable", b"  jump bb0(%0, %1)")),
    "unknown terminator": (old.replace(b"  unreachable", b"  unknown_term"),
                           new.replace(b"  unreachable", b"  unknown_term")),
    "type IDs exact": (old, new.replace(b"tail$t59", b"tail$t60")),
    "unknown call": (old.replace(b"bb3(%12: i64):", b"bb3(%12: i64):\n  %30 = rt_call mutate(%5) void"),
                     new.replace(b"bb3(%12: i64):", b"bb3(%12: i64):\n  %30 = rt_call mutate(%5) void")),
    "outside function": (old + b"\nmodule %10", new + b"\nmodule %11"),
    "separated reader": (old.replace(b"  %14 = rt_call", b"\n  %14 = rt_call"), new),
    "no transform": (new, new),
}
symbol = b"\nfunc helper%80() void {\nbb0():\n  ret\n}"
negatives.update({
    "function symbol": (old + symbol, new + symbol.replace(b"helper%80", b"helper%81")),
    "percent-leading function": (old + symbol.replace(b"helper%80", b"%80"),
                                 new + symbol.replace(b"helper%80", b"%81")),
    "callee symbol": (old + symbol.replace(b"  ret", b"  %0 = call @callee%80() void\n  ret"),
                      new + symbol.replace(b"  ret", b"  %0 = call @callee%81() void\n  ret")),
    "type symbol": (old + symbol.replace(b"() void", b"(%0: Type%80) void"),
                    new + symbol.replace(b"() void", b"(%0: Type%81) void")),
    "local symbol": (old + symbol.replace(b"  ret", b"  %0 = field_get %1[local%80] i64\n  ret"),
                     new + symbol.replace(b"  ret", b"  %0 = field_get %1[local%81] i64\n  ret")),
    "numeric adjacency": (old + symbol.replace(b"  ret", b"  %0 = const_int i64 1%80\n  ret"),
                          new + symbol.replace(b"  ret", b"  %0 = const_int i64 1%81\n  ret")),
    "trailing identifier": (old + symbol.replace(b"  ret", b"  %0 = ret %80foo\n  ret"),
                            new + symbol.replace(b"  ret", b"  %0 = ret %81foo\n  ret")),
})
for name, pair in negatives.items():
    assert verdict(*pair) == (1, b""), name
for kind in ("ir", "types", "ast", "fmt", "diags", "tokens", "doc"):
    assert verdict(old, new, kind) == (1, b""), kind
print("retired 8259 signature: 2 former-positive, 30 negative, 7 kind controls rejected")
local = br'''func owned(%0: []i64) []i64 {
bb0(%0: []i64):
  %1 = const_int i64 0
  %2 = const_int i64 8
  %3 = rt_call slice_new(%1, %2, %1, %2) []i64
  %4 = rt_call slice_append_slice_fresh(%3, %0, %1, %2) []i64
  ret %4
}
'''
ancestor = local.replace(b"func owned", b"func ancestor").replace(b") []i64 {", b") i64 {", 1)
ancestor = ancestor.replace(b"  ret %4\n", b"  %5 = rt_call slice_append_slice_fresh(%4, %3, %1, %2) []i64\n"
                            b"  %6 = slice_len %5\n  ret %6\n")
loop = br'''func ownedLoop(%0: []i64, %1: i64) void {
bb0(%0: []i64, %1: i64):
  %2 = const_int i64 0
  %3 = icmp_sgt bool %1, %2
  br %3, bb1(), bb2(%0)
bb1():
  %5 = const_int i64 1
  %6 = sub i64 %1, %5
  %7 = call @ownedLoop(%0, %6) void
  ret
bb2(%9: []i64):
  %10 = const_int i64 16
  %11 = const_int i64 8
  %12 = rt_call slice_new(%2, %10, %2, %11) []i64
  jump bb3(%9, %12, %2)
bb3(%14: []i64, %15: []i64, %16: i64):
  %17 = const_int i64 3
  %18 = icmp_slt bool %16, %17
  br %18, bb4(), bb5(%15)
bb4():
  %20 = const_int i64 0
  %21 = const_int i64 8
  %22 = rt_call slice_append_slice_fresh(%15, %14, %20, %21) []i64
  %23 = const_int i64 1
  %24 = add i64 %16, %23
  jump bb3(%14, %22, %24)
bb5(%26: []i64):
  %27 = slice_len %26
  ret
}
'''
recursive_prefix = loop.split(b'  jump bb3(%9, %12, %2)\n', 1)[0]
mixed = recursive_prefix.replace(b'ownedLoop', b'mixedOwned') + br'''  %13 = const_int i64 1
  %14 = slice_len %12
  %15 = field_get %12[24] i64
  %16 = icmp_slt bool %14, %15
  br %16, bb3(), bb4()
bb3():
  %18 = field_get %12[0] i64
  index_set %18[%14] = %13
  %20 = add i64 %14, %13
  field_set %12[8] = %20
  jump bb5(%12)
bb4():
  %23 = rt_call slice_append(%12, %13, %2, %11) []i64
  jump bb5(%23)
bb5(%25: []i64):
  %26 = rt_call slice_append_slice_fresh(%25, %9, %2, %11) []i64
  %27 = const_int i64 9
  %28 = rt_call slice_append_fresh(%26, %27, %2, %11) []i64
  %29 = const_string "
"
  %44 = slice_len %28
  %45 = sub i64 %44, %13
  %46 = icmp_ult bool %45, %44
  br %46, bb9(), bb8()
bb8():
  unreachable
bb9():
  %51 = field_get %28[0] i64
  %52 = index_get %51[%45] i64
  ret
}
'''
mixed_tail = b"  %29 = const_string" + mixed.split(b"  %29 = const_string", 1)[1]
for before, after in [(b"%29", b"%41"), (b"%28", b"%40"), (b"%44", b"%56"), (b"%45", b"%57"),
                      (b"%46", b"%58"), (b"%51", b"%63"), (b"%52", b"%64"), (b"bb8", b"bb11"), (b"bb9", b"bb12")]:
    mixed_tail = mixed_tail.replace(before, after)
mixed_fixed = mixed.split(b'bb5(%25: []i64):\n', 1)[0] + br'''bb5(%25: []i64):
  %26 = rt_call slice_append_slice(%25, %9, %2, %11) []i64
  %27 = const_int i64 9
  %28 = slice_len %26
  %29 = field_get %26[24] i64
  %30 = icmp_slt bool %28, %29
  br %30, bb6(), bb7()
bb6():
  %32 = field_get %26[0] i64
  index_set %32[%28] = %27
  %34 = const_int i64 1
  %35 = add i64 %28, %34
  field_set %26[8] = %35
  jump bb8(%26)
bb7():
  %38 = rt_call slice_append(%26, %27, %2, %11) []i64
  jump bb8(%38)
bb8(%40: []i64):
''' + mixed_tail
snapshot = recursive_prefix.replace(b'ownedLoop', b'snapshotLoop') + br'''  %13 = const_nil
  jump bb3(%9, %12, %13, %2)
bb3(%15: []i64, %16: []i64, %17: []i64, %18: i64):
  %19 = const_int i64 3
  %20 = icmp_slt bool %18, %19
  br %20, bb4(), bb7(%16, %17)
bb4():
  %22 = const_int i64 0
  %23 = const_int i64 8
  %24 = rt_call slice_append_slice_fresh(%16, %15, %22, %23) []i64
  %25 = icmp_eq bool %18, %22
  br %25, bb5(), bb6(%15, %24, %17, %18)
bb5():
  jump bb6(%15, %24, %24, %18)
bb6(%28: []i64, %29: []i64, %30: []i64, %31: i64):
  %32 = const_int i64 1
  %33 = add i64 %31, %32
  jump bb3(%28, %29, %30, %33)
bb7(%35: []i64, %36: []i64):
  %37 = slice_len %36
  %38 = slice_len %35
  ret
}
'''
field = br'''func put(%0: Bulk, %1: []i64, %2: i64) void {
bb0(%0: Bulk, %1: []i64, %2: i64):
  %3 = const_int i64 0
  %4 = icmp_eq bool %2, %3
  br %4, bb1(), bb2(%0, %1, %2)
bb1():
  %6 = const_int i64 8
  %7 = field_get %0[0] []i64
  %8 = rt_call slice_append_slice_fresh(%7, %1, %3, %6) []i64
  field_set %0[0] = %8
  ret
bb2(%11: Bulk, %12: []i64, %13: i64):
  %14 = const_int i64 1
  %15 = sub i64 %13, %14
  %16 = call @put(%11, %12, %15) void
  ret
}
'''
local_fixed = local.replace(b"slice_append_slice_fresh", b"slice_append_slice")
loop_fixed = loop.replace(b"slice_append_slice_fresh", b"slice_append_slice")
snapshot_bad = snapshot.replace(b"slice_append_slice_fresh", b"slice_append_slice")
field_bad = field.replace(b"slice_append_slice_fresh", b"slice_append_slice")
def expect_case(label, a, b, kind="iropt"):
    expected = (1, b"")  # Former accepted shapes are retirement controls.
    assert verdict(a, b, kind) == expected, label
def change_both(a, b, before, after):
    assert before in a and before in b
    return a.replace(before, after), b.replace(before, after)
for label, a, b in [("retained local", local, local_fixed),
                    ("retained recursive loop", loop, loop_fixed),
                    ("retained mixed scalar island", mixed, mixed_fixed)]:
    expect_case(label, a, b)
bulk = br'''func bulk() []TYPE {
bb0():
  %0 = const_int i64 0
  %1 = const_int i64 8
  %2 = const_int i64 REFS
  %3 = const_int i64 STRIDE
  %4 = rt_call slice_new(%0, %1, %2, %3) []TYPE
  %5 = rt_call slice_new(%0, %1, %2, %3) []TYPE
  %6 = rt_call slice_append_slice_fresh(%4, %5, %2, %3) []TYPE
  ret %6
}
'''
for typ, refs, stride in [(b"i64", b"0", b"8"), (b"string", b"1", b"8"), (b"u8", b"0", b"1"),
                          (b"Pair", b"1", b"8"), (b"map<string, i64>", b"1", b"8")]:
    a = bulk.replace(b"TYPE", typ).replace(b"REFS", refs).replace(b"STRIDE", stride)
    b = a.replace(b"slice_append_slice_fresh", b"slice_append_slice")
    expect_case("coherent bulk " + typ.decode(), a, b)
    expect_case("bulk argument swap", a, b.replace(b"(%4, %5, %2, %3)", b"(%4, %5, %3, %2)"))
    other = b"u8" if typ != b"u8" else b"i64"
    expect_case("bulk result type mismatch", a, b.replace(b") []" + typ + b"\n  ret", b") []" + other + b"\n  ret"))
nil_base = bulk.replace(b"TYPE", b"i64").replace(b"REFS", b"0").replace(b"STRIDE", b"8")
for value in (b"%4", b"%5"):
    a = nil_base.replace(value + b" = rt_call slice_new(%0, %1, %2, %3) []i64", value + b" = const_nil")
    expect_case("known nil " + value.decode(), a, a.replace(b"slice_append_slice_fresh", b"slice_append_slice"))
fresh_row = b"  %4 = rt_call slice_new(%0, %1, %2, %3) []i64\n"
renew_entry = b"  %90 = const_int i64 0\n  jump bb1(%90)\nbb1(%7: i64):\n"
renew_tail = (b"  %8 = call @observe(%6) void\n  %9 = const_int i64 1\n"
              b"  %10 = add i64 %7, %9\n  %11 = const_int i64 2\n"
              b"  %12 = icmp_slt bool %10, %11\n  br %12, bb1(%10), bb2()\nbb2():\n  ret\n")
renew = nil_base.replace(b"func bulk() []i64", b"func renewed() void").replace(fresh_row, renew_entry + fresh_row)
renew = renew.replace(b"  ret %6\n", renew_tail)
renew_fixed = renew.replace(b"slice_append_slice_fresh", b"slice_append_slice")
expect_case("iteration fresh receiver then escape", renew, renew_fixed)
hoisted = renew.replace(fresh_row, b"").replace(renew_entry, fresh_row + renew_entry)
expect_case("hoisted shared receiver", hoisted, hoisted.replace(b"slice_append_slice_fresh", b"slice_append_slice"))
expect_case("same iteration prior escape", *change_both(renew, renew_fixed,
    b"  %6 = rt_call", b"  %13 = call @observe(%4) void\n  %6 = rt_call"))
expect_case("old receiver live after append", *change_both(renew, renew_fixed,
    b"  %8 = call", b"  %13 = slice_len %4\n  %8 = call"))
u8 = mixed.split(b"bb5(%25: []i64):\n", 1)[0].replace(b"[]i64", b"[]u8")
u8 = u8.replace(b"%11 = const_int i64 8", b"%11 = const_int i64 1")
u8 = u8.replace(b"  %14 = slice_len", b"  %53 = convert u8 %13\n  %14 = slice_len")
u8 = u8.replace(b"] = %13", b"] = %53").replace(b"(%12, %13,", b"(%12, %53,")
u8 += b"bb5(%25: []u8):\n  %26 = rt_call slice_append_slice_fresh(%25, %9, %2, %11) []u8\n  ret\n}\n"
expect_case("mutated u8 receiver stays declined", u8, u8.replace(b"slice_append_slice_fresh", b"slice_append_slice"))
u8 = u8.replace(b"  %26 = ", b"  %54 = rt_call slice_new(%2, %10, %2, %11) []u8\n  %26 = ").replace(b"(%25, %9,", b"(%54, %25,")
u8_fixed = u8.replace(b"slice_append_slice_fresh", b"slice_append_slice")
expect_case("unchanged u8 capacity island", u8, u8_fixed)
expect_case("changed u8 fast store", u8, u8_fixed.replace(b"index_set %18[%14] = %53", b"index_set %18[%14] = %13"))
renamed = re.sub(rb"%([0-9]+)", lambda m: b"%" + str(int(m[1]) + 100).encode(), local_fixed)
expect_case("bijective SSA rename", local, renamed)
loop_renamed = re.sub(rb"bb([0-9]+)", lambda m: b"bb" + str(int(m[1]) + 30).encode(), loop_fixed)
expect_case("bijective block rename", loop, loop_renamed)
def nil_wide(src, typ=b"decimal", stride=b"16"):
    return src.replace(b"rt_call slice_new(%1, %2, %1, %2) []i64", b"const_nil").replace(
        b"[]i64", b"[]" + typ).replace(b"const_int i64 8", b"const_int i64 " + stride)
bridge = b"  jump bb360()\nbb360():\n  jump bb362()\nbb362():\n  jump bb364()\nbb364():\n"
nil_chain = nil_wide(ancestor.replace(b"(%4, %3,", b"(%4, %0,"))
nil_chain = nil_chain.replace(b"  %3 = const_nil", bridge + b"  %3 = const_nil")
nil_fixed = nil_chain.replace(b"slice_append_slice_fresh", b"slice_append_slice")
literal = b'  %90 = const_string "literal %80 bb360\n  %901 = rt_call slice_append_slice_fresh(%3, %0, %1, %2) []decimal"\n'
expect_case("nil quoted rows unchanged", nil_chain.replace(b"  %3 =", literal + b"  %3 ="), nil_fixed.replace(b"  %3 =", literal + b"  %3 ="))
expect_case("nil quoted callee mutation", nil_chain.replace(b"  %3 =", literal + b"  %3 ="), nil_fixed.replace(b"  %3 =", literal.replace(b"_fresh", b"") + b"  %3 ="))
# Decoded quotes can imitate a complete valid chain inside one actual string.
embedded = (b'"\n  %900 = const_int i64 0\n  %901 = const_int i64 16\n'
            b'  %902 = rt_call slice_new(%900, %900, %900, %901) []decimal\n'
            b'  %903 = const_nil\n  %904 = rt_call slice_append_slice_fresh(%903, %902, %900, %901) []decimal\n'
            b'  %905 = rt_call slice_append_slice_fresh(%904, %902, %900, %901) []decimal\n  %906 = const_string "')
changed = embedded.replace(b"slice_append_slice_fresh", b"slice_append_slice")
string_dump = b'func strings() void {\nbb0():\n  %0 = const_string "'
quoted_old = string_dump + embedded + b'"\n  ret\n}\n'
quoted_new = string_dump + changed + b'"\n  ret\n}\n'
assert verdict(quoted_old, quoted_new, pools=((embedded,), (changed,))) == (1, b"")
assert verdict(local + quoted_old, local_fixed + quoted_new,
               pools=((embedded,), (changed,))) == (1, b"")
assert verdict(local, local_fixed, caps=(local + b"changed", local_fixed)) == (1, b"")
literal_old = nil_chain.replace(b"  %3 =", literal + b"  %3 =")
literal_new = nil_fixed.replace(b"  %3 =", literal + b"  %3 =")
assert verdict(literal_old, literal_new, pools=((), fixture_pool(literal_new))) == (1, b"")
assert verdict(local, local_fixed, pools=((b"unused witness value",), ())) == (1, b"")
nul_dump = string_dump + b'a\0b"\n  ret\n}\n'
assert verdict(local + nul_dump.replace(b"\0", b""), local_fixed + nul_dump.replace(b"\0", b""),
               pools=((b"a\0b",), (b"a\0b",)), caps=(local + nul_dump, local_fixed + nul_dump)) == (1, b"")
assert verdict(local, local_fixed, caps=(local + b"\n\n", local_fixed + b"\n\n")) == (1, b"")
assert verdict(local, local_fixed, files=(os.path.join(store.name, "capture-0"),
               os.path.join(store.name, "absent"))) == (1, b"")
with open(os.path.join(os.path.dirname(helper), "selfhost-diffdump.sh"), encoding="utf8") as source:
    driver = source.read()
driver = "run_ir() {\n" + driver.split("run_ir() {\n", 1)[1].split('\ncase "$KIND" in', 1)[0]
mocks = b'''MOCK_RC=$1 MOCK_SIG=$2
NAME=iropt LABEL=IR PREFIX=mock VERB=post SKIPLABEL=mock CORPUS=mock ORACLE=oracle BIT2=current FLAG=mock
find() { printf 'fixture.bit\n'; }
alarmrun_retry_cap() { printf '%s\n' "$1" > "$3"; }
classify_rc() { echo ok; }
diffiropt_capture_text() { return 3; }
oracle_ir_coverage() { echo ok; }
ir_mismatch_signature() { printf '%s\n' "$MOCK_SIG"; return "$MOCK_RC"; }
declaredSignatureNames() { :; }
'''
for code, token in [(1, "canonical-ir-match"), (1, "6175-owned-append-local"), (0, "6175-owned-append-local"),
                     (0, "unknown-success-token"), (2, "canonical-ir-match")]:
    result = subprocess.run(["/bin/bash", "-s", "--", str(code), token],
                            input=mocks + driver.encode() + b"\nrun_ir\n", capture_output=True, timeout=10, env=clean_env)
    assert result.returncode == 1 and b"IR differential: MATCH=0 " in result.stdout and b"EXPLAINED=0 " in result.stdout
    assert b"INVALID: compared 0 files" in result.stderr
for typ, stride in [(b"decimal", b"16"), (b"Wide", b"24")]:
    a = nil_chain.replace(b"[]decimal", b"[]" + typ).replace(b"const_int i64 16", b"const_int i64 " + stride)
    expect_case("nil chain width " + stride.decode(), a, a.replace(b"slice_append_slice_fresh", b"slice_append_slice"))
unrelated = b"".join(b"bb" + str(i).encode() + b"():\n  unreachable\n" for i in range(1000, 1427))
expect_case("nil chain in 431-block function", nil_chain[:-2] + unrelated + b"}\n",
            nil_fixed[:-2] + unrelated + b"}\n")
bypass = nil_chain.replace(b"  %2 = const_int i64 16\n", b"").replace(b"bb362():", b"bb362():\n  %2 = const_int i64 16")
bypass = bypass.replace(b"  jump bb360()", b"  %90 = icmp_eq bool %1, %1\n  br %90, bb360(), bb364()")
entry_bypass = b"func entryBackedge() i64 {\nbb0():\n  jump bb364()\nbb360():\n"
entry_bypass += b"  %1 = const_int i64 0\n  %2 = const_int i64 16\n  %91 = rt_call slice_new(%1, %2, %1, %2) []decimal\n  jump bb0()\nbb364():\n"
entry_bypass += nil_chain.split(b"bb364():\n", 1)[1].replace(b", %0,", b", %91,").replace(b"  ret %6", b"  jump bb360()")
negative = {
    "nil opaque target-bearing op": change_both(nil_chain, nil_fixed, b"  %3 = const_nil", b"  opaque_edge bb360\n  %3 = const_nil"),
    "nil implicit entry bypass": (entry_bypass, entry_bypass.replace(b"slice_append_slice_fresh", b"slice_append_slice")),
    "nil final backedge phi": tuple(x.replace(b"bb364():", b"bb364(%99: []decimal):").replace(
        b"jump bb364()", b"jump bb364(%0)").replace(b"  ret %6", b"  jump bb364(%5)") for x in (nil_chain, nil_fixed)),
    "nil source type": change_both(nil_chain, nil_fixed, b"%0: []decimal", b"%0: []u8"),
    "nil reference metadata": change_both(nil_chain, nil_fixed, b"const_int i64 0", b"const_int i64 1"),
    "nil old-header store": change_both(nil_chain, nil_fixed, b"  %4 = rt_call", b"  field_set %3[8] = %1\n  %4 = rt_call"),
    "nil final predefinition": change_both(nil_chain, nil_fixed, b"  %3 = const_nil", b"  %90 = slice_len %5\n  %3 = const_nil"),
    "nil unknown target": change_both(nil_chain, nil_fixed, b"jump bb364()", b"jump bb999()"),
    "nil branch arity": change_both(nil_chain, nil_fixed, b"jump bb364()", b"jump bb364(%0)"),
    "nil dominance bypass": (bypass, bypass.replace(b"slice_append_slice_fresh", b"slice_append_slice")),
    "unchanged text is no signature": (local_fixed, local_fixed),
    "reverse target direction": (local_fixed, local),
    "field ownership is not local": (field, field_bad),
    "loop-carried snapshot": (snapshot, snapshot_bad),
    "earlier result used as later source": (ancestor, ancestor.replace(b"slice_append_slice_fresh", b"slice_append_slice", 1)),
    "live original header": change_both(local, local_fixed, b"  ret %4",
        b"  %5 = slice_len %3\n  ret %5"),
    "parameter receiver": change_both(local, local_fixed, b"(%3, %0,", b"(%0, %3,"),
    "receiver also spread source": change_both(local, local_fixed, b"(%3, %0,", b"(%3, %3,"),
    "call result is not fresh": change_both(local, local_fixed,
        b"rt_call slice_new(%1, %2, %1, %2)", b"call @supply()"),
    "earlier escaping call": change_both(local, local_fixed, b"  %4 = rt_call",
        b"  %5 = call @capture(%3) void\n  %4 = rt_call"),
    "indirect capture": change_both(local, local_fixed, b"  %4 = rt_call",
        b"  %5 = call_value %0(%3) void\n  %4 = rt_call"),
    "heap escape": change_both(local, local_fixed, b"  %4 = rt_call",
        b"  %5 = rt_call map_set(%0, %3) void\n  %4 = rt_call"),
    "unknown operation": change_both(local, local_fixed, b"  %4 = rt_call",
        b"  %5 = unknown %3\n  %4 = rt_call"),
    "phi arity": (loop, loop_fixed.replace(b"jump bb3(%9, %12, %2)", b"jump bb3(%9, %12)")),
    "loop retains old header": change_both(loop, loop_fixed,
        b"jump bb3(%14, %22, %24)", b"jump bb3(%14, %15, %24)"),
    "undefined operand": (local, local_fixed.replace(b"(%3, %0,", b"(%99, %0,")),
    "SSA collision": (local, local_fixed.replace(b"%4", b"%3")),
    "wrong result": (local, local_fixed.replace(b"ret %4", b"ret %3")),
    "wrong bulk target": (local, local_fixed.replace(b"slice_append_slice(", b"slice_append(")),
    "wrong stride": (local, local_fixed.replace(b"const_int i64 8", b"const_int i64 4")),
    "unrelated constant": (local, local_fixed.replace(b"const_int i64 0", b"const_int i64 1")),
    "new instruction": (local, local_fixed.replace(b"  ret %4", b"  %5 = const_int i64 1\n  ret %4")),
    "extra module bytes": (local + b"module stable\n", local_fixed + b"module changed\n"),
    "scalar capacity comparison": (mixed, mixed_fixed.replace(b"icmp_slt bool %28, %29", b"icmp_sgt bool %28, %29")),
    "scalar length write": (mixed, mixed_fixed.replace(b"field_set %26[8] = %35", b"field_set %26[24] = %35")),
    "scalar value store": (mixed, mixed_fixed.replace(b"index_set %32[%28] = %27", b"index_set %32[%28] = %2")),
    "scalar grow operand": (mixed, mixed_fixed.replace(b"slice_append(%26, %27,", b"slice_append(%26, %2,")),
    "scalar merge operand": (mixed, mixed_fixed.replace(b"jump bb8(%38)", b"jump bb8(%26)")),
}
a, b = negative["live original header"]  # Keep the observable mutation well typed.
negative["live original header"] = (a.replace(b") []i64 {", b") i64 {", 1),
                                    b.replace(b") []i64 {", b") i64 {", 1))
heap_old, heap_new = change_both(local, local_fixed, b"%0: []i64)", b"%0: []i64, %5: Holder)")
negative["field store escapes header"] = change_both(heap_old, heap_new, b"  %4 = rt_call",
    b"  field_set %5[0] = %3\n  %4 = rt_call")
negative["malformed SSA token"] = (local, local_fixed.replace(b"%4", b"%4x"))
negative["trailing call comma"] = change_both(local, local_fixed, b"%1, %2)", b"%1, %2,)")
negative["trailing branch comma"] = change_both(loop, loop_fixed, b"jump bb3(%9, %12, %2)", b"jump bb3(%9, %12, %2,)")
negative["slice_len requires identifier"] = change_both(local, local_fixed, b"  %4 = rt_call", b"  %5 = slice_len 0\n  %4 = rt_call")
negative["callee requires symbol"] = change_both(local, local_fixed, b"  %4 = rt_call", b'  %5 = call "quoted"() i64\n  %4 = rt_call')
negative["duplicate block label"] = (loop, loop_fixed.replace(b"bb5(%26: []i64):", b"bb0(%26: []i64):"))
late_old, late_new = change_both(local, local_fixed, b"  %1 = const_int i64 0\n", b"")
negative["use before definition"] = change_both(late_old, late_new, b"  ret %4",
    b"  %1 = const_int i64 0\n  ret %4")
typed_old, typed_new = change_both(local, local_fixed, b"%0: []i64)", b"%0: []i64, %5: bb80)")  # bbN stays a type.
typed_new = re.sub(rb"bb([0-9]+)(?=\()", lambda m: b"bb" + str(int(m[1]) + 30).encode(), typed_new)
expect_case("opaque bbN type with renamed graph", typed_old, typed_new.replace(b": bb80", b": bb81"))
for label, pair in negative.items():
    expect_case(label, *pair)
    if pair[0].startswith(b"func owned("):
        expect_case("wide nil " + label, nil_wide(pair[0]), nil_wide(pair[1]))
opaque = b'\nfunc helper%80() void {\nbb0():\n  %0 = const_string "literal %80 $t59 \\\" \xc0"\n  ret\n}\n'
expect_case("unchanged opaque literal", local + opaque, local_fixed + opaque)
for label, before, after in [("literal SSA", b"literal %80", b"literal %81"),
                             ("literal type", b"$t59", b"$t60"),
                             ("literal nonutf8", b"\xc0", b"\xc1"),
                             ("opaque function symbol", b"helper%80", b"helper%81")]:
    expect_case(label, local + opaque, local_fixed + opaque.replace(before, after))
    expect_case("nil " + label, nil_chain + opaque, nil_fixed + opaque.replace(before, after))
numbers = b"  %5 = const_int i64 -12345\n  %6 = const_int i64 987654\n"
numbers += b"  %7 = field_get %3[16] i64\n  %8 = field_get %3[24] i64\n"
numeric_old, numeric_new = change_both(local, local_fixed, b"  %4 = rt_call", numbers + b"  %4 = rt_call")
expect_case("signed and multi-digit constants and offsets", numeric_old, numeric_new)
for label, before, after in [("changed negative literal", b"-12345", b"-12346"),
                             ("changed multi-digit literal", b"987654", b"987655"),
                             ("changed offset literal", b"%3[16]", b"%3[24]")]:
    expect_case(label, numeric_old, numeric_new.replace(before, after))
expect_case("negative header offset unsupported", *change_both(numeric_old, numeric_new,
    b"%3[16]", b"%3[-16]"))
expect_case("numeric SSA adjacency stays opaque", numeric_old.replace(b"-12345", b"1%80"),
            numeric_new.replace(b"-12345", b"1%81"))
chain = b"".join(b"bb" + str(i).encode() + b"():\n  jump bb" + str(i + 1).encode() + b"()\n"
                 for i in range(256))
chain = chain.replace(b"bb0():", b"bb0(%0: []i64):", 1)
chain += b"bb256():\n" + local.split(b"bb0(%0: []i64):\n", 1)[1]
chain = local.split(b"\nbb0", 1)[0] + b"\n" + chain
expect_case("257 blocks", chain, chain.replace(b"slice_append_slice_fresh", b"slice_append_slice"))
long_nil = nil_wide(chain.replace(b"bb256():", b"bb256():\n  jump bb257()\nbb257():"))
expect_case("nil predecessor certificate bound", long_nil, long_nil.replace(b"slice_append_slice_fresh", b"slice_append_slice"))
constants = b"".join(b"  %" + str(i).encode() + b" = const_int i64 0\n" for i in range(5, 4097))
large_old = local.replace(b"  %4 = rt_call", constants + b"  %4 = rt_call")
large_new = local_fixed.replace(b"  %4 = rt_call", constants + b"  %4 = rt_call")
expect_case("4097 instructions", large_old, large_new)
extras = b"".join(b"func extra" + str(i).encode() + b"() void {\nbb0():\n  ret\n}\n" for i in range(8192))
expect_case("8193 function chunks", local + extras, local_fixed + extras)
half = 4 * 1024 * 1024
expect_case("combined byte bound", local + b" " * (half - len(local)),
            local_fixed + b" " * (half - len(local_fixed) + 1))
for kind in ("ir", "types", "ast", "fmt", "diags", "tokens", "doc"):
    expect_case(kind, local, local_fixed, kind=kind)
print("retired 6175 identity: local/loop/mixed cases and strict refusals passed")
field_main = local.replace(b"func owned(%0: []i64) []i64", b"func main() void")
field_main = field_main.replace(b"bb0(%0: []i64):", b"bb0():\n  %0 = gc_alloc size=8 ptrs=[%0] Bulk")
field_main = field_main.replace(b"  %4 = rt_call slice_append_slice_fresh(%3, %0, %1, %2) []i64\n",
    b"  field_set %0[0] = %3\n  %5 = rt_call slice_new(%1, %2, %1, %2) []i64\n"
    b"  %6 = const_int i64 2\n  %7 = call @put(%0, %5, %6) void\n").replace(b"  ret %4", b"  ret")
field_source = br'''class Bulk { items: []int }
fn put(h: Bulk, src: []int, depth: int) {
  if (depth == 0) {
    h.items = append(h.items, ...src)
    return
  }
  put(h, src, depth - 1)
}
fn main() {
  let h = Bulk{ items = []int(0, 8) }
  put(h, [1, 2], 2)
  assert(len(h.items) == 2)
}
'''
def field_check(src, body=field, main=field_main):
    old = body + b"\n" + main
    new = old.replace(b"slice_append_slice_fresh", b"slice_append_slice").replace(b"slice_append_fresh", b"slice_append")
    with tempfile.TemporaryDirectory(prefix="t6175-field-") as folder:
        path = os.path.join(folder, "private.bit")
        with open(path, "wb") as target:
            assert target.write(src) == len(src)
        assert verdict(old, new, path=path) == (1, b"")
field_check(field_source)
field_check(b'import { now } from "std/time"\n' + field_source)
for before, after in [(b"class Bulk", b"pub class Bulk"), (b"fn put(", b"pub fn put("),
                      (b"class Bulk { items: []int }", b"class Bulk { items: []int\nfn hidden() {} }"),
                      (b"put(h, src, depth - 1)", b"let callback = put\n  callback(h, src, depth - 1)")]:
    field_check(field_source.replace(before, after))
for extra in [b"let hidden = 1\n", b'import { put } from "other"\n', b"@hidden\n",
              b"fn hidden(h: Bulk) { put(h, []int(0, 8), 0) }\n", b'fn hidden() { let text = "${put()}" }\n']:
    field_check(extra + field_source)
seed = b"  field_set %0[0] = %3\n"
for main in [field_main.replace(seed, b""),
             field_main.replace(b"gc_alloc size=8 ptrs=[%0] Bulk", b"call @supply() Bulk"),
             field_main.replace(b"  %7 = call", b"  %8 = rt_call blackbox(%0) void\n  %7 = call"),
             field_main.replace(b"@put(%0, %5,", b"@put(%0, %3,"),
             field_main.replace(seed, seed + b"  field_set %0[0] = %1\n"),
             field_main.replace(seed, seed + b"  %8 = field_get %0[0] i64\n  %9 = rt_call blackbox(%8) void\n"),
             field_main.replace(b"ptrs=[%0]", b"ptrs=[%16]"),
             field_main.replace(b"  %0 = gc_alloc", b"  %50 = gc_alloc")]:
    field_check(field_source, main=main)
saved = field_main.replace(b"  %7 = call", b"  %8 = field_get %0[0] []i64\n  %7 = call")
field_check(field_source, main=saved.replace(b"  ret\n", b"  %9 = slice_len %8\n  ret\n"))
renamed = field_main.replace(b"  %0 = gc_alloc", b"  %50 = gc_alloc").replace(b"field_set %0[", b"field_set %50[").replace(b"@put(%0,", b"@put(%50,")
field_check(field_source, main=renamed)
scalar = b"  %9 = const_int i64 1\n  %10 = rt_call slice_append_fresh(%7, %9, %3, %6) []i64\n  field_set %0[0] = %10\n"
mixed_field = field.replace(b"  %8 = rt_call", scalar + b"  %8 = rt_call").replace(b"slice_append_slice_fresh(%7,", b"slice_append_slice_fresh(%10,")
field_check(field_source.replace(b"    h.items =", b"    h.items = append(h.items, 1)\n    h.items ="), body=mixed_field)
print("retired 6175 identity: field/scalar/bulk cases and strict refusals passed")
aggregate_fixture_controls(verdict, objects, store)
PYTHON
  rc=$?
  [ "$rc" -eq 0 ] || fail=1
  # #7931: the shared IR probe must distinguish unsupported lowering from
  # absent tools, failed execution, stale objects and unrelated diagnostics.
  probe_dir=$(mktemp -d "${TMPDIR:-/tmp}/t7931-probe.XXXXXX") || exit 2
  trap 'rm -rf "${probe_dir:?}"' EXIT
  ORACLE="$probe_dir/compiler"
  TIMEOUT=300
  cat > "$ORACLE" <<'PROBE'
#!/usr/bin/env bash
source=$2
refusal() {
  printf 'bit: %s: refusing to emit an object\n' "$source"
  printf 'error[E0092]: unsupported lowering\n --> %s:1:1\n  |\n1 | source\n  | ^\n' "$source"
}
if [ "$1" = check ]; then
  case "$PROBE_CASE" in
    check-decline) echo 'error[E0053]: rejected'; exit 1 ;;
    check-panic) echo 'panic: failed'; exit 2 ;;
    check-timeout) exit 142 ;;
    check-signal) kill -TERM "$$" ;;
    check-127) exit 127 ;;
    check-warning) echo 'warning: accepted' ;;
    check-success-panic) echo 'panic: failed'; exit 0 ;;
  esac
  exit 0
fi
if [ "$PROBE_CASE" = host-target ]; then
  for arg in "$@"; do
    case "$arg" in --target|--target=*) exit 86 ;; esac
  done
fi
while [ "$#" -gt 0 ]; do
  if [ "$1" = -o ]; then object=$2; break; fi
  shift
done
case "$PROBE_CASE" in
  success|check-warning) printf object > "$object"; exit 0 ;;
  object-warning) printf object > "$object"; echo 'warning: accepted'; exit 0 ;;
  object-success-panic) printf object > "$object"; echo 'panic: failed'; exit 0 ;;
  no-object) exit 0 ;;
  refusal|stale|host-target) refusal; exit 1 ;;
  notes) refusal; printf "note: while emitting 'f<i64>', instantiated here\n --> %s:2:1\n" "$source"; exit 1 ;;
  mixed) refusal; echo 'error[E0053]: unrelated'; exit 1 ;;
  wrong-source) source=wrong.bit; refusal; exit 1 ;;
  wrong-location) printf 'bit: %s: refusing to emit an object\nerror[E0092]: unsupported\n --> wrong.bit:1:1\n' "$source"; exit 1 ;;
  malformed-location) printf 'bit: %s: refusing to emit an object\nerror[E0092]: unsupported\n --> %s\n' "$source" "$source"; exit 1 ;;
  missing-location) printf 'bit: %s: refusing to emit an object\nerror[E0092]: unsupported\n' "$source"; exit 1 ;;
  panic) refusal; echo 'panic: failed'; exit 1 ;;
  object-refusal) printf object > "$object"; refusal; exit 1 ;;
  other-error) echo 'error[E0053]: unrelated'; exit 1 ;;
  status-126) exit 126 ;;
  status-127) exit 127 ;;
  timeout) exit 142 ;;
  signal) kill -TERM "$$" ;;
esac
PROBE
  chmod +x "$ORACLE"
  for row in 'success:ok' 'no-object:undecided' 'refusal:decline' 'host-target:decline' 'notes:decline' \
    'stale:decline' 'mixed:undecided' 'wrong-source:undecided' 'wrong-location:undecided' \
    'malformed-location:undecided' 'missing-location:undecided' \
    'panic:undecided' 'object-refusal:undecided' 'other-error:undecided' \
    'status-126:undecided' 'status-127:undecided' 'timeout:undecided' 'signal:undecided' \
    'check-decline:decline' 'check-panic:undecided' 'check-timeout:undecided' \
    'check-signal:undecided' 'check-127:undecided' 'check-warning:ok' 'object-warning:ok' \
    'check-success-panic:undecided' 'object-success-panic:undecided'; do
    PROBE_CASE=${row%%:*}; export PROBE_CASE
    printf stale > "$probe_dir/oracle-object.o"
    status=$(oracle_ir_coverage "$probe_dir/input.bit" "$probe_dir")
    expect "${row#*:}" "$status" "oracle coverage: $PROBE_CASE"
    case "$status" in
      ok) mismatch=1; undecided=0 ;;
      decline) mismatch=0; undecided=0 ;;
      *) mismatch=0; undecided=1 ;;
    esac
    (diffexit probe -f "$mismatch" -t "probe=$undecided") >/dev/null
    rc=$?
    case "${row#*:}" in
      ok) expect 1 "$rc" 'lowerable unexplained difference stays red' ;;
      decline) expect 0 "$rc" 'actual refusal is coverage' ;;
      *) expect 2 "$rc" 'failed probe never passes' ;;
    esac
  done
  chmod -x "$ORACLE"
  expect undecided "$(oracle_ir_coverage input.bit "$probe_dir")" 'nonexecutable oracle'
  ORACLE="$probe_dir/missing"
  expect undecided "$(oracle_ir_coverage input.bit "$probe_dir")" 'missing oracle'
  unset ORACLE PROBE_CASE
  got=$(declaredSignatureNames | LC_ALL=C sort)
  # Match the literal print even inside a conditional (#5510).
  want=$(grep -oE 'print[ (]+"[0-9]+-[a-z-]+"' "${ROOT}/scripts/selfhost-ir-signatures.sh" |
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
