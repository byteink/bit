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
  diffdump_owned_append_library && diffiropt_literal_library || exit 1
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
    return proof, framed

def main():
    global remaining
    data = sys.stdin.buffer.read(8 * 1024 * 1024 + 1)
    require(0 < len(data) <= 8 * 1024 * 1024)
    envelope = json.loads(data, object_pairs_hook=unique_object)
    require(type(envelope) is dict)
    remaining = integer(envelope["work_left"], 1, 1000000)
    require(envelope["comparison"] in {"ir", "iropt"})
    obj, framed = framed_proof(envelope)
    keys(obj, "version work_left kind queries")
    normalized = [literal_canonical(raw) for raw in framed]
    require(obj["kind"] == "canonical" and obj["queries"] == [])
    require(normalized[0] == normalized[1])
    response = json.dumps({"version": 2, "query_ids": [q["id"] for q in obj["queries"]],
                           "work_left": remaining}, separators=(",", ":")).encode("ascii") + b"\n"
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
  DIFFDUMP_OWNED_APPEND_CODE="${DIFFIROPT_LITERAL_PYTHON}"$'\n'"${DIFFDUMP_OWNED_APPEND_PYTHON}"$'\n'"${DIFFDUMP_OWNED_APPEND_ENGINE}"
  [ "${#DIFFDUMP_OWNED_APPEND_CODE}" -le 65536 ] || exit 1
  exec python3 -I /dev/fd/3 3<<<"${DIFFDUMP_OWNED_APPEND_CODE}"
fi
# Keep the ordinary selfcheck in its existing test file, without a child PID.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  exec /bin/bash "$(dirname -- "${BASH_SOURCE[0]}")/selfhost-ir-signatures-selfcheck.sh" --canon-only
fi
