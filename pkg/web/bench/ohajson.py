#!/usr/bin/env python3
"""One oha -j report on stdin, one results.csv row on stdout (#5418).

Kept apart from remote.sh because the field names below are oha's, not ours:
when oha renames one, exactly one file changes and it is this one.

A rep that answered anything other than 200, or answered nothing, is not a
throughput measurement. It is written out with its non200 count rather than
dropped, so a reader of results.csv sees the bad rep instead of a short file
whose rows all look fine.

remote.sh measures two things oha cannot see and passes them in as the last
two arguments: the server's total CPU time over the rep (microseconds, all
threads) and the load generator's busy core count over the same window. Both
are turned into per-request or per-rep figures here, beside oha's own numbers,
rather than in remote.sh, for the same reason as everything else in this file:
one row, one place it is assembled.
"""
import json
import sys


def ms(seconds):
    return round(float(seconds) * 1000.0, 3)


def main():
    if len(sys.argv) != 7:
        sys.exit("usage: ohajson.py <rep> <framework> <test> <connections> "
                  "<server_cpu_us> <load_cores> < oha-json")
    rep, framework, test, conn, server_cpu_us, load_cores = sys.argv[1:7]
    try:
        r = json.load(sys.stdin)
    except json.JSONDecodeError as e:
        sys.exit("ohajson.py: %s/%s rep %s: oha did not emit JSON: %s" % (framework, test, rep, e))

    rps = float(r["summary"]["requestsPerSec"])
    pct = r.get("latencyPercentiles", {})
    p50 = ms(pct.get("p50", 0.0))
    p99 = ms(pct.get("p99", 0.0))
    codes = r.get("statusCodeDistribution", {})
    total = sum(int(v) for v in codes.values())
    non200 = total - int(codes.get("200", 0))
    # 0 when total is 0 (a rep that answered nothing): there is no per-request
    # figure to report, and the row is already flagged by non200/total.
    cpu_us_per_req = float(server_cpu_us) / total if total else 0.0
    print("%s,%s,%s,%s,%.1f,%s,%s,%d,%d,%.1f,%s" % (
        rep, framework, test, conn, rps, p50, p99, total, non200, cpu_us_per_req, load_cores))


main()
