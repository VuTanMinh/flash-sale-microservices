"""Recompute every number the report states about the supplementary runs from
report/figures/supplementary/runs.csv and cells.csv (and the official C2 100/s
cell) and check that the report states it. One line per claim, then Exit code."""
import csv
import re
import sys

repo = sys.argv[1]
B = chr(92)
tex = re.sub(r'\s+', ' ', open(repo + r'\report\report.tex', encoding='utf8').read())
runs = list(csv.DictReader(open(repo + r'\report\figures\supplementary\runs.csv', encoding='utf8')))
off = {(c['config'], c['rate']): c for c in csv.DictReader(open(repo + r'\report\figures\official\cells.csv', encoding='utf8'))}
fails = 0


def cell(cfg, rate):
    return [r for r in runs if r['config'] == cfg and r['rate'] == str(rate)]


def rng(rs, f, scale=1.0):
    v = [float(r[f]) / scale for r in rs if r[f] not in ('', 'None')]
    return min(v), max(v)


def claim(text, ok, detail):
    global fails
    t = text.replace('¤', B)
    present = t in tex
    good = present and ok
    fails += 0 if good else 1
    print(('OK   ' if good else 'FAIL ') + f'"{t}" -- {detail}' + ('' if present else ' [text not in report]'))


claim('All 18 runs passed every validator check', len(runs) == 18 and all(r['status'] == 'PASS' and r['all_hold'] == 'True' for r in runs), f'{len(runs)} runs')
c1 = cell('C1', 400)
lo, hi = rng(c1, 'achieved'); claim('C1 accepted 194.5--203.8 requests a second', (lo, hi) == (194.5, 203.8), f'{lo}-{hi}')
lo, hi = rng(c1, 'api_p50', 1000); claim('the API p50 rose to 1.9--2.0¤,s', round(lo, 1) == 1.9 and round(hi, 1) == 2.0, f'{lo:.3f}-{hi:.3f}')
lo, hi = rng(c1, 'api_p95', 1000); claim('the p95 to 2.8--3.0¤,s', round(lo, 1) == 2.8 and round(hi, 1) == 3.0, f'{lo:.3f}-{hi:.3f}')
lo, hi = rng(c1, 'cpu_load_mean'); claim('host CPU 96¤,¤% busy (Order Service 48--50', round(lo) == 96 and round(hi) == 96, f'{lo:.1f}-{hi:.1f}')
lo, hi = rng(c1, 'cpu_order'); claim('(Order Service 48--50¤,¤%', (round(lo), round(hi)) == (48, 50), f'{lo:.1f}-{hi:.1f}')
lo, hi = rng(c1, 'cpu_infra'); claim('the infrastructure 46--47¤,¤%)', (round(lo), round(hi)) == (46, 47), f'{lo:.1f}-{hi:.1f}')
sell = cell('C1', 200) + cell('C2', 200) + cell('C3', 200)
claim('sold exactly 2,000 units and ended with stock 0', all(r['sold'] == '2000' and r['final_stock'] == '0' for r in sell), f'{len(sell)} sell-out runs')
for cfg, txt in (('C1', 'rejected: 10,047--10,103 per run for C1'), ('C2', '7,716--8,251 for C2'), ('C3', '403--835 for C3')):
    v = [int(r['jtl_2xx']) - int(r['sold']) for r in cell(cfg, 200)]
    want = tuple(int(x.replace(',', '')) for x in re.findall(r'[\d,]+', txt)[:2])
    claim(txt, (min(v), max(v)) == want, f'{min(v)}-{max(v)}')
v = [int(r['jtl_2xx']) for r in cell('C3', 200)]; claim('C3 admitted only 2,403--2,835 orders', (min(v), max(v)) == (2403, 2835), f'{min(v)}-{max(v)}')
v = [int(r['n503']) for r in cell('C3', 200)]; claim('refused 6,576--7,239 requests per run with 503', (min(v), max(v)) == (6576, 7239) and all(r['n429'] == '0' for r in cell('C3', 200)), f'{min(v)}-{max(v)}')
c2 = cell('C2', 400)
lo, hi = rng(c2, 'achieved'); claim('C2 accepted every request, at 180.2--184.2 a second', (lo, hi) == (180.2, 184.2) and all(r['jtl_2xx'] == r['jtl_submissions'] for r in c2), f'{lo}-{hi}')
lo, hi = rng(c2, 'api_p95', 1000); claim('an API p95 of 2.7--2.9¤,s', round(lo, 1) == 2.7 and round(hi, 1) == 2.9, f'{lo:.3f}-{hi:.3f}')
lo, hi = rng(c2, 'comp_p95', 1000); claim('a p95 of 140--147¤,s', (round(lo), round(hi)) == (140, 147), f'{lo:.1f}-{hi:.1f}')
lo, hi = rng(c2, 'drain_s'); claim('the backlog drained 134--148¤,s after the load', (lo, hi) == (134, 148), f'{lo}-{hi}')
lo, hi = rng(c2, 'dead_lettered'); claim('No message was dead-lettered', hi == 0, f'max {hi}')
lo, hi = rng(c2, 'reconciliation'); claim('re-triggered 190--971 orders per run', (lo, hi) == (190, 971), f'{lo}-{hi}')
med = sorted(float(r['achieved']) for r in c2)[1]; claim('accepted about 183 a second at the same p95', round(med) == 183, f'median {med}')
o = off[('C2', '100')]
s = cell('C2', 100)
sm = lambda f, sc=1.0: sorted(float(r[f]) / sc for r in s)[1]
claim('about 5¤,¤% lower (95.1 against 100.6 a second)', round(sm('achieved'), 1) == 95.1 and float(o['achieved_median']) == 100.6 and round(100 * (1 - 95.1 / 100.6)) in (5, 6), f"{sm('achieved')} vs {o['achieved_median']}")
claim('nearly twice as long (1.4 against 0.74¤,s)', round(sm('api_p95', 1000), 1) == 1.4 and round(float(o['api_p95_median']) / 1000, 2) == 0.74, f"{sm('api_p95')} vs {o['api_p95_median']}")
claim('14.0 orders a second completed during the load against 23.5', round(sm('done_load_per_s'), 1) == 14.0 and round(float(o['done_load_per_s_median']), 1) == 23.5, f"{sm('done_load_per_s'):.2f} vs {float(o['done_load_per_s_median']):.2f}")
claim('the completion p95 was 58 against 48¤,s, and the drain 46 against 32¤,s', round(sm('comp_p95', 1000)) == 58 and round(float(o['comp_p95_median']) / 1000) == 48 and sm('drain_s') == 46 and float(o['drain_s_median']) == 32, 'anchor')
print(f'{fails} claim(s) failed.')
print(f'Exit code: {1 if fails else 0}')
sys.exit(1 if fails else 0)
