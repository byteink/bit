#!/usr/bin/env python3
"""Self-check for dist/sbom.py (task #1752).

    python3 dist/sbom_test.py

Not wired into `zig build test` — dist/*.sh has never been (changelog.sh,
package.sh aren't either); this exercises the one thing zig build test can't:
that the generator emits the fields the release pipeline and downstream
consumers rely on. Installs cyclonedx-python-lib into a throwaway venv
rather than touching the caller's environment, pinned by
dist/sbom-requirements.txt - the same file the release flow's SBOM step reads,
so the two never drift apart.
"""
import json
import subprocess
import sys
import tempfile
import venv
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def get(doc, path):
    """Walk a slash-separated path over parsed JSON, e.g. metadata/component/name."""
    node = doc
    for key in path.split("/"):
        node = node[int(key)] if key.isdigit() else node[key]
    return node


def main() -> int:
    with tempfile.TemporaryDirectory() as venv_dir:
        venv.create(venv_dir, with_pip=True)
        pip = str(Path(venv_dir, "bin", "pip"))
        python = str(Path(venv_dir, "bin", "python3"))

        subprocess.run(
            [pip, "install", "--quiet", "--require-hashes", "-r",
             str(ROOT / "dist" / "sbom-requirements.txt")],
            check=True,
        )
        out = subprocess.run(
            [python, str(ROOT / "dist" / "sbom.py"), "9.9.9-test", "0.16.0"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout
        doc = json.loads(out)

    checks = [
        ("bomFormat", "bomFormat", "CycloneDX"),
        ("specVersion", "specVersion", "1.7"),
        ("app component name", "metadata/component/name", "bit"),
        ("app component version", "metadata/component/version", "9.9.9-test"),
        ("zig tool name", "metadata/tools/components/0/name", "zig"),
        ("zig tool version", "metadata/tools/components/0/version", "0.16.0"),
    ]
    for desc, path, want in checks:
        got = get(doc, path)
        if got != want:
            print(f"FAIL: {desc}: got {got!r}, want {want!r}", file=sys.stderr)
            return 1
        print(f"ok: {desc}")

    props = {p["name"]: p["value"] for p in doc["metadata"]["properties"]}
    if not props.get("bit:vendored-dependencies"):
        print("FAIL: missing bit:vendored-dependencies property", file=sys.stderr)
        return 1
    print("ok: vendored-dependencies property present")

    print("dist/sbom_test.py: all checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
