#!/usr/bin/env python3
"""Converter for tests/imports/regexconform/: Go's regexp `findTests` table
(https://github.com/golang/go/blob/<tag>/src/regexp/find_test.go) -> a Bit
data table (main.bit) plus a golden `expected` file, both derived
mechanically from the same parse of Go's source so the corpus can be
refreshed by re-running this script against a newer Go release.

Usage:
    python3 gen.py --fetch [--tag go1.27.0]     # download the pinned tag
    python3 gen.py --input find_test.go          # use an already-fetched copy

Either way, writes main.bit, expected and SKIPPED.tsv next to this script.
Only the Python 3 standard library — nothing to install.
"""
import argparse
import datetime
import os
import re
import sys
import urllib.request

DEFAULT_TAG = "go1.27.0"
HERE = os.path.dirname(os.path.abspath(__file__))


def src_url(tag):
    return f"https://raw.githubusercontent.com/golang/go/{tag}/src/regexp/find_test.go"


def fetch(tag, cache_path):
    with urllib.request.urlopen(src_url(tag)) as r:  # nosec: pinned https raw.githubusercontent.com URL
        data = r.read()
    with open(cache_path, "wb") as f:
        f.write(data)
    return data.decode("utf-8")


# --- Go-source parsing: extract the `findTests` []FindTest{...} table ------
#
# Both scanning functions below share one rule: a `"..."` or `` `...` ``
# literal is opaque to structure (a brace or comma inside one is text, not
# syntax). `skip_string_literal` is the one place that rule is implemented,
# so a fix to it reaches both callers instead of drifting between two copies.

def skip_string_literal(s, i):
    """`s[i]` is `"` or `` ` ``; returns the index just past the literal's
    closing quote/backtick. Handles a Go interpreted string's `\\"` escape;
    a raw string has no escapes at all."""
    quote = s[i]
    i += 1
    n = len(s)
    while i < n:
        if quote == '"' and s[i] == "\\":
            i += 2
            continue
        if s[i] == quote:
            return i + 1
        i += 1
    return i


def extract_table_body(src):
    marker = "var findTests = []FindTest{"
    start = src.index(marker) + len(marker)
    depth = 1
    i = start
    while depth > 0:
        if src[i] == "{":
            depth += 1
        elif src[i] == "}":
            depth -= 1
        i += 1
    return src[start:i - 1]


def split_top_level_entries(body):
    """Split a []FindTest{ {...}, {...}, ... } body into its `{...}` entries."""
    entries = []
    depth = 0
    start = None
    i, n = 0, len(body)
    while i < n:
        ch = body[i]
        if ch in "\"`":
            i = skip_string_literal(body, i)
            continue
        if ch == "{":
            if depth == 0:
                start = i
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                entries.append(body[start:i + 1])
        i += 1
    return entries


def split_top_level_fields(entry):
    """entry is one `{ pat, text, max, matches }` — split on its top-level
    commas, respecting nested (), [], {} and string literals."""
    assert entry[0] == "{" and entry[-1] == "}"
    inner = entry[1:-1]
    fields = []
    depth = 0
    field_start = 0
    i, n = 0, len(inner)
    while i < n:
        ch = inner[i]
        if ch in "\"`":
            i = skip_string_literal(inner, i)
            continue
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
        elif ch == "," and depth == 0:
            fields.append(inner[field_start:i].strip())
            field_start = i + 1
        i += 1
    fields.append(inner[field_start:].strip())
    # A Go composite literal may carry a trailing comma before the closing
    # brace; that produces one empty field at the end.
    while fields and fields[-1] == "":
        fields.pop()
    return fields


# --- Go string-literal decoding: both forms produce raw BYTES, since a Go
# string is a byte sequence, not necessarily valid UTF-8 (find_test.go's own
# "invalid UTF-8 subject" rows rely on that). -------------------------------

_GO_ESCAPE_1 = {"a": 0x07, "b": 0x08, "f": 0x0C, "n": 0x0A, "r": 0x0D,
                "t": 0x09, "v": 0x0B, "\\": 0x5C, "'": 0x27, '"': 0x22}


def decode_one_escape(s, i):
    """`s[i]` is the character right after a backslash. Returns
    (decoded_bytes, next_index)."""
    c = s[i]
    if c in _GO_ESCAPE_1:
        return bytes([_GO_ESCAPE_1[c]]), i + 1
    if c == "x":
        return bytes([int(s[i + 1:i + 3], 16)]), i + 3
    if c == "u":
        return chr(int(s[i + 1:i + 5], 16)).encode("utf-8"), i + 5
    if c == "U":
        return chr(int(s[i + 1:i + 9], 16)).encode("utf-8"), i + 9
    if c.isdigit():
        return bytes([int(s[i:i + 3], 8)]), i + 3
    raise ValueError(f"unhandled Go escape \\{c}")


def decode_go_interpreted(lit):
    assert lit[0] == '"' and lit[-1] == '"'
    s = lit[1:-1]
    out = bytearray()
    i, n = 0, len(s)
    while i < n:
        if s[i] != "\\":
            out.extend(s[i].encode("utf-8"))
            i += 1
            continue
        piece, i = decode_one_escape(s, i + 1)
        out.extend(piece)
    return bytes(out)


def decode_go_raw(lit):
    assert lit[0] == "`" and lit[-1] == "`"
    return lit[1:-1].replace("\r\n", "\n").encode("utf-8")


def decode_go_string_field(field):
    field = field.strip()
    if field.startswith("`"):
        return decode_go_raw(field)
    if field.startswith('"'):
        return decode_go_interpreted(field)
    raise ValueError(f"not a string literal: {field!r}")


def decode_build_call(field):
    """Go's `build(n, x...)` helper: n matches, each with len(x)/n ints
    (start,end pairs for the whole match then each capture group, -1 for a
    group that did not participate). `nil` means no match at all."""
    field = field.strip()
    if field == "nil":
        return None
    m = re.match(r"^build\((.*)\)$", field, re.S)
    assert m, f"unrecognised matches field: {field!r}"
    nums = [int(x) for x in re.split(r"[,\s]+", m.group(1).strip()) if x]
    n, x = nums[0], nums[1:]
    run_len = len(x) // n
    return [x[j * run_len:(j + 1) * run_len] for j in range(n)]


def parse_entry(entry):
    fields = split_top_level_fields(entry)
    assert len(fields) == 4, f"expected 4 fields, got {len(fields)}: {entry!r}"
    pat = decode_go_string_field(fields[0])
    subj = decode_go_string_field(fields[1])
    max_n = int(fields[2])
    matches = decode_build_call(fields[3])
    return pat, subj, max_n, matches


# --- skip classification: epic #2025's non-goals, and Bit's own contract ---

def skip_reason(pat_bytes, subj_bytes):
    try:
        pat = pat_bytes.decode("utf-8")
    except UnicodeDecodeError:
        return "invalid-utf8"  # pattern itself is not valid UTF-8
    try:
        subj_bytes.decode("utf-8")
    except UnicodeDecodeError:
        # Bit's `std/regex` contract is UTF-8 input only; Go's engine is
        # byte-oriented and substitutes U+FFFD per invalid byte, a behaviour
        # this engine has no equivalent of.
        return "invalid-utf8"
    if re.search(r"\\[1-9]", pat):
        return "backreference"  # epic #2025: no backreferences, ever
    if re.search(r"\(\?<?[=!]", pat):
        return "lookaround"  # epic #2025: no lookaround, ever
    if "\\p{" in pat or "\\P{" in pat:
        return "unicodeprop"  # #2032, not yet implemented
    if "\\G" in pat:
        return "anchorG"  # epic #2025: explicitly out of scope
    if re.search(r"[*+?}]\+", pat):
        return "possessive"  # epic #2025: explicitly out of scope
    return None


# --- Bit string-literal rendering -------------------------------------------

_BIT_SIMPLE_ESCAPES = {"\\": "\\\\", '"': '\\"', "$": "\\$",
                        "\n": "\\n", "\t": "\\t", "\r": "\\r"}


def bit_string_literal(s):
    """`s` is a Python str already proven to be valid UTF-8 (round-tripped
    through decode_go_string_field then .decode('utf-8')). Emits a Bit
    INTERPRETED string literal: ASCII printable verbatim, `\\`/`"`/`$`/
    control bytes escaped, anything >= 0x80 as `\\u{...}` so the generated
    source never depends on a raw multi-byte character surviving intact."""
    out = ['"']
    for ch in s:
        cp = ord(ch)
        if ch in _BIT_SIMPLE_ESCAPES:
            out.append(_BIT_SIMPLE_ESCAPES[ch])
        elif cp < 0x20 or cp == 0x7F:
            out.append("\\x%02x" % cp)
        elif cp < 0x80:
            out.append(ch)
        else:
            out.append("\\u{%x}" % cp)
    out.append('"')
    return "".join(out)


def go_want_string(matches):
    """The flat "count=<n> s0,e0,... ..." string Go's own table implies for
    this row — embedded verbatim in the generated Row as `want`, and NEVER
    adjusted afterward. This is the ground truth a disagreement is measured
    against, kept separate from `expected` (this project's own top-level
    pass/fail report), which reflects std/regex's CURRENT behaviour and is
    recaptured by re-running the corpus, exactly like every other
    tests/imports/* project's `expected` file."""
    if matches is None:
        return "count=0"
    parts = [",".join(str(v) for v in m) for m in matches]
    return f"count={len(matches)} " + " ".join(parts)


# --- main.bit rendering ------------------------------------------------

ROWS_PER_FN = 22  # keeps each generated `rowsN()` well under E0201's 80-line cap

HEADER_TEMPLATE = '''\
// std/regex conformance corpus: Go's `regexp` package's own `findTests`
// table (#2056, epic #2025).
//
// SOURCE: {url}
//   Go release {tag}, fetched {fetched}.
// Every row is `{{pattern, subject, limit, [][]int matches}}` from that
// file's `var findTests`, converted MECHANICALLY by the committed
// `gen.py` in this directory — never hand-transcribed. `matches[k]` is the
// k-th non-overlapping match's flat (start,end) pairs: group 0 (the whole
// match) first, then each capturing group in index order, `-1` for a group
// that did not participate. Re-running `gen.py` against a newer Go tag
// regenerates this file, `expected` and `SKIPPED.tsv` together.
//
// {kept} of {total} source rows are represented here; {skipped} are on the
// committed skip list (SKIPPED.tsv) — see that file for the one-word reason
// each was dropped. Go's regexp/RE2 syntax has no backreferences and no
// lookaround (the engine that produced this table has neither), so every
// row on the skip list here is Bit's own "Input is UTF-8" contract, not an
// epic-scoped exclusion; `gen.py`'s `skip_reason` still checks for
// backreference/lookaround/`\\\\p{{}}`/`\\\\G`/possessive-quantifier syntax so
// a future Go release that somehow introduced one would be caught and
// skipped, not silently miscompiled.
//
// A disagreement here is a bug in std/regex until proven otherwise (Go's
// table is the older, far more exercised artifact). `want` below is never
// edited to make a row pass — it is Go's own table, mechanically converted;
// a row outside this engine's contract belongs on the skip list with a
// reason instead.
//
// GRADING. Every row's `want` is Go's ground truth and is immutable once
// generated. This program compares its own `rowStr` output against `want`
// FOR EVERY ROW and prints a summary ("N of M vectors pass") plus one block
// per disagreement — never a per-row raw dump — because the outer harness
// (tests/bit/importsrun.bit) grades this project by diffing its stdout
// against the checked-in `expected` file byte for byte. If `want` were
// printed and diffed directly, the only way to make this project's gate
// pass while std/regex has open bugs would be editing `expected` to match
// the wrong answer, exactly what this file forbids. Instead `expected`
// holds THIS PROGRAM'S OWN current summary+mismatch report — captured by
// running it once, the same way every other tests/imports/* project's
// `expected` is captured — so a NEW disagreement (a regression) changes the
// summary and fails the gate, and a FIX (a mismatch disappearing) also
// changes the summary and fails the gate until `expected` is refreshed in
// the same commit as the fix. Exit code is always 0: this corpus reports,
// it does not block the build on bugs already filed and tracked.

import {{ compile, Match }} from "std/regex"

class Row {{ idx: int, pat: string, subj: string, max: int, want: string }}
'''

ROWSTR_AND_MAIN = '''\
// `pat` matched against `subj` with `findAll(subj, limit)`, rendered as
// "count=<n> <m0> <m1> ..." — `<mk>` is "s0,e0,s1,e1,...,sG,eG" for match k
// (group 0 = the whole match, then each capturing group, "-1,-1" for one
// that did not participate). A compile error is reported as its own string
// rather than allowed to panic and take the other rows down with it.
fn rowStr(pat: string, subj: string, limit: int): string {
  let re = compile(pat) catch e {
    return "ERR:${e.message()}"
  }
  let ms = re.findAll(subj, limit)
  let out = "count=${len(ms)}"
  let i = 0
  while (i < len(ms)) {
    out = out + " " + flatSlots(ms[i], re.groupCount())
    i = i + 1
  }
  return out
}

fn flatSlots(m: Match, groupCount: int): string {
  let flat = ""
  let g = 0
  while (g <= groupCount) {
    if (len(flat) > 0) {
      flat = flat + ","
    }
    flat = flat + slotStr(m, g)
    g = g + 1
  }
  return flat
}

fn slotStr(m: Match, g: int): string {
  return match (m.group(g)) {
    Some(gm) => "${gm.start},${gm.end}"
    None => "-1,-1"
  }
}

// `rs`, graded against their own `want`: the pass count and every
// mismatch's report block, in row order.
fn grade(rs: []Row): (int, []string) {
  let pass = 0
  let mismatches = []string(0)
  let i = 0
  // Bounded by `rs`'s length, fixed before the loop starts.
  while (i < len(rs)) {
    let r = rs[i]
    let got = rowStr(r.pat, r.subj, r.max)
    if (got == r.want) {
      pass = pass + 1
    } else {
      mismatches = append(mismatches,
        "MISMATCH ${r.idx}\\n  want: ${r.want}\\n  got:  ${got}")
    }
    i = i + 1
  }
  return pass, mismatches
}

// Rows dropped by gen.py's `skip_reason` (see SKIPPED.tsv) — not part of
// `rows()` at all, reported here only so the summary line accounts for
// every source row, kept or not.
const skippedRowCount: int = __SKIPPED_ROW_COUNT__

fn main() {
  let rs = rows()
  let (pass, mismatches) = grade(rs)
  println("regexconform: ${pass} of ${len(rs)} vectors pass " +
    "(${len(mismatches)} known disagreement(s), ${skippedRowCount} " +
    "skipped as invalid-utf8 — see SKIPPED.tsv)")
  let i = 0
  while (i < len(mismatches)) {
    println(mismatches[i])
    i = i + 1
  }
}
'''


def render_row_fns(kept):
    n_fns = (len(kept) + ROWS_PER_FN - 1) // ROWS_PER_FN
    chunks = [kept[i * ROWS_PER_FN:(i + 1) * ROWS_PER_FN] for i in range(n_fns)]
    lines = []
    for k, chunk in enumerate(chunks):
        lines.append(f"fn rows{k}(): []Row {{")
        lines.append("  return []Row{")
        for idx, pat, subj, max_n, want in chunk:
            lines.append(f"    Row{{ idx: {idx}, pat: {bit_string_literal(pat)}, "
                          f"subj: {bit_string_literal(subj)}, max: {max_n}, "
                          f"want: {bit_string_literal(want)} }},")
        lines.append("  }")
        lines.append("}")
        lines.append("")
    return lines, n_fns


def render_rows_aggregator(n_fns, total_kept):
    # Copies by INDEX into a freshly allocated, exactly-sized array rather
    # than `append`ing onto one of the `rowsN()` results directly — `append`
    # on a parameter that might alias a caller's backing array is E0214
    # (append-aliasing); a fresh `[]Row(total_kept)` has no caller to alias.
    lines = ["fn copyInto(out: []Row, offset: int, src: []Row): int {",
              "  let i = 0", "  while (i < len(src)) {",
              "    out[offset + i] = src[i]", "    i = i + 1", "  }",
              "  return offset + len(src)", "}", ""]
    lines.append("fn rows(): []Row {")
    lines.append(f"  let out = []Row({total_kept})")
    lines.append("  let off = 0")
    for k in range(n_fns):
        lines.append(f"  off = copyInto(out, off, rows{k}())")
    lines.append("  return out")
    lines.append("}")
    lines.append("")
    return lines


def render_main_bit(kept_rows, tag, url, fetched_date, total, skipped_count):
    header = HEADER_TEMPLATE.format(tag=tag, url=url, fetched=fetched_date,
                                     total=total, kept=len(kept_rows),
                                     skipped=skipped_count)
    row_fn_lines, n_fns = render_row_fns(kept_rows)
    footer = ROWSTR_AND_MAIN.replace("__SKIPPED_ROW_COUNT__", str(skipped_count))
    body = ([header] + row_fn_lines +
             render_rows_aggregator(n_fns, len(kept_rows)) + [footer])
    return "\n".join(body) + "\n"


# --- driver ------------------------------------------------------------

def parse_all(src):
    body = extract_table_body(src)
    entries = split_top_level_entries(body)
    parsed = [parse_entry(e) for e in entries]  # (pat_bytes, subj_bytes, max, matches)
    return entries, parsed


def classify(parsed):
    """Returns (kept, skipped): kept is [(idx, pat_str, subj_str, max, want)],
    skipped is [(idx, reason, pat_bytes, subj_bytes)]."""
    kept, skipped = [], []
    for idx, (pat, subj, max_n, matches) in enumerate(parsed):
        reason = skip_reason(pat, subj)
        if reason is None:
            kept.append((idx, pat.decode("utf-8"), subj.decode("utf-8"), max_n,
                         go_want_string(matches)))
        else:
            skipped.append((idx, reason, pat, subj))
    return kept, skipped


def write_outputs(kept, skipped, tag, fetched, total):
    main_bit = render_main_bit(kept, tag, src_url(tag), fetched,
                                total, len(skipped))
    with open(os.path.join(HERE, "main.bit"), "w", encoding="utf-8") as f:
        f.write(main_bit)

    with open(os.path.join(HERE, "SKIPPED.tsv"), "w", encoding="utf-8") as f:
        f.write("idx\treason\tpattern\tsubject\n")
        for idx, reason, pat, subj in skipped:
            f.write(f"{idx}\t{reason}\t{pat!r}\t{subj!r}\n")

    print("NOTE: main.bit and SKIPPED.tsv are regenerated. `expected` is NOT "
          "written by this script — it is std/regex's CURRENT stdout, "
          "captured by building and running this project once (same "
          "convention as every other tests/imports/* project) and is left "
          "untouched here so a real behaviour change is never silently "
          "masked.", file=sys.stderr)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tag", default=DEFAULT_TAG)
    ap.add_argument("--fetch", action="store_true")
    ap.add_argument("--input")
    ap.add_argument("--fetched-date", default=None,
                     help="override the recorded fetch date (for reproducible regen)")
    args = ap.parse_args()

    if args.input:
        src = open(args.input, encoding="utf-8").read()
    elif args.fetch:
        src = fetch(args.tag, os.path.join(HERE, ".find_test.go.cache"))
    else:
        ap.error("pass --fetch or --input <path>")

    fetched = args.fetched_date or datetime.date.today().isoformat()
    entries, parsed = parse_all(src)
    kept, skipped = classify(parsed)
    write_outputs(kept, skipped, args.tag, fetched, len(entries))

    print(f"{len(entries)} source rows, {len(kept)} kept, {len(skipped)} skipped",
          file=sys.stderr)
    for idx, reason, pat, subj in skipped:
        print(f"  skip {idx}: {reason} pat={pat!r} subj={subj!r}", file=sys.stderr)


if __name__ == "__main__":
    main()
