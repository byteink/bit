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

#4416 adds the LAYOUT-refusal cases (`test_parse_layout_mismatches`,
`test_layout_boundary_uses_true_parent_not_filtered_log_adjacency`,
`test_derive_layout_base_picks_the_earliest_across_constants`,
`test_verify_layout_base`), mirroring the arity cases above but exercising
`./make dump-layout-consts` (tools/build/abilayout.bit's own
`stepDumpLayoutConsts`) instead of `./make dump-abi-symbols`. The fake repo's
layout constants MUST use names `tools/build/abilayout.bit`'s
`abiLayoutConsts()` actually lists (e.g. `gcHeaderSize` in `gc/gc.bit`,
`slcHeaderSize` in `root/root.bit`) -- unlike the arity path, the driver does
not take an arbitrary symbol name, only the fixed, hand-picked constant
table (this file's own header explains why: only fields a compiler-emitted
literal actually writes, or that codegen must agree with the runtime on, are
a real ABI data contract).

#4417: `commit()`/`merge()` below give every commit/merge a distinct,
explicit GIT_AUTHOR_DATE/GIT_COMMITTER_DATE (a monotonic fake clock,
`_next_fake_date`) rather than relying on wall-clock time between
back-to-back `git` calls. On a fast machine `build_fake_repo`'s five commits
could land in the same second-resolution timestamp, and `derive_base`'s
`min(..., key=commit_time)` then broke the tie by dict-iteration order
instead of true chronological order --
`test_derive_base_picks_the_earliest_across_symbols` reproduced this on 3/3
runs before the fix.
"""
import os
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import abitwopass as atp  # noqa: E402

DRIVER_ROOT = atp.ROOT


def run(argv, cwd):
    return subprocess.run(argv, cwd=str(cwd), capture_output=True, text=True, check=True)


def run_env(argv, cwd, env):
    return subprocess.run(
        argv, cwd=str(cwd), capture_output=True, text=True, check=True, env={**os.environ, **env}
    )


# #4417: a monotonically increasing fake clock for every commit/merge this
# file makes, so two commits made back-to-back never share a
# second-resolution git timestamp -- see commit()'s own docstring for why
# that matters.
_FAKE_CLOCK = [1600000000]


def _next_fake_date() -> str:
    _FAKE_CLOCK[0] += 1
    return f"{_FAKE_CLOCK[0]} +0000"


def commit(repo, msg):
    """#4417: explicit GIT_AUTHOR_DATE/GIT_COMMITTER_DATE, strictly
    increasing per call (_next_fake_date), rather than relying on wall-clock
    time between back-to-back `git commit` calls. On a fast machine all of
    build_fake_repo's five commits can land in the same second-resolution
    timestamp; derive_base's `min(..., key=commit_time)` then breaks the tie
    by dict-iteration order instead of true chronological order, which is
    exactly why test_derive_base_picks_the_earliest_across_symbols was
    flaky (reproduced deterministically before this fix: FAIL on 3/3 runs)."""
    date = _next_fake_date()
    run(["git", "add", "-A"], repo)
    run_env(["git", "commit", "-q", "-m", msg], repo, {"GIT_AUTHOR_DATE": date, "GIT_COMMITTER_DATE": date})
    return run(["git", "rev-parse", "HEAD"], repo).stdout.strip()


def merge(repo, msg, branch):
    """Mirrors commit() -- same dated-clock fix, for the one `git merge`
    build_fake_repo/build_fake_layout_repo each make."""
    date = _next_fake_date()
    run_env(
        ["git", "merge", "-q", "--no-ff", "-m", msg, branch],
        repo,
        {"GIT_AUTHOR_DATE": date, "GIT_COMMITTER_DATE": date},
    )
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
    f2 = merge(repo, "F2: merge side (touches neither x.bit nor y.bit)", "side")

    write_symbol(repo, "root/x.bit", "bit_rt_foo", 3)
    f3 = commit(repo, "F3: bit_rt_foo gains a param (arity 3)")

    return repo, {"g0": g0, "f1": f1, "g1": g1, "f2": f2, "f3": f3}


def check(desc, cond):
    if not cond:
        print(f"FAIL: {desc}", file=sys.stderr)
        return False
    print(f"ok: {desc}")
    return True


def write_layout_const(repo, rel_path, name, value):
    p = repo / "runtime" / rel_path
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(f"export const {name} = {value}\n")


def build_fake_layout_repo(tmp):
    """G0 (slcHeaderSize 40) -> F1 (adds gc/gc.bit, gcHeaderSize 32) -> G1
    (slcHeaderSize 48) -> [side branch, unrelated] -> F2 (merge, touches
    NEITHER gc.bit NOR root.bit) -> F3 (gcHeaderSize 16, parent F2).

    Mirrors build_fake_repo's shape exactly (same #4064-shaped merge-commit
    trap for `find_boundary_commit`, same dated-clock fix, #4417) but for
    named layout constants: the dump driver (`./make dump-layout-consts`)
    only recognises the FIXED table `tools/build/abilayout.bit`'s
    `abiLayoutConsts()` declares, not an arbitrary name, so
    `gcHeaderSize`/`gc/gc.bit` and `slcHeaderSize`/`root/root.bit` (both real
    entries) stand in for the fake `bit_rt_foo`/`bit_rt_bar` symbols above."""
    repo = Path(tmp) / "repo"
    repo.mkdir()
    run(["git", "init", "-q", "-b", "main"], repo)
    run(["git", "config", "user.email", "test@test"], repo)
    run(["git", "config", "user.name", "test"], repo)

    write_layout_const(repo, "root/root.bit", "slcHeaderSize", 40)
    g0 = commit(repo, "G0: slcHeaderSize = 40")

    write_layout_const(repo, "gc/gc.bit", "gcHeaderSize", 32)
    f1 = commit(repo, "F1: add gc.bit (gcHeaderSize = 32)")

    write_layout_const(repo, "root/root.bit", "slcHeaderSize", 48)
    g1 = commit(repo, "G1: slcHeaderSize gains a field (40 -> 48)")

    run(["git", "checkout", "-q", "-b", "side"], repo)
    other = repo / "runtime" / "unrelated.bit"
    other.write_text("// nothing exported here\n")
    commit(repo, "side: touch an unrelated file")
    run(["git", "checkout", "-q", "main"], repo)
    f2 = merge(repo, "F2: merge side (touches neither gc.bit nor root.bit)", "side")

    write_layout_const(repo, "gc/gc.bit", "gcHeaderSize", 16)
    f3 = commit(repo, "F3: gc header shrinks 32 -> 16")

    return repo, {"g0": g0, "f1": f1, "g1": g1, "f2": f2, "f3": f3}


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


# ---- #4416: the LAYOUT refusal path -----------------------------------


def test_parse_layout_mismatches():
    ok = True
    text = (
        "make: selfhost: runtime ABI arity scan: parsed=818 dropped=0\n"
        "make: selfhost: refusing to link — runtime object LAYOUT mismatch against the pinned stage0 (v0.10.0):\n"
        "make:   gcHeaderSize (runtime/gc/gc.bit): stage0 (v0.10.0) was built expecting 32; this tree's runtime/** now declares 16\n"
        "make: stage0 is the compiler that EMITS this object's layout...\n"
    )
    ms = atp.parse_layout_mismatches(text)
    ok &= check("parse_layout_mismatches finds exactly one mismatch", len(ms) == 1)
    ok &= check("parsed name", ms[0].name == "gcHeaderSize")
    ok &= check("parsed file", ms[0].file == "gc/gc.bit")
    ok &= check("parsed stage0 value", ms[0].stage0_value == 32)
    ok &= check("parsed tree value", ms[0].tree_value == 16)

    ok &= check(
        "no marker -> no layout mismatches",
        atp.parse_layout_mismatches("make: libbitrt-aarch64-macos failed (1)\n") == [],
    )

    # An ARITY refusal (the OTHER member of this guard family) must not be
    # mistaken for a LAYOUT one -- the two markers/regexes are disjoint.
    arity_text = (
        "make: selfhost: refusing to link — runtime ABI arity mismatch against the pinned stage0 (v0.7.0):\n"
        "make:   bit_rt_map_new (root/maps.bit): stage0 (v0.7.0) emits calls for 2 arg(s); "
        "this tree's runtime/** now declares 3\n"
    )
    ok &= check("an ARITY refusal parses to zero layout mismatches", atp.parse_layout_mismatches(arity_text) == [])
    ok &= check("...and the arity parser still sees it (unaffected)", len(atp.parse_mismatches(arity_text)) == 1)
    return ok


def test_layout_boundary_uses_true_parent_not_filtered_log_adjacency(tmp):
    repo, sha = build_fake_layout_repo(tmp)

    log = run(["git", "log", "--format=%H", "--", "runtime/gc/gc.bit"], repo).stdout.split()
    ok = check("path-filtered log for gc.bit omits the merge commit F2", sha["f2"] not in log)
    ok &= check("path-filtered log for gc.bit includes F1 and F3", sha["f1"] in log and sha["f3"] in log)

    base = atp.find_boundary_commit(
        repo, DRIVER_ROOT, "gc/gc.bit", "gcHeaderSize", 32, atp.layout_value_at_commit, "value"
    )
    ok &= check(f"boundary for gcHeaderSize is F2 ({sha['f2'][:8]}), not F1 ({sha['f1'][:8]})", base == sha["f2"])
    return ok


def test_derive_layout_base_picks_the_earliest_across_constants(tmp):
    repo, sha = build_fake_layout_repo(tmp)
    mismatches = [
        atp.LayoutMismatch("gcHeaderSize", "gc/gc.bit", "v9.9.9", 32, 16),
        atp.LayoutMismatch("slcHeaderSize", "root/root.bit", "v9.9.9", 40, 48),
    ]
    base = atp.derive_layout_base(repo, DRIVER_ROOT, mismatches)
    return check(f"combined base is F1 ({sha['f1'][:8]}), the earlier of the two boundaries", base == sha["f1"])


def test_verify_layout_base(tmp):
    repo, sha = build_fake_layout_repo(tmp)
    mismatches = [
        atp.LayoutMismatch("gcHeaderSize", "gc/gc.bit", "v9.9.9", 32, 16),
        atp.LayoutMismatch("slcHeaderSize", "root/root.bit", "v9.9.9", 40, 48),
    ]
    ok = True
    try:
        atp.verify_layout_base(repo, DRIVER_ROOT, sha["f1"], mismatches)
        ok &= check("verify_layout_base accepts the correct base (F1)", True)
    except RuntimeError as e:
        ok &= check(f"verify_layout_base accepts the correct base (F1) -- raised {e!r}", False)

    # Mutation control: F3 has gcHeaderSize at 16, not the stage0 value (32)
    # the mismatch set demands -- verify_layout_base MUST refuse it.
    try:
        atp.verify_layout_base(repo, DRIVER_ROOT, sha["f3"], mismatches)
        ok &= check("verify_layout_base rejects a wrong base (F3)", False)
    except RuntimeError:
        ok &= check("verify_layout_base rejects a wrong base (F3)", True)
    return ok


def main() -> int:
    ok = test_parse_mismatches()
    ok &= test_parse_layout_mismatches()
    with tempfile.TemporaryDirectory(prefix="abitwopass-test-") as tmp1:
        ok &= test_boundary_uses_true_parent_not_filtered_log_adjacency(tmp1)
    with tempfile.TemporaryDirectory(prefix="abitwopass-test-") as tmp1b:
        ok &= test_layout_boundary_uses_true_parent_not_filtered_log_adjacency(tmp1b)
    with tempfile.TemporaryDirectory(prefix="abitwopass-test-") as tmp2:
        ok &= test_derive_base_picks_the_earliest_across_symbols(tmp2)
    with tempfile.TemporaryDirectory(prefix="abitwopass-test-") as tmp2b:
        ok &= test_derive_layout_base_picks_the_earliest_across_constants(tmp2b)
    with tempfile.TemporaryDirectory(prefix="abitwopass-test-") as tmp3:
        ok &= test_verify_base(tmp3)
    with tempfile.TemporaryDirectory(prefix="abitwopass-test-") as tmp3b:
        ok &= test_verify_layout_base(tmp3b)

    if not ok:
        print("dist/abitwopass_test.py: FAILED", file=sys.stderr)
        return 1
    print("dist/abitwopass_test.py: all checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
