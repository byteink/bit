#!/usr/bin/env bash
# Sourceable, fixed framing code for two-sided canonical proofs (#8271).
diffiropt_literal_library() {
  DIFFIROPT_LITERAL_PYTHON=
  local read_rc=0
  IFS= builtin read -r -d '' DIFFIROPT_LITERAL_PYTHON <<'DIFFIROPT_LITERAL_LIBRARY' || read_rc=$?
import json
import re
import struct

def literal_unpack(data, offset, fmt):
    size = struct.calcsize(fmt)
    require(type(offset) is int and 0 <= offset <= len(data) - size)
    spend(size)
    return struct.unpack_from(fmt, data, offset)

def literal_bounds(data, offset, size):
    require(type(offset) is int and type(size) is int)
    require(0 <= offset <= len(data) and 0 <= size <= len(data) - offset)

def literal_span(data, offset, size):
    literal_bounds(data, offset, size)
    spend(size)
    return data[offset:offset + size]

def literal_name(table, offset):
    require(0 <= offset < len(table))
    end = table.find(b"\0", offset)
    require(end >= offset)
    value = table[offset:end]
    spend(len(value) + 1)
    require(all(32 <= c <= 126 for c in value))
    return value

def literal_pool_symbol(names, name, row, prefix):
    if not name.startswith(prefix):
        return
    match = re.fullmatch(re.escape(prefix) + rb"(0|[1-9][0-9]*)(_data)?", name)
    require(match is not None and name not in names)
    names[name] = (int(match[1]), match[2] is not None, row)

def literal_pool_pairs(names):
    headers, payloads = {}, {}
    for index, is_data, row in names.values():
        target = payloads if is_data else headers
        require(index not in target)
        target[index] = row
    require(set(headers) == set(payloads) == set(range(len(headers))))
    return [(headers[i], payloads[i]) for i in range(len(headers))]

def literal_macho_sections(data, offset, size, sections):
    header = literal_unpack(data, offset, '<II16sQQQQiiII')
    count = header[9]
    require(count <= 4096 and size == 72 + 80 * count)
    for i in range(count):
        row = literal_unpack(data, offset + 72 + i * 80, '<16s16sQQIIIIIIII')
        require(len(sections) < 4096 and row[5] <= 31)
        require(row[2] % (1 << row[5]) == 0)
        literal_bounds(data, row[6], row[7] * 8)
        if row[8] & 255 not in (1, 12, 18):
            require(row[4] % (1 << row[5]) == 0)
            literal_bounds(data, row[4], row[3])
        sections.append(row)

def literal_macho_commands(data):
    header = literal_unpack(data, 0, '<8I')
    require(header[0] == 0xfeedfacf and header[1] == 0x100000c and header[3] == 1)
    require(0 < header[4] <= 4096)
    literal_bounds(data, 32, header[5])
    sections, symtab, offset = [], None, 32
    for unused in range(header[4]):
        command, size = literal_unpack(data, offset, '<II')
        require(size >= 8 and size % 8 == 0 and offset + size <= 32 + header[5])
        if command == 0x19:
            literal_macho_sections(data, offset, size, sections)
        elif command == 2:
            require(symtab is None and size == 24)
            symtab = literal_unpack(data, offset, '<6I')[2:]
        offset += size
    require(offset == 32 + header[5] and symtab is not None)
    return sections, symtab

def literal_macho_symbols(data, sections, symtab):
    offset, count, strings, size = symtab
    require(count <= 65536)
    literal_bounds(data, offset, count * 16)
    table = literal_span(data, strings, size)
    names, symbols = {}, []
    for i in range(count):
        row = literal_unpack(data, offset + i * 16, '<IBBHQ')
        name = literal_name(table, row[0])
        symbols.append((name, row))
        literal_pool_symbol(names, name, row, b'___bitstr_')
    return symbols, literal_pool_pairs(names)

def literal_macho_location(data, sections, symbol, size):
    require(symbol[1] & 0xee == 0x0e and 0 < symbol[2] <= len(sections))
    section = sections[symbol[2] - 1]
    relative = symbol[4] - section[2]
    require(0 <= relative <= section[3] and size <= section[3] - relative)
    return section, relative, literal_span(data, section[4] + relative, size)

def literal_relocation_add(index, address, width, row, section_size):
    require(width in (1, 2, 4, 8) and 0 <= address <= section_size - width)
    spend(3)
    previous = index.get(address)
    if previous is not None:
        width, row = max(width, previous[0]), None
    index[address] = (width, row)

def literal_relocation_rows(index, relative):
    spend(32)
    rows = []
    for address in range(relative - 7, relative + 24):
        entry = index.get(address)
        if entry is not None and relative < address + entry[0]:
            require(entry[1] is not None)
            spend(2)
            rows.append((address, entry[1]))
    return rows

def literal_macho_relocations(data, section):
    spend()
    index = {}
    for i in range(section[7]):
        address, bits = literal_unpack(data, section[6] + i * 8, '<iI')
        literal_relocation_add(index, address, 1 << ((bits >> 25) & 3), bits, section[3])
    return index

def literal_macho_pointer(index, relative, symbols, wanted):
    rows = literal_relocation_rows(index, relative)
    require(len(rows) == 1)
    address, bits = rows[0]
    require(address == relative and bits >> 24 == 14)
    target = bits & 0xffffff
    require(target < len(symbols) and symbols[target][1] == wanted)

def literal_macho_pool(data):
    sections, symtab = literal_macho_commands(data)
    symbols, pairs = literal_macho_symbols(data, sections, symtab)
    spend()
    values, previous, relocations = [], None, {}
    for header, payload in pairs:
        hs, ho, raw = literal_macho_location(data, sections, header, 24)
        pointer, size, base = struct.unpack('<3Q', raw)
        require(pointer == base == 0 and size <= len(data) and ho % 8 == 0)
        ds, do, value = literal_macho_location(data, sections, payload, size)
        require(hs[0].rstrip(b'\0') == b'__data' and ds[0].rstrip(b'\0') == b'__const')
        require(hs[1].rstrip(b'\0') == b'__DATA' and ds[1].rstrip(b'\0') == b'__TEXT')
        require(hs[8] & 255 == ds[8] & 255 == 0)
        spend(2)
        if header[2] not in relocations:
            spend()
            relocations[header[2]] = literal_macho_relocations(data, hs)
        literal_macho_pointer(relocations[header[2]], ho, symbols, payload)
        if previous is not None:
            require(header[2] == previous[0] and ho == previous[1] + 24)
            require(payload[2] == previous[2] and do == previous[3] + previous[4])
        previous = (header[2], ho, payload[2], do, size)
        values.append(value)
    require(len(set(values)) == len(values))
    return values

def literal_elf_header(data):
    header = literal_unpack(data, 0, '<16sHHIQQQIHHHHHH')
    require(header[0][:7] == b'\x7fELF\x02\x01\x01' and header[1] == 1)
    require(header[2] in (62, 183) and header[3] == 1 and header[5] == 0)
    require(header[8] == 64 and header[10] == 0 and header[11] == 64)
    require(0 < header[12] <= 4096 and header[13] < header[12])
    literal_bounds(data, header[6], header[12] * 64)
    return header

def literal_elf_sections(data):
    header = literal_elf_header(data)
    sections = [literal_unpack(data, header[6] + i * 64, '<IIQQQQIIQQ')
                for i in range(header[12])]
    for section in sections:
        if section[1] != 8:
            literal_bounds(data, section[4], section[5])
    strings = sections[header[13]]
    require(strings[1] == 3)
    table = literal_span(data, strings[4], strings[5])
    names = [literal_name(table, s[0]) for s in sections]
    return header[2], sections, names

def literal_elf_symbols(data, sections):
    candidates = [i for i, s in enumerate(sections) if s[1] == 2]
    require(len(candidates) == 1)
    index = candidates[0]
    section = sections[index]
    require(section[9] == 24 and section[5] % 24 == 0 and section[5] // 24 <= 65536)
    require(section[6] < len(sections) and sections[section[6]][1] == 3)
    strings = sections[section[6]]
    table = literal_span(data, strings[4], strings[5])
    names, symbols = {}, []
    for i in range(section[5] // 24):
        row = literal_unpack(data, section[4] + i * 24, '<IBBHQQ')
        name = literal_name(table, row[0])
        symbols.append((name, row))
        literal_pool_symbol(names, name, row, b'__bitstr_')
    return index, symbols, literal_pool_pairs(names)

def literal_elf_location(data, sections, symbol, size):
    require(symbol[1] & 15 == 1 and symbol[2] == 0)
    require(0 < symbol[3] < len(sections) and symbol[5] == size)
    section = sections[symbol[3]]
    require(symbol[4] <= section[5] and size <= section[5] - symbol[4])
    return section, literal_span(data, section[4] + symbol[4], size)

def literal_elf_relocations(data, sections, table, machine, target):
    spend(len(sections) + 1)
    index = {}
    for section in sections:
        if section[1] != 4 or section[7] != target:
            continue
        require(section[6] == table and section[9] == 24 and section[5] % 24 == 0)
        for i in range(section[5] // 24):
            row = literal_unpack(data, section[4] + i * 24, '<QQq')
            require(row[1] & 0xffffffff == (1 if machine == 62 else 257) and row[2] == 0)
            literal_relocation_add(index, row[0], 8, row, sections[target][5])
    return index

def literal_elf_pointer(index, symbols, header, payload):
    rows = literal_relocation_rows(index, header[4])
    require(len(rows) == 1)
    offset, info, addend = rows[0][1]
    require(offset == header[4] and addend == 0)
    target = info >> 32
    require(target < len(symbols) and symbols[target][1] == payload)

def literal_elf_pool(data):
    machine, sections, names = literal_elf_sections(data)
    table, symbols, pairs = literal_elf_symbols(data, sections)
    spend()
    values, previous, relocations = [], None, {}
    for header, payload in pairs:
        hs, raw = literal_elf_location(data, sections, header, 24)
        pointer, size, base = struct.unpack('<3Q', raw)
        require(pointer == base == 0 and size <= len(data))
        ds, value = literal_elf_location(data, sections, payload, size)
        require(header[3] == payload[3] and names[header[3]] == b'.rodata')
        require(hs[1] == ds[1] == 1 and hs[2] & 7 == 2)
        require(header[4] == (payload[4] + size + 7) // 8 * 8)
        spend(2)
        if header[3] not in relocations:
            spend()
            relocations[header[3]] = literal_elf_relocations(data, sections, table, machine, header[3])
        literal_elf_pointer(relocations[header[3]], symbols, header, payload)
        if previous is not None:
            require(payload[3] == previous[0] and payload[4] == previous[1] + 24)
        previous = (header[3], header[4])
        values.append(value)
    require(len(set(values)) == len(values))
    return values

def literal_pool(data):
    require(type(data) is bytes and 32 <= len(data) <= 8388608)
    if data[:4] == b'\xcf\xfa\xed\xfe':
        return literal_macho_pool(data)
    require(data[:4] == b'\x7fELF')
    return literal_elf_pool(data)

def literal_trie(pool):
    spend()
    trie = {}
    for value in pool:
        node = trie
        for byte in value:
            spend()
            if byte not in node:
                spend(2)
                node[byte] = {}
            node = node[byte]
        require(256 not in node)
        spend()
        node[256] = value
    return trie

def literal_match(raw, start, trie):
    node, matches = trie, []
    for end in range(start, len(raw) + 1):
        spend()
        value = node.get(256)
        if value is not None and raw[end:end + 2] == b'"\n':
            require(not matches)
            matches.append((end + 2, value))
        if end == len(raw) or raw[end] not in node:
            break
        node = node[raw[end]]
    require(len(matches) == 1)
    return matches[0]

# A nonempty match starts with a captured byte; keep the complete pool in the memo.
def literal_frame_trie(raw, entry):
    spend(len(raw) + 258)
    starts = frozenset(raw)
    if starts != entry[1]:
        spend(len(entry[0]) + 6)
        entry[1:] = starts, literal_trie(value for value in entry[0] if not value or value[0] in starts)
    return entry[2]

def literal_frames(raw, object_raw, memo=None):
    require(type(raw) is bytes and type(object_raw) is bytes and len(raw) + len(object_raw) <= 8388608)
    if memo is None:
        spend()
        memo = {}
    require(type(memo) is dict and len(memo) <= 2)
    if object_raw not in memo:
        require(len(memo) < 2)
        spend(2)
        memo[object_raw] = [literal_pool(object_raw), None, None]
    pool = literal_frame_trie(raw, memo[object_raw])
    output, offset = [], 0
    prefix = re.compile(rb'  %[0-9]+ = const_string "')
    for unused in range(len(raw) + 1):
        if offset == len(raw):
            return b''.join(output)
        match = prefix.match(raw, offset)
        if match is not None:
            end, value = literal_match(raw, match.end(), pool)
            quoted = json.dumps(value.decode('latin1'), ensure_ascii=True).encode('ascii')
            output.append(raw[offset:match.end() - 1] + quoted + b'\n')
        else:
            newline = raw.find(b'\n', offset)
            end = len(raw) if newline < 0 else newline + 1
            output.append(raw[offset:end])
        offset = end
    raise ValueError('literal framing bound')

def literal_canonical(frame):
    require(type(frame) is bytes and len(frame) <= 8388608)
    if b'$t' not in frame:
        return frame
    spend(len(frame))
    pattern = re.compile(rb'"(?:\\.|[^"\\])*"|\$t[0-9]+|[^"$]+|\$|"', re.S)
    output, names, end = [], {}, 0
    for match in pattern.finditer(frame):
        spend()
        token = match[0]
        require(match.start() == end and token != b'"')
        if token.startswith(b'$t'):
            names.setdefault(token, b'$c' + str(len(names)).encode())
            token = names[token]
        output.append(token)
        end = match.end()
    require(end == len(frame))
    return b''.join(output)

DIFFIROPT_LITERAL_LIBRARY
  [ "$read_rc" -eq 1 ]
}

# Capture status: 0=text without quotes, 3=quoted text, 1=NUL, 2=read error.
diffiropt_capture_text() {
  [ "$#" -eq 2 ] || return 2
  python3 -I /dev/fd/3 "$1" "$2" 3<<'DIFFIROPT_CAPTURE_TEXT'
import os
import stat
import sys

def capture_identity(info):
    return (info.st_dev, info.st_ino, info.st_mode, info.st_size,
            info.st_mtime_ns, info.st_ctime_ns)

def capture_bytes(path, limit):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode) or not 0 <= before.st_size <= limit:
            raise ValueError('capture boundary')
        chunks, total = [], 0
        for unused in range(129):
            chunk = os.read(fd, min(65536, limit + 1 - total))
            if not chunk:
                break
            chunks.append(chunk)
            total += len(chunk)
            if total > limit:
                raise ValueError('capture size')
        else:
            raise ValueError('capture read bound')
        if capture_identity(before) != capture_identity(os.fstat(fd)):
            raise ValueError('capture changed')
        if capture_identity(before) != capture_identity(os.lstat(path)):
            raise ValueError('capture replaced')
        return b''.join(chunks)
    finally:
        os.close(fd)

def capture_main():
    if len(sys.argv) != 3:
        return 2
    try:
        old = capture_bytes(sys.argv[1], 8388608)
        new = capture_bytes(sys.argv[2], 8388608 - len(old))
    except (OSError, ValueError, OverflowError):
        return 2
    if b'\0' in old or b'\0' in new:
        return 1
    return 3 if b'"' in old or b'"' in new else 0

sys.exit(capture_main())
DIFFIROPT_CAPTURE_TEXT
}
# Fixed data-only fixture mode shares the pure constructors with the tests.
if [ "${BASH_SOURCE[0]}" = "$0" ] && [ "$#" -eq 1 ] && [ "$1" = --fixture-object ]; then
  diffiropt_literal_library || exit 1
  . "$(dirname -- "${BASH_SOURCE[0]}")/selfhost-ir-canon.sh" || exit 1
  diffiropt_literal_fixture_library || exit 1
  DIFFIROPT_FIXTURE_COMMAND=
  read_rc=0
  IFS= builtin read -r -d '' DIFFIROPT_FIXTURE_COMMAND <<'DIFFIROPT_FIXTURE_COMMAND' || read_rc=$?
import base64
import binascii
import sys

def fixture_need(ok):
    if not ok:
        raise ValueError('fixture boundary')

def fixture_values():
    data = sys.stdin.buffer.read(2097153)
    fixture_need(len(data) <= 2097152)
    encoded = json.loads(data)
    fixture_need(type(encoded) is list and len(encoded) <= 4096)
    values, total = [], 0
    for item in encoded:
        fixture_need(type(item) is str and len(item) <= 349528)
        value = base64.b64decode(item.encode('ascii'), validate=True)
        fixture_need(len(value) <= 262144)
        total += len(value)
        fixture_need(total <= 1048576)
        values.append(value)
    fixture_need(len(set(values)) == len(values))
    return values

def fixture_main():
    try:
        result = literal_test_macho(fixture_values())
        fixture_need(len(result) <= 8388608)
        fixture_need(sys.stdout.buffer.write(result) == len(result))
        sys.stdout.buffer.flush()
    except (ValueError, TypeError, UnicodeError, OSError, binascii.Error):
        return 1
    return 0

sys.exit(fixture_main())
DIFFIROPT_FIXTURE_COMMAND
  [ "$read_rc" -eq 1 ] || exit 1
  exec python3 -I /dev/fd/3 3<<<"${DIFFIROPT_LITERAL_PYTHON}"$'\n'"${DIFFIROPT_LITERAL_FIXTURES}"$'\n'"${DIFFIROPT_FIXTURE_COMMAND}"
fi

# The exact test mode executes only fixed data and the fixed library above.
if [ "${BASH_SOURCE[0]}" = "$0" ] && [ "$#" -eq 1 ] && [ "$1" = --literal-selfcheck ]; then
  diffiropt_literal_library || exit 1
  . "$(dirname -- "${BASH_SOURCE[0]}")/selfhost-ir-canon.sh" || exit 1
  diffiropt_literal_fixture_library || exit 1
  DIFFIROPT_LITERAL_TESTS=
  read_rc=0
  IFS= builtin read -r -d '' DIFFIROPT_LITERAL_TESTS <<'DIFFIROPT_LITERAL_TESTS' || read_rc=$?
remaining = 1000000

def require(ok):
    if not ok:
        raise ValueError('literal selfcheck refusal')

def spend(n=1):
    global remaining
    remaining -= n
    require(remaining >= 0)

def literal_test_refuses(raw, obj):
    global remaining
    remaining = 1000000
    try:
        literal_frames(raw, obj)
    except (ValueError, struct.error, UnicodeError, OverflowError):
        return
    raise AssertionError('literal corruption accepted')

def literal_test_roundtrip(value, builder):
    global remaining
    remaining = 1000000
    raw = b'  %1 = const_string "' + value + b'"\n'
    result = literal_frames(raw, builder([value]))
    quoted = result.split(b' = const_string ', 1)[1].strip()
    require(json.loads(quoted.decode()).encode('latin1') == value)
    return raw

def literal_memo_refuses(raw, obj, memo):
    try:
        literal_frames(raw, obj, memo)
    except ValueError:
        return
    raise AssertionError('literal memo corruption accepted')

def literal_memo_selfcheck():
    global remaining
    remaining = 1000000
    raw = b'  %1 = const_string "normal"\n'
    obj = literal_test_macho([b'normal'])
    memo = {}
    before = remaining
    expected = literal_frames(raw, obj, memo)
    first_cost = before - remaining
    before = remaining
    require(literal_frames(raw, bytes(bytearray(obj)), memo) == expected)
    require(before - remaining < first_cost and len(memo) == 1)
    other = literal_test_elf([b'normal'])
    require(literal_frames(raw, other, memo) == expected)
    require(len(memo) == 2 and memo[obj] is not memo[other])
    literal_memo_refuses(raw, literal_test_macho([b'normal', b'other']), memo)
    literal_memo_refuses(raw.replace(b'normal', b'changed'), obj, memo)
    literal_memo_refuses(raw, b'', {})
    literal_memo_refuses(raw, obj, {b'one': {}, b'two': {}, b'three': {}})
    require(len(memo) == 2)
    require(literal_canonical(b'plain') == b'plain')
    values = [b'normal', b'other', b'\0table', b'']
    obj, memo = literal_test_macho(values), {}
    for value in values:
        raw = b'  %1 = const_string "' + value + b'"\n'
        quoted = json.dumps(value.decode('latin1')).encode()
        require(literal_frames(raw, obj, memo) == b'  %1 = const_string ' + quoted + b'\n')
    require(len(memo) == 1 and memo[obj][0] == values)
    previous = memo[obj][2]
    require(literal_frames(raw + b'\n', obj, memo) == raw + b'\n' and memo[obj][2] is previous)

def literal_index_refuses(address, width, duplicate=False):
    spend()
    index = {}
    try:
        literal_relocation_add(index, address, width, 0x0e000000, 64)
        if duplicate:
            literal_relocation_add(index, address, width, 0x0e000000, 64)
        literal_macho_pointer(index, 8, [(b'', ())], ())
    except ValueError:
        return
    raise AssertionError('literal relocation corruption accepted')

def literal_index_selfcheck():
    global remaining
    remaining = 1000000
    spend()
    index = {}
    for i in range(344):
        literal_relocation_add(index, i * 24, 8, i, 344 * 24)
    for i in range(302):
        require(literal_relocation_rows(index, i * 24) == [(i * 24, i)])
    require(1000000 - remaining == 1 + 344 * 3 + 302 * 34)
    for address, width in ((-1, 8), (57, 8), (8, 16), (1, 8), (9, 1), (31, 1)):
        literal_index_refuses(address, width)
    literal_index_refuses(8, 8, True)
    literal_relocation_add(index, 23, 1, 999, 344 * 24)
    literal_relocation_add(index, 23, 1, 999, 344 * 24)
    require(literal_relocation_rows(index, 24) == [(24, 1)])
    values = [b'scale-' + str(i).encode() for i in range(512)]
    raw = b''.join(b'  %1 = const_string "' + value + b'"\n' for value in values)
    for builder in (literal_test_macho, literal_test_elf):
        require(literal_frames(raw, builder(values)) == raw)

def literal_selfcheck():
    global remaining
    for builder in (literal_test_macho, literal_test_elf):
        for value in (b'', b'normal', b'quote"\\\n\0\xff'):
            literal_test_roundtrip(value, builder)
    fake = b'"\n  %4 = const_nil\n  %5 = rt_call slice_append_slice_fresh(%4, %9, %2, %3) []i64\n  %6 = const_string "'
    old = literal_test_roundtrip(fake, literal_test_macho)
    new = old.replace(b'slice_append_slice_fresh', b'slice_append_slice')
    literal_test_refuses(new, literal_test_macho([fake]))
    literal_test_refuses(old, literal_test_macho([]))
    literal_test_refuses(old, b'bad object')
    literal_test_refuses(new, literal_test_elf([fake]))
    literal_test_refuses(old, literal_test_elf([]))
    literal_test_refuses(old, literal_test_elf([fake])[:-1])
    literal_test_refuses(b'  %1 = const_string ""\nlong"\n', literal_test_macho([b'', b'"\nlong']))
    literal_test_refuses(b'  %1 = const_string "short"\nlong"\n', literal_test_macho([b'short', b'short"\nlong']))
    good = literal_test_macho([b'normal'])
    raw = b'  %1 = const_string "normal"\n'
    literal_test_refuses(raw, good[:-1])
    damaged = bytearray(good)
    damaged[-len(b'___bitstr_0\0')] = 10
    literal_test_refuses(raw, bytes(damaged))
    for offset, fmt, value in ((304, '<Q', len(good)), (312, '<Q', 1),
                               (296, '<Q', 1), (16, '<I', 0xffffffff),
                               (320, '<I', 0x0e000001), (232, '<I', 297)):
        damaged = bytearray(good)
        struct.pack_into(fmt, damaged, offset, value)
        literal_test_refuses(raw, bytes(damaged))
    elf = literal_test_elf([b'normal'])
    damaged = bytearray(elf)
    damaged[elf.find(b'__bitstr_0')] = 10
    literal_test_refuses(raw, bytes(damaged))
    damaged = bytearray(elf)
    struct.pack_into('<Q', damaged, 64 + 8 + 16, 1)
    literal_test_refuses(raw, bytes(damaged))
    remaining = 1000000
    require(literal_frames(old, literal_test_macho([fake])) != literal_frames(new, literal_test_macho([fake.replace(b'_fresh', b'')])) )
    remaining = 1000000
    require(literal_frames(old, literal_test_elf([fake])) == literal_frames(old, literal_test_macho([fake])))
    remaining = 1000000
    require(literal_canonical(b'%1 = new $t19\n') == literal_canonical(b'%1 = new $t2\n'))
    require(literal_canonical(b'  %1 = const_string "$t19"\n') != literal_canonical(b'  %1 = const_string "$t2"\n'))
    print('literal framing selfcheck OK')

import base64
import copy
import hashlib
import os
import subprocess
import sys

local = br'''func owned(%0: []i64) []i64 {
bb0(%0: []i64):
  %1 = const_int i64 0
  %2 = const_int i64 8
  %3 = rt_call slice_new(%1, %2, %1, %2) []i64
  %4 = rt_call slice_append_slice_fresh(%3, %0, %1, %2) []i64
  ret %4
}
'''
local_fixed = local.replace(b"slice_append_slice_fresh", b"slice_append_slice")
canon = os.path.join(sys.argv[1], 'selfhost-ir-canon.sh')
def proof_module(src, bulk):
    rows = src.rstrip(b"\n").decode("latin1").split("\n")
    st = ["[", "]", "i64"]
    specs = [("const_int", ["i64", "0"], ["i64"], None, []),
             ("const_int", ["i64", "8"], ["i64"], None, []),
             ("rt_call", [], st, "slice_new", ["%1", "%2", "%1", "%2"]),
             ("rt_call", [], st, bulk, ["%3", "%0", "%1", "%2"]),
             ("ret", ["%4"], [], None, [])]
    code = []
    for i, (op, tail, ty, name, args) in enumerate(specs):
        if name is not None:
            tail = [name, "("] + [x for a in args for x in (a, ",")][:-1] + [")"] + ty
        code.append(dict(row=rows[i + 2], ts=[op] + tail, out="%" + str(i + 1) if i < 4 else None,
                         op=op, ty=ty, name=name, args=args, targets=[]))
    graph = dict(header=rows[0], order=["bb0"], blocks={"bb0": dict(row=rows[1],
                 params=[["%0", st]], code=code)})
    raw = src.rstrip(b"\n")
    return dict(sha256=hashlib.sha256(raw).hexdigest(), chunks=[dict(kind="function",
                raw_b64=base64.b64encode(raw).decode(), graph=graph)])

def protocol(data, args=("--prove-owned-appends",)):
    env = {k: v for k, v in os.environ.items()
           if not k.startswith(("BIT", "LIBBITRT", "DIFFALL", "BOXLOCK"))
           and k not in ("ORACLE", "TIMEOUT_S", "BASH_ENV", "ENV")}
    return subprocess.run(["/bin/bash", canon, *args], input=data,
                          capture_output=True, timeout=10, env=env)

def wire(obj):
    return json.dumps(obj, separators=(",", ":")).encode()

def protocol_envelope(proof, originals, pools, frames=None):
    global remaining
    remaining = 1000000
    objects = [literal_test_macho(values) for values in pools]
    if frames is None:
        frames = [literal_frames(raw, obj) for raw, obj in zip(originals, objects)]
    return dict(version=2, comparison='iropt', work_left=1000000, proof=proof,
                original=[base64.b64encode(raw).decode() for raw in originals],
                objects=[base64.b64encode(obj).decode() for obj in objects],
                framed_sha256=[hashlib.sha256(raw).hexdigest() for raw in frames])

def protocol_refuses(payload, args=("--prove-owned-appends",)):
    answer = protocol(payload, args)
    assert (answer.returncode, answer.stdout, answer.stderr) == (1, b'', b''), payload[:100]

def protocol_positive(packet):
    answer = protocol(wire(packet))
    assert answer.returncode == 0 and answer.stderr == b'', (answer.returncode, answer.stderr)
    reply = json.loads(answer.stdout)
    assert set(reply) == {'version', 'query_ids', 'work_left'} and reply['version'] == 2
    assert reply['query_ids'] == [] and type(reply['work_left']) is int and 0 <= reply['work_left'] < 1000000

def protocol_bad_packets(packet):
    bad_packets = []
    for key, value in [('version', 1), ('work_left', 1000001), ('work_left', 0), ('extra', [])]:
        bad = copy.deepcopy(packet); bad[key] = value; bad_packets.append(bad)
    for key, value in [('version', 2), ('kind', 'owned'), ('extra', []), ('queries', [dict(id='q0')])]:
        bad = copy.deepcopy(packet); bad['proof'][key] = value; bad_packets.append(bad)
    for key in ('original', 'objects', 'framed_sha256'):
        bad = copy.deepcopy(packet); bad[key][1] = ''; bad_packets.append(bad)
    bad = copy.deepcopy(packet); bad['proof']['work_left'] = 999999; bad_packets.append(bad)
    bad = copy.deepcopy(packet); bad['proof'] = dict(version=1, work_left=1000000, raw=['eA==', 'eQ=='], queries=[dict(id='q0')]); bad_packets.append(bad)
    bad = copy.deepcopy(packet); bad['original'][0] = base64.b64encode(b'unrelated').decode(); bad_packets.append(bad)
    return bad_packets
def protocol_dispatch(packet):
    for args in [('--unknown-proof-mode',), ('--prove-owned-appends', 'extra')]:
        protocol_refuses(wire(packet), args)
    answer = protocol(b'', ())
    assert answer.returncode == 0 and answer.stderr == b'' and answer.stdout == b'selfhost-ir-canon.sh: self-check passed\n'
def protocol_canonical():
    proof = dict(version=1, work_left=1000000, kind='canonical', queries=[])
    raw = b'func example() $t19 {\nbb0():\n  ret\n}'
    packet = protocol_envelope(proof, [raw, raw.replace(b'$t19', b'$t2')], [[], []])
    packet['comparison'] = 'ir'
    answer = protocol(wire(packet))
    assert answer.returncode == 0 and answer.stderr == b''
    for value in (b'line\nbreak', b'quoted"\ntext', b'a\0b'):
        raw_literal = b'func literal() void {\nbb0():\n  %1 = const_string "' + value + b'"\n  ret\n}'
        protocol_positive(protocol_envelope(proof, [raw_literal, raw_literal], [[value], [value]]))
    old = b'func example() void {\nbb0():\n  %1 = const_string "$t19"\n  ret\n}'
    packet = protocol_envelope(proof, [old, old.replace(b'$t19', b'$t2')], [[b'$t19'], [b'$t2']])
    protocol_refuses(wire(packet))

def capture_status(wrapper, old, new):
    script = '. "$1"; diffiropt_capture_text "$2" "$3"'
    result = subprocess.run(['/bin/bash', '-c', script, 'literal-capture-test', wrapper, old, new],
                            capture_output=True, timeout=10)
    assert result.stdout == result.stderr == b''
    return result.returncode

def capture_selfcheck():
    import tempfile
    wrapper = os.path.join(sys.argv[1], 'selfhost-diffiropt.sh')
    with tempfile.TemporaryDirectory(prefix='bit-literal-selfcheck-') as root:
        old, new = os.path.join(root, 'old'), os.path.join(root, 'new')
        for value, expected in [(b'text', 0), (b'"quoted"', 3), (b'with\0nul', 1)]:
            with open(old, 'wb') as stream:
                stream.write(b'text')
            with open(new, 'wb') as stream:
                stream.write(value)
            assert capture_status(wrapper, old, new) == expected
        link = os.path.join(root, 'link')
        os.symlink(new, link)
        assert capture_status(wrapper, old, link) == 2
        assert capture_status(wrapper, old, root) == 2
        os.unlink(new)
        assert capture_status(wrapper, old, link) == 2
        with open(new, 'wb') as stream:
            stream.truncate(8388608)
        assert capture_status(wrapper, old, new) == 2
    print('literal captures: text/quotes/NUL/bounds/nofollow controls passed')

def protocol_selfcheck():
    query = dict(id='q0', side='oracle', fn=0, kind='owned', block='bb0', index=3, value=None)
    retired = dict(version=1, work_left=1000000, source=None, queries=[query],
                   modules=dict(oracle=proof_module(local, 'slice_append_slice_fresh'),
                                candidate=proof_module(local_fixed, 'slice_append_slice')))
    protocol_refuses(wire(protocol_envelope(retired, [local, local_fixed], [[], []])))
    proof = dict(version=1, work_left=1000000, kind='canonical', queries=[])
    packet = protocol_envelope(proof, [local, local], [[], []])
    protocol_positive(packet)
    bad_packets = protocol_bad_packets(packet)
    duplicate = wire(packet).replace(b'"version":2', b'"version":2,"version":2', 1)
    for payload in [b'{', b'', duplicate, wire(packet) + b' trailing', wire(proof)] + [wire(b) for b in bad_packets]:
        protocol_refuses(payload)
    protocol_dispatch(packet)
    protocol_canonical()
    print('canonical proof protocol: strict schema, budget, dispatch, framing and retired identity refusal passed')
literal_index_selfcheck()
literal_selfcheck()
literal_memo_selfcheck()
protocol_selfcheck()
capture_selfcheck()
DIFFIROPT_LITERAL_TESTS
  [ "$read_rc" -eq 1 ] || exit 1
  exec python3 -I /dev/fd/3 "$(dirname -- "${BASH_SOURCE[0]}")" 3<<<"${DIFFIROPT_LITERAL_PYTHON}"$'\n'"${DIFFIROPT_LITERAL_FIXTURES}"$'\n'"${DIFFIROPT_LITERAL_TESTS}"
fi

# Ordinary execution remains the table-driven iropt differential.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  exec bash "$(dirname -- "$0")/selfhost-diffdump.sh" iropt "$@"
fi
