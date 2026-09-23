#!/usr/bin/env python3
"""Self-check for dist/sbom.py (task #1752).

    python3 dist/sbom_test.py

Not wired into `./make test` - dist/*.sh has never been (changelog.sh,
package.sh aren't either); this exercises the one thing the suite can't:
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
            [python, str(ROOT / "dist" / "sbom.py"), "9.9.9-test", "0.1.4"],
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
        ("stage0 tool name", "metadata/tools/components/0/name", "bit"),
        ("stage0 tool version", "metadata/tools/components/0/version", "0.1.4"),
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

    # #4197: the ordinary (no pass1-base-commit argument) call must NOT gain
    # a two-pass property -- a routine release's SBOM must be unchanged.
    if "bit:pass1-base-commit" in props:
        print("FAIL: ordinary (no base-commit arg) SBOM carries bit:pass1-base-commit", file=sys.stderr)
        return 1
    print("ok: no bit:pass1-base-commit property without a pass1-base-commit argument")

    with tempfile.TemporaryDirectory() as venv_dir2:
        venv.create(venv_dir2, with_pip=True)
        pip2 = str(Path(venv_dir2, "bin", "pip"))
        python2 = str(Path(venv_dir2, "bin", "python3"))
        subprocess.run(
            [pip2, "install", "--quiet", "--require-hashes", "-r",
             str(ROOT / "dist" / "sbom-requirements.txt")],
            check=True,
        )
        out2 = subprocess.run(
            [python2, str(ROOT / "dist" / "sbom.py"), "9.9.9-test", "0.1.4", "deadbeef1234", "runtime"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout
        doc2 = json.loads(out2)

        # #5753: a stdlib syntax transition's pass1-base-commit is a DIFFERENT
        # directory than a runtime ABI one's -- the SBOM must say which
        # rather than always describing runtime/**.
        out3 = subprocess.run(
            [python2, str(ROOT / "dist" / "sbom.py"), "9.9.9-test", "0.1.4", "cafef00d5678", "stdlib"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout
        doc3 = json.loads(out3)

        # #5753: <pass1-dir> is required once <pass1-base-commit> is given --
        # a missing/invalid one must refuse rather than silently default to
        # "runtime", which was exactly the bug this test file is guarding
        # against.
        bad = subprocess.run(
            [python2, str(ROOT / "dist" / "sbom.py"), "9.9.9-test", "0.1.4", "deadbeef1234"],
            capture_output=True,
            text=True,
        )
    props2 = {p["name"]: p["value"] for p in doc2["metadata"]["properties"]}
    if props2.get("bit:pass1-base-commit") != "deadbeef1234":
        print(f"FAIL: two-pass SBOM's bit:pass1-base-commit is {props2.get('bit:pass1-base-commit')!r}, want 'deadbeef1234'", file=sys.stderr)
        return 1
    print("ok: bit:pass1-base-commit property present and correct when a base commit is given")
    if "deadbeef1234" not in get(doc2, "metadata/tools/components/0/description"):
        print("FAIL: two-pass SBOM's stage0 tool description does not name the pass1 base commit", file=sys.stderr)
        return 1
    print("ok: stage0 tool description names the pass1 base commit")
    if props2.get("bit:pass1-dir") != "runtime":
        print(f"FAIL: runtime two-pass SBOM's bit:pass1-dir is {props2.get('bit:pass1-dir')!r}, want 'runtime'", file=sys.stderr)
        return 1
    if "runtime/**" not in get(doc2, "metadata/tools/components/0/description"):
        print("FAIL: runtime two-pass SBOM's stage0 tool description does not name runtime/**", file=sys.stderr)
        return 1
    print("ok: runtime two-pass SBOM names runtime/** and bit:pass1-dir=runtime")

    props3 = {p["name"]: p["value"] for p in doc3["metadata"]["properties"]}
    if props3.get("bit:pass1-dir") != "stdlib":
        print(f"FAIL: stdlib two-pass SBOM's bit:pass1-dir is {props3.get('bit:pass1-dir')!r}, want 'stdlib'", file=sys.stderr)
        return 1
    if "stdlib/**" not in get(doc3, "metadata/tools/components/0/description"):
        print("FAIL: stdlib two-pass SBOM's stage0 tool description does not name stdlib/**", file=sys.stderr)
        return 1
    print("ok: stdlib two-pass SBOM names stdlib/** and bit:pass1-dir=stdlib")

    if bad.returncode == 0:
        print("FAIL: sbom.py exited 0 with a pass1-base-commit but no pass1-dir", file=sys.stderr)
        return 1
    print("ok: sbom.py refuses a pass1-base-commit given without a pass1-dir")

    print("dist/sbom_test.py: all checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
