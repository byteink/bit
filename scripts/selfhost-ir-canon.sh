#!/usr/bin/env bash
# Shared IR type-ID canonicalizer and object-backed framing (#1766).
# Object-backed proofs use the direct-only bounded JSON mode below.
# Source this file to call canon_ir_ids without starting a proof process.
canon_ir_ids() {
  # LC_ALL=C: a dump can hold bytes that are not valid UTF-8 (a string literal);
  # awk in a UTF-8 locale dies on them with `towc: multibyte conversion failure` (#6716).
  LC_ALL=C awk '
    {
      line = $0
      out = ""
      while (match(line, /\$t[0-9]+/)) {
        tok = substr(line, RSTART, RLENGTH)
        if (!(tok in map)) {
          map[tok] = "$c" n++
        }
        out = out substr(line, 1, RSTART - 1) map[tok]
        line = substr(line, RSTART + RLENGTH)
      }
      print out line
    }
  ' <<<"$1"
}
# Pure fixture constructors are separate from the production proof library.
diffiropt_literal_fixture_library() {
  DIFFIROPT_LITERAL_FIXTURES=
  local read_rc=0
  IFS= builtin read -r -d '' DIFFIROPT_LITERAL_FIXTURES <<'DIFFIROPT_LITERAL_FIXTURES' || read_rc=$?
def literal_test_macho(values):
    rodata = b''.join(values)
    payloads, headers, at = [], [], 0
    for value in values:
        payloads.append(at)
        headers.append(struct.pack('<3Q', 0, len(value), 0))
        at += len(value)
    strings, symbols, index = b'\0', [], 0
    for i in range(len(values)):
        for suffix, section, offset in ((b'_data', 1, payloads[i]), (b'', 2, i * 24)):
            name = b'___bitstr_' + str(i).encode() + suffix
            symbols.append(struct.pack('<IBBHQ', len(strings), 0xe, section, 0, offset))
            strings += name + b'\0'
            index += 1
    segment_size = 72 + 160
    start = 32 + segment_size + 24
    dataoff = (start + len(rodata) + 7) // 8 * 8
    relocoff = dataoff + len(headers) * 24
    relocs = b''.join(struct.pack('<iI', i * 24, 0xe000000 + 2 * i) for i in range(len(values)))
    symoff = relocoff + len(relocs)
    stringoff = symoff + len(symbols) * 16
    head = struct.pack('<8I', 0xfeedfacf, 0x100000c, 0, 1, 2, segment_size + 24, 0, 0)
    segment = struct.pack('<II16sQQQQiiII', 0x19, segment_size, b'', 0, 0, 0, 0, 0, 0, 2, 0)
    sections = struct.pack('<16s16sQQIIIIIIII', b'__const', b'__TEXT', 0, len(rodata), start, 0, 0, 0, 0, 0, 0, 0)
    sections += struct.pack('<16s16sQQIIIIIIII', b'__data', b'__DATA', 0, len(headers) * 24, dataoff, 3, relocoff, len(values), 0, 0, 0, 0)
    symtab = struct.pack('<6I', 2, 24, symoff, len(symbols), stringoff, len(strings))
    padding = bytes(dataoff - start - len(rodata))
    return head + segment + sections + symtab + rodata + padding + b''.join(headers) + relocs + b''.join(symbols) + strings

def literal_test_elf(values):
    rodata, strings, symbols, relocs = b'', b'\0', [bytes(24)], []
    for i, value in enumerate(values):
        offset = len(rodata)
        rodata += value
        rodata += bytes((-len(rodata)) % 8)
        header = len(rodata)
        rodata += struct.pack('<3Q', 0, len(value), 0)
        for suffix, location, size in ((b'_data', offset, len(value)), (b'', header, 24)):
            name = b'__bitstr_' + str(i).encode() + suffix
            symbols.append(struct.pack('<IBBHQQ', len(strings), 1, 0, 1, location, size))
            strings += name + b'\0'
        relocs.append(struct.pack('<QQq', header, ((1 + i * 2) << 32) | 257, 0))
    names = b'\0.rodata\0.rela.rodata\0.symtab\0.strtab\0.shstrtab\0'
    chunks = [rodata, b''.join(relocs), b''.join(symbols), strings, names]
    offsets, cursor = [], 64
    for chunk in chunks:
        offsets.append(cursor)
        cursor += len(chunk)
    shdrs = [bytes(64)]
    rows = [(1, 1, 2, 0, 0, 8, 0), (9, 4, 0, 3, 1, 8, 24),
            (22, 2, 0, 4, 1, 8, 24), (30, 3, 0, 0, 0, 1, 0),
            (38, 3, 0, 0, 0, 1, 0)]
    for i, (name, kind, flags, link, info, align, entry) in enumerate(rows):
        shdrs.append(struct.pack('<IIQQQQIIQQ', name, kind, flags, 0,
                                 offsets[i], len(chunks[i]), link, info, align, entry))
    ident = b'\x7fELF\x02\x01\x01' + bytes(9)
    head = struct.pack('<16sHHIQQQIHHHHHH', ident, 1, 183, 1, 0, 0,
                       cursor, 0, 64, 0, 0, 64, 6, 5)
    return head + b''.join(chunks) + b''.join(shdrs)
DIFFIROPT_LITERAL_FIXTURES
  [ "$read_rc" -eq 1 ]
}

# One paired transport relation; this library never rewrites a captured dump.
diffdump_aggregate_ir_library() {
  DIFFDUMP_AGGREGATE_IR_PYTHON=
  local aggregate_ir_rc=0
  IFS= builtin read -r -d '' DIFFDUMP_AGGREGATE_IR_PYTHON <<'AGGREGATE_IR' || aggregate_ir_rc=$?
def aggregate_parameters(raw):
    matches = list(re.finditer(rb'%(\d+): (.*?)(?=, %\d+: |$)', raw))
    require(b', '.join(match[0] for match in matches) == raw)
    return [(int(match[1]), match[2]) for match in matches]

def aggregate_function_line(line, functions, current, block):
    header = re.fullmatch(rb'func ([^(]+)\((.*)\) (.+) \{', line)
    if header is not None:
        require(current is None and header[1] not in functions)
        current = {'name': header[1], 'params': aggregate_parameters(header[2]),
                   'result': header[3], 'blocks': [], 'definitions': {}}
        functions[header[1]] = current
        return current, None
    if line == b'}':
        require(current is not None and block is not None)
        return None, None
    require(current is not None)
    label = re.fullmatch(rb'bb(\d+)\((.*)\):', line)
    if label is not None:
        block = (int(label[1]), aggregate_parameters(label[2]), [])
        require(block[0] not in [item[0] for item in current['blocks']])
        current['blocks'].append(block)
        return current, block
    aggregate_instruction_line(line, current, block)
    return current, block

def aggregate_instruction_line(line, current, block):
    require(block is not None and line.startswith(b'  '))
    definition = re.fullmatch(rb'  %(\d+) = (.+)', line)
    ident, body = (int(definition[1]), definition[2]) if definition else (None, line[2:])
    block[2].append((ident, body))
    if ident is not None:
        require(ident not in current['definitions'])
        current['definitions'][ident] = body

def aggregate_functions(raw):
    spend(len(raw))
    functions, current, block = {}, None, None
    for line in raw.splitlines():
        spend()
        if line:
            current, block = aggregate_function_line(line, functions, current, block)
    require(current is None and functions)
    return functions

def aggregate_call(body):
    match = re.fullmatch(rb'(call @([^ (]+)|call_iface %(\d+)\.(\d+))\((.*)\) (.+)', body)
    if match is None:
        return None
    target = ('direct', match[2]) if match[2] else ('interface', int(match[4]))
    return target, match[6]

def aggregate_run(instructions, index):
    spend()
    ident, body = instructions[index]
    call = aggregate_call(body)
    if call is None:
        return None
    types, indexes = [call[1]], [ident]
    for following, text in instructions[index + 1:]:
        spend()
        match = re.fullmatch(rb'call_word %(\d+)\[(\d+)\] (.+)', text)
        if match is None or int(match[1]) != ident:
            break
        require(int(match[2]) == len(types))
        types.append(match[3])
        indexes.append(following)
    return call[0], types, indexes

def aggregate_calls(function):
    result = []
    for unused, params, instructions in function['blocks']:
        for index in range(len(instructions)):
            run = aggregate_run(instructions, index)
            if run is not None:
                result.append(run)
    return result

def aggregate_note_spec(a, b, specs):
    require(a[0] == b[0])
    if a[1] == b[1]:
        return
    require(len(a[1]) == 2 and len(b[1]) >= 3 and a[1][-1] == b[1][-1])
    words = tuple(b[1][:-1])
    require(sum(ty not in (b'f32', b'f64') for ty in words) + 1 <= 5)
    require(sum(ty in (b'f32', b'f64') for ty in words) <= 6)
    spec = (a[1][0], words, a[1][-1])
    require(a[0] not in specs or specs[a[0]] == spec)
    specs[a[0]] = spec

def aggregate_specs(old, new):
    specs = {}
    for name in old:
        left, right = aggregate_calls(old[name]), aggregate_calls(new[name])
        require(len(left) == len(right))
        for a, b in zip(left, right):
            aggregate_note_spec(a, b, specs)
    require(specs)
    return specs

def aggregate_closure(specs, old, new, objects):
    left, right = [aggregate_object(obj) for obj in objects]
    require(left[:2] == right[:2])
    targets = {}
    for target, spec in specs.items():
        names = [target[1]] if target[0] == 'direct' else [row[1] for row in left[1].get(target[1], ())]
        require(names)
        for name in names:
            spend()
            require(name in old and name in new)
            require(old[name]['result'] == new[name]['result'] == spec[0])
            require(name not in targets or targets[name] == spec)
            targets[name] = spec
    for name, spec in targets.items():
        direct = ('direct', name)
        require(direct not in specs or specs[direct] == spec)
        specs[direct] = spec
    aggregate_references(left, old, targets)
    aggregate_references(right, new, targets)
    return targets

def aggregate_expected_references(metadata, functions, targets):
    expected = {}
    for name in targets:
        methods = sum(row[1] == name for rows in metadata[1].values() for row in rows)
        calls = sum(run[0] == ('direct', name) for function in functions.values() for run in aggregate_calls(function))
        expected[name] = (calls, methods)
    return expected

def aggregate_references(metadata, functions, targets):
    expected = aggregate_expected_references(metadata, functions, targets)
    observed = {name: [0, 0] for name in targets}
    for section, kind, name in metadata[2]:
        if name not in targets or section in (b'__bit_gc', b'__bit_dbg', b'.bit_gc', b'.bit_dbg'):
            continue
        if section in (b'__text', b'.text'):
            require(kind == 'call')
            observed[name][0] += 1
        else:
            require(section in (b'__data', b'.rodata') and kind == 'pointer')
            observed[name][1] += 1
    require(all(tuple(observed[name]) == count for name, count in expected.items()))

def aggregate_uses(body):
    if body.startswith((b'gc_alloc ', b'type_info ')):
        return []
    tokens = re.finditer(rb'"(?:\\.|[^"\\])*"|%(\d+)|[^"%]+|%', body)
    return [int(match[1]) for match in tokens if match[1]]

def aggregate_positions(blocks, ids):
    predecessors = {key: set() for key in ids}
    positions = {}
    for key, params, instructions in blocks:
        for ident, ty in params:
            require(ident not in positions)
            positions[ident] = (key, -1)
        require(instructions)
        for index, (ident, body) in enumerate(instructions):
            if ident is not None:
                require(ident not in positions)
                positions[ident] = (key, index)
        for target in re.findall(rb'bb(\d+)\(', instructions[-1][1]):
            target = int(target)
            require(target in ids)
            predecessors[target].add(key)
    return predecessors, positions

def aggregate_dominators(ids, predecessors):
    spend(len(ids) ** 2)
    dom = {key: ({0} if key == 0 else set(ids)) for key in ids}
    for unused in range(len(ids)):
        changed = False
        for key in sorted(ids - {0}):
            parents = predecessors[key]
            spend((len(parents) + 1) * len(ids))
            value = {key}
            if parents:
                value |= set.intersection(*(dom[parent] for parent in parents))
            changed |= value != dom[key]
            dom[key] = value
        if not changed:
            break
    require(not changed)
    return dom

def aggregate_graph(function):
    blocks = function['blocks']
    ids = {block[0] for block in blocks}
    require(len(ids) == len(blocks) and blocks[0][0] == 0)
    predecessors, positions = aggregate_positions(blocks, ids)
    dom = aggregate_dominators(ids, predecessors)
    for key, params, instructions in blocks:
        for index, (ident, body) in enumerate(instructions):
            for use in aggregate_uses(body):
                require(use in positions)
                owner, at = positions[use]
                require(owner in dom[key] and (owner != key or at < index))
    function['dominators'] = dom
    return positions

def aggregate_substitute(body, values):
    if body.startswith((b'gc_alloc ', b'type_info ')):
        return (body,)
    pattern = re.compile(rb'"(?:\\.|[^"\\])*"|%(\d+)|[^"%]+|%')
    result, end = [], 0
    for match in pattern.finditer(body):
        spend()
        require(match.start() == end)
        result.append(values[int(match[1])] if match[1] else match[0])
        end = match.end()
    require(end == len(body))
    return tuple(result)

def aggregate_constant(body):
    return body.startswith((b'const_int ', b'const_bool ', b'const_float ', b'const_nil'))

def aggregate_type(value):
    if value[0] in ('parameter', 'word', 'error', 'instruction'):
        return value[-1]
    require(value[0] == 'constant')
    body = value[1]
    if body.startswith(b'const_bool '):
        return b'bool'
    if body == b'const_nil':
        return None
    return body.split(b' ', 2)[1]

def aggregate_result_type(body):
    if body.startswith(b'const_string '):
        return b'string'
    if body.startswith(b'field_get '):
        return body[body.index(b']') + 2:]
    if body.startswith(b'call_word '):
        return body[body.index(b']') + 2:]
    if body.startswith(b'gc_alloc '):
        return body[body.index(b']') + 2:]
    if b') ' in body and body.startswith((b'call ', b'rt_call ', b'call_value ', b'call_iface ')):
        return body[body.rfind(b')') + 2:]
    parts = body.split(b' ', 2)
    require(len(parts) >= 2)
    return ('opaque-result',) if parts[1].startswith(b'%') else parts[1]

def aggregate_field_value(value, ty):
    actual = aggregate_type(value)
    if actual is not None:
        require(actual == ty)
        return
    require(ty not in (b'i8', b'i16', b'i32', b'i64', b'u8', b'u16', b'u32', b'u64', b'f32', b'f64', b'bool'))

def aggregate_initializer_constant(body):
    return re.fullmatch(rb'const_nil|const_bool (?:true|false)|const_int (?:[iu](?:8|16|32|64)) -?[0-9]+|const_float f(?:32|64) [+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?', body) is not None

def aggregate_initializer_value(target, text, ident, offset, values, pending):
    field = re.fullmatch(rb'field_set %(\d+)\[(\d+)\] = %(\d+)', text)
    require(target is None and field is not None)
    require(int(field[1]) == ident and int(field[2]) == offset)
    source = int(field[3])
    require(source in values or source in pending)
    return pending[source] if source in pending else values[source]

def aggregate_fields(instructions, index, spec, values):
    ident, body = instructions[index]
    match = re.fullmatch(rb'gc_alloc size=(\d+) ptrs=\[([^]]*)\] (.+)', body)
    if match is None or match[3] != spec[0]:
        return None
    words = spec[1]
    require(int(match[1]) >= (len(words) - 1) * 8 + 1)
    fields, pending, end = [], {}, index + 1
    for position in range(index + 1, len(instructions)):
        spend()
        target, text = instructions[position]
        if target is not None and aggregate_initializer_constant(text):
            pending[target] = ('constant', text)
            continue
        value = aggregate_initializer_value(target, text, ident, len(fields) * 8, values, pending)
        aggregate_field_value(value, words[len(fields)])
        fields.append(value)
        if len(fields) == len(words):
            end = position + 1
            break
    require(len(fields) == len(words))
    aggregate_gc_fields(match, fields, words)
    return tuple(fields), match[1], match[2], end, pending

def aggregate_gc_fields(match, fields, words):
    offsets = [int(value) for value in re.findall(rb'%(\d+)', match[2])]
    require(b', '.join(b'%' + str(value).encode() for value in offsets) == match[2])
    require(sorted(set(offsets)) == offsets and all(value + 8 <= int(match[1]) for value in offsets))
    scalar = (b'i8', b'i16', b'i32', b'i64', b'u8', b'u16', b'u32', b'u64', b'bool', b'f32', b'f64')
    for index, (field, ty) in enumerate(zip(fields, words)):
        pointer = index * 8 in offsets
        if ty in scalar or ty.startswith(b'*'):
            require(not pointer or aggregate_zero(field, ty))
        else:
            require(pointer)

def aggregate_guard(function, result, error):
    definitions = function['definitions']
    conditions = []
    for ident, body in definitions.items():
        match = re.fullmatch(rb'icmp_ne bool %(\d+), %(\d+)', body)
        if match is not None and int(match[1]) == error:
            require(definitions.get(int(match[2])) == b'const_nil')
            conditions.append(ident)
    require(len(conditions) == 1)
    branches = []
    for key, params, items in function['blocks']:
        match = re.fullmatch(rb'br %(\d+), bb(\d+)\((.*)\), bb(\d+)\((.*)\)', items[-1][1])
        if match is not None and int(match[1]) == conditions[0]:
            require(match[2] != match[4])
            branches.append(int(match[4]))
    require(len(branches) == 1)
    return branches[0]

def aggregate_zero(term, ty):
    require(term[0] == 'constant')
    body = term[1]
    if ty == b'bool':
        return body == b'const_bool false'
    if ty in (b'f32', b'f64'):
        return body == b'const_float ' + ty + b' 0'
    if ty in (b'i8', b'i16', b'i32', b'i64', b'u8', b'u16', b'u32', b'u64'):
        return body == b'const_int ' + ty + b' 0'
    return body == b'const_nil'

def aggregate_return(body, values, spec, side):
    require(re.fullmatch(rb'ret(?: %\d+(?:, %\d+)*)?', body) is not None)
    ids = aggregate_uses(body)
    terms = [values[ident] for ident in ids]
    if spec is None:
        return tuple(terms)
    if side:
        require(len(terms) == len(spec[1]) + 1)
        for term, ty in zip(terms[:-1], spec[1]):
            aggregate_field_value(term, ty)
        return tuple(terms)
    require(len(terms) == 2)
    if terms[0][0] == 'aggregate':
        return terms[0][1] + (terms[1],)
    require(terms[0] == ('constant', b'const_nil'))
    return ('failure', terms[1])

def aggregate_transport_instruction(state, index, instructions):
    values, residual = state['values'], state['residual']
    ident, body = instructions[index]
    run = aggregate_run(instructions, index)
    spec = state['specs'].get(run[0]) if run is not None else None
    if spec is not None:
        return aggregate_bind_call(state['function'], run, body, values, residual, spec, state['side'], index)
    if ident is not None and aggregate_constant(body):
        values[ident] = ('constant', body)
        state['constants'].add(ident)
        return index + 1
    item = aggregate_box(instructions, index, state['specs'], state['target'], values)
    if item is not None:
        fields, shape, following, pending = item
        values.update(pending)
        state['constants'].update(pending)
        values[ident] = ('aggregate', fields)
        state['boxes'].append((state['block'], ident, shape))
        aggregate_mark_reads(state, instructions, index, following)
        return following
    if aggregate_read(state['function'], state['block'], ident, body, values):
        aggregate_mark_reads(state, instructions, index, index + 1)
        return index + 1
    return index

def aggregate_residual_instruction(state, ident, body):
    values, residual = state['values'], state['residual']
    if body.startswith(b'ret'):
        terms = aggregate_return(body, values, state['target'], state['side'])
        residual.append(('return', terms))
        state['transport'].add((state['block'], state['index']))
        return
    expression = aggregate_substitute(body, values)
    require(not aggregate_contains_box(expression))
    residual.append(('instruction', expression))
    if ident is not None:
        values[ident] = ('instruction', len(residual) - 1, aggregate_result_type(body))

def aggregate_view(function, specs, target_spec, side):
    aggregate_graph(function)
    state = {'function': function, 'specs': specs, 'target': target_spec, 'side': side,
             'values': {}, 'residual': [], 'boxes': [], 'constants': set(),
             'block': None, 'transport': set(), 'index': None}
    for key, params, unused in function['blocks']:
        for k, (ident, ty) in enumerate(params):
            state['values'][ident] = ('parameter', key, k, ty)
    chunks = {}
    blocks = sorted(function['blocks'], key=lambda block: (len(function['dominators'][block[0]]), block[0]))
    for key, params, instructions in blocks:
        state['block'] = key
        start = len(state['residual'])
        state['residual'].append(('block', key, tuple(ty for ident, ty in params)))
        aggregate_block_view(state, instructions)
        chunks[key] = state['residual'][start:]
    state['residual'] = [item for key, params, instructions in function['blocks'] for item in chunks[key]]
    aggregate_constant_uses(state)
    if target_spec is not None:
        aggregate_return_reach(state)
    return state['residual'], state['boxes']

def aggregate_block_view(state, instructions):
    index = 0
    while index < len(instructions):
        state['index'] = index
        following = aggregate_transport_instruction(state, index, instructions)
        if following != index:
            index = following
            continue
        ident, body = instructions[index]
        aggregate_residual_instruction(state, ident, body)
        index += 1

def aggregate_mark_reads(state, instructions, start, end):
    for index in range(start, end):
        state['transport'].add((state['block'], index))

def aggregate_constant_uses(state):
    regular, all_uses = set(), set()
    for key, params, items in state['function']['blocks']:
        for index, (ident, body) in enumerate(items):
            uses = set(aggregate_uses(body))
            all_uses.update(uses)
            if (key, index) not in state['transport']:
                regular.update(uses)
    retained = (state['constants'] - all_uses) | (state['constants'] & regular)
    definitions = state['function']['definitions']
    state['residual'].append(('constant-definitions', tuple(sorted(definitions[ident] for ident in retained))))

def aggregate_return_reach(state):
    function = state['function']
    reached = set()
    for key, params, items in function['blocks']:
        for ident, body in items:
            if body.startswith(b'ret '):
                reached.update(aggregate_uses(body))
    for unused in range(len(function['definitions']) + 1):
        before = len(reached)
        for ident in tuple(reached):
            spend()
            if ident in function['definitions']:
                reached.update(aggregate_uses(function['definitions'][ident]))
        if len(reached) == before:
            break
    require(all(ident in reached for key, ident, shape in state['boxes']))

def aggregate_contains_box(term):
    pending = [term]
    for unused in range(1000000):
        if not pending:
            return False
        spend()
        value = pending.pop()
        if not isinstance(value, tuple):
            continue
        if value and value[0] == 'aggregate':
            return True
        pending.extend(value)
    require(False)

def aggregate_bind_call(function, run, body, values, residual, spec, side, index):
    target, types, ids = run
    wanted = list(spec[1]) + [spec[2]] if side else [spec[0], spec[2]]
    require(types == wanted)
    require(body.endswith(b' ' + types[0]))
    prefix = body[:-len(types[0]) - 1]
    residual.append(('call', aggregate_substitute(prefix, values), spec))
    call = len(residual) - 1
    words = tuple(('word', call, k, spec, ty) for k, ty in enumerate(spec[1]))
    error = ('error', call, spec[2])
    if side:
        for ident, value in zip(ids, words + (error,)):
            values[ident] = value
    else:
        guard = aggregate_guard(function, ids[0], ids[1])
        values[ids[0]] = ('aggregate', words, guard)
        values[ids[1]] = error
    return index + len(ids)

def aggregate_box_spec(instructions, index, target_spec, values):
    if target_spec is not None:
        return target_spec
    if index + 1 >= len(instructions):
        return None
    ident, body = instructions[index]
    field = re.fullmatch(rb'field_set %(\d+)\[0\] = %(\d+)', instructions[index + 1][1])
    if field is None or int(field[1]) != ident:
        return None
    value = values.get(int(field[2]))
    if value is None or value[0] != 'word':
        return None
    return value[-2]

def aggregate_box(instructions, index, specs, target_spec, values):
    spec = aggregate_box_spec(instructions, index, target_spec, values)
    if spec is None:
        return None
    fields = aggregate_fields(instructions, index, spec, values)
    if fields is None:
        return None
    if target_spec is None:
        require(all(value[0] == 'word' and value[-2] == spec for value in fields[0]))
        require(len({value[1] for value in fields[0]}) == 1)
        require([value[2] for value in fields[0]] == list(range(len(fields[0]))))
    return fields[0], (spec, fields[1], fields[2]), fields[3], fields[4]

def aggregate_read(function, key, ident, body, values):
    match = re.fullmatch(rb'field_get %(\d+)\[(\d+)\] (.+)', body)
    if match is None or int(match[1]) not in values:
        return False
    value = values[int(match[1])]
    if value[0] != 'aggregate':
        return False
    if len(value) == 3:
        require(value[2] in function['dominators'][key])
    offset = int(match[2])
    require(offset % 8 == 0 and offset // 8 < len(value[1]))
    result = value[1][offset // 8]
    aggregate_field_value(result, match[3])
    values[ident] = result
    return True

# ABI section 13 makes failure ok words unobservable; error SSA and typed zeros still match.
def aggregate_compare_returns(left, right, spec):
    require(len(left) == len(right))
    for a, b in zip(left, right):
        spend()
        if a == b:
            continue
        require(spec is not None and a[0] == b[0] == 'return')
        require(len(a[1]) == 2 and a[1][0] == 'failure')
        require(len(b[1]) == len(spec[1]) + 1 and b[1][-1] == a[1][1])
        require(b[1][-1] != ('constant', b'const_nil'))
        require(all(aggregate_zero(term, ty) for term, ty in zip(b[1][:-1], spec[1])))

def aggregate_prove(framed, objects):
    old, new = [aggregate_functions(raw) for raw in framed]
    require(list(old) == list(new))
    specs = aggregate_specs(old, new)
    targets = aggregate_closure(specs, old, new, objects)
    old_shapes, new_shapes = set(), set()
    for name in old:
        require(old[name]['params'] == new[name]['params'])
        require(old[name]['result'] == new[name]['result'])
        left, old_boxes = aggregate_view(old[name], specs, targets.get(name), False)
        right, new_boxes = aggregate_view(new[name], specs, targets.get(name), True)
        aggregate_compare_returns(left, right, targets.get(name))
        old_shapes.update(shape for key, ident, shape in old_boxes)
        new_shapes.update(shape for key, ident, shape in new_boxes)
    require(new_shapes <= old_shapes)
    return '6791-fallible-aggregate-words'
AGGREGATE_IR
  [ "$aggregate_ir_rc" -eq 1 ]
}

# Proof mode replaces this shell so a bounded caller also owns the Python PID.
if [ "${BASH_SOURCE[0]}" = "$0" ] && [ "$#" -ne 0 ]; then
  [ "$#" -eq 1 ] && [ "$1" = --prove-owned-appends ] || exit 1
  case "${BASH_SOURCE[0]}" in
    scripts/selfhost-ir-canon.sh) ROOT=. ;;
    */scripts/selfhost-ir-canon.sh) ROOT=${BASH_SOURCE[0]%/scripts/selfhost-ir-canon.sh} ;;
    *) exit 1 ;;
  esac
  . "${ROOT}/scripts/selfhost-diffdump-setup.sh" || exit 1
  . "${ROOT}/scripts/selfhost-diffiropt.sh" || exit 1
  diffdump_owned_append_library && diffiropt_literal_library &&
    diffdump_aggregate_object_library && diffdump_aggregate_ir_library || exit 1
  DIFFDUMP_OWNED_APPEND_ENGINE=
  diffdump_engine_rc=0
  IFS= builtin read -r -d '' DIFFDUMP_OWNED_APPEND_ENGINE <<'DIFFDUMP_OWNED_APPEND_ENGINE' || diffdump_engine_rc=$?
import base64
import binascii
import hashlib
import json
import sys

remaining = 0

def require(ok):
    if not ok:
        raise ValueError("unsupported proof")

def spend(n=1):
    global remaining
    require(type(n) is int and n >= 0)
    remaining -= n
    require(remaining >= 0)

def framing_bytes(value):
    return [base64.b64decode(s, validate=True) for s in sequence(value, 2, 2)]

def framed_proof(envelope):
    keys(envelope, "version comparison work_left proof original objects framed_sha256")
    require(type(envelope["version"]) is int and envelope["version"] == 2)
    original = framing_bytes(envelope["original"])
    objects = framing_bytes(envelope["objects"])
    require(sum(map(len, original + objects)) <= 8 * 1024 * 1024)
    memo = {}
    framed = [literal_frames(raw, obj, memo) for raw, obj in zip(original, objects)]
    require(envelope["framed_sha256"] == [hashlib.sha256(r).hexdigest() for r in framed])
    proof = envelope["proof"]
    require(type(proof) is dict and type(proof.get("version")) is int and proof["version"] == 1)
    require(type(proof["work_left"]) is int and proof["work_left"] == envelope["work_left"])
    return proof, framed, objects

def discovered_proof(envelope):
    keys(envelope, "version comparison work_left original objects")
    require(type(envelope["version"]) is int and envelope["version"] == 3)
    original, objects = framing_bytes(envelope["original"]), framing_bytes(envelope["objects"])
    require(sum(map(len, original + objects)) <= 8 * 1024 * 1024)
    require(original[0] != original[1] and all(b"\0" not in raw for raw in original))
    memo = {}
    framed = [literal_frames(raw, obj, memo) for raw, obj in zip(original, objects)]
    normalized = [literal_canonical(raw) for raw in framed]
    kind = "canonical" if normalized[0] == normalized[1] else aggregate_prove(framed, objects)
    return {"version": 3, "kind": kind, "work_left": remaining}

def certified_proof(envelope):
    obj, framed, objects = framed_proof(envelope)
    keys(obj, "version work_left kind queries")
    normalized = [literal_canonical(raw) for raw in framed]
    require(obj["queries"] == [])
    if obj["kind"] == "canonical":
        require(normalized[0] == normalized[1])
    else:
        require(obj["kind"] == "6791-fallible-aggregate-words")
        require(aggregate_prove(framed, objects) == obj["kind"])
    return {"version": 2, "query_ids": [q["id"] for q in obj["queries"]], "work_left": remaining}

def main():
    global remaining
    data = sys.stdin.buffer.read(8 * 1024 * 1024 + 1)
    require(0 < len(data) <= 8 * 1024 * 1024)
    envelope = json.loads(data, object_pairs_hook=unique_object)
    require(type(envelope) is dict)
    remaining = integer(envelope["work_left"], 1, 1000000)
    require(envelope["comparison"] in {"ir", "iropt"})
    if type(envelope.get("version")) is int and envelope["version"] == 3:
        result = discovered_proof(envelope)
    else:
        result = certified_proof(envelope)
    response = json.dumps(result, separators=(",", ":")).encode("ascii") + b"\n"
    require(len(response) <= 65536)
    sys.stdout.buffer.write(response)

try:
    main()
except (ValueError, TypeError, KeyError, IndexError, OverflowError, RecursionError, binascii.Error, struct.error):
    sys.exit(1)
DIFFDUMP_OWNED_APPEND_ENGINE
  [ "$diffdump_engine_rc" -eq 1 ] || exit 1
  LC_ALL=C
  export LC_ALL
  DIFFDUMP_OWNED_APPEND_CODE="${DIFFIROPT_LITERAL_PYTHON}"$'\n'"${DIFFDUMP_OWNED_APPEND_PYTHON}"$'\n'"${DIFFDUMP_AGGREGATE_OBJECT_PYTHON}"$'\n'"${DIFFDUMP_AGGREGATE_IR_PYTHON}"$'\n'"${DIFFDUMP_OWNED_APPEND_ENGINE}"
  [ "${#DIFFDUMP_OWNED_APPEND_CODE}" -le 65536 ] || exit 1
  exec python3 -I /dev/fd/3 3<<<"${DIFFDUMP_OWNED_APPEND_CODE}"
fi
# Keep the ordinary selfcheck in its existing test file, without a child PID.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  exec /bin/bash "$(dirname -- "${BASH_SOURCE[0]}")/selfhost-ir-signatures-selfcheck.sh" --canon-only
fi
