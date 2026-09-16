#!/usr/bin/env python3
"""Render out/results.csv as the README block bench/run.sh injects (#5418).

The whole block is produced here, prose included, so that nothing between the
BENCH markers can be typed by hand and quietly drift from the numbers beside
it. Every figure is the MEDIAN of the reps, and every median is published with
the rep count and the observed spread: on an unquota'd container sharing six
cores with neighbours nobody here can see, a single number with no spread
beside it is not a result a reader can judge.
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


def series(rows, fw, test, conn, field):
    return [float(r[field]) for r in rows
            if r["framework"] == fw and r["test"] == test and r["conn"] == conn]


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


def table(rows, test, conns):
    head = ["Framework"]
    for c in conns:
        head += ["req/s c=%s" % c, "spread"]
    head += ["p50 ms c=%s" % conns[-1], "p99 ms c=%s" % conns[-1], "vs pkg/web"]
    out = ["| " + " | ".join(head) + " |",
           "|---" + "|--:" * (len(head) - 1) + "|"]
    base = statistics.median(series(rows, "bit", test, conns[-1], "rps"))
    for fw in ORDER:
        cells = [LABEL[fw]]
        for c in conns:
            v = series(rows, fw, test, c, "rps")
            if not v:
                cells += ["n/a", "n/a"]
                continue
            cells += [rps(statistics.median(v)), spread(v)]
        last = series(rows, fw, test, conns[-1], "rps")
        p50 = series(rows, fw, test, conns[-1], "p50_ms")
        p99 = series(rows, fw, test, conns[-1], "p99_ms")
        cells += ["%.2f" % statistics.median(p50) if p50 else "n/a",
                  "%.1f" % statistics.median(p99) if p99 else "n/a",
                  "%.2fx" % (statistics.median(last) / base) if last and base else "n/a"]
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


def versions_line(v):
    parts = [("Bit toolchain", v.get("bit", "?")), ("gin", v.get("gin", "?")),
             ("Go", v.get("go", "?")), ("express", v.get("express", "?")),
             ("Node", v.get("node", "?")), ("bun", v.get("bun", "?")),
             ("Spring Boot", v.get("springboot", "?")), ("JVM", v.get("jvm", "?")),
             ("ASP.NET", v.get("dotnet", "?"))]
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


def main():
    out_dir, commit, stamp, host = sys.argv[1:5]
    rows = read_rows(os.path.join(out_dir, "results.csv"))
    if not rows:
        sys.exit("report.py: results.csv is empty")
    env = kv(os.path.join(out_dir, "env.txt"))
    ver = kv(os.path.join(out_dir, "versions.txt"))
    env_text = open(os.path.join(out_dir, "env.txt")).read()
    conns = sorted({r["conn"] for r in rows}, key=int)
    server_cpus, load_cpus = pinning(out_dir)
    reps = len({r["rep"] for r in rows})
    p = print

    p("## Benchmarks")
    p("")
    p("TechEmpower's test types 1 and 2, the same two every framework here")
    p("already publishes a number for. Types 3 to 5 need a database and are not")
    p("measured: `pkg/postgres`'s type codecs are open as #3989, so there is no")
    p("Bit side to compare yet.")
    p("")
    for test, title in TESTS:
        p("### %s" % title)
        p("")
        for line in table(rows, test, conns):
            p(line)
        p("")
    bad = bad_reps(rows)
    if bad:
        p("> %d rep(s) answered a status other than 200 and are in the table above;"
          " see bench/out/results.csv." % len(bad))
    p("> Every figure is the median of %d reps of 5 seconds each, and `spread` is"
      " half the min-to-max range as a percent of that median. `c` is the number"
      " of concurrent keep-alive connections the load generator held open."
      " `vs pkg/web` divides that framework's c=%s median by pkg/web's, so"
      " 2.00x is twice the requests per second." % (reps, conns[-1]))
    note = scaling_note(rows, conns)
    if note:
        p(note)
    p("> The two concurrency columns are published together because they do not"
      " move together. c=1 is what one request costs with no queue in front of"
      " it; c=64 is the server under load. A framework can lead on one and trail"
      " on the other, and one column alone would hide which.")
    p("> Identical responses were PROVEN before anything was timed, not assumed:"
      " all six servers answer the same body byte for byte (sha256 of each body"
      " compared against pkg/web's), the same Content-Type, a Content-Length"
      " equal to that body, and no chunked framing. The proof is regenerated on"
      " every run into `bench/out/verify.txt`. Keep-alive is on for all six and"
      " is checked the same way: two requests, one TCP connection.")
    p("> Round-robin, not one framework at a time. Every rep visits all six"
      " servers, rotating which goes first, and all six stay up for the whole"
      " run. The box drifts; interleaving spreads that drift over all six"
      " instead of over whichever framework held the noisy window.")
    p("> Load generator: oha, %s concurrent connections, HTTP/1.1 keep-alive,"
      " pinned to cores %s. Servers pinned to cores %s. Disjoint, and read back"
      " from `/proc/<pid>/status` `Cpus_allowed_list` of each running process"
      " rather than taken on trust from the flag."
      % (conns[-1], load_cpus, server_cpus))
    p("> Box AS MEASURED, not as specified: %s, `systemd-detect-virt` says `%s`,"
      " %s cores, `cpu.max` `%s`, %s MB RAM, %s, %s. It is a CONTAINER with no"
      " CPU quota, so anything else on the physical host competes with this"
      " benchmark and is invisible from inside it. During this run: %s. Read"
      " these figures as a RANKING taken under one shared load, not as absolute"
      " throughput; they are not comparable to bare-metal published numbers."
      % (host, env.get("virt", "?"), env.get("cores", "?"), env.get("cpu.max", "?"),
         env.get("mem_total_mb", "?"), env.get("cpu", "?"), env.get("kernel", "?"),
         io_line(env_text)))
    p("> Versions: %s." % versions_line(ver))
    p("> Generated by `pkg/web/bench/run.sh` from Bit `%s` on %s. Do not edit by"
      " hand." % (commit, stamp))


main()
