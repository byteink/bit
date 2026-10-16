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
# intentional lowering improvement had landed since the pin — #3107 was the
# first that did, and it reddened every IR arm by construction: a mismatch is
# no longer automatically a REGRESSION. It is checked first against a small
# table of DECLARED TRANSFORM SIGNATURES (`explainMismatch` below) — a strict
# structural identity, proven against the pinned oracle and tested with
# positive and negative controls. Only a divergence that satisfies a signature
# is downgraded to EXPLAINED (printed, not failed); anything else still fails
# exactly as before.
#
# WHY NOT A PER-FILE ALLOWLIST INSTEAD. There was one — the expected-mismatch
# list #1883 deleted, "so a known difference could be written down instead of
# fixed." A signature is not that list reborn: an allowlist names a FILE and
# accepts anything it does next; a signature names an IDENTITY the delta must
# satisfy, checked fresh on every run, and a second, unrelated bug landing on
# an already-explained file still fails it.
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
# like any other divergence.
#
# WHICH HOSTS. Every declared signature applies on EVERY host (aarch64-macos,
# aarch64-linux, x86_64-linux) — unlike #3103's diffruntime object-byte arm,
# which is aarch64-only because it disassembles target MACHINE CODE.
# `--dump-ir-pre`/`--dump-ir` are pre-codegen: the SSA text carries no
# register or instruction-selection content, so it does not vary by target
# ISA at all.
#
# COST PER LANDING, as this ticket names up front: a future lowering change
# that alters IR shape needs its OWN signature added to `explainMismatch`
# below: compare the real branch with the pinned oracle, prove the transform's
# structural preconditions, and reject unrelated differences with controls.
# Every eligible and unexplained corpus path must remain visible. A signature
# cannot accept a file merely because its name or opcode counts match; #1883
# is why that is rejected.
#
# Retirement history is preserved in docs/development/dump-differential.md.
#
# #8259 removes a full-length byte-header copy before an independent string copy.
# This identity checks structure and uses, not opcode counts or source filenames.

# explainMismatch <oracle_text> <bit2_text> <kind> [file]
explainMismatch() {
  [ "$3" = iropt ] || return 1
  { printf '%s\0%s' "$1" "$2"; } | python3 /dev/fd/3 3<<'PYTHON'
import re
import sys

TOKEN = re.compile(rb'"(?:\\.|[^"\\])*"|[A-Za-z_$@][A-Za-z0-9_$@.%]*|(?<![A-Za-z0-9_$@.%])%[0-9]+(?![A-Za-z0-9_$@.%])|.', re.S)
DEF = re.compile(rb"  (%[0-9]+) = (.*)")
LABEL = re.compile(rb"(bb[0-9]+)\(.*\):")
COPY = re.compile(rb"  (%[0-9]+) = rt_call slice_slice\((%[0-9]+), (%[0-9]+), (%[0-9]+)\) \[\]u8")
READ = re.compile(rb"  %[0-9]+ = rt_call string_from_byte_range\((%[0-9]+), %[0-9]+, (%[0-9]+)\) string")

def tokens(line):
    prefix = []
    if line.startswith(b"func ") and b"(" in line:
        name, line = line.split(b"(", 1)
        prefix, line = [name], b"(" + line
    result = TOKEN.findall(line)
    if b'"' in result:
        raise ValueError("unclosed literal")
    return prefix + result

def is_id(token):
    return re.fullmatch(rb"%[0-9]+", token) is not None

def safe_effects(line):
    # Unknown instructions cannot establish that the saved header stays unchanged.
    if LABEL.fullmatch(line):
        return True
    definition = DEF.fullmatch(line)
    body = definition[2] if definition else line.removeprefix(b"  ")
    if body.startswith(b"rt_call "):
        return re.match(rb"rt_call (panic|slice_slice|string_from_byte_range)\(", body)
    return body.split(b" ", 1)[0] in {
        b"const_int", b"const_string", b"field_get", b"slice_len",
        b"icmp_slt", b"icmp_sgt", b"br", b"jump", b"unreachable", b"ret"}

def scan_blocks(lines, start, end):
    at, definitions, last = {}, {}, {}
    current = None
    for i in range(start + 1, end):
        label = LABEL.fullmatch(lines[i])
        if label:
            current = label[1]
            if current in last:
                raise ValueError("duplicate block")
        if current is None or not safe_effects(lines[i]):
            return None
        at[i], last[current] = current, lines[i]
        definition = DEF.fullmatch(lines[i])
        if definition:
            if definition[1] in definitions:
                raise ValueError("duplicate definition")
            definitions[definition[1]] = (i, definition[2])
    return at, definitions, last

def targets(line):
    if line.startswith((b"  br ", b"  jump ")):
        result = re.findall(rb"bb[0-9]+(?=\()", line)
        if len(result) != (2 if line.startswith(b"  br ") else 1):
            raise ValueError("unknown branch")
        return result
    if line != b"  unreachable" and not re.fullmatch(rb"  ret(?: .*)?", line):
        raise ValueError("unknown terminator")
    return []

def function_info(lines, start, end):
    info = scan_blocks(lines, start, end)
    if info is None:
        return None
    at, definitions, last = info
    pred = {b: set() for b in last}
    for block, line in last.items():
        for target in targets(line):
            pred[target].add(block)
    return at, definitions, pred

def entry_chain(block, pred):
    chain = set()
    for unused in range(len(pred)):
        if block in chain:
            return set()
        chain.add(block)
        if block == b"bb0":
            return chain if not pred[block] else set()
        if len(pred[block]) != 1:
            return set()
        block = next(iter(pred[block]))
    return set()

def copy_operands(lines, i, at, uses):
    copy = COPY.fullmatch(lines[i])
    if not copy or i + 1 not in at or at[i] != at[i + 1]:
        return None
    read = READ.fullmatch(lines[i + 1])
    if not read or read[1] != copy[1] or read[2] != copy[4]:
        return None
    return copy if uses.get(copy[1]) == [i + 1] else None

def full_header(copy, definitions, at, chain, i):
    values = [definitions.get(t) for t in copy.group(2, 3, 4)]
    if any(v is None for v in values):
        return False
    source, zero, length = values
    if source[0] >= length[0]:
        return False
    if any(pos >= i or at[pos] not in chain for pos, unused in values):
        return False
    return (re.fullmatch(rb"field_get %[0-9]+\[[0-9]+\] \[\]u8", source[1])
            and zero[1] == b"const_int i64 0" and length[1] == b"slice_len " + copy[2])

def copied_reader(lines, i, info, uses):
    at, definitions, pred = info
    copy = copy_operands(lines, i, at, uses)
    if copy is None or not full_header(copy, definitions, at, entry_chain(at[i], pred), i):
        return None
    return lines[i + 1].replace(b"(" + copy[1] + b",", b"(" + copy[2] + b",", 1)

def uses_of(lines, at):
    uses = {}
    for i in at:
        row = list(filter(is_id, tokens(lines[i])))
        row = row[1:] if DEF.fullmatch(lines[i]) else row
        for token in row:
            uses.setdefault(token, []).append(i)
    return uses

def function_choices(lines, start, end):
    info = function_info(lines, start, end)
    if info is None:
        return {}
    uses, result = uses_of(lines, info[0]), {}
    for i in info[0]:
        reader = copied_reader(lines, i, info, uses)
        if reader is not None:
            result[i] = reader
    return result

def eligible(lines):
    result, start = {}, None
    for end, line in enumerate(lines):
        if line.startswith(b"func "):
            if start is not None:
                raise ValueError("nested function")
            start = end
        if line != b"}" or start is None:
            continue
        result.update(function_choices(lines, start, end))
        start = None
    if start is not None:
        raise ValueError("unclosed function")
    return result

def same_line(left, right, maps):
    if maps is None:
        return left == right
    forward, reverse = (dict(m) for m in maps)
    lt, rt = tokens(left), tokens(right)
    if len(lt) != len(rt):
        return False
    for a, b in zip(lt, rt):
        if not is_id(a):
            if a != b:
                return False
            continue
        if not is_id(b) or forward.get(a, b) != b or reverse.get(b, a) != a:
            return False
        forward[a], reverse[b] = b, a
    maps[:] = [forward, reverse]
    return True

def compare(old, new):
    choices, maps = eligible(old), None
    i = j = changed = 0
    while i < len(old) and j < len(new):
        if old[i].startswith(b"func "):
            maps = [{}, {}]
        if same_line(old[i], new[j], maps):
            if old[i] == b"}":
                maps = None
            i, j = i + 1, j + 1
        elif i in choices and same_line(choices[i], new[j], maps):
            i, j, changed = i + 2, j + 1, changed + 1
        else:
            return False
    return changed > 0 and i == len(old) and j == len(new)


try:
    data = sys.stdin.buffer.read(8 * 1024 * 1024 + 1)
    if len(data) > 8 * 1024 * 1024 or data.count(b"\0") != 1:
        raise ValueError("input bound or separator")
    old, new = data.split(b"\0")
    if not compare(old.split(b"\n"), new.split(b"\n")):
        sys.exit(1)
except (ValueError, KeyError, IndexError):
    sys.exit(1)
print("8259-owned-byte-header-copy")
PYTHON
}

# declaredSignatureNames [kind] -- the retirement audit consults this table.
declaredSignatureNames() {
  case "${1:-iropt}" in
    iropt) printf '%s\n' '8259-owned-byte-header-copy' ;;
  esac
}

# shellcheck source=scripts/selfhost-ir-canon.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/selfhost-ir-canon.sh"
