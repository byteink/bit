#!/usr/bin/env python3
"""Render pkg/web's benchmark: collect out/ into recorded.json, then render.

Three steps, so the README can be rebuilt without measuring again:

  report.py collect OUT_DIR   out/ (results.csv and friends) -> recorded.json on stdout
  report.py block RECORDED    the README block, for a reader with ten seconds
  report.py results RECORDED  bench/RESULTS.md: every table and the method

recorded.json is the committed record of the last measured run: the median of
the counted reps for each server, test and connection count, plus the box and
the proofs. Both renderers read ONLY it, so `run.sh --render` regenerates the
README and RESULTS.md from the last recorded run with no new measurement.

The whole block is produced here, prose included, so that nothing between the
BENCH markers can be typed by hand and quietly drift from the numbers beside
it. Every figure in recorded.json is the MEDIAN of the counted reps, published
in RESULTS.md with the observed spread: on an unquota'd container whose
neighbours nobody here can see, a single number with no spread beside it is
not a result a reader can judge.

Every comparison is pkg/web divided by one peer, never one peer against
another: the table exists to say where pkg/web stands.
"""
import csv
import json
import os
import re
import statistics
import sys

TESTS = [("plaintext", "Plaintext, `text/plain`, 13 bytes"),
         ("json", "JSON, one object serialized per request, 27 bytes")]
LABEL = {"bit": "pkg/web", "gin": "gin", "express": "express",
         "bun": "bun", "spring": "Spring Boot", "aspnet": "ASP.NET Core"}
ORDER = ["bit", "gin", "express", "bun", "spring", "aspnet"]
RATIO_FIELDS = ("rps", "cpu_us_per_req", "p50_ms", "p99_ms")


def read_rows(path):
    with open(path) as fh:
        return [r for r in csv.DictReader(fh)]


def kv(path):
    out = {}
    if not os.path.exists(path):
        return out
    for line in open(path):
        if " " in line and not line.startswith("---"):
            k, v = line.rstrip("\n").split(" ", 1)
            out[k.rstrip(":")] = v
    return out


def counted(rows):
    """The first and the last measured rep are dropped when there are three or
    more: the first follows the warmup while its load is still decaying, and
    dropping the last as well keeps the counted window in the middle of the
    run. Of five reps, the published medians are of reps 2-4."""
    reps = sorted({int(r["rep"]) for r in rows})
    keep = set(reps[1:-1]) if len(reps) >= 3 else set(reps)
    return [r for r in rows if int(r["rep"]) in keep], sorted(keep)


def series(rows, fw, test, conn, field):
    return [float(r[field]) for r in rows
            if r["framework"] == fw and r["test"] == test and r["conn"] == conn]


def med(vals):
    return statistics.median(vals) if vals else None


def noise(vals):
    """Half the min..max range as a fraction of the median, the reader's noise
    bar. Reported rather than a stddev because 5 reps do not support one."""
    if len(vals) < 2:
        return None
    m = statistics.median(vals)
    return (max(vals) - min(vals)) / 2.0 / m if m else 0.0


def spread(n):
    return "n/a" if n is None else "%.1f%%" % (100.0 * n)


def rps(n):
    return "{:,}".format(int(round(n)))


def ratio(bit, peer):
    return "%.2fx" % (bit / peer) if bit is not None and peer else "n/a"


def fmt(v, spec):
    return spec % v if v is not None else "n/a"


def cell(data, fw, test, conn):
    return data["cells"].get(fw, {}).get(test, {}).get(conn)


def field(data, fw, test, conn, name):
    c = cell(data, fw, test, conn)
    return c[name] if c else None


def pinning(out_dir):
    """The core sets out of verify.txt, not retyped here: the box hands the
    container a slice of the host's CPUs (ours is 2-7, not 0-5), so remote.sh
    derives the two sets at run time and this is where they are read back."""
    path = os.path.join(out_dir, "verify.txt")
    for line in open(path) if os.path.exists(path) else []:
        m = re.match(r"=== servers pinned (\S+?), load generator (\S+?), disjoint", line)
        if m:
            return m.group(1), m.group(2)
    return "?", "?"


def bad_reps(rows):
    return [r for r in rows if int(r["non200"]) != 0 or int(r["total"]) == 0]


def cpu_count(spec):
    """Number of CPUs in a Cpus_allowed_list spec ("3-5,7" is 4)."""
    if not spec or spec == "?":
        return 0
    n = 0
    for part in spec.split(","):
        lo, _, hi = part.partition("-")
        n += int(hi or lo) - int(lo) + 1
    return n


def quiet_line(out_dir):
    path = os.path.join(out_dir, "quiet.txt")
    lines = open(path).read().splitlines() if os.path.exists(path) else []
    if not lines:
        return "no quiet checks were recorded"
    checks = {l.split(" try ")[0] for l in lines}
    retried = len(lines) - len(checks)
    return "%d quiet checks (before every rep and after the last), %d retr%s" % (
        len(checks), retried, "y" if retried == 1 else "ies")


def versions_line(v):
    parts = [("Bit", v.get("bit", "?")), ("gin", v.get("gin", "?")),
             ("Go", v.get("go", "?")), ("express", v.get("express", "?")),
             ("Node", v.get("node", "?")), ("bun", v.get("bun", "?")),
             ("Spring Boot", v.get("springboot", "?")), ("JVM", v.get("jvm", "?")),
             ("ASP.NET Core on .NET SDK", v.get("dotnet", "?")),
             ("load generator oha", v.get("oha", "?"))]
    return ", ".join("%s %s" % (a, b) for a, b in parts)


def io_line(env_text):
    """The neighbour I/O as measured at run time, from the vmstat tail in
    env.txt. Published because it is the one part of this box a reader cannot
    otherwise see, and it is not ours."""
    rows, seen = [], False
    for line in env_text.splitlines():
        f = line.split()
        if len(f) > 16 and f[0].isdigit():
            if seen:
                rows.append((int(f[1]), int(f[8]), int(f[15])))
            seen = True
    if not rows:
        return "not captured"
    return "%d-%d process(es) blocked on disk, %.1f-%.1f MB/s read, %d-%d%% iowait" % (
        min(r[0] for r in rows), max(r[0] for r in rows),
        min(r[1] for r in rows) / 1024.0, max(r[1] for r in rows) / 1024.0,
        min(r[2] for r in rows), max(r[2] for r in rows))


def read_text(path):
    return open(path).read() if os.path.exists(path) else ""


def collect_cells(used, conns, n_load):
    """recorded.json's numbers: for every server, test and connection count the
    median of the counted reps, the noise bar, and whether the load generator
    was at 90% or more of its CPUs in ANY counted rep (req/s there may be oha's
    own throughput, not a server ceiling)."""
    cells = {}
    for fw in ORDER:
        for test, _ in TESTS:
            for c in conns:
                v = series(used, fw, test, c, "rps")
                if not v:
                    continue
                load = series(used, fw, test, c, "load_cores")
                cells.setdefault(fw, {}).setdefault(test, {})[c] = {
                    "rps": med(v), "noise": noise(v),
                    "cpu_us_per_req": med(series(used, fw, test, c, "cpu_us_per_req")),
                    "p50_ms": med(series(used, fw, test, c, "p50_ms")),
                    "p99_ms": med(series(used, fw, test, c, "p99_ms")),
                    "load_peak": max(load) if load else None,
                    "load_bound": bool(load and n_load and max(load) >= 0.9 * n_load)}
    # pkg/web divided by this server, from the unrounded medians: RESULTS.md
    # prints these, and a rerun from the rounded columns would drift in the
    # last digit.
    for fw, tests in cells.items():
        for test, by_conn in tests.items():
            for c, m in by_conn.items():
                bit = cells["bit"][test][c]
                m["bit_over_this"] = {f: bit[f] / m[f] if m[f] else None for f in RATIO_FIELDS}
    return cells


def collect(out_dir):
    rows = read_rows(os.path.join(out_dir, "results.csv"))
    if not rows:
        sys.exit("report.py: results.csv is empty")
    env = kv(os.path.join(out_dir, "env.txt"))
    ver = kv(os.path.join(out_dir, "versions.txt"))
    conns = sorted({r["conn"] for r in rows}, key=int)
    used, kept = counted(rows)
    server_cpus, load_cpus = pinning(out_dir)
    meta = {"date": env.get("date_utc", "?"), "commit": ver.get("bit", "?").split(" ")[0],
            "cpu": env.get("cpu", "?"), "cpu_cores": env.get("cpu_cores", "?"),
            "cpu_threads": env.get("cpu_threads", "?"),
            "kernel": env.get("kernel", "?").replace("Linux ", ""),
            "server_cpus": server_cpus, "load_cpus": load_cpus,
            "io": io_line(read_text(os.path.join(out_dir, "env.txt"))),
            "quiet": quiet_line(out_dir), "versions": versions_line(ver),
            "reps_counted": "%d-%d" % (kept[0], kept[-1]) if len(kept) > 1 else str(kept[0]),
            "reps_total": len({r["rep"] for r in rows}),
            "bad_reps": len(bad_reps(rows)), "conns": conns}
    return {"meta": meta, "cells": collect_cells(used, conns, cpu_count(load_cpus)),
            "verify": read_text(os.path.join(out_dir, "verify.txt")),
            "quiet_log": read_text(os.path.join(out_dir, "quiet.txt"))}


# ---- RESULTS.md: every table and the method --------------------------------

def headline(data):
    """pkg/web's req/s divided by each peer's, one row per test and c."""
    peers = [fw for fw in ORDER if fw != "bit"]
    out = ["| pkg/web / peer, req/s | pkg/web req/s | " +
           " | ".join(LABEL[fw] for fw in peers) + " |",
           "|---" + "|--:" * (len(peers) + 1) + "|"]
    for test, _ in TESTS:
        for c in data["meta"]["conns"]:
            bit = field(data, "bit", test, c, "rps")
            cells = ["%s c=%s" % (test, c), rps(bit) if bit is not None else "n/a"]
            cells += [ratio(bit, field(data, fw, test, c, "rps")) for fw in peers]
            out.append("| " + " | ".join(cells) + " |")
    return out


def table(data, test, c):
    head = ["Framework", "req/s", "req/min", "spread", "CPU us/req", "p50 ms",
            "p99 ms", "oha cores, peak", "pkg/web / this: req/s", "CPU", "p50",
            "p99"]
    out = ["| " + " | ".join(head) + " |",
           "|---" + "|--:" * (len(head) - 1) + "|"]
    for fw in ORDER:
        m = cell(data, fw, test, c)
        if not m:
            out.append("| %s |" % " | ".join([LABEL[fw]] + ["n/a"] * (len(head) - 1)))
            continue
        cells = [LABEL[fw], rps(m["rps"]) + (" *" if m["load_bound"] else ""),
                 rps(60.0 * m["rps"]), spread(m["noise"]), fmt(m["cpu_us_per_req"], "%.1f"),
                 fmt(m["p50_ms"], "%.2f"), fmt(m["p99_ms"], "%.2f"),
                 fmt(m["load_peak"], "%.2f")]
        cells += [fmt(m["bit_over_this"][f], "%.2fx") for f in RATIO_FIELDS]
        out.append("| " + " | ".join(cells) + " |")
    return out


def load_note(data, n_load):
    flagged = [1 for fw in data["cells"].values() for t in fw.values()
               for c in t.values() if c["load_bound"]]
    if not flagged:
        return ("> No row is load-bound: in every counted rep the load generator"
                " stayed under %.1f of its %d CPUs (`oha cores, peak`), so each"
                " req/s is the server's ceiling, not oha's." % (0.9 * n_load, n_load))
    return ("> `*` marks a LOAD-BOUND row: in at least one counted rep the load"
            " generator was busy on %.1f or more of its %d CPUs, so its req/s may"
            " be oha's own throughput, not a server ceiling. Compare those rows"
            " on `CPU us/req` instead." % (0.9 * n_load, n_load))


def scaling_note(data):
    """Name every framework whose throughput FALLS as concurrency rises. A
    table where one row's c=64 figure is a fifth of its c=1 figure reads like
    a transcription error unless the document says outright that it is not."""
    conns = data["meta"]["conns"]
    if len(conns) < 2:
        return ""
    lo, hi, hits = conns[0], conns[-1], []
    for fw in ORDER:
        for test, _ in TESTS:
            a, b = cell(data, fw, test, lo), cell(data, fw, test, hi)
            if not a or not b:
                continue
            # Only a fall LARGER than the two noise bars combined. Without
            # that test a 1% dip inside its own spread gets named here as a
            # scaling defect, which is the opposite of what this note is for.
            fall = (a["rps"] - b["rps"]) / a["rps"]
            if fall > (a["noise"] or 0.0) + (b["noise"] or 0.0):
                hits.append("%s on %s (%s at c=%s, %s at c=%s)" % (
                    LABEL[fw], test, rps(a["rps"]), lo, rps(b["rps"]), hi))
    if not hits:
        return ""
    return ("> Throughput FALLS with concurrency, which is a measurement and not"
            " a transcription error, for: %s. Every one of those reps answered"
            " 200 on every request; what changes is how long each took."
            % "; ".join(hits))


def hardware(m):
    """The machine by what it IS, never by what it is called: CPU model and
    topology, and how many hardware threads each side was given."""
    return ("%s, %s cores / %s threads, Linux %s. Each server ran on ONE"
            " physical core (%d hardware threads, CPUs %s); the load generator,"
            " oha, on %d other hardware threads (CPUs %s) sharing no core with"
            " it. Both sets were read back from `/proc/<pid>/status`"
            " `Cpus_allowed_list` of the running processes, not taken on trust"
            " from the flag"
            % (m["cpu"], m["cpu_cores"], m["cpu_threads"], m["kernel"],
               cpu_count(m["server_cpus"]), m["server_cpus"],
               cpu_count(m["load_cpus"]), m["load_cpus"]))


def method_notes(data):
    m = data["meta"]
    n_load = cpu_count(m["load_cpus"])
    reps = m["reps_counted"]
    notes = []
    if m["bad_reps"]:
        notes.append("> %d rep(s) answered a status other than 200 and are in the"
                     " results; see bench/out/results.csv." % m["bad_reps"])
    notes.append(
        "> Every figure is the median of reps %s of %d measured reps of 5 seconds"
        " each, after one 10-second warmup per server that is never counted. The"
        " first and last reps are measured but not counted: the first follows the"
        " warmup's decaying load, and dropping the last as well keeps the counted"
        " window in the middle of the run. `spread` is half the min-to-max range of the counted reps as a"
        " percent of their median. `c` is the number of concurrent keep-alive"
        " connections the load generator held open. `CPU us/req` is the server's"
        " own user plus system CPU time over the rep, divided by the requests it"
        " answered." % (reps, m["reps_total"]))
    notes.append(
        "> `pkg/web / this` divides pkg/web's median by that row's: above 1.00x is"
        " better for pkg/web on req/s, below 1.00x is better for pkg/web on CPU,"
        " p50 and p99.")
    notes.append(load_note(data, n_load))
    scaling = scaling_note(data)
    if scaling:
        notes.append(scaling)
    notes.append(
        "> Identical responses were PROVEN before anything was timed, not assumed:"
        " all six servers answer the same body byte for byte (sha256 of each body"
        " compared against pkg/web's), the same Content-Type, a Content-Length"
        " equal to that body, and no chunked framing. Keep-alive is on for all six"
        " and is checked the same way: two requests, one TCP connection. The run"
        " refuses to measure when either proof fails.")
    notes.append(
        "> Round-robin, not one framework at a time. Every rep visits all six"
        " servers, rotating which goes first, and all six stay up for the whole"
        " run. The box was checked quiet before every rep and after the last: no"
        " container running that the benchmark did not start, CPU pressure (PSI)"
        " under 1 over 10 s, and under 1%% of a 5 s window stalled. This run: %s."
        % m["quiet"])
    notes.append(
        "> Hardware: %s. The machine is a container with no CPU quota on a shared"
        " host, so read these figures as a comparison taken under one shared"
        " load, not as absolute throughput. During this run: %s."
        % (hardware(m), m["io"]))
    notes.append("> Versions: %s." % m["versions"])
    notes.append("> Generated by `pkg/web/bench/run.sh` from Bit `%s` on %s. Do not edit by"
                 " hand." % (m["commit"], m["date"]))
    return notes


def render_results(data):
    out = ["# pkg/web benchmark: full numbers and method", "",
           "The short version is in the [pkg/web README](../README.md#benchmarks)."
           " This file holds every table and the method behind it.", "",
           "## Benchmarks", "",
           "TechEmpower's test types 1 and 2, the same two every framework here",
           "already publishes a number for. Types 3 to 5 need a database-backed",
           "endpoint, and none of the six apps under `bench/apps/` has one, so there",
           "is no Bit side to compare yet.", "",
           "pkg/web's requests per second divided by each peer's: above 1.00x,",
           "pkg/web serves more.", ""]
    out += headline(data) + [""]
    for test, title in TESTS:
        for c in data["meta"]["conns"]:
            out += ["### %s, c=%s" % (title, c), ""] + table(data, test, c) + [""]
    out += method_notes(data)
    # The proofs travel with the numbers because out/ is generated and
    # gitignored: without them the committed artefact would assert identical
    # responses with nothing behind it.
    for title, key in (("Verification, exactly as it ran", "verify"),
                       ("Quiet checks, exactly as they ran", "quiet_log")):
        out += ["", "## " + title, "", "```", data[key].rstrip("\n"), "```"]
    return "\n".join(out) + "\n"


# ---- README block: ten seconds, no jargon -----------------------------------

# Words a reader without the method paragraph cannot parse, plus the load
# generator's flag vocabulary. The block is asserted free of them; RESULTS.md
# is where they live.
BANNED = re.compile(
    r"\b(cycles|instructions retired|rss|trimmed mean|quantis\w*|stw|"
    r"startup-corrected|oha|perf|p50|p99|psi|req/min|us/req)\b|\bc=\d|\u2014",
    re.IGNORECASE)

SAME = 0.05
SCENARIO = {"plaintext": "Plain text reply", "json": "JSON reply"}
SHORT = {"plaintext": "plaintext", "json": "JSON"}


def verdict(r):
    """pkg/web's req/s over a peer's, in the words the owner asked for."""
    if r is None:
        return "n/a"
    if abs(r - 1.0) <= SAME:
        return "about the same"
    return "%.1fx faster" % r if r > 1 else "%.1fx slower" % (1.0 / r)


def ratio_of(data, fw, test, c):
    a, b = field(data, "bit", test, c, "rps"), field(data, fw, test, c, "rps")
    return a / b if a is not None and b else None


def clients(c):
    return "1 client at a time" if int(c) == 1 else "%s clients at once" % c


def peers_of(data):
    return [fw for fw in ORDER if fw != "bit" and fw in data["cells"]]


def summary(data):
    peers, conns = peers_of(data), data["meta"]["conns"]
    rs = {(fw, t, c): ratio_of(data, fw, t, c)
          for fw in peers for t, _ in TESTS for c in conns}
    known = [r for r in rs.values() if r is not None]
    ahead = sum(1 for r in known if r > 1 + SAME)
    level = sum(1 for r in known if abs(r - 1) <= SAME)
    behind = len(known) - ahead - level
    text = ("pkg/web is faster than its rivals in %d of %d comparisons, about the"
            " same in %d, and slower in %d."
            % (ahead, len(known), level, behind))
    if not behind:
        return text + " It is not behind any of them in any test."
    # The rival that beats pkg/web by the widest margin, named with how close
    # pkg/web gets at the highest client count.
    worst = min((fw for fw in peers), key=lambda fw: min(
        r for (f, _, _), r in rs.items() if f == fw and r is not None))
    top = conns[-1]
    pct = ["%d%% of its %s rate" % (round(100 * rs[(worst, t, top)]), SHORT[t])
           for t, _ in TESTS if rs[(worst, t, top)] is not None]
    return text + (" The hardest rival is %s: with %s, pkg/web handles about %s."
                   % (LABEL[worst], clients(top), " and ".join(pct)))


def comparison_table(data):
    peers, conns = peers_of(data), data["meta"]["conns"]
    out = ["| pkg/web, requests per second | " +
           " | ".join("vs " + LABEL[fw] for fw in peers) + " |",
           "|---" + "|--:" * len(peers) + "|"]
    for test, _ in TESTS:
        for c in conns:
            row = ["%s, %s" % (SCENARIO[test], clients(c))]
            row += [verdict(ratio_of(data, fw, test, c)) for fw in peers]
            out.append("| " + " | ".join(row) + " |")
    return out


def latency_line(data):
    """A typical and a near-worst reply time at the highest client count, and
    who is quicker on both. Only said where the data exists."""
    c, test = data["meta"]["conns"][-1], TESTS[0][0]
    p50, p99 = (field(data, "bit", test, c, f) for f in ("p50_ms", "p99_ms"))
    if p50 is None or p99 is None:
        return None
    quicker = [LABEL[fw] for fw in peers_of(data)
               if (field(data, fw, test, c, "p50_ms") or p50) < p50
               and (field(data, fw, test, c, "p99_ms") or p99) < p99]
    who = ("only %s is quicker on both" % quicker[0] if len(quicker) == 1 else
           "no other server is quicker on both" if not quicker else
           "%d other servers are quicker on both" % len(quicker))
    return ("With %s on %s, a typical pkg/web reply takes %.2f ms and 99 in 100"
            " finish within %.2f ms; %s." % (clients(c), SHORT[test], p50, p99, who))


def reliability_line(data):
    if not data["verify"]:
        return None
    bad = data["meta"]["bad_reps"]
    if bad:
        return ("%d timed run(s) had a reply other than 200 OK; the details are in"
                " the full numbers." % bad)
    return ("Every server sent identical replies, checked byte for byte before"
            " timing, and every timed request got a 200 OK.")


def machine_line(data):
    m = data["meta"]
    return ("Measured on %s (%s cores) on %s, one core per server and a shared"
            " host, so compare the rows rather than reading them as absolute"
            " speeds." % (m["cpu"], m["cpu_cores"], m["date"][:10]))


def render_block(data):
    extra = [l for l in (latency_line(data), reliability_line(data)) if l]
    out = ["## Benchmarks", "", summary(data), ""] + comparison_table(data) + [""]
    out += ["- " + l for l in extra] + ["", machine_line(data), "",
            "Full numbers and method: [bench/RESULTS.md](bench/RESULTS.md)"]
    text = "\n".join(out) + "\n"
    hit = BANNED.search(text)
    if hit:
        sys.exit("report.py: the README block contains %r; plain words only,"
                 " the jargon belongs in bench/RESULTS.md" % hit.group(0))
    return text


def main():
    if len(sys.argv) != 3 or sys.argv[1] not in ("collect", "block", "results"):
        sys.exit("usage: report.py collect OUT_DIR | block RECORDED | results RECORDED")
    mode, path = sys.argv[1], sys.argv[2]
    if mode == "collect":
        sys.stdout.write(json.dumps(collect(path), indent=1, sort_keys=True) + "\n")
        return
    data = json.load(open(path))
    sys.stdout.write(render_block(data) if mode == "block" else render_results(data))


main()
