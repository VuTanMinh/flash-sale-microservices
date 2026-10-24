"""Latency split for the archived overload runs (midterm review, finding I).

Reads the raw JTL (and, when archived, the stage-intervals CSV) of each run in
tests/evidence and prints, per run:
  - successful intake: elapsed of POST submissions answered 201;
  - refusals: elapsed of POST submissions answered 429 (gateway) and 503
    (application), separately;
  - stock decision: accepted -> decided (published_to_decided added to
    accepted_to_published), per order;
  - completion: accepted -> completed, per order.
Percentiles use the nearest-rank definition of scripts/extract-run-metrics.ps1.
Polling requests (label poll-*) are excluded. Nothing is clamped: a negative
interval is counted and printed, not set to zero.

    python report/figures/latency_split.py
"""
import csv
import math
import os

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
EVIDENCE = os.path.join(ROOT, "tests", "evidence")
RUNS = ["20261022T152931Z", "20261023T144923Z", "20261024T104902Z-ec2"]


def rank(sorted_values, p):
    n = len(sorted_values)
    if n == 0:
        return None
    r = min(max(int(math.ceil(p / 100.0 * n)), 1), n)
    return sorted_values[r - 1]


def summary(values):
    s = sorted(values)
    if not s:
        return "n=0"
    neg = sum(1 for v in s if v < 0)
    return "n=%d p50=%.0f p95=%.0f p99=%.0f max=%.0f negative=%d" % (
        len(s), rank(s, 50), rank(s, 95), rank(s, 99), s[-1], neg)


for run in RUNS:
    print("== %s" % run)
    jtl = os.path.join(EVIDENCE, run + "-overload-raw.jtl")
    by_code = {}
    with open(jtl, newline="", encoding="utf-8") as f:
        for row in csv.DictReader(f):
            if not row["label"].startswith("submit"):
                continue
            by_code.setdefault(row["responseCode"], []).append(float(row["elapsed"]))
    for code in sorted(by_code):
        print("  POST %s ms: %s" % (code, summary(by_code[code])))
    stages = os.path.join(EVIDENCE, run + "-overload-stage-intervals.csv")
    if not os.path.exists(stages):
        print("  stage intervals: not archived for this run")
        continue
    decided, completed = [], []
    with open(stages, newline="", encoding="utf-8") as f:
        for row in csv.DictReader(f):
            a, b = row["accepted_to_published_ms"], row["published_to_decided_ms"]
            if a and b:
                decided.append(float(a) + float(b))
            if row["accepted_to_completed_ms"]:
                completed.append(float(row["accepted_to_completed_ms"]))
    print("  accepted -> decided ms: %s" % summary(decided))
    print("  accepted -> completed ms: %s" % summary(completed))
