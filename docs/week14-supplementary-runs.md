# Week 14 supplementary runs (plan)

One extra EC2 session after the 66 official runs. It answers two questions the
review raised that the official matrix could not:

- Where is C1's ceiling?
- Do the invariants hold at the sell-out boundary under load?

It uses the frozen code (`6ad3b00`, byte-identical to `9d00bea` in everything a
run uses) and changes **only command-line values** of `scripts/run-matrix.ps1`.
Nothing here has been applied yet.

## Why supplementary, and kept apart

- **It does not replace or extend the official matrix.** The 66 runs, their
  tables and every number in the Results stay as they are.
- **Its runs are labelled as supplementary.** They go to their own folder
  (`tests/evidence/<stamp>-supplementary/`), and each run's `official.json`
  says `"kind": "supplementary"` and names this plan. The report shows them in
  their own table, never in the official ones.
- **Its values are outside the frozen run matrix** (`docs/week14-freeze.md`
  section 7: 400/s only for C3 and C4, stock 100,000). That is why they are
  supplementary.
- **The code stays frozen.** No source, infrastructure, JMeter plan or script
  changes, so the freeze needs only this note, not a re-sign. Every other value
  is the frozen default: 60 s of open-loop load, threads `max(20, rate)`, one
  hot product, full reset and warm-up, and the C3 limits for C3.

## Cells (6 cells x 3 repeats = 18 runs)

| # | Config | Rate (/s) | Stock | Question |
| --- | --- | --- | --- | --- |
| 1 | C1 | 400 | 100,000 | C1's ceiling: does the row lock start to limit it above 200/s? |
| 2 | C2 | 400 | 100,000 | The same rate for the asynchronous design without shedding |
| 3 | C1 | 200 | 2,000 | Sell-out under load: no oversell, `Rejected` once stock is gone |
| 4 | C2 | 200 | 2,000 | The same through Redis and the full pipeline |
| 5 | C3 | 200 | 2,000 | The same with load shedding on |
| 6 | C2 | 100 | 100,000 | Anchor: the same cell as the official runs, to compare the hosts with 5 November |

At 200/s for 60 s about 12,000 requests compete for 2,000 units, so stock runs
out after about 10 s. The validator then proves the sell-out invariants on every
run:

- reservations never exceed 2,000;
- stock never goes below 0;
- one reservation per order;
- every accepted order is terminal, the rest as `Rejected`.

## Order and driver

- **Repeat-major order**, as for the official runs: cells 1 to 6, then again,
  then a third time.
- **One run-matrix call per run**, from the same driver as the official session
  with `-Plan supplementary`. A cell with a stock passes `-Stock 2000`; the
  others pass nothing beyond the official arguments. For example:

```
run-matrix.ps1 -Transport Ssm -BackendInstance <i-backend> -JMeterInstance <i-jmeter> -BackendHost <backend-private-ip> `
  -Configs C1 -Replicas 1 -Rates 400 -Repeats 1 -OutDir <session>\rep1
run-matrix.ps1 ... -Configs C2 -Replicas 1 -Rates 200 -Repeats 1 -Stock 2000 -OutDir <session>\rep1
```

- **Extraction and copy-back** work as in the official session: each run is
  extracted on the backend before the next reset, and each round is copied back
  after it ends.

## Time and cost

The estimate comes from the official session's own timings (per-run gaps in its
`runs.csv`, copy-back times in its log):

| Part | Time |
| --- | --- |
| Deploy over SSM and the live check | about 30 min |
| 18 runs (C1 runs about 2.5 min, C2 at 400/s about 6 min, the others about 3 min) | about 60 min |
| Copy-back, about 20 min per round for 6 runs | about 60 min |
| Margin | about 30 min |
| **Servers up in total** | **about 3 hours** |

The two servers (`m7i-flex.large` and `c7i-flex.large`) cost about USD 0.25 an
hour together, so the session costs well under USD 1 of credits. The safety
timer (`auto_terminate_minutes=720`) stays as before.

## What the owner does

The same steps as [week14-manual-steps.md](week14-manual-steps.md):

- steps 2 to 8 (credits check, keep awake, Terraform folder, log in, check no
  servers, create with `auto_terminate_minutes=720`, send the details);
- then, when told the session is done, steps 9 and 10 (destroy, check nothing is
  left).

Nothing else changes. Claude runs the session and reports after each round.

## Local dry run

Before the EC2 session, the same CLI values run against a scratch Compose stack
from a fresh clone of the committed HEAD:

- a sell-out cell for C1, C2 and C3 (100/s for 20 s against `-Stock 1000`);
- C1 and C2 at 400/s.

The script is `E:\Agent_Memory\DACNTT\tmp\w15supp\dry.ps1`, a scratch harness
like the README's case G. Its result is recorded under
`tests/evidence/<stamp>-supplementary-dry-run/` before the session.
