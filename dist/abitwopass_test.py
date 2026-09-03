#!/usr/bin/env python3
"""Self-check for dist/abitwopass.py (#4197).

    python3 dist/abitwopass_test.py

Not wired into `./make test` -- dist/*.py's own tests never have been
(dist/sbom_test.py's own header). Builds a throwaway git repo under a temp
dir to test the git-archaeology logic hermetically; the real `bit` build
driver (this repo's own `./make dump-abi-symbols`) is still used to parse
arities, so this also exercises the real, checked-in parser rather than a
second copy of it.

The case `test_boundary_uses_true_parent_not_filtered_log_adjacency` is a
regression test for a bug this ticket's own first draft shipped: walking a
PATH-FILTERED `git log`'s own adjacency instead of each candidate's TRUE
git parent silently landed on an ancestor further back than the actual
change, because `git log -- <path>` omits a merge commit whose diff for
that one path is empty -- exactly `bfda26a0`'s own parent, `01878950`, in
the real #4064 transition. Reverting find_boundary_commit's `resolve_parent`
call to instead read the previous entry in the path-filtered `shas` list
makes this case fail.
"""
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import abitwopass as atp  # noqa: E402

DRIVER_ROOT = atp.ROOT


def run(argv, cwd):
    return subprocess.run(argv, cwd=str(cwd), capture_output=True, text=True, check=True)


def commit(repo, msg):
    run(["git", "add", "-A"], repo)
    run(["git", "commit", "-q", "-m", msg], repo)
    return run(["git", "rev-parse", "HEAD"], repo).stdout.strip()


def write_symbol(repo, rel_path, symbol, params):
    p = repo / "runtime" / rel_path
    p.parent.mkdir(parents=True, exist_ok=True)
    body = ", ".join(f"p{i}: int" for i in range(params))
    p.write_text(f'@symbol("{symbol}")\nfn {symbol}({body}): int {{\n  return 0\n}}\n')


def build_fake_repo(tmp):
    """G0 (bar arity 5) -> F1 (adds x.bit, foo arity 2) -> G1 (bar arity 6)
    -> [side branch, unrelated] -> F2 (merge, touches NEITHER x.bit NOR
    y.bit) -> F3 (foo arity 3, parent F2).

    `git log -- runtime/root/x.bit` therefore lists F3 and F1 but NOT F2 --
    the exact shape that broke the first draft's naive walk."""
    repo = Path(tmp) / "repo"
    repo.mkdir()
    run(["git", "init", "-q", "-b", "main"], repo)
    run(["git", "config", "user.email", "test@test"], repo)
    run(["git", "config", "user.name", "test"], repo)

    write_symbol(repo, "root/y.bit", "bit_rt_bar", 5)
    g0 = commit(repo, "G0: add bit_rt_bar (arity 5)")

    write_symbol(repo, "root/x.bit", "bit_rt_foo", 2)
    f1 = commit(repo, "F1: add bit_rt_foo (arity 2)")

    write_symbol(repo, "root/y.bit", "bit_rt_bar", 6)
    g1 = commit(repo, "G1: bit_rt_bar gains a param (arity 6)")

    run(["git", "checkout", "-q", "-b", "side"], repo)
    other = repo / "runtime" / "unrelated.bit"
    other.write_text("// nothing exported here\n")
    commit(repo, "side: touch an unrelated file")
    run(["git", "checkout", "-q", "main"], repo)
    run(["git", "merge", "-q", "--no-ff", "-m", "F2: merge side (touches neither x.bit nor y.bit)", "side"], repo)
    f2 = run(["git", "rev-parse", "HEAD"], repo).stdout.strip()

    write_symbol(repo, "root/x.bit", "bit_rt_foo", 3)
    f3 = commit(repo, "F3: bit_rt_foo gains a param (arity 3)")

    return repo, {"g0": g0, "f1": f1, "g1": g1, "f2": f2, "f3": f3}


def check(desc, cond):
    if not cond:
        print(f"FAIL: {desc}", file=sys.stderr)
        return False
    print(f"ok: {desc}")
    return True


def test_parse_mismatches():
    ok = True
    text = (
        "make: selfhost: runtime ABI arity scan: parsed=780 dropped=0\n"
        "make: selfhost: refusing to link — runtime ABI arity mismatch against the pinned stage0 (v0.7.0):\n"
        "make:   bit_rt_map_new (root/maps.bit): stage0 (v0.7.0) emits calls for 2 arg(s); this tree's runtime/** now declares 3\n"
        "make: stage0's call-site lowering for these symbols is baked into its own compiled machine code...\n"
    )
    ms = atp.parse_mismatches(text)
    ok &= check("parse_mismatches finds exactly one mismatch", len(ms) == 1)
    ok &= check("parsed symbol", ms[0].symbol == "bit_rt_map_new")
    ok &= check("parsed file", ms[0].file == "root/maps.bit")
    ok &= check("parsed stage0 arity", ms[0].stage0_arity == 2)
    ok &= check("parsed tree arity", ms[0].tree_arity == 3)

    ok &= check("no marker -> no mismatches", atp.parse_mismatches("make: libbitrt-aarch64-macos failed (1)\n") == [])
    return ok


def test_boundary_uses_true_parent_not_filtered_log_adjacency(tmp):
    repo, sha = build_fake_repo(tmp)

    log = run(["git", "log", "--format=%H", "--", "runtime/root/x.bit"], repo).stdout.split()
    ok = check("path-filtered log for x.bit omits the merge commit F2", sha["f2"] not in log)
    ok &= check("path-filtered log for x.bit includes F1 and F3", sha["f1"] in log and sha["f3"] in log)

    base = atp.find_boundary_commit(repo, DRIVER_ROOT, "root/x.bit", "bit_rt_foo", 2)
    ok &= check(f"boundary for bit_rt_foo is F2 ({sha['f2'][:8]}), not F1 ({sha['f1'][:8]})", base == sha["f2"])
    return ok


def test_derive_base_picks_the_earliest_across_symbols(tmp):
    repo, sha = build_fake_repo(tmp)
    mismatches = [
        atp.Mismatch("bit_rt_foo", "root/x.bit", "v9.9.9", 2, 3),
        atp.Mismatch("bit_rt_bar", "root/y.bit", "v9.9.9", 5, 6),
    ]
    base = atp.derive_base(repo, DRIVER_ROOT, mismatches)
    return check(f"combined base is F1 ({sha['f1'][:8]}), the earlier of the two boundaries", base == sha["f1"])


def test_verify_base(tmp):
    repo, sha = build_fake_repo(tmp)
    mismatches = [
        atp.Mismatch("bit_rt_foo", "root/x.bit", "v9.9.9", 2, 3),
        atp.Mismatch("bit_rt_bar", "root/y.bit", "v9.9.9", 5, 6),
    ]
    ok = True
    try:
        atp.verify_base(repo, DRIVER_ROOT, sha["f1"], mismatches)
        ok &= check("verify_base accepts the correct base (F1)", True)
    except RuntimeError as e:
        ok &= check(f"verify_base accepts the correct base (F1) -- raised {e!r}", False)

    # Mutation control: F3 has bit_rt_foo at arity 3, not the stage0 value
    # (2) the mismatch set demands -- verify_base MUST refuse it.
    try:
        atp.verify_base(repo, DRIVER_ROOT, sha["f3"], mismatches)
        ok &= check("verify_base rejects a wrong base (F3)", False)
    except RuntimeError:
        ok &= check("verify_base rejects a wrong base (F3)", True)
    return ok


def main() -> int:
    ok = test_parse_mismatches()
    with tempfile.TemporaryDirectory(prefix="abitwopass-test-") as tmp1:
        ok &= test_boundary_uses_true_parent_not_filtered_log_adjacency(tmp1)
    with tempfile.TemporaryDirectory(prefix="abitwopass-test-") as tmp2:
        ok &= test_derive_base_picks_the_earliest_across_symbols(tmp2)
    with tempfile.TemporaryDirectory(prefix="abitwopass-test-") as tmp3:
        ok &= test_verify_base(tmp3)

    if not ok:
        print("dist/abitwopass_test.py: FAILED", file=sys.stderr)
        return 1
    print("dist/abitwopass_test.py: all checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
