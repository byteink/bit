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

# This grammar identifies operands, not opcodes permitted to differ. Every
# token outside the one derived edge/phi rewrite remains byte-exact.
def thread_schemas():
    binary = 'add sub mul sdiv udiv srem urem smulhi umulhi fadd fsub fmul fdiv band bor bxor shl ashr lshr'
    compare = 'icmp_eq icmp_ne icmp_slt icmp_sle icmp_sgt icmp_sge icmp_ult icmp_ule icmp_ugt icmp_uge fcmp_eq fcmp_ne fcmp_lt fcmp_le fcmp_gt fcmp_ge'
    unary = 'neg fneg bnot convert fsqrt bitcast ffloor fceil ftrunc fround'
    name, vals, ty = rb'[A-Za-z_.$][A-Za-z0-9_.$]*', rb'(?:%[0-9]+(?:, %[0-9]+)*)?', rb'(?P<ty>[^%\n]+)'
    return [
        (rb'(?:' + '|'.join((binary + ' ' + compare).split()).encode() + rb') ' + ty + rb' %[0-9]+, %[0-9]+', True, None),
        (rb'(?:' + '|'.join(unary.split()).encode() + rb') ' + ty + rb' %[0-9]+', True, None),
        (rb'const_(?:int|float) ' + ty + rb' [^ ]+', True, None),
        (rb'const_bool (?:true|false)', True, b'bool'),
        (rb'const_nil', True, None),
        (rb'const_string "(?:\\.|[^"\\])*"', True, b'string'),
        (rb'(?:call @' + name + rb'|rt_call ' + name + rb'|call_value %[0-9]+|call_iface %[0-9]+\.[0-9]+|syscall %[0-9]+)\(' + vals + rb'\) ' + ty, True, None),
        (rb'call_word %[0-9]+\[[0-9]+\] ' + ty, True, None),
        (rb'(?:gc_alloc size=[0-9]+|type_info disc=[0-9]+ size=[0-9]+) ptrs=\[' + vals + rb'\] ' + ty, True, None),
        (rb'(?:field_get %[0-9]+\[-?[0-9]+\]|index_get %[0-9]+\[%[0-9]+\]|atomic_load %[0-9]+) ' + ty, True, None),
        (rb'(?:atomic_rmw_(?:add|sub|and|or|xchg) %[0-9]+, %[0-9]+|atomic_cmpxchg %[0-9]+, %[0-9]+, %[0-9]+) ' + ty, True, None),
        (rb'slice_len %[0-9]+', True, b'i64'),
        (rb'(?:func_addr|global_addr|stackmaps_addr) @' + name, True, None),
        (rb'make_closure @' + name + rb', %[0-9]+', True, None),
        (rb'poll_attention', True, b'i64'),
        (rb'asm block=[0-9]+\(' + vals + rb'\)', True, None),
        (rb'(?:field_set %[0-9]+\[-?[0-9]+\]|index_set %[0-9]+\[%[0-9]+\]|atomic_store(?:_release)? %[0-9]+) = %[0-9]+', False, None),
        (rb'keep_alive %[0-9]+', False, None),
        (rb'asm block=[0-9]+\(' + vals + rb'\)', False, None),
        (rb'(?:jump bb[0-9]+\(' + vals + rb'\)|br %[0-9]+, bb[0-9]+\(' + vals + rb'\), bb[0-9]+\(' + vals + rb'\)|ret(?: ' + vals + rb')?|unreachable)', False, None),
    ]

def thread_type(body, defined):
    for pattern, result, fixed in thread_schemas():
        spend(len(body) + 1)
        match = re.fullmatch(pattern, body)
        if match is not None and result == defined:
            return match.groupdict().get('ty', fixed)
    raise ValueError('unknown IR grammar')

def thread_refs(body, replace=None):
    # Pointer offsets have the same spelling as values, but are metadata.
    parts = re.split(rb'(ptrs=\[(?:%[0-9]+(?:, %[0-9]+)*)?\]|"(?:\\.|[^"\\])*")', body)
    out, refs = [], []
    for i, part in enumerate(parts):
        spend(len(part) + 1)
        if i % 2:
            out.append(part)
            continue
        refs.extend(int(m[1]) for m in re.finditer(rb'%([0-9]+)', part))
        out.append(part if replace is None else re.sub(rb'%([0-9]+)', lambda m: b'%' + str(replace(int(m[1]))).encode(), part))
    return refs if replace is None else b''.join(out)

def thread_values(raw):
    require(re.fullmatch(rb'(?:%[0-9]+(?:, %[0-9]+)*)?', raw) is not None)
    return [int(m[1]) for m in re.finditer(rb'%([0-9]+)', raw)]

def thread_params(raw):
    starts = list(re.finditer(rb'(?:^|, )%([0-9]+): ', raw))
    require(bool(starts) == bool(raw))
    out = []
    for i, match in enumerate(starts):
        end = starts[i + 1].start() if i + 1 < len(starts) else len(raw)
        typ = raw[match.end():end]
        require(typ and b'%' not in typ and b'"' not in typ)
        out.append((int(match[1]), typ))
    return out

def thread_edges(body):
    if body.startswith(b'jump '):
        m = re.fullmatch(rb'jump bb([0-9]+)\((.*)\)', body)
        require(m is not None)
        return [(int(m[1]), thread_values(m[2]))]
    if body.startswith(b'br '):
        m = re.fullmatch(rb'br %[0-9]+, bb([0-9]+)\((.*?)\), bb([0-9]+)\((.*?)\)', body)
        require(m is not None)
        return [(int(m[1]), thread_values(m[2])), (int(m[3]), thread_values(m[4]))]
    require(body == b'unreachable' or body == b'ret' or body.startswith(b'ret '))
    return []

def thread_instruction(line):
    m = re.fullmatch(rb'  (?:%([0-9]+) = )?(.*)', line)
    require(m is not None)
    value = None if m[1] is None else int(m[1])
    return dict(value=value, body=m[2], type=thread_type(m[2], value is not None), refs=thread_refs(m[2]))

def thread_function(raw):
    lines = raw.splitlines()
    head = re.fullmatch(rb'func ([^ (\n]+)\((.*?)\) (.+) \{', lines[0])
    require(head is not None and lines[-1] == b'}')
    blocks = []
    for line in lines[1:-1]:
        spend(len(line) + 1)
        m = re.fullmatch(rb'bb([0-9]+)\((.*)\):', line)
        if m is not None:
            require(int(m[1]) == len(blocks))
            blocks.append(dict(params=thread_params(m[2]), ins=[], start=None))
        else:
            require(bool(blocks))
            blocks[-1]['ins'].append(thread_instruction(line))
    f = dict(header=lines[0], params=thread_params(head[2]), result=head[3], blocks=blocks, defs={})
    thread_slots(f)
    thread_validate(f)
    require(thread_derive(f, []) == raw)
    return f

def thread_anchors(block):
    anchors = [v - i for i, (v, unused) in enumerate(block['params'])]
    offset = len(block['params'])
    anchors += [ins['value'] - offset - i for i, ins in enumerate(block['ins']) if ins['value'] is not None]
    require(not anchors or len(set(anchors)) == 1)
    return anchors[0] if anchors else None

def thread_slot_choices(block, occupied):
    size = len(block['params']) + len(block['ins'])
    lower = max([0] + [v + 1 - i for i, ins in enumerate(block['ins']) for v in ins['refs']])
    return [i for i in range(lower, len(occupied) - size + 1) if not any(occupied[i:i + size])]

def thread_place(block, start, occupied):
    size = len(block['params']) + len(block['ins'])
    require(0 <= start <= len(occupied) - size and not any(occupied[start:start + size]))
    occupied[start:start + size] = [True] * size
    block['start'] = start

def thread_slots(f):
    blocks = f['blocks']
    require(bool(blocks) and all(b['ins'] for b in blocks))
    occupied = [False] * sum(len(b['params']) + len(b['ins']) for b in blocks)
    for b in blocks:
        start = thread_anchors(b)
        if start is not None:
            thread_place(b, start, occupied)
    thread_fill_slots(blocks, occupied)
    require(all(occupied) and blocks[0]['start'] == 0 and blocks[0]['params'] == f['params'])

def thread_fill_slots(blocks, occupied):
    for unused in range(len(blocks)):
        pending = [b for b in blocks if b['start'] is None]
        if not pending:
            break
        progress = False
        for b in pending:
            spend(len(occupied) * (len(b['ins']) + 1))
            choices = thread_slot_choices(b, occupied)
            require(bool(choices))
            if len(choices) == 1:
                thread_place(b, choices[0], occupied)
                progress = True
        require(progress)

def thread_reach(f, avoid=-1):
    seen, work = set(), [0]
    for unused in range(len(f['blocks'])):
        if not work:
            break
        b = work.pop()
        seen.add(b)
        for target, args in f['blocks'][b]['edges']:
            spend(len(args) + 1)
            if target != avoid and target not in seen and target not in work:
                work.append(target)
    require(not work)
    return seen

def thread_definition(f, value, typ, b, pos):
    require(value not in f['defs'])
    f['defs'][value] = (typ, b, pos)

def thread_edge_check(f, target, args):
    require(0 <= target < len(f['blocks']))
    params = f['blocks'][target]['params']
    require(len(args) == len(params))
    for value, (unused, typ) in zip(args, params):
        require(value in f['defs'] and f['defs'][value][0] == typ)

def thread_use_check(f, b, pos, value, avoid):
    require(value in f['defs'])
    unused, owner, where = f['defs'][value]
    if owner == b:
        require(where < pos)
        return
    require(b in f['reach'] and owner in f['reach'])
    if owner not in avoid:
        avoid[owner] = thread_reach(f, owner)
    require(owner == 0 or b not in avoid[owner])

def thread_validate(f):
    for bi, b in enumerate(f['blocks']):
        for i, (value, typ) in enumerate(b['params']):
            thread_definition(f, value, typ, bi, i)
        for i, ins in enumerate(b['ins'], len(b['params'])):
            if ins['value'] is not None:
                require(ins['value'] == b['start'] + i)
                thread_definition(f, ins['value'], ins['type'], bi, i)
        b['edges'] = thread_edges(b['ins'][-1]['body'])
    f['reach'], f['uses'], f['preds'] = thread_reach(f), {}, [[] for unused in f['blocks']]
    avoid = {}
    for bi, b in enumerate(f['blocks']):
        for target, args in b['edges']:
            thread_edge_check(f, target, args)
            f['preds'][target].append(bi)
        thread_terminator_type(f, b['ins'][-1])
        for i, ins in enumerate(b['ins'], len(b['params'])):
            for value in ins['refs']:
                spend()
                thread_use_check(f, bi, i, value, avoid)
                f['uses'].setdefault(value, []).append((bi, i))

def thread_terminator_type(f, ins):
    body = ins['body']
    if body.startswith(b'br '):
        require(f['defs'][ins['refs'][0]][0] == b'bool')
    if body.startswith(b'ret'):
        expected = [] if f['result'] == b'void' else [f['result']]
        require([f['defs'][v][0] for v in ins['refs']] == expected)

def thread_def(f, value):
    unused, b, pos = f['defs'][value]
    block = f['blocks'][b]
    require(pos >= len(block['params']))
    return b, block['ins'][pos - len(block['params'])]

def thread_guard(f, join, ok):
    b = f['blocks'][join]
    require(len(b['params']) == 1)
    term = b['ins'][-1]
    require(term['body'].startswith(b'br '))
    condition = term['refs'][0]
    if condition == ok:
        require(len(b['ins']) == 1)
        return 0
    require(len(b['ins']) == 3)
    const, cmp = b['ins'][:2]
    require(const['body'] == b'const_bool false')
    require(cmp['body'] == b'icmp_eq bool %' + str(ok).encode() + b', %' + str(const['value']).encode())
    require(condition == cmp['value'] and len(f['uses'][condition]) == len(f['uses'][const['value']]) == 1)
    return 1

def thread_probe(f, head):
    h = f['blocks'][head]
    require(h['ins'][-1]['body'].startswith(b'br '))
    owner, cmp = thread_def(f, h['ins'][-1]['refs'][0])
    require(owner == head and cmp['body'].startswith(b'icmp_ne bool ') and len(cmp['refs']) == 2)
    value, nil = cmp['refs']
    owner, call = thread_def(f, value)
    require(owner == head and call['body'].startswith(b'rt_call map_val_at(') and len(call['refs']) == 2)
    require(thread_def(f, nil)[0] == head and thread_def(f, nil)[1]['body'] == b'const_nil')
    slot = call['refs'][1]
    return value, thread_slot_flag(f, head, slot, call)

def thread_slot_flag(f, head, slot, call):
    require(thread_def(f, slot)[0] == head and thread_def(f, slot)[1]['body'].startswith(b'rt_call map_slot('))
    require(len(thread_def(f, slot)[1]['refs']) == 2 and thread_def(f, slot)[1]['refs'][0] == call['refs'][0])
    wanted = b'icmp_sge bool %' + str(slot).encode() + b', %'
    flags = [ins for ins in f['blocks'][head]['ins'] if ins['body'].startswith(wanted)]
    require(len(flags) == 1 and flags[0]['value'] < call['value'])
    require(thread_def(f, flags[0]['refs'][1])[0] == head and thread_def(f, flags[0]['refs'][1])[1]['body'] == b'const_int i64 0')
    return flags[0]['value']

def thread_candidate(f, head):
    value, ok = thread_probe(f, head)
    join, args = f['blocks'][head]['edges'][0]
    require(args == [value])
    side = thread_guard(f, join, ok)
    succ, args = f['blocks'][join]['edges'][side]
    require(succ > 0 and f['preds'][succ] == [join])
    p, typ = f['blocks'][join]['params'][0]
    require(f['defs'][value][0] == typ)
    require(f['blocks'][head]['start'] < f['blocks'][join]['start'] < f['blocks'][succ]['start'])
    free = [(b, i) for b, i in f['uses'].get(p, []) if b != join]
    avoid = thread_reach(f, succ)
    require(all(b in f['reach'] and b not in avoid and f['blocks'][b]['start'] >= f['blocks'][succ]['start'] for b, unused in free))
    return dict(head=head, join=join, succ=succ, side=side, value=value, p=p, type=typ, extra=bool(free), args=args)

def thread_val_list(values):
    return b', '.join(b'%' + str(v).encode() for v in values)

def thread_render_branch(ins, edges):
    targets = [b'bb' + str(t).encode() + b'(' + thread_val_list(a) + b')' for t, a in edges]
    return ins['body'].split(b', ', 1)[0] + b', ' + b', '.join(targets)

def thread_remap(f, cs):
    remap, extra, at = {}, {}, 0
    additions = {c['succ']: c for c in cs if c['extra']}
    for bi in sorted(range(len(f['blocks'])), key=lambda b: f['blocks'][b]['start']):
        b = f['blocks'][bi]
        for value, unused in b['params']:
            remap[value] = at
            at += 1
        if bi in additions:
            extra[bi] = at
            at += 1
        for ins in b['ins']:
            if ins['value'] is not None:
                remap[ins['value']] = at
            at += 1
    return remap, extra

def thread_branch_edges(ins, bi, cs):
    edges = thread_edges(ins['body'])
    for c in cs:
        if bi == c['head']:
            args = [c['value'] if v == c['p'] else v for v in c['args']]
            edges[0] = (c['succ'], args + ([c['value']] if c['extra'] else []))
        if bi == c['join'] and c['extra']:
            target, args = edges[c['side']]
            edges[c['side']] = (target, args + [c['p']])
    return thread_render_branch(ins, edges)

def thread_substitutions(bi, cs, extra):
    return {c['p']: extra[c['succ']] for c in cs if c['extra'] and bi != c['join']}

def thread_body(ins, bi, cs, remap, extra):
    substitutions = thread_substitutions(bi, cs, extra)
    replace = lambda value: substitutions.get(value, remap[value])
    body = ins['body']
    if body.startswith(b'br '):
        body = thread_branch_edges(ins, bi, cs)
    body = thread_refs(body, replace)
    prefix = b'' if ins['value'] is None else b'%' + str(remap[ins['value']]).encode() + b' = '
    return b'  ' + prefix + body + b'\n'

def thread_derive(f, heads):
    cs = [thread_candidate(f, h) for h in heads]
    require(len({c['succ'] for c in cs}) == len(cs))
    require(len({b for c in cs for b in (c['head'], c['join'])}) == 2 * len(cs))
    remap, extra = thread_remap(f, cs)
    out = [f['header'] + b'\n']
    for bi, b in enumerate(f['blocks']):
        out.append(thread_block_header(bi, b, cs, remap, extra))
        out.extend(thread_body(ins, bi, cs, remap, extra) for ins in b['ins'])
    return b''.join(out) + b'}\n'

def thread_block_header(bi, block, cs, remap, extra):
    params = [(remap[v], typ) for v, typ in block['params']]
    additions = [c for c in cs if c['succ'] == bi and c['extra']]
    params += [(extra[bi], c['type']) for c in additions]
    return b'bb' + str(bi).encode() + b'(' + b', '.join(b'%' + str(v).encode() + b': ' + typ for v, typ in params) + b'):\n'

def thread_modules(raw):
    functions = re.findall(rb'(?ms)^func [^\n]*\{\n.*?^}\n', raw)
    require(bool(functions) and b'\n'.join(functions) == raw)
    return functions

def thread_proof(old, new, queries=None):
    left, right = thread_modules(old), thread_modules(new)
    require(len(left) == len(right))
    discovered = []
    for fi, (a, b) in enumerate(zip(left, right)):
        if a == b:
            continue
        heads = thread_changed_function(a, b)
        discovered += [dict(id='f%d-b%d' % (fi, h), fn=fi, head=h) for h in heads]
    require(bool(discovered))
    if queries is not None:
        for query in sequence(queries, 1):
            keys(query, 'id fn head')
            require(type(query['id']) is str and type(query['fn']) is int and type(query['head']) is int)
        require(queries == discovered)
    return discovered

def thread_changed_function(old, new):
    f, g = thread_function(old), thread_function(new)
    require(f['header'] == g['header'] and len(f['blocks']) == len(g['blocks']))
    heads = []
    for h, block in enumerate(f['blocks']):
        if not block['ins'][-1]['body'].startswith(b'br '):
            continue
        require(bool(g['blocks'][h]['edges']))
        if block['edges'][0][0] != g['blocks'][h]['edges'][0][0]:
            heads.append(h)
    require(bool(heads) and thread_derive(f, heads) == new)
    return heads
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
  diffdump_parent_library && diffiropt_literal_library && diffdump_owned_append_library
}
