# Process Worker back-pressure A/B on EC2, 7 November 2026

A post-freeze experiment (`docs/week14-backpressure-fix.md`). It is kept apart from the 66
official runs and the 18 supplementary runs, and never pooled with them.

## Code

- **frozen:** the Process Worker of the tag `w14-official` (`9d00bea`), the code the
  official runs used. Built on the backend from a git worktree at the tag.
- **fix:** the Process Worker of `035e599` (post-freeze back-pressure fix). Every other
  service came from that build.
  - `git diff w14-official 035e599` changes, on the run paths, only the four Process
    Worker files.
  - It also changes report verifiers and `verify-freeze.ps1`, which no run uses.
- **Driver:** `scripts/ec2-session.ps1 -Plan backpressure` at `648d355`. The copies in
  `driver/` are the exact files used; the driver copied them at start.

## Hosts

- **Instances:** backend `i-02e9e76e8e3ab2290` (m7i-flex.large, 172.31.7.163) and JMeter
  `i-0cf4df00d23fdfd4e` (c7i-flex.large).
- **Image and zone:** both in ap-southeast-2a, on `ami-062900c135ab91582` (Amazon Linux
  2023.12.20261102, kernel 6.18.56). The AMI, instance types and zone are the same as on
  5 and 6 November, but this is a third host pair.
- **Safety timer:** shutdown was scheduled for 11:47 UTC (360 minutes). The session ended
  at 09:29 UTC.
- **Deploy:** the backend is on `035e599` with the frozen env values (Worker concurrency
  20, Order consumers 4, reconciliation 120 s and 300 s, gateway 200 r/s). See
  `deploy-backend.log`. From the JMeter host only port 80 of the backend is reachable
  (`deploy-jmeter.log`).

## Switch check (`switch-check/`), before any measured run

The two Worker images were `frozen` = `sha256:134ae6ae...` and `fix` = `sha256:8f679358...`
(`prepare-ab.log`).

| Step | Image | Manifest | Back-pressure HELP line | Run |
| --- | --- | --- | --- | --- |
| Worker on frozen | frozen | frozen | absent | C3 5/s 20 s PASS |
| Worker on fix | fix | fix | present | C3 5/s 20 s PASS |

All 5 Prometheus targets were up.

## Discarded (`discarded/`)

- **What:** the first switch check (05:53 to 05:57 UTC).
- **Why:** it switched the Worker with a compose override, but `run-matrix.ps1` passes
  `-ExtraComposeFile` to Local runs only. Over SSM its own `compose up` put the Worker
  back on the deployed (fix) image. The "frozen" check run's manifest records the fix
  image, so it is not a frozen run.
- **The fix in the driver:** it now selects the version by re-pointing the image tag
  the compose file names. Every measured run also asserts that the manifest, the
  running container and the switch all show the intended image, and that the
  back-pressure counter is exported by the fix only.

## Runs

- **Order:** 18 runs, 3 repeats, interleaved by repeat. Each repeat runs frozen C3 at
  200/s, C3 at 400/s and C4 (one consumer) at 400/s, then the same three on fix.
- **Defaults:** every run uses run-matrix's frozen defaults (60 s open-loop load, stock
  100,000, C3 limits); only `-Configs`, `-Replicas` and `-Rates` were passed.
- **Result:** all 18 runs PASS, with every validator check holding. Every worker check
  PASS (`driver.log`).

Files:

- `runs.csv`: the driver's row per run.
- `manifests.tgz`: per repeat, each run's `manifest.json`, `official.json` (worker version
  and image) and `host-post.log` (extraction, restarts, reconciliation by state, running
  Worker image, back-pressure HELP line).
- `w14-rep<N>-backend.tgz`: the backend run folders (samples, summary, stage intervals,
  validator log) and `docker-stats.csv`.
- `w14-rep<N>-jtl.tgz`: the raw JTLs.

The copy-back checked each file's SHA-256 on the host against the local copy.
`SHA256SUMS` lists them all.

## Analysis

```
python report/figures/analyze_official.py --backpressure tests/evidence/20261107T060310Z-backpressure-ab
```

It writes `report/figures/backpressure/` (`runs.csv`, `cells.csv`, `tab-backpressure.tex`).

## Measures

- **Worker dead letters:** the increase of `flashsale_process_worker_dead_lettered_total`
  over the run.
- **Back-pressure waits:** `flashsale_consumer_backpressure_waits_total`, exported by the
  fix only.
- **Reconciliation:** the re-triggers that Order Service logged during the run, by stuck
  state, from `host-post.log`. In every run the count equals the run's Worker dead
  letters. The extractor's counter missed some of them, because its window ends before
  reconciliation fires at 300 s.
