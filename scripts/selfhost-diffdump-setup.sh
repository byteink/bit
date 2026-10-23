#!/usr/bin/env bash
# Sourced-only setup for scripts/selfhost-diffdump.sh (#6196, split out to
# hold that file under the 800-line E0200 ceiling; behaviour unchanged,
# proven by `sh scripts/selfhost-diffall.sh` GREEN with this split in place).
#
# diffdump_setup resolves NAME (ast|tokens|diags|types|ir|iropt) into the
# FLAG/LABEL/SKIPLABEL/VERB/KIND/TIMEOUT/PREFIX row and the ORACLE/BIT2
# compilers, then exports the pinned-flag agreements every row body in
# selfhost-diffdump.sh needs before it walks the corpus. See that file's own
# header for the differential driver this feeds and
# docs/development/dump-differential.md for the full per-form design record.
#
# Usage (sourced, never executed standalone, ROOT already set by the caller):
#   . "${ROOT}/scripts/selfhost-diffdump-setup.sh"
#   diffdump_setup "$NAME"
#
# Sources diffexit.sh itself (harmless if the caller already did) since this
# file calls diffrequire directly -- _tests_/bit/shellsize.bit's #4724 check
# requires the source line in the SAME file that calls it, not merely
# somewhere in the call chain.
# shellcheck source=scripts/diffexit.sh
. "${ROOT}/scripts/diffexit.sh"

# A successful IR dump can hide failed lowering; only this source's E0092
# object refusal is coverage missing from the immutable oracle (#7931).
oracle_lowering_declined() {
  awk -v source="$2" '
    NR == 1 { if ($0 != "bit: " source ": refusing to emit an object") bad = 1; next }
    /^error\[E0092\]: / { if (pending) bad = 1; errors++; pending = 1; next }
    /^note: while emitting .*\047, instantiated here$/ { if (pending || !errors) bad = 1; pending = 1; next }
    /^[[:space:]]*--> / {
      location = $0; sub(/^[[:space:]]*--> /, "", location)
      if (location !~ /:[0-9]+:[0-9]+$/) bad = 1
      sub(/:[0-9]+:[0-9]+$/, "", location)
      if (!pending || location != source) bad = 1
      pending = 0; next
    }
    /^[[:space:]]*([0-9]+[[:space:]]*)?\|/ { next }
    /^[[:space:]]*$/ { next }
    { bad = 1 }
    END { exit (bad || pending || !errors) }
  ' "$1"
}

# Prints decline, ok, or undecided; failed execution never means coverage.
oracle_check_coverage() {
  local rc cap=$2
  alarmrun_retry_cap ORACLECHECK "" "$cap" "$ORACLE" check "$1"
  rc=$?
  case "$rc" in
    0) if grep -q '^panic: ' "$cap"; then echo undecided; else echo ok; fi ;;
    1) if grep -q '^panic: ' "$cap"; then echo undecided; else echo decline; fi ;;
    *) echo undecided ;;
  esac
}

oracle_object_coverage() {
  local source=$1 dir=$2 rc cap object
  cap="${dir:?}/oracle-object.cap"
  object="${dir:?}/oracle-object.o"
  alarmrun_retry_cap ORACLEOBJECT "$object" "$cap" "$ORACLE" build "$source" \
    --emit-obj --no-optimize -o "$object"
  rc=$?
  case "$rc" in
    0) [ -s "$object" ] && ! grep -q '^panic: ' "$cap" && echo ok || echo undecided ;;
    1) if [ ! -e "$object" ] && oracle_lowering_declined "$cap" "$source"; then echo decline; else echo undecided; fi ;;
    *) echo undecided ;;
  esac
}

oracle_ir_coverage() {
  local source=$1 dir=$2 status
  [ -x "$ORACLE" ] || { echo undecided; return; }
  status=$(oracle_check_coverage "$source" "${dir:?}/oracle-check.cap")
  [ "$status" = ok ] || { echo "$status"; return; }
  oracle_object_coverage "$source" "$dir"
}


# A candidate object is a framing witness, never a second oracle retry.
ir_mismatch_signature() {
  local source=$1 dir=$2 old=$3 new=$4 object cap rc
  case "$NAME" in ir|iropt) ;; *) return 1 ;; esac
  object="${dir:?}/bit2-object.o"
  cap="${dir:?}/bit2-object.cap"
  [ ! -L "$object" ] && [ ! -L "$cap" ] || return 2
  rm -f "$object" || return 2
  alarmrun_cap "$cap" "$BIT2" build "$source" --emit-obj --no-optimize -o "$object"
  rc=$?
  [ "$rc" -eq 0 ] && [ -f "$object" ] && [ ! -L "$object" ] && [ -s "$object" ] || {
    printf 'IR framing object command_rc=%s input=%s\n' "$rc" "$source" >&2
    return 2
  }
  if grep -q '^panic: ' "$cap"; then
    printf 'IR framing object command_rc=%s panic_output input=%s\n' "$rc" "$source" >&2
    return 2
  fi
  explainMismatch "$old" "$new" "$NAME" "$source" "${dir:?}/oracle-object.o" "$object" "${dir:?}/oracle.cap" "${dir:?}/bit2.cap"
}

diffdump_setup() {
  local name=$1
  # name    | flag           | verdict label   | skip label        | verb (ir only) | kind  | timeout (env, default)
  case "$name" in
    ast)    FLAG=--dump-ast;    LABEL="AST";           SKIPLABEL="parse-err";       VERB="";         KIND=basic; TIMEOUT="${DIFFAST_TIMEOUT:-20}" ;;
    tokens) FLAG=--dump-tokens; LABEL="token";         SKIPLABEL="lex-err";         VERB="";         KIND=basic; TIMEOUT="${DIFFTOKENS_TIMEOUT:-20}" ;;
    diags)  FLAG=--dump-diags;  LABEL="diag";          SKIPLABEL="";                VERB="";         KIND=basic; TIMEOUT="${DIFFDIAGS_TIMEOUT:-20}" ;;
    types)  FLAG=--dump-types;  LABEL="type";          SKIPLABEL="check-err";       VERB="";         KIND=types; TIMEOUT="${DIFFTYPES_TIMEOUT:-20}" ;;
    ir)     FLAG=--dump-ir-pre; LABEL="IR (pre-opt)";  SKIPLABEL="lower/check-err"; VERB="pre-opt";  KIND=ir;    TIMEOUT="${DIFFIR_TIMEOUT:-300}" ;;
    iropt)  FLAG=--dump-ir;     LABEL="IR (post-opt)"; SKIPLABEL="lower/check-err"; VERB="post-opt"; KIND=ir;    TIMEOUT="${DIFFIROPT_TIMEOUT:-300}" ;;
    *) echo "selfhost-diffdump: unknown differential '${name}' (want ast|tokens|diags|types|ir|iropt)" >&2; exit 2 ;;
  esac
  PREFIX="diff${name}"

  # Oracle: the pinned stage0 -- the same compiler one release back, an EARLIER
  # VERSION OF THIS SAME COMPILER, which is exactly what limits the claim below.
  # scripts/stage0.sh downloads and DIGEST-VERIFIES it, and refuses rather
  # than skipping, so a failure here is loud. A green run proves no behaviour
  # change versus the last release; it cannot catch a bug present in both —
  # docs/release/bootstrap.md §4/§5.
  ORACLE="$(sh "${ROOT}/scripts/stage0.sh")" || exit 2
  BIT2="${ROOT}/bit-out/bin/bit"

  # A missing compiler must ABORT, never score a vacuous green (#1514): both sides
  # of the differential would produce empty output, and equal-empty compares as
  # agreement. Exit 2 to keep this distinct from a real divergence (exit 1).
  # [diags' version of the same point:] This gate is the worst of the family
  # without it: both sides render empty, and since it skips nothing every file
  # scores MATCH — a full green board from no compiler.
  diffrequire "$PREFIX" "$ORACLE" "$BIT2"

  # BOTH SIDES must reach the working tree's stdlib THROUGH THE SAME PATH STRING,
  # the #1920 pin selfhost-diffcheck.sh already carries -- read its copy for the
  # full account. It was a check-row-only concern until #5177 routed
  # `--dump-types`/`--dump-ir`/`--dump-ir-pre` through `loadProject` for prelude
  # injection (compiler/main.bit's `checkedSourceFile`, replacing a scratch module
  # with `prelude: -1` that never touched stdRoot), and the pin was not carried
  # over here with it.
  #
  # Unpinned, stage0.sh's wrapper hands the ORACLE an absolute BIT_STDLIB while
  # BIT2 runs bare and `stdRootPath` (compiler/mainpaths.bit) falls through
  # `resolveNearExe` -- there is no `bit-out/stdlib` -- to the cwd-relative
  # literal `"stdlib"`. `loadModuleAt` (compiler/project.bit) memoises on
  # `pathResolve(dir)`, which is LEXICAL and never absolutises, so for a corpus
  # file under `stdlib/core/` the relative spelling makes the prelude's key and
  # the root's key the SAME STRING: the root load hits the prelude's cached
  # module and its `rootOnly` filter is dropped, dumping the whole two-file
  # module against its concatenated source. That is one compiler disagreeing with
  # ITSELF about an environment, scored as a divergence between two compilers
  # (#5356: stdlib/core/core.bit and stdlib/core/option.bit, MISMATCH=2 from a
  # bare shell while `./make test-differentials` -- which exports BIT_STDLIB per
  # tools/build/gatestable2.bit -- read green).
  #
  # `$(pwd)` not `${ROOT}`: it must name the tree the CORPUS below is found in,
  # since `find $CORPUS` is cwd-relative. The wrapper's `${BIT_STDLIB:-...}` takes
  # this value instead of substituting its own.
  BIT_STDLIB="$(pwd)/stdlib"
  export BIT_STDLIB

  # #6000: IFACE_SIG, BCE_JOIN, JSON_APPEND, and (since #6192) the #5990
  # static-const closure-cell lowering are all gone as flags -- the pinned
  # ORACLE (>= 0.31.0, which carries #6000) already emits every one of them
  # unconditionally, same as this tree. So are MAPLIT, STATIC_METHODS,
  # GENERIC_EXPLODE, DCE_PARAMS and DCE_METHODS since the 0.33.0 repin (#6245).
  # So are CONST_STRING_FOLD, MAP_PRESENCE and STRBOX_JOIN since the 0.35.0
  # repin (#6527).

  # #6416: the `if` branch-chain lowering (#5926, `ifBranchChainEnabled` in
  # compiler/lowercondchain.bit) defaults ON in this tree since the 0.41.0
  # repin; that ORACLE carries the code but still defaults it off. Both sides
  # inherit this environment, so force "1" to compare ON against ON. Delete
  # with the flag, one release after the flip.
  export BIT_IF_BRANCHCHAIN=1
}

# Fixed proof-library definitions; ordinary setup never calls this loader.
diffdump_owned_append_library() {
  DIFFDUMP_OWNED_APPEND_PYTHON=
  local diffdump_library_rc=0
  IFS= builtin read -r -d '' DIFFDUMP_OWNED_APPEND_PYTHON <<'DIFFDUMP_OWNED_APPEND_LIBRARY' || diffdump_library_rc=$?
def keys(value, expected):
    require(type(value) is dict and set(value) == set(expected.split()))

def integer(value, low, high):
    require(type(value) is int and low <= value <= high)
    return value

def sequence(value, low=0, high=8192):
    require(type(value) is list and low <= len(value) <= high)
    return value

def unique_object(pairs):
    result = dict(pairs)
    require(len(result) == len(pairs))
    return result

DIFFDUMP_OWNED_APPEND_LIBRARY
  [ "$diffdump_library_rc" -eq 1 ]
}

# Fixed byte-parser utilities shared with the isolated parent process.
diffdump_parent_library() {
  DIFFDUMP_PARENT_PYTHON=
  local diffdump_parent_rc=0
  IFS= builtin read -r -d '' DIFFDUMP_PARENT_PYTHON <<'DIFFDUMP_PARENT_LIBRARY' || diffdump_parent_rc=$?
def file_snapshot(path):
    require(0 < len(path) <= 4096)
    with os.fdopen(os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK), "rb") as stream:
        before = os.fstat(stream.fileno())
        require(stat.S_ISREG(before.st_mode) and 0 <= before.st_size <= 8 * 1024 * 1024)
        raw = stream.read(8 * 1024 * 1024 + 1)
        after, current = os.fstat(stream.fileno()), os.stat(path, follow_symlinks=False)
        require((before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns) ==
                (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns))
        require((current.st_dev, current.st_ino) == (before.st_dev, before.st_ino))
        require(len(raw) == before.st_size)
    return raw
DIFFDUMP_PARENT_LIBRARY
  [ "$diffdump_parent_rc" -eq 1 ]
}

# Only the fixed sibling framing source enters either proof process.
diffdump_frame_libraries() {
  . "$1/selfhost-diffiropt.sh" || return 1
  . "$1/selfhost-ir-canon.sh" || return 1
  diffdump_parent_library && diffiropt_literal_library && diffdump_owned_append_library
}

# Retired aggregate fixtures keep former transformations unexplained.
diffdump_aggregate_fixture_library() {
  DIFFDUMP_AGGREGATE_FIXTURES=
  local aggregate_fixture_rc=0
  IFS= builtin read -r -d '' DIFFDUMP_AGGREGATE_FIXTURES <<'AGGREGATE_FIXTURES' || aggregate_fixture_rc=$?
import struct
def fixture_pool(raw):
    remaining, found = raw, []
    for value in sorted(values, key=len, reverse=True):
        token = b'const_string "' + value + b'"'
        if token in remaining:
            found.append(value)
            remaining = remaining.replace(token, b"FIXED_LITERAL")
    assert b"const_string" not in remaining, "undeclared literal fixture"
    return tuple(sorted(set(found)))

def aggregate_fixture_entries(count, families):
    entries = [(b'_take$t1', 15, 1, 0)]
    if families:
        entries.append((b'_other$t2', 15, 1, 4))
    entries += [(b'___bittype_1_8_methods', 14, 3, 0), (b'___bittype_1_8', 15, 3, count * 16)]
    return entries

def aggregate_fixture_object(adjacent=False, overlap=False, families=False):
    text = bytes.fromhex('c0035fd6') * (2 if families else 1)
    count = 2 if adjacent or families else 1
    data = struct.pack('<2Q', 1, 0)
    if adjacent or families:
        data += struct.pack('<2Q', 2, 0)
    data += struct.pack('<8Q', 8, 0, 0, 0, 0, 0, count, 1)
    strings, symbols = b'\0', []
    entries = aggregate_fixture_entries(count, families)
    for name, kind, section, value in entries:
        symbols.append(struct.pack('<IBBHQ', len(strings), kind, section, 0, value))
        strings += name + b'\0'
    segment_size = 72 + 240
    start = 32 + segment_size + 24
    dataoff = (start + len(text) + 7) // 8 * 8
    relocoff = dataoff + len(data)
    relocs = struct.pack('<iI', 8, 0xe000000)
    if adjacent or families:
        relocs += struct.pack('<iI', 9 if overlap else 24, 0xe000000 + int(families))
    relocs += struct.pack('<iI', count * 16 + 40, 0xe000001 + int(families))
    symoff = relocoff + len(relocs)
    head = struct.pack('<8I', 0xfeedfacf, 0x100000c, 0, 1, 2, segment_size + 24, 0, 0)
    segment = struct.pack('<II16sQQQQiiII', 0x19, segment_size, b'', 0, 0, 0, 0, 0, 0, 3, 0)
    sections = struct.pack('<16s16sQQIIIIIIII', b'__text', b'__TEXT', 0, len(text), start, 2, 0, 0, 0, 0, 0, 0)
    sections += struct.pack('<16s16sQQIIIIIIII', b'__const', b'__TEXT', 0, 0, start, 0, 0, 0, 0, 0, 0, 0)
    sections += struct.pack('<16s16sQQIIIIIIII', b'__data', b'__DATA', 0, len(data), dataoff, 3, relocoff, count + 1, 0, 0, 0, 0)
    symtab = struct.pack('<6I', 2, 24, symoff, len(symbols), symoff + len(symbols) * 16, len(strings))
    raw = head + segment + sections + symtab + text + bytes(dataoff - start - len(text))
    return raw + data + relocs + b''.join(symbols) + strings, dataoff

def aggregate_fixture_pair():
    public = b'''func take$t1(%0: bool) Pair {
bb0(%0: bool):
  br %0, bb1(), bb2()
bb1():
  %1 = gc_alloc size=8 ptrs=[] Error
  %2 = const_nil
  ret %2, %1
bb2():
  %3 = const_int i64 7
  %4 = const_bool true
  %5 = gc_alloc size=16 ptrs=[] Pair
  field_set %5[0] = %3
  field_set %5[8] = %4
  %8 = const_nil
  ret %5, %8
}

func use(%0: Source, %1: bool) i64 {
bb0(%0: Source, %1: bool):
  %2 = call_iface %0.1(%1) Pair
  %3 = call_word %2[1] error
  %4 = const_nil
  %5 = icmp_ne bool %3, %4
  br %5, bb1(), bb2()
bb1():
  %7 = const_int i64 0
  ret %7
bb2():
  %9 = field_get %2[0] i64
  ret %9
}
'''
    candidate = b'''func take$t1(%0: bool) Pair {
bb0(%0: bool):
  br %0, bb1(), bb2()
bb1():
  %1 = gc_alloc size=8 ptrs=[] Error
  %2 = const_int i64 0
  %3 = const_bool false
  ret %2, %3, %1
bb2():
  %4 = const_int i64 7
  %5 = const_bool true
  %6 = const_nil
  ret %4, %5, %6
}

func use(%0: Source, %1: bool) i64 {
bb0(%0: Source, %1: bool):
  %2 = call_iface %0.1(%1) i64
  %3 = call_word %2[1] bool
  %4 = call_word %2[2] error
  %5 = const_nil
  %6 = icmp_ne bool %4, %5
  br %6, bb1(), bb2()
bb1():
  %8 = const_int i64 0
  ret %8
bb2():
  ret %2
}
'''
    return public, candidate

def aggregate_fixture_words(types):
    zero = lambda ty: b'const_float ' + ty + b' 0' if ty in (b'f32', b'f64') else b'const_int ' + ty + b' 0'
    constants = [b'  %' + str(k + 4).encode() + b' = ' + zero(ty) for k, ty in enumerate(types)]
    ids = [b'%' + str(k + 4).encode() for k in range(len(types))]
    common = b'func take$t1(%0: bool) Pair {\nbb0(%0: bool):\n  br %0, bb1(), bb2()\nbb1():\n  %1 = gc_alloc size=8 ptrs=[] Error\n'
    public = common + b'  %2 = const_nil\n  ret %2, %1\nbb2():\n' + b'\n'.join(constants)
    public += b'\n  %20 = gc_alloc size=' + str(len(types) * 8).encode() + b' ptrs=[] Pair\n'
    public += b''.join(b'  field_set %20[' + str(k * 8).encode() + b'] = ' + ident + b'\n' for k, ident in enumerate(ids))
    public += b'  %21 = const_nil\n  ret %20, %21\n}\n\n'
    failure = [b'  %' + str(k + 24).encode() + b' = ' + zero(ty) for k, ty in enumerate(types)]
    failure_ids = [b'%' + str(k + 24).encode() for k in range(len(types))]
    candidate = common + b'\n'.join(failure) + b'\n  ret ' + b', '.join(failure_ids + [b'%1'])
    candidate += b'\nbb2():\n' + b'\n'.join(constants) + b'\n  %21 = const_nil\n  ret ' + b', '.join(ids + [b'%21']) + b'\n}\n\n'
    caller = b'func use(%0: Source, %1: bool) ' + types[0] + b' {\nbb0(%0: Source, %1: bool):\n  %2 = call_iface %0.1(%1) '
    public += caller + b'Pair\n  %3 = call_word %2[1] error\n  %4 = const_nil\n  %5 = icmp_ne bool %3, %4\n  br %5, bb1(), bb2()\nbb1():\n  %7 = ' + zero(types[0]) + b'\n  ret %7\nbb2():\n  %9 = field_get %2[0] ' + types[0] + b'\n  ret %9\n}\n'
    candidate += caller + types[0] + b'\n'
    candidate += b''.join(b'  %' + str(k + 2).encode() + b' = call_word %2[' + str(k).encode() + b'] ' + ty + b'\n' for k, ty in enumerate(types[1:], 1))
    candidate += b'  %20 = call_word %2[' + str(len(types)).encode() + b'] error\n  %21 = const_nil\n  %22 = icmp_ne bool %20, %21\n  br %22, bb1(), bb2()\nbb1():\n  %23 = ' + zero(types[0]) + b'\n  ret %23\nbb2():\n  ret %2\n}\n'
    return public, candidate

def aggregate_fixture_word_controls(verdict):
    for types, expected in [((b'i8', b'u16'), 1), ((b'f32', b'f64'), 1),
            ((b'i64',) * 4, 1), ((b'i64',) * 5, 1),
            ((b'f64',) * 6, 1), ((b'f64',) * 7, 1)]:
        public, candidate = aggregate_fixture_words(types)
        assert verdict(public, candidate, pools=((), ()))[0] == expected, ('word budget', types)
    public, candidate = aggregate_fixture_words((b'f32', b'i8'))
    for before, after in [(b'const_float f32 0', b'const_float f32 1'),
            (b'call_word %2[1] i8', b'call_word %2[1] i16')]:
        wrong = candidate.replace(before, after, 1)
        assert verdict(public, wrong, pools=((), ()))[0] == 1, ('typed words', before)
    wrong = public.replace(b'field_get %2[0] f32', b'field_get %2[8] f32')
    assert verdict(wrong, candidate, pools=((), ()))[0] == 1, 'typed field offset'

def aggregate_fixture_initializers(verdict, public, candidate):
    before = b'  %3 = const_int i64 7\n  %4 = const_bool true\n  %5 = gc_alloc size=16 ptrs=[] Pair\n  field_set %5[0] = %3\n  field_set %5[8] = %4\n'
    after = b'  %5 = gc_alloc size=16 ptrs=[] Pair\n  %3 = const_int i64 7\n  field_set %5[0] = %3\n  %4 = const_bool true\n  field_set %5[8] = %4\n'
    interleaved = public.replace(before, after)
    assert interleaved != public
    assert verdict(interleaved, candidate, pools=((), ()))[0] == 1, 'retired interleaved constants'
    for effect in (b'  %10 = rt_call blackbox(%0) void\n', b'  %10 = rt_call blackbox(%5) void\n',
                   b'  %10 = const_int i64 123\n', b'  %10 = const_nil_bogus\n'):
        wrong = interleaved.replace(b'  %3 = const_int i64 7\n', effect + b'  %3 = const_int i64 7\n')
        assert verdict(wrong, candidate, pools=((), ()))[0] == 1, 'initializer effect/escape/unused/unknown'
    for before, after in [(b'field_set %5[8] = %4', b'field_set %5[0] = %4'),
                          (b'field_set %5[0] = %3', b'field_set %5[0] = %4')]:
        assert verdict(interleaved.replace(before, after), candidate, pools=((), ()))[0] == 1, 'duplicate/uninitialized field'
    old, new = [value.replace(b'Pair', b'(i64, bool)') for value in (interleaved, candidate)]
    assert verdict(old, new, pools=((), ()))[0] == 1, 'retired parenthesized call result'
    for before, after in [(b'%0.1(%1)', b'%0.1(%0)'), (b'call_iface %0.1(%1) i64', b'call_iface %0.1(%1) i32')]:
        assert verdict(old, new.replace(before, after), pools=((), ()))[0] == 1, 'call argument/result changed'

def aggregate_fixture_opaque(verdict, public, candidate):
    opaque = b'\nfunc opaque(%0: []string, %1: i64) i64 {\nbb0(%0: []string, %1: i64):\n  %2 = slice_len %0\n  %3 = index_get %0[%1] string\n  %4 = slice_len %3\n  ret %4\n}\n'
    renamed = re.sub(rb'%([234])\b', lambda match: b'%1' + match[1], opaque)
    assert verdict(public + opaque, candidate + renamed, pools=((), ()))[0] == 1, 'retired opaque result SSA mapping'
    wrong = renamed.replace(b'index_get %0[%1]', b'index_get %0[%12]')
    assert verdict(public + opaque, candidate + wrong, pools=((), ()))[0] == 1, 'opaque operand changed'
    unknown = b'  %10 = gc_alloc size=24 ptrs=[%0] []i64\n  %11 = slice_len %10\n'
    wrong = public.replace(b'  %3 = const_int i64 7\n', unknown).replace(b'field_set %5[0] = %3', b'field_set %5[0] = %11')
    assert verdict(wrong, candidate, pools=((), ()))[0] == 1, 'unknown result cannot authorize payload'

def aggregate_fixture_families(verdict, objects, folder):
    old, new = aggregate_fixture_pair()
    other_old, other_new = aggregate_fixture_words((b'f32', b'i8'))
    other_old, other_new = [value.replace(b'take$t1', b'other$t2').replace(b'func use(', b'func otherUse(').replace(b'%0.1(', b'%0.2(') for value in (other_old, other_new)]
    raw, unused = aggregate_fixture_object(families=True)
    path = os.path.join(folder, 'aggregate-families.o')
    with open(path, 'wb') as output:
        assert output.write(raw) == len(raw)
    saved = objects[()]
    objects[()] = path
    assert verdict(old + other_old, new + other_new, pools=((), ()))[0] == 1, 'retired same erased family name'
    wrong = other_new.replace(b'call_word %2[1] i8', b'call_word %2[1] bool')
    assert verdict(old + other_old, new + wrong, pools=((), ()))[0] == 1, 'cross family word'
    objects[()] = saved

def aggregate_fixture_late_blocks(verdict, public, candidate):
    late = b'\nfunc late() i64 {\nbb0():\n  jump bb2()\nbb1():\n  ret %1\nbb2():\n  %1 = const_int i64 1\n  jump bb1()\n}\n'
    assert verdict(public + late, candidate + late, pools=((), ()))[0] == 1, 'retired late dominating definition'
    bad = late.replace(b'jump bb2()', b'jump bb1()')
    assert verdict(public + bad, candidate + bad, pools=((), ()))[0] == 1, 'nondominating definition'

def aggregate_fixture_discovery(helper, public, candidate, raw):
    packet = {"version": 3, "comparison": "ir", "work_left": 1000000,
              "original": [base64.b64encode(value).decode() for value in (public, candidate)],
              "objects": [base64.b64encode(raw).decode()] * 2}
    child = os.path.join(os.path.dirname(helper), 'selfhost-ir-canon.sh')
    def run(value):
        wire = json.dumps(value, separators=(',', ':')).encode()
        result = subprocess.run(['/bin/bash', child, '--prove-owned-appends'], input=wire,
                                capture_output=True, timeout=5)
        return result.returncode, result.stdout, result.stderr
    assert run(packet) == (1, b'', b''), 'retired aggregate discovery'
    canonical = dict(packet, original=[packet['original'][0],
        base64.b64encode(public.replace(b'$t1', b'$t2')).decode()])
    rc, output, error = run(canonical)
    response = json.loads(output)
    assert rc == 0 and error == b'' and set(response) == {'version', 'kind', 'work_left'}
    assert response['version'] == 3 and response['kind'] == 'canonical'
    assert type(response['work_left']) is int and 0 <= response['work_left'] < 1000000
    bads = [{'version': True}, {'version': 4}, {'work_left': True}, {'work_left': 0},
            {'work_left': 1000001}, {'comparison': 'types'}, {'kind': 'canonical'},
            {'framed_sha256': ['forged']}, {'original': ['?', '?']}, {'objects': []},
            {'original': packet['original'][:1]}, {'original': [packet['original'][0]] * 2},
            {'objects': [base64.b64encode(raw[:-1]).decode()] * 2}]
    for change in bads:
        assert run(dict(packet, **change)) == (1, b'', b''), ('v3 refusal', change.keys())
    for key in packet:
        wrong = dict(packet)
        wrong.pop(key)
        assert run(wrong) == (1, b'', b''), ('v3 missing', key)
    wrong = dict(packet, original=[base64.b64encode(b'const_string "forged"\n').decode(), packet['original'][1]])
    assert run(wrong) == (1, b'', b''), 'v3 literal framing'

def aggregate_fixture_fake_child(helper, public, candidate, raw, folder):
    script = os.path.join(folder, 'aggregate-fake-child.sh')
    files = []
    for index, value in enumerate((raw, raw, public, candidate)):
        path = os.path.join(folder, 'aggregate-parent-' + str(index))
        with open(path, 'wb') as output:
            assert output.write(value) == len(value)
        files.append(path)
    with open(helper, encoding='utf8') as source:
        parent = source.read().split("<<'PYTHON'", 1)[1].split('\n', 1)[1].split('\nPYTHON', 1)[0]
    setup = os.path.join(os.path.dirname(helper), 'selfhost-diffdump-setup.sh')
    with open(setup, encoding='utf8') as source:
        library = source.read().split("<<'DIFFDUMP_PARENT_LIBRARY'", 1)[1].split('\n', 1)[1].split('\nDIFFDUMP_PARENT_LIBRARY', 1)[0]
    code = library + '\n' + parent
    response = {'version': 3, 'kind': 'canonical', 'work_left': 1000000}
    cases = [(dict(response, version=True), '', 0), (dict(response, version=2), '', 0),
             (dict(response, work_left=True), '', 0), (dict(response, work_left=1000001), '', 0),
             (dict(response, kind='forged'), '', 0), (dict(response, kind='6791-fallible-aggregate-words'), '', 0), (dict(response, extra=0), '', 0),
             ({'version': 3, 'work_left': 1}, '', 0), (response, 'bad', 0),
             (response, '', 1), ('X' * 65537, '', 0)]
    for value, stderr, rc in cases:
        text = value if type(value) is str else json.dumps(value)
        shell = "#!/bin/bash\ncat >/dev/null\nprintf '%s' '" + text + "'\nprintf '%s' '" + stderr + "' >&2\nexit " + str(rc) + "\n"
        with open(script, 'w', encoding='ascii') as output:
            assert output.write(shell) == len(shell)
        argv = [sys.executable, '-I', '-c', code, script, '', *files, 'ir']
        result = subprocess.run(argv, input=public.rstrip(b'\n') + b'\0' + candidate.rstrip(b'\n'), capture_output=True, timeout=6)
        assert result.returncode == 1 and result.stdout == b'', 'parent fake child refusal'

def aggregate_fixture_bucket(helper, folder):
    path = os.path.join(os.path.dirname(helper), 'selfhost-diffdump.sh')
    with open(path, encoding='utf8') as source:
        bucket = 'ir_signature_bucket() {' + source.read().split('ir_signature_bucket() {', 1)[1].split('\n}', 1)[0] + '\n}'
    command = bucket + '\nmatch=0; : >"$1/mismatch"; : >"$1/explained"; ir_signature_bucket 0 6791-fallible-aggregate-words fixture ir sep "$1"; test "$match" = 0 && test -s "$1/mismatch" && ! test -s "$1/explained"'
    result = subprocess.run(['/bin/bash', '-c', command, 'retired-bucket', folder], capture_output=True, timeout=5)
    assert result.returncode == 0 and result.stdout == result.stderr == b'', 'retired aggregate bucket'

def aggregate_fixture_controls(verdict, objects, store):
    public, candidate = aggregate_fixture_pair()
    raw, method = aggregate_fixture_object()
    positive = os.path.join(store.name, 'aggregate-positive.o')
    negative = os.path.join(store.name, 'aggregate-negative.o')
    with open(positive, 'wb') as output:
        assert output.write(raw) == len(raw)
    bad = raw[:method] + struct.pack('<Q', 2) + raw[method + 8:]
    with open(negative, 'wb') as output:
        assert output.write(bad) == len(bad)
    saved = objects.get(())
    objects[()] = positive
    objects[(b'aggregate-dispatch',)] = negative
    expected = (1, b'')
    aggregate_fixture_bucket(helper, store.name)
    aggregate_fixture_discovery(helper, public, candidate, raw)
    aggregate_fixture_fake_child(helper, public, candidate, raw, store.name)
    aggregate_fixture_late_blocks(verdict, public, candidate)
    aggregate_fixture_families(verdict, objects, store.name)
    aggregate_fixture_opaque(verdict, public, candidate)
    aggregate_fixture_initializers(verdict, public, candidate)
    assert verdict(public, candidate, pools=((), ())) == expected, 'retired aggregate transport'
    for suffix, overlap, expected_rc in [('adjacent', False, 1), ('overlap', True, 1)]:
        object_raw, unused = aggregate_fixture_object(True, overlap)
        path = os.path.join(store.name, 'aggregate-' + suffix + '.o')
        with open(path, 'wb') as output:
            assert output.write(object_raw) == len(object_raw)
        objects[()] = path
        assert verdict(public, candidate, pools=((), ()))[0] == expected_rc, suffix
    objects[()] = positive
    aggregate_fixture_word_controls(verdict)
    for bad_return in (b'ret_bogus %2', b'ret %2, 123'):
        wrong = candidate.replace(b'ret %2\n', bad_return + b'\n')
        assert verdict(public, wrong, pools=((), ())) == (1, b''), 'exact return grammar'
    wrong = candidate.replace(b'const_int i64 7', b'const_int i64 8')
    assert verdict(public, wrong, pools=((), ())) == (1, b''), 'aggregate changed return'
    wrong = candidate.replace(b'call_word %2[2] error', b'call_word %2[1] error')
    assert verdict(public, wrong, pools=((), ())) == (1, b''), 'aggregate error index'
    assert verdict(public, candidate, pools=((), (b'aggregate-dispatch',))) == (1, b''), 'aggregate dispatch closure'
    objects.pop((b'aggregate-dispatch',))
    if saved is None:
        objects.pop(())
    else:
        objects[()] = saved
AGGREGATE_FIXTURES
  [ "$aggregate_fixture_rc" -eq 1 ]
}
