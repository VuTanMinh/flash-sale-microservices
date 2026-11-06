"""Recompute every number the review fixes added to the report from cells.csv and
check that the report states it. Prints one line per claim and an Exit code line."""
import csv
import re
import sys

repo = sys.argv[1]
tex = open(repo + r'\report\report.tex', encoding='utf8').read()
flat = re.sub(r'\s+', ' ', tex)
rows = {(r['config'], int(r['replicas']), int(r['rate'])): r for r in csv.DictReader(open(repo + r'\report\figures\official\cells.csv', encoding='utf8'))}


def med(k, f):
    v = rows[k][f + '_median']
    return float(v) if v else None


def rng(keys, f, scale=1.0):
    v = [med(k, f) / scale for k in keys if med(k, f) is not None]
    return min(v), max(v)


A = [k for k in rows if k[0] != 'C1']
C34_100 = [k for k in rows if k[0] in ('C3', 'C4') and k[2] >= 100]
fails = 0


def claim(text, ok, detail):
    global fails
    present = text in flat
    good = present and ok
    fails += 0 if good else 1
    print(('OK   ' if good else 'FAIL ') + f'"{text}" -- {detail}' + ('' if present else ' [text not in report]'))


lo, hi = rng(A, 'cpu_order'); claim('the Order Service took 26--51¤,¤%'.replace('¤', chr(92)), (round(lo), round(hi)) == (26, 51), f'order {lo:.1f}-{hi:.1f}')
lo, hi = rng(A, 'cpu_inventory'); claim('Inventory 4--17¤,¤%'.replace('¤', chr(92)), (round(lo), round(hi)) == (4, 17), f'inventory {lo:.1f}-{hi:.1f}')
lo, hi = rng(A, 'cpu_worker'); claim('the Worker 2--6¤,¤%'.replace('¤', chr(92)), (round(lo), round(hi)) == (2, 6), f'worker {lo:.1f}-{hi:.1f}')
lo, hi = rng(A, 'cpu_infra'); claim('the infrastructure 39--51¤,¤%'.replace('¤', chr(92)), (round(lo), round(hi)) == (39, 51), f'infra {lo:.1f}-{hi:.1f}')
k = ('C1', 1, 200)
claim('C1 at 200/s used 88¤,¤%: 46¤,¤% in Order Service and 41¤,¤% in the infrastructure'.replace('¤', chr(92)),
      (round(med(k, 'cpu_load_mean')), round(med(k, 'cpu_order')), round(med(k, 'cpu_infra'))) == (88, 46, 41),
      f"host {med(k, 'cpu_load_mean'):.1f} order {med(k, 'cpu_order'):.1f} infra {med(k, 'cpu_infra'):.1f}")
claim('C2 used 90¤,¤% of the host against C1\'s 46¤,¤%'.replace('¤', chr(92)),
      (round(med(('C2', 1, 50), 'cpu_load_mean')), round(med(('C1', 1, 50), 'cpu_load_mean'))) == (90, 46),
      f"C2@50 {med(('C2', 1, 50), 'cpu_load_mean'):.1f}, C1@50 {med(('C1', 1, 50), 'cpu_load_mean'):.1f}")
lo, hi = rng([k for k in A if k[2] == 50], 'done_load_per_s'); claim('keeps pace (46--51 a second)', (round(lo), round(hi)) == (46, 51), f'{lo:.1f}-{hi:.1f}')
lo, hi = rng([k for k in A if k[2] == 100], 'done_load_per_s'); claim('At 100/s it falls to 21--30 a second', (round(lo), round(hi)) == (21, 30), f'{lo:.1f}-{hi:.1f}')
lo, hi = rng([k for k in A if k[2] >= 200], 'done_load_per_s'); claim('at 200/s and above to 4--10 a second', lo >= 3.5 and hi < 10.5, f'{lo:.1f}-{hi:.1f}')
lo, hi = rng([k for k in A if k[2] >= 100], 'done_load_per_s'); claim('only 4--30 a second complete', round(lo) == 4 and round(hi) == 30, f'{lo:.1f}-{hi:.1f}')
claim('about 4 orders a second completed', round(med(('C2', 1, 200), 'done_load_per_s')) == 4, f"C2@200 {med(('C2', 1, 200), 'done_load_per_s'):.2f}")
claim('42 and 124¤,s for C2 at 100 and 200/s'.replace('¤', chr(92)),
      (round(med(('C2', 1, 100), 'backlog_1pct_s')), round(med(('C2', 1, 200), 'backlog_1pct_s'))) == (42, 124), 'C2 99 % done')
lo, hi = rng(C34_100, 'backlog_1pct_s'); claim('36--59¤,s for C3 and C4 at 100/s and above'.replace('¤', chr(92)), (round(lo), round(hi)) == (36, 59), f'{lo:.1f}-{hi:.1f}')
lo, hi = rng([('C2', 1, 100), ('C2', 1, 200)], 'completed_per_s'); claim('For C2 it is 60--66 a second at 100/s and above', (round(lo), round(hi)) == (60, 66), f'{lo:.1f}-{hi:.1f}')
rat = [(med(k, 'accepted') / (60 + med(k, 'backlog_1pct_s'))) / med(k, 'completed_per_s') for k in C34_100]
waited = [x for x in rat if x > 1.5]
claim('understates their rate three to four times in the cells that waited', min(waited) >= 2.95 and max(waited) < 4.05,
      f'bulk rate / Completed/s in the waiting cells {min(waited):.1f}-{max(waited):.1f} ({len(waited)} of {len(rat)} cells)')
lo, hi = rng([k for k in rows if k[0] in ('C3', 'C4') and k[2] == 100], 'comp_p95', 1000.0)
claim('accepted orders wait 57--64¤,s at p95 to complete'.replace('¤', chr(92)), (round(lo), round(hi)) == (57, 64), f'{lo:.1f}-{hi:.1f}')
print(f'{fails} claim(s) failed.')
print(f'Exit code: {1 if fails else 0}')
sys.exit(1 if fails else 0)
