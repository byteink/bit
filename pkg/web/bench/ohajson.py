#!/usr/bin/env python3
"""One oha -j report on stdin, one results.csv row on stdout (#5418).

Kept apart from remote.sh because the field names below are oha's, not ours:
when oha renames one, exactly one file changes and it is this one.

A rep that answered anything other than 200, or answered nothing, is not a
throughput measurement. It is written out with its non200 count rather than
dropped, so a reader of results.csv sees the bad rep instead of a short file
whose rows all look fine.
"""
import json
import sys


def ms(seconds):
    return round(float(seconds) * 1000.0, 3)


def main():
    if len(sys.argv) != 5:
        sys.exit("usage: ohajson.py <rep> <framework> <test> <connections> < oha-json")
    rep, framework, test, conn = sys.argv[1:5]
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
    print("%s,%s,%s,%s,%.1f,%s,%s,%d,%d" % (rep, framework, test, conn, rps, p50, p99, total, non200))


main()
