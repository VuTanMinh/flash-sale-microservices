"""Week 14 official runs: per-run metrics, per-cell summaries, LaTeX tables and figures.

    python analyze_official.py [<evidence-dir>]

<evidence-dir> defaults to tests/evidence/20261105T104832Z-official. The script
unpacks the copied bundles into a temporary folder and reads, for every run:
  manifest.json + official.json  (local manifests.tgz)    rate, accepted, drain, validator exit
  raw.jtl                         (w14-repN-jtl.tgz)        client latency and response codes
  summary.json, stage-intervals.csv, samples.csv, validator.log  (w14-repN-backend.tgz)
Outputs go to report/figures/official/: runs.csv (one row per run), cells.csv
(median and range per cell), tab-*.tex (included by report.tex) and fig-*.png/pdf.

Definitions (fixed before the analysis, see docs/week14-freeze.md section 8):
  percentiles are nearest-rank (rank ceil(p n)); a cell is the median of its 3 runs
  with the range in brackets; API latency is over 2xx submissions only; Drain is
  run-matrix's drain_seconds (the extractor's drain_time_s does not apply to matrix
  runs: the collector stops when the drain check passes, so no drained sample exists);
  completed throughput = completed orders / (60 s load + drain).
"""
import csv
import io
import json
import math
import os
import re
import statistics
import sys
import tarfile
import tempfile
from datetime import datetime

from collections import defaultdict

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt

here = os.path.dirname(os.path.abspath(__file__))
repo = os.path.abspath(os.path.join(here, "..", ".."))
ev = sys.argv[1] if len(sys.argv) > 1 else os.path.join(repo, "tests", "evidence", "20261105T104832Z-official")
out = os.path.join(here, "official")
os.makedirs(out, exist_ok=True)

plt.rcParams.update({"font.size": 11, "axes.titlesize": 12, "axes.labelsize": 11,
                     "xtick.labelsize": 10, "ytick.labelsize": 10, "legend.fontsize": 9,
                     "axes.spines.top": False, "axes.spines.right": False,
                     "axes.edgecolor": "#8a8a85", "axes.labelcolor": "#2b2b29",
                     "xtick.color": "#5c5b56", "ytick.color": "#5c5b56", "text.color": "#2b2b29"})
# categorical slots in fixed order (validated: CVD and normal-vision separation pass);
# every series also has its own marker, and every figure has a table beside it.
SERIES = [("C1", 1, "C1", "#2a78d6", "o"), ("C2", 1, "C2", "#eb6834", "s"), ("C3", 1, "C3", "#1baf7a", "^"),
          ("C4", 1, "C4, 1 cons.", "#eda100", "D"), ("C4", 2, "C4, 2 cons.", "#e87ba4", "v"),
          ("C4", 4, "C4, 4 cons.", "#008300", "P")]
GRID = "#e6e5e0"


def pct(vals, p):
    v = sorted(vals)
    if not v:
        return None
    return v[max(0, math.ceil(p / 100.0 * len(v)) - 1)]


def num(x):
    try:
        return float(x)
    except (TypeError, ValueError):
        return None


# ------------------------------------------------------------------ unpack
tmp = tempfile.mkdtemp(prefix="w14-analysis-")
for name in os.listdir(ev):
    if name.startswith("w14-rep") and name.endswith(".tgz"):
        sub = os.path.join(tmp, name.split("-")[1], "jtl" if name.endswith("-jtl.tgz") else "backend")
        os.makedirs(sub, exist_ok=True)
        with tarfile.open(os.path.join(ev, name)) as t:
            t.extractall(sub, filter="data")
with tarfile.open(os.path.join(ev, "manifests.tgz")) as t:
    t.extractall(os.path.join(tmp, "manifests"), filter="data")

# ------------------------------------------------------------------ per run
runs = []
for rep in ("rep1", "rep2", "rep3"):
    mdir = os.path.join(tmp, "manifests", rep)
    for rid in sorted(d for d in os.listdir(mdir) if os.path.isdir(os.path.join(mdir, d))):
        m = json.load(open(os.path.join(mdir, rid, "manifest.json"), encoding="utf-8-sig"))
        o = json.load(open(os.path.join(mdir, rid, "official.json"), encoding="utf-8-sig"))
        b = os.path.join(tmp, rep, "backend", rid)
        s = json.load(open(os.path.join(b, "summary.json"), encoding="utf-8-sig"))
        val = open(os.path.join(b, "validator.log"), encoding="utf-8-sig", errors="replace").read()
        r = dict(rep=o["official_repeat"], run_id=rid, config=m["config"], replicas=int(m["replicas"]),
                 rate=int(m["requested_per_s"]), status=m["status"], validator_exit=m["post"]["validator_exit"],
                 achieved=m["load"]["achieved_per_s"], submissions=m["load"]["submissions"],
                 drain_s=m["post"]["drain_seconds"], duration_s=m["duration_s"])
        # client side, from the raw JTL (submissions only; there are no polls in open mode)
        codes = defaultdict(int)
        ok = []
        with open(os.path.join(tmp, rep, "jtl", rid, "raw.jtl"), encoding="utf-8", newline="") as f:
            for row in csv.DictReader(f):
                if "submit" not in row["label"]:
                    continue
                c = row["responseCode"]
                codes[c] += 1
                if re.fullmatch(r"2\d\d", c):
                    ok.append(float(row["elapsed"]))
        n = sum(codes.values())
        n429 = codes.get("429", 0)
        n503 = codes.get("503", 0)
        n2xx = len(ok)
        r.update(jtl_submissions=n, jtl_2xx=n2xx, n429=n429, n503=n503, other=n - n2xx - n429 - n503,
                 api_p50=pct(ok, 50), api_p95=pct(ok, 95), api_p99=pct(ok, 99), api_max=max(ok) if ok else None,
                 overload_pct=100.0 * (n429 + n503) / n if n else None,
                 error_pct=100.0 * (n - n2xx - n429 - n503) / n if n else None)
        # correctness, from the validator log of this run
        checks = {}
        for line in val.splitlines():
            mm = re.match(r"^\S+\s+(0b|\d)\.\s.*?\s(PASS|FAIL|INCONCLUSIVE|NOT APPLICABLE|SETUP ERROR)\s", line + " ")
            if mm:
                checks[mm.group(1)] = mm.group(2)
        r["checks"] = checks
        r["all_hold"] = "RESULT: all checks hold" in val
        mm = re.search(r"2\. successful_reservations <= initial\s+PASS\s+(?:Redis reservations (\d+).*?successful orders (\d+)|(\d+) <= )", val)
        sold = None
        if mm:
            sold = int(mm.group(2) or mm.group(3))
        r["sold"] = sold
        db = s.get("database") if isinstance(s.get("database"), dict) else {}
        col = s.get("collector", {})
        if r["config"] == "C1":
            r.update(accepted=n2xx, completed=None, reserved_pct=100.0 * (sold or 0) / n2xx if n2xx else None,
                     stock_rej_pct=100.0 * (n2xx - (sold or 0)) / n2xx if n2xx else None,
                     dec_p50=r["api_p50"], dec_p95=r["api_p95"], dec_p99=r["api_p99"])
        else:
            sr = db.get("stock_rates_pct", {})
            r.update(accepted=db.get("accepted_count"), completed=db.get("completed_count"), pending=db.get("pending_count"),
                     reserved_pct=sr.get("reserved"), stock_rej_pct=sr.get("rejected"))
            dec, comp = [], []
            with open(os.path.join(b, "stage-intervals.csv"), encoding="utf-8-sig", newline="") as f:
                for row in csv.DictReader(f):
                    a, p = num(row["accepted_to_published_ms"]), num(row["published_to_decided_ms"])
                    if a is not None and p is not None:
                        dec.append(a + p)
                    c = num(row["accepted_to_completed_ms"])
                    if c is not None:
                        comp.append(c)
            r.update(dec_p50=pct(dec, 50), dec_p95=pct(dec, 95), dec_p99=pct(dec, 99),
                     comp_p50=pct(comp, 50), comp_p95=pct(comp, 95), comp_p99=pct(comp, 99))
            for st in ("accepted_to_published", "published_to_decided", "decided_to_applied", "applied_to_completed", "accepted_to_completed"):
                x = db.get("stages_ms", {}).get(st, {})
                r[st + "_p50"], r[st + "_p95"], r[st + "_p99"] = x.get("p50"), x.get("p95"), x.get("p99")
                r[st + "_neg"] = x.get("negative_count")
        r["completed_per_s"] = (r["completed"] / (r["duration_s"] + r["drain_s"])) if r.get("completed") else None
        k = col.get("counters", {})
        r.update(retries=num(k.get("retries")), duplicates=num(k.get("duplicates")),
                 dead_lettered=num(k.get("dead_lettered")), reconciliation=num(k.get("reconciliation")),
                 cpu_mean=num(col.get("host_cpu_percent", {}).get("mean")), cpu_peak=num(col.get("host_cpu_percent", {}).get("peak")),
                 mem_mean_gb=(num(col.get("host_memory_used_bytes", {}).get("mean")) or 0) / 1e9,
                 mem_peak_gb=(num(col.get("host_memory_used_bytes", {}).get("peak")) or 0) / 1e9,
                 db_conn_mean=num(col.get("db_connections", {}).get("mean")), db_conn_peak=num(col.get("db_connections", {}).get("peak")),
                 redis_ms=(num(col.get("redis_mean_latency_us", {}).get("value")) or 0) / 1000.0 if num(col.get("redis_mean_latency_us", {}).get("value")) is not None else None,
                 peak_queue=num(col.get("peak_queue_depth", {}).get("per_queue", {}).get("OrderPlaced")),
                 oldest_s=num(col.get("peak_oldest_age_seconds", {}).get("per_queue", {}).get("OrderPlaced")))
        br = col.get("broker_rates") or {}
        for key in ("publish", "deliver_get", "ack"):
            v = br.get(key) if isinstance(br, dict) else None
            r["broker_" + key] = num(v.get("mean")) if isinstance(v, dict) else num(v)
        # from the samples: Outbox backlog (summed over services and replicas), Worker dead letters
        ob = defaultdict(float)
        wdl = []
        load_cpu = []
        series = defaultdict(dict)
        with open(os.path.join(b, "samples.csv"), encoding="utf-8-sig", newline="") as f:
            for row in csv.DictReader(f):
                v = num(row["value"])
                if v is None:
                    continue
                t = row["utc_time"]
                if row["name"] == "flashsale_outbox_unpublished":
                    ob[t] += v
                elif row["name"] == "flashsale_process_worker_dead_lettered_total":
                    wdl.append(v)
                elif row["name"] in ("messages_ready", "messages_unacknowledged") and row["labels"].startswith("queue="):
                    q = row["labels"][6:]
                    if q == "OrderPlaced":
                        series["orderplaced"][t] = series["orderplaced"].get(t, 0) + v
                    if not q.endswith(".dlq") and ".retry." not in q:
                        series["mainqueues"][t] = series["mainqueues"].get(t, 0) + v
                elif row["name"] == "flashsale_orders_accepted_total":
                    series["acc"][t] = series["acc"].get(t, 0) + v
                elif row["name"] == "flashsale_orders_outcome_total" and re.search(r'outcome="?(Completed|Rejected)"?(;|$)', row["labels"]):
                    series["done"][t] = series["done"].get(t, 0) + v
                elif row["name"] == "cpu_percent":
                    series["cpu"][t] = v
                    tt = datetime.fromisoformat(t.replace("Z", "+00:00")).timestamp() * 1000
                    if m["load"]["first_ms"] <= tt <= m["load"]["last_ms"]:
                        load_cpu.append(v)
        r["outbox_peak"] = max(ob.values()) if ob else None
        r["cpu_load_mean"] = statistics.mean(load_cpu) if load_cpu else None
        r["accepted_per_s"] = (r["accepted"] / r["duration_s"]) if r.get("accepted") else None
        r["worker_dead_lettered"] = (max(wdl) - min(wdl)) if wdl else None
        r["_outbox"] = dict(ob)
        r["_series"] = series
        # after the load: every sample as seconds since the last submission; unfinished
        # orders = accepted - (completed + rejected), both counted from the run's first sample
        end = m["load"]["last_ms"] / 1000.0
        ts = sorted(set(series["acc"]) & set(series["done"]))
        rec = []
        if ts:
            a0, d0 = series["acc"][ts[0]], series["done"][ts[0]]
            for t in sorted(set(ts) | set(ob) | set(series["mainqueues"])):
                x = datetime.fromisoformat(t.replace("Z", "+00:00")).timestamp() - end
                unf = (series["acc"][t] - a0) - (series["done"][t] - d0) if t in series["acc"] and t in series["done"] else None
                rec.append((x, unf, ob.get(t), series["mainqueues"].get(t)))
        r["_recovery"] = rec
        at_end = [p for p in rec if p[0] <= 0]
        last = at_end[-1] if at_end else (None, None, None, None)
        r["unfinished_at_end"], r["outbox_at_end"], r["queues_at_end"] = last[1], last[2], last[3]
        after = [p for p in rec if p[0] > 0]
        r["queues_peak_after"] = max((p[3] for p in after if p[3] is not None), default=None)
        # seconds after the load until unfinished orders first fall to 1 % of their count at the end
        r["backlog_1pct_s"] = None
        if r["unfinished_at_end"]:
            hit = [p[0] for p in after if p[1] is not None and p[1] <= 0.01 * r["unfinished_at_end"]]
            r["backlog_1pct_s"] = min(hit) if hit else None
        r["waited_reconciliation"] = bool((r.get("dead_lettered") or 0) > 0 and r["drain_s"] > 200)
        r["_jtl"] = os.path.join(tmp, rep, "jtl", rid, "raw.jtl")
        runs.append(r)

assert len(runs) == 66, len(runs)

# ------------------------------------------------------------------ per cell
FIELDS = ["achieved", "accepted", "completed", "completed_per_s", "drain_s", "api_p50", "api_p95", "api_p99", "api_max",
          "dec_p50", "dec_p95", "dec_p99", "comp_p50", "comp_p95", "comp_p99", "overload_pct", "error_pct",
          "reserved_pct", "stock_rej_pct", "retries", "duplicates", "dead_lettered", "worker_dead_lettered", "reconciliation",
          "outbox_peak", "peak_queue", "oldest_s", "cpu_mean", "cpu_load_mean", "accepted_per_s", "cpu_peak", "mem_mean_gb", "mem_peak_gb",
          "unfinished_at_end", "outbox_at_end", "queues_at_end", "queues_peak_after", "backlog_1pct_s",
          "db_conn_mean", "db_conn_peak", "redis_ms"] + \
         [f"{st}_{q}" for st in ("accepted_to_published", "published_to_decided", "decided_to_applied", "applied_to_completed", "accepted_to_completed") for q in ("p50", "p95", "p99", "neg")]
cells = defaultdict(list)
for r in runs:
    cells[(r["config"], r["replicas"], r["rate"])].append(r)
cellrows = {}
for key, rs in cells.items():
    c = {"n": len(rs)}
    for f in FIELDS:
        vals = [x.get(f) for x in rs if x.get(f) is not None]
        c[f] = (statistics.median(vals), min(vals), max(vals)) if vals else None
    cellrows[key] = c

order = [(cfg, n, rate) for cfg, n, _, _, _ in SERIES for rate in (50, 100, 200, 400) if (cfg, n, rate) in cells]
with open(os.path.join(out, "runs.csv"), "w", encoding="utf-8", newline="") as f:
    cols = ["rep", "run_id", "config", "replicas", "rate", "status", "validator_exit", "all_hold", "sold", "submissions", "jtl_2xx", "n429", "n503", "other"] + FIELDS
    w = csv.writer(f)
    w.writerow(cols)
    for r in sorted(runs, key=lambda x: (order.index((x["config"], x["replicas"], x["rate"])), x["rep"])):
        w.writerow([r.get(c) for c in cols])
with open(os.path.join(out, "cells.csv"), "w", encoding="utf-8", newline="") as f:
    w = csv.writer(f)
    w.writerow(["config", "replicas", "rate", "runs"] + [f"{x}_{y}" for x in FIELDS for y in ("median", "min", "max")])
    for key in order:
        c = cellrows[key]
        w.writerow(list(key) + [c["n"]] + [v for x in FIELDS for v in (c[x] if c[x] else (None, None, None))])


# ------------------------------------------------------------------ LaTeX tables
def label(cfg, n):
    return cfg if cfg != "C4" else f"C4, {n} cons."


def fmt(c, f, dec=0, rng=True, scale=1.0):
    v = c.get(f)
    if v is None:
        return "n/a"
    med, lo, hi = (x / scale for x in v)
    s = f"{med:,.{dec}f}"
    if rng and (round(lo, dec) != round(hi, dec)):
        s += f" ({lo:,.{dec}f}--{hi:,.{dec}f})"
    return s


def write_table(name, header, colspec, rowfn, keys=order):
    lines = [r"\begin{tabular}{" + colspec + "}", r"\toprule", header + r" \\", r"\midrule"]
    prev = None
    for key in keys:
        if prev and (key[0], key[1]) != (prev[0], prev[1]):
            lines.append(r"\addlinespace[2pt]")
        lines.append(rowfn(key, cellrows[key]) + r" \\")
        prev = key
    lines += [r"\bottomrule", r"\end{tabular}"]
    open(os.path.join(out, name), "w", encoding="utf-8", newline="\n").write("\n".join(lines) + "\n")


def cellname(key):
    return f"{label(key[0], key[1])} & {key[2]}"


write_table("tab-api.tex", r"Config. & Rate & Achieved (/s) & p50 & p95 & p99", "llrrrr",
            lambda k, c: f"{cellname(k)} & {fmt(c, 'achieved', 1, False)} & {fmt(c, 'api_p50')} & {fmt(c, 'api_p95')} & {fmt(c, 'api_p99')}")
write_table("tab-decision.tex", r"Config. & Rate & \multicolumn{2}{c}{Stock decision} & \multicolumn{2}{c}{Completion} \\ \cmidrule(lr){3-4}\cmidrule(lr){5-6}" + "\n" + r" & & p50 & p95 & p50 & p95", "llrrrr",
            lambda k, c: f"{cellname(k)} & {fmt(c, 'dec_p50', 3 if k[0] == 'C1' else 1, True, 1000)} & {fmt(c, 'dec_p95', 3 if k[0] == 'C1' else 1, True, 1000)} & {fmt(c, 'comp_p50', 1, True, 1000)} & {fmt(c, 'comp_p95', 1, True, 1000)}")
write_table("tab-throughput.tex", r"Config. & Rate & Achieved & Accepted & Completed/s & Overload rej. \%", "llrrrr",
            lambda k, c: f"{cellname(k)} & {fmt(c, 'achieved', 1, False)} & {fmt(c, 'accepted')} & {fmt(c, 'completed_per_s', 1)} & {fmt(c, 'overload_pct', 1)}")
# the two columns dropped from the table must stay constant, or the caption would be wrong
assert all(r.get("reserved_pct") == 100.0 for r in runs), "reserved share is no longer 100 % in every run"
assert all(r.get("error_pct") == 0.0 for r in runs), "some run had errors"
write_table("tab-overload.tex", r"Config. & Rate & Peak queue & Oldest (s) & Outbox peak & Drain (s)", "llrrrr",
            lambda k, c: f"{cellname(k)} & {fmt(c, 'peak_queue')} & {fmt(c, 'oldest_s')} & {fmt(c, 'outbox_peak')} & {fmt(c, 'drain_s')}",
            keys=[k for k in order if k[0] != "C1"])
write_table("tab-reliability.tex", r"Config. & Rate & Retries & Duplicates & Dead-lettered & Reconciliation", "llrrrr",
            lambda k, c: f"{cellname(k)} & {fmt(c, 'retries')} & {fmt(c, 'duplicates')} & {fmt(c, 'dead_lettered')} & {fmt(c, 'reconciliation')}",
            keys=[k for k in order if k[0] != "C1"])
write_table("tab-resources.tex", r"Config. & Rate & CPU in load \% & CPU peak \% & RAM (GB) & DB conns & Redis (ms)", "llrrrrr",
            lambda k, c: f"{cellname(k)} & {fmt(c, 'cpu_load_mean')} & {fmt(c, 'cpu_peak', 0, False)} & {fmt(c, 'mem_peak_gb', 1, False)} & {fmt(c, 'db_conn_peak', 0, False)} & {fmt(c, 'redis_ms', 2, False) if k[0] != 'C1' else 'n/a'}")
stage_keys = [k for k in order if k[0] == "C2"]
lines = [r"\begin{tabular}{lrrrr}", r"\toprule", r"Stage & Rate & p50 & p95 & Negative \\", r"\midrule"]
names = [("accepted_to_published", r"Accepted $\to$ published"), ("published_to_decided", r"Published $\to$ decided"),
         ("decided_to_applied", r"Decided $\to$ applied"), ("applied_to_completed", r"Applied $\to$ completed"),
         ("accepted_to_completed", r"Accepted $\to$ completed")]
for st, nm in names:
    for k in stage_keys:
        c = cellrows[k]
        lines.append(f"{nm} & {k[2]} & {fmt(c, st + '_p50', 1, True, 1000)} & {fmt(c, st + '_p95', 1, True, 1000)} & {fmt(c, st + '_neg', 0, False)} \\\\")
    if st != "accepted_to_completed":
        lines.append(r"\addlinespace[2pt]")
lines += [r"\bottomrule", r"\end{tabular}"]
open(os.path.join(out, "tab-stages.tex"), "w", encoding="utf-8", newline="\n").write("\n".join(lines) + "\n")
# correctness: runs that passed each validator check, per configuration
ck = [("0b", "0b. Run isolation (no data from before the run)"), ("1", "1. Available inventory $\\ge 0$"),
      ("2", "2. Successful reservations $\\le$ initial inventory"), ("3", "3. One reservation per order"),
      ("4", "4. A duplicate message never deducts twice"), ("5", "5. Accepted orders terminal (accounting)"),
      ("6", "6. Queue bound off (C1, C2 only)"), ("7", "7. Status history complete")]
groups = [("C1", lambda r: r["config"] == "C1"), ("C2", lambda r: r["config"] == "C2"), ("C3", lambda r: r["config"] == "C3"),
          ("C4", lambda r: r["config"] == "C4")]
lines = [r"\begin{tabular}{p{6.6cm}cccc}", r"\toprule", r"Check & C1 & C2 & C3 & C4 \\", r"\midrule"]
for cid, nm in ck:
    cellsx = []
    for g, fn in groups:
        rs = [r for r in runs if fn(r)]
        st = [r["checks"].get(cid) for r in rs]
        if all(x in (None, "NOT APPLICABLE") for x in st):
            cellsx.append("n/a")
        else:
            cellsx.append(f"{sum(1 for x in st if x == 'PASS')}/{len(rs)}")
    lines.append(f"{nm} & " + " & ".join(cellsx) + r" \\")
lines.append(r"\midrule")
cellsx = []
for g, fn in groups:
    rs = [r for r in runs if fn(r)]
    cellsx.append(f"{sum(1 for r in rs if r['all_hold'])}/{len(rs)}")
lines.append(r"All checks hold (validator exit 0) & " + " & ".join(cellsx) + r" \\")
over = []
for g, fn in groups:
    rs = [r for r in runs if fn(r)]
    over.append(str(max(max(0, (r["sold"] or 0) - 100000) for r in rs)))
lines.append(r"Units over-sold (worst run) & " + " & ".join(over) + r" \\")
lines += [r"\bottomrule", r"\end{tabular}"]
open(os.path.join(out, "tab-correctness.tex"), "w", encoding="utf-8", newline="\n").write("\n".join(lines) + "\n")


# ------------------------------------------------------------------ figures
def save(fig, name):
    fig.savefig(os.path.join(out, name + ".png"), dpi=200, bbox_inches="tight")
    fig.savefig(os.path.join(out, name + ".pdf"), bbox_inches="tight")
    plt.close(fig)


def style(ax):
    ax.grid(axis="y", color=GRID, linewidth=0.8)
    ax.set_axisbelow(True)


rates = [50, 100, 200, 400]
# 1. API latency p95 per cell: each run a point, the median a line (log scale: values span 10 ms to seconds)
fig, axes = plt.subplots(1, 2, figsize=(10, 4), sharey=True)
for ax, (fld, title) in zip(axes, [("api_p50", "API latency p50"), ("api_p95", "API latency p95")]):
    for i, (cfg, n, lab, col, mk) in enumerate(SERIES):
        xs, meds = [], []
        for rate in rates:
            rs = cells.get((cfg, n, rate))
            if not rs:
                continue
            x = math.log2(rate) + (i - 2.5) * 0.04
            for r in rs:
                ax.scatter(x, r[fld], s=16, color=col, marker=mk, alpha=0.55, linewidths=0, zorder=3)
            xs.append(x)
            meds.append(statistics.median(r[fld] for r in rs))
        ax.plot(xs, meds, color=col, linewidth=2, marker=mk, markersize=7, label=lab, zorder=4,
                markeredgecolor="white", markeredgewidth=1)
    ax.set_yscale("log")
    ax.set_xticks([math.log2(r) for r in rates], [str(r) for r in rates])
    ax.set_xlabel("Requested rate (req/s)")
    ax.set_title(title)
    style(ax)
axes[0].set_ylabel("ms (log scale)")
handles, labels = axes[0].get_legend_handles_labels()
fig.legend(handles, labels, loc="lower center", ncol=6, frameon=False, bbox_to_anchor=(0.5, -0.06))
save(fig, "fig-latency")

# 2. C4 replicas: completed throughput, drain, host CPU against the replica count
fig, axes = plt.subplots(1, 3, figsize=(11, 3.6))
rate_cols = {50: "#2a78d6", 100: "#eb6834", 200: "#1baf7a", 400: "#eda100"}
rate_mk = {50: "o", 100: "s", 200: "^", 400: "D"}
for ax, (fld, title, unit) in zip(axes, [("accepted_per_s", "Accepted orders", "orders/s"),
                                         ("comp_p95", "Completion latency p95", "s"), ("cpu_load_mean", "Host CPU during the load", "%")]):
    for rate in rates:
        xs, meds = [], []
        for n in (1, 2, 4):
            rs = cells.get(("C4", n, rate), [])
            vals = [r[fld] / (1000.0 if fld == "comp_p95" else 1.0) for r in rs if r.get(fld) is not None]
            if not vals:
                continue
            for v in vals:
                ax.scatter(n, v, s=14, color=rate_cols[rate], marker=rate_mk[rate], alpha=0.5, linewidths=0, zorder=3)
            xs.append(n)
            meds.append(statistics.median(vals))
        ax.plot(xs, meds, color=rate_cols[rate], marker=rate_mk[rate], linewidth=2, markersize=7, label=f"{rate}/s",
                markeredgecolor="white", markeredgewidth=1, zorder=4)
    ax.set_xticks([1, 2, 4])
    ax.set_xlabel("Inventory consumers")
    ax.set_ylabel(unit)
    ax.set_title(title)
    style(ax)
handles, labels = axes[0].get_legend_handles_labels()
fig.legend(handles, labels, title="Requested rate", loc="center right", frameon=False, bbox_to_anchor=(1.08, 0.5))
save(fig, "fig-replicas")


# 3. one run over time per panel: C2 at 200/s and C3 at 400/s, repeat 1
def per_second(jtl):
    acc, ref = defaultdict(int), defaultdict(int)
    t0 = None
    with open(jtl, encoding="utf-8", newline="") as f:
        for row in csv.DictReader(f):
            if "submit" not in row["label"]:
                continue
            ts = int(row["timeStamp"]) + int(row["elapsed"])
            t0 = ts if t0 is None else min(t0, ts)
            sec = ts // 1000
            if re.fullmatch(r"2\d\d", row["responseCode"]):
                acc[sec] += 1
            else:
                ref[sec] += 1
    return acc, ref





def to_epoch(t):
    return datetime.fromisoformat(t.replace("Z", "+00:00")).timestamp()


picks = [("C2", 1, 200), ("C3", 1, 400)]
fig, axes = plt.subplots(2, 2, figsize=(11, 6), sharex="col")
for col_i, key in enumerate(picks):
    r = [x for x in cells[key] if x["rep"] == 1][0]
    acc, ref = per_second(r["_jtl"])
    start = min(list(acc) + list(ref))
    ax = axes[0][col_i]
    xs = sorted(set(acc) | set(ref))
    ax.plot([x - start for x in xs], [acc.get(x, 0) for x in xs], color="#2a78d6", linewidth=1.6, label="Accepted (2xx)")
    ax.plot([x - start for x in xs], [ref.get(x, 0) for x in xs], color="#eb6834", linewidth=1.6, label="Refused (429/503)")
    ax.set_title(f"{label(key[0], key[1])} at {key[2]}/s, repeat 1: responses per second")
    ax.set_ylabel("per second")
    style(ax)
    ax.legend(frameon=False, loc="upper right")
    ax = axes[1][col_i]
    q = r["_series"].get("orderplaced", {})
    ts = sorted(q)
    ax.plot([to_epoch(t) - start for t in ts], [q[t] for t in ts], color="#1baf7a", linewidth=1.6, label="OrderPlaced queue")
    ob = r["_outbox"]
    ts2 = sorted(ob)
    ax.plot([to_epoch(t) - start for t in ts2], [ob[t] for t in ts2], color="#e87ba4", linewidth=1.6, label="Outbox unpublished")
    ax.axvline(r["duration_s"], color="#8a8a85", linewidth=1, linestyle="--")
    ax.text(r["duration_s"], ax.get_ylim()[1] * 0.95, " load ends", color="#5c5b56", fontsize=9, va="top")
    ax.set_xlabel("seconds from the first submission")
    ax.set_ylabel("messages / rows")
    style(ax)
    ax.legend(frameon=False, loc="upper right")
save(fig, "fig-timeline")
# 4. recovery after overload: the 200 and 400/s cells of C2 to C4 (every one offers
#    more than the backend completes, about 50-66 orders/s). Time to stable is the
#    matrix drain (the freeze's Drain definition). A run whose orders wait for the
#    300 s reconciliation of Confirmed/Processing orders is marked.
rec_keys = [k for k in order if k[0] != "C1" and k[2] in (200, 400)]
lines = [r"\begin{tabular}{llrrrrrl}", r"\toprule",
         r"Config. & Rate & Unfinished & Outbox & Queues & 99\,\% done (s) & Stable (s) & Reconc. \\", r"\midrule"]
prev = None
for k in rec_keys:
    if prev and (k[0], k[1]) != (prev[0], prev[1]):
        lines.append(r"\addlinespace[2pt]")
    c = cellrows[k]
    w = sum(1 for r in cells[k] if r["waited_reconciliation"])
    lines.append(f"{cellname(k)} & {fmt(c, 'unfinished_at_end')} & {fmt(c, 'outbox_at_end')} & {fmt(c, 'queues_peak_after')} & {fmt(c, 'backlog_1pct_s')} & {fmt(c, 'drain_s')} & {w}/{len(cells[k])} \\\\")
    prev = k
lines += [r"\bottomrule", r"\end{tabular}"]
open(os.path.join(out, "tab-recovery.tex"), "w", encoding="utf-8", newline="\n").write("\n".join(lines) + "\n")

panels = [("unfinished", 1, "Unfinished orders"), ("outbox", 2, "Unpublished Outbox rows"), ("queues", 3, "Messages in main queues")]
fig, axes = plt.subplots(len(rec_keys), 3, figsize=(7.4, 1.18 * len(rec_keys) + 0.8), sharex=True, sharey="col")
rep_cols = {1: "#2a78d6", 2: "#eb6834", 3: "#1baf7a"}
for j, k in enumerate(rec_keys):
    for r in sorted(cells[k], key=lambda x: x["rep"]):
        pts = [p for p in r["_recovery"] if -5 <= p[0] <= 360]
        for i, (_, idx, _) in enumerate(panels):
            xs = [p[0] for p in pts if p[idx] is not None]
            ys = [p[idx] for p in pts if p[idx] is not None]
            axes[j][i].plot(xs, ys, color=rep_cols[r["rep"]], linewidth=1.2,
                            linestyle="--" if r["waited_reconciliation"] else "-")
    axes[j][0].set_ylabel(f"{label(k[0], k[1])}\n{k[2]}/s", fontsize=8, rotation=0, ha="right", va="center")
    for i in range(3):
        style(axes[j][i])
        axes[j][i].axvline(300, color="#c3c2b7", linewidth=0.8, linestyle=":")
        axes[j][i].tick_params(labelsize=7)
for i, (_, _, nm) in enumerate(panels):
    axes[0][i].set_title(nm, fontsize=9)
    axes[-1][i].set_xlabel("seconds after the load", fontsize=8)
from matplotlib.lines import Line2D
handles = [Line2D([0], [0], color=rep_cols[n], linewidth=1.6, label=f"repeat {n}") for n in (1, 2, 3)] + \
          [Line2D([0], [0], color="#5c5b56", linewidth=1.6, linestyle="--", label="waited for the 300 s reconciliation"),
           Line2D([0], [0], color="#c3c2b7", linewidth=1, linestyle=":", label="300 s after the load")]
fig.legend(handles=handles, loc="lower center", ncol=3, frameon=False, bbox_to_anchor=(0.5, -0.01), fontsize=8)
fig.tight_layout(rect=(0, 0.045, 1, 1))
save(fig, "fig-recovery")
print("runs", len(runs), "cells", len(cellrows), "->", out)
