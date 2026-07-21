#!/usr/bin/env bash
# Behavioural gate for `bit lsp` (#1547): drive the REAL self-hosted `bit lsp`
# binary over stdio with scripted JSON-RPC transcripts and assert the framed
# replies. There is deliberately no lsp differential (one server, nothing to
# diff, per #1542), so this is the end-to-end check: initialize -> didOpen ->
# hover/definition/documentSymbol/completion -> shutdown, each against its own
# temp directory, mirroring the seed's TestSession sessions (seed/lsp.zig).
#
# Usage: bash scripts/lsp-transcript.sh [path-to-bit]
# Exit 0 iff every scenario's assertions pass; nonzero (with a FAIL line) otherwise.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIT="${1:-$ROOT/zig-out/bin/bit}"

if [ ! -x "$BIT" ]; then
  echo "FAIL: no bit binary at $BIT (run 'zig build' first)" >&2
  exit 1
fi

# stdlib resolution: the server loads the prelude from BIT_STDLIB so a temp-dir
# module resolves `println`/`std/*` exactly as a real build does.
export BIT_STDLIB="$ROOT/stdlib"

python3 - "$BIT" <<'PY'
import json, os, subprocess, sys, tempfile

BIT = sys.argv[1]
fails = 0

def run_session(files, messages):
    """Write `files` (name->text) into a temp dir, pipe `messages` (list of
    JSON-RPC dicts) framed into `bit lsp`, return the list of decoded reply
    bodies. `{DIR}`/`{URI:name}` placeholders in messages are filled per dir."""
    d = tempfile.mkdtemp(prefix="bitls_")
    for name, text in files.items():
        with open(os.path.join(d, name), "w") as f:
            f.write(text)

    def fill(obj):
        if isinstance(obj, str):
            obj = obj.replace("{DIR}", d)
            if obj.startswith("{URI:"):
                name = obj[len("{URI:"):-1]
                return "file://" + os.path.join(d, name)
            return obj
        if isinstance(obj, dict):
            return {k: fill(v) for k, v in obj.items()}
        if isinstance(obj, list):
            return [fill(v) for v in obj]
        return obj

    payload = b""
    for m in messages:
        body = json.dumps(fill(m)).encode()
        payload += b"Content-Length: %d\r\n\r\n%s" % (len(body), body)

    proc = subprocess.run([BIT, "lsp"], input=payload, capture_output=True, timeout=60)
    out = proc.stdout
    bodies, i = [], 0
    while True:
        hdr = out.find(b"\r\n\r\n", i)
        if hdr < 0:
            break
        header = out[i:hdr].decode()
        n = int(header.split("Content-Length:")[1].split("\r")[0].strip())
        start = hdr + 4
        bodies.append(out[start:start+n].decode())
        i = start + n
    return bodies

def check(name, cond, detail=""):
    global fails
    if cond:
        print(f"PASS  {name}")
    else:
        fails += 1
        print(f"FAIL  {name}  {detail}")

def joined(bodies):
    return "\n".join(bodies)

# 1. didOpen a file with a type error -> one publishDiagnostics, severity 1.
b = run_session(
    {"main.bit": 'let x: i32 = "nope"\n'},
    [
        {"jsonrpc":"2.0","id":1,"method":"initialize","params":{}},
        {"jsonrpc":"2.0","method":"textDocument/didOpen","params":{
            "textDocument":{"uri":"{URI:main.bit}","text":'let x: i32 = "nope"\n'}}},
        {"jsonrpc":"2.0","id":99,"method":"shutdown","params":{}},
    ])
diag = [x for x in b if "publishDiagnostics" in x]
check("diagnostics: publishDiagnostics emitted", len(diag) >= 1, joined(b))
check("diagnostics: severity 1 (error)", any('"severity":1' in x for x in diag), joined(diag))
check("diagnostics: source is bitls", any('"source":"bitls"' in x for x in diag), joined(diag))

# 2. prelude + std imports resolve: no false diagnostics, one empty array.
b = run_session(
    {"main.bit":
        'import { sqrt } from "std/math"\n'
        'function main() {\n'
        '  let d = sqrt(9.0)\n'
        '  println("d = ${d}")\n'
        '}\n'},
    [
        {"jsonrpc":"2.0","id":1,"method":"initialize","params":{}},
        {"jsonrpc":"2.0","method":"textDocument/didOpen","params":{
            "textDocument":{"uri":"{URI:main.bit}","text":
                'import { sqrt } from "std/math"\n'
                'function main() {\n'
                '  let d = sqrt(9.0)\n'
                '  println("d = ${d}")\n'
                '}\n'}}},
    ])
diag = [x for x in b if "publishDiagnostics" in x]
check("prelude: exactly one publishDiagnostics", len(diag) == 1, joined(b))
check("prelude: empty diagnostics array", any('"diagnostics":[]' in x for x in diag), joined(diag))

# 3. hover on `let x = 5` shows the inferred type.
text = "let x = 5\n"
b = run_session(
    {"main.bit": text},
    [
        {"jsonrpc":"2.0","id":1,"method":"initialize","params":{}},
        {"jsonrpc":"2.0","method":"textDocument/didOpen","params":{
            "textDocument":{"uri":"{URI:main.bit}","text":text}}},
        {"jsonrpc":"2.0","id":2,"method":"textDocument/hover","params":{
            "textDocument":{"uri":"{URI:main.bit}"},"position":{"line":0,"character":4}}},
    ])
resp = [x for x in b if '"id":2' in x]
check("hover: reply present", len(resp) == 1, joined(b))
check("hover: shows 'let x: i64'", any("let x: i64" in x for x in resp), joined(resp))

# 3b. hover on a USAGE (not the binder) re-derives the type via checkExprType.
utext = "let x = 5\nlet y = x\n"
b = run_session(
    {"main.bit": utext},
    [
        {"jsonrpc":"2.0","id":1,"method":"initialize","params":{}},
        {"jsonrpc":"2.0","method":"textDocument/didOpen","params":{
            "textDocument":{"uri":"{URI:main.bit}","text":utext}}},
        {"jsonrpc":"2.0","id":2,"method":"textDocument/hover","params":{
            "textDocument":{"uri":"{URI:main.bit}"},"position":{"line":1,"character":8}}},
    ])
resp = [x for x in b if '"id":2' in x]
check("hover-usage: type shown on a reference", any("i64" in x for x in resp), joined(resp))

# 4. goto-definition crosses sibling files in the same directory.
a_text = 'function greet(): string {\n  return "hi"\n}\n'
b_text = "let msg = greet()\n"
b = run_session(
    {"a.bit": a_text, "b.bit": b_text},
    [
        {"jsonrpc":"2.0","id":1,"method":"initialize","params":{}},
        {"jsonrpc":"2.0","method":"textDocument/didOpen","params":{
            "textDocument":{"uri":"{URI:b.bit}","text":b_text}}},
        {"jsonrpc":"2.0","id":2,"method":"textDocument/definition","params":{
            "textDocument":{"uri":"{URI:b.bit}"},"position":{"line":0,"character":10}}},
    ])
resp = [x for x in b if '"id":2' in x]
check("definition: reply present", len(resp) == 1, joined(b))
check("definition: points at a.bit", any("a.bit" in x and '"uri"' in x for x in resp), joined(resp))

# 5. completion after `.` lists the interface's methods.
ctext = (
    "interface Greeter {\n"
    "  greet(): string\n"
    "  wave(): string\n"
    "}\n"
    "struct Bot { name: string }\n"
    "function (b: Bot) greet(): string { return b.name }\n"
    "function (b: Bot) wave(): string { return b.name }\n"
    'let g: Greeter = Bot{name: "Ada"}\n'
    "let y = g.\n"
)
b = run_session(
    {"main.bit": ctext},
    [
        {"jsonrpc":"2.0","id":1,"method":"initialize","params":{}},
        {"jsonrpc":"2.0","method":"textDocument/didOpen","params":{
            "textDocument":{"uri":"{URI:main.bit}","text":ctext}}},
        {"jsonrpc":"2.0","id":2,"method":"textDocument/completion","params":{
            "textDocument":{"uri":"{URI:main.bit}"},"position":{"line":8,"character":10}}},
    ])
resp = [x for x in b if '"id":2' in x]
check("completion: reply present", len(resp) == 1, joined(b))
check("completion: lists 'greet'", any('"greet"' in x for x in resp), joined(resp))
check("completion: lists 'wave'", any('"wave"' in x for x in resp), joined(resp))

# 6. documentSymbol lists a top-level declaration.
dtext = "function greet(): string {\n  return \"hi\"\n}\nstruct Bot { name: string }\n"
b = run_session(
    {"main.bit": dtext},
    [
        {"jsonrpc":"2.0","id":1,"method":"initialize","params":{}},
        {"jsonrpc":"2.0","method":"textDocument/didOpen","params":{
            "textDocument":{"uri":"{URI:main.bit}","text":dtext}}},
        {"jsonrpc":"2.0","id":2,"method":"textDocument/documentSymbol","params":{
            "textDocument":{"uri":"{URI:main.bit}"}}},
    ])
resp = [x for x in b if '"id":2' in x]
check("documentSymbol: reply present", len(resp) == 1, joined(b))
check("documentSymbol: lists 'greet'", any('"greet"' in x for x in resp), joined(resp))
check("documentSymbol: lists 'Bot'", any('"Bot"' in x for x in resp), joined(resp))

# 7. didChange re-checks: open clean, then change to introduce a type error ->
#    a fresh publishDiagnostics carrying severity 1. didClose republishes too.
clean = "let x = 1\n"
broken = 'let x: i32 = "nope"\n'
b = run_session(
    {"main.bit": clean},
    [
        {"jsonrpc":"2.0","id":1,"method":"initialize","params":{}},
        {"jsonrpc":"2.0","method":"textDocument/didOpen","params":{
            "textDocument":{"uri":"{URI:main.bit}","text":clean}}},
        {"jsonrpc":"2.0","method":"textDocument/didChange","params":{
            "textDocument":{"uri":"{URI:main.bit}"},
            "contentChanges":[{"text":broken}]}},
        {"jsonrpc":"2.0","method":"textDocument/didClose","params":{
            "textDocument":{"uri":"{URI:main.bit}"}}},
    ])
diag = [x for x in b if "publishDiagnostics" in x]
check("didChange: at least two publishDiagnostics (open + change)", len(diag) >= 2, joined(b))
check("didChange: an error appears after the edit", any('"severity":1' in x for x in diag), joined(diag))

# 8. initialize advertises capabilities; shutdown replies null.
b = run_session(
    {"main.bit": "let x = 1\n"},
    [
        {"jsonrpc":"2.0","id":1,"method":"initialize","params":{}},
        {"jsonrpc":"2.0","id":2,"method":"shutdown","params":{}},
    ])
check("initialize: hoverProvider advertised", any('"hoverProvider":true' in x for x in b if '"id":1' in x), joined(b))
check("shutdown: replies null", any('"id":2' in x and '"result":null' in x for x in b), joined(b))

# 9. extern/decorator diagnostic parity (#1601). The unmanaged subset (SPEC
#    §11.7/§11.11) — `extern function` with pointer params and int/void returns,
#    and `@nosplit`/`@symbol(...)`-attributed functions taking `*i64` — is valid
#    code the real compiler (`bit check`) accepts. The LSP shares that parse/check
#    pipeline, so it must publish ZERO diagnostics here; a false positive on this
#    syntax (the reported regression, actually a stale installed binary) is the
#    unacceptable class. A single `run_session` needs a Content-Length line here
#    because Python len() differs from the byte count once we embed no non-ASCII.
extern_ok = (
    "extern function bit_rt_listen_tcp(host: *u8, hostLen: int, port: int): int\n"
    "extern function bit_rt_addr_octets(sa: *u8, out: *u8)\n"
    "@nosplit @symbol(\"bit_custom_entry\") function customEntry(p: *i64): int {\n"
    "  return 0\n"
    "}\n"
)
b = run_session(
    {"main.bit": extern_ok},
    [
        {"jsonrpc":"2.0","id":1,"method":"initialize","params":{}},
        {"jsonrpc":"2.0","method":"textDocument/didOpen","params":{
            "textDocument":{"uri":"{URI:main.bit}","text":extern_ok}}},
    ])
diag = [x for x in b if "publishDiagnostics" in x]
check("extern: exactly one publishDiagnostics", len(diag) == 1, joined(b))
check("extern: no diagnostics on valid extern/decorator/pointer code",
      any('"diagnostics":[]' in x for x in diag), joined(diag))

# 9b. Not over-suppressed: a genuine type error in the SAME file as valid externs
#     is still reported (severity 1), while the extern lines above stay clean.
extern_mixed = (
    "extern function bit_rt_listen_tcp(host: *u8, hostLen: int): int\n"
    "let bad: i32 = \"nope\"\n"
)
b = run_session(
    {"main.bit": extern_mixed},
    [
        {"jsonrpc":"2.0","id":1,"method":"initialize","params":{}},
        {"jsonrpc":"2.0","method":"textDocument/didOpen","params":{
            "textDocument":{"uri":"{URI:main.bit}","text":extern_mixed}}},
    ])
diag = [x for x in b if "publishDiagnostics" in x]
check("extern-mixed: genuine error beside externs still reported",
      any('"severity":1' in x for x in diag), joined(diag))

print()
if fails:
    print(f"lsp-transcript: {fails} FAILED")
    sys.exit(1)
print("lsp-transcript: all scenarios passed")
PY
