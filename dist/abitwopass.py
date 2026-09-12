#!/usr/bin/env python3
"""Detect a runtime ABI transition from a failed `./make libbitrt` log and
mechanically derive the pass-1 runtime base commit for the two-pass
BIT_STAGE0_BIN bootstrap (docs/development.md, "Landing a runtime ABI
change"; #4197).

    dist/abitwopass.py <libbitrt-log-file>

On success, prints exactly one line to stdout:

    ABI_TWOPASS_BASE=<sha>

and exits 0. `<sha>` is the closest ancestor of HEAD, per the touched
symbols' (or, for a LAYOUT transition, constants') OWN file history, whose
declared runtime/** value for every mismatched symbol/constant already
equals the pinned stage0's value -- i.e. "the commit before this runtime/**
change" docs/development.md's recipe asks for, derived rather than typed in
by hand, and re-derivable from the tag alone.

#4416: this tool detects TWO distinct refusals from the same guard family
(tools/build/abiarity.bit) -- a declared ARITY mismatch
(checkRuntimeAbiArity, #3152) and an object LAYOUT mismatch
(checkRuntimeAbiLayout, #3891/#3893), e.g. `gcHeaderSize` 32 -> 16 (#4086).
Both are handled by the SAME derivation shape (walk the touched file's
history for the (parent, child) edge where the value changes to/from the
pinned stage0's own value) against two different data sources: a symbol's
declared arity (`./make dump-abi-symbols`) or a named constant's declared
value (`./make dump-layout-consts`). Exactly one of the two refusals can be
present in a given log -- `checkRuntimeAbiArity` returns before ever calling
`checkRuntimeAbiLayout` when it finds an arity mismatch (abiarity.bit:682).

Exit 2 when `<libbitrt-log-file>` contains NEITHER refusal
(tools/build/abiarity.bit, checkRuntimeAbiArity / checkRuntimeAbiLayout).
The caller (dist/release.sh) MUST treat that as a genuine, unrelated build
failure and must NOT attempt a two-pass recovery -- this tool only ever
handles these two documented failure modes.

Exit 1 on any other failure: a refusal is present but a base commit could
not be derived, or the derived base failed verification. Never guesses --
see verify_base() / verify_layout_base().

WHY THIS SHELLS OUT TO THE REAL DRIVER rather than re-parsing signatures (or
constant declarations) itself: `./make dump-abi-symbols` and
`./make dump-layout-consts` (tools/build/abiarity.bit's `stepDumpAbiSymbols`
and tools/build/abilayout.bit's `stepDumpLayoutConsts`, both wired for
exactly this) expose the SAME `parseAbiSymbols` / `layoutConstValue` readers
`checkRuntimeAbiArity` / `checkRuntimeAbiLayout`'s own mismatch detection
already trusts. A second, hand-rolled Python parser could silently drift
from either the moment the Bit-side parser's rules change (the arity one
already handles a multi-line signature window, #4189) -- this tool would
then derive a base commit the real guard disagrees with, and nothing would
say so.
"""
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# The tree whose `./make dump-abi-symbols` / `./make dump-layout-consts`
# reads a candidate commit's declared arities and layout constants
# (stepDumpAbiSymbols in tools/build/abiarity.bit, stepDumpLayoutConsts in
# tools/build/abilayout.bit). ROOT by default -- the git repo being walked
# is also the driver, as for dist/abitwopass-run.sh.
#
# #3971: scripts/verify-reproducible-release.sh installs THIS file into the
# worktree of a tag cut before #4197 so that ROOT (and hence every `git`
# lookup, and dist/abitwopass-boot.sh's build) resolves to that tag's tree,
# which is the only correct repo to derive a pass-1 base from. Those tags
# have no dump steps at all, so that ONE lookup -- a pure parse of the
# source handed to it in BIT_ABI_SCAN_DIR, not a property of the tag -- is
# pointed back at the caller's own checkout through this variable.
DRIVER_ROOT = Path(os.environ.get("BIT_ABITWOPASS_DRIVER_ROOT") or ROOT).resolve()

REFUSAL_MARKER = "refusing to link - runtime ABI arity mismatch against the pinned stage0"

# Mirrors tools/build/abiarity.bit's checkRuntimeAbiArity exactly:
#   "make:   ${m.symbol} (${m.file}): stage0 (${tag}) emits calls for
#    ${m.stage0Arity} arg(s); this tree's runtime/** now declares ${m.treeArity}"
MISMATCH_RE = re.compile(
    r"^make:   (?P<symbol>\S+) \((?P<file>[^)]+)\): stage0 \((?P<tag>v[^)]+)\) "
    r"emits calls for (?P<stage0>\d+) arg\(s\); this tree's runtime/\*\* "
    r"now declares (?P<tree>\d+)$"
)

# #4416: tools/build/abilayout.bit's checkRuntimeAbiLayout -- the SECOND
# refusal this guard family can print, distinct from REFUSAL_MARKER above.
LAYOUT_REFUSAL_MARKER = "refusing to link - runtime object LAYOUT mismatch against the pinned stage0"

# Mirrors checkRuntimeAbiLayout exactly:
#   "make:   ${m.name} (runtime/${m.file}): stage0 (${tag}) was built
#    expecting ${m.stage0Value}; this tree's runtime/** now declares
#    ${m.treeValue}"
# Note the file group excludes the "runtime/" prefix the Bit side prints --
# `m.file` (a LayoutConst.file, e.g. "gc/gc.bit") is relative to `runtime/`,
# same convention arity's `m.file` uses, so both sides key on the same
# (name/symbol, file) pair `./make dump-layout-consts` / `dump-abi-symbols`
# print.
LAYOUT_MISMATCH_RE = re.compile(
    r"^make:   (?P<name>\S+) \(runtime/(?P<file>[^)]+)\): stage0 \((?P<tag>v[^)]+)\) "
    r"was built expecting (?P<stage0>\d+); this tree's runtime/\*\* "
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


class LayoutMismatch:
    def __init__(self, name, file, tag, stage0_value, tree_value):
        self.name = name
        self.file = file
        self.tag = tag
        self.stage0_value = int(stage0_value)
        self.tree_value = int(tree_value)

    def __repr__(self):
        return f"{self.name}({self.file}): stage0={self.stage0_value} tree={self.tree_value}"


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


def parse_layout_mismatches(log_text: str) -> list:
    """Every mismatch line in a checkRuntimeAbiLayout refusal. Empty when
    LAYOUT_REFUSAL_MARKER is not present at all -- mirrors parse_mismatches
    exactly, for the other refusal."""
    if LAYOUT_REFUSAL_MARKER not in log_text:
        return []
    out = []
    for line in log_text.splitlines():
        m = LAYOUT_MISMATCH_RE.match(line)
        if m:
            out.append(LayoutMismatch(m["name"], m["file"], m["tag"], m["stage0"], m["tree"]))
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


def dump_layout_consts(driver_root: Path, scan_dir: Path) -> dict:
    """{(name, file): value} for every abiLayoutConsts() entry found under
    scan_dir, read through the real driver (tools/build/abilayout.bit's
    layoutConstValue, via its stepDumpLayoutConsts, #4416) rather than a
    second, hand-rolled reader. Mirrors dump_abi_symbols exactly, for the
    LAYOUT refusal."""
    proc = subprocess.run(
        ["./make", "dump-layout-consts"],
        cwd=str(driver_root),
        env={**os.environ, "BIT_ABI_SCAN_DIR": str(scan_dir)},
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        raise RuntimeError(
            f"./make dump-layout-consts failed (rc={proc.returncode}) for {scan_dir}:\n{proc.stderr}"
        )
    out = {}
    for line in proc.stdout.splitlines():
        parts = line.split("\t")
        if len(parts) != 3:
            continue
        name, value, file = parts
        out[(name, file)] = int(value)
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


def layout_value_at_commit(git_repo: Path, driver_root: Path, sha: str, file: str, name: str):
    """The value the named layout constant had in runtime/<file> at `sha` in
    git_repo, or None if that path did not exist there at that commit.
    Mirrors arity_at_commit exactly, reading through dump_layout_consts
    instead of dump_abi_symbols."""
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
        consts = dump_layout_consts(driver_root, Path(scratch))
    return consts.get((name, file))


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


def find_boundary_commit(
    git_repo: Path,
    driver_root: Path,
    file: str,
    symbol: str,
    stage0_arity: int,
    value_fn=arity_at_commit,
    value_label: str = "arity",
) -> str:
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

    #4416: `value_fn`/`value_label` generalise this over BOTH refusals --
    the defaults (`arity_at_commit`, "arity") are the ARITY path and are
    UNCHANGED from #4197: every existing caller passes 5 positional args and
    gets IDENTICAL behaviour, including this docstring's and every raised
    message's exact wording. Passing `layout_value_at_commit`/"value" walks a
    named layout constant's declared value instead of a symbol's arity;
    `symbol`/`stage0_arity` then mean the constant's name and the pinned
    stage0's value for it -- same shape, a different data source.
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
        cur = value_fn(git_repo, driver_root, sha, file, symbol)
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
        if value_fn(git_repo, driver_root, parent, file, symbol) == stage0_arity:
            return parent
    raise RuntimeError(
        f"no (parent, child) edge in runtime/{file}'s history changes {symbol}'s "
        f"declared {value_label} to {stage0_arity} (the pinned stage0's own "
        f"{value_label}) -- cannot derive a pass-1 base mechanically"
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


def derive_layout_base(git_repo: Path, driver_root: Path, mismatches: list) -> str:
    """Mirrors derive_base exactly, for the LAYOUT refusal: one boundary
    commit per named constant (via layout_value_at_commit), the earliest by
    commit time is the base."""
    boundaries = {
        (m.name, m.file): find_boundary_commit(
            git_repo, driver_root, m.file, m.name, m.stage0_value, layout_value_at_commit, "value"
        )
        for m in mismatches
    }
    return min(boundaries.values(), key=lambda sha: commit_time(git_repo, sha))


def verify_layout_base(git_repo: Path, driver_root: Path, base: str, mismatches: list):
    """Mirrors verify_base exactly, for the LAYOUT refusal: re-check every
    mismatched constant's value AT THE DERIVED BASE."""
    for m in mismatches:
        got = layout_value_at_commit(git_repo, driver_root, base, m.file, m.name)
        if got != m.stage0_value:
            raise RuntimeError(
                f"derived base {base} does NOT carry the pinned stage0's value for "
                f"{m.name} ({m.file}): got {got}, want {m.stage0_value} -- refusing"
            )


def run_arity(mismatches: list) -> int:
    """The ARITY refusal path, byte-identical to #4197: unchanged from
    before #4416 other than living in its own function so main() can pick
    between this and run_layout below."""
    print(
        f"abitwopass.py: {len(mismatches)} mismatched symbol(s): "
        f"{', '.join(str(m) for m in mismatches)}",
        file=sys.stderr,
    )
    try:
        base = derive_base(ROOT, DRIVER_ROOT, mismatches)
        verify_base(ROOT, DRIVER_ROOT, base, mismatches)
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


def run_layout(mismatches: list) -> int:
    """The LAYOUT refusal path (#4416), mirroring run_arity exactly."""
    print(
        f"abitwopass.py: {len(mismatches)} mismatched layout constant(s): "
        f"{', '.join(str(m) for m in mismatches)}",
        file=sys.stderr,
    )
    try:
        base = derive_layout_base(ROOT, DRIVER_ROOT, mismatches)
        verify_layout_base(ROOT, DRIVER_ROOT, base, mismatches)
    except RuntimeError as e:
        print(f"abitwopass.py: {e}", file=sys.stderr)
        return 1
    print(
        f"abitwopass.py: pass-1 base = {base} (verified: runtime/** there carries "
        f"the pinned stage0's value for every mismatched layout constant)",
        file=sys.stderr,
    )
    print(f"ABI_TWOPASS_BASE={base}")
    return 0


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: abitwopass.py <libbitrt-log-file>", file=sys.stderr)
        return 2
    log_text = Path(sys.argv[1]).read_text()

    arity_mismatches = parse_mismatches(log_text)
    if arity_mismatches:
        return run_arity(arity_mismatches)

    layout_mismatches = parse_layout_mismatches(log_text)
    if layout_mismatches:
        return run_layout(layout_mismatches)

    print(
        "abitwopass.py: no runtime ABI arity or LAYOUT refusal found in the log; "
        "not a transition this tool handles",
        file=sys.stderr,
    )
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
