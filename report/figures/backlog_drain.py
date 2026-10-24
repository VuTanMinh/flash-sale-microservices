"""Backlog drain after overload for the EC2 run, with the same definition as
scripts/verify-load-shedding.ps1 case H: from the last overload submission until
both Outboxes' unpublished rows and the six main queues' ready + unacknowledged
messages are back at or below the baseline phase's maximum."""
import csv
import datetime as dt
import sys

run = sys.argv[1]
MAIN = {"OrderPlaced", "StockReserved", "StockRejected", "OrderProcessingStarted", "OrderProcessed", "ProcessWorker.StockReserved"}
ov = sorted(int(r["timeStamp"]) for r in csv.DictReader(open(run + "/raw.jtl")) if r["label"] == "submit-overload")
ov_start, ov_end = ov[0] / 1000.0, ov[-1] / 1000.0
outbox, depth, times, max_unacked = {}, {}, [], 0.0
for r in csv.DictReader(open(run + "/samples.csv", encoding="utf-8-sig")):
    t = r["utc_time"]
    if t not in outbox and t not in depth and (not times or times[-1] != t):
        times.append(t)
    try:
        v = float(r["value"])
    except ValueError:
        continue
    if r["source"] == "service" and r["name"] == "flashsale_outbox_unpublished" and ("service=order-service" in r["labels"] or "service=inventory-service" in r["labels"]):
        outbox[t] = outbox.get(t, 0.0) + v
    elif r["source"] == "rabbitmq" and r["name"] in ("messages_ready", "messages_unacknowledged"):
        if r["name"] == "messages_unacknowledged":
            max_unacked = max(max_unacked, v)
        q = [p[6:] for p in r["labels"].split(";") if p.startswith("queue=")]
        if q and q[0] in MAIN:
            depth[t] = depth.get(t, 0.0) + v

def ts(t):
    return dt.datetime.strptime(t, "%Y-%m-%dT%H:%M:%S.%fZ").replace(tzinfo=dt.timezone.utc).timestamp()

ordered = sorted(set(times), key=ts)
base_o = max([outbox.get(t, 0.0) for t in ordered if ts(t) < ov_start] or [0.0])
base_d = max([depth.get(t, 0.0) for t in ordered if ts(t) < ov_start] or [0.0])
drain = next((ts(t) - ov_end for t in ordered if ts(t) >= ov_end and outbox.get(t, 0.0) <= base_o and depth.get(t, 0.0) <= base_d), None)
peak_o = max(outbox.values() or [0.0])
peak_d = max(depth.values() or [0.0])
print("baseline max outbox %.0f depth %.0f | peak outbox %.0f depth (ready+unacked) %.0f | max unacked %.0f | backlog drain after overload %s s"
      % (base_o, base_d, peak_o, peak_d, max_unacked, None if drain is None else round(drain, 1)))
