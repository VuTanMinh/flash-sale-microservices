# Week 14 official runs (plan)

The official experiment matrix of the brief (§6), run once on one pair of EC2
hosts with every value frozen in [week14-freeze.md](week14-freeze.md) (frozen
commit `9d00bea`, re-signed by the owner on 5 November 2026). The owner's AWS
steps are in [week14-manual-steps.md](week14-manual-steps.md). Nothing here has
been applied yet.

## What runs

| Configuration | Replicas | Rates (req/s) | Cells |
| --- | --- | --- | --- |
| C1 | 1 | 50, 100, 200 | 3 |
| C2 | 1 | 50, 100, 200 | 3 |
| C3 | 1 | 50, 100, 200, 400 | 4 |
| C4 | 1, 2, 4 | 50, 100, 200, 400 | 12 |

That is 22 cells x 3 repeats = **66 runs**. Every run uses the frozen defaults of
`scripts/run-matrix.ps1`: 60 s of open-loop load, stock 100,000 on one hot
product, threads `max(20, rate)`, queue bound 1000 and gateway 200 r/s with burst
100 for C3 and C4, and a full reset, seed and warm-up before the run. The driver
passes only `-Transport Ssm`, the host ids and address, `-Configs`, `-Replicas`,
`-Rates`, `-Repeats 1` and `-OutDir`. It never overrides a frozen value.

This is the same set of runs as two matrix calls,
`-Configs C1,C2,C3,C4 -Rates 50,100,200` (54 runs) and
`-Configs C3,C4 -Rates 400` (12 runs), both with `-Repeats 3` and
`-Replicas 1,2,4`. The driver splits them into one call per run for three
reasons:

1. **Repeat-major order.** A single call runs a cell's three repeats back to
   back. The driver runs repeat 1 of all 22 cells, then repeat 2, then repeat 3,
   so a slow drift in the hosts over the day spreads across every cell instead of
   landing on one.
2. **Extraction before the next reset.** `extract-run-metrics.ps1` reads the run's
   orders from the live database, and the next run's reset wipes them. The
   driver extracts each run on the backend right after its post step, as in the
   Week 13 confirmation.
3. **A failure loses one run, not a matrix.** The matrix stops at the first run
   that fails; with one call per run, restarting means skipping the finished
   runs, with nothing re-run.

### Recording the true repeat number

A call with `-Repeats 1` labels its run `rep1` in `run_id` and `manifest.json`.
No frozen script changes for this. Instead:

- each repeat writes to its own folder, `rep1/`, `rep2/` and `rep3/`;
- the driver writes `official.json` next to each `manifest.json`, holding the true
  repeat, the cell, the round order and the start time;
- the driver keeps `runs.csv`, one row per run (repeat, cell, run id, status,
  achieved rate, drain, validator exit).

The results tables group runs by `official.json`, never by `run_id`.

## Order of steps

1. The owner does steps 1 to 8 of the manual steps and pastes the Terraform
   output with "applied".
2. **Deploy** over SSM, as in Week 13: wait for cloud-init, clone
   `main-test-bug-fix`, create `infra/ec2.env` from `infra/ec2.env.example` with
   fresh random passwords and nothing else changed, build, start, load the C1
   baseline tables, start the `docker stats` sampler. Prepare the JMeter host the
   same way. Record each host's commit and that the tree is clean.
3. **Live check** (deployment.md section 11a): `-Configs C3,C2,C1 -Rates 5
   -DurationSeconds 20 -Stock 1000`. It must print `MATRIX PASS: 3 run(s).` These
   are not official runs and go in their own folder.
4. **Round 1:** the 22 cells, repeat 1. Then copy back round 1.
5. **Round 2:** the same, repeat 2. Then copy back round 2.
6. **Round 3:** the same, repeat 3. Then copy back round 3.
7. Final host checks: no container restart, no "too many clients", disk use.
   Then tell the owner the evidence is copied back, so they can destroy.

## Copy-back

After each round both hosts are idle, so the copy cannot disturb a measurement.
The backend bundle holds every run folder (manifest inputs, collector samples,
validator log, extraction summary and stage intervals, `docker-stats.csv`). The
JMeter bundle holds every raw JTL and JMeter log. The two copy in parallel
through SSM, each checked against the SHA-256 printed on the host.

`db.dump` files stay on the backend: through SSM a copy moves about 15 KB every
few seconds, so 66 dumps would take hours. They are not needed, because each run
is extracted before the next reset. A round's bundles are about 10 MB together,
which takes about 20 minutes, so the three copies add about 1 hour.

A round's runs are lost only if the hosts die before its copy finishes; at most
one round (22 runs) is ever at risk.

## Time budget and cutoff

From Week 13 on the same hosts, a run takes 2.5 to 4 minutes at 50 and 100/s and
up to 8 minutes when the drain is long; 200 and 400/s runs drain longer. Budget:
66 runs at about 5 to 7 minutes is 5.5 to 7.5 hours, plus 45 minutes for setup
and about 1 hour for the copies, so 7.5 to 9.5 hours of the 12-hour timer.

The timer ends 720 minutes after apply. Before each run the driver checks that
the run (allowed 12 minutes) plus a final copy-back (allowed 45 minutes) still
ends at least 1 hour before the timer. If not, it stops, copies back everything
finished and reports. The cells still missing then run in a second session,
together with one cell repeated from the first (C2 at 100/s, repeat 1), so the
report can show whether the two machines differ.

## When a run fails

The matrix stops at the first run that fails a gate or the validator. Then:

1. Keep everything of the failed run: its folder, manifest, validator log and
   collector samples are copied back and never deleted or overwritten.
2. Diagnose from the run's own evidence and the host logs.
3. Report to the coordinator and the owner what failed and why, and **ask before
   rerunning anything**. This is stricter than the guide.
4. On the owner's word, restart the driver from the next cell; it skips every
   run that already has a PASS manifest in its repeat folder. A rerun of the
   failed run, if agreed, goes to a new folder and both runs are reported.

## What counts as done

- 66 run folders across `rep1/` to `rep3/`, each with `manifest.json` status
  `PASS`, its `official.json` and an extraction summary.
- Every validator log shows check 0b PASS (run isolation) and `RESULT: all
  checks hold`, with checks 1 to 4 and 6 (queue bound off) for C1, 1 to 7 for
  C2, and 1 to 5 and 7 for C3 and C4.
- Both hosts ran a commit whose frozen paths (`src/`, `infra/`, `tests/jmeter/`,
  `scripts/`) equal `9d00bea`, with a clean tree, read back at deploy and at the
  end.
- No container restart and no "too many clients" over the session.
- Bundles copied to this PC with matching SHA-256, then saved under
  `tests/evidence/` with a summary log, before the owner destroys.
