#!/usr/bin/env bash
# Keystroke-path perf gate for #1391 (lint findings over the LSP): the task's
# constraint is "do not run the full lint pass on every keystroke if it
# measurably costs latency — measure before optimising". This measures it
# directly rather than asserting it: build `bit` twice — once as committed
# (lint wired into lspPublishDiagnostics) and once with that one call site
# patched out — and time the same sequence of `textDocument/didChange` ->
# `publishDiagnostics` round trips against both. The delta IS the lint pass's
# marginal cost on the keystroke path.
#
# Usage: bash scripts/lsp-lint-perf.sh
# Exit 0 and prints both medians + the delta iff the lint overhead stays under
# the threshold below; nonzero otherwise.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export BIT_STDLIB="$ROOT/stdlib"

SRC="compiler/lspserver.bit"
MARK_START="    let lint = lspLintDiagnostics(src)"
MARK_END="    }"
# Overhead budget: lint must not add more than this fraction of the baseline
# (no-lint) per-edit latency. 25% is generous on purpose — the pass is one
# extra lex over text `lspBuildProject` already re-parses+resolves(+checks)
# in full on every keystroke, so a real regression should read far higher.
MAX_OVERHEAD_PCT=25

if ! git diff --quiet -- "$SRC"; then
  echo "FAIL: $SRC has uncommitted changes; perf gate needs a clean baseline to restore" >&2
  exit 1
fi

restore() {
  git checkout -- "$SRC"
  zig build >/dev/null
}
trap restore EXIT

measure_once() {
  local bit="$1"
  python3 - "$bit" <<'PY'
import json, os, statistics, subprocess, sys, tempfile, time

BIT = sys.argv[1]
N = 40  # edits timed; enough for a stable median without a slow run

def send(proc, msg):
    body = json.dumps(msg).encode()
    proc.stdin.write(b"Content-Length: %d\r\n\r\n" % len(body) + body)
    proc.stdin.flush()

def read_one(proc):
    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = proc.stdout.read(1)
        if not chunk:
            raise EOFError("bit lsp exited early")
        buf += chunk
    header, body = buf.split(b"\r\n\r\n", 1)
    n = int(header.split(b"Content-Length:")[1].split(b"\r")[0].strip())
    while len(body) < n:
        chunk = proc.stdout.read(n - len(body))
        if not chunk:
            raise EOFError("bit lsp exited early")
        body += chunk
    return json.loads(body.decode())

d = tempfile.mkdtemp(prefix="bitls_perf_")
path = os.path.join(d, "main.bit")
uri = "file://" + path
# 800 lines: at the lint file-size limit, so the rule's full-file scan cost is
# representative of the largest file lint runs against without also tripping
# a finding (irrelevant to timing either way, but keeps the fixture boring).
base_lines = ["let x0 = 0\n"] + ["// pad {}\n".format(i) for i in range(799)]
base_text = "".join(base_lines)
with open(path, "w") as f:
    f.write(base_text)

proc = subprocess.Popen([BIT, "lsp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=subprocess.DEVNULL,
                         env={**os.environ})
send(proc, {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}})
read_one(proc)  # initialize reply
send(proc, {"jsonrpc": "2.0", "method": "textDocument/didOpen", "params": {
    "textDocument": {"uri": uri, "text": base_text}}})
read_one(proc)  # publishDiagnostics for the open

deltas = []
for i in range(N):
    text = "let x0 = {}\n".format(i) + "".join(base_lines[1:])
    t0 = time.perf_counter()
    send(proc, {"jsonrpc": "2.0", "method": "textDocument/didChange", "params": {
        "textDocument": {"uri": uri},
        "contentChanges": [{"text": text}]}})
    read_one(proc)  # publishDiagnostics for this edit
    deltas.append(time.perf_counter() - t0)

send(proc, {"jsonrpc": "2.0", "id": 99, "method": "shutdown", "params": {}})
read_one(proc)
proc.stdin.close()
proc.wait(timeout=5)

print(min(deltas) * 1000.0)
PY
}

# Best-of-R, not average-of-R: this machine runs several other agents'
# `zig build test` concurrently (observed 9-way contention while developing
# this gate), which inflates every sample with scheduler noise but never
# makes one run faster than the true floor. The minimum across repeats is the
# noise-resistant statistic; an average would just launder the contention
# into the "measurement".
measure() {
  local bit="$1" best="" v
  for _ in 1 2 3; do
    v="$(measure_once "$bit")"
    if [ -z "$best" ] || python3 -c "import sys; sys.exit(0 if ${v} < ${best} else 1)"; then
      best="$v"
    fi
  done
  echo "$best"
}

echo "==> Building lint-enabled bit (as committed) ..."
zig build >/dev/null
with_lint_ms="$(measure "$ROOT/zig-out/bin/bit")"
echo "    best-of-3 min didChange->publishDiagnostics: ${with_lint_ms} ms (n=40/run)"

echo "==> Patching out the lint call site and rebuilding ..."
python3 - "$SRC" "$MARK_START" "$MARK_END" <<'PY'
import sys
path, start, end = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as f:
    lines = f.readlines()
out, i, patched = [], 0, False
while i < len(lines):
    if not patched and lines[i].rstrip("\n") == start:
        # Skip this line through its matching "}" (the for-loop body), so
        # `items` never gets the lint diagnostics appended.
        depth = 0
        while i < len(lines):
            out.append("    // " + lines[i] if lines[i].strip() else lines[i])
            if lines[i].rstrip("\n") == end:
                break
            i += 1
        patched = True
        i += 1
        continue
    out.append(lines[i])
    i += 1
if not patched:
    print("FAIL: lint call-site marker not found in", path, file=sys.stderr)
    sys.exit(1)
with open(path, "w") as f:
    f.writelines(out)
PY
zig build >/dev/null
without_lint_ms="$(measure "$ROOT/zig-out/bin/bit")"
echo "    best-of-3 min didChange->publishDiagnostics: ${without_lint_ms} ms (n=40/run, lint call site skipped)"

overhead_pct="$(python3 -c "print((${with_lint_ms} - ${without_lint_ms}) / ${without_lint_ms} * 100.0)")"
echo
echo "lint overhead: ${overhead_pct}% (budget: ${MAX_OVERHEAD_PCT}%)"

python3 -c "import sys; sys.exit(0 if ${overhead_pct} < ${MAX_OVERHEAD_PCT} else 1)"
result=$?
if [ "$result" -ne 0 ]; then
  echo "FAIL: lint pass measurably regresses the keystroke path" >&2
  exit 1
fi
echo "PASS: lint pass does not measurably regress the keystroke path"
