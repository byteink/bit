#!/usr/bin/env python3
"""Detect a runtime ABI transition from a failed `./make libbitrt` log and
mechanically derive the pass-1 runtime base commit for the two-pass
BIT_STAGE0_BIN bootstrap (docs/development.md, "Landing a runtime ABI
change"; #4197).

    dist/abitwopass.py <libbitrt-log-file>

On success, prints exactly one line to stdout:

    ABI_TWOPASS_BASE=<sha>

and exits 0. `<sha>` is the closest ancestor of HEAD, per the touched
symbols' OWN file history, whose declared runtime/** arity for every
mismatched symbol already equals the pinned stage0's arity — i.e. "the
commit before this runtime/** change" docs/development.md's recipe asks for,
derived rather than typed in by hand, and re-derivable from the tag alone.

Exit 2 when `<libbitrt-log-file>` does not contain the ABI arity refusal at
all (tools/build/abiarity.bit, checkRuntimeAbiArity). The caller
(dist/release.sh) MUST treat that as a genuine, unrelated build failure and
must NOT attempt a two-pass recovery — this tool only ever handles the one
documented failure mode.

Exit 1 on any other failure: the refusal is present but a base commit could
not be derived, or the derived base failed verification. Never guesses --
see verify_base().

WHY THIS SHELLS OUT TO THE REAL DRIVER rather than re-parsing signatures
itself: `./make dump-abi-symbols` (tools/build/abiarity.bit's own
`stepDumpAbiSymbols`, wired for exactly this) exposes the SAME
`parseAbiSymbols` reader `checkRuntimeAbiArity`'s own mismatch detection
already trusts. A second, hand-rolled Python parser could silently drift
from it the moment the Bit-side parser's rules change (it already handles a
multi-line signature window, #4189) -- this tool would then derive a base
commit the real guard disagrees with, and nothing would say so.
"""
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

REFUSAL_MARKER = "refusing to link — runtime ABI arity mismatch against the pinned stage0"

# Mirrors tools/build/abiarity.bit's checkRuntimeAbiArity exactly:
#   "make:   ${m.symbol} (${m.file}): stage0 (${tag}) emits calls for
#    ${m.stage0Arity} arg(s); this tree's runtime/** now declares ${m.treeArity}"
MISMATCH_RE = re.compile(
    r"^make:   (?P<symbol>\S+) \((?P<file>[^)]+)\): stage0 \((?P<tag>v[^)]+)\) "
    r"emits calls for (?P<stage0>\d+) arg\(s\); this tree's runtime/\*\* "
    r"now declares (?P<tree>\d+)$"
)


class Mismatch:
    def __init__(self, symbol, file, tag, stage0_arity, tree_arity):
        self.symbol = symbol
        self.file = file
        self.tag = tag
        self.stage0_arity = int(stage0_arity)
        self.tree_arity = int(tree_arity)

    def __repr__(self):
        return f"{self.symbol}({self.file}): stage0={self.stage0_arity} tree={self.tree_arity}"


def parse_mismatches(log_text: str) -> list:
    """Every mismatch line in a checkRuntimeAbiArity refusal. Empty when the
    refusal marker is not present at all -- the caller decides what that
    means (main() below treats it as "not my problem")."""
    if REFUSAL_MARKER not in log_text:
        return []
    out = []
    for line in log_text.splitlines():
        m = MISMATCH_RE.match(line)
        if m:
            out.append(Mismatch(m["symbol"], m["file"], m["tag"], m["stage0"], m["tree"]))
    return out


def dump_abi_symbols(driver_root: Path, scan_dir: Path) -> dict:
    """{(name, file): arity} for every @symbol(...) export under scan_dir,
    read through the real driver (tools/build/abiarity.bit's
    parseAbiSymbols) rather than a second, hand-rolled reader."""
    proc = subprocess.run(
        ["./make", "dump-abi-symbols"],
        cwd=str(driver_root),
        env={**os.environ, "BIT_ABI_SCAN_DIR": str(scan_dir)},
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        raise RuntimeError(
            f"./make dump-abi-symbols failed (rc={proc.returncode}) for {scan_dir}:\n{proc.stderr}"
        )
    out = {}
    for line in proc.stdout.splitlines():
        parts = line.split("\t")
        if len(parts) != 3:
            continue
        name, arity, file = parts
        out[(name, file)] = int(arity)
    return out


def arity_at_commit(git_repo: Path, driver_root: Path, sha: str, file: str, symbol: str):
    """The arity `symbol` had in runtime/<file> at `sha` in git_repo, or None
    if that path did not exist there at that commit."""
    show = subprocess.run(
        ["git", "-C", str(git_repo), "show", f"{sha}:runtime/{file}"],
        capture_output=True,
        text=True,
    )
    if show.returncode != 0:
        return None
    with tempfile.TemporaryDirectory(prefix="abitwopass-scan-") as scratch:
        dest = Path(scratch) / file
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_text(show.stdout)
        symbols = dump_abi_symbols(driver_root, Path(scratch))
    return symbols.get((symbol, file))


def resolve_parent(git_repo: Path, sha: str):
    """`sha`'s own first parent in the TRUE commit graph (`git rev-parse
    <sha>^`) -- never the previous entry in a path-filtered `git log`, which
    silently skips a merge commit whose diff for that one path is empty
    (exactly `bfda26a0`'s own parent, `01878950`, a "Merge #4182: ..." that
    does not touch runtime/root/maps.bit itself). Using the file-filtered
    log's own adjacency instead of the real parent would land on an
    ancestor further back than the actual change, silently discarding
    whatever else that merge brought into runtime/**. None (root commit,
    no parent) is a legitimate answer, not an error."""
    out = subprocess.run(
        ["git", "-C", str(git_repo), "rev-parse", f"{sha}^"],
        capture_output=True,
        text=True,
    )
    if out.returncode != 0:
        return None
    return out.stdout.strip()


def find_boundary_commit(git_repo: Path, driver_root: Path, file: str, symbol: str, stage0_arity: int) -> str:
    """"The commit that changed [SYMBOL]'s arity"'s own parent -- literally,
    per THE FIX in #4197's ticket, not "any ancestor with matching arity".
    Candidates come from runtime/<file>'s path-filtered history (only a
    commit that touched the file can be the one that changed it), walked
    newest first; for each, this checks that candidate's OWN declared arity
    against ITS OWN true git parent's declared arity -- so the transition
    edge is always a real (parent, child) pair in the DAG, never two
    file-log entries that merely happen to be adjacent in the filtered
    list. Refuses (raises) rather than guessing when no such edge exists in
    the recorded history.
    """
    log = subprocess.run(
        ["git", "-C", str(git_repo), "log", "--format=%H", "--", f"runtime/{file}"],
        capture_output=True,
        text=True,
        check=True,
    )
    shas = [s for s in log.stdout.splitlines() if s]
    if not shas:
        raise RuntimeError(f"no git history for runtime/{file} in {git_repo}")
    for sha in shas:
        cur = arity_at_commit(git_repo, driver_root, sha, file, symbol)
        if cur is None:
            continue
        if cur == stage0_arity:
            # This commit's own state already matches stage0 -- it is
            # itself a valid base (we walked past the transition edge
            # without a candidate on its far side, e.g. the very first
            # commit to introduce the symbol already used the old arity).
            return sha
        parent = resolve_parent(git_repo, sha)
        if parent is None:
            continue
        if arity_at_commit(git_repo, driver_root, parent, file, symbol) == stage0_arity:
            return parent
    raise RuntimeError(
        f"no (parent, child) edge in runtime/{file}'s history changes {symbol}'s "
        f"declared arity to {stage0_arity} (the pinned stage0's own arity) -- "
        f"cannot derive a pass-1 base mechanically"
    )


def commit_time(git_repo: Path, sha: str) -> int:
    out = subprocess.run(
        ["git", "-C", str(git_repo), "show", "-s", "--format=%ct", sha],
        capture_output=True,
        text=True,
        check=True,
    )
    return int(out.stdout.strip())


def derive_base(git_repo: Path, driver_root: Path, mismatches: list) -> str:
    """One base commit for every mismatched symbol at once. Each symbol gets
    its own boundary commit (find_boundary_commit); the EARLIEST of those,
    by commit time, is the base -- old enough that every mismatched symbol's
    own change is still in the future relative to it, generalising docs'
    "commit before THIS runtime/** change" to N simultaneous changes."""
    boundaries = {
        (m.symbol, m.file): find_boundary_commit(git_repo, driver_root, m.file, m.symbol, m.stage0_arity)
        for m in mismatches
    }
    return min(boundaries.values(), key=lambda sha: commit_time(git_repo, sha))


def verify_base(git_repo: Path, driver_root: Path, base: str, mismatches: list):
    """The safety net: re-check every mismatched symbol's arity AT THE
    DERIVED BASE, not just trust the walk that found it. A base that fails
    this is refused loudly rather than used -- see this file's own header on
    why the derivation must never be trusted without re-checking."""
    for m in mismatches:
        got = arity_at_commit(git_repo, driver_root, base, m.file, m.symbol)
        if got != m.stage0_arity:
            raise RuntimeError(
                f"derived base {base} does NOT carry the pinned stage0's arity for "
                f"{m.symbol} ({m.file}): got {got}, want {m.stage0_arity} -- refusing"
            )


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: abitwopass.py <libbitrt-log-file>", file=sys.stderr)
        return 2
    log_text = Path(sys.argv[1]).read_text()
    mismatches = parse_mismatches(log_text)
    if not mismatches:
        print(
            "abitwopass.py: no runtime ABI arity refusal found in the log; "
            "not a transition this tool handles",
            file=sys.stderr,
        )
        return 2

    print(
        f"abitwopass.py: {len(mismatches)} mismatched symbol(s): "
        f"{', '.join(str(m) for m in mismatches)}",
        file=sys.stderr,
    )

    try:
        base = derive_base(ROOT, ROOT, mismatches)
        verify_base(ROOT, ROOT, base, mismatches)
    except RuntimeError as e:
        print(f"abitwopass.py: {e}", file=sys.stderr)
        return 1

    print(
        f"abitwopass.py: pass-1 base = {base} (verified: runtime/** there carries "
        f"the pinned stage0's arity for every mismatched symbol)",
        file=sys.stderr,
    )
    print(f"ABI_TWOPASS_BASE={base}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
