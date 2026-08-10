#!/usr/bin/env bash
# Behavioural gate for `bit lsp` (#1547): drive the REAL self-hosted `bit lsp`
# binary over stdio with scripted JSON-RPC transcripts and assert the framed
# replies. There is deliberately no lsp differential (one server, nothing to
# diff, per #1542), so this is the end-to-end check: initialize -> didOpen ->
# hover/definition/documentSymbol/completion -> shutdown, each against its own
# temp directory, one session per request kind.
#
# Usage: bash scripts/lsp-transcript.sh [path-to-bit]
# Exit 0 iff every scenario's assertions pass; nonzero (with a FAIL line) otherwise.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIT="${1:-$ROOT/bit-out/bin/bit}"

if [ ! -x "$BIT" ]; then
  echo "FAIL: no bit binary at $BIT (run './make' first)" >&2
  exit 1
fi

# stdlib resolution: the server loads the prelude from BIT_STDLIB so a temp-dir
# module resolves `println`/`std/*` exactly as a real build does.
export BIT_STDLIB="$ROOT/stdlib"

python3 - "$BIT" <<'PY'
import json, os, subprocess, sys, tempfile, time

BIT = sys.argv[1]
fails = 0

# A private id space for the harness's own synchronization probes, well clear
# of every id a scenario below writes (1, 2, 99, ...).
_sync_seq = [1_000_000]

def _next_sync_id():
    _sync_seq[0] += 1
    return _sync_seq[0]

def run_session(files, messages):
    """Write `files` (name->text) into a temp dir, then deliver `messages`
    (list of JSON-RPC dicts) to `bit lsp` ONE AT A TIME over its stdin,
    confirming each is fully settled before sending the next, and return the
    list of decoded reply bodies observed along the way, in the order the
    server wrote them. `{DIR}`/`{URI:name}` placeholders in messages are
    filled per dir.

    #2852: a bulk write (the old `subprocess.run(input=payload)`) lands the
    whole burst in one OS read, so `lspRun`'s post-handle flush check
    (compiler/lspserver.bit:590,604 -- the #2201 coalescing gate, which only
    republishes once its input buffer has drained to empty) fires once for
    the entire burst instead of once per intended edit. Delivering messages
    one at a time isn't enough on its own either: separate write() calls to a
    pipe can still land in the same read() if the writer outruns the reader,
    which is exactly what a fast Python loop does against a starting `bit
    lsp`. The fix is synchronization, not spacing: `sync()`+`settle()` below
    hold off writing message N+1 until message N's turn -- read, handle, and
    (for a notification-carrying turn) any resulting flush -- has
    provably finished, using request/response round trips already offered by
    the protocol rather than a sleep."""
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

    proc = subprocess.Popen(
        [BIT, "lsp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        stderr=tempfile.TemporaryFile())
    bodies = []
    buf = b""
    deadline = time.monotonic() + 60

    def write(obj):
        body = json.dumps(fill(obj)).encode()
        proc.stdin.write(b"Content-Length: %d\r\n\r\n%s" % (len(body), body))
        proc.stdin.flush()

    def fail(msg):
        proc.kill()
        proc.wait()
        proc.stderr.seek(0)
        err = proc.stderr.read().decode(errors="replace")
        raise RuntimeError(f"{msg}\n--- bit lsp stderr ---\n{err}")

    def next_frame():
        nonlocal buf
        while True:
            hdr = buf.find(b"\r\n\r\n")
            if hdr >= 0:
                cl = None
                for line in buf[:hdr].decode(errors="replace").split("\r\n"):
                    if line.lower().startswith("content-length:"):
                        cl = int(line.split(":", 1)[1].strip())
                if cl is not None and len(buf) >= hdr + 4 + cl:
                    frame = buf[hdr + 4:hdr + 4 + cl].decode()
                    buf = buf[hdr + 4 + cl:]
                    return frame
            if time.monotonic() > deadline:
                fail("lsp-transcript: bit lsp timed out mid-session")
            chunk = os.read(proc.stdout.fileno(), 4096)
            if not chunk:
                fail("lsp-transcript: bit lsp closed stdout mid-session")
            buf += chunk

    def sync(expect_id):
        """Read frames, recording each, until the reply to `expect_id`."""
        while True:
            frame = next_frame()
            bodies.append(frame)
            if json.loads(frame).get("id") == expect_id:
                return

    def settle():
        """A second round trip after the message's own. `lspRun`'s
        post-handle flush check (len(r.buf) == 0) runs synchronously, still
        inside the same loop turn, strictly before the loop reads again -- so
        a reply to THIS probe can only exist once that check (and the flush
        it may have triggered) has already run and been written: the process
        cannot reach this probe's read without first finishing the prior
        turn's. That is a program-order guarantee, not a timing one -- no
        sleep, no fixed delay, and it holds regardless of how the OS happened
        to chunk the reads."""
        probe = _next_sync_id()
        write({"jsonrpc": "2.0", "id": probe, "method": "$/sync", "params": {}})
        sync(probe)

    for m in messages:
        write(m)
        mid = m.get("id")
        if mid is None:
            mid = _next_sync_id()
            write({"jsonrpc": "2.0", "id": mid, "method": "$/sync", "params": {}})
        sync(mid)
        settle()

    proc.stdin.close()
    try:
        proc.wait(timeout=10)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()
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
        'fn main() {\n'
        '  let d = sqrt(9.0)\n'
        '  println("d = ${d}")\n'
        '}\n'},
    [
        {"jsonrpc":"2.0","id":1,"method":"initialize","params":{}},
        {"jsonrpc":"2.0","method":"textDocument/didOpen","params":{
            "textDocument":{"uri":"{URI:main.bit}","text":
                'import { sqrt } from "std/math"\n'
                'fn main() {\n'
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
a_text = 'fn greet(): string {\n  return "hi"\n}\n'
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
    "fn (b: Bot) greet(): string { return b.name }\n"
    "fn (b: Bot) wave(): string { return b.name }\n"
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
dtext = "fn greet(): string {\n  return \"hi\"\n}\nstruct Bot { name: string }\n"
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
    "extern fn bit_rt_listen_tcp(host: *u8, hostLen: int, port: int): int\n"
    "extern fn bit_rt_addr_octets(sa: *u8, out: *u8)\n"
    "@nosplit @symbol(\"bit_custom_entry\") fn customEntry(p: *i64): int {\n"
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
    "extern fn bit_rt_listen_tcp(host: *u8, hostLen: int): int\n"
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

# 10. lint findings publish alongside check diagnostics (#1391): a file past
#     max-file-lines (800) gets a severity-2 (Warning) finding, distinct from
#     a severity-1 (Error) check diagnostic, and it updates as the file is
#     edited — grow past the limit, then shrink back under it.
short_lines = "let x = 1\n"
# Comment padding, not 801 duplicate `let x` decls: the point is tripping
# max-file-lines without also tripping a genuine duplicate-declaration error,
# which would just add noise this scenario isn't testing.
long_lines = "let x = 1\n" + "// pad\n" * 800
b = run_session(
    {"main.bit": short_lines},
    [
        {"jsonrpc":"2.0","id":1,"method":"initialize","params":{}},
        {"jsonrpc":"2.0","method":"textDocument/didOpen","params":{
            "textDocument":{"uri":"{URI:main.bit}","text":short_lines}}},
        {"jsonrpc":"2.0","method":"textDocument/didChange","params":{
            "textDocument":{"uri":"{URI:main.bit}"},
            "contentChanges":[{"text":long_lines}]}},
        {"jsonrpc":"2.0","method":"textDocument/didChange","params":{
            "textDocument":{"uri":"{URI:main.bit}"},
            "contentChanges":[{"text":short_lines}]}},
    ])
diag = [x for x in b if "publishDiagnostics" in x]
check("lint: at least three publishDiagnostics (open + 2 edits)", len(diag) >= 3, joined(b))
check("lint: no finding on the short file", '"diagnostics":[]' in diag[0], diag[0])
check("lint: E0200 warning (severity 2) once past the limit",
      '"code":"E0200"' in diag[1] and '"severity":2' in diag[1], diag[1])
check("lint: finding clears once back under the limit",
      '"diagnostics":[]' in diag[2], diag[2])

# 11. a malformed lint directive is reported in place and never blocks a
#     check feature (#1391 constraint): hover on the very file with the bad
#     directive still answers, and the directive error is severity 1 (Error)
#     while sitting beside zero check errors (`p.diags` is untouched).
bad_directive = "// bit:lint max-file-lines 900 -- missing '='\nlet x = 5\n"
b = run_session(
    {"main.bit": bad_directive},
    [
        {"jsonrpc":"2.0","id":1,"method":"initialize","params":{}},
        {"jsonrpc":"2.0","method":"textDocument/didOpen","params":{
            "textDocument":{"uri":"{URI:main.bit}","text":bad_directive}}},
        {"jsonrpc":"2.0","id":2,"method":"textDocument/hover","params":{
            "textDocument":{"uri":"{URI:main.bit}"},"position":{"line":1,"character":4}}},
    ])
diag = [x for x in b if "publishDiagnostics" in x]
resp = [x for x in b if '"id":2' in x]
check("lint: malformed directive reported", any('"code":"E0299"' in x for x in diag), joined(diag))
check("lint: hover still answers beside the bad directive",
      len(resp) == 1 and "let x: i64" in resp[0], joined(b))

print()
if fails:
    print(f"lsp-transcript: {fails} FAILED")
    sys.exit(1)
print("lsp-transcript: all scenarios passed")
PY
