#!/usr/bin/env bash
# Self-check for dist/sbom.py (task #1752).
#
#   dist/sbom_test.sh
#
# Not wired into `zig build test` — dist/*.sh has never been (changelog.sh,
# package.sh aren't either); this exercises the one thing zig build test
# can't: that the Python generator emits the fields the release pipeline and
# downstream consumers rely on. Installs cyclonedx-python-lib into a
# throwaway venv rather than touching the caller's environment, pinned by
# dist/sbom-requirements.txt — the same file release.yml's "sbom" step reads,
# so the two never drift apart.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENV="$(mktemp -d)"
trap 'rm -rf "${VENV}"' EXIT

python3 -m venv "${VENV}"
"${VENV}/bin/pip" install --quiet -r "${ROOT}/dist/sbom-requirements.txt"

OUT="$("${VENV}/bin/python3" "${ROOT}/dist/sbom.py" 9.9.9-test 0.16.0)"

# <path> is a slash-separated walk over the parsed JSON, e.g.
# metadata/component/name — plain string/int keys only, no quoting needed.
check() {
  local desc="$1" path="$2" want="$3"
  local got
  got="$(printf '%s' "${OUT}" | "${VENV}/bin/python3" -c "
import json, sys
d = json.load(sys.stdin)
for key in '${path}'.split('/'):
    d = d[int(key)] if key.isdigit() else d[key]
print(d)
")"
  [ "${got}" = "${want}" ] || { echo "FAIL: ${desc}: got '${got}', want '${want}'" >&2; exit 1; }
  echo "ok: ${desc}"
}

check 'bomFormat'             'bomFormat'                                   'CycloneDX'
check 'specVersion'           'specVersion'                                 '1.7'
check 'app component name'    'metadata/component/name'                    'bit'
check 'app component version' 'metadata/component/version'                 '9.9.9-test'
check 'zig tool name'         'metadata/tools/components/0/name'           'zig'
check 'zig tool version'      'metadata/tools/components/0/version'        '0.16.0'

printf '%s' "${OUT}" | "${VENV}/bin/python3" -c "
import json, sys
d = json.load(sys.stdin)
props = {p['name']: p['value'] for p in d['metadata']['properties']}
assert props.get('bit:vendored-dependencies'), 'missing bit:vendored-dependencies property'
"
echo "ok: vendored-dependencies property present"

echo "dist/sbom_test.sh: all checks passed"
