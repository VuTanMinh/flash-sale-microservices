# Flash-Sale Microservices Capstone

Thiết kế và đánh giá hệ thống microservices xử lý giao dịch song song trong kịch bản flash-sale — TDTU.

**Students:** Vũ Đình Kiệt (523V0011) and Vũ Tấn Minh (523V0012) — Class 23K50201 — TDTU  
**Roadmap:** 08/08–21/11 (15 weeks)

## Project scope and design

The report is in `report/`: the LaTeX source, its figures, and the built
`report/report.pdf` and `report/progress/progress-report.pdf`. The design
documents are in `docs/`.

- [Reproduce the results on a fresh machine](docs/reproduction.md)
- [Requirement-to-evidence index](docs/evidence-index.md)
- [Midterm review: what was found and how each finding was resolved](docs/midterm-review-disposition.md)
- [Test plan (every test case, its inputs, expected result and log)](docs/test-plan.md)

- [Scope and research questions](docs/00-scope-lock.md)
- [Service boundaries and event flow](docs/service-boundaries.md)
- [Order state machine](docs/order-state-machine.md)
- [Inventory invariants](docs/inventory-invariants.md)
- [Experiment protocol](docs/experiment-protocol.md)
- [Local infrastructure and AWS target](docs/infrastructure.md)
- [EC2 deployment runbook](docs/deployment.md)
- [OpenAPI export](docs/api-contract-v1.json)
- [Capstone report (PDF)](report/report.pdf) and [progress report (PDF)](report/progress/progress-report.pdf)

## Repository layout

| Path | Purpose |
|---|---|
| `src/` | Order Service, Inventory Service, Process Worker, and event contracts |
| `infra/` | Docker Compose (local and `docker-compose.ec2.yml`), Nginx, and `terraform/` for the AWS EC2 deployment |
| `scripts/` | Database reset/seed, warm-up, validation, verifiers, metric collection/extraction, and Redis Lua |
| `tests/` | .NET tests, JMeter plans, and `evidence/` (saved verifier logs and run data) |
| `docs/` | Scope, architecture, correctness, experiment, API, reproduction and evidence documents |
| `report/` | LaTeX report, figures and the built PDFs (report and progress report) |

## Results and how to reproduce them

The official experiment is 66 validated runs on AWS EC2: C1 to C4 at 50 to
400 requests a second, C4 with 1, 2 and 4 Inventory consumers, 3 repeats of
every cell, all with the values frozen in [docs/week14-freeze.md](docs/week14-freeze.md).
The raw data of every run (manifests, JMeter JTLs, collector samples, validator
logs) is in `tests/evidence/20261105T104832Z-official/`, and the report's
Results, Discussion and Conclusion chapters are built from it.

The code those runs used is the annotated tag **`w14-official`** (`9d00bea`). The
branch has moved on since the freeze was closed, with a post-freeze Process
Worker fix, so check out the tag to run the official experiment's code:
`git checkout w14-official`. The saved data and the analysis below live on the
branch and work from its head.

1. **Rebuild every Results table and figure from the saved data** (no Docker,
   no cloud): `python report/figures/analyze_official.py`, then
   `latexmk -pdf report.tex` in `report/`. On an unchanged checkout nothing in
   `report/figures/official/` changes.
2. **Run a validated experiment yourself** with the official runs' code
   (`git checkout w14-official`) on a local copy of the EC2 stack (Docker and
   JMeter):
   `powershell -ExecutionPolicy Bypass -Command "& .\scripts\verify-ec2-stack.ps1 -Cases A,G"`.
   It runs the same matrix runner as the official runs, with reset, seed,
   warm-up, open-loop load, drain and the correctness validator.
   Then `python report/figures/analyze_official.py --runs "$env:TEMP\ec2v-matrix" reproduction`
   draws those runs' own table and figures.
3. **Repeat the official matrix on EC2** (needs an AWS account), from the tag
   `w14-official`: the plan is
   [docs/week14-official-runs.md](docs/week14-official-runs.md) and the account
   steps are [docs/week14-manual-steps.md](docs/week14-manual-steps.md).

The full fresh-machine guide, prerequisites included, is
[docs/reproduction.md](docs/reproduction.md) (sections 7 to 9 for the
experiments).

## Quickstart

For a full reproduction from a clean machine, follow [docs/reproduction.md](docs/reproduction.md). To run the local stack and the three services by hand, follow [Local infrastructure — Running the application on the local stack](docs/infrastructure.md#running-the-application-on-the-local-stack). In short: Compose up, apply the role script on an existing volume, migrate with each service's own account, create the certificate, warm up, then `dotnet run` each service. The own-account runtime is verified by `scripts/verify-runtime-accounts.ps1`. The AWS EC2 deployment required by the brief (one backend host, JMeter on a separate host) is in `infra/terraform/` with `infra/docker-compose.ec2.yml`; its runbook is [docs/deployment.md](docs/deployment.md).
