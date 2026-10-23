"""Week 12 report figures from saved evidence.

    python plot_week12.py <run-dir> [<figure-name> [<title>]]

<figure-name>.png/.pdf : per-second outcomes of a TP-L04 overload run (201 / 429 / 503)
                         with the Order Outbox backlog and the Process Worker queue
                         (default name overload-timeline).
verification-overview.png/.pdf : PASS/FAIL counts read from each runtime verifier's
                         latest log in tests/evidence (never typed in by hand).
"""
import glob
import io
import os
import csv
import sys
from collections import defaultdict
from datetime import datetime, timezone

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt

# large type so the charts stay readable at full text width; PDF copies are vector
plt.rcParams.update({"font.size": 13, "axes.titlesize": 14, "axes.labelsize": 13,
                     "xtick.labelsize": 12, "ytick.labelsize": 12, "legend.fontsize": 11})


def save(fig, name):
    fig.savefig(f"{here}/{name}.png", dpi=300)
    fig.savefig(f"{here}/{name}.pdf")

run_dir = sys.argv[1]
fig_name = sys.argv[2] if len(sys.argv) > 2 else "overload-timeline"
fig_title = sys.argv[3] if len(sys.argv) > 3 else "TP-L04 overload, drain and recovery (local run, all C3 limits on)"
here = __file__.rsplit("\\", 1)[0] if "\\" in __file__ else __file__.rsplit("/", 1)[0]

# ---- overload timeline -------------------------------------------------------
rows = list(csv.DictReader(open(f"{run_dir}/raw.jtl", encoding="utf-8")))
sub = [r for r in rows if "submit" in r["label"]]
t0 = min(int(r["timeStamp"]) for r in sub) / 1000.0
per = defaultdict(lambda: defaultdict(int))
phase_bounds = {}
for r in sub:
    t = int(r["timeStamp"]) / 1000.0 - t0
    per[int(t)][r["responseCode"]] += 1
    ph = r["label"].replace("submit-", "")
    lo, hi = phase_bounds.get(ph, (t, t))
    phase_bounds[ph] = (min(lo, t), max(hi, t))
secs = list(range(0, max(per) + 1))
ok = [per[s].get("201", 0) for s in secs]
r429 = [per[s].get("429", 0) for s in secs]
r503 = [per[s].get("503", 0) for s in secs]

outbox, worker = {}, defaultdict(float)
for r in csv.DictReader(open(f"{run_dir}/samples.csv", encoding="utf-8-sig")):
    t = datetime.strptime(r["utc_time"], "%Y-%m-%dT%H:%M:%S.%fZ").replace(tzinfo=timezone.utc).timestamp() - t0
    if r["value"] in ("", "unavailable"):
        continue
    if r["name"] == "flashsale_outbox_unpublished" and "order-service" in r["labels"]:
        outbox[t] = float(r["value"])
    if r["source"] == "rabbitmq" and r["labels"] == "queue=ProcessWorker.StockReserved" and r["name"] in ("messages_ready", "messages_unacknowledged"):
        worker[t] += float(r["value"])

fig, ax = plt.subplots(figsize=(10, 5.2))
ax.bar(secs, ok, width=1.0, color="#2e7d32", label="201 accepted")
ax.bar(secs, r503, width=1.0, bottom=ok, color="#f9a825", label="503 admission")
ax.bar(secs, r429, width=1.0, bottom=[a + b for a, b in zip(ok, r503)], color="#c62828", label="429 gateway")
colors = {"baseline": "#e3f2fd", "overload": "#ffebee", "recovery": "#e8f5e9"}
for ph, (lo, hi) in phase_bounds.items():
    ax.axvspan(lo, hi, color=colors.get(ph, "#eeeeee"), alpha=0.6, zorder=0)
    ax.text((lo + hi) / 2, ax.get_ylim()[1] * 0.97, ph, ha="center", va="top", fontsize=12, fontweight="bold")
ax.set_xlabel("seconds since the first request")
ax.set_ylabel("requests per second")
ax2 = ax.twinx()
ts = sorted(t for t in outbox if t >= -5)
ax2.plot(ts, [outbox[t] for t in ts], color="#1565c0", lw=1.8, label="Order Outbox unpublished")
tw = sorted(t for t in worker if t >= -5)
ax2.plot(tw, [worker[t] for t in tw], color="#6a1b9a", lw=1.8, ls="--", label="Worker queue (ready + unacked)")
ax2.set_ylabel("messages")
ax2.set_ylim(bottom=0)
h1, l1 = ax.get_legend_handles_labels()
h2, l2 = ax2.get_legend_handles_labels()
ax.legend(h1 + h2, l1 + l2, loc="upper center", bbox_to_anchor=(0.5, -0.16), ncol=3, framealpha=0.9)
ax.set_xlim(-2, max(max(secs), max(tw) if tw else 0) + 2)
ax.set_title(fig_title)
fig.tight_layout()
save(fig, fig_name)

# ---- verification overview (latest runs, read from tests/evidence) ----------
evidence = os.path.normpath(os.path.join(here, "..", "..", "tests", "evidence"))
verifiers = [
    ("Delivery ordering (TP-M02)", "delivery-ordering"), ("Failure handling (TP-F01)", "failures"),
    ("Workflow vs diagrams (TP-W04)", "workflow"), ("Process Worker (TP-P01)", "worker"),
    ("Processing state (TP-P02)", "processing"), ("Load shedding (TP-L01/L02/L04)", "load-shedding"),
    ("Inventory (TP-I01/I02)", "inventory"), ("Delivery / crash (TP-M01)", "delivery"),
    ("Reconciliation (TP-F02)", "reconciliation"), ("Deployment (TP-L03, offline)", "deployment-offline"),
    ("Publication (TP-O02)", "publication"), ("Metrics (TP-P04)", "metrics"), ("Validator (TP-W02)", "validator"),
    ("Cross-store (TP-I03)", "cross-store"), ("Outbox (TP-O01)", "outbox"), ("Stock results (TP-W01)", "stock-results"),
    ("DB exceptions (TP-W03)", "db-exceptions"), ("Extraction (TP-P08)", "extract"),
]
checks = []
for label, suffix in verifiers:
    logs = sorted(glob.glob(os.path.join(evidence, f"*Z-{suffix}.log")))
    if not logs:
        raise SystemExit(f"no evidence log for {suffix}")
    raw = open(logs[-1], "rb").read()
    is_utf16 = raw[:2] in (bytes([0xFF, 0xFE]), bytes([0xFE, 0xFF]))
    lines = raw.decode("utf-16" if is_utf16 else "utf-8-sig", errors="replace").splitlines()
    passed = sum(1 for l in lines if l.startswith("PASS"))
    failed = sum(1 for l in lines if l.startswith("FAIL"))
    checks.append((label, passed, failed, os.path.basename(logs[-1])))
checks.sort(key=lambda c: c[1])
fig, ax = plt.subplots(figsize=(9, 7.4))
ax.barh([c[0] for c in checks], [c[1] for c in checks], color="#2e7d32", label="PASS")
ax.barh([c[0] for c in checks], [c[2] for c in checks], left=[c[1] for c in checks], color="#c62828", label="FAIL")
for i, c in enumerate(checks):
    ax.text(c[1] + c[2] + 0.8, i, f"{c[1]}" + (f" + {c[2]} FAIL" if c[2] else ""), va="center", fontsize=12)
ax.set_xlabel("checks in the latest run")
ax.set_xlim(0, max(c[1] + c[2] for c in checks) + 10)
total_fail = sum(c[2] for c in checks)
ax.set_title("Runtime verifiers, latest runs" + (" (all PASS)" if total_fail == 0 else f" ({total_fail} FAIL)"))
fig.tight_layout()
save(fig, "verification-overview")
for c in checks:
    print(f"{c[0]}: {c[1]} pass, {c[2]} fail ({c[3]})")
print("ok")
