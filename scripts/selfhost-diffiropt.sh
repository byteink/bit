#!/usr/bin/env bash
# Sourceable, fixed framing code for the two-sided ownership proof (#8271).
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

def literal_macho_pointer(data, section, relative, symbols, wanted):
    found = 0
    for i in range(section[7]):
        address, bits = literal_unpack(data, section[6] + i * 8, '<iI')
        require(address >= 0)
        width = 1 << ((bits >> 25) & 3)
        require(address <= section[3] - width)
        if address < relative + 24 and relative < address + width:
            require(address == relative and bits >> 24 == 14)
            index = bits & 0xffffff
            require(index < len(symbols) and symbols[index][1] == wanted)
            found += 1
    require(found == 1)

def literal_macho_pool(data):
    sections, symtab = literal_macho_commands(data)
    symbols, pairs = literal_macho_symbols(data, sections, symtab)
    values, previous = [], None
    for header, payload in pairs:
        hs, ho, raw = literal_macho_location(data, sections, header, 24)
        pointer, size, base = struct.unpack('<3Q', raw)
        require(pointer == base == 0 and size <= len(data) and ho % 8 == 0)
        ds, do, value = literal_macho_location(data, sections, payload, size)
        require(hs[0].rstrip(b'\0') == b'__data' and ds[0].rstrip(b'\0') == b'__const')
        require(hs[1].rstrip(b'\0') == b'__DATA' and ds[1].rstrip(b'\0') == b'__TEXT')
        require(hs[8] & 255 == ds[8] & 255 == 0)
        literal_macho_pointer(data, hs, ho, symbols, payload)
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

def literal_elf_relocation(row, symbols, machine, header, payload, section_size):
    offset, info, addend = row
    require(info & 0xffffffff == (1 if machine == 62 else 257) and addend == 0)
    require(offset <= section_size - 8)
    if not header[4] - 7 <= offset < header[4] + 24:
        return 0
    require(offset == header[4] and addend == 0)
    target = info >> 32
    require(target < len(symbols) and symbols[target][1] == payload)
    return 1

def literal_elf_pointer(data, sections, table, symbols, machine, header, payload):
    found = 0
    for section in sections:
        if section[1] != 4 or section[7] != header[3]:
            continue
        require(section[6] == table and section[9] == 24 and section[5] % 24 == 0)
        for i in range(section[5] // 24):
            row = literal_unpack(data, section[4] + i * 24, '<QQq')
            found += literal_elf_relocation(row, symbols, machine, header, payload, sections[header[3]][5])
    require(found == 1)

def literal_elf_pool(data):
    machine, sections, names = literal_elf_sections(data)
    table, symbols, pairs = literal_elf_symbols(data, sections)
    values, previous = [], None
    for header, payload in pairs:
        hs, raw = literal_elf_location(data, sections, header, 24)
        pointer, size, base = struct.unpack('<3Q', raw)
        require(pointer == base == 0 and size <= len(data))
        ds, value = literal_elf_location(data, sections, payload, size)
        require(header[3] == payload[3] and names[header[3]] == b'.rodata')
        require(hs[1] == ds[1] == 1 and hs[2] & 7 == 2)
        require(header[4] == (payload[4] + size + 7) // 8 * 8)
        literal_elf_pointer(data, sections, table, symbols, machine, header, payload)
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

def literal_frames(raw, object_raw, memo=None):
    require(type(raw) is bytes and type(object_raw) is bytes and len(raw) + len(object_raw) <= 8388608)
    if memo is None:
        spend()
        memo = {}
    require(type(memo) is dict and len(memo) <= 2)
    if object_raw not in memo:
        require(len(memo) < 2)
        spend()
        memo[object_raw] = literal_trie(literal_pool(object_raw))
    pool = memo[object_raw]
    spend(len(raw))
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

# Fixed data-only fixture mode shares the pure constructors with the tests.
if [ "${BASH_SOURCE[0]}" = "$0" ] && [ "$#" -eq 1 ] && [ "$1" = --fixture-object ]; then
  diffiropt_literal_library || exit 1
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

def protocol_literal(packet, token, expected):
    proof = copy.deepcopy(packet['proof'])
    proof['queries'][0]['index'] = 4
    raw_inputs = []
    escaped = json.dumps('line\nbreak') if expected == 0 else token
    for module in proof['modules'].values():
        chunk = module['chunks'][0]
        graph = chunk['graph']; code = graph['blocks']['bb0']['code']
        code.insert(3, dict(row='  %5 = const_string ' + escaped,
                           ts=['const_string', escaped], out='%5', op='const_string',
                           ty=['string'], name=None, args=[], targets=[]))
        raw = '\n'.join([graph['header'], graph['blocks']['bb0']['row']]
                         + [n['row'] for n in code] + ['}']).encode('latin1')
        chunk['raw_b64'] = base64.b64encode(raw).decode()
        module['sha256'] = hashlib.sha256(raw).hexdigest()
        raw_inputs.append(raw.replace(escaped.encode(), token.encode(), 1))
    frames = [base64.b64decode(m['chunks'][0]['raw_b64']) for m in proof['modules'].values()]
    envelope = protocol_envelope(proof, raw_inputs, [[b'line\nbreak']] * 2, frames)
    answer = protocol(wire(envelope))
    assert answer.returncode == expected and answer.stderr == b'' and bool(answer.stdout) == (expected == 0)


def protocol_positive(packet):
    answer = protocol(wire(packet))
    assert answer.returncode == 0 and answer.stderr == b'', (answer.returncode, answer.stderr)
    reply = json.loads(answer.stdout)
    assert set(reply) == {'version', 'query_ids', 'work_left'} and reply['version'] == 2
    assert reply['query_ids'] == ['q0'] and type(reply['work_left']) is int and 0 <= reply['work_left'] < 1000000


def protocol_bad_packets(packet, query):
    bad_packets = []
    for key, value in [('version', 1), ('work_left', 1000001), ('work_left', 0), ('extra', [])]:
        bad = copy.deepcopy(packet); bad[key] = value; bad_packets.append(bad)
    for key, value in [('version', 2), ('source', 'untrusted.bit'), ('extra', []), ('queries', [])]:
        bad = copy.deepcopy(packet); bad['proof'][key] = value; bad_packets.append(bad)
    bad = copy.deepcopy(packet); del bad['proof']['queries'][0]['id']; bad_packets.append(bad)
    bad = copy.deepcopy(packet); bad['proof']['queries'].append(copy.deepcopy(query)); bad_packets.append(bad)
    bad = copy.deepcopy(packet); bad['proof']['queries'][0]['fn'] = 1; bad_packets.append(bad)
    bad = copy.deepcopy(packet); bad['proof']['modules']['oracle']['chunks'][0]['graph']['owned'] = True; bad_packets.append(bad)
    bad = copy.deepcopy(packet); bad['proof']['modules']['oracle']['sha256'] = '0' * 64; bad_packets.append(bad)
    bad = copy.deepcopy(packet); bad['proof']['modules']['candidate']['chunks'][0]['graph'] = None; bad_packets.append(bad)
    bad = copy.deepcopy(packet); bad['proof']['modules']['oracle']['chunks'][0]['graph']['header'] = ['nested']; bad_packets.append(bad)
    bad = copy.deepcopy(packet); bad['proof']['modules']['oracle']['chunks'][0]['graph']['blocks']['bb0']['code'][0]['ts'][-1] = '1'; bad_packets.append(bad)
    bad = copy.deepcopy(packet)
    chunk = bad['proof']['modules']['oracle']['chunks'][0]; node = chunk['graph']['blocks']['bb0']['code'][2]
    node.update(row='  %3 = field_get %0[0] []i64', ts=['field_get', '%0', '[', '0', ']', '[', ']', 'i64'], op='field_get', name=None, args=[])
    raw = local.rstrip(b'\n').replace(b'  %3 = rt_call slice_new(%1, %2, %1, %2) []i64', node['row'].encode())
    chunk['raw_b64'] = base64.b64encode(raw).decode(); bad['proof']['modules']['oracle']['sha256'] = hashlib.sha256(raw).hexdigest()
    bad['original'][0] = base64.b64encode(raw).decode(); bad['framed_sha256'][0] = hashlib.sha256(raw).hexdigest(); bad_packets.append(bad)
    for key in ('original', 'objects', 'framed_sha256'):
        bad = copy.deepcopy(packet); bad[key][1] = ''; bad_packets.append(bad)
    bad = copy.deepcopy(packet); bad['proof']['work_left'] = 999999; bad_packets.append(bad)
    bad = copy.deepcopy(packet); bad['proof'] = dict(version=1, work_left=1000000, raw=['eA==', 'eQ=='], queries=[dict(id='q0')]); bad_packets.append(bad)
    bad = copy.deepcopy(packet); bad['original'][0] = base64.b64encode(b'func unrelated() void {\nbb0():\n  ret\n}').decode(); bad_packets.append(bad)
    return bad_packets


def protocol_dispatch(packet):
    for args in [('--unknown-proof-mode',), ('--prove-owned-appends', 'extra')]:
        protocol_refuses(wire(packet), args)
    answer = protocol(b'', ())
    assert answer.returncode == 0 and answer.stderr == b'' and answer.stdout == b'selfhost-ir-canon.sh: self-check passed\n'
    for token, expected in [('"line\nbreak"', 0), ('"line"\nbreak', 1)]:
        protocol_literal(packet, token, expected)


def protocol_canonical():
    proof = dict(version=1, work_left=1000000, kind='canonical', queries=[])
    raw = b'func example() $t19 {\nbb0():\n  ret\n}'
    packet = protocol_envelope(proof, [raw, raw.replace(b'$t19', b'$t2')], [[], []])
    packet['comparison'] = 'ir'
    answer = protocol(wire(packet))
    assert answer.returncode == 0 and answer.stderr == b''
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
    proof = dict(version=1, work_left=1000000, source=None, queries=[query],
                 modules=dict(oracle=proof_module(local, 'slice_append_slice_fresh'),
                              candidate=proof_module(local_fixed, 'slice_append_slice')))
    packet = protocol_envelope(proof, [local.rstrip(b'\n'), local_fixed.rstrip(b'\n')], [[], []])
    protocol_positive(packet)
    bad_packets = protocol_bad_packets(packet, query)
    duplicate = wire(packet).replace(b'"version":2', b'"version":2,"version":2', 1)
    for payload in [b'{', b'', duplicate, wire(packet) + b' trailing', wire(proof)] + [wire(b) for b in bad_packets]:
        protocol_refuses(payload)
    protocol_dispatch(packet)
    protocol_canonical()
    print('6175 proof protocol: strict v2 schema, query IDs, budget, dispatch and framing controls passed')


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
