# Week 13 EC2 confirmation run (plan)

Confirms on EC2 what the local diagnosis found
(`tests/evidence/20261103T150800Z-slowdown-diagnosis.log`): with Order Service
consumers handling 4 messages at once and reconciliation waiting 120 s, the
C3/C4 drain is short and nothing is dead-lettered. Local numbers came from a
2-core Docker stack, so this run checks that the effect holds on
`m7i-flex.large` before the Week 14 freeze. Nothing here has been applied.

## What runs

Two settings, the same in every other respect. Each setting runs C2 and C4 with
2 replicas, at 50/s and 100/s, with 2 repeats.

| Setting | `ORDER_CONSUMER_CONCURRENCY` | `RECONCILIATION_STUCK_TIMEOUT_SECONDS` | `PROCESSING_MAX_CONCURRENCY` |
| --- | --- | --- | --- |
| current | 1 | 30 | 32 |
| fixed | 4 | 120 | 20 |

All other values are the same for both settings: queue bound 1000 on C4,
gateway `200r/s` with burst 100 on C4, `MaxConcurrentNewOrders` 64, Outbox
limit 2000, Inventory consumer concurrency 1, prefetch 20, 60 s open-loop load
and stock 100000.

That is 2 settings x 2 configs x 2 rates x 2 repeats = **16 runs**. From the
pilot, a run takes 3 to 8 minutes, so the runs take about 1.5 hours, or 2 hours
with deployment and the copy-back.

Order: run every `current` run first, then switch the env file and recreate the
services, then run every `fixed` run. Interleaving the two settings would
recreate the services between every run.

## Steps

1. The owner says "push", so the hosts clone the committed values.
2. The owner runs steps 2 to 7 of [week13-manual-steps.md](week13-manual-steps.md),
   with `"-var=auto_terminate_minutes=240"`. That is 4 hours: double the estimate,
   and still short enough to stop a forgotten session.
3. Deploy, then run the section 11a live check.
4. `current`: set the three variables above in `infra/ec2.env` on the backend, then run
   `run-matrix.ps1 -Transport Ssm -Configs C2,C4 -Replicas 2 -Rates 50,100 -Repeats 2`.
5. `fixed`: set the three variables, then run the same command. `prepare` recreates the services.
6. After each setting, extract every run, then bundle and copy back as in the pilot.
7. The owner runs steps 9 and 10 (destroy and leftover check).

## What counts as confirmed

- Every run passes its validator, as in the pilot.
- On C4 at 100/s, `fixed` drains in a clearly shorter time than `current` in both
  repeats, and has no dead letters.
- `fixed` has no reconciliation retriggers, or far fewer than `current`.
- On C2 at 50/s, `fixed` is no worse than `current`.

If `fixed` is not better on EC2, the freeze keeps the `current` values, and the
report says so.
