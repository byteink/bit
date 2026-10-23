#!/usr/bin/env bash
# Shared structural identities for the IR comparisons (#3125, #3132).
# Unknown differences fail closed; filenames never authorize a difference.
# Rationale and history: docs/development/dump-differential.md.

# explainMismatch <old> <new> <kind> <source> <oldobj> <newobj> <oldcap> <newcap>
explainMismatch() {
  case "$3" in ir|iropt) ;; *) return 1 ;; esac
  local LC_ALL=C
  [ "$((${#1} + ${#2} + 1))" -le 8388608 ] || return 1
  local proof_dir="${BASH_SOURCE[0]%/*}" ROOT
  ROOT=${proof_dir%/scripts}
  [ "$proof_dir" != scripts ] || ROOT=.
  local DIFFIROPT_LITERAL_PYTHON DIFFDUMP_PARENT_PYTHON DIFFDUMP_PARENT_ENGINE
  local parent_read_rc=0 parent_code
  . "$proof_dir/selfhost-diffdump-setup.sh" || return 1
  diffdump_frame_libraries "$proof_dir" || return 1
  IFS= builtin read -r -d '' DIFFDUMP_PARENT_ENGINE <<'PYTHON' || parent_read_rc=$?
import base64
import json
import os
import stat
import struct
import subprocess
import sys

remaining = 1000000

def require(ok):
    if not ok:
        raise ValueError("unsupported identity")

def spend(n=1):
    global remaining
    remaining -= n
    require(remaining >= 0)

def unique_object(pairs):
    result = dict(pairs)
    require(len(result) == len(pairs))
    return result

def prove(packet):
    wire = json.dumps(packet, ensure_ascii=True, separators=(",", ":")).encode("ascii")
    require(len(wire) <= 8 * 1024 * 1024)
    environment = dict(os.environ)
    environment.pop("BASH_ENV", None)
    environment.pop("ENV", None)
    result = subprocess.run(["/bin/bash", sys.argv[1], "--prove-owned-appends"],
                            input=wire, capture_output=True, timeout=5, env=environment)
    require(result.returncode == 0 and result.stderr == b"")
    require(len(result.stdout) <= 65536)
    response = json.loads(result.stdout, object_pairs_hook=unique_object)
    require(type(response) is dict and set(response) == {"version", "kind", "work_left"})
    require(type(response["version"]) is int and response["version"] == 3)
    require(response["kind"] == "canonical")
    require(type(response["work_left"]) is int)
    require(0 <= response["work_left"] <= packet["work_left"])
    return response["kind"]

try:
    data = sys.stdin.buffer.read(8 * 1024 * 1024 + 1)
    require(len(data) <= 8 * 1024 * 1024 and data.count(b"\0") == 1)
    legacy = data.split(b"\0")
    original = [file_snapshot(path) for path in sys.argv[5:7]]
    require(len(original) == 2 and all(b"\0" not in raw for raw in original))
    require([r.rstrip(b"\n") for r in original] == legacy)
    require(original[0] != original[1])
    objects = [file_snapshot(path) for path in sys.argv[3:5]]
    require(len(objects) == 2 and sum(map(len, original + objects)) <= 8 * 1024 * 1024)
    packet = {"version": 3, "comparison": sys.argv[7], "work_left": remaining,
              "original": [base64.b64encode(r).decode("ascii") for r in original],
              "objects": [base64.b64encode(r).decode("ascii") for r in objects]}
    identity = prove(packet)
except (ValueError, KeyError, IndexError, TypeError, RecursionError, OSError, OverflowError, struct.error, subprocess.TimeoutExpired):
    sys.exit(1)
print("canonical-ir-match")
PYTHON
  [ "$parent_read_rc" -eq 1 ] || return 1
  parent_code="${DIFFDUMP_PARENT_PYTHON}"$'\n'"${DIFFDUMP_PARENT_ENGINE}"
  [ "${#parent_code}" -le 65536 ] || return 1
  { printf '%s\0%s' "$1" "$2"; } | python3 -I /dev/fd/3 "$proof_dir/selfhost-ir-canon.sh" "${4:-}" "${5:-}" "${6:-}" "${7:-}" "${8:-}" "$3" 3<<<"$parent_code"
}

# declaredSignatureNames [kind] -- the retirement audit still consults this table.
declaredSignatureNames() {
  :
}

# shellcheck source=scripts/selfhost-ir-canon.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/selfhost-ir-canon.sh"
