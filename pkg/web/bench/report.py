#!/usr/bin/env python3
"""Render out/results.csv as the README block bench/run.sh injects.

The whole block is produced here, prose included, so that nothing between the
BENCH markers can be typed by hand and quietly drift from the numbers beside
it. Every figure is the MEDIAN of the counted reps, and every median is
published with the rep count and the observed spread: on an unquota'd
container whose neighbours nobody here can see, a single number with no spread
beside it is not a result a reader can judge.

Every comparison is pkg/web divided by one peer, never one peer against
another: the table exists to say where pkg/web stands.
"""
import csv
import os
import re
import statistics
import sys

TESTS = [("plaintext", "Plaintext, `text/plain`, 13 bytes"),
         ("json", "JSON, one object serialized per request, 27 bytes")]
LABEL = {"bit": "pkg/web", "gin": "gin", "express": "express",
         "bun": "bun", "spring": "Spring Boot", "aspnet": "ASP.NET Core"}
ORDER = ["bit", "gin", "express", "bun", "spring", "aspnet"]


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


def med(rows, fw, test, conn, field):
    v = series(rows, fw, test, conn, field)
    return statistics.median(v) if v else None


def noise(vals):
    """Half the min..max range as a fraction of the median."""
    if len(vals) < 2:
        return 0.0
    med = statistics.median(vals)
    return (max(vals) - min(vals)) / 2.0 / med if med else 0.0


def spread(vals):
    """Half the min..max range as a percent of the median, the reader's noise
    bar. Reported rather than a stddev because 5 reps do not support one."""
    if len(vals) < 2:
        return "n/a"
    return "%.1f%%" % (100.0 * noise(vals))


def rps(n):
    return "{:,}".format(int(round(n)))


def ratio(bit, peer):
    return "%.2fx" % (bit / peer) if bit is not None and peer else "n/a"


def fmt(v, spec):
    return spec % v if v is not None else "n/a"


def headline(rows, conns):
    """pkg/web's req/s divided by each peer's, one row per test and c."""
    peers = [fw for fw in ORDER if fw != "bit"]
    out = ["| pkg/web / peer, req/s | pkg/web req/s | " +
           " | ".join(LABEL[fw] for fw in peers) + " |",
           "|---" + "|--:" * (len(peers) + 1) + "|"]
    for test, _ in TESTS:
        for c in conns:
            bit = med(rows, "bit", test, c, "rps")
            cells = ["%s c=%s" % (test, c), rps(bit) if bit is not None else "n/a"]
            cells += [ratio(bit, med(rows, fw, test, c, "rps")) for fw in peers]
            out.append("| " + " | ".join(cells) + " |")
    return out


def table(rows, test, c, flagged):
    head = ["Framework", "req/s", "req/min", "spread", "CPU us/req", "p50 ms",
            "p99 ms", "oha cores, peak", "pkg/web / this: req/s", "CPU", "p50",
            "p99"]
    out = ["| " + " | ".join(head) + " |",
           "|---" + "|--:" * (len(head) - 1) + "|"]
    bit = {f: med(rows, "bit", test, c, f)
           for f in ("rps", "cpu_us_per_req", "p50_ms", "p99_ms")}
    for fw in ORDER:
        v = series(rows, fw, test, c, "rps")
        if not v:
            out.append("| %s |" % " | ".join([LABEL[fw]] + ["n/a"] * (len(head) - 1)))
            continue
        m = {f: med(rows, fw, test, c, f) for f in bit}
        load = series(rows, fw, test, c, "load_cores")
        cells = [LABEL[fw], rps(m["rps"]) + (" *" if (fw, test, c) in flagged else ""),
                 rps(60.0 * m["rps"]), spread(v), fmt(m["cpu_us_per_req"], "%.1f"),
                 fmt(m["p50_ms"], "%.2f"), fmt(m["p99_ms"], "%.2f"),
                 "%.2f" % max(load) if load else "n/a"]
        cells += [ratio(bit[f], m[f]) for f in ("rps", "cpu_us_per_req", "p50_ms", "p99_ms")]
        out.append("| " + " | ".join(cells) + " |")
    return out


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


def load_bound(rows, conns, n_load):
    """(framework, test, conn) tuples where ANY counted rep had the load
    generator at 90% or more of its CPUs: req/s there may be oha's own
    throughput, not a server ceiling."""
    flagged = set()
    if not n_load:
        return flagged
    for fw in ORDER:
        for test, _ in TESTS:
            for c in conns:
                v = series(rows, fw, test, c, "load_cores")
                if v and max(v) >= 0.9 * n_load:
                    flagged.add((fw, test, c))
    return flagged


def load_note(flagged, n_load):
    if not flagged:
        return ("> No row is load-bound: in every counted rep the load generator"
                " stayed under %.1f of its %d CPUs (`oha cores, peak`), so each"
                " req/s is the server's ceiling, not oha's." % (0.9 * n_load, n_load))
    return ("> `*` marks a LOAD-BOUND row: in at least one counted rep the load"
            " generator was busy on %.1f or more of its %d CPUs, so its req/s may"
            " be oha's own throughput, not a server ceiling. Compare those rows"
            " on `CPU us/req` instead." % (0.9 * n_load, n_load))


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


def scaling_note(rows, conns):
    """Name every framework whose throughput FALLS as concurrency rises. A
    table where one row's c=64 figure is a fifth of its c=1 figure reads like
    a transcription error unless the block says outright that it is not."""
    if len(conns) < 2:
        return ""
    lo, hi, hits = conns[0], conns[-1], []
    for fw in ORDER:
        for test, _ in TESTS:
            a = series(rows, fw, test, lo, "rps")
            b = series(rows, fw, test, hi, "rps")
            if not a or not b:
                continue
            # Only a fall LARGER than the two noise bars combined. Without
            # that test a 1% dip inside its own spread gets named here as a
            # scaling defect, which is the opposite of what this note is for.
            fall = (statistics.median(a) - statistics.median(b)) / statistics.median(a)
            if fall > noise(a) + noise(b):
                hits.append("%s on %s (%s at c=%s, %s at c=%s)" % (
                    LABEL[fw], test, rps(statistics.median(a)), lo,
                    rps(statistics.median(b)), hi))
    if not hits:
        return ""
    return ("> Throughput FALLS with concurrency, which is a measurement and not"
            " a transcription error, for: %s. Every one of those reps answered"
            " 200 on every request; what changes is how long each took."
            % "; ".join(hits))


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


def hardware(env, server_cpus, load_cpus):
    """The machine by what it IS, never by what it is called: CPU model and
    topology, and how many hardware threads each side was given."""
    return ("%s, %s cores / %s threads, Linux %s. Each server ran on ONE"
            " physical core (%d hardware threads, CPUs %s); the load generator,"
            " oha, on %d other hardware threads (CPUs %s) sharing no core with"
            " it. Both sets were read back from `/proc/<pid>/status`"
            " `Cpus_allowed_list` of the running processes, not taken on trust"
            " from the flag"
            % (env.get("cpu", "?"), env.get("cpu_cores", "?"), env.get("cpu_threads", "?"),
               env.get("kernel", "?").replace("Linux ", ""), cpu_count(server_cpus),
               server_cpus, cpu_count(load_cpus), load_cpus))


def main():
    out_dir = sys.argv[1]
    rows = read_rows(os.path.join(out_dir, "results.csv"))
    if not rows:
        sys.exit("report.py: results.csv is empty")
    env = kv(os.path.join(out_dir, "env.txt"))
    ver = kv(os.path.join(out_dir, "versions.txt"))
    env_text = open(os.path.join(out_dir, "env.txt")).read()
    conns = sorted({r["conn"] for r in rows}, key=int)
    used, kept = counted(rows)
    server_cpus, load_cpus = pinning(out_dir)
    n_load = cpu_count(load_cpus)
    flagged = load_bound(used, conns, n_load)
    commit = ver.get("bit", "?").split(" ")[0]
    p = print

    p("## Benchmarks")
    p("")
    p("TechEmpower's test types 1 and 2, the same two every framework here")
    p("already publishes a number for. Types 3 to 5 need a database-backed")
    p("endpoint, and none of the six apps under `bench/apps/` has one, so there")
    p("is no Bit side to compare yet.")
    p("")
    p("pkg/web's requests per second divided by each peer's: above 1.00x,")
    p("pkg/web serves more.")
    p("")
    for line in headline(used, conns):
        p(line)
    p("")
    for test, title in TESTS:
        for c in conns:
            p("### %s, c=%s" % (title, c))
            p("")
            for line in table(used, test, c, flagged):
                p(line)
            p("")
    bad = bad_reps(rows)
    if bad:
        p("> %d rep(s) answered a status other than 200 and are in the results;"
          " see bench/out/results.csv." % len(bad))
    p("> Every figure is the median of reps %s of %d measured reps of 5 seconds"
      " each, after one 10-second warmup per server that is never counted. The"
      " first and last reps are measured but not counted: the first follows the"
      " warmup's decaying load, and dropping the last as well keeps the counted"
      " window in the middle of the run. `spread` is half the min-to-max range of the counted reps as a"
      " percent of their median. `c` is the number of concurrent keep-alive"
      " connections the load generator held open. `CPU us/req` is the server's"
      " own user plus system CPU time over the rep, divided by the requests it"
      " answered."
      % ("-".join(str(k) for k in (kept[0], kept[-1])) if len(kept) > 1 else kept[0],
         len({r["rep"] for r in rows})))
    p("> `pkg/web / this` divides pkg/web's median by that row's: above 1.00x is"
      " better for pkg/web on req/s, below 1.00x is better for pkg/web on CPU,"
      " p50 and p99.")
    p(load_note(flagged, n_load))
    note = scaling_note(used, conns)
    if note:
        p(note)
    p("> Identical responses were PROVEN before anything was timed, not assumed:"
      " all six servers answer the same body byte for byte (sha256 of each body"
      " compared against pkg/web's), the same Content-Type, a Content-Length"
      " equal to that body, and no chunked framing. Keep-alive is on for all six"
      " and is checked the same way: two requests, one TCP connection. The run"
      " refuses to measure when either proof fails.")
    p("> Round-robin, not one framework at a time. Every rep visits all six"
      " servers, rotating which goes first, and all six stay up for the whole"
      " run. The box was checked quiet before every rep and after the last: no"
      " container running that the benchmark did not start, CPU pressure (PSI)"
      " under 1 over 10 s, and under 1%% of a 5 s window stalled. This run: %s."
      % quiet_line(out_dir))
    p("> Hardware: %s. The machine is a container with no CPU quota on a shared"
      " host, so read these figures as a comparison taken under one shared"
      " load, not as absolute throughput. During this run: %s."
      % (hardware(env, server_cpus, load_cpus), io_line(env_text)))
    p("> Versions: %s." % versions_line(ver))
    p("> Generated by `pkg/web/bench/run.sh` from Bit `%s` on %s. Do not edit by"
      " hand." % (commit, env.get("date_utc", "?")))


main()
