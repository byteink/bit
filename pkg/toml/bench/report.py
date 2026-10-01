#!/usr/bin/env python3
"""Record and render pkg/toml's benchmark results (#5488, #6438).

  report.py record OUT RESULTS_JSON COMMIT STAMP BITVER GOVER HOST RUNS TOOLS
      read the timed runs under OUT (written by run.sh) into RESULTS_JSON
  report.py render RESULTS_JSON README RESULTS_MD
      rebuild the README block and RESULTS.md from RESULTS_JSON alone,
      measuring nothing

THE BLOCK IS GENERATED, NEVER HAND-EDITED. The README block is the five
things a reader scans in ten seconds: one summary sentence, one table of
"Nx faster" / "Nx slower" cells, a memory line, the machine and the date, and
a link. Every table and method paragraph that used to sit in the block lives
in RESULTS.md, rendered from the same JSON. The block is checked against
BANNED before it is written: a jargon word fails the run.

The estimator is run.sh's trimmean(): drop the slowest fifth of the runs,
average the rest.
"""
import json
import os
import re
import sys

SUBJECT = "bit"
SIDES = [
    ("bit", "pkg/toml"),
    ("burntsushi", "BurntSushi/toml"),
    ("gotoml", "go-toml/v2 (pelletier)"),
    ("rusttoml", "toml (Rust)"),
    ("tomledit", "toml_edit (Rust)"),
    ("tomlpp", "toml++ (C++)"),
    ("tomlc17", "tomlc17 (C)"),
]
# (file under bench/data, subdirectory of out/ holding its runs, plain title,
# what is in it)
FIXTURES = [
    (
        "fixture.toml",
        "",
        "Cargo manifest",
        "a Cargo-manifest shape scaled up with tables, arrays of tables, inline "
        "tables, dotted keys, all four TOML 1.0.0 date-time forms and multi-line "
        "strings",
    ),
    (
        "config.toml",
        "config",
        "Service config",
        "many small tables, escape-dense long strings and big integer and float "
        "arrays",
    ),
]
BANNED = re.compile(
    r"cycles|instructions retired|rss|trimmed mean|quantis|stw|startup-corrected",
    re.I,
)
SAME = 0.05  # within this of 1.0x reads "about the same"
BEGIN, END = "<!-- BENCH:START -->", "<!-- BENCH:END -->"


def trimmean(vals):
    vals = sorted(vals)
    k = max(1, len(vals) // 5)
    kept = vals[: len(vals) - k]
    return sum(kept) / len(kept)


def read_runs(path):
    if not os.path.exists(path):
        return None
    return [float(x) for x in open(path)]


# ---------------------------------------------------------------- record


def record_fixture(out_dir, data_dir, fname, sub, title, desc):
    bytes_ = os.path.getsize(os.path.join(data_dir, fname))
    dir_ = os.path.join(out_dir, sub) if sub else out_dir
    sides = []
    for key, label in SIDES:
        rs = read_runs(os.path.join(dir_, key + ".rs"))
        ms = read_runs(os.path.join(dir_, key + ".ms"))
        if rs is None or ms is None:
            continue
        secs = trimmean(rs)
        side = {
            "key": key,
            "label": label,
            "mb_s": round(bytes_ / secs / 1e6, 1),
            "rss_mb": round(trimmean(ms) / 1048576, 1),
        }
        empty = read_runs(os.path.join(out_dir, "empty", key + ".rs"))
        if empty is not None and trimmean(empty) < secs:
            side["net_mb_s"] = round(bytes_ / (secs - trimmean(empty)) / 1e6, 1)
        sides.append(side)
    if not sides:
        return None
    return {"file": fname, "title": title, "desc": desc, "bytes": bytes_, "sides": sides}


def record(args):
    out_dir, dest, commit, stamp, bitver, gover, host, runs, tools = args
    data_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "data")
    fixtures = [record_fixture(out_dir, data_dir, *f) for f in FIXTURES]
    verify = os.path.join(out_dir, "verify.txt")
    data = {
        "commit": commit,
        "stamp": stamp,
        "bit": bitver,
        "go": gover,
        "host": host,
        "runs": int(runs),
        "tools": tools,
        "fixtures": [f for f in fixtures if f],
        "verification": open(verify).read().rstrip("\n") if os.path.exists(verify) else "",
    }
    with open(dest, "w") as f:
        json.dump(data, f, indent=1)
        f.write("\n")


# ---------------------------------------------------------------- render


def speed(side):
    return side.get("net_mb_s", side["mb_s"])


def verdict(mine, theirs):
    """pkg/toml against one parser: ('faster'|'slower'|'same', factor)."""
    r = mine / theirs
    if abs(r - 1) <= SAME:
        return "same", 1.0
    return ("faster", r) if r > 1 else ("slower", 1 / r)


def cell(kind, factor):
    return "about the same" if kind == "same" else f"{factor:.1f}x {kind}"


def sides_of(fx):
    return {s["key"]: s for s in fx["sides"]}


def peers(data):
    seen = []
    for fx in data["fixtures"]:
        for s in fx["sides"]:
            if s["key"] != SUBJECT and s["label"] not in seen:
                seen.append(s["label"])
    return seen


def comparisons(data):
    """(fixture title, parser label, kind, factor) for every cell."""
    out = []
    for fx in data["fixtures"]:
        by = sides_of(fx)
        mine = speed(by[SUBJECT])
        for s in fx["sides"]:
            if s["key"] != SUBJECT:
                out.append((fx["title"], s["label"], *verdict(mine, speed(s))))
    return out


def summary(data):
    cs = comparisons(data)
    counts = {k: sum(1 for c in cs if c[2] == k) for k in ("faster", "same", "slower")}
    words = {"faster": "faster in", "same": "about the same in", "slower": "slower in"}
    parts = [f"{words[k]} {counts[k]}" for k in ("faster", "same", "slower") if counts[k]]
    text = f"In {len(cs)} comparisons with other TOML parsers, pkg/toml is " + " and ".join(
        parts
    )
    worst = max((c for c in cs if c[2] == "slower"), key=lambda c: c[3], default=None)
    if worst:
        text += f"; the biggest gap is {worst[1]}, {worst[3]:.1f}x faster than pkg/toml ({worst[0]})"
    return text + "."


def table(data):
    cols = peers(data)
    rows = ["| File | " + " | ".join(f"pkg/toml vs {c}" for c in cols) + " |"]
    rows.append("|---|" + "|".join("---" for _ in cols) + "|")
    for fx in data["fixtures"]:
        by = {s["label"]: s for s in fx["sides"]}
        mine = speed(by["pkg/toml"])
        cells = [
            cell(*verdict(mine, speed(by[c]))) if c in by else "not measured" for c in cols
        ]
        size = f"{fx['bytes'] / 1048576:.2f} MB"
        rows.append(f"| {fx['title']}, {size} | " + " | ".join(cells) + " |")
    return "\n".join(rows)


def span(vals):
    lo, hi = min(vals), max(vals)
    return f"{lo:.0f} MB" if round(lo) == round(hi) else f"{lo:.0f} to {hi:.0f} MB"


def memory(data):
    mine, others = [], []
    for fx in data["fixtures"]:
        for s in fx["sides"]:
            (mine if s["key"] == SUBJECT else others).append(s["rss_mb"])
    return (
        f"Memory: pkg/toml needs {span(mine)} to parse these files; "
        f"the other parsers need {span(others)}."
    )


def block(data):
    text = "\n\n".join(
        [
            "## Benchmarks",
            summary(data),
            table(data),
            memory(data),
            f"Measured on {data['host']} on {data['stamp'][:10]} with {data['bit']}.",
            "Full numbers and method: [bench/RESULTS.md](bench/RESULTS.md)",
        ]
    )
    hit = BANNED.search(text)
    assert not hit, f"banned word {hit.group(0)!r} in the README block"
    assert chr(0x2014) not in text, "em dash in the README block"
    return text


def results_md(data):
    names = " and ".join(", ".join(peers(data)).rsplit(", ", 1))
    out = [
        "# pkg/toml benchmark results",
        "",
        "Generated by `pkg/toml/bench/run.sh` from `bench/results.json`. Do not edit by hand.",
    ]
    if data.get("seeded_from"):
        out += ["", f"Recorded figures: {data['seeded_from']}."]
    out += [
        "",
        "## Method",
        "",
        f"Parse throughput of pkg/toml against {names}. Every parser reads the "
        "same checked-in fixture and parses it to a byte-identical checksum "
        "before anything is timed (entry count plus a CRC-32C fold over every "
        "key and scalar value, sorted by key so an unordered Go map iterates "
        "the same as pkg/toml's source-ordered table).",
        "",
        f"Each figure is the trimmed mean (slowest fifth of {data['runs']} runs "
        "dropped, mean of the rest) of one process invocation: read the "
        "fixture, parse it once, print an entry count, exit. The checksum walk "
        "is a separate, untimed mode of the same binary (folding and sorting "
        "the whole tree on every timed run would measure parse+hash "
        "throughput, not parse throughput). `vs pkg/toml` divides that "
        "implementation's MB/s by pkg/toml's own. Where a run recorded the "
        "empty-document control (process start, runtime init, reading a file "
        "and exit, with nothing to parse), MB/s is startup-corrected: the "
        "control's time is subtracted first.",
        "",
        "Peak RSS is the kernel's \"maximum resident set size\" for that same "
        "process, trimmed the same way.",
        "",
        "Every competitor is cross-compiled for this host's own OS/arch inside "
        "a throwaway `docker run` (never installed on the host) and then run "
        "natively, exactly like pkg/toml's own binary. Nothing is timed from "
        "inside the container, which would fold Docker Desktop's VM overhead "
        "into one side of the comparison and not the other.",
        "",
        f"Versions: compiler {data['bit']} (released), {data['go']}, {data['tools']}.",
        f"Host: {data['host']}.",
        f"Generated from pkg/toml at `{data['commit']}` on {data['stamp']}.",
    ]
    for fx in data["fixtures"]:
        base = speed(sides_of(fx)[SUBJECT])
        out += [
            "",
            f"## {fx['title']} (`bench/data/{fx['file']}`, {fx['bytes']:,} bytes)",
            "",
            f"The fixture is {fx['desc']}. Checked in, never regenerated at run time.",
            "",
            "| Implementation | MB/s | Peak RSS | vs pkg/toml |",
            "|---|--:|--:|--:|",
        ]
        for s in fx["sides"]:
            out.append(
                f"| {s['label']} | {speed(s):,.1f} | {s['rss_mb']:,.1f} MB | "
                f"{speed(s) / base:.2f}x |"
            )
    if data["verification"]:
        out += ["", "## Verification, exactly as it ran", "", "```", data["verification"], "```"]
    return "\n".join(out) + "\n"


def inject(readme, body):
    text = open(readme).read()
    if BEGIN not in text or END not in text:
        sys.exit(f"{readme} has no {BEGIN} / {END} pair to write into")
    head, rest = text.split(BEGIN, 1)
    _, tail = rest.split(END, 1)
    open(readme, "w").write(f"{head}{BEGIN}\n{body}\n{END}{tail}")


def render(args):
    src, readme, results = args
    data = json.load(open(src))
    inject(readme, block(data))
    open(results, "w").write(results_md(data))


if __name__ == "__main__":
    modes = {"record": (record, 11), "render": (render, 5)}
    if len(sys.argv) < 2 or sys.argv[1] not in modes:
        sys.exit(__doc__)
    fn, argc = modes[sys.argv[1]]
    if len(sys.argv) != argc:
        sys.exit(__doc__)
    fn(sys.argv[2:])
