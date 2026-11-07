"""Recompute every number the report states about the Worker back-pressure A/B from
report/figures/backpressure/runs.csv and check that the report states it."""
import csv
import re
import sys

repo = sys.argv[1]
B = chr(92)
tex = re.sub(r'\s+', ' ', open(repo + r'\report\report.tex', encoding='utf8').read())
runs = list(csv.DictReader(open(repo + r'\report\figures\backpressure\runs.csv', encoding='utf8')))
fz = [r for r in runs if r['worker_version'] == 'frozen']
fx = [r for r in runs if r['worker_version'] == 'fix']
f = lambda r, k: float(r[k]) if r[k] not in ('', 'None') else None
fails = 0


def claim(text, ok, detail):
    global fails
    t = text.replace('¤', B)
    present = t in tex
    good = present and ok
    fails += 0 if good else 1
    print(('OK   ' if good else 'FAIL ') + f'"{t}" -- {detail}' + ('' if present else ' [text not in report]'))


def rng(rs, k, scale=1.0):
    v = [f(r, k) / scale for r in rs if f(r, k) is not None]
    return (min(v), max(v), len(v)) if v else (None, None, 0)


claim('18 runs', len(runs) == 18 and len(fz) == 9 and len(fx) == 9 and all(r['status'] == 'PASS' and r['all_hold'] == 'True' for r in runs), '18 PASS')
lo, hi, _ = rng(fz, 'worker_dead_lettered'); claim('The frozen Worker dead-lettered 0 to 11 messages per run', (lo, hi) == (0, 11), f'{lo}-{hi}')
claim('every dead letter was one reconciliation re-trigger', all(f(r, 'worker_dead_lettered') == (f(r, 'recon_logged') or 0) for r in runs), 'dead letters == logged re-triggers in every run')
with_dl = [r for r in fz if f(r, 'worker_dead_lettered') > 0]
without = [r for r in fz if f(r, 'worker_dead_lettered') == 0]
lo, hi, _ = rng(with_dl, 'drain_s'); claim('Its 7 runs with dead letters drained in 308--326¤,s', len(with_dl) == 7 and (lo, hi) == (308, 326), f'{len(with_dl)} runs {lo}-{hi}')
lo, hi, _ = rng(without, 'drain_s'); claim('the 2 runs without any drained in 21--25¤,s', len(without) == 2 and (lo, hi) == (21, 25), f'{len(without)} runs {lo}-{hi}')
claim('The fixed Worker dead-lettered nothing in 9 of 9 runs and triggered no reconciliation',
      all(f(r, 'worker_dead_lettered') == 0 and not f(r, 'recon_logged') for r in fx), 'fix: 0 dead letters, 0 re-triggers')
lo, hi, _ = rng(fx, 'backpressure_waits'); claim('it waited 181--276 times per run instead', (lo, hi) == (181, 276), f'{lo}-{hi}')
lo, hi, _ = rng(fx, 'drain_s'); claim('every run drained in 29--43¤,s', (lo, hi) == (29, 43), f'{lo}-{hi}')
lo, hi, n = rng(fz, 'backlog_1pct_s'); claim('30--48¤,s after the load on the frozen Worker', (round(lo), round(hi)) == (30, 48), f'{lo:.1f}-{hi:.1f} ({n} runs)')
lo2, hi2, n2 = rng(fx, 'backlog_1pct_s'); claim('38--51¤,s on the fix, where measured', (round(lo2), round(hi2)) == (38, 51), f'{lo2:.1f}-{hi2:.1f} ({n2} of 9 runs)')
lo, hi, _ = rng(runs, 'comp_p95', 1000.0); claim('the completion p95 was 56--65¤,s on both', (round(lo), round(hi)) == (56, 65), f'{lo:.1f}-{hi:.1f}')
claim('Worker dead letters fell from 0--11 per run to none in 9 of 9 runs', True, 'as above')
claim('from 308--326¤,s in 7 of 9 runs to 29--43¤,s in all of them', True, 'as above')
print(f'{fails} claim(s) failed.')
print(f'Exit code: {1 if fails else 0}')
sys.exit(1 if fails else 0)
